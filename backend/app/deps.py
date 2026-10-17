"""Dependencias de FastAPI: cliente de Supabase con el JWT del caller (respeta RLS) y cliente
con service_role (para operaciones administrativas: invitar usuarios, subir al bucket)."""
import logging
import re

import httpx
from fastapi import Depends, Header, HTTPException, Request, status
from pydantic import BaseModel
from supabase import Client, create_client
from supabase_auth.errors import AuthApiError, AuthError, AuthRetryableError, AuthUnknownError

from app.config import Settings, get_settings
from app.errores import MENSAJE_BASE_NO_DISPONIBLE, MENSAJE_TOKEN_INVALIDO, REINTENTAR_DESPUES_S

logger = logging.getLogger("app.deps")

# Un JWT de Supabase son tres segmentos base64url separados por puntos. Lo que no tenga esa forma (o sea enorme) se rechaza AQUÍ, sin salir a GoTrue: no amplifica basura hacia Supabase/su WAF.
_FORMA_JWT = re.compile(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")
MAX_LARGO_TOKEN = 4096
# Qué errores de GoTrue significan «ESTE token no sirve» (401, y el frontend cierra la sesión). Lista cerrada por `error.code`; con código ausente o desconocido se cae al status.
# Todo lo demás (429 over_request_rate_limit —todas las validaciones salen de la IP del backend—, 408, 4xx raros del borde) NO es un token malo: 503 con Retry-After.
CODIGOS_NO_TOKEN = frozenset({"over_request_rate_limit", "over_email_send_rate_limit", "request_timeout"})   # aunque traigan un status de la lista, no son «token inválido»
CODIGOS_TOKEN_INVALIDO = frozenset({"bad_jwt", "no_authorization", "session_not_found", "session_expired", "user_not_found", "user_banned"})
STATUS_TOKEN_INVALIDO = frozenset({400, 401, 403, 404, 422})


def get_service_client(request: Request, settings: Settings = Depends(get_settings)) -> Client:
    request.state.usa_cliente_servicio = True      # lo lee el manejador de APIError: un PGRST30x de un cliente de SERVICIO no es «token del usuario inválido»
    return create_client(settings.supabase_url, settings.supabase_service_role_key)


def _extraer_token(authorization: str) -> str:
    if not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Falta el token de acceso")
    token = authorization.removeprefix("Bearer ")
    if len(token) > MAX_LARGO_TOKEN or not _FORMA_JWT.fullmatch(token):
        raise _token_invalido()
    return token


def get_caller_client(
    request: Request,
    authorization: str = Header(...),
    settings: Settings = Depends(get_settings),
) -> Client:
    """Cliente con el token del usuario que llama — cualquier consulta con este cliente respeta
    la RLS de personas.fn_caller_activo() (SCJ-PRO-02), no hay chequeo de estado aparte aquí."""
    token = _extraer_token(authorization)
    request.state.usa_cliente_caller = True        # idem: un PGRST301/302/303 con este cliente SÍ es el token del usuario
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    client.postgrest.auth(token)
    return client


def _token_invalido() -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, MENSAJE_TOKEN_INVALIDO, headers={"WWW-Authenticate": "Bearer"})


def _no_disponible() -> HTTPException:
    return HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_BASE_NO_DISPONIBLE, headers={"Retry-After": str(REINTENTAR_DESPUES_S)})


class CallerIdentity(BaseModel):
    auth_user_id: str
    correo: str | None


def get_caller_identity(
    authorization: str = Header(...),
    settings: Settings = Depends(get_settings),
) -> CallerIdentity:
    """Identidad del caller validada contra GoTrue (supabase.auth.get_user) — no decodifica el
    JWT localmente, así se evita meter PyJWT y el JWT secret al proyecto. A diferencia de
    get_caller_client, no crea un cliente con RLS del caller: sólo confirma quién es."""
    token = _extraer_token(authorization)
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    try:
        respuesta = client.auth.get_user(token)
    except (AuthRetryableError, AuthUnknownError, httpx.HTTPError) as error:
        # No se pudo validar (GoTrue caído, red, respuesta que no es JSON): NO es un token malo. 503 con Retry-After, sin el texto del SDK.
        logger.warning("validación de token: GoTrue no respondió con claridad (%s); 503", type(error).__name__)
        raise _no_disponible() from None
    except AuthApiError as error:
        codigo = error.code if isinstance(error.code, str) else None
        if codigo in CODIGOS_TOKEN_INVALIDO or (codigo not in CODIGOS_NO_TOKEN and error.status in STATUS_TOKEN_INVALIDO):
            raise _token_invalido() from None   # mal formado, vencido, firma inválida, usuario borrado: 401 con el mismo mensaje fijo (sin el texto del SDK)
        logger.warning("validación de token: GoTrue respondió %s (%s) y no es un token inválido; 503", error.status, codigo or "-")
        raise _no_disponible() from None
    except AuthError:
        raise _token_invalido() from None
    if respuesta is None or respuesta.user is None:
        raise _token_invalido()
    return CallerIdentity(auth_user_id=respuesta.user.id, correo=respuesta.user.email)
