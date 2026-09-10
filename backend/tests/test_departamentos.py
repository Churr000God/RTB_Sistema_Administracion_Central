from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app
from app.routers.departamentos import (
    MENSAJE_REACTIVACION_INVALIDA,
    MENSAJE_TIENE_PUESTOS_ACTIVOS,
)

AREA_ID = "33333333-3333-3333-3333-333333333333"
DEPARTAMENTO_ID = "55555555-5555-5555-5555-555555555555"

# Ver test_areas.py: el gate real (requiere_permiso) toca usuario/asignacion/puesto_permiso,
# que departamentos.py nunca usa por su cuenta -- se hace pasar siempre, sin importar el
# código pedido, para no interferir con lo que cada test prueba del propio router.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _tabla_gate(nombre_tabla):
    tabla = MagicMock()
    if nombre_tabla == "usuario":
        tabla.select.return_value.eq.return_value.execute.return_value.data = [
            {"persona_id": GATE_PERSONA_ID}
        ]
    elif nombre_tabla == "asignacion":
        tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
            {"puesto_id": GATE_PUESTO_ID}
        ]
    elif nombre_tabla == "puesto_permiso":
        tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
            {"puesto_id": GATE_PUESTO_ID}
        ]
    return tabla


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _fila_departamento(**overrides):
    fila = {
        "id": DEPARTAMENTO_ID,
        "area_id": AREA_ID,
        "nombre_departamento": "Ventas",
        "activo": True,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _fake_client_area_valida():
    """MagicMock donde el SELECT de validación de area_id (alta_departamento) devuelve un
    área existente y activa, y el gate de permisos ya pasa. Otras tablas se configuran
    aparte por side_effect si hace falta."""
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table

    def side_effect(nombre_tabla):
        if nombre_tabla == "area":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"id": AREA_ID, "activo": True}
            ]
            return tabla
        return _tabla_gate(nombre_tabla)

    tabla_mock.side_effect = side_effect
    return fake_client, tabla_mock


def test_listar_departamentos():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.order.return_value.execute.return_value.data = [
        _fila_departamento(),
        _fila_departamento(id="66666666-6666-6666-6666-666666666666", nombre_departamento="Cobranza"),
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/departamentos", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert len(cuerpo) == 2
    assert cuerpo[0]["nombre_departamento"] == "Ventas"


def test_alta_departamento_inserta_departamento():
    fake_client, tabla_mock = _fake_client_area_valida()
    tabla_departamento = MagicMock()
    tabla_departamento.insert.return_value.execute.return_value.data = [_fila_departamento()]

    def side_effect(nombre_tabla):
        if nombre_tabla == "area":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"id": AREA_ID, "activo": True}
            ]
            return tabla
        if nombre_tabla == "departamento":
            return tabla_departamento
        return _tabla_gate(nombre_tabla)

    tabla_mock.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/departamentos",
        json={"area_id": AREA_ID, "nombre_departamento": "Ventas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["nombre_departamento"] == "Ventas"
    assert tabla_departamento.insert.call_args_list[0].args[0] == {
        "area_id": AREA_ID,
        "nombre_departamento": "Ventas",
    }


def test_alta_departamento_area_inexistente_devuelve_422():
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "area":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = []
            return tabla
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/departamentos",
        json={"area_id": AREA_ID, "nombre_departamento": "Ventas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_departamento_area_inactiva_devuelve_422():
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "area":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"id": AREA_ID, "activo": False}
            ]
            return tabla
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/departamentos",
        json={"area_id": AREA_ID, "nombre_departamento": "Ventas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_departamento_duplicado_devuelve_409():
    fake_client, tabla_mock = _fake_client_area_valida()
    tabla_departamento = MagicMock()
    tabla_departamento.insert.return_value.execute.side_effect = APIError(
        {
            "code": "23505",
            "message": 'duplicate key value violates unique constraint "uq_departamento_nombre"',
        }
    )

    def side_effect(nombre_tabla):
        if nombre_tabla == "area":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"id": AREA_ID, "activo": True}
            ]
            return tabla
        if nombre_tabla == "departamento":
            return tabla_departamento
        return _tabla_gate(nombre_tabla)

    tabla_mock.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/departamentos",
        json={"area_id": AREA_ID, "nombre_departamento": "Ventas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_obtener_departamento():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = [
        _fila_departamento()
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        f"/api/departamentos/{DEPARTAMENTO_ID}", headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["id"] == DEPARTAMENTO_ID


def test_obtener_departamento_no_encontrado():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        f"/api/departamentos/{DEPARTAMENTO_ID}", headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_renombrar_departamento():
    tabla_departamento = MagicMock()
    tabla_departamento.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_departamento(nombre_departamento="Ventas Nacionales")
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}",
        json={"nombre_departamento": "Ventas Nacionales"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["nombre_departamento"] == "Ventas Nacionales"
    tabla_departamento.update.return_value.eq.assert_called_with("id", DEPARTAMENTO_ID)


def test_renombrar_departamento_duplicado_devuelve_409():
    tabla_departamento = MagicMock()
    tabla_departamento.update.return_value.eq.return_value.execute.side_effect = APIError(
        {
            "code": "23505",
            "message": 'duplicate key value violates unique constraint "uq_departamento_nombre"',
        }
    )
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}",
        json={"nombre_departamento": "Cobranza"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_renombrar_departamento_no_encontrado():
    tabla_departamento = MagicMock()
    tabla_departamento.update.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}",
        json={"nombre_departamento": "Ventas Nacionales"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_desactivar_departamento():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = [
        {"area_id": AREA_ID}
    ]
    tabla_departamento.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_departamento(activo=False)
    ]
    tabla_puesto = MagicMock()
    tabla_puesto.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "departamento":
            return tabla_departamento
        if nombre_tabla == "puesto":
            return tabla_puesto
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is False


def test_desactivar_departamento_con_puestos_activos_devuelve_422():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = [
        {"area_id": AREA_ID}
    ]
    tabla_puesto = MagicMock()
    tabla_puesto.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
        {"id": "puesto-activo-1"}
    ]
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "departamento":
            return tabla_departamento
        if nombre_tabla == "puesto":
            return tabla_puesto
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_TIENE_PUESTOS_ACTIVOS


def test_reactivar_departamento():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = [
        {"area_id": AREA_ID}
    ]
    tabla_departamento.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_departamento(activo=True)
    ]
    tabla_area = MagicMock()
    tabla_area.select.return_value.eq.return_value.execute.return_value.data = [{"activo": True}]
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "departamento":
            return tabla_departamento
        if nombre_tabla == "area":
            return tabla_area
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is True


def test_reactivar_departamento_area_inactiva_devuelve_422():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = [
        {"area_id": AREA_ID}
    ]
    tabla_area = MagicMock()
    tabla_area.select.return_value.eq.return_value.execute.return_value.data = [{"activo": False}]
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "departamento":
            return tabla_departamento
        if nombre_tabla == "area":
            return tabla_area
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_REACTIVACION_INVALIDA


def test_cambiar_estado_departamento_no_encontrado():
    tabla_departamento = MagicMock()
    tabla_departamento.select.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_departamento if nombre == "departamento" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/departamentos/{DEPARTAMENTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_alta_departamento_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin departamento_edicion -- el gate debe rechazar
    antes de validar siquiera el area_id."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"persona_id": GATE_PERSONA_ID}
            ]
        elif nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": GATE_PUESTO_ID}
            ]
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
        elif nombre_tabla == "permiso":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": False}
            ]
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/departamentos",
        json={"area_id": AREA_ID, "nombre_departamento": "Ventas"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_departamentos_sin_token():
    client = TestClient(app)
    response = client.get("/api/departamentos")

    assert response.status_code in (401, 422)


def test_alta_departamento_sin_token():
    client = TestClient(app)
    response = client.post(
        "/api/departamentos", json={"area_id": AREA_ID, "nombre_departamento": "Ventas"}
    )

    assert response.status_code in (401, 422)
