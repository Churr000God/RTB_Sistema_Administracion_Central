"""Helper compartido para traducir violaciones de unicidad de Postgres (23505) a HTTPException.

Cada router valida unicidad por su cuenta con un `try/except APIError` alrededor del
insert/update -- este helper sólo evita repetir el `if error.code == UNIQUE_VIOLATION` en cada
uno. El mensaje (MENSAJE_*) y el status_code siguen siendo decisión de cada router.
"""

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
