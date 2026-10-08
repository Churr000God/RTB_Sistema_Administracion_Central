"""API de bitacora_movimiento_persona (SCJ-PRO-02: suspender/reactivar/dar de baja).

Gate de permisos: GET sin cambio -- no existe código de lectura para este módulo, sigue el
gate débil. POST (cambio de estado) exige además requiere_permiso("cambio_estado_persona")
(app/permisos.py)."""

import logging

from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.permisos import requiere_permiso
from app.schemas.movimientos import MovimientoCreate, MovimientoOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/personas/{persona_id}/movimientos", tags=["movimientos"])

# Movimientos que dejan a la persona fuera de «activo»: apagan su acceso a las terminales.
TIPOS_QUE_DAN_DE_BAJA_EN_TERMINALES = ("suspension", "baja_definitiva")
ADVERTENCIA_BAJA_TERMINAL_PENDIENTE = "baja_terminal_pendiente"


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
    insertar aquí, así que el FK nunca falla (no hace falta manejo de error especial)."""
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
