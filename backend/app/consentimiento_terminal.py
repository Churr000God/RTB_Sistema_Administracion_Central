"""Piezas compartidas del texto de consentimiento versionado (tiempo.terminal_consentimiento, 88_)."""

import logging

from fastapi import status
from postgrest.exceptions import APIError
from supabase import Client

from app.errores import HINTS_CON_CONSENTIMIENTO_VIGENTE, traducir_error_terminal_web
from app.respuestas_error import ErrorConCampos

logger = logging.getLogger(__name__)

COLUMNAS_CONSENTIMIENTO = "id, version, texto, texto_sha256, provisional, cambio_material, nota, creado_por, creado_en"


def leer_vigente(db: Client) -> dict | None:
    """Versión vigente = la de mayor `version`. Con el cliente del caller (policy terminal_consentimiento_select_lectura)."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_consentimiento")
        .select(COLUMNAS_CONSENTIMIENTO)
        .order("version", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return filas[0] if filas else None


def resumen_vigente(fila: dict) -> dict:
    """Forma del campo `consentimiento_vigente` de los 409 (CONTRATO §6.1)."""
    return {
        "id": fila["id"],
        "version": fila["version"],
        "texto": fila["texto"],
        "texto_sha256": fila["texto_sha256"],
        "provisional": fila["provisional"],
        "cambio_material": fila["cambio_material"],
        "vigente_desde": fila["creado_en"],
    }


def resolver_nombres_autores(db: Client, persona_ids: list[str]) -> dict[str, str]:
    from app.altas_terminal import resolver_nombres_persona

    return resolver_nombres_persona(db, persona_ids)


def error_de_terminal_con_consentimiento(
    error: APIError, db: Client, rango=None, contexto: str | None = None
) -> Exception | None:
    """Como traducir_error_terminal_web, pero los 409 de consentimiento desactualizado llevan el texto vigente
    (releído con el cliente del caller). Si esa relectura falla, se devuelve sólo `detail`: el frontend debe
    tolerar la ausencia del campo y pedir GET …/consentimiento."""
    traduccion = traducir_error_terminal_web(error, rango, contexto)
    if (
        traduccion is not None
        and error.code == "SCJ16"
        and (error.hint or "") in HINTS_CON_CONSENTIMIENTO_VIGENTE
    ):
        try:
            vigente = leer_vigente(db)
        except Exception:  # la relectura nunca debe empeorar el error original
            logger.warning("no se pudo releer el texto de consentimiento vigente para el 409")
            vigente = None
        codigo = error.hint  # consentimiento_desactualizado | version_base_desactualizada
        campos = {"consentimiento_vigente": resumen_vigente(vigente)} if vigente is not None else {}
        return ErrorConCampos(traduccion.status_code, traduccion.detail, campos, codigo=codigo)
    return traduccion


def manejar_error_con_consentimiento(error: APIError, db: Client, rango=None, contexto: str | None = None):
    traduccion = error_de_terminal_con_consentimiento(error, db, rango, contexto)
    if traduccion is not None:
        raise traduccion from None
    raise error


def error_consentimiento_desactualizado(db: Client, vigente: dict) -> ErrorConCampos:
    """409 armado por el endpoint (sin pasar por la base) cuando `consentimiento_id` no es el vigente."""
    from app.errores import MENSAJE_CONSENTIMIENTO_DESACTUALIZADO

    return ErrorConCampos(
        status.HTTP_409_CONFLICT,
        MENSAJE_CONSENTIMIENTO_DESACTUALIZADO,
        {"consentimiento_vigente": resumen_vigente(vigente)},
        codigo="consentimiento_desactualizado",
    )


