"""Desglose de antigüedad del saldo del banco de horas (SCJ-DEC-02), reconstruido en memoria
desde `tiempo.movimiento_de_saldo` -- sin migración nueva. Precedente de forma:
`app/alertas_horario.py` (funciones puras + resolución batch, no un router).

`tiempo.banco_de_horas.vivo_desde` es un solo timestamp por persona (se resetea a NULL cuando el
saldo toca 0) -- no alcanza para distinguir horas viejas de horas nuevas DENTRO de la misma
persona (ej. una persona que debe 10h desde hace 4 meses y generó 2h más la quincena pasada).
Este módulo reconstruye esa distinción con FIFO puro sobre el ledger append-only.

`ventana_banco_meses` (tiempo.parametro, sembrado desde `03_parametros_ejemplo.sql`, nunca leído
hasta este corte) define los 2 cortes: [0, V/2) reciente, [V/2, V) media, [V, inf) fuera_ventana.
Con V=6 (valor de ejemplo) da 0-3/3-6/6+ meses."""

import calendar
from dataclasses import dataclass
from datetime import date, datetime

from supabase import Client

VENTANA_BANCO_POR_DEFECTO_MESES = 6
TOLERANCIA_RECONCILIACION = 0.01  # numeric(8,2) -- un centavo de hora de margen por redondeo.


@dataclass
class Lote:
    fecha: datetime
    restante: float
    movimiento_id: int | None = None  # sólo lo usa el ledger de una persona (routers/banco_de_horas.py) para marcar "vivo"; repartir_por_tramo lo ignora.


@dataclass
class Reparto:
    horas_reciente: float
    horas_media: float
    horas_fuera_ventana: float
    mas_antiguo: datetime | None
    meses_antiguedad_max: int


@dataclass
class ResultadoAntiguedad:
    horas_reciente: float
    horas_media: float
    horas_fuera_ventana: float
    meses_antiguedad_max: int
    conciliado: bool


def resolver_ventana_meses(db: Client, fecha_iso: str) -> int:
    """Molde exacto de cierre_dia.py::_resolver_descuento_pausa_no_registrada -- resolución de
    una sola fecha, .limit(1)."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("parametro")
        .select("valor")
        .eq("clave", "ventana_banco_meses")
        .lte("vigente_desde", fecha_iso)
        .order("vigente_desde", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not filas:
        return VENTANA_BANCO_POR_DEFECTO_MESES
    return int(filas[0]["valor"])


def _restar_meses(momento: datetime, meses: int) -> datetime:
    """Resta meses CALENDARIO, no días aproximados -- clampa el día si el mes destino es más
    corto (ej. 31 de marzo menos 1 mes -> 28/29 de febrero)."""
    mes_total = momento.month - 1 - meses
    anio = momento.year + mes_total // 12
    mes = mes_total % 12 + 1
    dia = min(momento.day, calendar.monthrange(anio, mes)[1])
    return momento.replace(year=anio, month=mes, day=dia)


def _meses_entre(desde: datetime, hasta: datetime) -> int:
    """Antigüedad aproximada en meses completos, sólo informativa (meses_antiguedad_max) -- 30.44
    días/mes (promedio gregoriano). El corte real de tramo usa _restar_meses (calendario exacto),
    esto sólo redondea para mostrar 'hace ~4 meses'."""
    dias = (hasta - desde).total_seconds() / 86400.0
    return int(dias / 30.44)


def calcular_lotes(movimientos: list[dict]) -> list[Lote]:
    """FIFO puro sobre el ledger, ordenado por (creado_en, id) asc. monto > 0
    (generado_quincena) apila un lote nuevo. monto < 0 (cubrir/descontar/condonar) consume desde
    el lote más viejo primero -- FIFO real, nunca LIFO. monto == 0 (arrastrar) no toca lotes.
    Devuelve sólo los lotes con saldo restante."""
    ordenados = sorted(movimientos, key=lambda m: (m["creado_en"], m.get("id", 0)))
    lotes: list[Lote] = []
    for movimiento in ordenados:
        monto = round(float(movimiento["monto"]), 2)
        if monto > 0:
            lotes.append(
                Lote(
                    fecha=datetime.fromisoformat(movimiento["creado_en"]),
                    restante=monto,
                    movimiento_id=movimiento.get("id"),
                )
            )
        elif monto < 0:
            pendiente = -monto
            for lote in lotes:
                if pendiente <= 0:
                    break
                if lote.restante <= 0:
                    continue
                consumo = min(lote.restante, pendiente)
                lote.restante = round(lote.restante - consumo, 2)
                pendiente = round(pendiente - consumo, 2)
        # monto == 0 (arrastrar): no-op, documentado en el ledger pero sin efecto en los lotes.
    return [lote for lote in lotes if lote.restante > 0]


def repartir_por_tramo(lotes: list[Lote], ventana_meses: int, hoy: datetime) -> Reparto:
    """Clasifica cada lote vivo contra los 2 cortes derivados de la ventana."""
    if not lotes:
        return Reparto(0.0, 0.0, 0.0, None, 0)

    corte_reciente = _restar_meses(hoy, ventana_meses // 2)
    corte_medio = _restar_meses(hoy, ventana_meses)

    horas_reciente = horas_media = horas_fuera_ventana = 0.0
    for lote in lotes:
        if lote.fecha >= corte_reciente:
            horas_reciente += lote.restante
        elif lote.fecha >= corte_medio:
            horas_media += lote.restante
        else:
            horas_fuera_ventana += lote.restante

    mas_antiguo = min(lote.fecha for lote in lotes)
    return Reparto(
        round(horas_reciente, 2),
        round(horas_media, 2),
        round(horas_fuera_ventana, 2),
        mas_antiguo,
        _meses_entre(mas_antiguo, hoy),
    )


def _reparto_por_tramo_unico(monto: float, fecha: datetime, ventana_meses: int, hoy: datetime) -> Reparto:
    """Mismo criterio de corte que repartir_por_tramo, pero para un único monto ya conocido (el
    fallback de reconciliación) en vez de una lista de lotes."""
    corte_reciente = _restar_meses(hoy, ventana_meses // 2)
    corte_medio = _restar_meses(hoy, ventana_meses)
    if fecha >= corte_reciente:
        reparto = (monto, 0.0, 0.0)
    elif fecha >= corte_medio:
        reparto = (0.0, monto, 0.0)
    else:
        reparto = (0.0, 0.0, monto)
    return Reparto(*reparto, fecha, _meses_entre(fecha, hoy))


def calcular_antiguedad_saldo(
    movimientos: list[dict],
    monto_banco: float,
    vivo_desde: datetime | None,
    ventana_meses: int,
    hoy: datetime,
) -> ResultadoAntiguedad:
    """Reconcilia el desglose FIFO contra `banco_de_horas.monto` (la fuente materializada por
    trigger). Si no cuadran (con tolerancia de redondeo), NO se esconde el hueco -- SCJ-DEC-02 ya
    lo documenta como abierto: se marca `conciliado=False` y se cae a un reparto de bulto único
    usando `vivo_desde`, en vez de inventar una distribución por lotes que no se sostiene."""
    monto_redondeado = round(monto_banco, 2)
    if monto_redondeado <= 0:
        return ResultadoAntiguedad(0.0, 0.0, 0.0, 0, conciliado=True)

    lotes = calcular_lotes(movimientos)
    reparto = repartir_por_tramo(lotes, ventana_meses, hoy)
    suma_lotes = round(reparto.horas_reciente + reparto.horas_media + reparto.horas_fuera_ventana, 2)

    if abs(suma_lotes - monto_redondeado) <= TOLERANCIA_RECONCILIACION:
        return ResultadoAntiguedad(
            reparto.horas_reciente,
            reparto.horas_media,
            reparto.horas_fuera_ventana,
            reparto.meses_antiguedad_max,
            conciliado=True,
        )

    if vivo_desde is None:
        # No hay ni lotes que cuadren ni vivo_desde de dónde agarrarse -- el hueco de SCJ-DEC-02
        # no da para inventar una fecha, se reporta como desconciliado con antigüedad desconocida.
        return ResultadoAntiguedad(0.0, 0.0, 0.0, 0, conciliado=False)

    fallback = _reparto_por_tramo_unico(monto_redondeado, vivo_desde, ventana_meses, hoy)
    return ResultadoAntiguedad(
        fallback.horas_reciente,
        fallback.horas_media,
        fallback.horas_fuera_ventana,
        fallback.meses_antiguedad_max,
        conciliado=False,
    )
