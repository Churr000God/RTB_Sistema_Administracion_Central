"""API del catálogo personas.puesto (SCJ-PRO-03 alta, SCJ-PRO-06 desactivar/reactivar).
Calcado de app/routers/departamentos.py -- mismo gate, misma forma de PATCH.

Gate de permisos: get_caller_client (RLS) + requiere_permiso(...) (app/permisos.py) --
lectura exige puesto_lectura o puesto_edicion; alta/renombrado/estado exigen puesto_edicion.

reasignar departamento_id o reporta_a_id de un puesto existente está fuera de alcance
(decisión tomada con el usuario) -- PuestoUpdate no acepta ninguno de los dos.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso
from app.schemas.puestos import PuestoCreate, PuestoEstado, PuestoOut, PuestoUpdate

router = APIRouter(prefix="/api/puestos", tags=["puestos"])

MENSAJE_PUESTO_NO_ENCONTRADO = "Puesto no encontrado."
MENSAJE_DEPARTAMENTO_INVALIDO = "El departamento no existe o está inactivo."
MENSAJE_SUPERIOR_INVALIDO = "El puesto superior no existe."
MENSAJE_TIENE_ASIGNACION_VIGENTE = "No se puede desactivar: tiene una asignación vigente."
MENSAJE_TIENE_PERMISOS_ACTIVOS = "No se puede desactivar: tiene permisos activos otorgados."
MENSAJE_TIENE_SUBORDINADOS = "No se puede desactivar: tiene puestos subordinados activos."
MENSAJE_REACTIVACION_INVALIDA = (
    "No se puede reactivar: el departamento o el puesto superior no están activos."
)
MENSAJE_ADMINISTRADOR_SIN_ACCESO = (
    "No se puede desactivar: dejaría al puesto administrador sin acceso."
)


@router.get("", response_model=list[PuestoOut])
def listar_puestos(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("puesto_lectura", "puesto_edicion")),
) -> list[dict]:
    return (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("*")
        .order("nombre_puesto")
        .execute()
        .data
    )


@router.post("", status_code=201, response_model=PuestoOut)
def alta_puesto(
    datos: PuestoCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("puesto_edicion")),
) -> dict:
    """SCJ-PRO-03 P0-P7. Se valida departamento_id y reporta_a_id antes del insert -- mismo
    criterio que departamento validando area_id: el error de FK de Postgres sería menos legible
    que estos 422. Sin chequeo de auto-referencia/ciclo: reporta_a_id siempre apunta a un
    puesto YA existente (nunca puede ser el que se está creando), es matemáticamente imposible
    en el alta -- el CHECK de DB y el índice del tope son la única defensa y no deberían
    dispararse nunca desde acá."""
    departamento = (
        db.postgrest.schema("personas")
        .table("departamento")
        .select("id, activo")
        .eq("id", datos.departamento_id)
        .execute()
        .data
    )
    if not departamento or not departamento[0]["activo"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DEPARTAMENTO_INVALIDO)

    superior = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("id")
        .eq("id", datos.reporta_a_id)
        .execute()
        .data
    )
    if not superior:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_SUPERIOR_INVALIDO)

    return (
        db.postgrest.schema("personas")
        .table("puesto")
        .insert(
            {
                "departamento_id": datos.departamento_id,
                "nombre_puesto": datos.nombre_puesto,
                "nivel": datos.nivel,
                "plazas_totales": datos.plazas_totales,
                "reporta_a_id": datos.reporta_a_id,
            }
        )
        .execute()
        .data[0]
    )


@router.get("/{puesto_id}", response_model=PuestoOut)
def obtener_puesto(
    puesto_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("puesto_lectura", "puesto_edicion")),
) -> dict:
    fila = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("*")
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PUESTO_NO_ENCONTRADO)
    return fila[0]


@router.patch("/{puesto_id}", response_model=PuestoOut)
def actualizar_puesto(
    puesto_id: str,
    datos: PuestoUpdate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("puesto_edicion")),
) -> dict:
    """SCJ-PRO-03: renombrar/cambiar nivel/plazas. Sin 409: nombre_puesto no tiene UNIQUE."""
    fila = (
        db.postgrest.schema("personas")
        .table("puesto")
        .update(
            {
                "nombre_puesto": datos.nombre_puesto,
                "nivel": datos.nivel,
                "plazas_totales": datos.plazas_totales,
                "actualizado_en": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PUESTO_NO_ENCONTRADO)
    return fila[0]


@router.patch("/{puesto_id}/estado", response_model=PuestoOut)
def cambiar_estado_puesto(
    puesto_id: str,
    datos: PuestoEstado,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("puesto_edicion")),
) -> dict:
    """SCJ-PRO-06 DP1/DP3/DP4 (desactivar) / RP1 (reactivar)."""
    puesto_actual = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("departamento_id, reporta_a_id, es_administrador_generico")
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if not puesto_actual:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PUESTO_NO_ENCONTRADO)

    if not datos.activo:
        # Chequeo espejo (UX) de db/ddl/32_puesto_administrador_generico_proteccion.sql bloque 6
        # -- va ANTES de DP1/DP3 porque es más específico (identifica el puesto directamente, sin
        # necesidad de consultar asignacion/puesto_permiso). La RLS real es la que efectivamente
        # lo impide.
        if puesto_actual[0]["es_administrador_generico"]:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ADMINISTRADOR_SIN_ACCESO)

        asignacion_vigente = (
            db.postgrest.schema("personas")
            .table("asignacion")
            .select("id")
            .eq("puesto_id", puesto_id)
            .is_("vigente_hasta", "null")
            .execute()
            .data
        )
        if asignacion_vigente:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TIENE_ASIGNACION_VIGENTE
            )

        permisos_activos = (
            db.postgrest.schema("personas")
            .table("puesto_permiso")
            .select("id")
            .eq("puesto_id", puesto_id)
            .eq("activo", True)
            .execute()
            .data
        )
        if permisos_activos:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TIENE_PERMISOS_ACTIVOS)

        subordinados_activos = (
            db.postgrest.schema("personas")
            .table("puesto")
            .select("id")
            .eq("reporta_a_id", puesto_id)
            .eq("activo", True)
            .execute()
            .data
        )
        if subordinados_activos:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TIENE_SUBORDINADOS)
    else:
        departamento_id = puesto_actual[0]["departamento_id"]
        reporta_a_id = puesto_actual[0]["reporta_a_id"]

        departamento = (
            db.postgrest.schema("personas")
            .table("departamento")
            .select("activo")
            .eq("id", departamento_id)
            .execute()
            .data
        )
        departamento_activo = bool(departamento and departamento[0]["activo"])

        superior_activo = True
        if reporta_a_id is not None:
            superior = (
                db.postgrest.schema("personas")
                .table("puesto")
                .select("activo")
                .eq("id", reporta_a_id)
                .execute()
                .data
            )
            superior_activo = bool(superior and superior[0]["activo"])

        if not departamento_activo or not superior_activo:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_REACTIVACION_INVALIDA)

    fila = (
        db.postgrest.schema("personas")
        .table("puesto")
        .update(
            {
                "activo": datos.activo,
                "actualizado_en": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", puesto_id)
        .execute()
        .data
    )
    return fila[0]
