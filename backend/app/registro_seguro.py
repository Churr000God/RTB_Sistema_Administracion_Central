"""Registro (logs) sin valores: UNA política para el manejador global, los jobs y los batches (security A2/L1/L2).

El mensaje de una excepción puede traer datos de la petición o de la fila (employee_no, evento_id, una nota, una URL con parámetros, el `input` de una ResponseValidationError…). Por eso:
- APIError (PostgREST): solo el SQLSTATE;
- cualquier otra excepción: tipo y marcos de la traza, NUNCA el texto del mensaje ni el de sus causas;
- el mensaje completo solo para una excepción PROPIA que lo declare explícitamente (atributo de clase `mensaje_registrable = True`): es texto escrito por este código, no datos."""

import traceback

from postgrest.exceptions import APIError

# (se conserva para quien lo importaba) paquetes cuyas excepciones llevan datos en su mensaje
PAQUETES_CON_MENSAJE_SENSIBLE = frozenset({"postgrest", "supabase", "gotrue", "supabase_auth", "storage3", "realtime", "supafunc", "httpx", "httpcore"})


def tiene_mensaje_registrable(exc: BaseException) -> bool:
    """Solo las excepciones propias que declaran `mensaje_registrable = True` (True EXACTO en la clase) pueden registrarse con su texto."""
    return getattr(type(exc), "mensaje_registrable", False) is True


def traza_sin_mensaje(exc: BaseException) -> str:
    """Solo los marcos de la traza (archivo, línea, función y código fuente); NUNCA el texto del mensaje de la excepción ni el de sus causas."""
    marcos = "".join(traceback.format_tb(exc.__traceback__))
    return f"{type(exc).__module__}.{type(exc).__qualname__}\n{marcos}"


def descripcion_segura(exc: BaseException) -> str:
    """Una línea para listas de errores y detalles: `APIError sqlstate=23505` o el nombre del tipo. Sin texto."""
    if isinstance(exc, APIError):
        return f"APIError sqlstate={exc.code}"
    return type(exc).__qualname__
