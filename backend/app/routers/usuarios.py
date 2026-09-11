from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client
from supabase_auth.errors import AuthError

from app.config import Settings, get_settings, parse_frontend_urls
from app.deps import get_caller_client, get_service_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.usuarios import UsuarioCreate, UsuarioOut

router = APIRouter(prefix="/api/usuarios", tags=["usuarios"])

MENSAJE_USUARIO_DUPLICADO = "Esta persona ya tiene un usuario asociado."
MENSAJE_INVITACION_REDIRECT_NO_PERMITIDO = (
    "No se pudo enviar la invitación: la URL de redirect no está permitida en la configuración "
    "de Supabase Auth (Authentication > URL Configuration > Redirect URLs)."
)
MENSAJE_INVITACION_DATOS_INVALIDOS = "El correo no es válido o ya tiene una cuenta de acceso."
MENSAJE_INVITACION_LIMITE_EXCEDIDO = (
    "Se alcanzó el límite de envíos de invitación de Supabase Auth -- reintentá en unos minutos."
)
MENSAJE_INVITACION_FALLIDA = "No se pudo enviar la invitación de acceso."


def _lanzar_error_invitacion(error: AuthError) -> None:
    """invite_user_by_email puede tirar AuthApiError (con .status/.code reales del API de
    GoTrue) o AuthUnknownError (si el cuerpo de la respuesta no es JSON -- ej. un 403 crudo de
    un proxy/WAF delante de GoTrue que nunca llega al manejo normal de error de la API) -- ambas
    heredan de AuthError, se capturan juntas acá. Sólo AuthApiError expone `.status` de forma
    confiable (AuthUnknownError no), por eso se usa `getattr` en vez de asumirlo.

    Bug real encontrado 2026-09-11: `redirect_to` fuera de la allowlist de Supabase Auth
    (Redirect URLs, gotcha ya documentado en CLAUDE.md sobre actualizarla al pasar de entorno)
    da 403 y subía como 500 crudo sin capturar -- reproducido en vivo desde el Pi de pruebas
    (100.115.160.115:8080), ausente del dashboard. Se mapean por `.status` (siempre HTTP
    estándar, confiable) en vez de por `.code` (string específico de Supabase que no se
    verificó para cada caso -- no vale la pena adivinar mensajes más finos sin evidencia real de
    qué código manda cada escenario)."""
    status_http = getattr(error, "status", None)
    if status_http == status.HTTP_403_FORBIDDEN:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_INVITACION_REDIRECT_NO_PERMITIDO
        ) from error
    if status_http == status.HTTP_422_UNPROCESSABLE_ENTITY:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_INVITACION_DATOS_INVALIDOS
        ) from error
    if status_http == status.HTTP_429_TOO_MANY_REQUESTS:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_INVITACION_LIMITE_EXCEDIDO
        ) from error
    raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_INVITACION_FALLIDA) from error


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
    try:
        invite = db.auth.admin.invite_user_by_email(
            datos.correo,
            {"redirect_to": f"{frontend_url}/completar-invitacion"},
        )
    except AuthError as error:
        _lanzar_error_invitacion(error)

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
