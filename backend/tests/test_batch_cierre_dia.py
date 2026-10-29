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


def _tabla_jornada_vigente_persona(datos):
    """_fecha_en_patron (1/2): select(id).eq(persona).in_(tipo).lte().or_().order().limit(1).execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.in_.return_value.lte.return_value.or_.return_value
        .order.return_value.limit.return_value.execute.return_value.data
    ) = datos
    return tabla


def _tabla_patron_dia(datos):
    """_fecha_en_patron (2/2): select(id).eq(jornada).eq(dia_semana).limit(1).execute()."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.limit.return_value.execute.return_value.data = datos
    return tabla


def _entrada_en_patron(en_patron=True, jornada_id=7):
    """Las dos consultas que hace el batch para un día SIN marcas: jornada vigente y fila del patrón."""
    return [
        ("jornada_asignada", _tabla_jornada_vigente_persona([{"id": jornada_id}])),
        ("patron_semanal", _tabla_patron_dia([{"id": 1}] if en_patron else [])),
    ]


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


def _tabla_parametro(datos):
    """_resolver_descuento_pausa_no_registrada: select().eq(clave).lte(vigente_desde)
    .order(vigente_desde, desc=True).limit(1).execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.lte.return_value.order.return_value.limit
        .return_value.execute.return_value.data
    ) = datos
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


def _marca(id_, hora_iso, desfase="+00:00"):
    return {
        "id": id_,
        "momento_dispositivo": f"{FECHA_ISO}T{hora_iso}{desfase}",
        "desfase_local": desfase,
    }


def _llamada_rpc(fake_db):
    """La ÚNICA llamada a tiempo.fn_cierre_dia_armar: (nombre, argumentos nombrados)."""
    llamadas = fake_db.postgrest.schema.return_value.rpc.call_args_list
    assert len(llamadas) == 1, llamadas
    return llamadas[0].args[0], llamadas[0].args[1]


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
            ("parametro", _tabla_parametro([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_paridad_impar_bloquea_el_dia_y_crea_excepcion_sin_marca_id():
    marcas = [_marca(101, "09:00:00"), _marca(102, "13:00:00"), _marca(103, "18:00:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
        ]
        + _entrada_cierre_corrida(estado="exitosa")
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    nombre, argumentos = _llamada_rpc(fake_db)
    assert nombre == "fn_cierre_dia_armar"
    assert argumentos["p_estado"] == "bloqueado" and argumentos["p_horas_totales"] is None
    assert argumentos["p_motivo_excepcion_dia"] == MOTIVO_PARIDAD_IMPAR          # la excepción de día (marca_id NULL) la inserta la propia RPC


def test_cero_marcas_sin_ausencia_previa_crea_ausencia():
    tabla_ausencia_insert = _tabla_ausencia_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
        ]
        + _entrada_en_patron()
        + [
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
        ]
        + _entrada_en_patron()
        + [
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
        ]
        + _entrada_en_patron()
        + [
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
            ("parametro", _tabla_parametro([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = _llamada_rpc(fake_db)[1]["p_tramos"][0]
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
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([marca_local, marca_utc_dia_siguiente])),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = _llamada_rpc(fake_db)[1]["p_tramos"][0]
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
        ]
        + _entrada_en_patron()
        + [
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
            ("parametro", _tabla_parametro([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_tramo = _llamada_rpc(fake_db)[1]["p_tramos"][0]
    assert payload_tramo["marca_apertura_id"] == 301
    assert payload_tramo["marca_cierre_id"] == 302
    assert payload_tramo["inicio"] == f"{FECHA_ISO}T00:10:00+00:00"


def test_un_solo_tramo_descuenta_pausa_no_registrada_con_parametro_configurado():
    """09:00 a 18:00 = 540 min, descuento configurado de 90 -> 450 min = 7.5h."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([{"valor": "90", "vigente_desde": "2026-01-01"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = {"horas_totales": _llamada_rpc(fake_db)[1]["p_horas_totales"]}
    assert payload_dia["horas_totales"] == pytest.approx(7.5)


def test_un_solo_tramo_sin_parametro_usa_el_default():
    """Sin fila de parámetro para esa fecha -> default de 60 min. 540 - 60 = 480 min = 8h."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = {"horas_totales": _llamada_rpc(fake_db)[1]["p_horas_totales"]}
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
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = {"horas_totales": _llamada_rpc(fake_db)[1]["p_horas_totales"]}
    # (13-9) + (18-14) = 4h + 4h = 8h, sin descuento.
    assert payload_dia["horas_totales"] == pytest.approx(8.0)


def test_un_solo_tramo_descuento_mayor_a_las_horas_trabajadas_no_queda_negativo():
    """Tramo de 30 min, descuento de 60 -> nunca negativo, queda en 0."""
    marcas = [_marca(101, "09:00:00"), _marca(102, "09:30:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([{"valor": "60", "vigente_desde": "2026-01-01"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"
    payload_dia = {"horas_totales": _llamada_rpc(fake_db)[1]["p_horas_totales"]}
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
        ]
        + _entrada_en_patron()
        + [
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", _tabla_ausencia_insert_conflicto()),
            ("ausencia", _tabla_ausencia_select([{"id": 77, "estado_autorizacion": "pendiente"}])),
        ]
        + _entrada_cierre_corrida()
    )

    resultado = ejecutar_cierre_dia(FECHA, fake_db)

    assert resultado["estado"] == "exitosa"


def test_tiempos_incoherentes_de_una_persona_es_fallo_controlado_con_hint_en_el_log_y_sin_tumbar_la_corrida(monkeypatch, caplog):
    """123_: trg_tramo_valida_tiempos rechaza el tramo de PERSONA_1 (SCJ15 / tramo_tiempos_incoherentes). La corrida sigue con PERSONA_2, termina 'fallida' (la persona hay que revisarla), el log lleva
    el SQLSTATE y el hint estables y NUNCA el texto de la base; el detalle persistido solo lleva conteos."""
    import logging

    from app.batches import cierre_dia

    marcas = [{"id": 1, "efectivo": None}, {"id": 2, "efectivo": None}]
    armadas = []

    def armar(db, persona_id, fecha_iso, marcas_dia):
        if persona_id == PERSONA_1:
            raise APIError({"code": "SCJ15", "hint": "tramo_tiempos_incoherentes", "message": "TEXTO-DE-LA-BASE con ids 9981"})
        armadas.append(persona_id)
        return True

    monkeypatch.setattr(cierre_dia, "_personas_normal_flexible_vigentes", lambda db, f: [PERSONA_1, PERSONA_2])
    monkeypatch.setattr(cierre_dia, "_dia_ya_resuelto", lambda db, p, f: False)
    monkeypatch.setattr(cierre_dia, "_es_festivo", lambda db, f: False)
    monkeypatch.setattr(cierre_dia, "_marcas_efectivas_del_dia", lambda db, p, f: marcas)
    monkeypatch.setattr(cierre_dia, "_armar_dia_par", armar)
    monkeypatch.setattr(cierre_dia, "upsert_corrida_en_progreso", lambda db, tipo, fecha: {"id": 1})
    finalizado = {}
    monkeypatch.setattr(cierre_dia, "finalizar_corrida", lambda db, id_, estado, detalle: finalizado.update(estado=estado, detalle=detalle) or finalizado)

    with caplog.at_level(logging.DEBUG, logger="app.batches.cierre_dia"):
        resultado = ejecutar_cierre_dia(FECHA, MagicMock())

    assert armadas == [PERSONA_2]                                       # PERSONA_2 se procesó pese al fallo de PERSONA_1
    assert resultado["estado"] == "fallida" and "1 error(es)" in resultado["detalle"] and "9981" not in resultado["detalle"]
    registro = " ".join(r.getMessage() for r in caplog.records)
    assert "sqlstate=SCJ15 hint=tramo_tiempos_incoherentes" in registro
    assert "TEXTO-DE-LA-BASE" not in registro and "9981" not in registro


# ---------------------------------------------------------------------------
# 124_: el día y TODOS sus tramos (y la excepción de paridad) en UNA llamada atómica
# ---------------------------------------------------------------------------


def _correr_una_persona(marcas, rpc_efecto=None, parametro=None, dia_tras_rpc=None):
    secuencia = (
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
        ]
        + ([("parametro", _tabla_parametro(parametro or []))] if len(marcas) == 2 else [])
        + ([("dia", _tabla_dia_estado(dia_tras_rpc))] if dia_tras_rpc is not None else [])      # la relectura de `_dia_ya_resuelto` tras dia_ya_existe
    )
    cierre = _entrada_cierre_corrida(estado="fallida" if rpc_efecto else "exitosa")
    fake_db = _fake_db(secuencia + cierre)
    if rpc_efecto:
        fake_db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = rpc_efecto
    resultado = dict(ejecutar_cierre_dia(FECHA, fake_db))
    resultado["detalle"] = cierre[0][1].update.call_args[0][0]["detalle"]          # lo que se PERSISTE en corrida_batch
    return fake_db, resultado


def test_dia_par_manda_el_payload_exacto_a_la_rpc():
    marcas = [_marca(101, "09:00:00"), _marca(102, "13:00:00"), _marca(103, "14:00:00"), _marca(104, "18:00:00")]
    fake_db, resultado = _correr_una_persona(marcas)
    assert resultado["estado"] == "exitosa"
    nombre, argumentos = _llamada_rpc(fake_db)
    assert nombre == "fn_cierre_dia_armar"
    assert argumentos == {
        "p_persona_id": PERSONA_1,
        "p_fecha": FECHA_ISO,
        "p_estado": "cerrado",
        "p_horas_totales": 8.0,              # (13-9) + (18-14), sin descuento con 2 tramos
        "p_tramos": [
            {"marca_apertura_id": 101, "marca_cierre_id": 102, "inicio": f"{FECHA_ISO}T09:00:00+00:00", "fin": f"{FECHA_ISO}T13:00:00+00:00", "minutos_trabajados": 240.0},
            {"marca_apertura_id": 103, "marca_cierre_id": 104, "inicio": f"{FECHA_ISO}T14:00:00+00:00", "fin": f"{FECHA_ISO}T18:00:00+00:00", "minutos_trabajados": 240.0},
        ],
        "p_motivo_excepcion_dia": None,
    }


def test_dia_par_de_un_solo_tramo_descuenta_la_pausa_en_las_horas_no_en_el_tramo():
    fake_db, _ = _correr_una_persona([_marca(101, "09:00:00"), _marca(102, "18:00:00")], parametro=[{"valor": "90", "vigente_desde": "2026-01-01"}])
    argumentos = _llamada_rpc(fake_db)[1]
    assert argumentos["p_horas_totales"] == pytest.approx(7.5)                         # 540 - 90 min
    assert argumentos["p_tramos"][0]["minutos_trabajados"] == pytest.approx(540.0)     # el tramo conserva los minutos reales


def test_dia_impar_manda_payload_exacto_con_el_tramo_abierto_ultimo_y_el_motivo():
    marcas = [_marca(101, "09:00:00"), _marca(102, "13:00:00"), _marca(103, "18:00:00")]
    fake_db, resultado = _correr_una_persona(marcas)
    assert resultado["estado"] == "exitosa"
    nombre, argumentos = _llamada_rpc(fake_db)
    assert nombre == "fn_cierre_dia_armar"
    assert argumentos == {
        "p_persona_id": PERSONA_1,
        "p_fecha": FECHA_ISO,
        "p_estado": "bloqueado",
        "p_horas_totales": None,
        "p_tramos": [
            {"marca_apertura_id": 101, "marca_cierre_id": 102, "inicio": f"{FECHA_ISO}T09:00:00+00:00", "fin": f"{FECHA_ISO}T13:00:00+00:00", "minutos_trabajados": 240.0},
            {"marca_apertura_id": 103, "marca_cierre_id": None, "inicio": f"{FECHA_ISO}T18:00:00+00:00", "fin": None, "minutos_trabajados": None},
        ],
        "p_motivo_excepcion_dia": MOTIVO_PARIDAD_IMPAR,
    }


def test_una_sola_marca_impar_es_un_unico_tramo_abierto():
    fake_db, _ = _correr_una_persona([_marca(101, "09:00:00")])
    tramos = _llamada_rpc(fake_db)[1]["p_tramos"]
    assert tramos == [{"marca_apertura_id": 101, "marca_cierre_id": None, "inicio": f"{FECHA_ISO}T09:00:00+00:00", "fin": None, "minutos_trabajados": None}]


def _error_rpc(code, hint):
    return APIError({"code": code, "hint": hint, "message": "TEXTO-DE-LA-BASE con ids 9981"})


def test_dia_ya_existe_se_cuenta_como_saltada_y_no_falla_la_corrida():
    fake_db, resultado = _correr_una_persona([_marca(101, "09:00:00"), _marca(102, "13:00:00"), _marca(103, "14:00:00"), _marca(104, "18:00:00")], rpc_efecto=_error_rpc("SCJ27", "dia_ya_existe"), dia_tras_rpc=[{"id": 9, "estado": "cerrado"}])
    assert "1 saltada(s)" in resultado["detalle"] and "0 cerrado(s)" in resultado["detalle"] and "error(es)" not in resultado["detalle"]


def test_dia_ya_existe_impar_tambien_es_saltada():
    _, resultado = _correr_una_persona([_marca(101, "09:00:00")], rpc_efecto=_error_rpc("SCJ27", "dia_ya_existe"), dia_tras_rpc=[{"id": 9, "estado": "bloqueado"}])
    assert "1 saltada(s)" in resultado["detalle"] and "0 bloqueado(s)" in resultado["detalle"] and "error(es)" not in resultado["detalle"]


def test_dia_ya_existe_con_el_dia_abierto_NO_se_oculta_como_saltada_es_fallo_controlado(caplog):
    """Un día existente en estado 'abierto' no es un día resuelto: la RPC dice dia_ya_existe pero `_dia_ya_resuelto` es False al releer. Contarlo como «saltada» lo dejaría sin cerrar nunca y en
    silencio; se relanza como fallo de esa persona (visible)."""
    import logging

    with caplog.at_level(logging.DEBUG, logger="app.batches.cierre_dia"):
        _, resultado = _correr_una_persona([_marca(101, "09:00:00"), _marca(102, "18:00:00")], rpc_efecto=_error_rpc("SCJ27", "dia_ya_existe"), dia_tras_rpc=[{"id": 9, "estado": "abierto"}])
    assert resultado["estado"] == "fallida" and "1 error(es)" in resultado["detalle"] and "saltada" in resultado["detalle"] and "0 saltada(s)" in resultado["detalle"]
    assert "sqlstate=SCJ27 hint=dia_ya_existe" in " ".join(r.getMessage() for r in caplog.records)


def test_dia_ya_existe_pero_el_dia_desaparecio_al_releer_tambien_es_fallo():
    """Si al releer no hay día (condición rara), tampoco se da por resuelto."""
    _, resultado = _correr_una_persona([_marca(101, "09:00:00"), _marca(102, "18:00:00")], rpc_efecto=_error_rpc("SCJ27", "dia_ya_existe"), dia_tras_rpc=[])
    assert resultado["estado"] == "fallida" and "0 saltada(s)" in resultado["detalle"]


@pytest.mark.parametrize("code,hint", [
    ("SCJ27", "estado_invalido"), ("SCJ27", "tramos_inconsistentes"), ("SCJ27", "horas_fuera_de_rango"), ("SCJ27", None), ("SCJ15", "tramo_incoherente"), ("SCJ15", "tramo_tiempos_incoherentes"),
    ("23503", None), ("23505", None), ("XX000", None),
])
def test_cualquier_otro_error_de_la_rpc_es_fallo_controlado_de_esa_persona(code, hint, caplog):
    import logging

    with caplog.at_level(logging.DEBUG, logger="app.batches.cierre_dia"):
        _, resultado = _correr_una_persona([_marca(101, "09:00:00"), _marca(102, "18:00:00")], rpc_efecto=_error_rpc(code, hint))
    assert resultado["estado"] == "fallida" and "1 error(es)" in resultado["detalle"] and "0 cerrado(s)" in resultado["detalle"]
    registro = " ".join(r.getMessage() for r in caplog.records)
    assert f"sqlstate={code}" in registro and "TEXTO-DE-LA-BASE" not in registro and "9981" not in registro
    if code.startswith("SCJ") and hint:
        assert f"hint={hint}" in registro


def test_un_fallo_de_una_persona_no_impide_cerrar_a_la_siguiente():
    llamadas = []

    def rpc(nombre, argumentos):
        llamadas.append(argumentos["p_persona_id"])
        ejecutor = MagicMock()
        if argumentos["p_persona_id"] == PERSONA_1:
            ejecutor.execute.side_effect = _error_rpc("SCJ15", "tramo_tiempos_incoherentes")
        return ejecutor

    marcas = [_marca(101, "09:00:00"), _marca(102, "13:00:00")]
    cierre = _entrada_cierre_corrida(estado="fallida")
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1, PERSONA_2])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([])),
        ]
        + cierre
    )
    fake_db.postgrest.schema.return_value.rpc.side_effect = rpc
    ejecutar_cierre_dia(FECHA, fake_db)
    resultado = {"detalle": cierre[0][1].update.call_args[0][0]["detalle"]}
    assert llamadas == [PERSONA_1, PERSONA_2] and "1 cerrado(s)" in resultado["detalle"] and "1 error(es)" in resultado["detalle"]


def test_cierre_dia_ya_no_inserta_dia_tramo_ni_excepcion_con_llamadas_sueltas():
    """Guarda: la secuencia insert día + tramos + excepción era no atómica (un fallo a medias dejaba un día sin sus tramos que `_dia_ya_resuelto` saltaba para siempre). Hoy todo va por la RPC."""
    import ast
    from pathlib import Path

    arbol = ast.parse((Path(__file__).resolve().parents[1] / "app" / "batches" / "cierre_dia.py").read_text(encoding="utf-8"))
    escrituras = []
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Attribute) and nodo.func.attr in {"insert", "update", "upsert", "delete"}:
            origen = nodo.func.value
            while isinstance(origen, (ast.Call, ast.Attribute)):
                if isinstance(origen, ast.Call) and isinstance(origen.func, ast.Attribute) and origen.func.attr == "table" and origen.args and isinstance(origen.args[0], ast.Constant):
                    escrituras.append(origen.args[0].value)
                    break
                origen = origen.func.value if isinstance(origen, ast.Call) else origen.value
    assert not {"dia", "tramo", "excepcion"} & set(escrituras), escrituras
    assert escrituras == ["ausencia"]            # la única escritura suelta que queda: la solicitud de falta (un solo INSERT, atómico por sí mismo)


# --- contrato con db/ddl/124_*.sql ----------------------------------------------------------------------------------------------------------------------


def _sql_124():
    from pathlib import Path

    archivos = sorted((Path(__file__).resolve().parents[2] / "db" / "ddl").glob("124_*.sql"))
    assert archivos, "no se encontró db/ddl/124_*.sql"
    return archivos[0].read_text(encoding="utf-8")


def test_el_contrato_los_nombres_de_parametros_y_hints_del_backend_existen_en_124():
    import re

    from app.batches import cierre_dia

    sql = _sql_124()
    firma = re.search(r"CREATE FUNCTION tiempo\.fn_cierre_dia_armar\((.*?)\)\s*RETURNS bigint", sql, re.S).group(1)
    parametros_sql = [linea.strip().split()[0] for linea in firma.split(",") if linea.strip()]
    capturado = {}
    db = MagicMock()
    db.postgrest.schema.return_value.rpc.side_effect = lambda nombre, args: capturado.update(nombre=nombre, args=args) or MagicMock()
    cierre_dia._armar_dia(db, PERSONA_1, FECHA_ISO, "cerrado", 8.0, [], None)
    assert capturado["nombre"] == "fn_cierre_dia_armar"
    assert list(capturado["args"]) == parametros_sql == ["p_persona_id", "p_fecha", "p_estado", "p_horas_totales", "p_tramos", "p_motivo_excepcion_dia"]
    assert "ERRCODE = 'SCJ27', HINT = 'dia_ya_existe'" in sql
    assert cierre_dia.CODIGO_CIERRE_DIA == "SCJ27" and cierre_dia.HINT_DIA_YA_EXISTE == "dia_ya_existe"
    assert "GRANT EXECUTE ON FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text) TO service_role" in sql
    for estado in ("cerrado", "bloqueado"):
        assert f"'{estado}'" in sql
    assert f"'{MOTIVO_PARIDAD_IMPAR}'" in sql or "paridad_impar" in sql                     # el motivo que manda el batch es el que documenta 124_
    for hint in ("estado_invalido", "tramos_inconsistentes", "horas_fuera_de_rango"):
        assert f"HINT = '{hint}'" in sql


def test_el_payload_de_los_tramos_usa_las_claves_que_lee_la_rpc():
    import re

    sql = _sql_124()
    claves_sql = set(re.findall(r"jsonb_to_recordset\(p_tramos\) AS \((.*?)\)\)", sql, re.S)[0].replace("\n", " ").split(","))
    claves_sql = {c.strip().split()[0] for c in claves_sql}
    from app.batches.cierre_dia import _payload_tramo

    payload, _ = _payload_tramo({"id": 1, "efectivo": __import__("datetime").datetime(2026, 3, 2, 9, tzinfo=__import__("datetime").timezone.utc)}, None)
    assert set(payload) == claves_sql


# ---------------------------------------------------------------------------
# P-191: un día que el patrón semanal no espera trabajado no genera falta (SCJ-PRO-08 A1)
# ---------------------------------------------------------------------------


def _detalle_y_estado(tabla_update):
    payload = tabla_update.update.call_args[0][0]
    return payload["estado"], payload["detalle"]


def test_dia_fuera_del_patron_sin_marcas_no_crea_falta_y_cuenta_como_saltada():
    """Lunes que el patrón (p. ej. martes a sábado) no espera trabajado: sin marcas no se crea tiempo.ausencia. La secuencia termina en el patrón: cualquier
    consulta a ausencia rompería el mock y la corrida quedaría 'fallida'."""
    tabla_cierre = _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})
    tabla_patron = _tabla_patron_dia([])
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("jornada_asignada", _tabla_jornada_vigente_persona([{"id": 7}])),
            ("patron_semanal", tabla_patron),
            ("corrida_batch", tabla_cierre),
        ]
    )

    ejecutar_cierre_dia(FECHA, fake_db)

    estado, detalle = _detalle_y_estado(tabla_cierre)
    assert estado == "exitosa"
    assert "0 ausencia(s) creada(s), 1 saltada(s)" in detalle
    # Consulta el patrón de ESA jornada y ESE día de la semana (FECHA es lunes).
    tabla_patron.select.return_value.eq.assert_called_once_with("jornada_asignada_id", 7)
    tabla_patron.select.return_value.eq.return_value.eq.assert_called_once_with("dia_semana", "lunes")


def test_dia_en_el_patron_sin_marcas_sigue_creando_la_falta():
    """Persona de lunes a sábado: mismo comportamiento de siempre."""
    tabla_cierre = _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})
    tabla_ausencia_insert = _tabla_ausencia_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
        ]
        + _entrada_en_patron(en_patron=True)
        + [
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", tabla_ausencia_insert),
            ("corrida_batch", tabla_cierre),
        ]
    )

    ejecutar_cierre_dia(FECHA, fake_db)

    estado, detalle = _detalle_y_estado(tabla_cierre)
    assert estado == "exitosa"
    assert "1 ausencia(s) creada(s), 0 saltada(s)" in detalle
    assert tabla_ausencia_insert.insert.call_args[0][0]["tipo_de_ausencia"] == "falta"


def test_dia_fuera_del_patron_con_marcas_se_procesa_igual_y_no_consulta_el_patron():
    """Las marcas nunca se descartan: si la persona trabajó su día de descanso, el día se arma como cualquier otro (cerrado con su tramo). El patrón solo se mira sin
    marcas, así que no aparece en la secuencia."""
    tabla_cierre = _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})
    marcas = [_marca(101, "09:00:00"), _marca(102, "18:00:00")]
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca(marcas)),
            ("correccion", _tabla_correccion([])),
            ("parametro", _tabla_parametro([])),
            ("corrida_batch", tabla_cierre),
        ]
    )

    ejecutar_cierre_dia(FECHA, fake_db)

    estado, detalle = _detalle_y_estado(tabla_cierre)
    assert estado == "exitosa" and detalle.startswith("1 cerrado(s)")
    assert _llamada_rpc(fake_db)[1]["p_estado"] == "cerrado"


def test_sin_jornada_vigente_al_releer_conserva_el_comportamiento_anterior_y_crea_la_falta():
    tabla_cierre = _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})
    tabla_ausencia_insert = _tabla_ausencia_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
            ("jornada_asignada", _tabla_jornada_vigente_persona([])),
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", tabla_ausencia_insert),
            ("corrida_batch", tabla_cierre),
        ]
    )

    ejecutar_cierre_dia(FECHA, fake_db)

    estado, detalle = _detalle_y_estado(tabla_cierre)
    assert estado == "exitosa" and "1 ausencia(s) creada(s)" in detalle


def test_dos_personas_una_descansa_por_patron_y_la_otra_recibe_su_falta():
    tabla_cierre = _tabla_corrida_update({"id": 1, "estado": "exitosa", "intentos": 1})
    tabla_ausencia_insert = _tabla_ausencia_insert()
    fake_db = _fake_db(
        _entrada_arranque_corrida_primera_vez()
        + [
            ("dia_festivo", _tabla_dia_festivo([])),
            ("jornada_asignada", _tabla_jornada_vigentes([PERSONA_1, PERSONA_2])),
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
        ]
        + _entrada_en_patron(en_patron=False, jornada_id=7)
        + [
            ("dia", _tabla_dia_estado([])),
            ("marca", _tabla_marca([])),
        ]
        + _entrada_en_patron(en_patron=True, jornada_id=8)
        + [
            ("ausencia", _tabla_ausencia_select([])),
            ("ausencia", tabla_ausencia_insert),
            ("corrida_batch", tabla_cierre),
        ]
    )

    ejecutar_cierre_dia(FECHA, fake_db)

    estado, detalle = _detalle_y_estado(tabla_cierre)
    assert estado == "exitosa" and "1 ausencia(s) creada(s), 1 saltada(s)" in detalle
    assert tabla_ausencia_insert.insert.call_args[0][0]["persona_id"] == PERSONA_2
