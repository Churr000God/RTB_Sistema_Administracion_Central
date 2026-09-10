"""API de tiempo.tramo (pantalla de sólo lectura, `/tiempo/tramos`). El par de marcas que
produce el batch de cierre de día (SCJ-PRO-12) -- hasta ahora sólo se leía desde adentro del
sistema (batches/corte_quincenal.py, routers/tope_legal.py). No hay alta/edición: no existe
tramo_edicion en el catálogo a propósito, el sistema los calcula (db/ddl/54_*.sql).

Gate: get_service_client para el dato + requiere_permiso("tramo_lectura") -- mismo patrón que
tope_legal.py, que ya lee tiempo.tramo así.

tiempo.tramo no tiene persona_id ni fecha -- cuelga de dia_id. dia:dia_id!inner(...) es un embed
forward dentro del mismo esquema tiempo (a diferencia de personas.persona, que exige una segunda
consulta batch por la frontera SCJ-FRO-01). El filtro sobre columna embebida
(.in_("dia.persona_id", ...), .gte/.lte("dia.fecha", ...)) se verificó en vivo contra el
proyecto Supabase real antes de escribir este router -- funciona con !inner."""

from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Query
from supabase import Client

from app.deps import get_service_client
from app.permisos import requiere_permiso
from app.schemas.tramos import TramoListaOut

router = APIRouter(prefix="/api/tramos", tags=["tramos"])

LIMITE_DEFECTO = 50
LIMITE_MAXIMO = 200

SELECT_CON_DIA = "id, inicio, fin, minutos_trabajados, dia:dia_id!inner(fecha, persona_id, estado)"

ORDEN_A_COLUMNA: dict[str, tuple[str, bool]] = {
    "inicio_desc": ("inicio", True),
    "inicio_asc": ("inicio", False),
    "minutos_desc": ("minutos_trabajados", True),
    "minutos_asc": ("minutos_trabajados", False),
}


def _aplanar_fila(fila: dict) -> dict:
    """Sube dia.fecha -> fecha, dia.persona_id -> persona_id y dia.estado -> dia_estado (mismo
    criterio que asignaciones.py::_aplanar_fila)."""
    dia = fila.pop("dia")
    return {
        **fila,
        "fecha": dia["fecha"],
        "persona_id": dia["persona_id"],
        "dia_estado": dia["estado"],
    }


def _resolver_ids_por_busqueda(db: Client, busqueda: str) -> list[str]:
    """Texto libre sobre primer_nombre/apellido_paterno/apellido_materno -- misma resolución que
    el resto de las pantallas con buscador de persona."""
    filtro = f"primer_nombre.ilike.%{busqueda}%,apellido_paterno.ilike.%{busqueda}%,apellido_materno.ilike.%{busqueda}%"
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id")
        .or_(filtro)
        .execute()
        .data
    )
    return [fila["id"] for fila in filas]


def _resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
    """Mismo patrón que marcas.py::_resolver_nombres_persona -- tiempo.tramo (vía tiempo.dia)
    sólo tiene persona_id (SCJ-FRO-01), el nombre vive en personas.persona."""
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", persona_ids)
        .execute()
        .data
    )
    return {fila["id"]: f"{fila['primer_nombre']} {fila['apellido_paterno']}" for fila in filas}


def _resolver_tipos_por_tramo(db: Client, tramo_ids: list[int]) -> dict[int, str]:
    """tramo_id es UNIQUE en tiempo.clasificacion_de_tiempo (uq_clasificacion_de_tiempo_tramo) --
    1:1, no hace falta acumular en lista. El batch de corte quincenal (SCJ-PRO-13) es lo que la
    calcula, no un trigger -- un tramo puede no tener fila todavía (tipo=None), típicamente el
    tramo "en curso" (nunca se clasifica hasta que cierra)."""
    if not tramo_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("clasificacion_de_tiempo")
        .select("tramo_id, tipo")
        .in_("tramo_id", tramo_ids)
        .execute()
        .data
    )
    return {fila["tramo_id"]: fila["tipo"] for fila in filas}


@router.get("", response_model=TramoListaOut)
def listar_tramos(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("tramo_lectura")),
    busqueda_persona: str | None = Query(None, description="Texto libre sobre el nombre."),
    desde: date | None = Query(None, description="dia.fecha >= desde."),
    hasta: date | None = Query(None, description="dia.fecha <= hasta."),
    orden: Literal["inicio_desc", "inicio_asc", "minutos_desc", "minutos_asc"] = Query("inicio_desc"),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """No se puede ordenar por nombre de persona server-side (cruza esquema, SCJ-FRO-01) -- las
    4 opciones de orden son todas columnas propias de tramo."""
    persona_ids: list[str] | None = None
    if busqueda_persona is not None:
        persona_ids = _resolver_ids_por_busqueda(db_servicio, busqueda_persona)
        if not persona_ids:
            return {"total": 0, "tramos": []}

    consulta = (
        db_servicio.postgrest.schema("tiempo")
        .table("tramo")
        .select(SELECT_CON_DIA, count="exact")
    )
    if persona_ids is not None:
        consulta = consulta.in_("dia.persona_id", persona_ids)
    if desde is not None:
        consulta = consulta.gte("dia.fecha", desde.isoformat())
    if hasta is not None:
        consulta = consulta.lte("dia.fecha", hasta.isoformat())

    columna, descendente = ORDEN_A_COLUMNA[orden]
    resultado = (
        consulta.order(columna, desc=descendente)
        .range(desplazamiento, desplazamiento + limite - 1)
        .execute()
    )

    filas = [_aplanar_fila(fila) for fila in resultado.data]
    nombres = _resolver_nombres_persona(
        db_servicio, sorted({fila["persona_id"] for fila in filas})
    )
    tipos = _resolver_tipos_por_tramo(db_servicio, sorted({fila["id"] for fila in filas}))
    tramos = [
        {
            **fila,
            "persona_nombre": nombres.get(fila["persona_id"]),
            "tipo": tipos.get(fila["id"]),
        }
        for fila in filas
    ]
    return {"total": resultado.count, "tramos": tramos}
