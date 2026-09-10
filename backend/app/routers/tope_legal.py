"""API de tiempo.tope_legal (módulo Parámetros de Tiempo, primera pantalla). Historial +
vigencia (mismo patrón de vigencias que jornada_asignada.py: cierre+apertura vía RPC
transaccional, ERRCODE 'SCJ01' si hay una vigente sin confirmar) + reporte de cumplimiento
("¿quién se pasó del tope esta semana?").

get_service_client para TODA lectura de datos en /exceso-semanal (tope_legal, tiempo.dia,
tiempo.tramo, tiempo.clasificacion_de_tiempo, personas.persona) -- decisión de arquitectura del
orchestrator, no de este router: tiempo.dia/tiempo.tramo exigen dia_lectura/tramo_lectura por
RLS, hoy mapeados a los mismos puestos que tope_legal_lectura pero sin garantía estructural de
seguir acoplados. Con get_caller_client, un desacople futuro haría que este reporte de
cumplimiento legal devuelva "nadie se pasó" por RLS silenciosa en vez de por ser cierto -- un
reporte de cumplimiento que miente en silencio es peor que uno que nunca se hizo. Mismo patrón
que corridas_batch.py: permiso vía caller (requiere_permiso, que resuelve con get_caller_client/
get_caller_identity internamente), dato vía service_role en la misma firma de endpoint."""

from collections import defaultdict
from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_service_client
from app.permisos import requiere_permiso
from app.schemas.tope_legal import ExcesoSemanalOut, PersonaSobreTopeItem, TopeLegalCreate, TopeLegalOut

router = APIRouter(prefix="/api/tope-legal", tags=["tope-legal"])

CODIGO_VIGENCIA_ACTIVA_SIN_CONFIRMAR = "SCJ01"
LUNES = 0  # date.weekday(): lunes=0 ... domingo=6

MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR = (
    "Ya existe un tope legal vigente. Confirmá para cerrarlo y crear el nuevo."
)
MENSAJE_SEMANA_NO_ES_LUNES = "semana_de debe ser un lunes."

# Un día en cualquiera de estos dos estados hace que la semana ENTERA de esa persona se excluya
# del reporte -- ni parcial ni aproximado (mismo criterio que corte_quincenal.py: "pendiente" o
# "en curso" nunca se mezcla con datos ya cerrados en el mismo cálculo).
ESTADOS_EXCLUYEN_SEMANA = {"abierto", "bloqueado"}


@router.get("", response_model=list[TopeLegalOut])
def listar_tope_legal(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("tope_legal_lectura", "tope_legal_edicion")),
) -> list[dict]:
    return (
        db_servicio.postgrest.schema("tiempo")
        .table("tope_legal")
        .select("*")
        .order("vigente_desde", desc=True)
        .execute()
        .data
    )


@router.post("", status_code=201, response_model=TopeLegalOut)
def crear_tope_legal(
    datos: TopeLegalCreate,
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("tope_legal_edicion")),
) -> dict:
    """tiempo.fn_tope_legal_crear_vigencia -- mismo patrón que fn_jornada_asignar_renovar: cierra
    la vigencia activa (si la hay y el cliente confirmó) y crea la nueva en una sola transacción.
    Si hay vigencia activa sin confirmar, el RPC revienta con ERRCODE 'SCJ01'."""
    try:
        resultado = (
            db_servicio.postgrest.schema("tiempo")
            .rpc(
                "fn_tope_legal_crear_vigencia",
                {
                    "p_vigente_desde": datos.vigente_desde.isoformat(),
                    "p_maximo_semanal": datos.maximo_semanal,
                    "p_maximo_extra": datos.maximo_extra,
                    "p_confirma_cierre_vigente": datos.confirma_cierre_vigente,
                },
            )
            .execute()
        )
    except APIError as error:
        if error.code == CODIGO_VIGENCIA_ACTIVA_SIN_CONFIRMAR:
            raise HTTPException(
                status.HTTP_409_CONFLICT, MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR
            ) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    return resultado.data


def _resolver_tope_vigente(db: Client, semana_de_iso: str) -> dict | None:
    """Mismo query shape que _validar_tope_legal en jornada_asignada.py -- última vigencia con
    vigente_desde <= semana_de que además siga vigente en esa fecha."""
    topes = (
        db.postgrest.schema("tiempo")
        .table("tope_legal")
        .select("maximo_semanal, maximo_extra, vigente_hasta")
        .lte("vigente_desde", semana_de_iso)
        .order("vigente_desde", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not topes:
        return None
    tope = topes[0]
    if tope["vigente_hasta"] is not None and tope["vigente_hasta"] < semana_de_iso:
        return None
    return tope


def _dias_de_la_semana(db: Client, semana_desde_iso: str, semana_hasta_iso: str) -> list[dict]:
    return (
        db.postgrest.schema("tiempo")
        .table("dia")
        .select("id, persona_id, fecha, estado")
        .gte("fecha", semana_desde_iso)
        .lte("fecha", semana_hasta_iso)
        .execute()
        .data
    )


def _tramos_de_dias(db: Client, dia_ids: list[int]) -> list[dict]:
    if not dia_ids:
        return []
    return (
        db.postgrest.schema("tiempo")
        .table("tramo")
        .select("id, dia_id, minutos_trabajados")
        .in_("dia_id", dia_ids)
        .execute()
        .data
    )


def _clasificaciones_de_tramos(db: Client, tramo_ids: list[int]) -> dict[int, str]:
    """Consulta separada de tramo (no embed reverso clasificacion_de_tiempo(tipo) -- sin
    precedente en el estilo de supabase-py de este proyecto). Join en memoria por tramo_id,
    mismo criterio que corte_quincenal.py."""
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


def _resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
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


@router.get("/exceso-semanal", response_model=ExcesoSemanalOut)
def exceso_semanal(
    semana_de: date = Query(..., description="Lunes de la semana a evaluar."),
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("tope_legal_lectura", "tope_legal_edicion")),
) -> dict:
    if semana_de.weekday() != LUNES:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_SEMANA_NO_ES_LUNES)

    semana_hasta = semana_de + timedelta(days=6)
    semana_de_iso = semana_de.isoformat()
    semana_hasta_iso = semana_hasta.isoformat()

    tope = _resolver_tope_vigente(db_servicio, semana_de_iso)
    if tope is None:
        return {
            "semana_desde": semana_de,
            "semana_hasta": semana_hasta,
            "maximo_semanal": None,
            "maximo_extra": None,
            "personas": [],
        }

    dias = _dias_de_la_semana(db_servicio, semana_de_iso, semana_hasta_iso)
    dias_por_persona: dict[str, list[dict]] = defaultdict(list)
    for fila in dias:
        dias_por_persona[fila["persona_id"]].append(fila)

    # Persona sin ninguna fila tiempo.dia en la semana no entra a dias_por_persona -- no es caso
    # especial, simplemente nunca se evalúa (no aparece en el reporte).
    dia_a_persona: dict[int, str] = {}
    dia_ids_elegibles: list[int] = []
    for persona_id, filas_persona in dias_por_persona.items():
        if any(fila["estado"] in ESTADOS_EXCLUYEN_SEMANA for fila in filas_persona):
            continue  # semana completa excluida -- no parcial (ver ESTADOS_EXCLUYEN_SEMANA)
        for fila in filas_persona:
            dia_a_persona[fila["id"]] = persona_id
            dia_ids_elegibles.append(fila["id"])

    tramos = _tramos_de_dias(db_servicio, dia_ids_elegibles)
    clasificacion_por_tramo = _clasificaciones_de_tramos(db_servicio, [t["id"] for t in tramos])

    minutos_por_persona: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for tramo in tramos:
        tipo = clasificacion_por_tramo.get(tramo["id"])
        if tipo is None:
            # Corte quincenal todavía no corrió sobre este tramo -- se ignora en las 3 sumas
            # (ordinario/extra/reposición). Decisión explícita, no un olvido: sin clasificación
            # no hay forma de saber a cuál de las 3 categorías pertenece, y contarlo en cualquiera
            # de ellas inventaría un dato que la base todavía no tiene.
            continue
        persona_id = dia_a_persona[tramo["dia_id"]]
        minutos_por_persona[persona_id][tipo] += tramo["minutos_trabajados"] or 0

    maximo_semanal = tope["maximo_semanal"]
    maximo_extra = tope["maximo_extra"]

    items: list[dict] = []
    for persona_id in sorted(set(dia_a_persona.values())):
        minutos = minutos_por_persona.get(persona_id, {})
        horas_ordinarias = minutos.get("ordinario", 0) / 60.0
        horas_extra = minutos.get("extra", 0) / 60.0
        horas_reposicion = minutos.get("reposicion", 0) / 60.0

        # Reposición nunca participa en ninguna de las 3 comparaciones -- paga una deuda previa
        # del banco de horas, no es carga de trabajo nueva (SCJ-DEC-02).
        supera_semanal = horas_ordinarias > maximo_semanal
        supera_extra = horas_extra > maximo_extra
        supera_combinado = (horas_ordinarias + horas_extra) > (maximo_semanal + maximo_extra)

        if not (supera_semanal or supera_extra or supera_combinado):
            continue

        items.append(
            {
                "persona_id": persona_id,
                "horas_ordinarias": horas_ordinarias,
                "horas_extra": horas_extra,
                "horas_reposicion": horas_reposicion,
                "supera_semanal": supera_semanal,
                "supera_extra": supera_extra,
                "supera_combinado": supera_combinado,
                "exceso_semanal": (horas_ordinarias - maximo_semanal) if supera_semanal else None,
                "exceso_extra": (horas_extra - maximo_extra) if supera_extra else None,
                "exceso_combinado": (
                    (horas_ordinarias + horas_extra) - (maximo_semanal + maximo_extra)
                    if supera_combinado
                    else None
                ),
            }
        )

    nombres = _resolver_nombres_persona(db_servicio, [item["persona_id"] for item in items])
    for item in items:
        item["persona_nombre"] = nombres.get(item["persona_id"])

    return {
        "semana_desde": semana_de,
        "semana_hasta": semana_hasta,
        "maximo_semanal": maximo_semanal,
        "maximo_extra": maximo_extra,
        "personas": [PersonaSobreTopeItem(**item) for item in items],
    }
