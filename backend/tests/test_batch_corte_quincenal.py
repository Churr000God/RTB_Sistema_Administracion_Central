from datetime import date
from unittest.mock import MagicMock, patch

import pytest
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


def _tabla_periodo_aplicado(datos):
    """_periodo_ya_aplicado: select().eq(persona).eq(desde).limit(1).execute() sobre tiempo.corte_quincenal_aplicado (UNIQUE persona_id + periodo_desde)."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.limit.return_value.execute.return_value.data = datos
    return tabla


def _tabla_ausencia(datos):
    """_ausencias_con_goce_del_periodo: select().eq(persona).eq(estado).in_(tipos).lte(inicio, hasta).gte(fin, desde).execute() -> [{fecha_inicio, fecha_fin}]."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.in_.return_value.lte.return_value.gte.return_value.execute.return_value.data = [
        {"fecha_inicio": i, "fecha_fin": f} for i, f in datos
    ]
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
        PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": estado_lunes, "horas_totales": None},
        PERIODO_HASTA_ISO: {"id": DIA_2_ID, "fecha": PERIODO_HASTA_ISO, "estado": estado_martes, "horas_totales": None},
    }


def _tramo(id_, minutos_trabajados, inicio="2026-03-02T09:00:00+00:00", dia_id=DIA_1_ID):
    return {"id": id_, "dia_id": dia_id, "inicio": inicio, "minutos_trabajados": minutos_trabajados}


# ---------------------------------------------------------------------------
# _procesar_persona -- casos pedidos por orchestrator
# ---------------------------------------------------------------------------


def test_deficit_de_periodo_todo_ordinario_genera_generado_quincena():
    """esperadas = 8h (2 días x 4h), trabajadas = 4h (un solo tramo, el otro día sin tramo) --
    déficit de 4h. Escritura atómica: una sola llamada al RPC con clasificaciones + movimientos
    ya armados, no inserts sueltos (hallazgo de security)."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),  # 4h, sólo el lunes
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("ausencia", _tabla_ausencia([])),
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
            "p_periodo_desde": PERIODO_DESDE_ISO,
            "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": 8.0,
            "p_horas_trabajadas": 4.0,
        },
    )


def test_solo_simular_deficit_no_llama_aplicar_persona():
    """Mismo escenario que test_deficit_de_periodo_todo_ordinario_genera_generado_quincena, pero
    con solo_simular=True -- mismo código de retorno, cero escritura."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("ausencia", _tabla_ausencia([])),
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360, dia_id=DIA_2_ID)])),
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360, dia_id=DIA_2_ID)])),
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
            "p_periodo_desde": PERIODO_DESDE_ISO,
            "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": 8.0,
            "p_horas_trabajadas": 10.0,
        },
    )


def test_excedente_sin_deuda_clasifica_extra_sin_movimiento():
    """Mismo excedente que el caso anterior, pero sin deuda previa -- 'extra', nunca toca
    banco_de_horas (p_movimientos va vacío)."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240), _tramo(202, 360, dia_id=DIA_2_ID)])),
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
            "p_periodo_desde": PERIODO_DESDE_ISO,
            "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": 8.0,
            "p_horas_trabajadas": 10.0,
        },
    )


def test_dia_bloqueado_se_excluye_de_esperadas_y_trabajadas():
    """El martes queda bloqueado -- ni su patron_semanal cuenta como esperado, ni su tramo (si lo
    tuviera) se toca. Sólo el lunes entra al cálculo."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
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
            "p_periodo_desde": PERIODO_DESDE_ISO,
            "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": 4.0,
            "p_horas_trabajadas": 4.0,
        },
    )


def test_persona_de_confianza_en_todo_el_periodo_queda_excluida():
    """tipo_jornada='de_confianza' durante todo el periodo -- ningún día cuenta como esperado ni
    trabajado, no se toca tramo/clasificacion_de_tiempo pero el resultado 0 SÍ se registra: el RPC se llama con listas vacías (periodo aplicado)."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada(tipo="de_confianza")])),
            ("patron_semanal", _tabla_patron_semanal([])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
        ]
    )

    resultado = _procesar_persona(
        fake_db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set()
    )

    assert resultado == PROCESADA_OK
    fake_db.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_corte_quincenal_aplicar_persona",
        {"p_persona_id": PERSONA_1, "p_clasificaciones": [], "p_movimientos": [], "p_motivo": f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}",
         "p_periodo_desde": PERIODO_DESDE_ISO, "p_periodo_hasta": PERIODO_HASTA_ISO, "p_horas_esperadas": 0.0, "p_horas_trabajadas": 0.0},
    )


def test_periodo_ya_procesado_se_salta_sin_reescribir():
    """Si cualquier tramo elegible del periodo ya tiene clasificacion_de_tiempo, la persona
    entera se salta (idempotencia por persona, decisión propia -- ver docstring del módulo)."""
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
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
    dias_incompletos = {PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado", "horas_totales": None}}
    fake_db = _fake_db(
        [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
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
    dias_incompletos = {PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado", "horas_totales": None}}
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_periodo([PERSONA_1])),
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", tabla_jornada_falla),
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("ausencia", _tabla_ausencia([])),
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
            "p_periodo_desde": PERIODO_DESDE_ISO,
            "p_periodo_hasta": PERIODO_HASTA_ISO,
            "p_horas_esperadas": 8.0,
            "p_horas_trabajadas": 4.0,
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
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo([_tramo(201, 240)])),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("ausencia", _tabla_ausencia([])),
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


# ---------------------------------------------------------------------------
# Días SIN tramos (permiso con goce, etc.) e idempotencia por persona + periodo
# ---------------------------------------------------------------------------

MOTIVO = f"corte quincenal {PERIODO_DESDE_ISO} a {PERIODO_HASTA_ISO}"


def _dias_con_horas(lunes=None, martes=None):
    return list(
        {
            PERIODO_DESDE_ISO: {"id": DIA_1_ID, "fecha": PERIODO_DESDE_ISO, "estado": "cerrado", "horas_totales": lunes},
            PERIODO_HASTA_ISO: {"id": DIA_2_ID, "fecha": PERIODO_HASTA_ISO, "estado": "cerrado", "horas_totales": martes},
        }.values()
    )


def _db_corte(dias, tramos, banco=None, periodo_aplicado=(), ausencias=None):
    """`ausencias`: None = no se espera la lectura de ausencias (todos los días elegibles tienen tramos); lista de (inicio, fin) = lo que devuelve la consulta."""
    secuencia = [
        ("corte_quincenal_aplicado", _tabla_periodo_aplicado(list(periodo_aplicado))),
        ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
        ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
        ("dia", _tabla_dia_periodo(dias)),
        ("tramo", _tabla_tramo_periodo(tramos)),
    ]
    # Sin tramos no se consulta clasificacion_de_tiempo (nada que mirar): la lectura de ausencias va justo después de tramo.
    if tramos:
        secuencia.append(("clasificacion_de_tiempo", _tabla_clasificacion_existente([])))
    if ausencias is not None:
        secuencia.append(("ausencia", _tabla_ausencia(ausencias)))
    if banco is not None:
        secuencia.append(("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": banco}])))
    return _fake_db(secuencia)


def _correr(db, **kw):
    return _procesar_persona(db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, set(), **kw)


def _rpc(db):
    return db.postgrest.schema.return_value.rpc


def _args_rpc(clasificaciones, movimientos, esperadas=8.0, trabajadas=8.0):
    return {"p_persona_id": PERSONA_1, "p_clasificaciones": clasificaciones, "p_movimientos": movimientos, "p_motivo": MOTIVO,
            "p_periodo_desde": PERIODO_DESDE_ISO, "p_periodo_hasta": PERIODO_HASTA_ISO, "p_horas_esperadas": esperadas, "p_horas_trabajadas": trabajadas}


TODO_EL_PERIODO = [(PERIODO_DESDE_ISO, PERIODO_HASTA_ISO)]


def test_permiso_con_goce_sin_tramos_no_genera_deficit():
    """Caso real del corte 1-15 oct: días 'cerrado' SIN tramos cubiertos por una ausencia autorizada con goce. Valen la esperada del día: 8 h contra 8 -> déficit 0; el resultado 0 se registra igual."""
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=TODO_EL_PERIODO)
    assert _correr(db) == PROCESADA_OK
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([], []))


def test_caso_de_abuso_horas_totales_a_mano_sin_ausencia_da_el_deficit_completo():
    """Un día sin tramos con horas_totales = 8 escrito a mano (fn_dia_revisar o UPDATE directo) y SIN ausencia autorizada NO borra la deuda: trabajadas = 0."""
    db = _db_corte(_dias_con_horas("8", "8"), [], ausencias=[])
    assert _correr(db) == PROCESADA_DEFICIT
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([], [{"tramo_id": None, "tipo": "generado_quincena", "monto": 8.0}], 8.0, 0.0))


def test_la_lectura_de_ausencias_filtra_autorizada_y_solo_tipos_con_goce_en_una_sola_consulta():
    """Pendiente, rechazada, sin goce y falta no cuentan porque la consulta no las trae (el filtro es de la base): se comprueba el filtro exacto y que es UNA consulta por persona."""
    db = _db_corte(_dias_con_horas(), [], ausencias=[])
    _correr(db)
    llamadas_ausencia = [c for c in db.postgrest.schema.return_value.table.call_args_list if c.args == ("ausencia",)]
    assert len(llamadas_ausencia) == 1                       # una vez por persona, no día por día


def test_el_filtro_de_la_consulta_de_ausencias_es_autorizada_y_con_goce():
    from app.batches.corte_quincenal import TIPOS_AUSENCIA_CON_GOCE, _ausencias_con_goce_del_periodo

    tabla = _tabla_ausencia([("2026-03-01", "2026-03-31")])
    fake = MagicMock()
    fake.postgrest.schema.return_value.table.return_value = tabla
    assert _ausencias_con_goce_del_periodo(fake, PERSONA_1, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO) == [("2026-03-01", "2026-03-31")]
    cadena = tabla.select.return_value
    cadena.eq.assert_called_once_with("persona_id", PERSONA_1)
    segundo = cadena.eq.return_value
    segundo.eq.assert_called_once_with("estado_autorizacion", "autorizada")
    segundo.eq.return_value.in_.assert_called_once_with("tipo_de_ausencia", ["vacaciones", "permiso_con_goce", "incapacidad"])
    assert set(TIPOS_AUSENCIA_CON_GOCE) == {"vacaciones", "permiso_con_goce", "incapacidad"}
    ultimo = segundo.eq.return_value.in_.return_value
    ultimo.lte.assert_called_once_with("fecha_inicio", PERIODO_HASTA_ISO)
    ultimo.lte.return_value.gte.assert_called_once_with("fecha_fin", PERIODO_DESDE_ISO)


@pytest.mark.parametrize("ausencia,deficit", [
    (("2026-02-20", "2026-03-02"), 4.0),       # cruza el INICIO del periodo: cubre solo el lunes 2
    (("2026-03-03", "2026-03-20"), 4.0),       # cruza el FIN del periodo: cubre solo el martes 3
    (("2026-02-01", "2026-04-30"), 0.0),       # contiene el periodo entero
    (("2026-03-04", "2026-03-10"), 8.0),       # no toca ningún día del periodo
])
def test_ausencia_de_varios_dias_que_cruza_el_inicio_o_el_fin_del_periodo(ausencia, deficit):
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=[ausencia])
    resultado = _correr(db)
    assert resultado == (PROCESADA_DEFICIT if deficit else PROCESADA_OK)
    argumentos = _rpc(db).call_args.args[1]
    assert argumentos["p_horas_esperadas"] == 8.0 and argumentos["p_horas_trabajadas"] == round(8.0 - deficit, 2)


def test_horas_totales_nulas_sin_ausencia_tambien_dan_deficit_completo():
    db = _db_corte(_dias_con_horas(None, None), [], ausencias=[])
    assert _correr(db) == PROCESADA_DEFICIT
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([], [{"tramo_id": None, "tipo": "generado_quincena", "monto": 8.0}], 8.0, 0.0))


def test_mezcla_dia_con_tramo_y_dia_de_permiso_suma_ambos():
    """Lunes con un tramo de 2 h (manda el tramo, aunque haya una ausencia ese día) + martes de permiso (esperada 4 h) = 6 h contra 8 -> déficit de 2 h."""
    db = _db_corte(_dias_con_horas(lunes="99", martes="0"), [_tramo(201, 120)], ausencias=[("2026-03-03", "2026-03-03")])
    assert _correr(db) == PROCESADA_DEFICIT
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([{"tramo_id": 201, "tipo": "ordinario"}], [{"tramo_id": None, "tipo": "generado_quincena", "monto": 2.0}], 8.0, 6.0))


def test_mezcla_con_exceso_las_horas_de_permiso_consumen_esperadas_primero():
    """Martes de permiso (4 h esperadas, sin tramo) ya consume la mitad de las 8: el tramo de 6 h del lunes (4 + 6 = 10 > 8) es el que excede -> 'extra' sin deuda, 'reposicion' + 'cubrir' con deuda."""
    ausencia = [("2026-03-03", "2026-03-03")]
    sin_deuda = _db_corte(_dias_con_horas(), [_tramo(201, 360)], banco="0", ausencias=ausencia)
    assert _correr(sin_deuda) == PROCESADA_OK
    _rpc(sin_deuda).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([{"tramo_id": 201, "tipo": "extra"}], [], 8.0, 10.0))
    con_deuda = _db_corte(_dias_con_horas(), [_tramo(201, 360)], banco="3", ausencias=ausencia)
    assert _correr(con_deuda) == PROCESADA_OK
    _rpc(con_deuda).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([{"tramo_id": 201, "tipo": "reposicion"}], [{"tramo_id": 201, "tipo": "cubrir", "monto": -3.0}], 8.0, 10.0))


def test_las_horas_de_dias_sin_tramos_nunca_exceden_las_esperadas_ni_dejan_warning(caplog):
    """Cada día sin tramos aporta como mucho su propia esperada: aunque haya varias ausencias traslapadas o horas_totales enormes escritas a mano, trabajadas == esperadas y no hay rama de «exceso»."""
    import logging

    db = _db_corte(_dias_con_horas("24", "24"), [], banco="3", ausencias=[("2026-03-01", "2026-03-10"), ("2026-03-02", "2026-03-03")])
    with caplog.at_level(logging.DEBUG, logger="app.batches.corte_quincenal"):
        assert _correr(db) == PROCESADA_OK
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([], [], 8.0, 8.0))
    assert not caplog.records


def test_una_segunda_corrida_del_mismo_periodo_no_calcula_ni_escribe():
    """Idempotencia por persona + periodo: con la fila en la tabla de periodos aplicados ni siquiera se consulta jornada/día/tramo, y no se llama al RPC (ni en simulación)."""
    for kw in ({}, {"solo_simular": True}):
        db = _fake_db([("corte_quincenal_aplicado", _tabla_periodo_aplicado([{"persona_id": PERSONA_1}]))])
        assert _correr(db, **kw) == SALTADA_YA_PROCESADA
        _rpc(db).assert_not_called()


def test_la_carrera_de_dos_corridas_el_rpc_levanta_scj23_y_queda_saltada():
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=TODO_EL_PERIODO)
    _rpc(db).return_value.execute.side_effect = APIError({"code": "SCJ23", "message": "periodo ya aplicado", "hint": "periodo_ya_aplicado"})
    assert _correr(db) == SALTADA_YA_PROCESADA


def test_el_23505_de_unique_tramo_id_no_es_periodo_ya_aplicado_se_relanza():
    """La carrera de UNIQUE(tramo_id) de clasificacion_de_tiempo sigue siendo un error de esa persona (aislado por ejecutar_corte_quincenal), no un «periodo ya aplicado»."""
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=TODO_EL_PERIODO)
    _rpc(db).return_value.execute.side_effect = APIError({"code": "23505", "message": 'duplicate key value violates unique constraint "uq_clasificacion_tramo"'})
    with pytest.raises(APIError):
        _correr(db)


def test_la_firma_del_rpc_lleva_las_horas_obligatorias_las_fechas_iso_y_los_nombres_exactos():
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=TODO_EL_PERIODO)
    _correr(db)
    argumentos = _rpc(db).call_args.args[1]
    assert set(argumentos) == {"p_persona_id", "p_periodo_desde", "p_periodo_hasta", "p_horas_esperadas", "p_horas_trabajadas", "p_clasificaciones", "p_movimientos", "p_motivo"}
    assert argumentos["p_periodo_desde"] == "2026-03-02" and argumentos["p_periodo_hasta"] == "2026-03-03"
    assert isinstance(argumentos["p_horas_esperadas"], float) and isinstance(argumentos["p_horas_trabajadas"], float)



@pytest.mark.parametrize("minutos_comida", [50, 40, 20, 35, 10])
def test_un_permiso_queda_neutro_al_centesimo_con_minutos_de_comida_no_multiplos_de_3(minutos_comida):
    """El permiso vale la esperada de cada día REDONDEADA a 2 decimales (9 h de jornada menos la comida, p. ej. 8.3333 -> 8.33): esperadas y trabajadas se calculan con el mismo redondeo
    por día y quedan iguales al centésimo (sumar las esperadas sin redondear daba 16.6667 contra 2 x 8.33 = 16.66)."""
    por_dia = round(9 - minutos_comida / 60.0, 2)
    patron = [_patron("lunes", "09:00:00", "18:00:00", minutos_comida), _patron("martes", "09:00:00", "18:00:00", minutos_comida)]
    db = _fake_db([
        ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
        ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
        ("patron_semanal", _tabla_patron_semanal(patron)),
        ("dia", _tabla_dia_periodo(_dias_con_horas())),
        ("tramo", _tabla_tramo_periodo([])),
        ("ausencia", _tabla_ausencia(TODO_EL_PERIODO)),
        ("banco_de_horas", _tabla_banco_select([{"id": 9, "monto": "0"}])),
    ])
    assert _correr(db) == PROCESADA_OK
    argumentos = _rpc(db).call_args.args[1]
    assert argumentos["p_movimientos"] == [] and argumentos["p_horas_esperadas"] == argumentos["p_horas_trabajadas"] == round(2 * por_dia, 2)


def test_otro_error_del_rpc_no_se_confunde_con_duplicado():
    db = _db_corte(_dias_con_horas(), [], banco="0", ausencias=TODO_EL_PERIODO)
    _rpc(db).return_value.execute.side_effect = APIError({"code": "XX000", "message": "otro"})
    with pytest.raises(APIError):
        _correr(db)


def test_el_resultado_cero_se_registra_aunque_no_haya_nada_esperado_ni_trabajado():
    """Persona con jornada pero todo el periodo en festivo: esperadas 0, trabajadas 0 -> el RPC se llama igual, con listas vacías (queda como periodo aplicado)."""
    db = _fake_db([
        ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
        ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
        ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
        ("dia", _tabla_dia_periodo([])),
        ("tramo", _tabla_tramo_periodo([])),
        ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
    ])
    festivos = {PERIODO_DESDE_ISO, PERIODO_HASTA_ISO}
    assert _procesar_persona(db, PERSONA_1, PERIODO_DESDE, PERIODO_HASTA, PERIODO_DESDE_ISO, PERIODO_HASTA_ISO, festivos) == PROCESADA_OK
    _rpc(db).assert_called_once_with("fn_corte_quincenal_aplicar_persona", _args_rpc([], [], 0.0, 0.0))


def test_el_deficit_y_las_trabajadas_se_redondean_a_2_decimales_con_minutos_de_tramo_no_exactos():
    """Tramo de 20 min (0.3333... h) en el lunes + martes de permiso 4 h: trabajadas 4.33, déficit 3.67 (8 - 4.33), sin ruido de punto flotante en lo que viaja al RPC."""
    db = _db_corte(_dias_con_horas(), [_tramo(201, 20)], ausencias=[("2026-03-03", "2026-03-03")])
    assert _correr(db) == PROCESADA_DEFICIT
    argumentos = _rpc(db).call_args.args[1]
    assert argumentos["p_horas_trabajadas"] == 4.33
    assert argumentos["p_movimientos"] == [{"tramo_id": None, "tipo": "generado_quincena", "monto": 3.67}]
    assert argumentos["p_horas_esperadas"] == 8.0


def test_el_deficit_no_arrastra_ruido_de_punto_flotante():
    """Tramo de 21 min (0.35 h) + permiso de 4 h: trabajadas 4.35; 8 - 4.35 en float es 3.6500000000000004 y al RPC debe viajar 3.65."""
    db = _db_corte(_dias_con_horas(), [_tramo(201, 21)], ausencias=[("2026-03-03", "2026-03-03")])
    assert _correr(db) == PROCESADA_DEFICIT
    assert _rpc(db).call_args.args[1]["p_movimientos"] == [{"tramo_id": None, "tipo": "generado_quincena", "monto": 3.65}]


def test_ejecutar_corte_quincenal_scj23_de_una_persona_cuenta_como_saltada_y_la_corrida_no_falla():
    """Carrera: otra corrida ganó el periodo de PERSONA_1 entre el chequeo y el RPC (SCJ23). Es 'ya procesada', no error: la corrida sale 'exitosa', sin errores, y PERSONA_2 se procesa normal."""
    llamadas = []

    def rpc_side_effect(nombre, argumentos):
        llamadas.append(argumentos["p_persona_id"])
        ejecutor = MagicMock()
        if argumentos["p_persona_id"] == PERSONA_1:
            ejecutor.execute.side_effect = APIError({"code": "SCJ23", "message": "periodo ya aplicado", "hint": "periodo_ya_aplicado"})
        return ejecutor

    def persona_completa(tramos):
        return [
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", _tabla_jornadas_persona([_jornada()])),
            ("patron_semanal", _tabla_patron_semanal([_patron("lunes"), _patron("martes")])),
            ("dia", _tabla_dia_periodo(list(_dias_lunes_martes().values()))),
            ("tramo", _tabla_tramo_periodo(tramos)),
            ("clasificacion_de_tiempo", _tabla_clasificacion_existente([])),
            ("ausencia", _tabla_ausencia([])),
        ]

    cierre = _entrada_cierre_corrida(estado="exitosa")
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [("dia_festivo", _tabla_festivos([])), ("jornada_asignada", _tabla_personas_periodo([PERSONA_1, PERSONA_2]))]
        + persona_completa([_tramo(201, 240)])
        + persona_completa([_tramo(202, 240)])
        + cierre
    )
    fake_db.postgrest.schema.return_value.rpc.side_effect = rpc_side_effect

    with patch("app.batches.corte_quincenal._rango_periodo", return_value=(PERIODO_DESDE, PERIODO_HASTA)):
        ejecutar_corte_quincenal(date(2026, 3, 16), fake_db)

    assert llamadas == [PERSONA_1, PERSONA_2]       # PERSONA_2 no se detiene por la carrera de PERSONA_1
    actualizado = cierre[0][1].update.call_args.args[0]
    assert actualizado["estado"] == "exitosa"
    assert "1 ya procesada(s)" in actualizado["detalle"] and "1 con déficit" in actualizado["detalle"]
    assert "error(es)" not in actualizado["detalle"]


def test_el_detalle_de_la_corrida_no_lleva_persona_id_y_el_log_del_servidor_si_sin_texto_de_error(caplog):
    """corrida_batch.detalle lo lee cualquier persona activa: solo conteos. Los persona_id con su error acotado (clase o sqlstate, sin texto) van al log del servidor; el resumen no lleva ids."""
    import logging

    cierre = _entrada_cierre_corrida(estado="fallida")
    tabla_jornada_falla = MagicMock()
    tabla_jornada_falla.select.return_value.eq.return_value.lte.return_value.or_.return_value.execute.side_effect = APIError({"code": "57014", "message": "TEXTO-SENSIBLE de la base"})
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_festivos([])),
            ("jornada_asignada", _tabla_personas_periodo([PERSONA_1])),
            ("corte_quincenal_aplicado", _tabla_periodo_aplicado([])),
            ("jornada_asignada", tabla_jornada_falla),
        ]
        + cierre
    )
    with caplog.at_level(logging.DEBUG, logger="app.batches.corte_quincenal"), patch("app.batches.corte_quincenal._rango_periodo", return_value=(PERIODO_DESDE, PERIODO_HASTA)):
        ejecutar_corte_quincenal(date(2026, 3, 16), fake_db)

    detalle = cierre[0][1].update.call_args.args[0]["detalle"]
    assert "1 error(es) -- ver logs del servidor." in detalle and PERSONA_1 not in detalle and "57014" not in detalle
    mensajes = [r.getMessage() for r in caplog.records]
    resumen = next(m for m in mensajes if "errores=1" in m)
    assert PERIODO_DESDE_ISO in resumen and PERSONA_1 not in resumen
    con_ids = next(m for m in mensajes if "personas con error" in m)
    assert PERSONA_1 in con_ids and "sqlstate=57014" in con_ids and "TEXTO-SENSIBLE" not in " ".join(mensajes)


def test_el_log_del_servidor_acota_la_lista_de_personas_con_error():
    """lista_acotada: con más errores que el máximo, los primeros y un «y N más» (no vuelca todos los ids de golpe)."""
    from app.registro_seguro import MAXIMO_EN_LISTA, lista_acotada

    muchos = [f"persona-{i}: RuntimeError" for i in range(MAXIMO_EN_LISTA + 7)]
    acotada = lista_acotada(muchos)
    assert len(acotada) == MAXIMO_EN_LISTA + 1 and acotada[-1] == "y 7 más"
