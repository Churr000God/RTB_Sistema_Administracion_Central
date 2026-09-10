from datetime import time
from unittest.mock import MagicMock

from app.hora_cierre_dia import (
    HORA_CORRIDA_CIERRE_DIA_POR_DEFECTO,
    HORA_CORTE_DIA_POR_DEFECTO,
    resolver_umbral_cierre_dia,
    resolver_umbral_cierre_dia_cron,
)

FECHA = "2026-09-09"


def _fake_db(valores):
    """valores: {clave: valor_str}. Un solo mock de tabla distingue cada llamada por el valor
    pasado a .eq('clave', ...) -- se leen 2 claves por separado (hora_corte_dia,
    hora_corrida_cierre_dia)."""
    fake_client = MagicMock()
    tabla = MagicMock()

    def eq_side_effect(campo, valor_clave):
        assert campo == "clave"
        resultado = MagicMock()
        datos = [{"valor": valores[valor_clave]}] if valor_clave in valores else []
        (
            resultado.lte.return_value.order.return_value.limit.return_value.execute
            .return_value.data
        ) = datos
        return resultado

    tabla.select.return_value.eq.side_effect = eq_side_effect
    fake_client.postgrest.schema.return_value.table.return_value = tabla
    return fake_client


def test_resolver_umbral_suma_las_2_claves_sin_desborde():
    db = _fake_db({"hora_corte_dia": "01:15", "hora_corrida_cierre_dia": "02:30"})
    assert resolver_umbral_cierre_dia(db, FECHA) == time(3, 45)


def test_resolver_umbral_desborda_24h():
    """22:00 + 05:30 = 27:30 -> % 24h = 03:30, no un valor > 23:59 inválido."""
    db = _fake_db({"hora_corte_dia": "22:00", "hora_corrida_cierre_dia": "05:30"})
    assert resolver_umbral_cierre_dia(db, FECHA) == time(3, 30)


def test_resolver_umbral_sin_filas_usa_fallback_de_las_2_claves():
    db = _fake_db({})
    esperado_minutos = (
        HORA_CORTE_DIA_POR_DEFECTO.hour * 60
        + HORA_CORTE_DIA_POR_DEFECTO.minute
        + HORA_CORRIDA_CIERRE_DIA_POR_DEFECTO.hour * 60
        + HORA_CORRIDA_CIERRE_DIA_POR_DEFECTO.minute
    )
    assert resolver_umbral_cierre_dia(db, FECHA) == time(
        esperado_minutos // 60, esperado_minutos % 60
    )


def test_resolver_umbral_con_solo_una_fila_usa_fallback_para_la_otra():
    db = _fake_db({"hora_corte_dia": "01:00"})
    assert resolver_umbral_cierre_dia(db, FECHA) == time(4, 0)  # 01:00 + 03:00 (default)


def test_resolver_umbral_cron_devuelve_tupla_hora_minuto():
    db = _fake_db({"hora_corte_dia": "01:15", "hora_corrida_cierre_dia": "02:30"})
    assert resolver_umbral_cierre_dia_cron(db, FECHA) == (3, 45)
