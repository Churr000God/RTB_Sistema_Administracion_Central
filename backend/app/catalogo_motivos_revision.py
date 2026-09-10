"""Catálogo cerrado de los 6 motivos de tiempo.excepcion.motivo_revision (SCJ-DEC-07). Vive en
código, no en un CHECK de la base -- chocaría con la concatenación de
fn_ausencia_resuelve_excepcion (02_tiempo.sql:827-841), que le agrega un sufijo de resolución al
motivo original.

reloj_no_sincronizado/persona_inactiva/dia_cerrado/fuera_de_horario: los escribe el trigger
fn_marca_valida_revision (02_tiempo.sql:684-770) al insertar la marca -- pueden acumularse varios
a la vez. paridad_impar: lo agrega el batch de cierre de día (app/batches/cierre_dia.py) a nivel
de tiempo.dia, sin marca_id asociada. plantilla_desconocida: nace en Operación, fuera de este
repo (SCJ-ESP-01 §I.4)."""

from dataclasses import dataclass


@dataclass(frozen=True)
class EntradaMotivo:
    etiqueta: str
    quien_genera: str


MOTIVO_RELOJ_NO_SINCRONIZADO = "reloj_no_sincronizado"
MOTIVO_PERSONA_INACTIVA = "persona_inactiva"
MOTIVO_DIA_CERRADO = "dia_cerrado"
MOTIVO_FUERA_DE_HORARIO = "fuera_de_horario"
MOTIVO_PARIDAD_IMPAR = "paridad_impar"
MOTIVO_PLANTILLA_DESCONOCIDA = "plantilla_desconocida"

CATALOGO: dict[str, EntradaMotivo] = {
    MOTIVO_RELOJ_NO_SINCRONIZADO: EntradaMotivo(
        etiqueta="Reloj no sincronizado",
        quien_genera="Trigger fn_marca_valida_revision, al insertar la marca.",
    ),
    MOTIVO_PERSONA_INACTIVA: EntradaMotivo(
        etiqueta="Persona inactiva",
        quien_genera="Trigger fn_marca_valida_revision, al insertar la marca.",
    ),
    MOTIVO_DIA_CERRADO: EntradaMotivo(
        etiqueta="Día ya cerrado",
        quien_genera="Trigger fn_marca_valida_revision, al insertar la marca.",
    ),
    MOTIVO_FUERA_DE_HORARIO: EntradaMotivo(
        etiqueta="Fuera de horario",
        quien_genera="Trigger fn_marca_valida_revision, al insertar la marca.",
    ),
    MOTIVO_PARIDAD_IMPAR: EntradaMotivo(
        etiqueta="Paridad impar de marcas",
        quien_genera="Batch de cierre de día (app/batches/cierre_dia.py), a nivel de día.",
    ),
    MOTIVO_PLANTILLA_DESCONOCIDA: EntradaMotivo(
        etiqueta="Plantilla biométrica desconocida",
        quien_genera="Operación (fuera de este repo, SCJ-ESP-01).",
    ),
}
