"""API de bitacora_movimiento_persona (SCJ-PRO-02: suspender/reactivar/dar de baja).

Gate de permisos: GET sin cambio -- no existe código de lectura para este módulo, sigue el
gate débil. POST (cambio de estado) exige además requiere_permiso("cambio_estado_persona")
(app/permisos.py)."""

from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.permisos import requiere_permiso
from app.schemas.movimientos import MovimientoCreate, MovimientoOut

router = APIRouter(prefix="/api/personas/{persona_id}/movimientos", tags=["movimientos"])


@router.post("", status_code=201, response_model=MovimientoOut)
def crear_movimiento(
    persona_id: str,
    datos: MovimientoCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(requiere_permiso("cambio_estado_persona")),
) -> dict:
    """SCJ-PRO-02: el trigger trg_bitacora_sincroniza_persona actualiza persona.estado solo —
    este endpoint nunca hace UPDATE directo a personas.persona. registrado_por es el caller
    autenticado; fn_caller_activo() ya exige que tenga fila en personas.usuario para poder
    insertar aquí, así que el FK nunca falla (no hace falta manejo de error especial)."""
    return (
        db.postgrest.schema("personas")
        .table("bitacora_movimiento_persona")
        .insert(
            {
                "persona_id": persona_id,
                "tipo_movimiento": datos.tipo_movimiento,
                "motivo": datos.motivo,
                "registrado_por": caller.auth_user_id,
            }
        )
        .execute()
        .data[0]
    )


@router.get("", response_model=list[MovimientoOut])
def listar_movimientos(persona_id: str, db: Client = Depends(get_caller_client)) -> list[dict]:
    tabla = db.postgrest.schema("personas").table
    movimientos = (
        tabla("bitacora_movimiento_persona")
        .select("*")
        .eq("persona_id", persona_id)
        .order("fecha_efectiva", desc=True)
        .execute()
        .data
    )

    autores_ids = {m["registrado_por"] for m in movimientos if m.get("registrado_por")}
    if autores_ids:
        filas_usuario = (
            tabla("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", list(autores_ids))
            .execute()
            .data
        )
        nombre_por_id = {fila["auth_user_id"]: fila["nombre_usuario"] for fila in filas_usuario}
        for movimiento in movimientos:
            movimiento["registrado_por_nombre"] = nombre_por_id.get(movimiento.get("registrado_por"))

    return movimientos
