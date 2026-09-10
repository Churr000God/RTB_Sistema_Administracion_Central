"""Dependencias de FastAPI: cliente de Supabase con el JWT del caller (respeta RLS) y cliente
con service_role (para operaciones administrativas: invitar usuarios, subir al bucket)."""
from fastapi import Depends, Header, HTTPException, status
from pydantic import BaseModel
from supabase import Client, create_client

from app.config import Settings, get_settings


def get_service_client(settings: Settings = Depends(get_settings)) -> Client:
    return create_client(settings.supabase_url, settings.supabase_service_role_key)


def _extraer_token(authorization: str) -> str:
    if not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Falta el token de acceso")
    return authorization.removeprefix("Bearer ")


def get_caller_client(
    authorization: str = Header(...),
    settings: Settings = Depends(get_settings),
) -> Client:
    """Cliente con el token del usuario que llama — cualquier consulta con este cliente respeta
    la RLS de personas.fn_caller_activo() (SCJ-PRO-02), no hay chequeo de estado aparte aquí."""
    token = _extraer_token(authorization)
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    client.postgrest.auth(token)
    return client


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
    respuesta = client.auth.get_user(token)
    if respuesta is None or respuesta.user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token inválido o expirado")
    return CallerIdentity(auth_user_id=respuesta.user.id, correo=respuesta.user.email)
