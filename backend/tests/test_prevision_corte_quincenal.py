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


def _tabla_periodo_aplicado(datos):
    """_periodo_ya_aplicado: select().eq().eq().limit(1).execute() sobre la tabla de periodos aplicados."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.limit.return_value.execute.return_value.data = datos
    return tabla


def _tabla_ausencia(datos):
    """_ausencias_con_goce_del_periodo: select().eq().eq().in_().lte().gte().execute() -> [{fecha_inicio, fecha_fin}]."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.in_.return_value.lte.return_value.gte.return_value.execute.return_value.data = [
        {"fecha_inicio": i, "fecha_fin": f} for i, f in datos
    ]
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
    return {"id": id_, "fecha": fecha, "estado": estado, "horas_totales": None}


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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo([_dia(101, PERIODO_DESDE_ISO), _dia(102, PERIODO_HASTA_ISO)])),
            ("tramo", _tabla_tramo_periodo([{"id": 5, "dia_id": 101, "inicio": "2026-03-02T09:00:00+00:00", "minutos_trabajados": 60}])),
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", tabla_jornada_revienta),  # persona 1 revienta
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),  # persona 2 sigue
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo([_dia(101, PERIODO_DESDE_ISO), _dia(102, PERIODO_HASTA_ISO)])),
            ("tramo", _tabla_tramo_periodo([{"id": 5, "dia_id": 101, "inicio": "2026-03-02T09:00:00+00:00", "minutos_trabajados": 60}])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([{"id": 1}])),  # ya procesada
        ]
    )

    pendientes = resolver_personas_con_corte_pendiente(
        fake_db, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert pendientes == {PERSONA_1}


def test_resolver_personas_con_corte_pendiente_periodo_ya_aplicado_no_aparece_sin_calcular():
    """Idempotencia por persona + periodo: con la fila en la tabla de periodos aplicados la previsión no consulta nada más (misma salida que el corte real)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_personas_candidatas([{"persona_id": PERSONA_1}])),
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([{"persona_id": PERSONA_1}])),
        ]
    )

    pendientes = resolver_personas_con_corte_pendiente(
        fake_db, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert pendientes == set()
    fake_db.postgrest.schema.return_value.rpc.assert_not_called()


def test_la_prevision_calcula_igual_que_el_corte_real_incluidos_los_dias_sin_tramos():
    """Dos días de permiso con goce (sin tramos, cubiertos por una ausencia autorizada con goce): la simulación devuelve el MISMO resultado que el corte real (PROCESADA_OK, sin déficit) y no escribe.
    Las horas_totales (aquí 0, o un valor enorme escrito a mano) no intervienen."""
    from app.batches.corte_quincenal import PROCESADA_OK, _procesar_persona

    def armar():
        dias = [{"id": 101, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado", "horas_totales": "0"}, {"id": 102, "fecha": PERIODO_HASTA_ISO, "estado": "cerrado", "horas_totales": "99"}]
        patron = [{"jornada_asignada_id": JORNADA_ID, "dia_semana": d, "hora_entrada": "09:00:00", "hora_salida": "13:00:00", "minutos_comida": 0} for d in ("lunes", "martes")]
        return _fake_db(
            [
                ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
                ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
                ("patron_semanal", _tabla_patron_semanal(patron)),
                ("dia", _tabla_dia_periodo(dias)),
                ("tramo", _tabla_tramo_periodo([])),
                ("ausencia", _tabla_ausencia([(PERIODO_DESDE_ISO, PERIODO_HASTA_ISO)])),
            ]
        )

    args = (PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set())
    simulada, real = armar(), armar()
    assert _procesar_persona(simulada, *args, solo_simular=True) == _procesar_persona(real, *args) == PROCESADA_OK
    simulada.postgrest.schema.return_value.rpc.assert_not_called()
    real.postgrest.schema.return_value.rpc.assert_called_once()


def _tabla_banco_deuda(monto):
    """_deuda_actual: select().eq().execute()."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = [{"id": 9, "monto": monto}]
    return tabla


# (id, lunes: (minutos de tramo | None, horas_totales), martes: idem, deuda | None, resultado, clasificaciones, movimientos, esperadas, trabajadas)
_ESCENARIOS_PREVISION = {
    "tramos_con_deficit": (120, None, 120, None, None, "PROCESADA_DEFICIT", [{"tramo_id": 5, "tipo": "ordinario"}, {"tramo_id": 6, "tipo": "ordinario"}], [{"tramo_id": None, "tipo": "generado_quincena", "monto": 4.0}], 8.0, 4.0),
    "exceso_con_deuda": (300, None, 300, None, "3", "PROCESADA_OK", [{"tramo_id": 5, "tipo": "ordinario"}, {"tramo_id": 6, "tipo": "reposicion"}], [{"tramo_id": 6, "tipo": "cubrir", "monto": -3.0}], 8.0, 10.0),
    "mezcla_tramo_y_permiso_con_exceso": (360, None, None, "permiso", "0", "PROCESADA_OK", [{"tramo_id": 5, "tipo": "extra"}], [], 8.0, 10.0),
}


import pytest  # noqa: E402


@pytest.mark.parametrize("nombre", list(_ESCENARIOS_PREVISION))
def test_la_prevision_calcula_igual_que_el_corte_real_con_tramos_deuda_y_mezcla(nombre):
    """Misma entrada, dos corridas: la simulación devuelve el MISMO resultado que el corte real, no escribe, y el real manda al RPC exactamente la clasificación esperada."""
    from app.batches import corte_quincenal as cq

    minutos_lunes, _, minutos_martes, horas_martes, deuda, esperado, clasificaciones, movimientos, esperadas, trabajadas = _ESCENARIOS_PREVISION[nombre]
    resultado_esperado = getattr(cq, esperado)

    def armar():
        dias = [
            {"id": 101, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado", "horas_totales": "99"},
            {"id": 102, "fecha": PERIODO_HASTA_ISO, "estado": "cerrado", "horas_totales": "99"},
        ]
        tramos = []
        if minutos_lunes:
            tramos.append({"id": 5, "dia_id": 101, "inicio": "2026-03-02T09:00:00+00:00", "minutos_trabajados": minutos_lunes})
        if minutos_martes:
            tramos.append({"id": 6, "dia_id": 102, "inicio": "2026-03-03T09:00:00+00:00", "minutos_trabajados": minutos_martes})
        patron = [{"jornada_asignada_id": JORNADA_ID, "dia_semana": d, "hora_entrada": "09:00:00", "hora_salida": "13:00:00", "minutos_comida": 0} for d in ("lunes", "martes")]
        secuencia = [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal(patron)),
            ("dia", _tabla_dia_periodo(dias)),
            ("tramo", _tabla_tramo_periodo(tramos)),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
        ]
        if not (minutos_lunes and minutos_martes):      # algún día sin tramos: se lee UNA vez la ausencia (aquí «permiso» = una autorizada con goce que cubre el martes)
            secuencia.append(("ausencia", _tabla_ausencia([(PERIODO_HASTA_ISO, PERIODO_HASTA_ISO)] if horas_martes == "permiso" else [])))
        if tramos and resultado_esperado == cq.PROCESADA_OK:
            secuencia.append(("banco_de_horas", _tabla_banco_deuda(deuda or "0")))
        return _fake_db(secuencia)

    args = (PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set())
    simulada, real = armar(), armar()
    assert cq._procesar_persona(simulada, *args, solo_simular=True) == cq._procesar_persona(real, *args) == resultado_esperado
    simulada.postgrest.schema.return_value.rpc.assert_not_called()
    real.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_1, "p_periodo_desde": PERIODO_DESDE_ISO, "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": esperadas, "p_horas_trabajadas": trabajadas,
            "p_clasificaciones": clasificaciones, "p_movimientos": movimientos,
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )
