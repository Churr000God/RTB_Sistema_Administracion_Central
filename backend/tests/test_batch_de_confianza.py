from datetime import date
from unittest.mock import MagicMock

from postgrest.exceptions import APIError

from app.batches.de_confianza import ejecutar_batch_de_confianza

FECHA = date(2026, 9, 6)
PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"
PERSONA_3 = "cccccccc-0000-0000-0000-000000000003"


def _tabla_corrida_select(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_corrida_insert(fila):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [fila]
    return tabla


def _tabla_corrida_insert_conflicto():
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": "duplicate key value violates uq_corrida_batch_tipo_fecha"}
    )
    return tabla


def _tabla_corrida_update(fila):
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.return_value.data = [fila]
    return tabla


def _tabla_jornada_vigentes(personas_ids):
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = [{"persona_id": pid} for pid in personas_ids]
    return tabla


def _tabla_dia(comportamiento_por_persona: dict):
    """comportamiento_por_persona: {persona_id: None (éxito) | APIError (se relanza como
    side_effect) | "duplicado" (23505, idempotente)}."""
    tabla = MagicMock()

    def insert_side_effect(datos):
        resultado = MagicMock()
        comportamiento = comportamiento_por_persona[datos["persona_id"]]
        if comportamiento == "duplicado":
            resultado.execute.side_effect = APIError(
                {"code": "23505", "message": "duplicate key value violates uq_dia_persona_fecha"}
            )
        elif comportamiento is not None:
            resultado.execute.side_effect = comportamiento
        else:
            resultado.execute.return_value.data = [datos]
        return resultado

    tabla.insert.side_effect = insert_side_effect
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


def test_primera_corrida_del_dia_arranca_con_intentos_1():
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
            ("jornada_asignada", _tabla_jornada_vigentes([])),
            ("corrida_batch", _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_carrera_en_insert_corrida_releé_y_actualiza_en_vez_de_500():
    """Job programado y botón manual cayendo a la vez para el mismo (tipo_batch, fecha): el
    SELECT inicial no ve nada, pero el INSERT choca con uq_corrida_batch_tipo_fecha (23505) --
    debe releer la fila que ganó la carrera y actualizarla, no propagar el error."""
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert_conflicto()),
            ("corrida_batch", _tabla_corrida_select([{"id": 9, "intentos": 1}])),
            ("corrida_batch", _tabla_corrida_update({"id": 9, "intentos": 2, "estado": "en_progreso"})),
            ("jornada_asignada", _tabla_jornada_vigentes([])),
            ("corrida_batch", _tabla_corrida_update({"id": 9, "estado": "exitosa", "intentos": 2})),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    assert resultado["intentos"] == 2


def test_corrida_existente_incrementa_intentos():
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([{"id": 7, "intentos": 2}])),
            ("corrida_batch", _tabla_corrida_update({"id": 7, "intentos": 3, "estado": "en_progreso"})),
            ("jornada_asignada", _tabla_jornada_vigentes([])),
            ("corrida_batch", _tabla_corrida_update({"id": 7, "estado": "exitosa", "intentos": 3})),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["intentos"] == 3


def test_crea_dia_para_personas_de_confianza_vigentes_estado_exitosa():
    tabla_dia = _tabla_dia({PERSONA_1: None, PERSONA_2: None})
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1, PERSONA_2])),
            ("dia", tabla_dia),
            ("dia", tabla_dia),
            (
                "corrida_batch",
                _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1}),
            ),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    assert tabla_dia.insert.call_count == 2


def test_dia_ya_existente_es_idempotente_no_cuenta_como_error():
    tabla_dia = _tabla_dia({PERSONA_1: "duplicado"})
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", tabla_dia),
            (
                "corrida_batch",
                _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1}),
            ),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_error_de_una_persona_no_detiene_a_las_demas_y_marca_fallida():
    tabla_dia = _tabla_dia(
        {
            PERSONA_1: None,
            PERSONA_2: RuntimeError("fallo simulado de red"),
            PERSONA_3: None,
        }
    )
    tabla_corrida_update_final = _tabla_corrida_update({"id": 1, "estado": "fallida", "intentos": 1})
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1, PERSONA_2, PERSONA_3])),
            ("dia", tabla_dia),
            ("dia", tabla_dia),
            ("dia", tabla_dia),
            ("corrida_batch", tabla_corrida_update_final),
        ]
    )

    resultado = ejecutar_batch_de_confianza(FECHA, fake_db)

    assert resultado["estado"] == "fallida"
    assert tabla_dia.insert.call_count == 3
    # RLS de corrida_batch sólo exige fn_caller_activo(), sin permiso específico -- el detalle
    # persistido no debe llevar persona_id crudo (security, ver bitácora del hallazgo).
    detalle_persistido = tabla_corrida_update_final.update.call_args[0][0]["detalle"]
    assert PERSONA_2 not in detalle_persistido
