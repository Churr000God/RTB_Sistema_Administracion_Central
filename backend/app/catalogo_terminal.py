"""Catálogo de las variables del módulo Terminales (claves `terminal_*` de tiempo.parametro, 89_*.sql).
Valor por defecto y rango viven TAMBIÉN en la base (fn_terminal_config_catalogo, única fuente del RPC); un test
de contrato compara ambos. La etiqueta, descripción y unidad viven sólo aquí (la base no las tiene)."""

from dataclasses import dataclass


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


def valor_vigente(db_servicio, clave: str) -> int:
    """Valor vigente de una variable, tolerante: si la clave no existe todavía (89_ sin aplicar), falta, está
    mal formada o fuera de rango, devuelve el valor por defecto (mismo criterio que fn_terminal_config_valor en
    la base). Un parámetro corrupto jamás debe tumbar un listado. `db_servicio` es service_role: tiempo.parametro
    es deny-all para el caller y esto es una lectura de insumo de configuración, no una autorización."""
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
        valor = int(str(filas[0]["valor"]).strip()) if filas else entrada.defecto
    except Exception:  # base caída, valor no entero… nunca tumba el listado
        return entrada.defecto
    return valor if entrada.minimo <= valor <= entrada.maximo else entrada.defecto
