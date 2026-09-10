"""API de tiempo.dia_festivo (módulo Parámetros de Tiempo, segunda pantalla). Catálogo chico
(decenas de filas), consumido de sólo lectura por correcciones.py::_festivos_entre,
batches/cierre_dia.py::_es_festivo y batches/corte_quincenal.py::_festivos_del_periodo -- este
router no los toca, sólo agrega alta/baja/consulta desde la pantalla nueva.

Mismo split que tope_legal.py: get_service_client para TODA lectura/escritura de
tiempo.dia_festivo, get_caller_client (vía requiere_permiso, internamente) sólo para el gate de
permiso -- tiempo.dia_festivo tiene la misma RLS deny-all por defecto que el resto de tiempo
(41_tiempo_rls_deny_default.sql), acoplada hoy a dia_festivo_lectura/dia_festivo_edicion pero sin
garantía estructural de seguir así.

DELETE "/{festivo_id}" es el primer @router.delete de todo el proyecto -- ningún otro catálogo
del proyecto permite borrar filas (área/departamento/puesto sólo desactivan). Un día festivo sí
se puede borrar de verdad (no tiene estado activo/inactivo) pero sólo hacia adelante: borrar un
festivo pasado invalidaría en silencio cálculos ya cerrados (cierre de día, corte quincenal) que
ya lo usaron para decidir si un día contaba como esperado."""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_service_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.dias_festivos import DiaFestivoCreate, DiaFestivoOut

router = APIRouter(prefix="/api/dias-festivos", tags=["dias-festivos"])

MENSAJE_FESTIVO_DUPLICADO = "Ya existe un día festivo con esa fecha."
MENSAJE_FESTIVO_NO_ENCONTRADO = "Día festivo no encontrado."
MENSAJE_FESTIVO_NO_FUTURO = "No se puede borrar un día festivo de hoy o del pasado."


@router.get("", response_model=list[DiaFestivoOut])
def listar_dias_festivos(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("dia_festivo_lectura", "dia_festivo_edicion")),
) -> list[dict]:
    """Sin query params -- el catálogo es chico, el filtrado (por año, por rango) lo hace el
    frontend client-side sobre esta misma lista, no se duplica esa lógica acá."""
    return (
        db_servicio.postgrest.schema("tiempo")
        .table("dia_festivo")
        .select("*")
        .order("fecha", desc=True)
        .execute()
        .data
    )


@router.post("", status_code=201, response_model=DiaFestivoOut)
def alta_dia_festivo(
    datos: DiaFestivoCreate,
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("dia_festivo_edicion")),
) -> dict:
    """uq_dia_festivo_fecha es la garantía real de unicidad -- este try/except sólo traduce la
    violación a un 409 legible. Sin validación de fecha futura: se permite cargar catálogo
    retroactivo/histórico a propósito."""
    try:
        return (
            db_servicio.postgrest.schema("tiempo")
            .table("dia_festivo")
            .insert({"fecha": datos.fecha.isoformat(), "nombre": datos.nombre})
            .execute()
            .data[0]
        )
    except APIError as error:
        manejar_violacion_unicidad(error, MENSAJE_FESTIVO_DUPLICADO)


@router.delete("/{festivo_id}", status_code=status.HTTP_204_NO_CONTENT)
def borrar_dia_festivo(
    festivo_id: int,
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("dia_festivo_edicion")),
) -> None:
    """Lee-verifica-borra en dos pasos (no un DELETE condicional en una sola llamada) --
    necesita distinguir 404 (no existe) de 422 (existe pero ya pasó) con el mensaje correcto.
    <=, no <: el festivo de HOY tampoco se borra (batches de cierre de día ya pudieron haber
    corrido sobre él)."""
    fila = (
        db_servicio.postgrest.schema("tiempo")
        .table("dia_festivo")
        .select("id, fecha")
        .eq("id", festivo_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_FESTIVO_NO_ENCONTRADO)

    if date.fromisoformat(fila[0]["fecha"]) <= date.today():
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_FESTIVO_NO_FUTURO)

    db_servicio.postgrest.schema("tiempo").table("dia_festivo").delete().eq(
        "id", festivo_id
    ).execute()
