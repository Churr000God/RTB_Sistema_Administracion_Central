"""Lógica compartida para calcular la primera/última marca efectiva del día y las alertas de
horario direccionales e independientes que usa la pantalla de Días (`routers/dias.py`). Precedente
de forma: `app/dias_habiles.py` (funciones puras + resolución batch, no un router).

Reconstrucción de hora local: hay DOS implementaciones que divergen en el proyecto --
`batches/cierre_dia.py` (`astimezone(UTC)`, robusta) y `routers/alertas_de_retardo.py`
(`replace(tzinfo=None)`, frágil si el offset no viniera ya en +00:00 -- verificado con grep que
son literalmente distintas). Este módulo copia el criterio de `cierre_dia.py`. **No se toca
`alertas_de_retardo.py` en este corte** -- el módulo se escribe para que ese refactor sea trivial
después, pero queda fuera de alcance.

Reglas propias de esta pantalla, que NO están en el trigger SQL (`fn_marca_valida_revision` sólo
marca `fuera_de_horario` como un único BETWEEN sin dirección):
- Las alertas son CON SIGNO: llegar tarde (retardo) y llegar muy temprano (entrada_anticipada) son
  casos distintos; igual para salida (salida_tardia/salida_anticipada).
- Las dos alertas (entrada/salida) son INDEPENDIENTES -- no hace falta que fallen las dos a la vez
  (`alertas_de_retardo.py` sí lo exige, con `not coincide_entrada and not coincide_salida`).
- Se usa `jornada_asignada.genera_alerta_horario` (el campo que existe exactamente para esto) en
  vez de comparar `tipo_jornada == 'normal'` a mano, que es lo que hace hoy
  `alertas_de_retardo.py:64` -- inconsistencia real que esta pantalla corrige, sin tocar esa
  página.
- `origen IS NOT NULL` suprime alertas (día sintético, sin marcas reales que evaluar).
  `estado='revisado'` NO suprime -- a diferencia de `alertas_de_retardo.py`, que oculta el día
  completo porque es una bandeja de pendientes. Esta pantalla es la consulta de la verdad del
  día: si "revisar" hiciera desaparecer la alerta, parecería que borró evidencia."""

from datetime import date, datetime, time, timedelta, timezone

from supabase import Client

DIAS_SEMANA = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
TOLERANCIA_POR_DEFECTO_MIN = 0


def dia_semana(fecha: date) -> str:
    return DIAS_SEMANA[fecha.isoweekday() - 1]


def _parse_desfase(desfase_local: str) -> timedelta:
    signo = 1 if desfase_local[0] == "+" else -1
    horas, minutos = desfase_local[1:].split(":")
    return signo * timedelta(hours=int(horas), minutes=int(minutos))


def momento_local(momento_iso: str, desfase_local: str) -> datetime:
    """Mismo criterio robusto que `cierre_dia.py::_fecha_local` (`astimezone(UTC)`) -- acá se
    devuelve el instante completo porque además de la fecha hace falta la hora, para comparar
    contra el patrón semanal."""
    momento = datetime.fromisoformat(momento_iso)
    return momento.astimezone(timezone.utc) + _parse_desfase(desfase_local)


def resolver_marcas_efectivas(
    db: Client, persona_ids: list[str], desde: date, hasta: date
) -> dict[tuple[str, date], dict]:
    """Ventana +-1 día en UTC (mismo motivo que `alertas_de_retardo.py`/`cierre_dia.py`: un
    desfase != +00:00 puede correr la fecha local fuera del rango UTC pedido). Cruza
    `tiempo.correccion` quedándose con la de `creado_en` más reciente por marca (mismo cálculo
    que `marcas.py`/`fn_correccion_valida`) y agrupa por la fecha LOCAL del valor EFECTIVO, no
    del crudo -- así una corrección que cruza medianoche mueve la marca al día correcto (gap real
    que `alertas_de_retardo.py` no cubre, documentado en `cierre_dia.py`).

    Devuelve, por (persona_id, fecha), el instante efectivo (UTC aware, tal cual se muestra en la
    pantalla) y la hora local (para comparar contra el patrón semanal) de la primera y última
    marca de ese día, más `marca_ids` -- TODAS las marcas del día, no sólo la primera/última,
    necesario para contar excepciones pendientes ligadas a esas marcas (routers/dias.py)."""
    if not persona_ids:
        return {}

    ventana_desde = (desde - timedelta(days=1)).isoformat() + "T00:00:00+00:00"
    ventana_hasta = (hasta + timedelta(days=1)).isoformat() + "T23:59:59+00:00"
    marcas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, persona_id, momento_dispositivo, desfase_local")
        .in_("persona_id", persona_ids)
        .gte("momento_dispositivo", ventana_desde)
        .lte("momento_dispositivo", ventana_hasta)
        .execute()
        .data
    )
    if not marcas:
        return {}

    marca_ids = [m["id"] for m in marcas]
    correcciones = (
        db.postgrest.schema("tiempo")
        .table("correccion")
        .select("marca_id, valor_corregido, creado_en")
        .in_("marca_id", marca_ids)
        .execute()
        .data
    )
    ultima_correccion_por_marca: dict[int, dict] = {}
    for correccion in correcciones:
        actual = ultima_correccion_por_marca.get(correccion["marca_id"])
        if actual is None or correccion["creado_en"] > actual["creado_en"]:
            ultima_correccion_por_marca[correccion["marca_id"]] = correccion

    candidatas: dict[tuple[str, date], list[tuple[datetime, datetime, int]]] = {}
    for marca in marcas:
        correccion = ultima_correccion_por_marca.get(marca["id"])
        efectivo_iso = correccion["valor_corregido"] if correccion else marca["momento_dispositivo"]
        local = momento_local(efectivo_iso, marca["desfase_local"])
        fecha_local = local.date()
        if not (desde <= fecha_local <= hasta):
            continue  # fuera de la página pedida -- sólo se amplió la ventana para no perderla
        efectivo = datetime.fromisoformat(efectivo_iso)
        clave = (marca["persona_id"], fecha_local)
        candidatas.setdefault(clave, []).append((efectivo, local, marca["id"]))

    resultado: dict[tuple[str, date], dict] = {}
    for clave, tercias in candidatas.items():
        tercias.sort(key=lambda tercia: tercia[0])
        primera_efectivo, primera_local, _ = tercias[0]
        ultima_efectivo, ultima_local, _ = tercias[-1]
        resultado[clave] = {
            "primera": primera_efectivo,
            "ultima": ultima_efectivo,
            "primera_local": primera_local.time(),
            "ultima_local": ultima_local.time(),
            "marca_ids": [tercia[2] for tercia in tercias],
        }
    return resultado


def resolver_jornadas(
    db: Client, persona_ids: list[str], desde: date, hasta: date
) -> dict[str, list[dict]]:
    """normal/flexible únicamente -- de_confianza no pasa por acá (batch aparte, día siempre
    origen='automatico_confianza', sin marcas que evaluar), mismo recorte que
    `cierre_dia.py::_personas_normal_flexible_vigentes`."""
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("id, persona_id, tipo_jornada, genera_alerta_horario, vigente_desde, vigente_hasta")
        .in_("persona_id", persona_ids)
        .in_("tipo_jornada", ["normal", "flexible"])
        .lte("vigente_desde", hasta.isoformat())
        .execute()
        .data
    )
    por_persona: dict[str, list[dict]] = {}
    for fila in filas:
        if fila["vigente_hasta"] is not None and fila["vigente_hasta"] < desde.isoformat():
            continue
        por_persona.setdefault(fila["persona_id"], []).append(fila)
    return por_persona


def jornada_vigente(jornadas: list[dict], fecha: date) -> dict | None:
    """La jornada vigente en `fecha` -- si más de una calificara (no debería pasar, SCJ-DEC-04
    exige vigencias sin traslape, pero la función es defensiva), gana la de `vigente_desde`
    mayor."""
    fecha_iso = fecha.isoformat()
    candidatas = [
        jornada
        for jornada in jornadas
        if jornada["vigente_desde"] <= fecha_iso
        and (jornada["vigente_hasta"] is None or jornada["vigente_hasta"] >= fecha_iso)
    ]
    if not candidatas:
        return None
    return max(candidatas, key=lambda jornada: jornada["vigente_desde"])


def resolver_patrones(db: Client, jornada_ids: list[int]) -> dict[int, dict[str, list[dict]]]:
    """Mismo shape que `alertas_de_retardo.py::_resolver_patrones`."""
    if not jornada_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("jornada_asignada_id, dia_semana, hora_entrada, hora_salida")
        .in_("jornada_asignada_id", jornada_ids)
        .execute()
        .data
    )
    patrones: dict[int, dict[str, list[dict]]] = {}
    for fila in filas:
        por_dia = patrones.setdefault(fila["jornada_asignada_id"], {})
        por_dia.setdefault(fila["dia_semana"], []).append(fila)
    return patrones


def entrada_salida_programadas(patron_del_dia: list[dict]) -> tuple[time, time]:
    """Jornada partida admite varias filas para el mismo día de semana (`02_tiempo.sql:120-122`)
    -- min(hora_entrada)/max(hora_salida), mismo criterio que `alertas_de_retardo.py:232-235`."""
    entrada = min(fila["hora_entrada"] for fila in patron_del_dia)
    salida = max(fila["hora_salida"] for fila in patron_del_dia)
    return time.fromisoformat(entrada), time.fromisoformat(salida)


def resolver_tolerancias(db: Client, hasta: date) -> list[tuple[date, int]]:
    """Mismo criterio que `alertas_de_retardo.py::_resolver_tolerancias` -- última vigente antes
    de cada fecha, resuelta en memoria."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("parametro")
        .select("valor, vigente_desde")
        .eq("clave", "tolerancia_retardo_min")
        .lte("vigente_desde", hasta.isoformat())
        .order("vigente_desde", desc=True)
        .execute()
        .data
    )
    return [(date.fromisoformat(fila["vigente_desde"]), int(fila["valor"])) for fila in filas]


def tolerancia_vigente(tolerancias: list[tuple[date, int]], fecha: date) -> int:
    for vigente_desde, valor in tolerancias:
        if vigente_desde <= fecha:
            return valor
    return TOLERANCIA_POR_DEFECTO_MIN


def _diferencia_con_signo_minutos(hora_a: time, hora_b: time) -> float:
    """a - b, en minutos, CON signo -- a diferencia de `alertas_de_retardo.py::_diferencia_minutos`
    (que usa `abs()`), acá el signo es justo lo que distingue retardo de entrada_anticipada."""
    referencia = date(2000, 1, 1)
    return (
        datetime.combine(referencia, hora_a) - datetime.combine(referencia, hora_b)
    ).total_seconds() / 60.0


def evaluar_alertas(
    primera: time,
    ultima: time,
    entrada_programada: time,
    salida_programada: time,
    tolerancia_min: int,
) -> tuple[str | None, str | None]:
    """Direccionales e independientes -- ver docstring del módulo. Frontera inclusiva: exactamente
    en el límite de tolerancia no dispara alerta (mismo criterio que el BETWEEN del trigger, sólo
    que acá son dos comparaciones con signo en vez de una sola sin dirección). Con una sola marca
    en el día, se llama con `primera == ultima` -- se compara igual contra ambos extremos, sin
    caso especial (mismo criterio que `alertas_de_retardo.py`)."""
    diff_entrada = _diferencia_con_signo_minutos(primera, entrada_programada)
    if diff_entrada > tolerancia_min:
        alerta_entrada = "retardo"
    elif diff_entrada < -tolerancia_min:
        alerta_entrada = "entrada_anticipada"
    else:
        alerta_entrada = None

    diff_salida = _diferencia_con_signo_minutos(ultima, salida_programada)
    if diff_salida > tolerancia_min:
        alerta_salida = "salida_tardia"
    elif diff_salida < -tolerancia_min:
        alerta_salida = "salida_anticipada"
    else:
        alerta_salida = None

    return alerta_entrada, alerta_salida
