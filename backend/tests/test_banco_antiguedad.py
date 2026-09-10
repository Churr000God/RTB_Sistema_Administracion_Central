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
