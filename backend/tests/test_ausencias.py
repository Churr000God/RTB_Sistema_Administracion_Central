from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

AUSENCIA_ID = 5
PERSONA_ID = "persona-caller"
PUESTO_ID = "puesto-caller"
PERSONA_ID_AUSENCIA = "aaaaaaaa-0000-0000-0000-000000000001"
CALLER_IDENTITY = CallerIdentity(auth_user_id="auth-caller", correo="caller@example.com")


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


def _tabla_ausencia_pendientes(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _tabla_persona_in(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_ausencia_lista(datos, total):
    """select/in_/gte/lte/eq/order/range encadenan sobre el mismo builder (self) -- sólo
    execute() corta la cadena, así que da igual qué combinación de filtros se haya aplicado."""
    tabla = MagicMock()
    for metodo in ("select", "in_", "gte", "lte", "eq", "order", "range", "or_"):
        getattr(tabla, metodo).return_value = tabla
    resultado = MagicMock()
    resultado.data = datos
    resultado.count = total
    tabla.execute.return_value = resultado
    return tabla


def _tabla_aprobacion(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _entradas_gate_and():
    """requiere_todos_los_permisos exige AND (ausencia_edicion Y aprobacion_ausencia_edicion) --
    tiene_permiso se llama una vez por código, cada una resuelve puestos vigentes + poseedores
    desde cero."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
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
            [{"puesto_id": PUESTO_ID}] if tiene else []
        )
        return siguiente

    tabla.select.return_value.eq.side_effect = eq_codigo
    return tabla


def _fake_caller_client_con_permisos(codigos_con_permiso):
    def side_effect(nombre_tabla):
        if nombre_tabla == "usuario":
            return _tabla_select_simple([{"persona_id": PERSONA_ID}])
        if nombre_tabla == "asignacion":
            return _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])
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
    app.dependency_overrides[get_caller_identity] = lambda: CALLER_IDENTITY


def _fila_ausencia(**overrides):
    fila = {
        "id": AUSENCIA_ID,
        "persona_id": PERSONA_ID_AUSENCIA,
        "tipo_de_ausencia": "falta",
        "fecha_inicio": "2026-01-01",
        "fecha_fin": "2026-01-01",
        "estado_autorizacion": "pendiente",
        "documento_ref": None,
    }
    fila.update(overrides)
    return fila


def _fila_persona_ausencia(**overrides):
    fila = {"id": PERSONA_ID_AUSENCIA, "primer_nombre": "Ficticia", "apellido_paterno": "Alfa"}
    fila.update(overrides)
    return fila


APROBADOR_ID = "aaaaaaaa-0000-0000-0000-000000000009"


def _fila_aprobacion(**overrides):
    fila = {
        "ausencia_id": AUSENCIA_ID,
        "numero_paso": 1,
        "aprobador_id": APROBADOR_ID,
        "motivo": "vacaciones justificadas",
        "decidido_en": "2026-01-02T10:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _pedir_ausencias(**params):
    client = TestClient(app)
    return client.get(
        "/api/ausencias", params=params, headers={"Authorization": "Bearer fake-token"}
    )


def test_listar_ausencias_devuelve_pagina_con_nombre_resuelto():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3]
        + [
            ("ausencia", _tabla_ausencia_lista([_fila_ausencia()], total=1)),
            ("persona", _tabla_persona_in([_fila_persona_ausencia()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias()

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    ausencia = cuerpo["ausencias"][0]
    assert ausencia["persona_nombre"] == "Ficticia Alfa"
    assert ausencia["aprobador_nombre"] is None
    assert ausencia["motivo"] is None
    assert ausencia["decidido_en"] is None


def test_listar_ausencias_acepta_filtros_orden_y_paginacion():
    tabla_ausencia = _tabla_ausencia_lista([_fila_ausencia()], total=1)
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3]
        + [
            ("ausencia", tabla_ausencia),
            ("persona", _tabla_persona_in([_fila_persona_ausencia()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias(
        desde="2026-01-01",
        hasta="2026-12-31",
        tipo="vacaciones",
        estado="pendiente",
        orden="fecha_asc",
        limite=10,
        desplazamiento=20,
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    tabla_ausencia.gte.assert_called_once_with("fecha_inicio", "2026-01-01")
    tabla_ausencia.lte.assert_called_once_with("fecha_inicio", "2026-12-31")
    tabla_ausencia.eq.assert_any_call("tipo_de_ausencia", "vacaciones")
    tabla_ausencia.eq.assert_any_call("estado_autorizacion", "pendiente")
    tabla_ausencia.order.assert_called_once_with("fecha_inicio", desc=False)
    tabla_ausencia.range.assert_called_once_with(20, 29)


def test_listar_ausencias_autorizada_resuelve_aprobador_y_motivo():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3]
        + [
            ("ausencia", _tabla_ausencia_lista([_fila_ausencia(estado_autorizacion="autorizada")], total=1)),
            ("persona", _tabla_persona_in([_fila_persona_ausencia()])),
            ("aprobacion_ausencia", _tabla_aprobacion([_fila_aprobacion()])),
            (
                "persona",
                _tabla_persona_in(
                    [{"id": APROBADOR_ID, "primer_nombre": "Gerente", "apellido_paterno": "General"}]
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias()

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    ausencia = response.json()["ausencias"][0]
    assert ausencia["aprobador_id"] == APROBADOR_ID
    assert ausencia["aprobador_nombre"] == "Gerente General"
    assert ausencia["motivo"] == "vacaciones justificadas"
    assert ausencia["decidido_en"] == "2026-01-02T10:00:00Z"


def test_listar_ausencias_pendiente_no_consulta_aprobacion():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3]
        + [
            ("ausencia", _tabla_ausencia_lista([_fila_ausencia()], total=1)),
            ("persona", _tabla_persona_in([_fila_persona_ausencia()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias()

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    tablas_pedidas = {
        llamada.args[0]
        for llamada in fake_client.postgrest.schema.return_value.table.call_args_list
    }
    assert "aprobacion_ausencia" not in tablas_pedidas


def test_listar_ausencias_busqueda_sin_coincidencias_no_consulta_ausencia():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3] + [("persona", _tabla_persona_in([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias(busqueda_persona="nadie-existe")

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "ausencias": []}


def test_listar_ausencias_sin_permiso_devuelve_403():
    fake_client = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_ausencias()

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_ausencias_pendientes():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3]  # GET usa gate OR (un solo permiso alcanza, ausencia_edicion)
        + [
            ("ausencia", _tabla_ausencia_pendientes([_fila_ausencia()])),
            ("persona", _tabla_persona_in([_fila_persona_ausencia()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/ausencias/pendientes", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()[0]
    assert cuerpo["estado_autorizacion"] == "pendiente"
    assert cuerpo["persona_nombre"] == "Ficticia Alfa"


def test_listar_ausencias_pendientes_vacio_no_consulta_persona():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and()[:3] + [("ausencia", _tabla_ausencia_pendientes([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/ausencias/pendientes", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json() == []


def test_resolver_ausencia_autorizada_reclasifica_y_aprueba():
    """fn_ausencia_resolver hace reclasificar+aprobar en una sola transacción -- el router sólo
    reenvía los parámetros al RPC, no arma el update/insert él mismo."""
    fake_client = _fake_client_secuencia(
        _entradas_gate_and() + [("persona", _tabla_persona_in([_fila_persona_ausencia()]))]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_ausencia(tipo_de_ausencia="vacaciones", estado_autorizacion="autorizada")
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "autorizada", "tipo_de_ausencia": "vacaciones", "motivo": "vacaciones justificadas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["tipo_de_ausencia"] == "vacaciones"
    assert cuerpo["estado_autorizacion"] == "autorizada"
    assert cuerpo["persona_nombre"] == "Ficticia Alfa"
    fake_client.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_ausencia_resolver",
        {
            "p_ausencia_id": AUSENCIA_ID,
            "p_decision": "autorizada",
            "p_tipo_de_ausencia": "vacaciones",
            "p_motivo": "vacaciones justificadas",
        },
    )


def test_resolver_ausencia_rechazada_no_reclasifica():
    fake_client = _fake_client_secuencia(
        _entradas_gate_and() + [("persona", _tabla_persona_in([_fila_persona_ausencia()]))]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_ausencia(estado_autorizacion="rechazada")
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "rechazada", "motivo": "sin justificación"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["tipo_de_ausencia"] == "falta"
    assert cuerpo["estado_autorizacion"] == "rechazada"
    parametros_rpc = fake_client.postgrest.schema.return_value.rpc.call_args[0][1]
    assert parametros_rpc["p_tipo_de_ausencia"] is None


def test_resolver_ausencia_ya_resuelta_devuelve_409():
    """El RPC pre-chequea y revienta con ERRCODE 'SCJ03' si ya no está pendiente."""
    fake_client = _fake_client_secuencia(_entradas_gate_and())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ03", "message": "la ausencia ya fue resuelta"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "rechazada"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_resolver_ausencia_no_encontrada_devuelve_404():
    """El RPC revienta con ERRCODE 'SCJ02' si la ausencia no existe (o RLS la esconde)."""
    fake_client = _fake_client_secuencia(_entradas_gate_and())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ02", "message": "la ausencia no existe"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "rechazada"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_resolver_ausencia_carrera_devuelve_409():
    """H1-H2: dos personas resolviendo a la vez -- si la función no alcanza a adelantarse con
    SCJ03, el 23505 real de uq_aprobacion_ausencia_paso también cae a 409."""
    fake_client = _fake_client_secuencia(_entradas_gate_and())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": "duplicate key value violates uq_aprobacion_ausencia_paso"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "rechazada"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_resolver_ausencia_tipo_invalido_segun_bd_devuelve_422():
    """El RPC también valida (ERRCODE 'SCJ04') -- capa real e insaltable, independiente de la
    validación de Pydantic en el schema."""
    fake_client = _fake_client_secuencia(_entradas_gate_and())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ04", "message": "tipo_de_ausencia inválido para autorizar"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "autorizada", "tipo_de_ausencia": "vacaciones"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_resolver_ausencia_autorizada_sin_tipo_devuelve_422_sin_llegar_a_bd():
    fake_client = _fake_client_secuencia(_entradas_gate_and())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/ausencias/5/resolver",
        json={"decision": "autorizada"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
