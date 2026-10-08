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


# --- Terminales, API web (CONTRATO_API_TERMINALES_PAQUETE_2.md §6; SCJ11-SCJ17) -----------------------------

CODIGO_SIN_VIGENCIA_ACTIVA = "SCJ02"
CODIGOS_SCJ = {"SCJ11", "SCJ12", "SCJ13", "SCJ14", "SCJ16", "SCJ17"}
FK_VIOLATION = "23503"

MENSAJE_TRANSICION_INVALIDA = "El movimiento no es válido para el estado actual del alta."
MENSAJE_ALTA_DUPLICADA = "La persona ya tiene un alta vigente en esta terminal."
MENSAJE_PERSONA_NO_ACTIVA = "La persona no existe o no está activa."
MENSAJE_TERMINAL_NO_VALIDA = "La terminal no existe o no está activa."
MENSAJE_TERMINAL_CON_ALTAS = (
    "La terminal tiene altas vigentes; da de baja todas antes de desactivarla."
)
MENSAJE_CREDENCIAL_YA_REVOCADA = "La credencial ya está revocada."
MENSAJE_CONSENTIMIENTO_DESACTUALIZADO = "El texto de consentimiento cambió; vuelve a leerlo."
MENSAJE_CONSENTIMIENTO_REQUERIDO = "Falta la versión del texto de consentimiento."
MENSAJE_CLAVE_RESERVADA = "Esa variable se edita desde Terminales → Configuración."
MENSAJE_TEXTO_INVALIDO = "El texto debe tener entre 1 y 4 000 caracteres."
MENSAJE_NOTA_INVALIDA = "El motivo del cambio no puede pasar de 200 caracteres."
MENSAJE_LOTE_INVALIDO = "El lote debe traer entre 1 y 200 altas."
MENSAJE_VARIABLE_NO_EXISTE = "La variable no existe."
MENSAJE_VALOR_INVALIDO = "El valor no es válido para esta variable."
MENSAJE_PARAMETRO_SIN_VIGENCIA = "No existe un parámetro activo con esa clave."
MENSAJE_PERSONA_NO_SINCRONIZADA = (
    "La persona no está sincronizada en el esquema de tiempo; avisa a Sistemas."
)
MENSAJE_ASIGNACION_SIMULTANEA = "Otra asignación de esta persona ocurrió al mismo tiempo; recarga."
MENSAJE_DATO_RELACIONADO = "Un dato relacionado no existe o no está sincronizado; avisa a Sistemas."
MENSAJE_REGISTRO_SIMULTANEO = "Otro cambio ocurrió al mismo tiempo; recarga."
MENSAJE_LOTE_NO_ELEGIBLE = "No se registró nada: algunas altas ya no son elegibles."
MENSAJE_DATOS_INVALIDOS_TERMINAL = "Los datos enviados no son válidos."

_SCJ12_POR_HINT = {
    "alta_duplicada": (status.HTTP_409_CONFLICT, MENSAJE_ALTA_DUPLICADA),
    "persona_no_activa": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PERSONA_NO_ACTIVA),
    "terminal_no_valida": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TERMINAL_NO_VALIDA),
}
_SCJ16_POR_HINT = {
    "consentimiento_desactualizado": (
        status.HTTP_409_CONFLICT,
        MENSAJE_CONSENTIMIENTO_DESACTUALIZADO,
    ),
    "consentimiento_requerido": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        MENSAJE_CONSENTIMIENTO_REQUERIDO,
    ),
}
_22023_POR_HINT = {
    "texto_invalido": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_TEXTO_INVALIDO),
    "nota_invalida": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_NOTA_INVALIDA),
    "lote_invalido": (status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_LOTE_INVALIDO),
    "clave_no_editable": (status.HTTP_404_NOT_FOUND, MENSAJE_VARIABLE_NO_EXISTE),
}


def traducir_error_terminal_web(
    error: APIError,
    rango: tuple[int, int] | None = None,
    contexto: str | None = None,
) -> HTTPException | None:
    """Traduce los errores de la base de la API WEB de Terminales (SCJ11–SCJ17 y compañía) a una
    HTTPException con mensaje FIJO: el texto de la base nunca llega a la respuesta. Devuelve None si el
    error no es de esta familia (el llamador decide: normalmente relanzar al 500 genérico).

    - SCJ15, 42501 y 22023/motivo_invalido los resuelve `traducir_error_dia_cerrado` (mismo contrato).
    - `rango`=(mínimo, máximo) del catálogo del backend permite el mensaje «entre {min} y {max}» de
      22023/valor_invalido sin leer el texto de la base.
    - `contexto` decide qué significan 23505 y 23503, que dependen del endpoint: sólo con
      contexto='asignacion' (POST asignar, que espera `uq_terminal_usuario_persona_vigente` y la FK
      persona_id -> tiempo.persona) son «asignación simultánea» (409) y «persona no sincronizada» (422). Sin
      contexto son mensajes genéricos que no afirman nada del endpoint. Cada endpoint que use este helper
      debe declarar el contexto que espera.
    - SCJ16/consentimiento_desactualizado trae sólo estado y mensaje: el endpoint le agrega el campo
      `consentimiento_vigente` (el texto vigente) porque el cuerpo lo conoce el llamador, no este helper."""
    codigo, hint = error.code, error.hint or ""

    if codigo == "SCJ11":
        return HTTPException(status.HTTP_409_CONFLICT, MENSAJE_TRANSICION_INVALIDA)
    if codigo == "SCJ12" and hint in _SCJ12_POR_HINT:
        estado, mensaje = _SCJ12_POR_HINT[hint]
        return HTTPException(estado, mensaje)
    if codigo == "SCJ13":
        return HTTPException(status.HTTP_409_CONFLICT, MENSAJE_TERMINAL_CON_ALTAS)
    if codigo == "SCJ14":
        return HTTPException(status.HTTP_409_CONFLICT, MENSAJE_CREDENCIAL_YA_REVOCADA)
    if codigo == "SCJ16":
        estado, mensaje = _SCJ16_POR_HINT.get(
            hint, (status.HTTP_409_CONFLICT, MENSAJE_CONSENTIMIENTO_DESACTUALIZADO)
        )
        return HTTPException(estado, mensaje)
    if codigo == "SCJ17":
        return HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_CLAVE_RESERVADA)
    if codigo == CODIGO_SIN_VIGENCIA_ACTIVA:
        return HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PARAMETRO_SIN_VIGENCIA)
    if codigo == FK_VIOLATION:
        mensaje = MENSAJE_PERSONA_NO_SINCRONIZADA if contexto == "asignacion" else MENSAJE_DATO_RELACIONADO
        return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, mensaje)
    if codigo == UNIQUE_VIOLATION:
        mensaje = MENSAJE_ASIGNACION_SIMULTANEA if contexto == "asignacion" else MENSAJE_REGISTRO_SIMULTANEO
        return HTTPException(status.HTTP_409_CONFLICT, mensaje)
    if codigo == "22023":
        if hint in _22023_POR_HINT:
            estado, mensaje = _22023_POR_HINT[hint]
            return HTTPException(estado, mensaje)
        if hint == "valor_invalido":
            mensaje = (
                f"El valor debe ser un entero entre {rango[0]} y {rango[1]}."
                if rango
                else MENSAJE_VALOR_INVALIDO
            )
            return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, mensaje)
        if hint == "lote_no_elegible":
            # El DETAIL de la base NO se relaya (puede traer ids): el endpoint reconstruye la lista de
            # no elegibles y su razón con sus propias consultas.
            return HTTPException(status.HTTP_409_CONFLICT, MENSAJE_LOTE_NO_ELEGIBLE)
        if hint != "motivo_invalido":
            # cualquier otro 22023 (huellas_invalidas, retencion_invalida, sin hint…): genérico
            return HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DATOS_INVALIDOS_TERMINAL)
    # SCJ15, 42501 y 22023/motivo_invalido
    return traducir_error_dia_cerrado(error)


def manejar_error_terminal_web(
    error: APIError, rango: tuple[int, int] | None = None, contexto: str | None = None
) -> NoReturn:
    """Debe llamarse desde un `except APIError`. Levanta la traducción o relanza el error original (que
    cae al handler genérico de main.py: 500 sin texto)."""
    traduccion = traducir_error_terminal_web(error, rango, contexto)
    if traduccion is not None:
        raise traduccion from None
    raise error
