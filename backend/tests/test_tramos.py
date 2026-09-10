from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"


# ---------------------------------------------------------------------------
# Helpers de gate (mismo estilo que test_tope_legal.py/test_marcas.py)
# ---------------------------------------------------------------------------


def _tabla_select_simple(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_eq_is(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_doble_eq(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _entradas_gate():
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_caller_client_secuencia(secuencia):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    iterador = iter(secuencia)

    def side_effect(nombre_tabla):
        nombre_esperado, mock_tabla = next(iterador)
        assert nombre_tabla == nombre_esperado, f"esperaba tabla {nombre_esperado!r}, llegó {nombre_tabla!r}"
        return mock_tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def _tabla_puesto_permiso_por_codigo(codigos_con_permiso):
    tabla = MagicMock()

    def eq_codigo(campo, valor):
        siguiente = MagicMock()
        tiene = valor in codigos_con_permiso
        siguiente.eq.return_value.execute.return_value.data = (
            [{"puesto_id": GATE_PUESTO_ID}] if tiene else []
        )
        return siguiente

    tabla.select.return_value.eq.side_effect = eq_codigo
    return tabla


def _fake_caller_client_con_permisos(codigos_con_permiso):
    def side_effect(nombre_tabla):
        if nombre_tabla == "usuario":
            return _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])
        if nombre_tabla == "asignacion":
            return _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])
        if nombre_tabla == "puesto_permiso":
            return _tabla_puesto_permiso_por_codigo(codigos_con_permiso)
        if nombre_tabla == "permiso":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": False}
            ]
            return tabla
        return MagicMock()

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _limpiar():
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# Helpers de dato (service client)
# ---------------------------------------------------------------------------


def _tabla_tramo(datos, total):
    """select/in_/gte/lte/order/range encadenan sobre el mismo builder (self) -- sólo execute()
    corta la cadena, así que da igual qué combinación de filtros se haya aplicado."""
    tabla = MagicMock()
    tabla.select.return_value = tabla
    tabla.in_.return_value = tabla
    tabla.gte.return_value = tabla
    tabla.lte.return_value = tabla
    tabla.order.return_value = tabla
    tabla.range.return_value = tabla
    resultado = MagicMock()
    resultado.data = datos
    resultado.count = total
    tabla.execute.return_value = resultado
    return tabla


def _tabla_persona(busqueda_ids=None, nombres=None):
    tabla = MagicMock()
    tabla.select.return_value.or_.return_value.execute.return_value.data = (
        [{"id": pid} for pid in busqueda_ids] if busqueda_ids is not None else []
    )
    tabla.select.return_value.in_.return_value.execute.return_value.data = nombres or []
    return tabla


def _tabla_clasificacion(tipos=None):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = tipos or []
    return tabla


def _fake_service_client(tramo=None, persona=None, clasificacion=None):
    clasificacion = clasificacion if clasificacion is not None else _tabla_clasificacion()

    def side_effect(nombre_tabla):
        if nombre_tabla == "tramo":
            return tramo
        if nombre_tabla == "persona":
            return persona
        if nombre_tabla == "clasificacion_de_tiempo":
            return clasificacion
        return MagicMock()

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _fila_tramo(dia_estado="cerrado", **overrides):
    fila = {
        "id": 4,
        "inicio": "2026-09-08T15:00:00+00:00",
        "fin": "2026-09-09T00:00:00+00:00",
        "minutos_trabajados": 540.0,
        "dia": {"fecha": "2026-09-08", "persona_id": PERSONA_1, "estado": dia_estado},
    }
    fila.update(overrides)
    return fila


def _pedir_tramos(**params):
    client = TestClient(app)
    return client.get("/api/tramos", params=params, headers={"Authorization": "Bearer fake-token"})


def _preparar_gate_y_servicio(tabla_tramo=None, tabla_persona=None, tabla_clasificacion=None):
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _fake_service_client(
        tramo=tabla_tramo, persona=tabla_persona, clasificacion=tabla_clasificacion
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()
    return fake_caller, fake_service


# ---------------------------------------------------------------------------
# GET /api/tramos
# ---------------------------------------------------------------------------


def test_listar_tramos_devuelve_pagina_con_nombre_persona_resuelto_y_campos_aplanados():
    tabla_tramo = _tabla_tramo([_fila_tramo()], total=1)
    tabla_persona = _tabla_persona(nombres=[{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    tramo = cuerpo["tramos"][0]
    assert tramo["fecha"] == "2026-09-08"
    assert tramo["persona_id"] == PERSONA_1
    assert tramo["persona_nombre"] == "Ana Pérez"
    assert tramo["dia_estado"] == "cerrado"
    assert "dia" not in tramo


def test_listar_tramos_con_clasificacion_expone_el_tipo_tal_cual():
    tabla_tramo = _tabla_tramo([_fila_tramo()], total=1)
    tabla_persona = _tabla_persona(nombres=[])
    tabla_clasificacion = _tabla_clasificacion([{"tramo_id": 4, "tipo": "reposicion"}])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona, tabla_clasificacion)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["tramos"][0]["tipo"] == "reposicion"


def test_listar_tramos_sin_clasificacion_tipo_es_none():
    """Tramo sin fila en tiempo.clasificacion_de_tiempo -- típicamente el tramo 'en curso', que
    todavía no pasó por el batch de corte quincenal (SCJ-PRO-13)."""
    fila_abierta = _fila_tramo(dia_estado="abierto", fin=None, minutos_trabajados=None)
    tabla_tramo = _tabla_tramo([fila_abierta], total=1)
    tabla_persona = _tabla_persona(nombres=[])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["tramos"][0]["tipo"] is None


def test_listar_tramos_tramo_abierto_fin_y_minutos_nulos_sobreviven():
    fila_abierta = _fila_tramo(dia_estado="abierto", fin=None, minutos_trabajados=None)
    tabla_tramo = _tabla_tramo([fila_abierta], total=1)
    tabla_persona = _tabla_persona(nombres=[])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    tramo = response.json()["tramos"][0]
    assert tramo["fin"] is None
    assert tramo["minutos_trabajados"] is None
    assert tramo["dia_estado"] == "abierto"


def test_listar_tramos_dia_bloqueado_viaja_tal_cual_desde_el_embed():
    """Tramo 'en curso' que nunca va a cerrarse porque el día quedó bloqueado (SCJ-DEC-06, no se
    reabre automáticamente) -- la señal de alerta que pidió el usuario."""
    fila_bloqueada = _fila_tramo(dia_estado="bloqueado", fin=None, minutos_trabajados=None)
    tabla_tramo = _tabla_tramo([fila_bloqueada], total=1)
    tabla_persona = _tabla_persona(nombres=[])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    tramo = response.json()["tramos"][0]
    assert tramo["dia_estado"] == "bloqueado"


def test_listar_tramos_acepta_filtros_y_paginacion():
    tabla_tramo = _tabla_tramo([_fila_tramo()], total=1)
    tabla_persona = _tabla_persona(nombres=[{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}])
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos(
        desde="2026-01-01",
        hasta="2026-12-31",
        orden="minutos_asc",
        limite=10,
        desplazamiento=20,
    )

    _limpiar()
    assert response.status_code == 200, response.text
    tabla_tramo.gte.assert_called_once_with("dia.fecha", "2026-01-01")
    tabla_tramo.lte.assert_called_once_with("dia.fecha", "2026-12-31")
    tabla_tramo.order.assert_called_once_with("minutos_trabajados", desc=False)
    tabla_tramo.range.assert_called_once_with(20, 29)


def test_listar_tramos_busqueda_sin_coincidencias_no_consulta_tramo():
    tabla_persona = _tabla_persona(busqueda_ids=[])
    fake_caller, fake_service = _preparar_gate_y_servicio(tabla_persona=tabla_persona)

    response = _pedir_tramos(busqueda_persona="nadie-existe")

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "tramos": []}
    tablas_pedidas = {
        llamada.args[0]
        for llamada in fake_service.postgrest.schema.return_value.table.call_args_list
    }
    assert "tramo" not in tablas_pedidas


def test_listar_tramos_busqueda_con_coincidencias_filtra_por_persona_id():
    tabla_tramo = _tabla_tramo([_fila_tramo()], total=1)
    tabla_persona = _tabla_persona(
        busqueda_ids=[PERSONA_1],
        nombres=[{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}],
    )
    _preparar_gate_y_servicio(tabla_tramo, tabla_persona)

    response = _pedir_tramos(busqueda_persona="Ana")

    _limpiar()
    assert response.status_code == 200, response.text
    tabla_tramo.in_.assert_called_once_with("dia.persona_id", [PERSONA_1])


def test_listar_tramos_resultado_vacio_no_consulta_nombres_de_persona():
    tabla_tramo = _tabla_tramo([], total=0)
    fake_caller, fake_service = _preparar_gate_y_servicio(tabla_tramo=tabla_tramo, tabla_persona=None)

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "tramos": []}
    tablas_pedidas = [
        llamada.args[0]
        for llamada in fake_service.postgrest.schema.return_value.table.call_args_list
    ]
    assert "persona" not in tablas_pedidas


def test_listar_tramos_limite_fuera_de_rango_devuelve_422():
    _preparar_gate_y_servicio()

    response = _pedir_tramos(limite=500)

    _limpiar()
    assert response.status_code == 422


def test_listar_tramos_sin_tramo_lectura_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_tramos()

    _limpiar()
    assert response.status_code == 403
