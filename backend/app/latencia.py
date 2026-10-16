"""Latencia por petición: UNA línea INFO por petición en el logger `app.latencia` y, aparte, un WARNING AGREGADO por minuto con cuántas tardaron más de 2 s y más de 5 s.

Formato exacto de la línea:  `<MÉTODO> <plantilla de ruta> status=<código> duracion_ms=<entero>`
    p. ej.  `GET /api/personas/{persona_id} status=200 duracion_ms=153`

Qué NUNCA lleva: el path con ids reales, la query, cabeceras, cuerpo, tokens, correos ni ids. La ruta es la PLANTILLA que declaró el router (`/api/personas/{persona_id}`); una petición sin
ruta (404) sale como `(sin ruta)`. Excluidos: `/salud` y `/api/terminal/*` (los latidos, la cola y las marcas del puente: inundarían el log). Es un middleware ASGI puro (sin librerías
nuevas); la duración usa el reloj monotónico; una excepción no capturada se registra con status 500 y se re-lanza SIN alterar la respuesta; y nada de lo que hace aquí puede romper una
petición (todo el registro va dentro de try/except).

Dos salvedades de diseño (sin riesgo de seguridad): (1) el WARNING agregado por minuto NO lo emite un hilo ni un temporizador: solo sale cuando llega OTRA petición en el minuto siguiente
(si el tráfico se detiene, el resumen del último minuto se queda pendiente); (2) `configurar_registro_de_latencia()` agrega un manejador propio solo si, al importar `main`, la raíz no
tiene ninguno; si algo configura la raíz DESPUÉS de importar `main`, la misma línea podría salir dos veces (manejador propio + raíz): es duplicación cosmética, no filtración."""

import logging
import threading
import time

from starlette._utils import get_route_path

from app.terminal_auth import es_ruta_terminal

logger = logging.getLogger("app.latencia")

def configurar_registro_de_latencia() -> None:
    """uvicorn solo configura SUS loggers: sin esto la raíz queda en WARNING y sin manejador, y las líneas INFO de `app.latencia` no saldrían nunca. Fija el nivel INFO de este logger
    y, SOLO si nadie configuró la raíz (producción con uvicorn), le pone un manejador a stderr con hora. Si la raíz ya tiene manejadores (pruebas, otra configuración) no duplica nada.
    Idempotente."""
    logger.setLevel(logging.INFO)
    if not logging.getLogger().handlers and not logger.handlers:
        manejador = logging.StreamHandler()
        manejador.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        logger.addHandler(manejador)


UMBRAL_LENTA_S = 2.0
UMBRAL_MUY_LENTA_S = 5.0
RUTAS_EXCLUIDAS = frozenset({"/salud"})
SIN_RUTA = "(sin ruta)"


class AgregadorDeLentas:
    """Cuenta por minuto las peticiones >2 s y >5 s y emite UN WARNING agregado cuando cambia el minuto (lo dispara la siguiente petición: sin hilos ni temporizadores)."""

    def __init__(self, reloj=time.monotonic) -> None:
        self._reloj, self._cerrojo = reloj, threading.Lock()
        self._minuto: int | None = None
        self._total = self._lentas = self._muy_lentas = 0

    def registrar(self, duracion_s: float) -> None:
        resumen = None
        with self._cerrojo:
            minuto = int(self._reloj() // 60)
            if self._minuto is not None and minuto != self._minuto and (self._lentas or self._muy_lentas):
                resumen = (self._total, self._lentas, self._muy_lentas)
            if minuto != self._minuto:
                self._minuto, self._total, self._lentas, self._muy_lentas = minuto, 0, 0, 0
            self._total += 1
            self._lentas += duracion_s > UMBRAL_LENTA_S
            self._muy_lentas += duracion_s > UMBRAL_MUY_LENTA_S
        if resumen is not None:
            logger.warning("latencia: en el minuto anterior %d de %d peticiones tardaron más de %g s y %d más de %g s", resumen[1], resumen[0], UMBRAL_LENTA_S, resumen[2], UMBRAL_MUY_LENTA_S)


def plantilla_de_ruta(scope) -> str:
    """La plantilla que declaró el router (`/api/personas/{persona_id}`), nunca el path real; solo existe si Starlette resolvió una ruta."""
    ruta = scope.get("route")
    plantilla = getattr(ruta, "path", None)
    return plantilla if isinstance(plantilla, str) and plantilla.startswith("/") else SIN_RUTA


def linea_de_latencia(metodo: str, plantilla: str, status: int, duracion_ms: int) -> str:
    return f"{metodo} {plantilla} status={status} duracion_ms={duracion_ms}"


class MedirLatencia:
    def __init__(self, app, reloj=time.monotonic, agregador: AgregadorDeLentas | None = None) -> None:
        self.app, self._reloj = app, reloj
        self._agregador = agregador or AgregadorDeLentas()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        try:
            ruta = get_route_path(scope)
            excluida = ruta in RUTAS_EXCLUIDAS or es_ruta_terminal(ruta)
        except Exception:  # noqa: BLE001
            excluida = False
        if excluida:
            return await self.app(scope, receive, send)

        inicio = self._reloj()
        estado: list[int] = []

        async def send_observado(mensaje):
            if mensaje["type"] == "http.response.start" and not estado:
                estado.append(int(mensaje["status"]))
            await send(mensaje)

        codigo = None
        try:
            await self.app(scope, receive, send_observado)
        except Exception:
            codigo = 500          # el 500 lo arma ServerErrorMiddleware por fuera: aquí solo se registra y se re-lanza
            raise
        except BaseException:
            codigo = 499          # cancelación (el cliente cerró la conexión)
            raise
        finally:
            self._registrar(scope, estado[0] if estado else (codigo or 499), self._reloj() - inicio)

    def _registrar(self, scope, status: int, duracion_s: float) -> None:
        try:
            logger.info("%s", linea_de_latencia(str(scope.get("method", "?"))[:10], plantilla_de_ruta(scope), status, int(duracion_s * 1000)))
            self._agregador.registrar(duracion_s)
        except Exception:  # noqa: BLE001 - medir la latencia nunca puede romper una petición
            pass
