"""Segundo eje de alerta del banco de horas (SCJ-ESP-01 §VI.6, SCJ-DEC-02, SCJ-TRZ-01): MAGNITUD
de la deuda como % de la jornada semanal de la persona -- distinto del eje de ANTIGÜEDAD
(`app/banco_antiguedad.py`, desglose 0-V/2/V/2-V/V+ meses, entregado el 8 de septiembre). Los 2
ejes son independientes y se muestran juntos en `routers/banco_de_horas.py`.

Precedente de forma: `app/banco_antiguedad.py` -- funciones puras + resolvers de parámetro con
vigencia, no un router.

`jornada_semanal_horas` reusa el mismo cálculo que `routers/jornada_asignada.py::_horas_patron` y
`batches/corte_quincenal.py::_horas_patron_fila` -- NUNCA
`jornada_asignada.horas_semanales_calculadas` (columna siempre NULL, ningún código la escribe,
confirmado por grep). `_patrones_por_jornada`/`_horas_patron_fila` se importan directo de
`corte_quincenal.py` en vez de reimplementarse -- mismo precedente que
`routers/banco_de_horas.py` ya importando `_festivos_del_periodo` de ahí."""

from typing import Literal

from supabase import Client

from app.batches.corte_quincenal import _horas_patron_fila, _patrones_por_jornada

NivelAlerta = Literal["sin_alerta", "aviso", "escalamiento"]

AVISO_PCT_POR_DEFECTO = 100
ESCALAMIENTO_PCT_POR_DEFECTO = 200

TIPOS_JORNADA_CON_BANCO = ("normal", "flexible")  # de_confianza excluida -- sin banco de horas


def _resolver_umbral_pct(db: Client, clave: str, fecha_iso: str, por_defecto: int) -> int:
    """Molde exacto de `banco_antiguedad.py::resolver_ventana_meses`."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("parametro")
        .select("valor")
        .eq("clave", clave)
        .lte("vigente_desde", fecha_iso)
        .order("vigente_desde", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not filas:
        return por_defecto
    return int(filas[0]["valor"])


def resolver_umbrales_pct(db: Client, fecha_iso: str) -> tuple[int, int]:
    """(aviso_pct, escalamiento_pct) vigentes en fecha_iso."""
    aviso_pct = _resolver_umbral_pct(db, "umbral_aviso_pct", fecha_iso, AVISO_PCT_POR_DEFECTO)
    escalamiento_pct = _resolver_umbral_pct(
        db, "umbral_escalamiento_pct", fecha_iso, ESCALAMIENTO_PCT_POR_DEFECTO
    )
    return aviso_pct, escalamiento_pct


def _jornadas_normal_flexible_vigentes(
    db: Client, persona_ids: list[str], fecha_iso: str
) -> dict[str, dict]:
    """Una fila por persona (la de `vigente_desde` mayor si hay más de una candidata -- mismo
    criterio que `corte_quincenal.py::_jornada_vigente_en`), sólo normal/flexible."""
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("id, persona_id, vigente_desde")
        .in_("persona_id", persona_ids)
        .in_("tipo_jornada", list(TIPOS_JORNADA_CON_BANCO))
        .lte("vigente_desde", fecha_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{fecha_iso}")
        .execute()
        .data
    )
    por_persona: dict[str, dict] = {}
    for fila in filas:
        actual = por_persona.get(fila["persona_id"])
        if actual is None or fila["vigente_desde"] > actual["vigente_desde"]:
            por_persona[fila["persona_id"]] = fila
    return por_persona


def resolver_jornadas_semanales(
    db: Client, persona_ids: list[str], fecha_iso: str
) -> dict[str, float | None]:
    """Fetch por lote, no N+1. `None` (nunca 0.0) para quien no tiene jornada normal/flexible
    vigente en fecha_iso -- de_confianza incluida en ese `None`, no maneja banco de horas."""
    jornada_por_persona = _jornadas_normal_flexible_vigentes(db, persona_ids, fecha_iso)
    patrones_por_jornada = _patrones_por_jornada(
        db, [j["id"] for j in jornada_por_persona.values()]
    )

    resultado: dict[str, float | None] = {persona_id: None for persona_id in persona_ids}
    for persona_id, jornada in jornada_por_persona.items():
        filas_patron = patrones_por_jornada.get(jornada["id"], [])
        resultado[persona_id] = sum(_horas_patron_fila(fila) for fila in filas_patron)
    return resultado


def clasificar_nivel_deuda(
    monto: float,
    jornada_semanal_horas: float | None,
    aviso_pct: int,
    escalamiento_pct: int,
) -> NivelAlerta | None:
    """`None` si no hay jornada semanal contra la que medir (sin jornada normal/flexible vigente,
    o jornada en 0). Fronteras INCLUSIVAS, mismo criterio que `alertas_horario.py::evaluar_alertas`."""
    if jornada_semanal_horas is None or jornada_semanal_horas <= 0:
        return None
    pct = monto / jornada_semanal_horas * 100
    if pct >= escalamiento_pct:
        return "escalamiento"
    if pct >= aviso_pct:
        return "aviso"
    return "sin_alerta"
