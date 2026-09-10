"""API del catálogo personas.area (SCJ-PRO-03 alta/renombrado, SCJ-PRO-06 desactivar/reactivar).

Gate de permisos: get_caller_client (RLS) + requiere_permiso(...) (app/permisos.py) --
lectura exige area_lectura o area_edicion; alta/renombrado/estado exigen area_edicion.

PATCH /{area_id} y PATCH /{area_id}/estado son los primeros PATCH del proyecto (no había
ningún PUT/PATCH previo en backend/app/routers/ para copiar 1:1). Forma elegida: cuerpo con
sólo el/los campos que cambian (AreaRename, AreaEstado), actualizado_en seteado explícito en
Python (mismo patrón que fecha_nacimiento/fecha_ingreso en personas.py: .isoformat(), no
depender de trigger -- el proyecto no tiene ningún trigger genérico de auto-refresco).
departamento y puesto deberían replicar esta forma cuando se construyan.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.areas import AreaCreate, AreaEstado, AreaOut, AreaRename

router = APIRouter(prefix="/api/areas", tags=["areas"])

MENSAJE_AREA_DUPLICADA = "Ya existe un área con ese nombre."
MENSAJE_AREA_NO_ENCONTRADA = "Área no encontrada."
MENSAJE_TIENE_DEPARTAMENTOS_ACTIVOS = (
    "No se puede desactivar: tiene departamentos activos."
)


@router.get("", response_model=list[AreaOut])
def listar_areas(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("area_lectura", "area_edicion")),
) -> list[dict]:
    return (
        db.postgrest.schema("personas")
        .table("area")
        .select("*")
        .order("nombre_area")
        .execute()
        .data
    )


@router.post("", status_code=201, response_model=AreaOut)
def alta_area(
    datos: AreaCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("area_edicion")),
) -> dict:
    """SCJ-PRO-03 A0-A3. uq_area_nombre y ux_area_nombre_insensible (10_personas_area.sql) son
    la garantía real de unicidad -- este try/except sólo traduce la violación a un 409 legible."""
    try:
        return (
            db.postgrest.schema("personas")
            .table("area")
            .insert({"nombre_area": datos.nombre_area})
            .execute()
            .data[0]
        )
    except APIError as error:
        manejar_violacion_unicidad(error, MENSAJE_AREA_DUPLICADA)


@router.get("/{area_id}", response_model=AreaOut)
def obtener_area(
    area_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("area_lectura", "area_edicion")),
) -> dict:
    fila = (
        db.postgrest.schema("personas")
        .table("area")
        .select("*")
        .eq("id", area_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_AREA_NO_ENCONTRADA)
    return fila[0]


@router.patch("/{area_id}", response_model=AreaOut)
def renombrar_area(
    area_id: str,
    datos: AreaRename,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("area_edicion")),
) -> dict:
    """SCJ-PRO-03 A1: renombrar área existente. Mismo 409 en duplicado que el alta."""
    try:
        fila = (
            db.postgrest.schema("personas")
            .table("area")
            .update(
                {
                    "nombre_area": datos.nombre_area,
                    "actualizado_en": datetime.now(timezone.utc).isoformat(),
                }
            )
            .eq("id", area_id)
            .execute()
            .data
        )
    except APIError as error:
        manejar_violacion_unicidad(error, MENSAJE_AREA_DUPLICADA)
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_AREA_NO_ENCONTRADA)
    return fila[0]


@router.patch("/{area_id}/estado", response_model=AreaOut)
def cambiar_estado_area(
    area_id: str,
    datos: AreaEstado,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("area_edicion")),
) -> dict:
    """SCJ-PRO-06 DA1 (desactivar) / RA1 (reactivar)."""
    if not datos.activo:
        departamentos_activos = (
            db.postgrest.schema("personas")
            .table("departamento")
            .select("id")
            .eq("area_id", area_id)
            .eq("activo", True)
            .execute()
            .data
        )
        if departamentos_activos:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TIENE_DEPARTAMENTOS_ACTIVOS
            )

    fila = (
        db.postgrest.schema("personas")
        .table("area")
        .update(
            {
                "activo": datos.activo,
                "actualizado_en": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", area_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_AREA_NO_ENCONTRADA)
    return fila[0]
