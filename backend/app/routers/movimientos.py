"""API de bitacora_movimiento_persona (SCJ-PRO-02: suspender/reactivar/dar de baja).

Gate de permisos: GET sin cambio -- no existe código de lectura para este módulo, sigue el
gate débil. POST (cambio de estado) exige además requiere_permiso("cambio_estado_persona")
(app/permisos.py). baja_definitiva exige además asignacion_edicion (129_*.sql)."""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import PERMISO_DENEGADO, limpiar_para_log
from app import permisos
from app.permisos import requiere_permiso
from app.schemas.movimientos import MovimientoCreate, MovimientoOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/personas/{persona_id}/movimientos", tags=["movimientos"])

# Movimientos que dejan a la persona fuera de «activo»: apagan su acceso a las terminales.
TIPOS_QUE_DAN_DE_BAJA_EN_TERMINALES = ("suspension", "baja_definitiva")
ADVERTENCIA_BAJA_TERMINAL_PENDIENTE = "baja_terminal_pendiente"

# 129_*.sql: la baja definitiva cierra las asignaciones abiertas de la persona (trigger de la bitácora,
# con los privilegios del caller). Sin asignacion_edicion la RLS filtraba ese UPDATE y las asignaciones
# quedaban abiertas sin error; ahora la policy de INSERT lo exige y el backend lo valida antes.
PERMISO_EXTRA_BAJA_DEFINITIVA = "asignacion_edicion"
MENSAJE_BAJA_SIN_PERMISO_ASIGNACIONES = (
    "Para dar de baja definitiva a una persona también necesitas el permiso de edición de asignaciones."
)
MENSAJE_MOVIMIENTO_SIN_PERMISO = "No tienes permiso para registrar este movimiento."
# 32_*.sql: la policy de asignacion impide terminar la asignación de quien ocupa el puesto administrador
# (es_administrador_generico). No es falta de permiso: es la protección de ese puesto. Mismo 422 legible
# que revocar_permiso / terminar_asignacion / cambiar_puesto_asignacion / cambiar_estado_puesto.
MENSAJE_BAJA_PUESTO_ADMINISTRADOR = (
    "No se puede dar de baja definitiva a quien ocupa el puesto administrador; primero hay que reasignar "
    "ese puesto."
)


def _solicitar_baja_en_terminales(db_servicio: Client, persona_id: str) -> tuple[int, list[str]]:
    """SCJ-DEC-12 §5. Llama fn_terminal_baja_por_persona_inactiva con service_role: quien suspende tiene
    cambio_estado_persona, que NO implica terminal_usuario_edicion, y con la RLS del caller el INSERT se
    rechazaría y la persona seguiría marcando. La autorización ya ocurrió (el caller estaba autorizado a
    cambiar el estado) y el autor de la baja lo deriva el RPC del movimiento de persona, no el backend.

    Devuelve (bajas_emitidas, advertencias). NUNCA propaga un error: el movimiento de persona ya está
    confirmado y es el acto principal; si esto falla, se avisa y un job de respaldo lo reintenta.
    Un resultado -1 (sin autor derivable) también es una advertencia, no un reintento en bucle."""
    try:
        resultado = (
            db_servicio.postgrest.schema("tiempo")
            .rpc("fn_terminal_baja_por_persona_inactiva", {"p_persona_id": persona_id})
            .execute()
            .data
        )
    except Exception as error:  # APIError, red, timeout…
        logger.error(
            "no se pudo pedir la baja de terminal de la persona %s (%s, código %s)",
            persona_id,
            type(error).__name__,
            getattr(error, "code", None),
        )
        return 0, [ADVERTENCIA_BAJA_TERMINAL_PENDIENTE]
    if isinstance(resultado, bool) or not isinstance(resultado, int) or resultado < 0:
        logger.error(
            "fn_terminal_baja_por_persona_inactiva devolvió %r para la persona %s (sin autor derivable "
            "o forma inesperada)",
            resultado,
            persona_id,
        )
        return 0, [ADVERTENCIA_BAJA_TERMINAL_PENDIENTE]
    return resultado, []


def _traducir_42501(tipo_movimiento: str) -> HTTPException:
    """Respaldo: el backend ya validó permisos y el puesto administrador antes del INSERT, así que un 42501
    aquí es una carrera (permiso revocado entre la validación y el INSERT) o una policy desalineada con el
    backend. NO se lee el texto de Postgres para distinguir causas: no es un contrato (cambia con versión e
    idioma). Por eso el mensaje es SIEMPRE el genérico: en una baja definitiva el rechazo puede venir de la
    policy de la bitácora (falta asignacion_edicion, 129_) o de la de asignacion (puesto administrador, 32_),
    y el respaldo nunca afirma una causa. Al log sólo el tipo de movimiento."""
    logger.warning(
        "la RLS rechazó el movimiento %s (42501) pese a las validaciones del backend; revisar permisos/policy",
        limpiar_para_log(tipo_movimiento, 40),
    )
    return HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_MOVIMIENTO_SIN_PERMISO)


@router.post("", status_code=201, response_model=MovimientoOut)
def crear_movimiento(
    persona_id: str,
    datos: MovimientoCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(requiere_permiso("cambio_estado_persona")),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """SCJ-PRO-02: el trigger trg_bitacora_sincroniza_persona actualiza persona.estado solo —
    este endpoint nunca hace UPDATE directo a personas.persona. registrado_por es el caller
    autenticado; fn_caller_activo() ya exige que tenga fila en personas.usuario para poder
    insertar aquí, así que el FK nunca falla.

    baja_definitiva exige ADEMÁS asignacion_edicion (con herencia jerárquica, igual que la policy de
    129_*.sql): el 403 legible sale aquí antes de tocar la base. Tampoco se puede dar de baja a quien
    ocupa el puesto administrador (422, 32_*.sql). Si aun así la RLS rechaza el INSERT (42501), se
    responde 403 con mensaje fijo sin leer el texto de la base; ese texto nunca va a la respuesta ni al
    log."""
    if datos.tipo_movimiento == "baja_definitiva":
        persona_caller = permisos.resolver_persona_id(db, caller)
        if not permisos.tiene_alguno(db, persona_caller, PERMISO_EXTRA_BAJA_DEFINITIVA):
            raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_BAJA_SIN_PERMISO_ASIGNACIONES)
        # Puesto administrador (32_*.sql): se detecta antes, con service_role, porque la asignación de la
        # persona afectada puede no ser visible por la RLS del caller. Es un dato para decidir, no la
        # autorización (esa la sigue haciendo la policy en el INSERT).
        if permisos.es_administrador_generico(db_servicio, persona_id):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_BAJA_PUESTO_ADMINISTRADOR)

    try:
        movimiento = (
            db.postgrest.schema("personas")
            .table("bitacora_movimiento_persona")
            .insert(
                {
                    "persona_id": persona_id,
                    "tipo_movimiento": datos.tipo_movimiento,
                    "motivo": datos.motivo,
                    "registrado_por": caller.auth_user_id,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        if error.code != PERMISO_DENEGADO:
            raise
        raise _traducir_42501(datos.tipo_movimiento) from None

    # SCJ-DEC-12 §5: si la persona dejó de estar activa, se pide la baja de sus altas en las terminales.
    # Sólo DESPUÉS de que el movimiento quedó confirmado (si el INSERT falla nada de esto corre).
    bajas, advertencias = 0, []
    if datos.tipo_movimiento in TIPOS_QUE_DAN_DE_BAJA_EN_TERMINALES:
        bajas, advertencias = _solicitar_baja_en_terminales(db_servicio, persona_id)
    return {**movimiento, "advertencias": advertencias, "bajas_terminal_emitidas": bajas}


@router.get("", response_model=list[MovimientoOut])
def listar_movimientos(persona_id: str, db: Client = Depends(get_caller_client)) -> list[dict]:
    tabla = db.postgrest.schema("personas").table
    movimientos = (
        tabla("bitacora_movimiento_persona")
        .select("*")
        .eq("persona_id", persona_id)
        .order("fecha_efectiva", desc=True)
        .execute()
        .data
    )

    autores_ids = {m["registrado_por"] for m in movimientos if m.get("registrado_por")}
    if autores_ids:
        filas_usuario = (
            tabla("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", list(autores_ids))
            .execute()
            .data
        )
        nombre_por_id = {fila["auth_user_id"]: fila["nombre_usuario"] for fila in filas_usuario}
        for movimiento in movimientos:
            movimiento["registrado_por_nombre"] = nombre_por_id.get(movimiento.get("registrado_por"))

    return movimientos
