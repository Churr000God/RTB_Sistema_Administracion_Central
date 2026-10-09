"""Autenticación de la terminal (SCJ-DEC-12 §1, §7): llave opaca `scjt_…` en `Authorization: Bearer`,
canal HTTPS obligatorio, IP del cliente confiable y backoff por IP.

La llave NUNCA se guarda ni se registra: el backend sólo calcula su SHA-256 y llama al RPC
`tiempo.fn_terminal_autenticar(p_hash, p_ip)` (SECURITY DEFINER, EXECUTE sólo service_role), que
busca por igualdad en la base. No se comparan hashes en Python. Ningún mensaje de log incluye la
llave, su hash ni la cabecera Authorization (B1): sólo IP, motivo genérico e id de credencial.

Un 401 nunca distingue el motivo (sin cabecera, mal formada, desconocida, revocada, vencida o
terminal inactiva): quien adivina no aprende nada. Un fallo de la BASE (red, 42501) es un 503: no
es una credencial inválida y no cuenta para el backoff.

Despliegue (SCJ-DEC-12 §7): TERMINAL_PROXIES_CONFIANZA nunca 0.0.0.0/0 (esas entradas se ignoran); el
proxy debe SOBRESCRIBIR X-Forwarded-Proto y AÑADIR al final de X-Forwarded-For; FORWARDED_ALLOW_IPS de
uvicorn nunca '*' (al arrancar se emite un WARNING si lo es)."""

import hashlib
import ipaddress
import logging
import math
import re
import secrets
import threading
import time
from collections import OrderedDict
from functools import lru_cache
from typing import Mapping, NamedTuple

from fastapi import Depends, Header, HTTPException, Request, status
from postgrest.exceptions import APIError
from pydantic import BaseModel, ValidationError
from supabase import Client

from starlette._utils import get_route_path

from app.config import Settings, get_settings
from app.deps import get_service_client

logger = logging.getLogger("app.terminal")

PREFIJO_LLAVE = "scjt_"
# secrets.token_urlsafe(32) = 43 caracteres URL-safe (256 bits): longitud exacta.
FORMATO_LLAVE = re.compile(r"scjt_[A-Za-z0-9_-]{43}")

MENSAJE_CREDENCIAL_INVALIDA = "Credencial de terminal inválida."
MENSAJE_HTTPS_REQUERIDO = "Se requiere HTTPS para este recurso."
MENSAJE_DEMASIADOS_INTENTOS = "Demasiados intentos; vuelve a intentar más tarde."
MENSAJE_NO_DISPONIBLE = "Servicio no disponible; reintenta."

# Un año, sin includeSubDomains: el host del API puede ser el mismo del frontend.
HSTS = "max-age=31536000"
RUTA_TERMINAL = "/api/terminal"


def es_ruta_terminal(ruta: str) -> bool:
    """`/api/terminal` y `/api/terminal/…`, NO `/api/terminales/…` (el prefijo a secas atrapaba también la API web)."""
    return ruta == RUTA_TERMINAL or ruta.startswith(RUTA_TERMINAL + "/")
BLOQUEO_MAXIMO_SEG = 3600
OLVIDO_REINCIDENCIA_SEG = 86_400  # sin fallos durante 24 h, la reincidencia se olvida
IPS_BUENAS_MAX = 64
IPS_BUENAS_TTL_SEG = 86_400
CAPACIDAD_TRAS_EXPULSION = 0.8


def generar_llave() -> str:
    return PREFIJO_LLAVE + secrets.token_urlsafe(32)


def hash_llave(llave: str) -> str:
    return hashlib.sha256(llave.encode("utf-8")).hexdigest()


class TerminalIdentity(BaseModel):
    """Lo que devuelve el RPC de autenticación. `id` es tiempo.terminal.id (el bigint que reciben
    todos los RPC como p_terminal_id); `serie` es tiempo.terminal.terminal_id (varchar)."""

    id: int
    serie: str
    credencial_id: int
    ip_cambio: bool


# --- IP y esquema "efectivos": sólo se honran las cabeceras de un proxy de confianza ---------------


@lru_cache(maxsize=16)
def _redes_confiables(valor: str) -> tuple:
    redes = []
    for entrada in valor.split(","):
        entrada = entrada.strip()
        if not entrada:
            continue
        try:
            red = ipaddress.ip_network(entrada, strict=False)
        except ValueError:
            continue  # entrada inválida: se ignora, jamás se confía "por defecto"
        if red.prefixlen == 0:
            # 0.0.0.0/0 o ::/0 confiaría en TODO el mundo: equivale a no configurar nada
            logger.warning("terminal: TERMINAL_PROXIES_CONFIANZA contiene %s; se ignora", red)
            continue
        redes.append(red)
    return tuple(redes)


def _es_ip(texto: str) -> bool:
    try:
        ipaddress.ip_address(texto)
        return True
    except ValueError:
        return False


def _es_confiable(ip: str | None, settings: Settings) -> bool:
    if not ip or not _es_ip(ip):
        return False
    direccion = ipaddress.ip_address(ip)
    return any(
        direccion.version == red.version and direccion in red
        for red in _redes_confiables(settings.terminal_proxies_confianza)
    )


def _par(request: Request) -> str | None:
    return request.client.host if request.client else None


def ip_cliente(request: Request, settings: Settings) -> str:
    """X-Forwarded-For sólo si el par inmediato es un proxy de confianza; entonces vale la última
    IP NO confiable de la cadena (lo anterior lo puede escribir el cliente)."""
    par = _par(request)
    if _es_confiable(par, settings):
        reenviado = request.headers.get("x-forwarded-for", "")
        for candidato in reversed([parte.strip() for parte in reenviado.split(",")]):
            if not candidato:
                continue
            if not _es_ip(candidato):
                return par  # basura: no se confía
            if not _es_confiable(candidato, settings):
                return candidato
    return par or "desconocida"


def esquema_efectivo(request: Request, settings: Settings) -> str:
    """Esquema real de la petición; X-Forwarded-Proto sólo cuenta si lo manda un proxy de
    confianza y entonces vale el ÚLTIMO valor (el que agregó el proxy)."""
    if _es_confiable(_par(request), settings):
        proto = request.headers.get("x-forwarded-proto", "").split(",")[-1].strip().lower()
        if proto:
            return proto
    return request.url.scheme.lower()


# --- backoff por IP ----------------------------------------------------------------------------------


def clave_ip(ip: str) -> str:
    """Clave del limitador: IPv4 tal cual; IPv6 por prefijo /64 (un host controla un /64 entero y
    rotaría direcciones para esquivar el bloqueo); IPv4 mapeada en IPv6 como la IPv4."""
    try:
        direccion = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if direccion.version == 6:
        if direccion.ipv4_mapped is not None:
            return str(direccion.ipv4_mapped)
        return str(ipaddress.ip_network(f"{direccion}/64", strict=False))
    return str(direccion)


class ResultadoFallo(NamedTuple):
    fallos: int  # fallos consecutivos tras éste (0 si éste disparó un bloqueo)
    bloqueo_seg: int  # > 0 si éste disparó un bloqueo nuevo


class LimitadorFallos:
    """Fallos 401 consecutivos por IP, en memoria y por proceso. Sin bloqueo por llave ni por
    terminal: un atacante no puede dejar fuera al Pi legítimo mandando llaves malas con su nombre
    (sólo afecta a su propia IP). El bloqueo se duplica con la reincidencia (tope 1 h).

    Mitigación de IP compartida (SCJ-DEC-12 §7, M1): las IPs desde las que ya hubo una autenticación
    EXITOSA (máx. 64, TTL 24 h) quedan exentas del 429; sus fallos se siguen contando y registrando.
    No abre fuerza bruta: la llave tiene 256 bits.

    Memoria acotada con expulsión LRU en lotes (hasta el 80 % de la capacidad): amortizado O(1) por
    fallo, sin recorrer ni ordenar todo en cada llamada."""

    def __init__(
        self,
        max_entradas: int = 10_000,
        ips_buenas_max: int = IPS_BUENAS_MAX,
        ips_buenas_ttl_seg: float = IPS_BUENAS_TTL_SEG,
        reloj=time.monotonic,
    ):
        self._lock = threading.Lock()
        self._estado: OrderedDict[str, dict] = OrderedDict()
        self._buenas: OrderedDict[str, float] = OrderedDict()
        self._max_entradas = max_entradas
        self._ips_buenas_max = ips_buenas_max
        self._ips_buenas_ttl = ips_buenas_ttl_seg
        self.reloj = reloj

    def __len__(self) -> int:
        with self._lock:
            return len(self._estado)

    def reiniciar(self) -> None:
        with self._lock:
            self._estado.clear()
            self._buenas.clear()

    def _es_buena(self, clave: str, ahora: float) -> bool:
        marca = self._buenas.get(clave)
        if marca is None:
            return False
        if ahora - marca > self._ips_buenas_ttl:
            del self._buenas[clave]
            return False
        return True

    def es_ip_buena(self, ip: str) -> bool:
        with self._lock:
            return self._es_buena(clave_ip(ip), self.reloj())

    def fallos_consecutivos(self, ip: str) -> int:
        with self._lock:
            entrada = self._estado.get(clave_ip(ip))
            return entrada["fallos"] if entrada else 0

    def segundos_bloqueado(self, ip: str) -> int:
        """Segundos restantes del bloqueo; 0 si no hay o si la IP es 'buena' (exenta)."""
        clave = clave_ip(ip)
        with self._lock:
            ahora = self.reloj()
            if self._es_buena(clave, ahora):
                return 0
            entrada = self._estado.get(clave)
            if not entrada:
                return 0
            restante = entrada["bloqueado_hasta"] - ahora
            return math.ceil(restante) if restante > 0 else 0

    def primer_429(self, ip: str) -> bool:
        """True una sola vez por bloqueo: para loguear sólo el primer 429 de cada bloqueo."""
        with self._lock:
            entrada = self._estado.get(clave_ip(ip))
            if entrada and not entrada["avisado"]:
                entrada["avisado"] = True
                return True
            return False

    def fallo(
        self, ip: str, max_fallos: int, ventana_seg: int, bloqueo_base_seg: int
    ) -> ResultadoFallo:
        clave = clave_ip(ip)
        with self._lock:
            ahora = self.reloj()
            entrada = self._estado.get(clave)
            if entrada is None or ahora - entrada["ultimo"] > OLVIDO_REINCIDENCIA_SEG:
                entrada = {
                    "fallos": 0,
                    "desde": ahora,
                    "ultimo": ahora,
                    "strikes": 0,
                    "bloqueado_hasta": 0.0,
                    "avisado": False,
                }
                self._estado[clave] = entrada
            if ahora - entrada["desde"] > ventana_seg:
                entrada["fallos"] = 0
                entrada["desde"] = ahora
            entrada["ultimo"] = ahora
            entrada["fallos"] += 1
            bloqueo = 0
            if entrada["fallos"] >= max_fallos:
                entrada["strikes"] += 1
                entrada["fallos"] = 0
                bloqueo = int(
                    min(bloqueo_base_seg * (2 ** (entrada["strikes"] - 1)), BLOQUEO_MAXIMO_SEG)
                )
                entrada["bloqueado_hasta"] = ahora + bloqueo
                entrada["avisado"] = False
            self._estado.move_to_end(clave)
            self._expulsar_excedente()
            return ResultadoFallo(entrada["fallos"], bloqueo)

    def exito(self, ip: str) -> None:
        clave = clave_ip(ip)
        with self._lock:
            ahora = self.reloj()
            self._estado.pop(clave, None)
            self._buenas[clave] = ahora
            self._buenas.move_to_end(clave)
            while len(self._buenas) > self._ips_buenas_max:
                self._buenas.popitem(last=False)

    def _expulsar_excedente(self) -> None:
        if len(self._estado) <= self._max_entradas:
            return
        objetivo = int(self._max_entradas * CAPACIDAD_TRAS_EXPULSION)
        while len(self._estado) > objetivo:
            self._estado.popitem(last=False)


limitador = LimitadorFallos()


# --- dependencias de FastAPI ---------------------------------------------------------------------------


def canal_seguro(request: Request, settings: Settings = Depends(get_settings)) -> None:
    """Falla cerrada: sin HTTPS efectivo, 403 (a menos que terminal_requiere_https sea false)."""
    if settings.terminal_requiere_https and esquema_efectivo(request, settings) != "https":
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_HTTPS_REQUERIDO)


def _no_autorizado() -> HTTPException:
    return HTTPException(
        status.HTTP_401_UNAUTHORIZED,
        MENSAJE_CREDENCIAL_INVALIDA,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _llave_de(authorization: str | None) -> str | None:
    if not authorization or not authorization.startswith("Bearer "):
        return None
    llave = authorization.removeprefix("Bearer ")
    return llave if FORMATO_LLAVE.fullmatch(llave) else None


def _rechazar(ip: str, settings: Settings, motivo: str) -> HTTPException:
    resultado = limitador.fallo(
        ip,
        settings.terminal_max_fallos_por_ip,
        settings.terminal_ventana_fallos_seg,
        settings.terminal_bloqueo_base_seg,
    )
    # Poco ruido: WARNING sólo en el primer fallo de la racha y al disparar un bloqueo; el resto,
    # DEBUG (un atacante no debe poder llenar el log).
    if resultado.bloqueo_seg:
        logger.warning(
            "terminal: IP %s bloqueada %s s tras %s respuestas 401 consecutivas (%s)",
            ip,
            resultado.bloqueo_seg,
            settings.terminal_max_fallos_por_ip,
            motivo,
        )
    elif resultado.fallos == 1:
        logger.warning("terminal: 401 (%s) desde %s", motivo, ip)
    else:
        logger.debug("terminal: 401 (%s) desde %s", motivo, ip)
    return _no_autorizado()


def get_terminal_actual(
    request: Request,
    authorization: str | None = Header(default=None),
    _canal: None = Depends(canal_seguro),  # antes que `db`: sin HTTPS no se crea ni el cliente
    settings: Settings = Depends(get_settings),
    db: Client = Depends(get_service_client),
) -> TerminalIdentity:
    ip = ip_cliente(request, settings)

    bloqueo = limitador.segundos_bloqueado(ip)
    if bloqueo:
        if limitador.primer_429(ip):
            logger.warning("terminal: 429 (IP %s bloqueada por intentos fallidos)", ip)
        else:
            logger.debug("terminal: 429 (IP %s bloqueada por intentos fallidos)", ip)
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            MENSAJE_DEMASIADOS_INTENTOS,
            headers={"Retry-After": str(bloqueo)},
        )

    llave = _llave_de(authorization)
    if llave is None:
        # formato inválido: se corta ANTES de tocar la base
        raise _rechazar(ip, settings, "credencial ausente o mal formada")

    try:
        datos = (
            db.postgrest.schema("tiempo")
            .rpc("fn_terminal_autenticar", {"p_hash": hash_llave(llave), "p_ip": ip})
            .execute()
            .data
        )
    except APIError as error:
        # 42501 (grant/policy rota) u otro error de la base: no es una credencial inválida.
        logger.error("terminal: la autenticación falló en la base (código %s)", error.code)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None
    except Exception as error:  # red, timeout, etc.
        logger.error("terminal: la autenticación no pudo consultar la base (%s)", type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None

    if not datos:
        raise _rechazar(ip, settings, "credencial desconocida, revocada o terminal inactiva")

    try:
        identidad = TerminalIdentity(
            id=datos["terminal_id"],
            serie=datos["serie"],
            credencial_id=datos["credencial_id"],
            ip_cambio=datos["ip_cambio"],
        )
    except (KeyError, TypeError, ValidationError):
        logger.error("terminal: fn_terminal_autenticar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None

    limitador.exito(ip)
    if identidad.ip_cambio:
        # alarma para el tablero (SCJ-DEC-12 §1/M6), no un bloqueo
        logger.warning(
            "terminal: credencial %s usada desde una IP distinta de la anterior (%s)",
            identidad.credencial_id,
            ip,
        )
    return identidad


class CabecerasTerminal:
    """Middleware ASGI puro: HSTS (SCJ-DEC-12 §7) y `Cache-Control: no-store` en TODA respuesta de /api/terminal/*, incluidos los
    4xx/5xx de los handlers de excepciones y el 413 del límite de cuerpo. Las respuestas 500 de excepciones no capturadas las genera
    ServerErrorMiddleware, por fuera de este middleware: el handler global de main.py agrega los mismos encabezados."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not es_ruta_terminal(get_route_path(scope)):
            return await self.app(scope, receive, send)

        async def send_con_cabeceras(mensaje):
            if mensaje["type"] == "http.response.start":
                cabeceras = list(mensaje.get("headers", []))
                existentes = {k.lower() for k, _ in cabeceras}
                if b"strict-transport-security" not in existentes:
                    cabeceras.append((b"strict-transport-security", HSTS.encode()))
                if b"cache-control" not in existentes:
                    cabeceras.append((b"cache-control", b"no-store"))
                mensaje = {**mensaje, "headers": cabeceras}
            await send(mensaje)

        await self.app(scope, receive, send_con_cabeceras)


LIMITE_CUERPO_TERMINAL = 256 * 1024  # 256 KB (igual que client_max_body_size de nginx, SCJ-DEC-12 §7); un lote de 200 marcas pesa ≈ 40 KB
MENSAJE_CUERPO_GRANDE = "El cuerpo de la petición es demasiado grande."


class LimiteCuerpoTerminal:
    """Middleware ASGI puro: en /api/terminal/* responde 413 a un cuerpo mayor al límite ANTES de parsear JSON y ANTES de
    autenticar, tanto por `Content-Length` como contando los bytes que llegan (un cliente que miente o usa chunked no lo evita).
    No lee el cuerpo entero en memoria. Al pasarse del límite corta el flujo (el app ve una desconexión) y esta clase reemplaza
    cualquier respuesta que el app intente dar por el 413 (FastAPI convertiría el corte en un 400)."""

    def __init__(self, app, limite: int = LIMITE_CUERPO_TERMINAL) -> None:
        self.app = app
        self.limite = limite

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not es_ruta_terminal(get_route_path(scope)):
            return await self.app(scope, receive, send)
        declarado = dict(scope["headers"]).get(b"content-length")
        if declarado and declarado.isdigit() and int(declarado) > self.limite:
            return await self._rechazar(send)

        recibido = 0
        excedido = False
        respondido = False

        async def receive_limitado():
            nonlocal recibido, excedido
            if excedido:
                return {"type": "http.disconnect"}
            mensaje = await receive()
            if mensaje["type"] == "http.request":
                recibido += len(mensaje.get("body", b""))
                if recibido > self.limite:
                    excedido = True
                    return {"type": "http.disconnect"}
            return mensaje

        async def send_vigilado(mensaje):
            nonlocal respondido
            if excedido:
                if not respondido:
                    respondido = True
                    await self._rechazar(send)
                return  # se descarta todo lo demás que el app quiera enviar
            await send(mensaje)

        await self.app(scope, receive_limitado, send_vigilado)
        if excedido and not respondido:  # el app terminó sin responder
            await self._rechazar(send)

    async def _rechazar(self, send):
        cuerpo = b'{"detail":"' + MENSAJE_CUERPO_GRANDE.encode() + b'"}'
        await send(
            {
                "type": "http.response.start",
                "status": 413,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(cuerpo)).encode()),
                    (b"strict-transport-security", HSTS.encode()),
                    (b"cache-control", b"no-store"),
                ],
            }
        )
        await send({"type": "http.response.body", "body": cuerpo})


def advertir_despliegue(entorno: Mapping[str, str]) -> list[str]:
    """Revisa al arrancar la configuración de proxies del entorno y emite un WARNING por cada
    problema (devuelve los mensajes). Criterio: se ADVIERTE, no se falla el arranque: una mala
    configuración de proxies no debe tumbar todo el backend (personas, tiempo, batches); lo que
    protege de verdad es que la confianza en las cabeceras se acota en tiempo de petición
    (TERMINAL_PROXIES_CONFIANZA, entradas /0 ignoradas, y por defecto no se confía en nadie)."""
    avisos: list[str] = []
    permitidas = entorno.get("FORWARDED_ALLOW_IPS", "")
    if "*" in [parte.strip() for parte in permitidas.split(",")]:
        avisos.append(
            "FORWARDED_ALLOW_IPS contiene '*': cualquier cliente podría falsificar X-Forwarded-For y "
            "X-Forwarded-Proto ante uvicorn. Limítalo a la IP del proxy (SCJ-DEC-12 §7)."
        )
    for entrada in entorno.get("TERMINAL_PROXIES_CONFIANZA", "").split(","):
        entrada = entrada.strip()
        try:
            if entrada and ipaddress.ip_network(entrada, strict=False).prefixlen == 0:
                avisos.append(
                    f"TERMINAL_PROXIES_CONFIANZA contiene {entrada}: confía en todo el mundo; se "
                    "ignora (SCJ-DEC-12 §7)."
                )
        except ValueError:
            continue
    for aviso in avisos:
        logger.warning("terminal: %s", aviso)
    return avisos
