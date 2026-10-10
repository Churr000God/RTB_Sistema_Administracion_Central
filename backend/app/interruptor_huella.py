"""Interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md): lógica PURA y sin I/O.

- `rango_de_fechas` / `instante_de_fecha`: «activo hasta» es una FECHA civil de America/Mexico_City que vence a las 23:59:59 de ese día. UNA sola función calcula el rango
  y la usan el GET (que lo devuelve) y la validación del POST (que recalcula con su propio reloj y nunca confía en lo que mostró el GET).
- `normalizar_estado`: valida la forma del JSON de `fn_terminal_inferir_huella_estado()` (una forma ilegible NO se interpreta como «apagado»).
- `alarma_de`: función pura sobre ese JSON; la regla NO depende del conteo de activaciones ni de nombres.
- `construir_estado`: la forma pública del estado (sin uuid; el nombre solo si el llamador lo puede ver)."""

from datetime import date, datetime, time, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

PREFIJO = "/api/terminales/configuracion/activacion-por-huella"
ZONA_MEXICO = ZoneInfo("America/Mexico_City")
TOPE_DIAS = 30                 # el de la base (fn_terminal_inferir_huella_cambiar / _estado)
MARGEN_S = 60                  # holgura del backend frente al now() de la base
FIN_DE_DIA = time(23, 59, 59)
NOTA_MINIMO, NOTA_MAXIMO = 10, 500
CENTINELA = "1970-01-01T00:00:00Z"

MENSAJE_ALARMA_SISTEMAS = "Avisa a Sistemas."
MENSAJES_MOTIVO: dict[str, str | None] = {
    "apagado": None,
    "vencido": "El vencimiento ya pasó; el interruptor está apagado.",
    "sin_respaldo_de_la_funcion": "Se detectó un cambio hecho fuera de esta pantalla; el interruptor quedó apagado. Avisa a Sistemas.",
    "vigencias_inconsistentes": "El ajuste está en un estado inconsistente; el interruptor quedó apagado. Avisa a Sistemas.",
    "valor_invalido": "El ajuste tiene un valor no válido; el interruptor quedó apagado. Avisa a Sistemas.",
    "hasta_ilegible": "El ajuste tiene un valor no válido; el interruptor quedó apagado. Avisa a Sistemas.",
    "hasta_excede_tope": "El ajuste tiene un valor no válido; el interruptor quedó apagado. Avisa a Sistemas.",
    "error": "No se pudo leer el ajuste; el interruptor quedó apagado. Avisa a Sistemas.",
}
MENSAJE_SIN_RESPALDO_ENCENDIDO = "El interruptor está encendido pero su último cambio no quedó registrado como debe. Avisa a Sistemas."
MENSAJE_ESTADO_ILEGIBLE = "No se pudo leer el ajuste; el interruptor quedó apagado. Avisa a Sistemas."
MOTIVOS_FALLA_CERRADA = frozenset({"vigencias_inconsistentes", "valor_invalido", "hasta_ilegible", "hasta_excede_tope", "error"})


# --- «activo hasta» -------------------------------------------------------------------------------------------------------------


def instante_de_fecha(fecha: date) -> datetime:
    """El instante UTC en que vence una fecha civil de México: ese día a las 23:59:59 hora de México."""
    return datetime.combine(fecha, FIN_DE_DIA, tzinfo=ZONA_MEXICO).astimezone(timezone.utc)


def rango_de_fechas(ahora: datetime) -> tuple[date, date]:
    """(fecha_minima, fecha_maxima) que se pueden elegir. `p_hasta` debe ser futuro y a lo más a 30 días contra el `now()` de LA BASE: se deja una holgura de 60 s para que el reloj
    del backend no cruce el tope por una carrera. minima = hoy (México) si todavía falta más de la holgura para su 23:59:59; si no, mañana. maxima = la última fecha cuyo 23:59:59 es
    <= ahora + 30 días - holgura."""
    ahora = ahora.astimezone(timezone.utc)
    hoy = ahora.astimezone(ZONA_MEXICO).date()
    minima = hoy if instante_de_fecha(hoy) > ahora + timedelta(seconds=MARGEN_S) else hoy + timedelta(days=1)
    limite = ahora + timedelta(days=TOPE_DIAS) - timedelta(seconds=MARGEN_S)
    maxima = limite.astimezone(ZONA_MEXICO).date()
    if instante_de_fecha(maxima) > limite:
        maxima -= timedelta(days=1)
    return minima, maxima


def fecha_valida(fecha: date, ahora: datetime) -> bool:
    minima, maxima = rango_de_fechas(ahora)
    return minima <= fecha <= maxima


# --- estado -----------------------------------------------------------------------------------------------------------------------

_BOOLEANOS = ("activo", "vencido", "sin_registro")
_TEXTOS_O_NULO = ("motivo", "valor", "hasta", "encendido_por", "encendido_en")


def normalizar_estado(crudo: Any) -> dict | None:
    """El JSON de `fn_terminal_inferir_huella_estado()` si tiene la forma esperada; None si es ilegible (tipos o claves que no son)."""
    if not isinstance(crudo, dict):
        return None
    for clave in _BOOLEANOS:
        if type(crudo.get(clave)) is not bool:
            return None
    for clave in _TEXTOS_O_NULO:
        if crudo.get(clave) is not None and not isinstance(crudo.get(clave), str):
            return None
    via = crudo.get("ultimo_cambio_via_funcion")
    if via is not None and type(via) is not bool:
        return None
    if crudo["activo"] and crudo.get("motivo") is not None:
        return None
    if not crudo["activo"] and not crudo.get("motivo"):
        return None
    return {**{k: crudo.get(k) for k in _BOOLEANOS + _TEXTOS_O_NULO}, "ultimo_cambio_via_funcion": via}


def estado_derivado(estado: dict) -> str:
    if estado["activo"]:
        return "encendido"
    if estado["motivo"] == "vencido":
        return "vencido"
    if estado["motivo"] == "apagado":
        return "apagado"
    return "inconsistente"


def alarma_de(crudo: Any) -> dict:
    """Alarma sobre el JSON de la base (función PURA, sin I/O). La regla no depende del conteo ni de nombres, y un estado ilegible NUNCA es «sin alarma»."""
    sin = {"activa": False, "nivel": None, "codigo": None, "mensaje": None}
    estado = normalizar_estado(crudo)
    if estado is None:
        return {"activa": True, "nivel": "revisar", "codigo": "estado_ilegible", "mensaje": MENSAJE_ESTADO_ILEGIBLE}
    if estado["motivo"] == "sin_respaldo_de_la_funcion":
        return {"activa": True, "nivel": "atender", "codigo": "sin_respaldo_de_la_funcion", "mensaje": MENSAJES_MOTIVO["sin_respaldo_de_la_funcion"]}
    if estado["activo"] and estado["ultimo_cambio_via_funcion"] is False:
        return {"activa": True, "nivel": "atender", "codigo": "cambio_fuera_de_la_funcion", "mensaje": MENSAJE_SIN_RESPALDO_ENCENDIDO}
    if estado["activo"] and estado["sin_registro"]:
        return {"activa": True, "nivel": "atender", "codigo": "sin_registro", "mensaje": MENSAJE_SIN_RESPALDO_ENCENDIDO}
    motivo = estado["motivo"]
    if motivo in MOTIVOS_FALLA_CERRADA:
        return {"activa": True, "nivel": "revisar", "codigo": motivo, "mensaje": MENSAJES_MOTIVO[motivo]}
    if not estado["activo"] and motivo not in ("apagado", "vencido"):
        return {"activa": True, "nivel": "revisar", "codigo": "estado_ilegible", "mensaje": MENSAJE_ESTADO_ILEGIBLE}   # un motivo que no conocemos: nunca silencio
    return sin


def _instante(texto: str | None) -> datetime | None:
    if not texto:
        return None
    try:
        valor = datetime.fromisoformat(texto.replace("Z", "+00:00"))
    except ValueError:
        return None
    return valor.astimezone(timezone.utc) if valor.tzinfo is not None else None


def _iso_utc(instante: datetime | None) -> str | None:
    return instante.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if instante else None


def construir_estado(
    crudo: Any, *, nombre_autor: str | None, altas_activadas: int | None, requisitos: dict, ahora: datetime
) -> dict | None:
    """La forma pública del estado (CONTRATO §1) o None si el JSON de la base es ilegible. NUNCA lleva el uuid de `encendido_por`: solo `nombre_autor` (ya resuelto por quien llama y
    solo si el llamador puede verlo)."""
    estado = normalizar_estado(crudo)
    if estado is None:
        return None
    derivado = estado_derivado(estado)
    hasta = _instante(estado["hasta"])
    if derivado not in ("encendido", "vencido") or (hasta is not None and hasta.year <= 1970):
        hasta = None
    minima, maxima = rango_de_fechas(ahora)
    encendido_en = _instante(estado["encendido_en"])
    return {
        "activo": estado["activo"],
        "estado": derivado,
        "motivo": estado["motivo"],
        "mensaje": MENSAJES_MOTIVO.get(estado["motivo"]) if estado["motivo"] else None,
        "hasta": _iso_utc(hasta),
        "hasta_fecha": hasta.astimezone(ZONA_MEXICO).date().isoformat() if hasta else None,
        "vencido": estado["vencido"],
        "encendido_por_nombre": nombre_autor,
        "encendido_en": _iso_utc(encendido_en),
        "altas_activadas_desde_encendido": altas_activadas if derivado == "encendido" and encendido_en is not None else None,
        "maximo_dias": TOPE_DIAS,
        "fecha_minima": minima.isoformat(),
        "fecha_maxima": maxima.isoformat(),
        "nota_minimo": NOTA_MINIMO,
        "nota_maximo": NOTA_MAXIMO,
        "requisitos": requisitos,
        "alarma": alarma_de(crudo),
    }


# --- cabeceras --------------------------------------------------------------------------------------------------------------------


class SinCacheInterruptor:
    """Middleware ASGI: toda respuesta bajo PREFIJO (éxito, 4xx, 5xx de los handlers) lleva `Cache-Control: no-store`: lleva nombres y notas de texto libre (F1 de security)."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or not scope["path"].startswith(PREFIJO):
            await self.app(scope, receive, send)
            return

        async def enviar(mensaje) -> None:
            if mensaje["type"] == "http.response.start":
                cabeceras = [(k, v) for k, v in mensaje.get("headers", []) if k.lower() not in (b"cache-control", b"pragma")]
                cabeceras += [(b"cache-control", b"no-store"), (b"pragma", b"no-cache")]
                mensaje = {**mensaje, "headers": cabeceras}
            await send(mensaje)

        await self.app(scope, receive, enviar)
