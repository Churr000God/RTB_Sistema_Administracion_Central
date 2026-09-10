"""API de personas.asignacion (SCJ-PRO-04: alta, terminar, cambiar de puesto).

Gate de permisos: get_caller_client (RLS) + requiere_permiso(...) (app/permisos.py) --
lectura exige asignacion_lectura o asignacion_edicion; alta/terminar/cambiar-puesto exigen
asignacion_edicion.

Sin endpoint anidado /api/personas/{id}/asignaciones -- a diferencia de movimientos.py (que sí
es un sub-recurso dedicado), se reusa este mismo GET global tanto para la bitácora general como
para el historial de una persona (filtrado en cliente por el frontend).
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.asignaciones import (
    AsignacionCambiarPuesto,
    AsignacionConDetalle,
    AsignacionCreate,
    AsignacionOut,
    AsignacionTerminar,
)

router = APIRouter(prefix="/api/asignaciones", tags=["asignaciones"])

MENSAJE_ASIGNACION_NO_ENCONTRADA = "Asignación no encontrada."
MENSAJE_ASIGNACION_YA_CERRADA = "Esta asignación ya está cerrada."
MENSAJE_PERSONA_INVALIDA = "La persona no existe o no está activa."
MENSAJE_PUESTO_INVALIDO = "El puesto no existe o está inactivo."
MENSAJE_PLAZAS_LLENAS = "El puesto no tiene plazas libres."
MENSAJE_ASIGNACION_VIGENTE_DUPLICADA = "Esta persona ya tiene una asignación vigente a ese puesto."
MENSAJE_ADMINISTRADOR_SIN_ACCESO = (
    "No se puede hacer esto: dejaría al puesto administrador sin acceso."
)

SELECT_CON_DETALLE = (
    "*, persona:persona_id(primer_nombre, apellido_paterno), "
    "puesto:puesto_id(nombre_puesto, departamento:departamento_id("
    "nombre_departamento, area:area_id(nombre_area)))"
)


def _aplanar_fila(fila: dict) -> dict:
    """El embed anidado de PostgREST devuelve persona/puesto/departamento/area como objetos
    hijos -- AsignacionConDetalle es plano (mismo criterio que PersonaConExpediente aplanando
    el embed de expediente en personas.py), así que se resuelve acá antes de devolver."""
    persona = fila.pop("persona")
    puesto = fila.pop("puesto")
    departamento = puesto.pop("departamento")
    area = departamento.pop("area")
    return {
        **fila,
        "persona_nombre": f"{persona['primer_nombre']} {persona['apellido_paterno']}",
        "nombre_puesto": puesto["nombre_puesto"],
        "nombre_departamento": departamento["nombre_departamento"],
        "nombre_area": area["nombre_area"],
    }


def _validar_persona_activa(db: Client, persona_id: str) -> None:
    persona = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, estado")
        .eq("id", persona_id)
        .execute()
        .data
    )
    if not persona or persona[0]["estado"] != "activo":
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PERSONA_INVALIDA)


def _validar_puesto_con_plazas_libres(db: Client, puesto_id: str) -> None:
    puesto = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("id, activo, plazas_totales")
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if not puesto or not puesto[0]["activo"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PUESTO_INVALIDO)

    ocupadas = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select("id")
        .eq("puesto_id", puesto_id)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    if len(ocupadas) >= puesto[0]["plazas_totales"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PLAZAS_LLENAS)


def _validar_puesto_no_es_administrador_generico(db: Client, puesto_id: str) -> None:
    """Chequeo espejo (UX) de db/ddl/32_puesto_administrador_generico_proteccion.sql bloque 5 --
    la RLS real de personas.asignacion es la que efectivamente lo impide; esto sólo evita que la
    app reciba un error crudo de violación de policy en vez de un 422 legible."""
    puesto = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("es_administrador_generico")
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if puesto and puesto[0]["es_administrador_generico"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ADMINISTRADOR_SIN_ACCESO)


@router.get("", response_model=list[AsignacionConDetalle])
def listar_asignaciones(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("asignacion_lectura", "asignacion_edicion")),
) -> list[dict]:
    filas = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select(SELECT_CON_DETALLE)
        .order("vigente_desde", desc=True)
        .execute()
        .data
    )
    return [_aplanar_fila(fila) for fila in filas]


@router.get("/{asignacion_id}", response_model=AsignacionConDetalle)
def obtener_asignacion(
    asignacion_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("asignacion_lectura", "asignacion_edicion")),
) -> dict:
    filas = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select(SELECT_CON_DETALLE)
        .eq("id", asignacion_id)
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_ASIGNACION_NO_ENCONTRADA)
    return _aplanar_fila(filas[0])


@router.post("", status_code=201, response_model=AsignacionOut)
def alta_asignacion(
    datos: AsignacionCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("asignacion_edicion")),
) -> dict:
    """SCJ-PRO-04 N0-N8."""
    _validar_persona_activa(db, datos.persona_id)
    _validar_puesto_con_plazas_libres(db, datos.puesto_id)

    try:
        return (
            db.postgrest.schema("personas")
            .table("asignacion")
            .insert(
                {
                    "persona_id": datos.persona_id,
                    "puesto_id": datos.puesto_id,
                    "vigente_desde": datos.vigente_desde.isoformat(),
                    "vigente_hasta": None,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        manejar_violacion_unicidad(
            error, MENSAJE_ASIGNACION_VIGENTE_DUPLICADA, status.HTTP_422_UNPROCESSABLE_ENTITY
        )


@router.patch("/{asignacion_id}/terminar", response_model=AsignacionOut)
def terminar_asignacion(
    asignacion_id: str,
    datos: AsignacionTerminar,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("asignacion_edicion")),
) -> dict:
    """SCJ-PRO-04 T0-T1."""
    actual = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select("puesto_id, vigente_hasta")
        .eq("id", asignacion_id)
        .execute()
        .data
    )
    if not actual:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_ASIGNACION_NO_ENCONTRADA)
    if actual[0]["vigente_hasta"] is not None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ASIGNACION_YA_CERRADA)
    _validar_puesto_no_es_administrador_generico(db, actual[0]["puesto_id"])

    return (
        db.postgrest.schema("personas")
        .table("asignacion")
        .update(
            {
                "vigente_hasta": datos.vigente_hasta.isoformat(),
                "actualizado_en": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", asignacion_id)
        .execute()
        .data[0]
    )


@router.post("/{asignacion_id}/cambiar-puesto", response_model=AsignacionOut)
def cambiar_puesto_asignacion(
    asignacion_id: str,
    datos: AsignacionCambiarPuesto,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("asignacion_edicion")),
) -> dict:
    """SCJ-PRO-04 C0-C4. El puesto nuevo se valida con las mismas 3 reglas del alta ANTES de
    invocar el RPC transaccional (cierra la asignación vieja y abre una nueva). Si la
    asignación origen no existe o ya está cerrada, fn_asignacion_cambiar_puesto la rechaza con
    RAISE EXCEPTION -- postgrest-py lo propaga como APIError (mismo tipo que insert/update),
    con code = 'P0001' (SQLSTATE por omisión de PL/pgSQL, la función no fija uno propio).
    fn_asignacion_cambiar_puesto RETURNS personas.asignacion (fila única, no SETOF) --
    verificado en vivo contra Supabase: PostgREST devuelve un objeto JSON plano, no una lista
    de un elemento, así que resultado.data ya es el dict de la nueva asignación."""
    _validar_puesto_con_plazas_libres(db, datos.puesto_nuevo_id)

    origen = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select("puesto_id")
        .eq("id", asignacion_id)
        .execute()
        .data
    )
    if origen:
        _validar_puesto_no_es_administrador_generico(db, origen[0]["puesto_id"])

    try:
        resultado = (
            db.postgrest.schema("personas")
            .rpc(
                "fn_asignacion_cambiar_puesto",
                {
                    "p_asignacion_id": asignacion_id,
                    "p_puesto_nuevo_id": datos.puesto_nuevo_id,
                    "p_fecha": datos.fecha.isoformat(),
                },
            )
            .execute()
        )
    except APIError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    return resultado.data
