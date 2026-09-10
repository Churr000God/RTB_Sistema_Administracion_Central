from unittest.mock import MagicMock

from app.banco_alertas_magnitud import (
    AVISO_PCT_POR_DEFECTO,
    ESCALAMIENTO_PCT_POR_DEFECTO,
    clasificar_nivel_deuda,
    resolver_jornadas_semanales,
    resolver_umbrales_pct,
)

FECHA = "2026-09-09"


def _fake_db_jornadas(jornada_filas, patron_filas):
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "jornada_asignada":
            (
                tabla.select.return_value.in_.return_value.in_.return_value.lte.return_value.or_
                .return_value.execute.return_value.data
            ) = jornada_filas
        elif nombre_tabla == "patron_semanal":
            tabla.select.return_value.in_.return_value.execute.return_value.data = patron_filas
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _fila_patron(jornada_id, dia_semana, hora_entrada, hora_salida, minutos_comida=0):
    return {
        "jornada_asignada_id": jornada_id,
        "dia_semana": dia_semana,
        "hora_entrada": hora_entrada,
        "hora_salida": hora_salida,
        "minutos_comida": minutos_comida,
    }


# ---------------------------------------------------------------------------
# resolver_umbrales_pct
# ---------------------------------------------------------------------------


def test_resolver_umbrales_usa_los_valores_sembrados():
    """Un solo mock de tabla distingue cada clave por el valor pasado a .eq('clave', ...) --
    umbral_aviso_pct y umbral_escalamiento_pct se leen por separado, mismo valor no sirve para
    distinguir la clave correcta de la incorrecta."""
    tabla = MagicMock()

    def eq_side_effect(campo, valor_clave):
        assert campo == "clave"
        resultado = MagicMock()
        valores = {"umbral_aviso_pct": "150", "umbral_escalamiento_pct": "250"}
        datos = [{"valor": valores[valor_clave]}] if valor_clave in valores else []
        resultado.lte.return_value.order.return_value.limit.return_value.execute.return_value.data = datos
        return resultado

    tabla.select.return_value.eq.side_effect = eq_side_effect
    fake_db = MagicMock()
    fake_db.postgrest.schema.return_value.table.return_value = tabla

    assert resolver_umbrales_pct(fake_db, FECHA) == (150, 250)


def test_resolver_umbrales_sin_filas_usa_default():
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.lte.return_value.order.return_value.limit.return_value.execute.return_value.data = []
    fake_db = MagicMock()
    fake_db.postgrest.schema.return_value.table.return_value = tabla

    assert resolver_umbrales_pct(fake_db, FECHA) == (
        AVISO_PCT_POR_DEFECTO,
        ESCALAMIENTO_PCT_POR_DEFECTO,
    )


# ---------------------------------------------------------------------------
# resolver_jornadas_semanales
# ---------------------------------------------------------------------------


def test_resolver_jornadas_persona_normal_con_patron_de_5_dias():
    jornada_filas = [{"id": 1, "persona_id": "p1", "vigente_desde": "2026-01-01"}]
    patron_filas = [
        _fila_patron(1, dia, "08:00", "17:00", 60)
        for dia in ("lunes", "martes", "miercoles", "jueves", "viernes")
    ]
    fake_db = _fake_db_jornadas(jornada_filas, patron_filas)

    resultado = resolver_jornadas_semanales(fake_db, ["p1"], FECHA)

    assert resultado == {"p1": 40.0}  # 8h - 1h comida = 8h/dia * 5


def test_resolver_jornadas_de_confianza_devuelve_none():
    """La query ya filtra tipo_jornada in (normal, flexible) -- de_confianza nunca aparece en
    jornada_filas, ni siquiera hay que excluirla en Python."""
    fake_db = _fake_db_jornadas([], [])

    resultado = resolver_jornadas_semanales(fake_db, ["p_confianza"], FECHA)

    assert resultado == {"p_confianza": None}


def test_resolver_jornadas_sin_jornada_vigente_devuelve_none():
    fake_db = _fake_db_jornadas([], [])

    resultado = resolver_jornadas_semanales(fake_db, ["p_sin_jornada"], FECHA)

    assert resultado == {"p_sin_jornada": None}


def test_resolver_jornadas_jornada_partida_suma_las_2_filas_del_mismo_dia():
    jornada_filas = [{"id": 2, "persona_id": "p2", "vigente_desde": "2026-01-01"}]
    patron_filas = [
        _fila_patron(2, "lunes", "08:00", "12:00", 0),  # matutino
        _fila_patron(2, "lunes", "14:00", "18:00", 0),  # vespertino
    ]
    fake_db = _fake_db_jornadas(jornada_filas, patron_filas)

    resultado = resolver_jornadas_semanales(fake_db, ["p2"], FECHA)

    assert resultado == {"p2": 8.0}  # 4h + 4h, sin comida que restar


def test_resolver_jornadas_toma_la_vigente_desde_mas_reciente_si_hay_2_candidatas():
    jornada_filas = [
        {"id": 10, "persona_id": "p3", "vigente_desde": "2026-01-01"},
        {"id": 11, "persona_id": "p3", "vigente_desde": "2026-06-01"},  # más reciente -- gana
    ]
    patron_filas = [
        _fila_patron(10, "lunes", "08:00", "20:00", 0),  # jornada vieja, 12h/dia (no debe usarse)
        _fila_patron(11, "lunes", "08:00", "12:00", 0),  # jornada nueva, 4h/dia
    ]
    fake_db = _fake_db_jornadas(jornada_filas, patron_filas)

    resultado = resolver_jornadas_semanales(fake_db, ["p3"], FECHA)

    assert resultado == {"p3": 4.0}


# ---------------------------------------------------------------------------
# clasificar_nivel_deuda
# ---------------------------------------------------------------------------


def test_clasificar_sin_alerta_por_debajo_del_umbral_de_aviso():
    assert clasificar_nivel_deuda(10.0, 40.0, aviso_pct=100, escalamiento_pct=200) == "sin_alerta"


def test_clasificar_exactamente_en_el_umbral_de_aviso_es_inclusivo():
    assert clasificar_nivel_deuda(40.0, 40.0, aviso_pct=100, escalamiento_pct=200) == "aviso"


def test_clasificar_entre_aviso_y_escalamiento():
    assert clasificar_nivel_deuda(60.0, 40.0, aviso_pct=100, escalamiento_pct=200) == "aviso"


def test_clasificar_exactamente_en_el_umbral_de_escalamiento_es_inclusivo():
    assert clasificar_nivel_deuda(80.0, 40.0, aviso_pct=100, escalamiento_pct=200) == "escalamiento"


def test_clasificar_jornada_none_devuelve_none():
    assert clasificar_nivel_deuda(10.0, None, aviso_pct=100, escalamiento_pct=200) is None


def test_clasificar_jornada_cero_devuelve_none():
    assert clasificar_nivel_deuda(10.0, 0.0, aviso_pct=100, escalamiento_pct=200) is None
