from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


# ---------------------------------------------------------------------------
# Helpers de gate (mismo estilo que test_dias_festivos.py / test_tope_legal.py)
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


def _autorizar(fake_service):
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()
    return fake_caller


# ---------------------------------------------------------------------------
# GET /api/parametros
# ---------------------------------------------------------------------------


def _tabla_parametro_vigentes(datos):
    tabla = MagicMock()
    tabla.select.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def test_listar_parametros_vigentes_mezcla_catalogo():
    tabla = _tabla_parametro_vigentes(
        [{"clave": "tolerancia_retardo_min", "valor": "15", "vigente_desde": "2026-01-01"}]
    )
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.get("/api/parametros", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert len(cuerpo) == 1
    fila = cuerpo[0]
    assert fila["clave"] == "tolerancia_retardo_min"
    assert fila["valor"] == "15"
    assert fila["etiqueta"] == "Tolerancia de retardo"
    assert fila["tipo"] == "entero"
    assert fila["unidad"] == "min"
    assert fila["impacta_logica"] is True
    assert fila["nota"] is None
    tabla.select.return_value.is_.assert_called_once_with("vigente_hasta", "null")


def test_listar_parametros_vigentes_con_solo_lectura_devuelve_200():
    tabla = _tabla_parametro_vigentes([])
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    fake_caller = _fake_caller_client_con_permisos({"parametro_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/parametros", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 200, response.text


def test_listar_parametros_vigentes_nunca_usa_caller_client_para_leer_datos():
    tabla = _tabla_parametro_vigentes([])
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    fake_caller = _autorizar(fake_service)

    client = TestClient(app)
    response = client.get("/api/parametros", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 200, response.text
    tablas_pedidas_al_caller = {
        llamada.args[0]
        for llamada in fake_caller.postgrest.schema.return_value.table.call_args_list
    }
    assert tablas_pedidas_al_caller == {"usuario", "asignacion", "puesto_permiso"}
    assert "parametro" not in tablas_pedidas_al_caller


# ---------------------------------------------------------------------------
# GET /api/parametros/historial
# ---------------------------------------------------------------------------


def _fake_service_historial(historial_rows, usuarios_rows=None):
    tabla_parametro = MagicMock()
    tabla_parametro.select.return_value.order.return_value.execute.return_value.data = historial_rows
    tabla_usuario = MagicMock()
    tabla_usuario.select.return_value.in_.return_value.execute.return_value.data = usuarios_rows or []

    def schema_side_effect(nombre):
        namespace = MagicMock()
        if nombre == "tiempo":
            namespace.table.return_value = tabla_parametro
        elif nombre == "personas":
            namespace.table.return_value = tabla_usuario
        return namespace

    fake_service = MagicMock()
    fake_service.postgrest.schema.side_effect = schema_side_effect
    return fake_service, tabla_parametro, tabla_usuario


def test_listar_historial_orden_desc_y_resuelve_autor():
    historial_rows = [
        {
            "id": 2,
            "clave": "tolerancia_retardo_min",
            "valor": "15",
            "vigente_desde": "2026-02-01",
            "vigente_hasta": None,
            "registrado_por": "auth-usuario-1",
        },
        {
            "id": 1,
            "clave": "tolerancia_retardo_min",
            "valor": "10",
            "vigente_desde": "2026-01-01",
            "vigente_hasta": "2026-02-01",
            "registrado_por": None,
        },
    ]
    fake_service, tabla_parametro, _ = _fake_service_historial(
        historial_rows, usuarios_rows=[{"auth_user_id": "auth-usuario-1", "nombre_usuario": "Ana Ríos"}]
    )
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.get(
        "/api/parametros/historial", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert [f["id"] for f in cuerpo] == [2, 1]
    assert cuerpo[0]["nombre_registrado_por"] == "Ana Ríos"
    assert cuerpo[1]["registrado_por"] is None
    assert cuerpo[1]["nombre_registrado_por"] is None
    tabla_parametro.select.return_value.order.assert_called_once_with("vigente_desde", desc=True)


def test_listar_historial_con_solo_lectura_devuelve_200():
    fake_service, _, _ = _fake_service_historial([])
    fake_caller = _fake_caller_client_con_permisos({"parametro_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        "/api/parametros/historial", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 200, response.text


# ---------------------------------------------------------------------------
# PUT /api/parametros/{clave}
# ---------------------------------------------------------------------------


def _fake_service_put(fila_resultado):
    tabla_rpc = MagicMock()
    tabla_rpc.execute.return_value.data = fila_resultado
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value = tabla_rpc
    return fake_service


def test_actualizar_valor_parametro_caso_feliz():
    fake_service = _fake_service_put(
        {"clave": "tolerancia_retardo_min", "valor": "20", "vigente_desde": "2026-09-07"}
    )
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "20"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["valor"] == "20"
    fake_service.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_parametro_actualizar_valor",
        {
            "p_clave": "tolerancia_retardo_min",
            "p_valor": "20",
            "p_registrado_por": GATE_IDENTITY.auth_user_id,
        },
    )


def test_actualizar_valor_parametro_sin_vigencia_activa_devuelve_404():
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ02", "message": "No existe vigencia activa"}
    )
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "20"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 404
    assert response.json()["detail"] == "No existe un parámetro activo con esa clave."


def test_actualizar_valor_parametro_otro_apierror_devuelve_422():
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "OTRO", "message": "algo salió mal"}
    )
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "20"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422


def test_actualizar_valor_parametro_con_solo_lectura_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos({"parametro_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "20"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 403


def test_actualizar_valor_parametro_sin_ningun_permiso_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "20"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 403


def test_actualizar_valor_parametro_entero_no_numerico_devuelve_422():
    fake_service = MagicMock()
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/tolerancia_retardo_min",
        json={"valor": "abc"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422
    fake_service.postgrest.schema.return_value.rpc.assert_not_called()


def test_actualizar_valor_parametro_hora_fuera_de_rango_devuelve_422():
    fake_service = MagicMock()
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/hora_corte_dia",
        json={"valor": "25:00"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422
    fake_service.postgrest.schema.return_value.rpc.assert_not_called()


def test_actualizar_valor_parametro_hora_sin_cero_relleno_devuelve_422():
    fake_service = MagicMock()
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.put(
        "/api/parametros/hora_corte_dia",
        json={"valor": "3:00"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422
    fake_service.postgrest.schema.return_value.rpc.assert_not_called()
