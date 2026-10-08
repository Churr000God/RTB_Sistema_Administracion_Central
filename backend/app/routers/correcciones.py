"""API de tiempo.correccion (SCJ-PRO-10). Corrige el valor de una marca sin modificarla nunca --
inserta una fila nueva que apunta a la marca original (SCJ-DEC-03).

Sólo se corrige resolviendo una excepcion existente -- nunca libre. El trigger BEFORE INSERT
(fn_correccion_valida, db/ddl/02_tiempo.sql) es la integridad real e insaltable: exige excepcion
previa y bloquea cualquier valor_corregido que reordene las marcas de la persona. Este router
pre-chequea lo mismo para dar mensajes legibles (422 en vez del texto crudo de Postgres) y, sobre
todo, para decidir DINÁMICAMENTE qué permiso exigir -- no se puede declarar con un solo
Depends(requiere_permiso(...)) fijo porque el permiso depende del estado de la excepcion de la
marca (SCJ-PRO-10 §II.3). AND, no OR (confirmado por db: así quedó la RLS real de INSERT en
tiempo.correccion, 48/49_*.sql):
- correccion_edicion SIEMPRE (los 3 puestos).
- ADEMÁS excepcion_reapertura si TODAS las excepciones de la marca ya están 'resuelto'
  (reabrir/editar una ya cerrada) -- no heredable, exclusivo de Gerente o Encargado de TI.

Gate: get_caller_client (RLS) -- nunca service_role, la RLS que arma db es la autorización real.
tiempo.parametro/tiempo.dia_festivo se leen con service_role: son configuración global de
sistema, no datos del caller (mismo criterio que app/scheduler.py leyendo
hora_corrida_cierre_dia)."""

import logging
from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import (
    MENSAJE_DIA_CERRADO_REQUIERE_REVISION,
    MENSAJE_MARCA_EN_TRAMO,
    limpiar_para_log,
    traducir_error_dia_cerrado,
)
from app.dias_habiles import _dias_habiles_limite, _dias_habiles_transcurridos, _festivos_entre
from app.marca_en_tramo import EN_TRAMO, bloqueo_por_tramo
from app.permisos import resolver_persona_id, tiene_permiso
from app.schemas.correcciones import CorreccionCreate, CorreccionOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/correcciones", tags=["correcciones"])

MENSAJE_MARCA_NO_ENCONTRADA = "La marca no existe."
MENSAJE_MARCA_SIN_EXCEPCION = (
    "Esta marca no tiene ninguna excepción asociada -- no se puede corregir sin pasar antes "
    "por la cola de excepciones."
)
MENSAJE_VENTANA_VENCIDA = (
    "La ventana de corrección de {dias} día(s) hábil(es) ya venció para esta marca."
)
MENSAJE_ORDEN_CRONOLOGICO = (
    "La hora corregida debe quedar entre la marca anterior y la siguiente de la persona -- no "
    "se puede reordenar, sólo ajustar la hora."
)
MENSAJE_SIN_PERMISO_REAPERTURA = (
    "Esta excepción ya está resuelta -- reabrirla exige el permiso excepcion_reapertura "
    "(exclusivo de TI)."
)
MENSAJE_SIN_PERMISO_CORRECCION = (
    "No tenés el permiso necesario (correccion_edicion) para esta acción."
)
MENSAJE_DIA_YA_CERRADO = (
    "Este día ya está cerrado: la corrección no se refleja en las horas. Revisa el día."
)
MENSAJE_CORRECCION_NO_REGISTRADA = "No se pudo registrar la corrección."


def _buscar_marca(db: Client, marca_id: int) -> dict | None:
    filas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, momento_dispositivo")
        .eq("id", marca_id)
        .execute()
        .data
    )
    return filas[0] if filas else None


def _excepciones_de_marca(db: Client, marca_id: int) -> list[dict]:
    return (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("estado, motivo_revision")
        .eq("marca_id", marca_id)
        .execute()
        .data
    )


def _hay_dia_cerrado_pendiente(excepciones: list[dict]) -> bool:
    """Prefijo del motivo, no igualdad: una excepción reabierta puede llevar un sufijo " — ..." (86_*.sql)."""
    return any(
        fila["estado"] == "pendiente" and (fila.get("motivo_revision") or "").startswith("dia_cerrado")
        for fila in excepciones
    )


def _linea(texto: str) -> str:
    """Para el log: una sola línea y acotado (un mensaje con saltos de línea podría falsificar entradas)."""
    return limpiar_para_log(texto)


def _validar_ventana(fecha_marca: date) -> None:
    """SCJ-PRO-10 D1-D2: sólo aplicación -- política de proceso, no integridad estructural."""
    limite = _dias_habiles_limite()
    hoy = date.today()
    festivos = _festivos_entre(fecha_marca, hoy)
    transcurridos = _dias_habiles_transcurridos(fecha_marca, hoy, festivos)
    if transcurridos > limite:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_VENTANA_VENCIDA.format(dias=limite)
        )


@router.post("", status_code=201, response_model=CorreccionOut)
def corregir_marca(
    datos: CorreccionCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """SCJ-PRO-10 A1-K2. El gate no es un Depends fijo -- ver docstring del módulo."""
    marca = _buscar_marca(db, datos.marca_id)
    if marca is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_MARCA_NO_ENCONTRADA)

    excepciones = _excepciones_de_marca(db, datos.marca_id)
    estados = [fila["estado"] for fila in excepciones]
    if not estados:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MARCA_SIN_EXCEPCION)

    hay_pendiente = "pendiente" in estados
    persona_id = resolver_persona_id(db, caller)

    # correccion_edicion es SIEMPRE necesario; excepcion_reapertura se exige ADEMÁS cuando se
    # reabre una excepción ya resuelta -- AND, no OR (confirmado por db: así quedó la RLS real de
    # INSERT en tiempo.correccion, 48/49_*.sql).
    if not tiene_permiso(db, persona_id, "correccion_edicion"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO_CORRECCION)
    if not hay_pendiente and not tiene_permiso(db, persona_id, "excepcion_reapertura"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO_REAPERTURA)

    # Marca tardía de un día cerrado: no se corrige ni se resuelve a mano (86_*.sql). La base lo rechaza
    # con SCJ15 al COMMIT (constraint trigger diferido); este chequeo evita depender de ese camino en el
    # caso común y da el mismo mensaje.
    if _hay_dia_cerrado_pendiente(excepciones):
        raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_DIA_CERRADO_REQUIERE_REVISION)

    # Una marca que ya forma parte de un tramo no se corrige desde aquí (ensayo de db): en un tramo
    # CERRADO o de un día cerrado/revisado el UPDATE del tramo afecta 0 filas por RLS y la hora no se
    # refleja; en un tramo ABIERTO falla con 42501 (WITH CHECK) y se rechazaría la corrección entera. Se
    # corta antes de insertar, con un mensaje claro y no como un 403 engañoso.
    bloqueo = bloqueo_por_tramo(db_servicio, [datos.marca_id]).get(datos.marca_id)
    if bloqueo == EN_TRAMO:
        raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_MARCA_EN_TRAMO)
    if bloqueo is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_DIA_YA_CERRADO)

    fecha_marca = datetime.fromisoformat(marca["momento_dispositivo"]).date()
    _validar_ventana(fecha_marca)

    try:
        fila = (
            db.postgrest.schema("tiempo")
            .table("correccion")
            .insert(
                {
                    "marca_id": datos.marca_id,
                    "valor_corregido": datos.valor_corregido.isoformat(),
                    "motivo": datos.motivo,
                    "autor_id": persona_id,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        # SCJ15 (86_*.sql): una corrección sobre una marca con excepción dia_cerrado pendiente falla
        # AL COMMIT (constraint trigger diferido) y llega aquí como cualquier otro error de la petición.
        traduccion = traducir_error_dia_cerrado(error)
        if traduccion is not None:
            raise traduccion from error
        mensaje_crudo = error.message or ""
        if "rompería el orden cronológico" in mensaje_crudo:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ORDEN_CRONOLOGICO
            ) from error
        if "no tiene ninguna excepcion asociada" in mensaje_crudo:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MARCA_SIN_EXCEPCION
            ) from error
        # Código desconocido: mensaje FIJO (el texto de la base puede traer ids internos). El detalle
        # va al log del servidor. Si un error diferido (p. ej. SCJ15 al COMMIT) llegara con otro código,
        # el comportamiento sigue siendo seguro.
        logger.error(
            "corrección rechazada por la base: código=%s hint=%s mensaje=%s",
            error.code,
            _linea(str(error.hint or "")),
            _linea(mensaje_crudo),
        )
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_CORRECCION_NO_REGISTRADA
        ) from None

    return fila
