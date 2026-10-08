from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.permisos import tiene_permisos
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
    puede_descartar_excepciones = False
    puede_ver_terminales = False
    puede_editar_terminales = False
    puede_editar_config_terminales = False
    if acceso_permitido:
        # UNA resolución de puestos y poseedores para todos los códigos (antes ~5 consultas por código).
        permisos = tiene_permisos(
            db,
            usuario["persona_id"],
            (
                "ver_modulo_1",
                "ver_modulo_2",
                "ver_modulo_3",
                "excepcion_dia_cerrado_descarte",
                "terminal_usuario_lectura",
                "terminal_usuario_edicion",
                "terminal_config_edicion",
            ),
        )
        puede_ver_modulo_1 = permisos["ver_modulo_1"]
        puede_ver_modulo_2 = permisos["ver_modulo_2"]
        puede_ver_modulo_3 = permisos["ver_modulo_3"]
        puede_descartar_excepciones = permisos["excepcion_dia_cerrado_descarte"]
        puede_editar_terminales = permisos["terminal_usuario_edicion"]
        puede_editar_config_terminales = permisos["terminal_config_edicion"]
        # Q5 (decidido por el usuario): terminal_config_edicion SOLA no da acceso a Terminales.
        puede_ver_terminales = permisos["terminal_usuario_lectura"] or puede_editar_terminales

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
        "puede_descartar_excepciones": puede_descartar_excepciones,
        "puede_ver_terminales": puede_ver_terminales,
        "puede_editar_terminales": puede_editar_terminales,
        "puede_editar_config_terminales": puede_editar_config_terminales,
    }
