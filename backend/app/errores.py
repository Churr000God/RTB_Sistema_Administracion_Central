"""Helper compartido para traducir violaciones de unicidad de Postgres (23505) a HTTPException.

Cada router valida unicidad por su cuenta con un `try/except APIError` alrededor del
insert/update -- este helper sólo evita repetir el `if error.code == UNIQUE_VIOLATION` en cada
uno. El mensaje (MENSAJE_*) y el status_code siguen siendo decisión de cada router.
"""

import logging
from typing import NoReturn

from fastapi import HTTPException, status
from postgrest.exceptions import APIError

UNIQUE_VIOLATION = "23505"


def manejar_violacion_unicidad(
    error: APIError,
    mensaje: str,
    status_code: int = status.HTTP_409_CONFLICT,
) -> NoReturn:
    """Debe llamarse desde un `except APIError as error:`. Si error.code es 23505, levanta
    HTTPException(status_code, mensaje); si no, relanza el APIError original sin tocar."""
    if error.code == UNIQUE_VIOLATION:
        raise HTTPException(status_code, mensaje) from error
    raise error


# --- Terminal / puente (SCJ-DEC-12 §3) -----------------------------------------------------------

logger = logging.getLogger("app.errores")

CODIGO_TERMINAL_NO_VALIDA = "SCJ12"
HINT_TERMINAL_NO_VALIDA = "terminal_no_valida"
PERMISO_DENEGADO = "42501"

MENSAJE_CREDENCIAL_TERMINAL_INVALIDA = "Credencial de terminal inválida."
MENSAJE_TERMINAL_NO_DISPONIBLE = "Servicio no disponible; reintenta."
MENSAJE_DATOS_INVALIDOS = "Los datos enviados no son válidos."


def manejar_error_terminal(error: APIError) -> NoReturn:
    """Traduce los errores de la base de los endpoints de /api/terminal/* SIN retransmitir su texto
    (puede traer ids internos, SCJ-DEC-11 riesgo 3). Debe llamarse desde un `except APIError`. Lo
    no reconocido se relanza y cae al handler genérico de main.py (500 sin texto).

    - SCJ12/terminal_no_valida (la terminal se desactivó entre la autenticación y la llamada)
      -> 401: la credencial dejó de valer.
    - 42501 -> 503 y SIEMPRE un ERROR en el log: un 42501 inesperado es un grant o una policy rota,
      no una terminal sin permiso.
    - clase 22 (dato fuera de rango o mal formado) -> 422."""
    if error.code == CODIGO_TERMINAL_NO_VALIDA and error.hint == HINT_TERMINAL_NO_VALIDA:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            MENSAJE_CREDENCIAL_TERMINAL_INVALIDA,
            headers={"WWW-Authenticate": "Bearer"},
        ) from None
    if error.code == PERMISO_DENEGADO:
        logger.error("terminal: la base respondió 42501 (permiso denegado); revisar grants/policies")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_TERMINAL_NO_DISPONIBLE) from None
    if error.code and error.code.startswith("22"):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DATOS_INVALIDOS) from None
    raise error
