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


# --- Excepciones de día cerrado (86_*.sql; SCJ15) ---------------------------------------------------------

CODIGO_SCJ15 = "SCJ15"
CODIGO_MOTIVO_INVALIDO = "22023"
HINT_SIN_PERMISO = "sin_permiso"
HINT_MOTIVO_INVALIDO = "motivo_invalido"

MENSAJE_DIA_CERRADO_REQUIERE_REVISION = (
    "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día "
    "(o, si el día ya está revisado, descarta la marca tardía)."
)
MENSAJE_EXCEPCION_INMUTABLE = "La excepción no se puede alterar."
MENSAJE_TRAMO_INCOHERENTE = "La marca no corresponde a la persona o al día del tramo."
MENSAJE_DIA_NO_REVISADO = (
    "El día todavía no está revisado: revísalo en vez de descartar la marca."
)
MENSAJE_EXCEPCION_NO_DESCARTABLE = (
    "Esta excepción no se puede descartar: no es una marca tardía de día cerrado, o ya está "
    "resuelta por otra vía."
)
MENSAJE_MARCA_EN_TRAMO = (
    "Esta marca ya forma parte de un tramo: no se puede corregir su hora desde aquí. Revisa el día."
)
MENSAJE_SCJ15_GENERICO = "La operación no es válida para el estado actual de la excepción o del día."
MENSAJE_SIN_PERMISO = "No tienes permiso para esta acción."
MENSAJE_MOTIVO_INVALIDO = "El motivo es obligatorio."

_SCJ15_POR_HINT = {
    "dia_cerrado_requiere_revision": (status.HTTP_409_CONFLICT, MENSAJE_DIA_CERRADO_REQUIERE_REVISION),
    "excepcion_columna_inmutable": (status.HTTP_409_CONFLICT, MENSAJE_EXCEPCION_INMUTABLE),
    "excepcion_motivo_inmutable": (status.HTTP_409_CONFLICT, MENSAJE_EXCEPCION_INMUTABLE),
    "tramo_incoherente": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TRAMO_INCOHERENTE),
    "dia_no_revisado": (status.HTTP_409_CONFLICT, MENSAJE_DIA_NO_REVISADO),
    "excepcion_no_descartable": (status.HTTP_409_CONFLICT, MENSAJE_EXCEPCION_NO_DESCARTABLE),
    # 87_*.sql: BEFORE INSERT en tiempo.correccion; la marca es apertura/cierre de algún tramo. Mismo 409 fijo
    # que el guard previo del backend (marca_en_tramo.py). Consecuencia de producto: después de cierre_dia casi
    # ninguna marca es corregible por esta vía; la UI debe explicar "esta marca ya está en un tramo: revisa el
    # día o usa captura manual".
    "marca_en_tramo": (status.HTTP_409_CONFLICT, MENSAJE_MARCA_EN_TRAMO),
}


def traducir_error_dia_cerrado(error: APIError) -> HTTPException | None:
    """Traduce los errores de 86_*.sql (SCJ15 por HINT, 42501/sin_permiso, 22023/motivo_invalido) a
    una HTTPException con un mensaje FIJO: el texto de la base nunca va a la respuesta (puede traer
    ids internos). Devuelve None si el error no es de esta familia, para que el llamador siga con sus
    propias reglas.

    Ojo con cuándo llega SCJ15/dia_cerrado_requiere_revision: el constraint trigger es DEFERRABLE
    INITIALLY DEFERRED y dispara al COMMIT, que PostgREST ejecuta dentro de la MISMA petición HTTP
    (una petición = una transacción). Por eso el error llega como la respuesta de la petición completa
    (p. ej. POST /api/correcciones) y supabase-py lo levanta como APIError con code=SCJ15 y el hint
    en `error.hint`, igual que uno inmediato."""
    if error.code == CODIGO_SCJ15:
        estado, mensaje = _SCJ15_POR_HINT.get(
            error.hint or "", (status.HTTP_409_CONFLICT, MENSAJE_SCJ15_GENERICO)
        )
        return HTTPException(estado, mensaje)
    if error.code == PERMISO_DENEGADO:
        if error.hint != HINT_SIN_PERMISO:
            # un 42501 sin el hint del RPC es una policy o un grant (no un usuario sin permiso)
            logger.error("la base respondió 42501 sin hint; revisar grants/policies")
        return HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO)
    if error.code == CODIGO_MOTIVO_INVALIDO and error.hint == HINT_MOTIVO_INVALIDO:
        return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MOTIVO_INVALIDO)
    return None


def manejar_error_dia_cerrado(error: APIError) -> NoReturn:
    """Debe llamarse desde un `except APIError`. Levanta la traducción o relanza el error original
    (que cae al handler genérico de main.py, sin texto)."""
    traduccion = traducir_error_dia_cerrado(error)
    if traduccion is not None:
        raise traduccion from None
    raise error
