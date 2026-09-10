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

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso
from app.schemas.excepciones import ExcepcionOut

router = APIRouter(prefix="/api/excepciones", tags=["excepciones"])

MENSAJE_EXCEPCION_NO_ENCONTRADA = "La excepción no existe."


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
        .select("id, persona_id, momento_dispositivo")
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
        }
        for marca in marcas
    }


def _armar_filas(db: Client, filas_excepcion: list[dict]) -> list[dict]:
    detalle_por_marca = _resolver_detalle_marca(db, filas_excepcion)
    return [
        {
            **fila,
            "persona_id": detalle_por_marca.get(fila["marca_id"], {}).get("persona_id"),
            "persona_nombre": detalle_por_marca.get(fila["marca_id"], {}).get("persona_nombre"),
            "momento_dispositivo": detalle_por_marca.get(fila["marca_id"], {}).get(
                "momento_dispositivo"
            ),
        }
        for fila in filas_excepcion
    ]


@router.get("", response_model=list[ExcepcionOut])
def listar_excepciones_pendientes(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("excepcion_lectura", "excepcion_edicion")),
) -> list[dict]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("id, marca_id, dia_id, motivo_revision, estado, creado_en")
        .eq("estado", "pendiente")
        .order("creado_en")
        .execute()
        .data
    )
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
