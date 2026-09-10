"""API del catálogo personas.departamento (SCJ-PRO-03 alta/renombrado, SCJ-PRO-06
desactivar/reactivar). Calcado de app/routers/areas.py -- mismo gate, misma forma de PATCH.

Gate de permisos: get_caller_client (RLS) + requiere_permiso(...) (app/permisos.py) --
lectura exige departamento_lectura o departamento_edicion; alta/renombrado/estado exigen
departamento_edicion.

reasignar el area_id de un departamento existente está fuera de alcance (decisión tomada con
el usuario) -- DepartamentoRename no acepta area_id, sólo AreaCreate lo tiene, y sólo en el
alta.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.departamentos import (
    DepartamentoCreate,
    DepartamentoEstado,
    DepartamentoOut,
    DepartamentoRename,
)

router = APIRouter(prefix="/api/departamentos", tags=["departamentos"])

MENSAJE_DEPARTAMENTO_DUPLICADO = "Ya existe un departamento con ese nombre."
MENSAJE_DEPARTAMENTO_NO_ENCONTRADO = "Departamento no encontrado."
MENSAJE_AREA_INVALIDA = "El área no existe o está inactiva."
MENSAJE_TIENE_PUESTOS_ACTIVOS = "No se puede desactivar: tiene puestos activos."
MENSAJE_REACTIVACION_INVALIDA = "No se puede reactivar: el área no está activa."


@router.get("", response_model=list[DepartamentoOut])
def listar_departamentos(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("departamento_lectura", "departamento_edicion")),
) -> list[dict]:
    return (
        db.postgrest.schema("personas")
        .table("departamento")
        .select("*")
        .order("nombre_departamento")
        .execute()
        .data
    )


@router.post("", status_code=201, response_model=DepartamentoOut)
def alta_departamento(
    datos: DepartamentoCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("departamento_edicion")),
) -> dict:
    """SCJ-PRO-03 D0-D3. area_id se valida antes del insert: departamento no tiene padre en
    area (a diferencia de area, que no tiene padre alguno), así que acá sí hace falta chequear
    que el area exista y esté activa -- si no, el error de FK de Postgres sería menos legible
    que este 422."""
    area = (
        db.postgrest.schema("personas")
        .table("area")
        .select("id, activo")
        .eq("id", datos.area_id)
        .execute()
        .data
    )
    if not area or not area[0]["activo"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_AREA_INVALIDA)

    try:
        return (
            db.postgrest.schema("personas")
            .table("departamento")
            .insert({"area_id": datos.area_id, "nombre_departamento": datos.nombre_departamento})
            .execute()
            .data[0]
        )
    except APIError as error:
        manejar_violacion_unicidad(error, MENSAJE_DEPARTAMENTO_DUPLICADO)


@router.get("/{departamento_id}", response_model=DepartamentoOut)
def obtener_departamento(
    departamento_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("departamento_lectura", "departamento_edicion")),
) -> dict:
    fila = (
        db.postgrest.schema("personas")
        .table("departamento")
        .select("*")
        .eq("id", departamento_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_DEPARTAMENTO_NO_ENCONTRADO)
    return fila[0]


@router.patch("/{departamento_id}", response_model=DepartamentoOut)
def renombrar_departamento(
    departamento_id: str,
    datos: DepartamentoRename,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("departamento_edicion")),
) -> dict:
    """SCJ-PRO-03 D1: renombrar departamento existente. Mismo 409 en duplicado que el alta."""
    try:
        fila = (
            db.postgrest.schema("personas")
            .table("departamento")
            .update(
                {
                    "nombre_departamento": datos.nombre_departamento,
                    "actualizado_en": datetime.now(timezone.utc).isoformat(),
                }
            )
            .eq("id", departamento_id)
            .execute()
            .data
        )
    except APIError as error:
        manejar_violacion_unicidad(error, MENSAJE_DEPARTAMENTO_DUPLICADO)
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_DEPARTAMENTO_NO_ENCONTRADO)
    return fila[0]


@router.patch("/{departamento_id}/estado", response_model=DepartamentoOut)
def cambiar_estado_departamento(
    departamento_id: str,
    datos: DepartamentoEstado,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("departamento_edicion")),
) -> dict:
    """SCJ-PRO-06 DD1 (desactivar) / RD1 (reactivar)."""
    departamento_actual = (
        db.postgrest.schema("personas")
        .table("departamento")
        .select("area_id")
        .eq("id", departamento_id)
        .execute()
        .data
    )
    if not departamento_actual:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_DEPARTAMENTO_NO_ENCONTRADO)

    if not datos.activo:
        puestos_activos = (
            db.postgrest.schema("personas")
            .table("puesto")
            .select("id")
            .eq("departamento_id", departamento_id)
            .eq("activo", True)
            .execute()
            .data
        )
        if puestos_activos:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TIENE_PUESTOS_ACTIVOS)
    else:
        area_id = departamento_actual[0]["area_id"]
        area = (
            db.postgrest.schema("personas")
            .table("area")
            .select("activo")
            .eq("id", area_id)
            .execute()
            .data
        )
        if not area or not area[0]["activo"]:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_REACTIVACION_INVALIDA)

    fila = (
        db.postgrest.schema("personas")
        .table("departamento")
        .update(
            {
                "activo": datos.activo,
                "actualizado_en": datetime.now(timezone.utc).isoformat(),
            }
        )
        .eq("id", departamento_id)
        .execute()
        .data
    )
    return fila[0]
