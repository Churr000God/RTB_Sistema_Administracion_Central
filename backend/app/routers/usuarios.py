from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.config import Settings, get_settings, parse_frontend_urls
from app.deps import get_caller_client, get_service_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.usuarios import UsuarioCreate, UsuarioOut

router = APIRouter(prefix="/api/usuarios", tags=["usuarios"])

MENSAJE_USUARIO_DUPLICADO = "Esta persona ya tiene un usuario asociado."


@router.post("", status_code=201, response_model=UsuarioOut)
def alta_usuario(
    datos: UsuarioCreate,
    db: Client = Depends(get_service_client),
    settings: Settings = Depends(get_settings),
    _caller: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("alta_personas_usuarios")),
) -> dict:
    """SCJ-PRO-01: A2 (crear usuario) + A4 (invitación). A3 (bitácora) lo dispara
    trg_usuario_bitacora_alta en la base de datos, no hay nada que hacer aquí para eso.
    redirect_to es obligatorio: sin él, Supabase manda el link al Site URL (la raíz, el
    login), no a /completar-invitacion -- la persona invitada nunca llega a definir su
    contraseña. _caller exige sólo Bearer token válido (RLS); _permiso exige además
    alta_personas_usuarios (app/permisos.py) -- el mismo código que gatea el alta de persona.

    uq_usuario_persona (05_personas_estructura.sql) es la garantía real de "una persona, un
    usuario" -- se chequea acá antes para no invitar (crear cuenta de Auth + mandar correo) a
    alguien que de todos modos va a rebotar por la constraint. La segunda capa (except APIError)
    cubre la carrera de dos altas casi simultáneas para la misma persona.

    redirect_to necesita una única URL -- si FRONTEND_URL trae varios orígenes separados por
    coma (localhost + IP de Tailscale), se usa el primero."""
    ya_tiene_usuario = (
        db.postgrest.schema("personas")
        .table("usuario")
        .select("auth_user_id")
        .eq("persona_id", datos.persona_id)
        .execute()
        .data
    )
    if ya_tiene_usuario:
        raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_USUARIO_DUPLICADO)

    frontend_url = parse_frontend_urls(settings.frontend_url)[0]
    invite = db.auth.admin.invite_user_by_email(
        datos.correo,
        {"redirect_to": f"{frontend_url}/completar-invitacion"},
    )

    try:
        usuario = (
            db.postgrest.schema("personas")
            .table("usuario")
            .insert(
                {
                    "auth_user_id": invite.user.id,
                    "persona_id": datos.persona_id,
                    "nombre_usuario": datos.nombre_usuario,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        # El usuario de Auth ya invitado queda huérfano (sin fila en personas.usuario) si el
        # insert falla por cualquier motivo, no sólo la carrera de uq_usuario_persona -- se
        # revierte siempre para no dejar cuentas de Auth sueltas.
        db.auth.admin.delete_user(invite.user.id)
        manejar_violacion_unicidad(error, MENSAJE_USUARIO_DUPLICADO)

    return usuario
