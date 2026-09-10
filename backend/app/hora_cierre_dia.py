"""Umbral real de cierre_dia (SCJ-PRO-12 §V): `hora_corte_dia + hora_corrida_cierre_dia`, un
colchón sumado sobre la hora de corte del día -- no sólo `hora_corrida_cierre_dia` como asumía el
código hasta este corte (divergencia real entre `docs/07-procesos/SCJ-PRO-12_*.md §V` y
`scheduler.py`, que usaba el colchón como hora absoluta).

Molde de resolución de vigencia: `app/banco_antiguedad.py::resolver_ventana_meses` -- síncrona,
recibe `Client` por parámetro, última fila vigente antes de la fecha (`lte` + `order(desc)` +
`limit(1)`), sin try/except propio (fail-open, si corresponde, es responsabilidad del caller --
ver `app/scheduler.py`). Parseo de horas con `time.fromisoformat`, mismo patrón que
`app/alertas_horario.py::entrada_salida_programadas`."""

from datetime import time

from supabase import Client

HORA_CORTE_DIA_POR_DEFECTO = time(0, 0)
HORA_CORRIDA_CIERRE_DIA_POR_DEFECTO = time(3, 0)  # valores de ejemplo, db/ddl/03_parametros_ejemplo.sql

MINUTOS_POR_DIA = 24 * 60


def _resolver_hora_parametro(db: Client, clave: str, fecha_iso: str, por_defecto: time) -> time:
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
    return time.fromisoformat(filas[0]["valor"])


def resolver_umbral_cierre_dia(db: Client, fecha_iso: str) -> time:
    """`hora_corte_dia` + `hora_corrida_cierre_dia`, con desborde de 24h (`% MINUTOS_POR_DIA`) si
    la suma pasa medianoche."""
    hora_corte = _resolver_hora_parametro(
        db, "hora_corte_dia", fecha_iso, HORA_CORTE_DIA_POR_DEFECTO
    )
    colchon = _resolver_hora_parametro(
        db, "hora_corrida_cierre_dia", fecha_iso, HORA_CORRIDA_CIERRE_DIA_POR_DEFECTO
    )
    minutos_totales = (
        hora_corte.hour * 60 + hora_corte.minute + colchon.hour * 60 + colchon.minute
    ) % MINUTOS_POR_DIA
    return time(minutos_totales // 60, minutos_totales % 60)


def resolver_umbral_cierre_dia_cron(db: Client, fecha_iso: str) -> tuple[int, int]:
    """Mismo umbral que `resolver_umbral_cierre_dia`, como `(hora, minuto)` -- forma que necesita
    el cron de APScheduler (`scheduler.py`), que no acepta `datetime.time` directo."""
    umbral = resolver_umbral_cierre_dia(db, fecha_iso)
    return umbral.hour, umbral.minute
