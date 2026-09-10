from datetime import date, timedelta
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")

HOY = date.today()
MANIANA_ISO = (HOY + timedelta(days=1)).isoformat()
AYER_ISO = (HOY - timedelta(days=1)).isoformat()
HOY_ISO = HOY.isoformat()


# ---------------------------------------------------------------------------
# Helpers de gate (mismo estilo que test_tope_legal.py)
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
# GET /api/dias-festivos
# ---------------------------------------------------------------------------


def _tabla_dia_festivo_listado(datos):
    tabla = MagicMock()
    tabla.select.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def test_listar_dias_festivos_devuelve_orden_desc():
    tabla = _tabla_dia_festivo_listado(
        [
            {"id": 2, "fecha": "2026-12-25", "nombre": "Navidad"},
            {"id": 1, "fecha": "2026-01-01", "nombre": "Año Nuevo"},
        ]
    )
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.get("/api/dias-festivos", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert [f["id"] for f in cuerpo] == [2, 1]
    tabla.eq.assert_not_called()
    tabla.gte.assert_not_called()
    tabla.lte.assert_not_called()


def test_listar_dias_festivos_sin_ninguno_de_los_2_permisos_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/dias-festivos", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# POST /api/dias-festivos
# ---------------------------------------------------------------------------


def _tabla_dia_festivo_insert(fila):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [fila]
    return tabla


def test_alta_dia_festivo_caso_feliz_201():
    tabla = _tabla_dia_festivo_insert({"id": 3, "fecha": MANIANA_ISO, "nombre": "Festivo de prueba"})
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.post(
        "/api/dias-festivos",
        json={"fecha": MANIANA_ISO, "nombre": "Festivo de prueba"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 201, response.text
    assert response.json()["nombre"] == "Festivo de prueba"


def test_alta_dia_festivo_fecha_pasada_permitida_201():
    """Carga de catálogo retroactivo/histórico -- decisión explícita, no un descuido."""
    tabla = _tabla_dia_festivo_insert({"id": 4, "fecha": AYER_ISO, "nombre": "Festivo viejo"})
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.post(
        "/api/dias-festivos",
        json={"fecha": AYER_ISO, "nombre": "Festivo viejo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 201, response.text


def test_alta_dia_festivo_fecha_duplicada_devuelve_409():
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": "duplicate key value violates uq_dia_festivo_fecha"}
    )
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.post(
        "/api/dias-festivos",
        json={"fecha": MANIANA_ISO, "nombre": "Duplicado"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 409
    assert response.json()["detail"] == "Ya existe un día festivo con esa fecha."


def test_alta_dia_festivo_sin_dia_festivo_edicion_devuelve_403():
    """dia_festivo_lectura sola no alcanza -- el POST exige específicamente dia_festivo_edicion."""
    fake_caller = _fake_caller_client_con_permisos({"dia_festivo_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/dias-festivos",
        json={"fecha": MANIANA_ISO, "nombre": "Festivo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 403


def test_alta_dia_festivo_nombre_solo_espacios_devuelve_422():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/dias-festivos",
        json={"fecha": MANIANA_ISO, "nombre": "    "},
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# DELETE /api/dias-festivos/{festivo_id}
# ---------------------------------------------------------------------------


def _tabla_dia_festivo_borrado(fila_existente):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = (
        [fila_existente] if fila_existente else []
    )
    return tabla


def test_borrar_dia_festivo_fecha_futura_204():
    tabla = _tabla_dia_festivo_borrado({"id": 5, "fecha": MANIANA_ISO})
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.delete(
        "/api/dias-festivos/5", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 204
    tabla.delete.return_value.eq.assert_called_once_with("id", 5)


def test_borrar_dia_festivo_fecha_pasada_devuelve_422_y_no_borra():
    tabla = _tabla_dia_festivo_borrado({"id": 6, "fecha": AYER_ISO})
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.delete(
        "/api/dias-festivos/6", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 422
    assert response.json()["detail"] == "No se puede borrar un día festivo de hoy o del pasado."
    tabla.delete.assert_not_called()


def test_borrar_dia_festivo_fecha_de_hoy_devuelve_422_y_no_borra():
    """Caso borde crítico: <=, no < -- el festivo de HOY tampoco se borra."""
    tabla = _tabla_dia_festivo_borrado({"id": 7, "fecha": HOY_ISO})
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.delete(
        "/api/dias-festivos/7", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 422
    tabla.delete.assert_not_called()


def test_borrar_dia_festivo_inexistente_devuelve_404_y_no_borra():
    tabla = _tabla_dia_festivo_borrado(None)
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla
    _autorizar(fake_service)

    client = TestClient(app)
    response = client.delete(
        "/api/dias-festivos/999", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 404
    tabla.delete.assert_not_called()


def test_borrar_dia_festivo_sin_dia_festivo_edicion_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos({"dia_festivo_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.delete(
        "/api/dias-festivos/1", headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 403
