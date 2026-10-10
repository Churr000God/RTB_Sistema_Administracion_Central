"""Interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md, 97_/98_).

LECTURA: el estado efectivo sale de `fn_terminal_inferir_huella_estado()` con service_role (insumo, no autorización); el nombre del autor se resuelve con el cliente del LLAMADOR (RLS) y
solo si puede verlo; el conteo de activaciones es un `count` exacto (sin filas ni identidades). ESCRITURA (encender/renovar/apagar): `fn_terminal_inferir_huella_cambiar` con el cliente del
CALLER; el gate de persona activa + terminal_config_edicion está DENTRO de la función. Este router nunca escribe con service_role. Toda respuesta bajo el prefijo lleva `Cache-Control: no-store`
(middleware `SinCacheInterruptor`)."""

import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import (
    CODIGOS_MIGRACION_FALTANTE,
    MENSAJE_ERROR_INTERNO,
    MENSAJE_INTERRUPTOR_HASTA,
    traducir_error_interruptor_huella,
)
from app.interruptor_huella import (
    PREFIJO,
    construir_estado,
    fecha_valida,
    instante_de_fecha,
    instante_de_texto,
    mismo_instante,
    normalizar_estado,
    normalizar_nota,
)
from app.permisos import requiere_permiso
from app.respuestas_error import ErrorConCampos
from app.routers.config_terminales import _nombres_de_autores
from app.schemas.interruptor_huella import ApagarIn, CambioOut, EncenderIn, EstadoInterruptorOut, HistorialOut, RenovarIn

logger = logging.getLogger(__name__)

router = APIRouter(prefix=PREFIJO, tags=["terminales"])

# El ESTADO está abierto a los tres permisos de lectura de Terminales; el NOMBRE del autor, el historial y las escrituras son más estrechos (C1).
_PERMISO_VER = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
PERMISOS_VER_NOMBRES = ("terminal_config_edicion", "terminal_usuario_edicion")
_PERMISO_HISTORIAL = requiere_permiso(*PERMISOS_VER_NOMBRES)  # C1: el historial lleva notas de texto libre y autores; la lectura a secas no lo ve
_PERMISO_CAMBIAR = requiere_permiso("terminal_config_edicion")  # gate débil; la autorización real es la de la función (persona activa + permiso, no heredable)

MENSAJE_YA_ENCENDIDO = "Ya está encendido; usa Renovar para cambiar el vencimiento."
MENSAJE_NO_ENCENDIDO = "No está encendido; usa Encender."
MENSAJE_ESTADO_DESACTUALIZADO = "El interruptor cambió mientras lo editabas; revisa el estado actual."
MENSAJE_NOTA_REPETIDA = "Escribe un motivo nuevo para la renovación."
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


COLUMNAS_HISTORIAL = "id, creado_en, clave, operacion, valor_anterior, valor_nuevo, nota, registrado_por, via_funcion"


@router.get("/historial", response_model=HistorialOut)
def historial(
    limite: int = Query(50, ge=1, le=100),
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_HISTORIAL),
) -> dict:
    """Rastro inmutable del interruptor (CONTRATO §2), con el cliente del CALLER (la policy SELECT de la bitácora es la autorización real). Solo columnas seguras; el autor se
    resuelve con el mismo cliente y es null si la RLS no deja verlo (jamás el uuid)."""
    try:
        filas = db.postgrest.schema("tiempo").table("bitacora_config_terminal").select(COLUMNAS_HISTORIAL).order("id", desc=True).limit(limite).execute().data
    except APIError as error:
        if error.code in CODIGOS_MIGRACION_FALTANTE:
            raise
        logger.error("no se pudo leer la bitácora del interruptor (sqlstate %s)", error.code)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA) from None
    if not isinstance(filas, list):
        logger.error("la bitácora del interruptor devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    try:
        nombres = _nombres_de_autores(db, [f.get("registrado_por") for f in filas if isinstance(f.get("registrado_por"), str)])
    except Exception:  # noqa: BLE001
        logger.warning("no se pudo resolver los autores del historial del interruptor")
        nombres = {}
    return {
        "items": [
            {
                "id": f["id"], "creado_en": f["creado_en"], "clave": f["clave"], "operacion": f["operacion"], "valor_anterior": f.get("valor_anterior"),
                "valor_nuevo": f.get("valor_nuevo"), "nota": f.get("nota"), "autor_nombre": nombres.get(f.get("registrado_por")), "via_funcion": f["via_funcion"],
            }
            for f in filas
        ]
    }


# --- escrituras (cliente del CALLER; el gate está dentro de la función) -------------------------------------------------------------------------------


def _conflicto(codigo: str, mensaje: str, estado_publico: dict | None) -> ErrorConCampos:
    return ErrorConCampos(status.HTTP_409_CONFLICT, mensaje, {} if estado_publico is None else {"estado": estado_publico}, codigo=codigo)


def _hasta_invalido() -> ErrorConCampos:
    return ErrorConCampos(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_INTERRUPTOR_HASTA, {}, codigo="hasta_invalido")


def _validar_fecha(fecha) -> None:
    """Recalcula el rango con el reloj de ESTA petición: nunca se confía en lo que mostró el GET (puede haber pasado la medianoche)."""
    if not fecha_valida(fecha, _ahora()):
        raise _hasta_invalido()


def _estado_previo(db_servicio: Client) -> dict:
    """Estado leído con service_role para los chequeos de cortesía (la base sigue siendo idempotente y la autoridad)."""
    crudo = leer_estado_crudo(db_servicio)
    estado = normalizar_estado(crudo)
    if estado is None:
        logger.error("fn_terminal_inferir_huella_estado devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    return {"crudo": crudo, "normalizado": estado}


def _ultima_nota(db_servicio: Client) -> str | None:
    """La última nota registrada del interruptor, SOLO para compararla (no se devuelve ni se registra). None si no hay o si no se pudo leer."""
    try:
        filas = (
            db_servicio.postgrest.schema("tiempo").table("bitacora_config_terminal").select("nota").not_.is_("nota", "null").order("id", desc=True).limit(1).execute().data
        )
        return filas[0]["nota"] if filas and isinstance(filas[0].get("nota"), str) else None
    except Exception:  # noqa: BLE001 - el chequeo de nota repetida es de cortesía: no bloquea si no se puede leer
        logger.warning("no se pudo leer la última nota del interruptor para compararla")
        return None


def _cambiar(db: Client, activa: bool, nota: str | None, hasta_iso: str | None) -> dict:
    """Llama la función con el cliente del CALLER. Todo APIError conocido se traduce a un mensaje fijo; cualquier otro se registra SOLO con su SQLSTATE (su DETAIL puede traer la fila
    con la nota) y sale como 500 sin texto. Una migración sin aplicar sigue al handler global."""
    try:
        datos = db.postgrest.schema("tiempo").rpc("fn_terminal_inferir_huella_cambiar", {"p_activa": activa, "p_nota": nota, "p_hasta": hasta_iso}).execute().data
    except APIError as error:
        if error.code in CODIGOS_MIGRACION_FALTANTE:
            raise
        traduccion = traducir_error_interruptor_huella(error)
        if traduccion is not None:
            raise traduccion from None
        logger.error("fn_terminal_inferir_huella_cambiar falló (sqlstate %s)", error.code)
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, MENSAJE_ERROR_INTERNO) from None
    if not isinstance(datos, dict) or datos.get("resultado") not in ("actualizada", "sin_cambio"):
        logger.error("fn_terminal_inferir_huella_cambiar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    return datos


def _respuesta(db: Client, db_servicio: Client, caller: CallerIdentity, datos: dict) -> dict:
    """N1: el cambio YA se aplicó cuando se llega aquí. Si el estado no se puede armar (la función no lo devolvió bien, o falló una lectura accesoria) NO se responde un error que haría creer
    que no pasó nada: se devuelve 200 con el resultado y `estado: null`, y la pantalla recarga el estado con el GET."""
    try:
        estado = armar_estado(db, db_servicio, caller, datos.get("estado"))
    except Exception as error:  # noqa: BLE001 - incluye el 503 de armar_estado
        logger.warning("el cambio del interruptor se aplicó pero no se pudo armar el estado (%s)", type(error).__name__)
        estado = None
    return {"resultado": datos["resultado"], "estado": estado}


@router.post("/encender", response_model=CambioOut)
def encender(
    datos: EncenderIn,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_CAMBIAR),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Enciende (CONTRATO §3.1). `hasta_fecha` vence a las 23:59:59 de México de ese día."""
    _validar_fecha(datos.hasta_fecha)
    previo = _estado_previo(db_servicio)
    if previo["normalizado"]["activo"]:
        raise _conflicto("ya_esta_encendido", MENSAJE_YA_ENCENDIDO, armar_estado(db, db_servicio, caller, previo["crudo"]))
    resultado = _cambiar(db, True, datos.nota, instante_de_fecha(datos.hasta_fecha).isoformat())
    return _respuesta(db, db_servicio, caller, resultado)


@router.post("/renovar", response_model=CambioOut)
def renovar(
    datos: RenovarIn,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_CAMBIAR),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Renueva el vencimiento (CONTRATO §3.2): exige nota NUEVA y el `hasta` que la pantalla tenía."""
    _validar_fecha(datos.hasta_fecha)
    base = instante_de_texto(datos.hasta_base)
    if base is None:
        raise _hasta_invalido()
    previo = _estado_previo(db_servicio)
    if not previo["normalizado"]["activo"]:
        raise _conflicto("no_esta_encendido", MENSAJE_NO_ENCENDIDO, None)
    if not mismo_instante(base, instante_de_texto(previo["normalizado"]["hasta"])):
        raise _conflicto("estado_desactualizado", MENSAJE_ESTADO_DESACTUALIZADO, armar_estado(db, db_servicio, caller, previo["crudo"]))
    ultima = _ultima_nota(db_servicio)
    if ultima is not None and normalizar_nota(ultima) == normalizar_nota(datos.nota):
        raise ErrorConCampos(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_NOTA_REPETIDA, {}, codigo="nota_repetida")
    resultado = _cambiar(db, True, datos.nota, instante_de_fecha(datos.hasta_fecha).isoformat())
    return _respuesta(db, db_servicio, caller, resultado)


@router.post("/apagar", response_model=CambioOut)
def apagar(
    datos: ApagarIn,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_CAMBIAR),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Apaga (CONTRATO §3.3): siempre se puede; la nota es opcional."""
    resultado = _cambiar(db, False, datos.nota or None, None)
    return _respuesta(db, db_servicio, caller, resultado)
