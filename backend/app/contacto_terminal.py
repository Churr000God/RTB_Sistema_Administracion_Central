"""Estado de contacto de una terminal con el servidor (latido del puente): UNA sola función para la insignia de Terminales y para la tarjeta 15 del tablero de anomalías
(CONTRATO_API_TERMINALES_PAQUETE_2.md §9). Ninguna otra parte reimplementa el umbral."""

import logging
from datetime import datetime

from app.fecha_local import a_datetime

logger = logging.getLogger(__name__)


def segundos_sin_contacto(ultimo: datetime | None, ahora: datetime) -> int | None:
    if ultimo is None:
        return None
    return max(0, int((ahora - ultimo).total_seconds()))


def estado_contacto(activa: bool, ultimo_contacto_en: datetime | None, ahora: datetime, umbral_seg: int) -> tuple[str, int | None]:
    """(nivel, segundos_sin_contacto). Prioridad: inactiva > nunca > sin_contacto > en_linea. Se calcula AL LEER (no hay estado persistido que olvidar actualizar). Un contacto
    «en el futuro» (reloj desfasado) cuenta como 0 s, no como negativo."""
    if not activa:
        return "inactiva", segundos_sin_contacto(ultimo_contacto_en, ahora)
    if ultimo_contacto_en is None:
        return "nunca", None
    segundos = segundos_sin_contacto(ultimo_contacto_en, ahora)
    return ("sin_contacto" if segundos >= umbral_seg else "en_linea"), segundos


def ultimo_contacto(fila: dict) -> tuple[datetime | None, bool]:
    """(último contacto, ilegible). Un valor no parseable se trata como «nunca» para la insignia (con ERROR en el log) y se avisa con `ilegible=True` para quien necesite distinguirlo."""
    bruto = fila.get("ultimo_contacto_en")
    if not bruto:
        return None, False
    try:
        return a_datetime(bruto), False
    except (ValueError, TypeError, AttributeError):
        logger.error("terminal %s: ultimo_contacto_en no parseable; se trata como 'nunca'", fila.get("id"))
        return None, True
