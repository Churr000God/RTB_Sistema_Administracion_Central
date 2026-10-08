"""Catálogo de las variables del módulo Terminales (claves `terminal_*` de tiempo.parametro, 89_*.sql).
Valor por defecto y rango viven TAMBIÉN en la base (fn_terminal_config_catalogo, única fuente del RPC); un test
de contrato compara ambos. La etiqueta, descripción y unidad viven sólo aquí (la base no las tiene)."""

import logging
import re
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class VariableTerminal:
    etiqueta: str
    descripcion: str
    unidad: str
    defecto: int
    minimo: int
    maximo: int


CATALOGO_TERMINAL: dict[str, VariableTerminal] = {
    "terminal_caducidad_alta_horas": VariableTerminal(
        "Caducidad de altas sin huella",
        "Horas que un alta puede quedar en «Esperando huella» antes de darse de baja sola.",
        "horas", 24, 4, 168,
    ),
    "terminal_llave_max_meses": VariableTerminal(
        "Antigüedad máxima de la llave del puente",
        "Meses tras los cuales el tablero marca la llave para rotar.",
        "meses", 12, 3, 36,
    ),
    "terminal_traslape_llave_max_dias": VariableTerminal(
        "Traslape de llaves",
        "Días que pueden convivir la llave vieja y la nueva del puente al rotar.",
        "días", 7, 1, 90,
    ),
    "terminal_anomalias_ventana_dias": VariableTerminal(
        "Ventana de anomalías",
        "Días hacia atrás que considera el tablero por defecto.",
        "días", 7, 1, 90,
    ),
    "terminal_retencion_rechazos_dias": VariableTerminal(
        "Retención de rechazos",
        "Días que se conservan las marcas rechazadas antes de purgarlas.",
        "días", 90, 30, 365,
    ),
}

CLAVE_CADUCIDAD = "terminal_caducidad_alta_horas"


def _entero_en_rango(valor, entrada: VariableTerminal) -> int | None:
    if isinstance(valor, bool) or not isinstance(valor, int):
        return None
    return valor if entrada.minimo <= valor <= entrada.maximo else None


def valor_vigente(db_servicio, clave: str) -> int:
    """Valor vigente de una variable, TOLERANTE: un parámetro faltante, mal formado o fuera de rango, o una base
    sin 89_, devuelve el valor por defecto; un parámetro corrupto jamás debe tumbar un listado ni un job.
    Primero `fn_terminal_config_valor` (89_, EXECUTE sólo service_role, ya acota al rango); si no responde un
    entero válido (función ausente, forma rara) cae a leer tiempo.parametro directo y, en último caso, al
    defecto. `db_servicio` es service_role: es lectura de insumo de configuración, no una autorización."""
    entrada = CATALOGO_TERMINAL[clave]
    try:
        por_rpc = (
            db_servicio.postgrest.schema("tiempo").rpc("fn_terminal_config_valor", {"p_clave": clave}).execute().data
        )
        valido = _entero_en_rango(por_rpc, entrada)
        if valido is not None:
            return valido
    except Exception:  # 89_ sin aplicar o base caída: se intenta la lectura directa
        pass
    try:
        filas = (
            db_servicio.postgrest.schema("tiempo")
            .table("parametro")
            .select("valor")
            .eq("clave", clave)
            .is_("vigente_hasta", "null")
            .execute()
            .data
        )
        valor = int(str(filas[0]["valor"]).strip()) if filas else entrada.defecto
    except Exception:
        return entrada.defecto
    return valor if entrada.minimo <= valor <= entrada.maximo else entrada.defecto


CLAVE_RETENCION_RECHAZOS = "terminal_retencion_rechazos_dias"

_FORMATO_ENTERO = re.compile(r"[0-9]{1,6}")
_MIGRACION_FALTANTE = {"PGRST202", "PGRST204", "PGRST205", "42P01"}


def valor_vigente_estricto(db_servicio, clave: str) -> int | None:
    """Valor vigente para los jobs DESTRUCTIVOS (baja por caducidad, purga): jamás cae a un valor distinto del configurado
    sin avisar. `None` = no se pudo leer con certeza (excepción, forma inesperada, valor ilegible o fuera de rango en la
    base): el job debe registrar ERROR y OMITIR la corrida. El valor por defecto sólo se usa cuando la clave aún no existe
    en tiempo.parametro (89_ sin aplicar), con WARNING. A diferencia de `valor_vigente`, que es para mostrar."""
    entrada = CATALOGO_TERMINAL[clave]
    try:
        filas = (
            db_servicio.postgrest.schema("tiempo")
            .table("parametro")
            .select("valor")
            .eq("clave", clave)
            .is_("vigente_hasta", "null")
            .execute()
            .data
        )
    except Exception as error:
        logger.error("no se pudo leer %s (%s)", clave, getattr(error, "code", None) or type(error).__name__)
        return None
    if not filas:
        logger.warning("la variable %s todavía no existe en la base; se usa el valor por defecto (%s)", clave, entrada.defecto)
        return entrada.defecto
    crudo = str(filas[0].get("valor", "")).strip()
    en_tabla = int(crudo) if _FORMATO_ENTERO.fullmatch(crudo) else None
    if en_tabla is None or not (entrada.minimo <= en_tabla <= entrada.maximo):
        logger.error("la variable %s tiene un valor ilegible o fuera de rango en la base", clave)
        return None
    try:
        por_rpc = (
            db_servicio.postgrest.schema("tiempo").rpc("fn_terminal_config_valor", {"p_clave": clave}).execute().data
        )
    except Exception as error:
        if getattr(error, "code", None) in _MIGRACION_FALTANTE:
            return en_tabla  # la fila existe y es legible; sólo falta la función lectora
        logger.error("no se pudo leer %s por fn_terminal_config_valor (%s)", clave, getattr(error, "code", None) or type(error).__name__)
        return None
    valido = _entero_en_rango(por_rpc, entrada)
    if valido is None:
        logger.error("fn_terminal_config_valor devolvió una forma inesperada para %s", clave)
        return None
    return valido
