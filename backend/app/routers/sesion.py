from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.permisos import tiene_permiso
from app.schemas.sesion import SesionOut

router = APIRouter(prefix="/api/sesion", tags=["sesion"])


@router.get("", response_model=SesionOut)
def obtener_sesion(
    caller: CallerIdentity = Depends(get_caller_identity),
    db: Client = Depends(get_service_client),
) -> dict:
    """Usa service_role, no get_caller_client (excepción documentada en app/deps.py): la policy
    solo_caller_activo de personas.usuario también exige al caller activo para leer sus propias
    filas, así que una cuenta suspendida consultándose con su propio cliente recibiría cero
    filas — el mismo síntoma que este endpoint existe para diagnosticar. Por eso filtra
    exclusivamente por el auth_user_id ya verificado por get_caller_identity
    (supabase.auth.get_user contra GoTrue), nunca por un parámetro de la request."""
    tabla = db.postgrest.schema("personas").table

    filas_usuario = (
        tabla("usuario")
        .select("auth_user_id, nombre_usuario, persona_id")
        .eq("auth_user_id", caller.auth_user_id)
        .execute()
        .data
    )
    if not filas_usuario:
        return {
            "auth_user_id": caller.auth_user_id,
            "correo": caller.correo,
            "nombre_usuario": None,
            "persona_id": None,
            "persona_estado": None,
            "acceso_permitido": False,
            "motivo_bloqueo": "sin_usuario",
        }

    usuario = filas_usuario[0]
    if not usuario.get("persona_id"):
        return {
            "auth_user_id": caller.auth_user_id,
            "correo": caller.correo,
            "nombre_usuario": usuario["nombre_usuario"],
            "persona_id": None,
            "persona_estado": None,
            "acceso_permitido": False,
            "motivo_bloqueo": "sin_persona",
        }

    filas_persona = (
        tabla("persona").select("estado").eq("id", usuario["persona_id"]).execute().data
    )
    persona_estado = filas_persona[0]["estado"] if filas_persona else None
    acceso_permitido = persona_estado == "activo"
    motivo_bloqueo = None if acceso_permitido else (persona_estado or "sin_persona")

    puede_ver_modulo_1 = False
    puede_ver_modulo_2 = False
    puede_ver_modulo_3 = False
    if acceso_permitido:
        puede_ver_modulo_1 = tiene_permiso(db, usuario["persona_id"], "ver_modulo_1")
        puede_ver_modulo_2 = tiene_permiso(db, usuario["persona_id"], "ver_modulo_2")
        puede_ver_modulo_3 = tiene_permiso(db, usuario["persona_id"], "ver_modulo_3")

    return {
        "auth_user_id": caller.auth_user_id,
        "correo": caller.correo,
        "nombre_usuario": usuario["nombre_usuario"],
        "persona_id": usuario["persona_id"],
        "persona_estado": persona_estado,
        "acceso_permitido": acceso_permitido,
        "motivo_bloqueo": motivo_bloqueo,
        "puede_ver_modulo_1": puede_ver_modulo_1,
        "puede_ver_modulo_2": puede_ver_modulo_2,
        "puede_ver_modulo_3": puede_ver_modulo_3,
    }
