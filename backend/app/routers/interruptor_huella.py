"""Interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md, 97_/98_).

LECTURA: el estado efectivo sale de `fn_terminal_inferir_huella_estado()` con service_role (insumo, no autorización); el nombre del autor se resuelve con el cliente del LLAMADOR (RLS) y
solo si puede verlo; el conteo de activaciones es un `count` exacto (sin filas ni identidades). ESCRITURA (encender/renovar/apagar): `fn_terminal_inferir_huella_cambiar` con el cliente del
CALLER; el gate de persona activa + terminal_config_edicion está DENTRO de la función. Este router nunca escribe con service_role. Toda respuesta bajo el prefijo lleva `Cache-Control: no-store`
(middleware `SinCacheInterruptor`)."""

import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import CODIGOS_MIGRACION_FALTANTE
from app.interruptor_huella import PREFIJO, construir_estado
from app.permisos import requiere_permiso
from app.routers.config_terminales import _nombres_de_autores
from app.schemas.interruptor_huella import EstadoInterruptorOut

logger = logging.getLogger(__name__)

router = APIRouter(prefix=PREFIJO, tags=["terminales"])

# El ESTADO está abierto a los tres permisos de lectura de Terminales; el NOMBRE del autor, el historial y las escrituras son más estrechos (C1).
_PERMISO_VER = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
PERMISOS_VER_NOMBRES = ("terminal_config_edicion", "terminal_usuario_edicion")

MENSAJE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
TIPO_ACTIVACION = "huella_inferida"


def _ahora() -> datetime:
    return datetime.now(timezone.utc)


def leer_estado_crudo(db_servicio: Client) -> Any:
    """El JSON de `fn_terminal_inferir_huella_estado()` (service_role). Un fallo de lectura NO se disfraza de «apagado»: 503 con mensaje fijo (una migración sin aplicar sigue al
    handler global de main.py)."""
    try:
        return db_servicio.postgrest.schema("tiempo").rpc("fn_terminal_inferir_huella_estado", {}).execute().data
    except APIError as error:
        if error.code in CODIGOS_MIGRACION_FALTANTE:
            raise
        logger.error("fn_terminal_inferir_huella_estado falló (sqlstate %s)", error.code)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA) from None


def _requisitos(db_servicio: Client) -> dict:
    """Informativo (la base decide): consentimiento definitivo publicado y al menos una terminal activa. Lo que no se pueda leer queda en None."""
    resultado: dict[str, bool | None] = {"consentimiento_publicado": None, "terminal_activa": None}
    try:
        filas = (
            db_servicio.postgrest.schema("tiempo").table("terminal_consentimiento").select("provisional").order("version", desc=True).limit(1).execute().data
        )
        resultado["consentimiento_publicado"] = bool(filas) and filas[0].get("provisional") is False
    except Exception:  # noqa: BLE001 - la pantalla no se cae por un requisito informativo
        logger.warning("no se pudo leer el consentimiento vigente para los requisitos del interruptor")
    try:
        resultado["terminal_activa"] = bool(db_servicio.postgrest.schema("tiempo").table("terminal").select("id").eq("activa", True).limit(1).execute().data)
    except Exception:  # noqa: BLE001
        logger.warning("no se pudo leer si hay una terminal activa para los requisitos del interruptor")
    return resultado


def _conteo_de_activaciones(db_servicio: Client, encendido_en: str) -> int | None:
    """`count` exacto de movimientos `huella_inferida` desde `encendido_en` (global, sin traer filas, solo el número). None si falla."""
    try:
        n = (
            db_servicio.postgrest.schema("tiempo")
            .table("bitacora_movimiento_terminal_usuario")
            .select("id", count="exact", head=True)
            .eq("tipo_movimiento", TIPO_ACTIVACION)
            .gte("creado_en", encendido_en)
            .execute()
            .count
        )
        return n if isinstance(n, int) and not isinstance(n, bool) and n >= 0 else None
    except Exception:  # noqa: BLE001
        logger.warning("no se pudo contar las activaciones desde el encendido del interruptor")
        return None


def _nombre_del_autor(db: Client, caller: CallerIdentity, uuid_autor: str | None) -> str | None:
    """Con el cliente del LLAMADOR (su RLS), nunca service_role. Solo si tiene un permiso de edición de Terminales; si no se puede ver a la persona, None (jamás el uuid)."""
    if not uuid_autor:
        return None
    try:
        persona_id = permisos.resolver_persona_id(db, caller)
        if not permisos.tiene_alguno(db, persona_id, *PERMISOS_VER_NOMBRES):
            return None
        return _nombres_de_autores(db, [uuid_autor]).get(uuid_autor)
    except Exception:  # noqa: BLE001
        logger.warning("no se pudo resolver el nombre del autor del interruptor")
        return None


def armar_estado(db: Client, db_servicio: Client, caller: CallerIdentity, crudo: Any) -> dict:
    """Estado público a partir del JSON de la base (lo usan el GET y, más adelante, las respuestas de las escrituras). Forma ilegible -> 503, nunca «apagado» inventado."""
    ahora = _ahora()
    base = construir_estado(crudo, nombre_autor=None, altas_activadas=None, requisitos={}, ahora=ahora)
    if base is None:
        logger.error("fn_terminal_inferir_huella_estado devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    autor = crudo.get("encendido_por") if isinstance(crudo.get("encendido_por"), str) else None
    conteo = _conteo_de_activaciones(db_servicio, base["encendido_en"]) if base["estado"] == "encendido" and base["encendido_en"] else None
    return construir_estado(crudo, nombre_autor=_nombre_del_autor(db, caller, autor), altas_activadas=conteo, requisitos=_requisitos(db_servicio), ahora=ahora)  # type: ignore[return-value]


@router.get("", response_model=EstadoInterruptorOut)
def obtener_estado(
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_VER),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Estado efectivo del interruptor (CONTRATO §1). Gate: los tres permisos de lectura de Terminales."""
    return armar_estado(db, db_servicio, caller, leer_estado_crudo(db_servicio))
