"""API de tiempo.excepcion (sólo lectura) -- cola de excepciones que alimenta el formulario de
corrección de marca (SCJ-PRO-10) y, a futuro, cualquier otro flujo que resuelva una excepcion.
Nadie edita tiempo.excepcion a mano: los triggers de corrección/ausencia (SCJ-PRO-10/08) son los
únicos que la cierran -- este router sólo expone GETs.

Resuelve del lado del servidor los datos de la marca asociada (persona_nombre,
momento_dispositivo) para que el cliente no tenga que cruzar tiempo.excepcion -> tiempo.marca ->
personas.persona él mismo -- las tres tablas no comparten esquema salvo por persona_id
(SCJ-FRO-01), PostgREST no las embebe en una sola llamada.

Gate: get_caller_client (RLS) + requiere_permiso("excepcion_lectura", "excepcion_edicion") --
lectura-o-edición, mismo patrón de siempre (RH/Gerente General sólo tienen excepcion_edicion,
sin esto quedarían afuera)."""

import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from pydantic import ValidationError
from supabase import Client

from app.deps import get_caller_client
from app.errores import UNIQUE_VIOLATION, manejar_error_dia_cerrado
from app.fecha_local import a_datetime, fecha_local_efectiva
from app.permisos import requiere_permiso
from app.schemas.excepciones import DescartarExcepcionIn, DescartarExcepcionOut, ExcepcionOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/excepciones", tags=["excepciones"])

MENSAJE_EXCEPCION_NO_ENCONTRADA = "La excepción no existe."
MENSAJE_RESPUESTA_INESPERADA = "Servicio no disponible; reintenta."
MENSAJE_YA_DESCARTADA = "La excepción ya fue descartada antes."

# Prefijo del motivo de una excepción de marca sobre un día cerrado. Puede llevar un sufijo " — ..." (una
# excepción ya resuelta y reabierta, o descartada), por eso se compara por prefijo, no por igualdad (86_*.sql).
PREFIJO_DIA_CERRADO = "dia_cerrado"


def _resolver_detalle_marca(db: Client, filas_excepcion: list[dict]) -> dict[int, dict]:
    """Sólo las excepciones con marca_id (las de dia_id -- cierre de día, Fase 4 -- no tienen
    marca que resolver). Devuelve {marca_id: {persona_id, persona_nombre, momento_dispositivo}}.
    """
    marca_ids = sorted(
        {fila["marca_id"] for fila in filas_excepcion if fila["marca_id"] is not None}
    )
    if not marca_ids:
        return {}

    marcas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, persona_id, momento_dispositivo, desfase_local")
        .in_("id", marca_ids)
        .execute()
        .data
    )

    persona_ids = sorted({marca["persona_id"] for marca in marcas})
    personas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", persona_ids)
        .execute()
        .data
        if persona_ids
        else []
    )
    nombre_por_persona = {
        persona["id"]: f"{persona['primer_nombre']} {persona['apellido_paterno']}"
        for persona in personas
    }

    return {
        marca["id"]: {
            "persona_id": marca["persona_id"],
            "persona_nombre": nombre_por_persona.get(marca["persona_id"]),
            "momento_dispositivo": marca["momento_dispositivo"],
            "desfase_local": marca.get("desfase_local"),
        }
        for marca in marcas
    }


def _es_dia_cerrado(fila: dict) -> bool:
    return fila.get("marca_id") is not None and (fila.get("motivo_revision") or "").startswith(
        PREFIJO_DIA_CERRADO
    )


def _resolver_dias_de_marcas(
    db: Client, filas_excepcion: list[dict], detalle_por_marca: dict[int, dict]
) -> dict[int, dict]:
    """Para las excepciones dia_cerrado de marca: {marca_id: {dia_id, estado}} del día al que
    pertenece cada marca (fecha local EFECTIVA, mismo criterio que fn_marca_fecha_local, 86_*.sql).
    Sólo consulta si hay alguna dia_cerrado (el resto de la cola no paga estas consultas)."""
    marca_ids = sorted({f["marca_id"] for f in filas_excepcion if _es_dia_cerrado(f)})
    if not marca_ids:
        return {}

    correcciones = (
        db.postgrest.schema("tiempo")
        .table("correccion")
        .select("marca_id, valor_corregido, creado_en")
        .in_("marca_id", marca_ids)
        .order("creado_en", desc=True)
        .execute()
        .data
    )
    efectivo: dict[int, str] = {}
    for fila in correcciones:
        efectivo.setdefault(fila["marca_id"], fila["valor_corregido"])

    fecha_por_marca: dict[int, tuple[str, object]] = {}
    for marca_id in marca_ids:
        detalle = detalle_por_marca.get(marca_id)
        if not detalle or not detalle.get("desfase_local"):
            continue
        momento = efectivo.get(marca_id, detalle["momento_dispositivo"])
        fecha_por_marca[marca_id] = (
            detalle["persona_id"],
            fecha_local_efectiva(momento, detalle["desfase_local"]),
        )
    if not fecha_por_marca:
        return {}

    personas = sorted({persona for persona, _ in fecha_por_marca.values()})
    # Fechas EXACTAS (no el rango min..max): con un rango, personas × días intermedios crecería sin
    # control y el max-rows de PostgREST truncaría en silencio dejando camino_resolucion en None.
    fechas = [fecha for _, fecha in fecha_por_marca.values()]
    dias = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .select("id, persona_id, fecha, estado")
        .in_("persona_id", personas)
        .in_("fecha", sorted({fecha.isoformat() for fecha in fechas}))
        .execute()
        .data
    )
    dia_por_clave = {(d["persona_id"], d["fecha"]): d for d in dias}
    resultado = {}
    for marca_id, (persona, fecha) in fecha_por_marca.items():
        dia = dia_por_clave.get((persona, fecha.isoformat()))
        if dia:
            resultado[marca_id] = {"dia_id": dia["id"], "estado": dia["estado"]}
    return resultado


def _camino_resolucion(fila: dict, dia_estado: str | None) -> str | None:
    """Qué resuelve una dia_cerrado PENDIENTE: revisar el día (bloqueado/cerrado) o descartar la marca
    (día ya revisado). Sin acción si ya no está pendiente o el día no admite ninguna."""
    if not _es_dia_cerrado(fila) or fila["estado"] != "pendiente":
        return None
    if dia_estado == "revisado":
        return "descartar"
    if dia_estado in ("bloqueado", "cerrado"):
        return "revisar_dia"
    return None


def _armar_filas(db: Client, filas_excepcion: list[dict]) -> list[dict]:
    detalle_por_marca = _resolver_detalle_marca(db, filas_excepcion)
    dia_por_marca = _resolver_dias_de_marcas(db, filas_excepcion, detalle_por_marca)
    resultado = []
    for fila in filas_excepcion:
        dia = dia_por_marca.get(fila["marca_id"], {})
        resultado.append(
            {
                **fila,
                "persona_id": detalle_por_marca.get(fila["marca_id"], {}).get("persona_id"),
                "persona_nombre": detalle_por_marca.get(fila["marca_id"], {}).get("persona_nombre"),
                "momento_dispositivo": detalle_por_marca.get(fila["marca_id"], {}).get(
                    "momento_dispositivo"
                ),
                "es_dia_cerrado": _es_dia_cerrado(fila),
                "dia_de_la_marca_id": dia.get("dia_id"),
                "dia_de_la_marca_estado": dia.get("estado"),
                "camino_resolucion": _camino_resolucion(fila, dia.get("estado")),
            }
        )
    return resultado


@router.get("", response_model=list[ExcepcionOut])
def listar_excepciones_pendientes(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("excepcion_lectura", "excepcion_edicion")),
    tipo: Literal["dia_cerrado"] | None = Query(
        None,
        description="dia_cerrado: sólo las marcas tardías de días cerrados (con el estado del día y "
        "el camino que las resuelve: revisar el día o descartar la marca).",
    ),
) -> list[dict]:
    consulta = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("id, marca_id, dia_id, motivo_revision, estado, creado_en")
        .eq("estado", "pendiente")
    )
    if tipo == "dia_cerrado":
        # SIN escapar el `_`: como comodín de LIKE es inofensivo (ningún motivo difiere en ese carácter) y
        # no se depende de cómo PostgREST traduce un backslash. El filtro exacto es el startswith de abajo
        # (prefijo, no igualdad: puede llevar un sufijo " — ..."). El SQL de 86_ sí usa el escape correcto.
        consulta = consulta.like("motivo_revision", f"{PREFIJO_DIA_CERRADO}%")
    filas = consulta.order("creado_en").execute().data
    if tipo == "dia_cerrado":
        filas = [fila for fila in filas if _es_dia_cerrado(fila)]
    return _armar_filas(db, filas)


@router.get("/{excepcion_id}", response_model=ExcepcionOut)
def obtener_excepcion(
    excepcion_id: int,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("excepcion_lectura", "excepcion_edicion")),
) -> dict:
    """Sin filtro de estado -- reabrir una excepcion 'resuelto' (SCJ-PRO-10 §II.3) también
    necesita precargar el formulario con el valor original de la marca."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("id, marca_id, dia_id, motivo_revision, estado, creado_en")
        .eq("id", excepcion_id)
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_EXCEPCION_NO_ENCONTRADA)
    return _armar_filas(db, filas)[0]


@router.post("/{excepcion_id}/descartar", response_model=DescartarExcepcionOut)
def descartar_excepcion_dia_cerrado(
    excepcion_id: int,
    datos: DescartarExcepcionIn,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("excepcion_dia_cerrado_descarte")),
) -> dict:
    """Descarta una marca tardía sobre un día YA revisado (86_*.sql, decisión de producto 2026-10-07).

    Se llama con el cliente del CALLER (anon key + su JWT), NUNCA con service_role: el RPC
    `fn_excepcion_dia_cerrado_descartar` es SECURITY DEFINER con EXECUTE sólo para `authenticated`, y
    su gate vive DENTRO (persona activa + permiso de acción `excepcion_dia_cerrado_descarte`, no
    heredable); el actor se deriva de auth.uid(), que con service_role no existe. El
    `requiere_permiso` de arriba es sólo un gate débil para dar un 403 legible: la autorización real
    es la base.

    Resultado del RPC -> HTTP: descartada | ya_descartada (idempotente) -> 200; no_encontrada -> 404.
    Los errores se traducen con mensajes fijos (409 día no revisado / no descartable, 422 motivo
    inválido, 403 sin permiso); el texto de la base nunca llega a la respuesta."""
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_excepcion_dia_cerrado_descartar",
                {"p_excepcion_id": excepcion_id, "p_motivo": datos.motivo},
            )
            .execute()
            .data
        )
    except APIError as error:
        if error.code == UNIQUE_VIOLATION:
            # Defensa: si la tabla de auditoría rechazara por unicidad (db ya quitó el UNIQUE en 86_)
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_YA_DESCARTADA) from None
        manejar_error_dia_cerrado(error)

    if isinstance(resultado, dict) and resultado.get("resultado") == "no_encontrada":
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_EXCEPCION_NO_ENCONTRADA)

    try:
        return DescartarExcepcionOut(
            resultado=resultado["resultado"],
            excepcion_id=resultado.get("excepcion_id", excepcion_id),
            dia_id=resultado.get("dia_id"),
        ).model_dump()
    except (ValidationError, KeyError, TypeError, AttributeError):
        logger.error("fn_excepcion_dia_cerrado_descartar devolvió una forma inesperada")
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA
        ) from None
