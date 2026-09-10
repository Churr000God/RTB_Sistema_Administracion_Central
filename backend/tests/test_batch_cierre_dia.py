from datetime import date
from unittest.mock import MagicMock

import pytest
from postgrest.exceptions import APIError

from app.batches.cierre_dia import MOTIVO_PARIDAD_IMPAR, ejecutar_cierre_dia

FECHA = date(2026, 3, 2)  # lunes, ni domingo ni festivo (para los casos "normales")
FECHA_ISO = FECHA.isoformat()
PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"
DIA_ID = 55


# ---------------------------------------------------------------------------
# Mocks por shape exacto de cada cadena de PostgREST usada en cierre_dia.py
# ---------------------------------------------------------------------------


def _tabla_corrida_select(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_corrida_insert(fila):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [fila]
    return tabla


def _tabla_corrida_update(fila):
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.return_value.data = [fila]
    return tabla


def _tabla_dia_festivo(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_jornada_vigentes(personas_ids):
    tabla = MagicMock()
    (
        tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = [{"persona_id": pid} for pid in personas_ids]
    return tabla


def _tabla_dia_estado(datos):
    """_dia_ya_resuelto: select().eq(persona_id).eq(fecha).execute()."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_marca(datos):
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.gte.return_value.lt.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_correccion(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_ausencia_select(datos):
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.gte.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _tabla_ausencia_insert():
    return MagicMock()


def _tabla_ausencia_insert_conflicto():
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": "duplicate key value violates uq_ausencia_falta_persona_fecha"}
    )
    return tabla


def _tabla_dia_insert(dia_id=DIA_ID):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [{"id": dia_id}]
    return tabla


def _tabla_dia_update():
    return MagicMock()


def _tabla_parametro(datos):
    """_resolver_descuento_pausa_no_registrada: select().eq(clave).lte(vigente_desde)
    .order(vigente_desde, desc=True).limit(1).execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.order.return_value.limit
        .return_value.execute.return_value.data
    ) = datos
    return tabla


def _tabla_tramo_insert():
    return MagicMock()


def _tabla_excepcion_insert():
    return MagicMock()


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


def _marca(id_, hora_iso, desfase="+00:00"):
    return {
        "id": id_,
        "momento_dispositivo": f"{FECHA_ISO}T{hora_iso}{desfase}",
        "desfase_local": desfase,
    }


def _entrada_arranque_corrida_primera_vez():
    return [
        ("corrida_batch", _tabla_corrida_select([])),
        ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
    ]


def _entrada_cierre_corrida(estado="exitosa"):
    return [("corrida_batch", _tabla_corrida_update({"id": 1, "estado": estado, "intentos": 1}))]


# ---------------------------------------------------------------------------


def test_paridad_par_arma_tramo_y_cierra_el_dia():
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("parametro", _tabla_parametro([])),
            ("dia", _tabla_dia_update()),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_paridad_impar_bloquea_el_dia_y_crea_excepcion_sin_marca_id():
    marcas = [_marca(101, "09:00:00"), _marca(102, "13:00:00"), _marca(103, "18:00:00")]
    tabla_excepcion = _tabla_excepcion_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),  # tramo completo (09-13)
            ("tramo", _tabla_tramo_insert()),  # tramo abierto (18, sin cierre)
            ("excepcion", tabla_excepcion),
        ]
        + _entrada_cierre_corrida(estado="exitosa")
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_excepcion = tabla_excepcion.insert.call_args[0][0]
    assert payload_excepcion["marca_id"] is None
    assert payload_excepcion["dia_id"] == DIA_ID
    assert payload_excepcion["motivo_revision"] == MOTIVO_PARIDAD_IMPAR


def test_cero_marcas_sin_ausencia_previa_crea_ausencia():
    tabla_ausencia_insert = _tabla_ausencia_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", tabla_ausencia_insert),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload = tabla_ausencia_insert.insert.call_args[0][0]
    assert payload["persona_id"] == PERSONA_1
    assert payload["tipo_de_ausencia"] == "falta"
    assert payload["estado_autorizacion"] == "pendiente"


def test_cero_marcas_con_ausencia_pendiente_no_duplica():
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("ausencia", _tabla_ausencia_select([{"id": 9, "estado_autorizacion": "pendiente"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_cero_marcas_con_ausencia_ya_resuelta_no_hace_nada_mas():
    """G4 (materializar tiempo.dia) es responsabilidad del trigger de SCJ-PRO-08, no de este
    batch -- acá sólo se verifica que no intenta crear una ausencia duplicada ni tocar tiempo.dia."""
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("ausencia", _tabla_ausencia_select([{"id": 9, "estado_autorizacion": "autorizada"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_domingo_no_genera_nada():
    """fecha.weekday()==6 corta por short-circuit antes de consultar tiempo.dia_festivo -- la
    secuencia no incluye esa tabla a propósito, si el código la llamara igual este test fallaría
    por tabla inesperada."""
    domingo = date(2026, 3, 1)
    assert domingo.weekday() == 6
    fake_db = _fake_db(
        [
            ("corrida_batch", _tabla_corrida_select([])),
            ("corrida_batch", _tabla_corrida_insert({"id": 1, "intentos": 1})),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(domingo, fake_db)

    assert resultado["estado"] == "exitosa"


def test_festivo_no_genera_nada():
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([{"fecha": FECHA_ISO}])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_dia_ya_resuelto_se_salta_sin_tocar_marcas():
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([{"id": 1, "estado": "cerrado"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_correccion_aplicada_usa_el_valor_efectivo_no_el_crudo():
    """marca 102 llegó cruda a las 17:00, pero tiene una corrección a las 18:00 -- el tramo debe
    usar el valor corregido (SCJ-PRO-10), no el momento_dispositivo original."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "17:00:00")]
    tabla_tramo = _tabla_tramo_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            (
                "correccion",
                _tabla_correccion(
                    [
                        {
                            "marca_id": 102,
                            "valor_corregido": f"{FECHA_ISO}T18:00:00+00:00",
                            "creado_en": "2026-03-02T20:00:00+00:00",
                        }
                    ]
                ),
            ),
            ("dia", _tabla_dia_insert()),
            ("tramo", tabla_tramo),
            ("parametro", _tabla_parametro([])),
            ("dia", _tabla_dia_update()),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = tabla_tramo.insert.call_args[0][0]
    assert payload_tramo["fin"] == f"{FECHA_ISO}T18:00:00+00:00"
    assert payload_tramo["minutos_trabajados"] == pytest.approx(540.0)  # 09:00 a 18:00


def test_fecha_local_no_la_utc_cruda_decide_a_que_dia_pertenece_la_marca():
    """Una marca guardada con fecha UTC cruda del día SIGUIENTE (2026-03-03T02:00 UTC) pertenece
    localmente a FECHA (2026-03-02 20:00 con desfase -06:00) -- si el batch agrupara por el
    campo crudo en vez de por _fecha_local, esta marca quedaría fuera y la persona caería en el
    flujo de 0 marcas (ausencia) en vez de aparearse con la otra marca del día."""
    marca_local = _marca(101, "09:00:00")  # 2026-03-02T09:00:00+00:00, mismo día en ambos sentidos
    marca_utc_dia_siguiente = {
        "id": 201,
        "momento_dispositivo": "2026-03-03T02:00:00+00:00",
        "desfase_local": "-06:00",
    }
    tabla_tramo = _tabla_tramo_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([marca_local, marca_utc_dia_siguiente])),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", tabla_tramo),
            ("parametro", _tabla_parametro([])),
            ("dia", _tabla_dia_update()),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = tabla_tramo.insert.call_args[0][0]
    assert payload_tramo["marca_apertura_id"] == 101
    assert payload_tramo["marca_cierre_id"] == 201
    assert payload_tramo["fin"] == "2026-03-03T02:00:00+00:00"


def test_error_de_una_persona_no_detiene_a_las_demas_y_marca_fallida():
    tabla_marca_falla = MagicMock()
    tabla_marca_falla.select.return_value.eq.return_value.gte.return_value.lt.return_value.execute.side_effect = RuntimeError(
        "fallo simulado"
    )
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1, PERSONA_2])),
            ("dia", _tabla_dia_estado([])),
            ("marca", tabla_marca_falla),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", _tabla_ausencia_insert()),
        ]
        + _entrada_cierre_corrida(estado="fallida")
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "fallida"


def test_correccion_que_cruza_medianoche_reubica_la_marca_al_dia_efectivo():
    """Hallazgo de security: fn_correccion_valida no impide que una corrección cruce medianoche
    (sólo exige quedar entre las marcas vecinas de la persona). Una marca cuyo momento_dispositivo
    ORIGINAL es del día anterior, pero cuya corrección la mueve a FECHA, debe aparearse con las
    marcas de FECHA -- no quedar huérfana en el día anterior ni ignorada acá."""
    marca_corregida_a_fecha = {
        "id": 301,
        "momento_dispositivo": "2026-03-01T23:50:00+00:00",  # día ANTERIOR a FECHA, sin corregir
        "desfase_local": "+00:00",
    }
    marca_normal = _marca(302, "18:00:00")
    tabla_tramo = _tabla_tramo_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([marca_corregida_a_fecha, marca_normal])),
            (
                "correccion",
                _tabla_correccion(
                    [
                        {
                            "marca_id": 301,
                            "valor_corregido": f"{FECHA_ISO}T00:10:00+00:00",  # ahora sí, FECHA
                            "creado_en": "2026-03-02T08:00:00+00:00",
                        }
                    ]
                ),
            ),
            ("dia", _tabla_dia_insert()),
            ("tramo", tabla_tramo),
            ("parametro", _tabla_parametro([])),
            ("dia", _tabla_dia_update()),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = tabla_tramo.insert.call_args[0][0]
    assert payload_tramo["marca_apertura_id"] == 301
    assert payload_tramo["marca_cierre_id"] == 302
    assert payload_tramo["inicio"] == f"{FECHA_ISO}T00:10:00+00:00"


def test_un_solo_tramo_descuenta_pausa_no_registrada_con_parametro_configurado():
    """09:00 a 18:00 = 540 min, descuento configurado de 90 -> 450 min = 7.5h."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    tabla_dia_update = _tabla_dia_update()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("parametro", _tabla_parametro([{"valor": "90", "vigente_desde": "2026-01-01"}])),
            ("dia", tabla_dia_update),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = tabla_dia_update.update.call_args[0][0]
    assert payload_dia["horas_totales"] == pytest.approx(7.5)


def test_un_solo_tramo_sin_parametro_usa_el_default():
    """Sin fila de parámetro para esa fecha -> default de 60 min. 540 - 60 = 480 min = 8h."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    tabla_dia_update = _tabla_dia_update()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("parametro", _tabla_parametro([])),
            ("dia", tabla_dia_update),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = tabla_dia_update.update.call_args[0][0]
    assert payload_dia["horas_totales"] == pytest.approx(8.0)


def test_dos_tramos_no_descuenta_ni_consulta_parametro():
    """2+ tramos: la pausa sí quedó registrada (el hueco entre tramos) -- sin descuento, y la
    consulta a tiempo.parametro ni siquiera se dispara (si el código la llamara igual, la
    secuencia estricta de _fake_db fallaría por tabla inesperada)."""
    marcas = [
        _marca(101, "09:00:00"),
        _marca(102, "13:00:00"),
        _marca(103, "14:00:00"),
        _marca(104, "18:00:00"),
    ]
    tabla_dia_update = _tabla_dia_update()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("dia", tabla_dia_update),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = tabla_dia_update.update.call_args[0][0]
    # (13-9) + (18-14) = 4h + 4h = 8h, sin descuento.
    assert payload_dia["horas_totales"] == pytest.approx(8.0)


def test_un_solo_tramo_descuento_mayor_a_las_horas_trabajadas_no_queda_negativo():
    """Tramo de 30 min, descuento de 60 -> nunca negativo, queda en 0."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "09:30:00")]
    tabla_dia_update = _tabla_dia_update()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("dia", _tabla_dia_insert()),
            ("tramo", _tabla_tramo_insert()),
            ("parametro", _tabla_parametro([{"valor": "60", "vigente_desde": "2026-01-01"}])),
            ("dia", tabla_dia_update),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = tabla_dia_update.update.call_args[0][0]
    assert payload_dia["horas_totales"] == 0.0


def test_ausencia_carrera_no_revienta_y_queda_pendiente():
    """Hallazgo de security: dos corridas casi simultáneas con 0 marcas para la misma
    persona/fecha -- uq_ausencia_falta_persona_fecha (índice único parcial, confirmado por db)
    rechaza el segundo INSERT con 23505; el batch debe releer en vez de propagar el error."""
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", _tabla_ausencia_insert_conflicto()),
            ("ausencia", _tabla_ausencia_select([{"id": 77, "estado_autorizacion": "pendiente"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
