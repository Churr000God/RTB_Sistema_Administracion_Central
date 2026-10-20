from datetime import datetime, timezone

from app.banco_antiguedad import (
    calcular_antiguedad_saldo,
    calcular_lotes,
    repartir_por_tramo,
)

HOY = datetime(2026, 9, 8, tzinfo=timezone.utc)


def _mov(id_, creado_en, monto):
    return {"id": id_, "creado_en": creado_en, "monto": str(monto)}


def test_calcular_lotes_un_solo_generado_queda_vivo_completo():
    movimientos = [_mov(1, "2026-09-01T00:00:00+00:00", 5.0)]
    lotes = calcular_lotes(movimientos)
    assert len(lotes) == 1
    assert lotes[0].restante == 5.0
    assert lotes[0].movimiento_id == 1


def test_calcular_lotes_cubrir_parcial_deja_el_lote_viejo_vivo():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 10.0),
        _mov(2, "2026-06-01T00:00:00+00:00", -4.0),  # cubrir
    ]
    lotes = calcular_lotes(movimientos)
    assert len(lotes) == 1
    assert lotes[0].movimiento_id == 1
    assert lotes[0].restante == 6.0


def test_calcular_lotes_cubrir_total_el_vivo_pasa_a_ser_otro():
    """FIFO real: el lote más viejo se consume primero y por completo antes de tocar el
    siguiente."""
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 4.0),
        _mov(2, "2026-06-01T00:00:00+00:00", 6.0),
        _mov(3, "2026-07-01T00:00:00+00:00", -4.0),  # cubre exactamente el lote 1
    ]
    lotes = calcular_lotes(movimientos)
    assert len(lotes) == 1
    assert lotes[0].movimiento_id == 2
    assert lotes[0].restante == 6.0


def test_calcular_lotes_descontar_y_condonar_consumen_desde_el_frente():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 5.0),
        _mov(2, "2026-02-01T00:00:00+00:00", -2.0),  # descontar
        _mov(3, "2026-03-01T00:00:00+00:00", -1.0),  # condonar
    ]
    lotes = calcular_lotes(movimientos)
    assert len(lotes) == 1
    assert lotes[0].movimiento_id == 1
    assert lotes[0].restante == 2.0


def test_calcular_lotes_arrastrar_no_tiene_efecto():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 5.0),
        _mov(2, "2026-02-01T00:00:00+00:00", 0.0),  # arrastrar
    ]
    lotes = calcular_lotes(movimientos)
    assert len(lotes) == 1
    assert lotes[0].restante == 5.0


def test_calcular_lotes_consumo_agotado_no_devuelve_lote():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 5.0),
        _mov(2, "2026-02-01T00:00:00+00:00", -5.0),
    ]
    lotes = calcular_lotes(movimientos)
    assert lotes == []


def test_repartir_por_tramo_cruza_los_3_tramos_a_la_vez():
    """Ventana de 6 meses -> cortes en 3 y 6 meses antes de hoy (2026-09-08)."""
    lotes = calcular_lotes(
        [
            _mov(1, "2026-09-01T00:00:00+00:00", 2.0),  # reciente (< 3 meses)
            _mov(2, "2026-05-01T00:00:00+00:00", 3.0),  # media (3-6 meses)
            _mov(3, "2026-01-01T00:00:00+00:00", 4.0),  # fuera_ventana (6+ meses)
        ]
    )
    reparto = repartir_por_tramo(lotes, ventana_meses=6, hoy=HOY)
    assert reparto.horas_reciente == 2.0
    assert reparto.horas_media == 3.0
    assert reparto.horas_fuera_ventana == 4.0
    assert reparto.mas_antiguo == datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_repartir_por_tramo_el_corte_se_mueve_al_cambiar_ventana_meses():
    """El mismo lote (4 meses de antigüedad) cae en tramos distintos según la ventana vigente."""
    lotes = calcular_lotes([_mov(1, "2026-05-08T00:00:00+00:00", 10.0)])  # 4 meses antes de HOY

    reparto_ventana_6 = repartir_por_tramo(lotes, ventana_meses=6, hoy=HOY)
    assert reparto_ventana_6.horas_media == 10.0
    assert reparto_ventana_6.horas_reciente == 0.0
    assert reparto_ventana_6.horas_fuera_ventana == 0.0

    reparto_ventana_2 = repartir_por_tramo(lotes, ventana_meses=2, hoy=HOY)
    assert reparto_ventana_2.horas_fuera_ventana == 10.0
    assert reparto_ventana_2.horas_reciente == 0.0
    assert reparto_ventana_2.horas_media == 0.0


def test_repartir_por_tramo_ventana_impar_usa_piso_entero_para_el_corte_reciente():
    """V=5 (impar) -> corte reciente en piso(5/2)=2 meses antes de hoy, NO 2.5 ni redondeado a 3.
    Con piso=2, el corte reciente cae en 2026-07-08; un lote fechado 2026-06-15 queda ANTES de ese
    corte (va a "media"). Si el corte usara techo=3 en vez de piso (2026-06-08), ese mismo lote
    caería en "reciente" -- este caso distingue ambas implementaciones."""
    lotes = calcular_lotes([_mov(1, "2026-06-15T00:00:00+00:00", 7.0)])

    reparto = repartir_por_tramo(lotes, ventana_meses=5, hoy=HOY)

    assert reparto.horas_reciente == 0.0
    assert reparto.horas_media == 7.0
    assert reparto.horas_fuera_ventana == 0.0


def test_calcular_antiguedad_saldo_conciliado_usa_los_lotes():
    movimientos = [_mov(1, "2026-09-01T00:00:00+00:00", 5.0)]
    resultado = calcular_antiguedad_saldo(
        movimientos, monto_banco=5.0, vivo_desde=None, ventana_meses=6, hoy=HOY
    )
    assert resultado.conciliado is True
    assert resultado.horas_reciente == 5.0


def test_calcular_antiguedad_saldo_monto_cero_es_trivial_sin_tocar_el_ledger():
    resultado = calcular_antiguedad_saldo(
        movimientos=[], monto_banco=0.0, vivo_desde=None, ventana_meses=6, hoy=HOY
    )
    assert resultado.conciliado is True
    assert resultado.horas_reciente == 0.0
    assert resultado.horas_media == 0.0
    assert resultado.horas_fuera_ventana == 0.0


def test_calcular_antiguedad_saldo_desconciliado_cae_a_vivo_desde():
    """El ledger no reconstruye el monto real de banco_de_horas (SCJ-DEC-02, hueco documentado) --
    se marca desconciliado y todo el monto va al tramo de vivo_desde."""
    movimientos = [_mov(1, "2026-09-01T00:00:00+00:00", 2.0)]  # sólo reconstruye 2, banco dice 8
    vivo_desde = datetime(2026, 5, 1, tzinfo=timezone.utc)  # 4 meses -> tramo media

    resultado = calcular_antiguedad_saldo(
        movimientos, monto_banco=8.0, vivo_desde=vivo_desde, ventana_meses=6, hoy=HOY
    )

    assert resultado.conciliado is False
    assert resultado.horas_media == 8.0
    assert resultado.horas_reciente == 0.0
    assert resultado.horas_fuera_ventana == 0.0


def test_calcular_antiguedad_saldo_desconciliado_sin_vivo_desde_no_inventa_fecha():
    resultado = calcular_antiguedad_saldo(
        movimientos=[], monto_banco=8.0, vivo_desde=None, ventana_meses=6, hoy=HOY
    )
    assert resultado.conciliado is False
    assert resultado.horas_reciente == 0.0
    assert resultado.horas_media == 0.0
    assert resultado.horas_fuera_ventana == 0.0
    assert resultado.meses_antiguedad_max == 0


# --- 'compensacion' (120_): revierte un generado_quincena erróneo y consume PRIMERO su propio lote -----------------------------------------------------------


def _comp(id_, creado_en, monto, compensa):
    return {**_mov(id_, creado_en, monto), "compensa_movimiento_id": compensa}


def test_compensar_el_movimiento_mas_reciente_deja_intactos_los_lotes_viejos():
    """Sin la regla, el -3 consumiría el lote MÁS VIEJO (FIFO) y el desglose por antigüedad quedaría rejuvenecido."""
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 10.0),      # viejo
        _mov(2, "2026-09-01T00:00:00+00:00", 3.0),       # reciente, el erróneo
        _comp(3, "2026-09-02T00:00:00+00:00", -3.0, 2),
    ]
    lotes = calcular_lotes(movimientos)
    assert [(l.movimiento_id, l.restante) for l in lotes] == [(1, 10.0)]
    # y como FIFO normal (sin compensa_movimiento_id) sí se comería el viejo: la diferencia es exactamente la regla nueva
    sin_regla = calcular_lotes(movimientos[:2] + [_mov(3, "2026-09-02T00:00:00+00:00", -3.0)])
    assert [(l.movimiento_id, l.restante) for l in sin_regla] == [(1, 7.0), (2, 3.0)]


def test_compensacion_con_el_lote_ya_parcialmente_consumido_toma_lo_que_le_queda_y_el_resto_va_por_fifo():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 10.0),
        _mov(2, "2026-08-01T00:00:00+00:00", 4.0),                 # el erróneo
        _mov(3, "2026-08-02T00:00:00+00:00", -2.0),                 # un cubrir FIFO: se come 2 del lote 1 (el viejo), no del 2
        _mov(4, "2026-08-03T00:00:00+00:00", -3.0),                 # descontar 3 (FIFO): del lote 1
        _comp(5, "2026-09-01T00:00:00+00:00", -4.0, 2),             # compensa el lote 2 entero (4)
    ]
    lotes = calcular_lotes(movimientos)
    assert [(l.movimiento_id, l.restante) for l in lotes] == [(1, 5.0)]


def test_compensacion_cuyo_lote_ya_fue_consumido_en_parte_por_el_frente_consume_solo_el_remanente_y_el_resto_por_fifo():
    """El lote 1 (3 h) se consumió casi todo por FIFO; el generado erróneo (lote 2, 5 h) quedó con 4 h tras un cubrir de 4 que primero vació el lote 1. Compensar 5 h: 4 del lote 2 + 1 por FIFO del que siga."""
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 3.0),
        _mov(2, "2026-08-01T00:00:00+00:00", 5.0),                  # erróneo
        _mov(3, "2026-08-05T00:00:00+00:00", -4.0),                  # FIFO: vacía el 1 (3) y toma 1 del 2 -> el 2 queda en 4
        _mov(4, "2026-08-06T00:00:00+00:00", 2.0),                   # otro lote (4)
        _comp(5, "2026-09-01T00:00:00+00:00", -5.0, 2),              # compensa 5: 4 del lote 2 y 1 por FIFO (lote 4)
    ]
    lotes = calcular_lotes(movimientos)
    assert [(l.movimiento_id, l.restante) for l in lotes] == [(4, 1.0)]


def test_compensacion_sobre_un_lote_ya_agotado_cae_entera_al_fifo_y_sin_compensa_id_es_un_negativo_normal():
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 2.0),
        _mov(2, "2026-02-01T00:00:00+00:00", 5.0),
        _mov(3, "2026-03-01T00:00:00+00:00", -2.0),                  # FIFO: agota el lote 1
        _comp(4, "2026-04-01T00:00:00+00:00", -2.0, 1),              # apunta al lote 1 (agotado): todo por FIFO sobre el lote 2
    ]
    assert [(l.movimiento_id, l.restante) for l in calcular_lotes(movimientos)] == [(2, 3.0)]
    assert calcular_lotes([_mov(1, "2026-01-01T00:00:00+00:00", 2.0), {**_mov(2, "2026-02-01T00:00:00+00:00", -1.0), "compensa_movimiento_id": None}])[0].restante == 1.0


def test_la_conciliacion_contra_el_monto_sigue_cuadrando_con_compensacion():
    """Σ de los lotes vivos == banco_de_horas.monto: la compensación resta lo mismo que cualquier negativo, solo cambia de DÓNDE."""
    movimientos = [
        _mov(1, "2026-01-01T00:00:00+00:00", 10.0),
        _mov(2, "2026-09-01T00:00:00+00:00", 3.0),
        _comp(3, "2026-09-02T00:00:00+00:00", -3.0, 2),
    ]
    resultado = calcular_antiguedad_saldo(movimientos, 10.0, None, 6, HOY)
    assert resultado.conciliado is True
    assert (resultado.horas_reciente, resultado.horas_media, resultado.horas_fuera_ventana) == (0.0, 0.0, 10.0)   # las 10 h siguen siendo VIEJAS
