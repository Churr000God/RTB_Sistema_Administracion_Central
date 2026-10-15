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


NIVELES_DE_CADENA = 5


def _nombre_de_clase(valor: object) -> str:
    """El nombre de la CLASE (jamás el valor), acotado a caracteres de identificador."""
    nombre = type(valor).__name__
    return nombre if nombre.replace("_", "").replace(".", "").isalnum() and len(nombre) <= 64 else "otra"


def resumen_de_cadena(exc: BaseException, niveles: int = NIVELES_DE_CADENA) -> dict:
    """Solo CLASES y enteros de una excepción y de su cadena de causas: `clase`, `causas` (por `__cause__`), `contextos` (por `__context__`, hasta `niveles` cada una), la clase de
    `original_error` (supabase-auth lo trae en AuthUnknownError) y los códigos HTTP (enteros) de las respuestas que cuelguen de la cadena. NUNCA el mensaje, la URL, cabeceras, el cuerpo
    ni datos de la petición. Sirve para saber si fue un ConnectError, un ReadTimeout, un fallo TLS o de DNS, sin registrar nada sensible."""
    def recorrer(inicio, atributo):
        nombres, visto, actual = [], {id(exc)}, getattr(inicio, atributo, None)
        while actual is not None and len(nombres) < niveles and id(actual) not in visto:
            visto.add(id(actual))
            nombres.append(_nombre_de_clase(actual))
            actual = getattr(actual, atributo, None)
        return nombres

    codigos = []
    for nodo in (exc, *_nodos(exc, niveles)):
        respuesta = getattr(nodo, "response", None)
        codigo = getattr(respuesta, "status_code", None)
        if isinstance(codigo, int) and not isinstance(codigo, bool) and 100 <= codigo <= 599 and codigo not in codigos:
            codigos.append(codigo)
    original = getattr(exc, "original_error", None)
    return {"clase": _nombre_de_clase(exc), "causas": recorrer(exc, "__cause__"), "contextos": recorrer(exc, "__context__"),
            "original": _nombre_de_clase(original) if original is not None else None, "http": codigos}


def _nodos(exc: BaseException, niveles: int) -> list[BaseException]:
    nodos, visto = [], {id(exc)}
    for atributo in ("__cause__", "__context__"):
        actual = getattr(exc, atributo, None)
        while actual is not None and len(nodos) < 2 * niveles and id(actual) not in visto:
            visto.add(id(actual))
            nodos.append(actual)
            actual = getattr(actual, atributo, None)
    return nodos


MAXIMO_EN_LISTA = 20


def lista_acotada(elementos: list[str], maximo: int = MAXIMO_EN_LISTA) -> list[str]:
    """Para registrar una lista de errores por persona: los primeros `maximo` y un «y N más» (el log no crece con el número de fallos y no vuelca todos los ids de golpe)."""
    if len(elementos) <= maximo:
        return list(elementos)
    return [*elementos[:maximo], f"y {len(elementos) - maximo} más"]
