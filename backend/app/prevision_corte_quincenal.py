"""2 alertas preventivas sobre el corte quincenal (SCJ-PRO-13), sin escribir nada -- reusa por
import directo, cross-módulo, símbolos privados de `app.batches.corte_quincenal` (aunque tengan
guión bajo), mismo criterio que evitó una tercera reconstrucción de "hora local" al crear
`app/alertas_horario.py`: la lógica de qué días/jornadas/personas entran en un periodo ya está
escrita y testeada ahí, no se reescribe acá.

`_procesar_persona(..., solo_simular=True)` bloquea a una persona cuando falta `tiempo.dia` para
alguna fecha esperada del periodo -- en la práctica, casi siempre porque el cierre de día
(SCJ-PRO-12) todavía no corrió sobre esa fecha, no porque exista de verdad un `estado='abierto'`
(nada lo escribe hoy, ver docstring de `corte_quincenal.py`).

Dos preguntas distintas, dos funciones:
- `resolver_dias_faltantes` mira el periodo EN CURSO (todavía sin cerrar) -- "¿a quién le falta
  un día para que el corte de este periodo no se trabe cuando llegue su hora?".
- `resolver_personas_con_corte_pendiente` mira el ÚLTIMO periodo YA VENCIDO -- "¿a quién el corte
  real todavía no le corrió, sea por lo anterior o por cualquier otra razón?"."""

import calendar
from datetime import date

from supabase import Client

from app.batches.corte_quincenal import (
    DOMINGO,
    SALTADA_YA_PROCESADA,
    _dias_del_periodo,
    _fechas_del_periodo,
    _festivos_del_periodo,
    _jornada_vigente_en,
    _jornadas_del_periodo,
    _personas_normal_flexible_del_periodo,
    _procesar_persona,
    resolver_ultimo_periodo_vencido,
)

__all__ = [
    "resolver_periodo_en_curso",
    "resolver_dias_faltantes",
    "resolver_personas_con_corte_pendiente",
]


def resolver_periodo_en_curso(hoy: date) -> tuple[date, date]:
    """Distinto de resolver_ultimo_periodo_vencido (ex _rango_periodo): ésta da el periodo que
    CONTIENE a `hoy`, todavía sin cerrar -- no el que ya venció."""
    if hoy.day <= 15:
        return date(hoy.year, hoy.month, 1), date(hoy.year, hoy.month, 15)
    ultimo_dia_mes = calendar.monthrange(hoy.year, hoy.month)[1]
    return date(hoy.year, hoy.month, 16), date(hoy.year, hoy.month, ultimo_dia_mes)


def resolver_dias_faltantes(
    db: Client, periodo_desde: date, periodo_hasta: date, hoy: date
) -> list[dict]:
    """Enumera TODAS las fechas faltantes de cada persona (a diferencia de _procesar_persona,
    que corta en el primer hallazgo con `return`) -- acá el objetivo es mostrarle a RH la lista
    completa, no sólo detectar que hay un problema. `fecha < hoy` estrictamente: nunca marcar hoy
    ni fechas futuras del periodo -- el cierre de día corre de madrugada sobre el día ANTERIOR,
    marcar "hoy" sería puro falso positivo (la corrida de esta noche todavía no corrió)."""
    periodo_desde_iso = periodo_desde.isoformat()
    periodo_hasta_iso = periodo_hasta.isoformat()
    festivos = _festivos_del_periodo(db, periodo_desde_iso, periodo_hasta_iso)

    faltantes: list[dict] = []
    for persona_id in _personas_normal_flexible_del_periodo(db, periodo_desde_iso, periodo_hasta_iso):
        jornadas = _jornadas_del_periodo(db, persona_id, periodo_desde_iso, periodo_hasta_iso)
        dias_por_fecha = _dias_del_periodo(db, persona_id, periodo_desde_iso, periodo_hasta_iso)

        for fecha in _fechas_del_periodo(periodo_desde, periodo_hasta):
            if fecha >= hoy:
                continue
            fecha_iso = fecha.isoformat()
            if fecha.weekday() == DOMINGO or fecha_iso in festivos:
                continue

            jornada = _jornada_vigente_en(jornadas, fecha_iso)
            if jornada is None or jornada["tipo_jornada"] not in ("normal", "flexible"):
                continue  # de_confianza (o sin jornada vigente) esa fecha puntual -- excluida

            if fecha_iso not in dias_por_fecha:
                faltantes.append({"persona_id": persona_id, "fecha": fecha_iso})

    return faltantes


def resolver_personas_con_corte_pendiente(
    db: Client,
    periodo_desde: date,
    periodo_hasta: date,
    periodo_desde_iso: str,
    periodo_hasta_iso: str,
    festivos: set[str],
) -> set[str]:
    """Simula el corte real (solo_simular=True, no escribe nada) para el ÚLTIMO periodo YA
    VENCIDO. `SALTADA_YA_PROCESADA` es la única respuesta que confirma que el corte real ya se
    aplicó de verdad -- cualquier otra cosa (pendiente por día faltante, listo pero nunca
    disparado, o una excepción) significa que todavía no corrió, así que entra al set."""
    pendientes: set[str] = set()
    for persona_id in _personas_normal_flexible_del_periodo(db, periodo_desde_iso, periodo_hasta_iso):
        try:
            resultado = _procesar_persona(
                db,
                persona_id,
                periodo_desde,
                periodo_hasta,
                periodo_desde_iso,
                periodo_hasta_iso,
                festivos,
                solo_simular=True,
            )
        except Exception:  # noqa: BLE001 -- por diseño: aislar la falla de una persona, ver docstring
            pendientes.add(persona_id)
            continue
        if resultado != SALTADA_YA_PROCESADA:
            pendientes.add(persona_id)
    return pendientes
