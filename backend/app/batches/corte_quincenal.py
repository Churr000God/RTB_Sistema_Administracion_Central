"""Batch de corte quincenal (SCJ-PRO-13) -- junto con cierre de día, la otra pieza de mayor
riesgo del subsistema Tiempo (afecta banco de horas y clasificación de pago). Combina, a
propósito, el corte de banco de horas (generado_quincena, SCJ-DEC-02) y la clasificación de
tiempo por tramo (clasificacion_de_tiempo.tipo): reposición sólo se puede saber sabiendo si la
persona tenía deuda, y eso sólo se conoce al momento del corte.

ejecutar_corte_quincenal es el punto de entrada tanto del job programado (app/scheduler.py, corre
sólo los días 1 y 16 de cada mes) como del botón manual (routers/corridas_batch.py) -- misma
orquestación de tiempo.corrida_batch (app/batches/_orquestacion.py) que ya usan cierre_dia/
de_confianza. Corre como service_role: es un proceso de sistema, no un caller humano sujeto a RLS.

Periodo cubierto por fecha_corte (SCJ-PRO-13 §V): si fecha_corte.day >= 16, el periodo es
[1, 15] del mismo mes; si no, es [16, último día real] del mes ANTERIOR -- esto resuelve solo el
caso de meses de 31 días (el 31 nunca abre un tercer periodo, cae en el "16-fin" que ya se
extiende hasta el último día real de ese mes).

Algoritmo por persona, SCJ-PRO-13 §III/§IV (sólo tipo_jornada normal/flexible -- de_confianza
queda excluida por completo, ni siquiera por persona: se excluye POR FECHA dentro del periodo, en
caso de que la persona haya cambiado de tipo de jornada a mitad de periodo):
1. Idempotente por persona -- si algún tramo del periodo ya tiene clasificacion_de_tiempo, se
   salta (no vuelve a escribir). Ver "OJO -- idempotencia" abajo, no está especificado así en el
   documento, es una decisión propia.
2. Si algún día esperado del periodo no tiene tiempo.dia (cierre de día no llegó a esa fecha) o
   sigue 'abierto', la persona se salta ENTERA para esta corrida -- cuenta como pendiente, hace
   fallar la corrida (mismo criterio que un error real, SCJ-PRO-13 §III K1).
3. Un día 'bloqueado' se excluye de ambos lados del cálculo (ni esperado ni trabajado).
4. horas_esperadas = suma de patron_semanal (recalculado desde hora_entrada/hora_salida/
   minutos_comida, igual que el trigger de tope legal -- horas_efectivas no es fuente de verdad)
   de cada día esperado (no domingo/festivo/bloqueado, jornada vigente ese día es normal/
   flexible). horas_trabajadas = suma de tramo.minutos_trabajados de los días elegibles
   (cerrado/revisado, no bloqueado) -- no se usa dia.horas_totales directo, se sabe recalcular
   desde el tramo por el mismo criterio de "no confiar en columnas derivadas".
5. Si trabajadas < esperadas (déficit): todos los tramos elegibles -> 'ordinario', un
   movimiento_de_saldo tipo='generado_quincena', monto=+déficit.
6. Si no hay déficit: recorre los tramos en orden cronológico acumulando. Mientras el acumulado
   (después de sumar el tramo completo -- nunca se parte uno) no exceda esperadas: 'ordinario'.
   Si excede: si queda deuda en banco_de_horas, el tramo entero -> 'reposicion' + un
   movimiento_de_saldo tipo='cubrir', monto=-min(horas_del_tramo, deuda_restante) (nunca rebasa
   la deuda, el resto del tramo si sobra no genera un movimiento aparte -- no se puede partir el
   tramo); si ya no queda deuda, el tramo entero -> 'extra', sin tocar banco_de_horas.

Escritura atómica por persona (hallazgo de security, corregido): Python sólo CALCULA -- recorre
los tramos y decide clasificaciones/movimientos en memoria, sin escribir nada hasta el final.
Todo lo que decidió para una persona se manda junto a tiempo.fn_corte_quincenal_aplicar_persona
(RPC, SECURITY INVOKER, GRANT EXECUTE sólo a service_role), que inserta clasificacion_de_tiempo +
movimiento_de_saldo (resolviendo banco_de_horas y el mapa tramo_id -> clasificacion_de_tiempo.id
del lado de la base) en una sola transacción real. Antes, cada INSERT iba suelto: si algo fallaba
a mitad (error, o la carrera del UNIQUE(tramo_id) si cron+botón manual coincidían), la persona
quedaba con clasificación parcial sin su movimiento correspondiente, y "si algún tramo ya
clasificado, saltar entero" la dejaba atascada para siempre sin reintento limpio. Con la
transacción real, un fallo a mitad de camino no deja nada escrito -- el próximo reintento la ve
como no procesada y la reprocesa limpia.

OJO -- idempotencia: el documento dice "misma orquestación... idempotente por persona" como
heredado de SCJ-PRO-12, pero a diferencia de tiempo.dia.estado (que tiene un valor "ya resuelto"
explícito), clasificacion_de_tiempo/movimiento_de_saldo no tienen ningún campo que diga "este
periodo ya se procesó". Se implementó el criterio más conservador: si CUALQUIER tramo elegible
del periodo ya tiene una fila en clasificacion_de_tiempo, la persona entera se salta (no hay
retry parcial por tramo). Reportado a orchestrator como decisión propia, no tomada de un
documento -- si prefieren granularidad por tramo, es un cambio de una función. Esta lectura de
idempotencia sigue viviendo en Python (SELECT antes de llamar al RPC), no en la base.

OJO -- comentario desactualizado en 02_tiempo.sql: el COMMENT de tiempo.clasificacion_de_tiempo
dice que el tipo "se calcula comparando... contra tope_legal vigente" y que "la regla exacta del
disparador queda pendiente de programar" -- eso es texto previo a SCJ-PRO-13 (que sí cerró la
regla exacta, basada en patron_semanal/horas_esperadas, no en tope_legal, y como algoritmo de
aplicación, no un disparador de BD). Se siguió el documento SCJ-PRO-13 (más nuevo y específico),
no el comentario viejo -- vale la pena que alguien actualice ese COMMENT en una pasada futura."""

import logging
from datetime import date, time, timedelta

from postgrest.exceptions import APIError
from supabase import Client

from app.batches._orquestacion import finalizar_corrida, upsert_corrida_en_progreso
from app.config import get_settings
from app.deps import get_service_client

TIPO_BATCH = "corte_quincenal"
DOMINGO = 6  # date.weekday(): lunes=0 ... domingo=6
DIAS_SEMANA = ("lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo")

logger = logging.getLogger(__name__)


def _rango_periodo(fecha_corte: date) -> tuple[date, date]:
    """SCJ-PRO-13 §V: periodos fijos 1-15 / 16-fin de mes. fecha_corte.day >= 16 cierra el
    periodo [1,15] del mismo mes; cualquier otro día cierra el [16, último día real] del mes
    anterior -- generaliza el "corre el 1 y el 16" a cualquier fecha de reproceso manual."""
    if fecha_corte.day >= 16:
        return date(fecha_corte.year, fecha_corte.month, 1), date(fecha_corte.year, fecha_corte.month, 15)
    ultimo_dia_mes_anterior = date(fecha_corte.year, fecha_corte.month, 1) - timedelta(days=1)
    return date(ultimo_dia_mes_anterior.year, ultimo_dia_mes_anterior.month, 16), ultimo_dia_mes_anterior


def resolver_ultimo_periodo_vencido(hoy: date) -> tuple[date, date]:
    """Wrapper público de _rango_periodo -- mismo cálculo, para reuso desde
    prevision_corte_quincenal.py sin tocar el símbolo que los tests ya mockean por nombre exacto
    (mocker.patch("app.batches.corte_quincenal._rango_periodo", ...))."""
    return _rango_periodo(hoy)


def _fechas_del_periodo(periodo_desde: date, periodo_hasta: date) -> list[date]:
    dias = (periodo_hasta - periodo_desde).days + 1
    return [periodo_desde + timedelta(days=i) for i in range(dias)]


def _festivos_del_periodo(db: Client, periodo_desde_iso: str, periodo_hasta_iso: str) -> set[str]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("dia_festivo")
        .select("fecha")
        .gte("fecha", periodo_desde_iso)
        .lte("fecha", periodo_hasta_iso)
        .execute()
        .data
    )
    return {fila["fecha"] for fila in filas}


def _personas_normal_flexible_del_periodo(
    db: Client, periodo_desde_iso: str, periodo_hasta_iso: str
) -> list[str]:
    """Candidatas amplias: al menos una jornada normal/flexible que se traslape con el periodo.
    El filtro fino por fecha (de_confianza a mitad de periodo, si la hubiera) pasa después, por
    persona."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("persona_id")
        .in_("tipo_jornada", ["normal", "flexible"])
        .lte("vigente_desde", periodo_hasta_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{periodo_desde_iso}")
        .execute()
        .data
    )
    return sorted({fila["persona_id"] for fila in filas})


def _jornadas_del_periodo(
    db: Client, persona_id: str, periodo_desde_iso: str, periodo_hasta_iso: str
) -> list[dict]:
    """Sin filtrar por tipo -- hace falta ver también una de_confianza si la hubiera a mitad de
    periodo, para excluir esas fechas puntuales del cálculo."""
    return (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("id, tipo_jornada, vigente_desde, vigente_hasta")
        .eq("persona_id", persona_id)
        .lte("vigente_desde", periodo_hasta_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{periodo_desde_iso}")
        .execute()
        .data
    )


def _jornada_vigente_en(jornadas: list[dict], fecha_iso: str) -> dict | None:
    candidatas = [
        j
        for j in jornadas
        if j["vigente_desde"] <= fecha_iso and (j["vigente_hasta"] is None or j["vigente_hasta"] >= fecha_iso)
    ]
    if not candidatas:
        return None
    return max(candidatas, key=lambda j: j["vigente_desde"])


def _patrones_por_jornada(db: Client, jornada_ids: list[int]) -> dict[int, list[dict]]:
    if not jornada_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida")
        .in_("jornada_asignada_id", jornada_ids)
        .execute()
        .data
    )
    por_jornada: dict[int, list[dict]] = {}
    for fila in filas:
        por_jornada.setdefault(fila["jornada_asignada_id"], []).append(fila)
    return por_jornada


def _horas_patron_fila(fila: dict) -> float:
    """No confía en horas_efectivas (columna derivada) -- recalcula desde hora_entrada/
    hora_salida/minutos_comida, mismo criterio que tiempo.fn_patron_semanal_valida_tope_legal."""
    entrada = time.fromisoformat(fila["hora_entrada"])
    salida = time.fromisoformat(fila["hora_salida"])
    minutos_jornada = (salida.hour * 60 + salida.minute) - (entrada.hour * 60 + entrada.minute)
    return minutos_jornada / 60.0 - fila["minutos_comida"] / 60.0


def _horas_esperadas_dia(patrones_por_jornada: dict[int, list[dict]], jornada_id: int, fecha: date) -> float:
    dia_semana = DIAS_SEMANA[fecha.weekday()]
    filas = [
        fila for fila in patrones_por_jornada.get(jornada_id, []) if fila["dia_semana"] == dia_semana
    ]
    return sum(_horas_patron_fila(fila) for fila in filas)


def _dias_del_periodo(
    db: Client, persona_id: str, periodo_desde_iso: str, periodo_hasta_iso: str
) -> dict[str, dict]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .select("id, fecha, estado")
        .eq("persona_id", persona_id)
        .gte("fecha", periodo_desde_iso)
        .lte("fecha", periodo_hasta_iso)
        .execute()
        .data
    )
    return {fila["fecha"]: fila for fila in filas}


def _tramos_de_dias(db: Client, dia_ids: list[int]) -> list[dict]:
    if not dia_ids:
        return []
    filas = (
        db.postgrest.schema("tiempo")
        .table("tramo")
        .select("id, inicio, minutos_trabajados")
        .in_("dia_id", dia_ids)
        .order("inicio")
        .execute()
        .data
    )
    return filas


def _tramos_ya_clasificados(db: Client, tramo_ids: list[int]) -> bool:
    if not tramo_ids:
        return False
    filas = (
        db.postgrest.schema("tiempo")
        .table("clasificacion_de_tiempo")
        .select("id")
        .in_("tramo_id", tramo_ids)
        .limit(1)
        .execute()
        .data
    )
    return bool(filas)


CODIGO_DESALINEACION_MOVIMIENTO = "SCJ05"


def _deuda_actual(db: Client, persona_id: str) -> float:
    """Sólo lectura -- decidir reposicion/extra necesita saber la deuda ANTES de escribir nada.
    0.0 si la persona todavía no tiene fila en banco_de_horas (el RPC la crea si hace falta al
    escribir el primer movimiento)."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("banco_de_horas")
        .select("monto")
        .eq("persona_id", persona_id)
        .execute()
        .data
    )
    return float(filas[0]["monto"]) if filas else 0.0


def _aplicar_persona(
    db: Client,
    persona_id: str,
    clasificaciones: list[dict],
    movimientos: list[dict],
    motivo: str,
) -> None:
    """tiempo.fn_corte_quincenal_aplicar_persona -- INSERT de todas las clasificaciones + todos
    los movimientos de ESTA persona en una sola transacción real (hallazgo de security: insertar
    uno por uno dejaba clasificación parcial sin su movimiento si algo fallaba a mitad, y la
    idempotencia por persona la dejaba atascada para siempre sin reintento limpio). Resuelve
    banco_de_horas (get-or-create) y el mapa tramo_id -> clasificacion_de_tiempo.id internamente,
    del lado de la base."""
    try:
        db.postgrest.schema("tiempo").rpc(
            "fn_corte_quincenal_aplicar_persona",
            {
                "p_persona_id": persona_id,
                "p_clasificaciones": clasificaciones,
                "p_movimientos": movimientos,
                "p_motivo": motivo,
            },
        ).execute()
    except APIError as error:
        if error.code == CODIGO_DESALINEACION_MOVIMIENTO:
            # Defensivo del lado de db: un movimiento trae un tramo_id que no vino en
            # clasificaciones -- no debería pasar nunca si el cálculo de Python está bien, es un
            # bug real de este módulo si se dispara, no un caso externo esperado.
            raise RuntimeError(
                f"Desalineación interna corte_quincenal: un movimiento referencia un tramo_id "
                f"fuera de clasificaciones para persona {persona_id} (bug en _procesar_persona, "
                f"no un caso esperado): {error.message}"
            ) from error
        raise


PENDIENTE_DIA_ABIERTO = "pendiente_dia_abierto"
SALTADA_YA_PROCESADA = "saltada_ya_procesada"
PROCESADA_DEFICIT = "procesada_deficit"
PROCESADA_OK = "procesada_ok"


def _procesar_persona(
    db: Client,
    persona_id: str,
    periodo_desde: date,
    periodo_hasta: date,
    periodo_desde_iso: str,
    periodo_hasta_iso: str,
    festivos: set[str],
    *,
    solo_simular: bool = False,
) -> str:
    jornadas = _jornadas_del_periodo(db, persona_id, periodo_desde_iso, periodo_hasta_iso)
    patrones_por_jornada = _patrones_por_jornada(db, [j["id"] for j in jornadas])
    dias_por_fecha = _dias_del_periodo(db, persona_id, periodo_desde_iso, periodo_hasta_iso)

    esperadas_totales = 0.0
    dia_ids_elegibles: list[int] = []

    for fecha in _fechas_del_periodo(periodo_desde, periodo_hasta):
        fecha_iso = fecha.isoformat()
        if fecha.weekday() == DOMINGO or fecha_iso in festivos:
            continue

        jornada = _jornada_vigente_en(jornadas, fecha_iso)
        if jornada is None or jornada["tipo_jornada"] not in ("normal", "flexible"):
            continue  # de_confianza (o sin jornada vigente) esa fecha puntual -- excluida

        dia = dias_por_fecha.get(fecha_iso)
        if dia is None or dia["estado"] == "abierto":
            return PENDIENTE_DIA_ABIERTO
        if dia["estado"] == "bloqueado":
            continue  # excluido de ambos lados (SCJ-PRO-13 §V)

        dia_ids_elegibles.append(dia["id"])
        esperadas_totales += _horas_esperadas_dia(patrones_por_jornada, jornada["id"], fecha)

    tramos = _tramos_de_dias(db, dia_ids_elegibles)
    tramo_ids = [t["id"] for t in tramos]

    if _tramos_ya_clasificados(db, tramo_ids):
        return SALTADA_YA_PROCESADA

    trabajadas_totales = sum((t["minutos_trabajados"] or 0) / 60.0 for t in tramos)
    motivo = f"corte quincenal {periodo_desde_iso} a {periodo_hasta_iso}"
    clasificaciones: list[dict] = []
    movimientos: list[dict] = []

    if trabajadas_totales < esperadas_totales:
        for tramo in tramos:
            clasificaciones.append({"tramo_id": tramo["id"], "tipo": "ordinario"})
        deficit = esperadas_totales - trabajadas_totales
        movimientos.append({"tramo_id": None, "tipo": "generado_quincena", "monto": deficit})
        if not solo_simular:
            _aplicar_persona(db, persona_id, clasificaciones, movimientos, motivo)
        return PROCESADA_DEFICIT

    if not tramos:
        return PROCESADA_OK  # nada esperado, nada trabajado -- sin escritura, sin llamar al RPC

    deuda_restante = _deuda_actual(db, persona_id)
    acumulado = 0.0

    for tramo in tramos:
        horas_tramo = (tramo["minutos_trabajados"] or 0) / 60.0
        acumulado += horas_tramo

        if acumulado <= esperadas_totales:
            clasificaciones.append({"tramo_id": tramo["id"], "tipo": "ordinario"})
            continue

        if deuda_restante > 0:
            clasificaciones.append({"tramo_id": tramo["id"], "tipo": "reposicion"})
            monto_a_cubrir = min(horas_tramo, deuda_restante)
            movimientos.append({"tramo_id": tramo["id"], "tipo": "cubrir", "monto": -monto_a_cubrir})
            deuda_restante -= monto_a_cubrir
        else:
            clasificaciones.append({"tramo_id": tramo["id"], "tipo": "extra"})

    if not solo_simular:
        _aplicar_persona(db, persona_id, clasificaciones, movimientos, motivo)
    return PROCESADA_OK


def ejecutar_corte_quincenal(fecha_corte: date, db: Client | None = None) -> dict:
    """SCJ-PRO-13 A1-K3. Si no se pasa un cliente ya armado, arma uno de service_role propio
    (mismo criterio que los otros dos batches). Una persona que revienta no detiene a las demás;
    una persona pendiente (día abierto) tampoco detiene a las demás, pero sí hace fallar la
    corrida completa (K1) para que el mecanismo de reintentos la vuelva a intentar."""
    if db is None:
        db = get_service_client(get_settings())

    periodo_desde, periodo_hasta = _rango_periodo(fecha_corte)
    periodo_desde_iso = periodo_desde.isoformat()
    periodo_hasta_iso = periodo_hasta.isoformat()
    fecha_corrida_iso = fecha_corte.isoformat()

    corrida = upsert_corrida_en_progreso(db, TIPO_BATCH, fecha_corrida_iso)

    festivos = _festivos_del_periodo(db, periodo_desde_iso, periodo_hasta_iso)

    contadores = {
        PENDIENTE_DIA_ABIERTO: 0,
        SALTADA_YA_PROCESADA: 0,
        PROCESADA_DEFICIT: 0,
        PROCESADA_OK: 0,
    }
    errores: list[str] = []

    for persona_id in _personas_normal_flexible_del_periodo(db, periodo_desde_iso, periodo_hasta_iso):
        try:
            resultado = _procesar_persona(
                db, persona_id, periodo_desde, periodo_hasta, periodo_desde_iso, periodo_hasta_iso, festivos
            )
            contadores[resultado] += 1
        except Exception as error:  # noqa: BLE001 -- por diseño: aislar la falla de una persona
            errores.append(f"{persona_id}: {error}")

    pendientes = contadores[PENDIENTE_DIA_ABIERTO]
    resumen = (
        f"periodo {periodo_desde_iso} a {periodo_hasta_iso}: "
        f"{contadores[PROCESADA_OK]} procesada(s), {contadores[PROCESADA_DEFICIT]} con déficit, "
        f"{contadores[SALTADA_YA_PROCESADA]} ya procesada(s), {pendientes} pendiente(s) de cierre de día"
    )
    if errores or pendientes:
        logger.error("corte_quincenal fecha_corte=%s errores=%s", fecha_corrida_iso, errores)
        detalle = f"{resumen}, {len(errores)} error(es) -- ver logs del servidor."
        estado_final = "fallida"
    else:
        detalle = f"{resumen}."
        estado_final = "exitosa"

    return finalizar_corrida(db, corrida["id"], estado_final, detalle)
