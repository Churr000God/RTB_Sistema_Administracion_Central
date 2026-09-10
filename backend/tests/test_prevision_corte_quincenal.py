from datetime import date
from unittest.mock import MagicMock

from app.prevision_corte_quincenal import (
    resolver_dias_faltantes,
    resolver_periodo_en_curso,
    resolver_personas_con_corte_pendiente,
)

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"
JORNADA_ID = 1
JORNADA_ID_2 = 2


# ---------------------------------------------------------------------------
# resolver_periodo_en_curso -- función pura, sin BD
# ---------------------------------------------------------------------------


def test_resolver_periodo_en_curso_primera_mitad():
    assert resolver_periodo_en_curso(date(2026, 9, 8)) == (date(2026, 9, 1), date(2026, 9, 15))


def test_resolver_periodo_en_curso_segunda_mitad_mes_30_dias():
    assert resolver_periodo_en_curso(date(2026, 9, 20)) == (date(2026, 9, 16), date(2026, 9, 30))


def test_resolver_periodo_en_curso_segunda_mitad_mes_31_dias():
    assert resolver_periodo_en_curso(date(2026, 8, 20)) == (date(2026, 8, 16), date(2026, 8, 31))


def test_resolver_periodo_en_curso_segunda_mitad_febrero_no_bisiesto():
    assert resolver_periodo_en_curso(date(2026, 2, 20)) == (date(2026, 2, 16), date(2026, 2, 28))


def test_resolver_periodo_en_curso_segunda_mitad_febrero_bisiesto():
    assert resolver_periodo_en_curso(date(2028, 2, 20)) == (date(2028, 2, 16), date(2028, 2, 29))


def test_resolver_periodo_en_curso_borde_dia_15_es_primera_mitad():
    assert resolver_periodo_en_curso(date(2026, 9, 15)) == (date(2026, 9, 1), date(2026, 9, 15))


def test_resolver_periodo_en_curso_borde_dia_16_es_segunda_mitad():
    assert resolver_periodo_en_curso(date(2026, 9, 16)) == (date(2026, 9, 16), date(2026, 9, 30))


# ---------------------------------------------------------------------------
# Mocks por shape exacto de cada cadena de PostgREST usada (reusadas de corte_quincenal.py)
# ---------------------------------------------------------------------------


def _tabla_festivos(datos):
    """_festivos_del_periodo: select().gte().lte().execute()."""
    tabla = MagicMock()
    tabla.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = datos
    return tabla


def _tabla_personas_candidatas(datos):
    """_personas_normal_flexible_del_periodo: select().in_().lte().or_().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_jornadas_persona(datos):
    """_jornadas_del_periodo: select().eq(persona_id).lte().or_().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_dia_periodo(datos):
    """_dias_del_periodo: select().eq(persona_id).gte().lte().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.gte.return_value.lte.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_patron_semanal(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_tramo_periodo(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _tabla_clasificacion_existente(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.limit.return_value.execute.return_value.data = datos
    return tabla


def _fake_db(secuencia):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    iterador = iter(secuencia)

    def side_effect(nombre_tabla):
        nombre_esperado, mock_tabla = next(iterador)
        assert nombre_tabla == nombre_esperado, f"esperaba tabla {nombre_esperado!r}, llegó {nombre_tabla!r}"
        return mock_tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def _jornada(id_=JORNADA_ID, tipo="normal", vigente_desde="2026-01-01", vigente_hasta=None):
    return {"id": id_, "tipo_jornada": tipo, "vigente_desde": vigente_desde, "vigente_hasta": vigente_hasta}


def _dia(id_, fecha, estado="cerrado"):
    return {"id": id_, "fecha": fecha, "estado": estado}


# ---------------------------------------------------------------------------
# resolver_dias_faltantes
# ---------------------------------------------------------------------------


def test_resolver_dias_faltantes_detecta_hueco_y_excluye_hoy_y_futuro():
    """Periodo 09-01..09-04, hoy=09-03 -- candidatas son 09-01/09-02 (09-03 es hoy, excluido;
    09-04 es futuro, excluido). 09-01 tiene tiempo.dia, 09-02 no -- sólo ésa aparece."""
    fake_db = _fake_db(
        [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("dia", _tabla_dia_periodo([_dia(1, "2026-09-01")])),
        ]
    )

    faltantes = resolver_dias_faltantes(fake_db, date(2026, 9, 1), date(2026, 9, 4), date(2026, 9, 3))

    assert faltantes == [{"persona_id": PERSONA_1, "fecha": "2026-09-02"}]


def test_resolver_dias_faltantes_sin_huecos_no_aparece():
    fake_db = _fake_db(
        [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("dia", _tabla_dia_periodo([_dia(1, "2026-09-01"), _dia(2, "2026-09-02")])),
        ]
    )

    faltantes = resolver_dias_faltantes(fake_db, date(2026, 9, 1), date(2026, 9, 4), date(2026, 9, 3))

    assert faltantes == []


def test_resolver_dias_faltantes_excluye_domingo_y_festivo():
    """Periodo 09-05 (sábado) a 09-07 (lunes), hoy=09-08 -- los 3 días son "antes de hoy".
    09-05 es festivo, 09-06 es domingo -- sólo 09-07 (lunes) es candidata, y le falta el día."""
    fake_db = _fake_db(
        [
            ("dia_festivo", _tabla_festivos([{"fecha": "2026-09-05"}])),
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("dia", _tabla_dia_periodo([])),
        ]
    )

    faltantes = resolver_dias_faltantes(fake_db, date(2026, 9, 5), date(2026, 9, 7), date(2026, 9, 8))

    assert faltantes == [{"persona_id": PERSONA_1, "fecha": "2026-09-07"}]


def test_resolver_dias_faltantes_persona_de_confianza_esa_fecha_excluida():
    """09-02 tiene una jornada de_confianza vigente ese día puntual (vigente_desde más reciente
    gana el tiebreak) -- se excluye aunque le falte tiempo.dia; 09-01 sigue con la jornada normal."""
    fake_db = _fake_db(
        [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            (
                "jornada_asignada",
                _tabla_jornadas_persona(
                    [
                        _jornada(JORNADA_ID, "normal", "2026-01-01", None),
                        _jornada(JORNADA_ID_2, "de_confianza", "2026-09-02", "2026-09-02"),
                    ]
                ),
            ),
            ("dia", _tabla_dia_periodo([])),
        ]
    )

    faltantes = resolver_dias_faltantes(fake_db, date(2026, 9, 1), date(2026, 9, 2), date(2026, 9, 3))

    assert faltantes == [{"persona_id": PERSONA_1, "fecha": "2026-09-01"}]


# ---------------------------------------------------------------------------
# resolver_personas_con_corte_pendiente
# ---------------------------------------------------------------------------

PERIODO_DESDE = date(2026, 3, 2)  # lunes
PERIODO_HASTA = date(2026, 3, 3)  # martes
PERIODO_DESDE_ISO = PERIODO_DESDE.isoformat()
PERIODO_HASTA_ISO = PERIODO_HASTA.isoformat()


def test_resolver_personas_con_corte_pendiente_ya_procesada_no_aparece():
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo([_dia(101, PERIODO_DESDE_ISO), _dia(102, PERIODO_HASTA_ISO)])),
            ("tramo", _tabla_tramo_periodo([{"id": 5, "inicio": "2026-03-02T09:00:00+00:00", "minutos_trabajados": 60}])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([{"id": 1}])),
        ]
    )

    pendientes = resolver_personas_con_corte_pendiente(
        fake_db, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert pendientes == set()


def test_resolver_personas_con_corte_pendiente_dia_faltante_aparece():
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo([_dia(101, PERIODO_DESDE_ISO)])),  # falta el martes
        ]
    )

    pendientes = resolver_personas_con_corte_pendiente(
        fake_db, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert pendientes == {PERSONA_1}


def test_resolver_personas_con_corte_pendiente_excepcion_de_una_no_tumba_a_las_demas():
    tabla_jornada_revienta = MagicMock()
    tabla_jornada_revienta.select.return_value.eq.return_value.lte.return_value.or_.return_value.execute.side_effect = RuntimeError(
        "fallo simulado"
    )
    fake_db = _fake_db(
        [
            (
                "jornada_asignada",
                _tabla_personas_candidatas([{"persona_id": PERSONA_1}, {"persona_id": PERSONA_2}]),
            ),
            ("jornada_asignada", tabla_jornada_revienta),  # persona 1 revienta
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),  # persona 2 sigue
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo([_dia(101, PERIODO_DESDE_ISO), _dia(102, PERIODO_HASTA_ISO)])),
            ("tramo", _tabla_tramo_periodo([{"id": 5, "inicio": "2026-03-02T09:00:00+00:00", "minutos_trabajados": 60}])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([{"id": 1}])),  # ya procesada
        ]
    )

    pendientes = resolver_personas_con_corte_pendiente(
        fake_db, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert pendientes == {PERSONA_1}
