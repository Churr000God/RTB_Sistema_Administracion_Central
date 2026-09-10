from datetime import date
from unittest.mock import MagicMock, patch

from postgrest.exceptions import APIError

from app.batches.corte_quincenal import (
    PENDIENTE_DIA_ABIERTO,
    PROCESADA_DEFICIT,
    PROCESADA_OK,
    SALTADA_YA_PROCESADA,
    _procesar_persona,
    _rango_periodo,
    ejecutar_corte_quincenal,
)

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"
JORNADA_ID = 1

# Periodo corto de prueba: lunes 2026-03-02 y martes 2026-03-03, ninguno domingo/festivo.
PERIODO_DESDE = date(2026, 3, 2)
PERIODO_HASTA = date(2026, 3, 3)
PERIODO_DESDE_ISO = PERIODO_DESDE.isoformat()
PERIODO_HASTA_ISO = PERIODO_HASTA.isoformat()
DIA_1_ID = 101
DIA_2_ID = 102


# ---------------------------------------------------------------------------
# _rango_periodo -- función pura, sin BD
# ---------------------------------------------------------------------------


def test_rango_periodo_dia_16_cierra_1_al_15_del_mismo_mes():
    assert _rango_periodo(date(2026, 9, 16)) == (date(2026, 9, 1), date(2026, 9, 15))


def test_rango_periodo_dia_1_cierra_16_al_31_del_mes_anterior_31_dias():
    """Agosto tiene 31 días -- el 31 no abre un tercer periodo, cae en el 16-31 de agosto."""
    assert _rango_periodo(date(2026, 9, 1)) == (date(2026, 8, 16), date(2026, 8, 31))


def test_rango_periodo_dia_1_cierra_16_al_30_mes_de_30_dias():
    assert _rango_periodo(date(2026, 10, 1)) == (date(2026, 9, 16), date(2026, 9, 30))


def test_rango_periodo_dia_1_cierra_16_al_28_febrero_no_bisiesto():
    assert _rango_periodo(date(2026, 3, 1)) == (date(2026, 2, 16), date(2026, 2, 28))


def test_rango_periodo_reproceso_manual_un_dia_cualquiera_usa_el_ultimo_periodo_completo():
    """Botón manual disparado un día que no es 1 ni 16 -- sigue resolviendo un periodo válido."""
    assert _rango_periodo(date(2026, 9, 20)) == (date(2026, 9, 1), date(2026, 9, 15))
    assert _rango_periodo(date(2026, 9, 10)) == (date(2026, 8, 16), date(2026, 8, 31))


# ---------------------------------------------------------------------------
# Mocks por shape exacto de cada cadena de PostgREST usada en corte_quincenal.py
# ---------------------------------------------------------------------------


def _tabla_jornadas_persona(datos):
    """_jornadas_del_periodo: select().eq(persona_id).lte().or_().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_patron_semanal(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_dia_periodo(datos):
    """_dias_del_periodo: select().eq(persona_id).gte().lte().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.gte.return_value.lte.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_tramo_periodo(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _tabla_clasificacion_existente(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.limit.return_value.execute.return_value.data = datos
    return tabla


def _tabla_banco_select(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
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


def _jornada(tipo="normal"):
    return {"id": JORNADA_ID, "tipo_jornada": tipo, "vigente_desde": "2026-01-01", "vigente_hasta": None}


def _patron(dia_semana, hora_entrada="09:00:00", hora_salida="13:00:00", minutos_comida=0):
    return {
        "jornada_asignada_id": JORNADA_ID,
        "dia_semana": dia_semana,
        "hora_entrada": hora_entrada,
        "hora_salida": hora_salida,
        "minutos_comida": minutos_comida,
    }


def _dias_lunes_martes(estado_lunes="cerrado", estado_martes="cerrado"):
    return {
        PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": estado_lunes},
        PERIODO_HASTA_ISO: {"id": DIA_2_ID, "fecha": PERIODO_HASTA_ISO, "estado": estado_martes},
    }


def _tramo(id_, minutos_trabajados, inicio="2026-03-02T09:00:00+00:00"):
    return {"id": id_, "inicio": inicio, "minutos_trabajados": minutos_trabajados}


# ---------------------------------------------------------------------------
# _procesar_persona -- casos pedidos por orchestrator
# ---------------------------------------------------------------------------


def test_deficit_de_periodo_todo_ordinario_genera_generado_quincena():
    """esperadas = 8h (2 días x 4h), trabajadas = 4h (un solo tramo, el otro día sin tramo) --
    déficit de 4h. Escritura atómica: una sola llamada al RPC con clasificaciones + movimientos
    ya armados, no inserts sueltos (hallazgo de security)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),  # 4h, sólo el lunes
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_DEFICIT
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_1,
            "p_clasificaciones": [{"tramo_id": 201, "tipo": "ordinario"}],
            "p_movimientos": [{"tramo_id": None, "tipo": "generado_quincena", "monto": 4.0}],
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )


def test_solo_simular_deficit_no_llama_aplicar_persona():
    """Mismo escenario que test_deficit_de_periodo_todo_ordinario_genera_generado_quincena, pero
    con solo_simular=True -- mismo código de retorno, cero escritura."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
        ]
    )

    resultado = _procesar_persona(
        fake_db,
        PERSONA_1,
        PERIODO_DESDE,
        PERIODO_HASTA,
        PERIODO_DESDE_ISO,
        PERIODO_HASTA_ISO,
        set(),
        solo_simular=True,
    )

    assert resultado == PROCESADA_DEFICIT
    fake_db.postgrest.schema.return_value.rpc.assert_not_called()


def test_solo_simular_excedente_no_llama_aplicar_persona():
    """Mismo escenario que test_excedente_con_deuda_previa_clasifica_reposicion_y_cubre, pero con
    solo_simular=True -- mismo código de retorno, cero escritura (sí lee banco_de_horas, es sólo
    lectura)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": "3"}])),
        ]
    )

    resultado = _procesar_persona(
        fake_db,
        PERSONA_1,
        PERIODO_DESDE,
        PERIODO_HASTA,
        PERIODO_DESDE_ISO,
        PERIODO_HASTA_ISO,
        set(),
        solo_simular=True,
    )

    assert resultado == PROCESADA_OK
    fake_db.postgrest.schema.return_value.rpc.assert_not_called()


def test_excedente_con_deuda_previa_clasifica_reposicion_y_cubre():
    """esperadas=8h, trabajadas=10h (4h+6h) -- el segundo tramo cruza el umbral entero (nunca se
    parte). Deuda previa de 3h: reposicion cubre min(6, 3)=3h, deuda queda en 0."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": "3"}])),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_OK
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_1,
            "p_clasificaciones": [
                {"tramo_id": 201, "tipo": "ordinario"},
                {"tramo_id": 202, "tipo": "reposicion"},
            ],
            "p_movimientos": [{"tramo_id": 202, "tipo": "cubrir", "monto": -3.0}],
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )


def test_excedente_sin_deuda_clasifica_extra_sin_movimiento():
    """Mismo excedente que el caso anterior, pero sin deuda previa -- 'extra', nunca toca
    banco_de_horas (p_movimientos va vacío)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": "0"}])),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_OK
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_1,
            "p_clasificaciones": [
                {"tramo_id": 201, "tipo": "ordinario"},
                {"tramo_id": 202, "tipo": "extra"},
            ],
            "p_movimientos": [],
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )


def test_dia_bloqueado_se_excluye_de_esperadas_y_trabajadas():
    """El martes queda bloqueado -- ni su patron_semanal cuenta como esperado, ni su tramo (si lo
    tuviera) se toca. Sólo el lunes entra al cálculo."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes(estado_martes="bloqueado").values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(301, 240)])),  # sólo el tramo del lunes
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": "0"}])),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_OK
    # esperadas = 4h (sólo lunes) == trabajadas = 4h -> ordinario, sin excedente ni déficit
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_1,
            "p_clasificaciones": [{"tramo_id": 301, "tipo": "ordinario"}],
            "p_movimientos": [],
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )


def test_persona_de_confianza_en_todo_el_periodo_queda_excluida():
    """tipo_jornada='de_confianza' durante todo el periodo -- ningún día cuenta como esperado ni
    trabajado, no se toca tramo/clasificacion_de_tiempo ni se llama al RPC en absoluto (nada que
    escribir)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada(tipo="de_confianza")])),
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_OK
    fake_db.postgrest.schema.return_value.rpc.assert_not_called()


def test_periodo_ya_procesado_se_salta_sin_reescribir():
    """Si cualquier tramo elegible del periodo ya tiene clasificacion_de_tiempo, la persona
    entera se salta (idempotencia por persona, decisión propia -- ver docstring del módulo)."""
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([{"id": 999}])),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == SALTADA_YA_PROCESADA


def test_dia_abierto_o_faltante_deja_pendiente_a_la_persona():
    """El martes no tiene tiempo.dia todavía (cierre de día no llegó ahí) -- la persona se salta
    entera, sin escribir nada."""
    dias_incompletos = {PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado"}}
    fake_db = _fake_db(
        [
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(dias_incompletos.values()))),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PENDIENTE_DIA_ABIERTO


# ---------------------------------------------------------------------------
# ejecutar_corte_quincenal -- orquestación completa
# ---------------------------------------------------------------------------


def _entrada_arranque_corrida_primera_vez():
    tabla_select = MagicMock()
    tabla_select.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    tabla_insert = MagicMock()
    tabla_insert.insert.return_value.execute.return_value.data = [{"id": 1, "intentos": 1}]
    return [("corrida_batch", tabla_select), ("corrida_batch", tabla_insert)]


def _entrada_cierre_corrida(estado="exitosa"):
    tabla_update = MagicMock()
    tabla_update.update.return_value.eq.return_value.execute.return_value.data = [
        {"id": 1, "estado": estado, "intentos": 1}
    ]
    return [("corrida_batch", tabla_update)]


def _tabla_festivos(datos):
    tabla = MagicMock()
    tabla.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = datos
    return tabla


def _tabla_personas_periodo(persona_ids):
    tabla = MagicMock()
    (
        tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = [{"persona_id": pid} for pid in persona_ids]
    return tabla


def test_ejecutar_corte_quincenal_dia_abierto_hace_fallar_la_corrida():
    """Una persona pendiente (K1) hace fallar la corrida completa, aunque nadie haya reventado
    con una excepción real -- mismo criterio que un error, para que el mecanismo de reintentos
    la vuelva a intentar. Se parchea _rango_periodo para reusar el periodo corto de 2 días de
    los tests de _procesar_persona -- el real (1-15/16-fin) exigiría fixtures de 15 días."""
    dias_incompletos = {PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado"}}
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_periodo([PERSONA_1])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(dias_incompletos.values()))),
        ]
        + _entrada_cierre_corrida(estado="fallida")
    )

    with patch(
        "app.batches.corte_quincenal._rango_periodo", return_value=(PERIODO_DESDE, PERIODO_HASTA)
    ):
        resultado = ejecutar_corte_quincenal(date(2026, 3, 16), fake_db)

    assert resultado["estado"] == "fallida"


def test_ejecutar_corte_quincenal_dos_personas_una_con_error_no_detiene_a_la_otra():
    """PERSONA_1 revienta en _jornadas_del_periodo; PERSONA_2 sigue su curso normal (déficit,
    una sola llamada al RPC) -- el error de la primera no le impide a la segunda escribir."""
    tabla_jornada_falla = MagicMock()
    tabla_jornada_falla.select.return_value.eq.return_value.lte.return_value.or_.return_value.execute.side_effect = RuntimeError(
        "fallo simulado"
    )
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_periodo([PERSONA_1, PERSONA_2])),
            ("jornada_asignada", tabla_jornada_falla),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
        ]
        + _entrada_cierre_corrida(estado="fallida")
    )

    with patch(
        "app.batches.corte_quincenal._rango_periodo", return_value=(PERIODO_DESDE, PERIODO_HASTA)
    ):
        resultado = ejecutar_corte_quincenal(date(2026, 3, 16), fake_db)

    assert resultado["estado"] == "fallida"
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {
            "p_persona_id": PERSONA_2,
            "p_clasificaciones": [{"tramo_id": 201, "tipo": "ordinario"}],
            "p_movimientos": [{"tramo_id": None, "tipo": "generado_quincena", "monto": 4.0}],
            "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
        },
    )


def test_rpc_error_scj05_se_relanza_con_mensaje_claro_y_aisla_a_la_persona():
    """Defensivo del lado de db: un movimiento con tramo_id fuera de clasificaciones (bug real
    en _procesar_persona, no debería pasar nunca) -- se relanza como RuntimeError con mensaje
    claro y lo captura el try/except de ejecutar_corte_quincenal como el error de esa persona,
    sin detener a las demás ni reventar el proceso."""
    entradas_cierre = _entrada_cierre_corrida(estado="fallida")
    tabla_cierre = entradas_cierre[0][1]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_periodo([PERSONA_1])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
        ]
        + entradas_cierre
    )
    fake_db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ05", "message": "movimiento con tramo_id fuera de p_clasificaciones"}
    )

    with patch(
        "app.batches.corte_quincenal._rango_periodo", return_value=(PERIODO_DESDE, PERIODO_HASTA)
    ):
        resultado = ejecutar_corte_quincenal(date(2026, 3, 16), fake_db)

    assert resultado["estado"] == "fallida"
    detalle_persistido = tabla_cierre.update.call_args[0][0]["detalle"]
    assert "1 error(es)" in detalle_persistido
