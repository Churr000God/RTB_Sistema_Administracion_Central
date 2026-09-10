from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app
from app.routers.areas import MENSAJE_TIENE_DEPARTAMENTOS_ACTIVOS

AREA_ID = "33333333-3333-3333-3333-333333333333"

# El gate de permisos real (requiere_permiso, conectado en el corte "cerrar el gate") exige
# además de get_caller_client un get_caller_identity, y resuelve persona_id (tabla "usuario"),
# puestos vigentes (tabla "asignacion") y el permiso directo (tabla "puesto_permiso") ANTES de
# llegar al cuerpo del endpoint. area.py nunca toca esas 3 tablas por su cuenta, así que hacerlas
# pasar siempre (sin importar qué código de permiso se pida) no interfiere con lo que cada test
# ya prueba del propio router -- separado en test_gate_permisos.py el comportamiento real del
# gate (403 sin permiso, herencia, edición-implica-lectura).
GATE_AUTH_USER_ID = "auth-ficticio-gate"
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id=GATE_AUTH_USER_ID, correo="gate-ficticio@example.com")


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
    elif nombre_tabla == "departamento":
        # cambiar_estado_area (SCJ-PRO-06 DA1) consulta departamentos activos de la misma área
        # antes de desactivar -- sin bloqueo por omisión, cada test que quiera probar el 422
        # sobreescribe esta tabla con su propio side_effect.
        tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
    return tabla


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _fila_area(**overrides):
    fila = {
        "id": AREA_ID,
        "nombre_area": "Comercial",
        "activo": True,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def test_listar_areas():
    tabla_area = MagicMock()
    tabla_area.select.return_value.order.return_value.execute.return_value.data = [
        _fila_area(),
        _fila_area(id="44444444-4444-4444-4444-444444444444", nombre_area="Operaciones"),
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/areas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert len(cuerpo) == 2
    assert cuerpo[0]["nombre_area"] == "Comercial"


def test_alta_area_inserta_area():
    tabla_area = MagicMock()
    tabla_area.insert.return_value.execute.return_value.data = [_fila_area()]
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    tabla_mock.side_effect = lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/areas",
        json={"nombre_area": "Comercial"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["nombre_area"] == "Comercial"
    assert tabla_area.insert.call_args_list[0].args[0] == {"nombre_area": "Comercial"}


def test_alta_area_normaliza_espacios_en_nombre():
    tabla_area = MagicMock()
    tabla_area.insert.return_value.execute.return_value.data = [_fila_area(nombre_area="Comercial Norte")]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/areas",
        json={"nombre_area": "  Comercial   Norte  "},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert tabla_area.insert.call_args_list[0].args[0] == {"nombre_area": "Comercial Norte"}


def test_alta_area_duplicada_devuelve_409():
    tabla_area = MagicMock()
    tabla_area.insert.return_value.execute.side_effect = APIError(
        {
            "code": "23505",
            "message": 'duplicate key value violates unique constraint "uq_area_nombre"',
        }
    )
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/areas",
        json={"nombre_area": "Comercial"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_renombrar_area():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_area(nombre_area="Comercial y Marketing")
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}",
        json={"nombre_area": "Comercial y Marketing"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["nombre_area"] == "Comercial y Marketing"
    tabla_area.update.return_value.eq.assert_called_with("id", AREA_ID)


def test_renombrar_area_duplicada_devuelve_409():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.side_effect = APIError(
        {
            "code": "23505",
            "message": 'duplicate key value violates unique constraint "uq_area_nombre"',
        }
    )
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}",
        json={"nombre_area": "Operaciones"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_desactivar_area():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_area(activo=False)
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is False
    datos_actualizados = tabla_area.update.call_args_list[0].args[0]
    assert datos_actualizados["activo"] is False


def test_desactivar_area_con_departamentos_activos_devuelve_422():
    tabla_area = MagicMock()
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "departamento":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
                {"id": "departamento-activo-1"}
            ]
            return tabla
        return tabla_area if nombre_tabla == "area" else _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_TIENE_DEPARTAMENTOS_ACTIVOS


def test_reactivar_area():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.return_value.data = [
        _fila_area(activo=True)
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is True


def test_obtener_area():
    tabla_area = MagicMock()
    tabla_area.select.return_value.eq.return_value.execute.return_value.data = [_fila_area()]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/areas/{AREA_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["id"] == AREA_ID


def test_obtener_area_no_encontrada():
    tabla_area = MagicMock()
    tabla_area.select.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/areas/{AREA_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_renombrar_area_no_encontrada():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}",
        json={"nombre_area": "Comercial y Marketing"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_cambiar_estado_area_no_encontrada():
    tabla_area = MagicMock()
    tabla_area.update.return_value.eq.return_value.execute.return_value.data = []
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_area if nombre == "area" else _tabla_gate(nombre)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/areas/{AREA_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_listar_areas_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin area_lectura ni area_edicion en ningún puesto
    vigente -- el gate real debe rechazar antes de llegar al router."""
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
    response = client.get("/api/areas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_areas_sin_token():
    client = TestClient(app)
    response = client.get("/api/areas")

    assert response.status_code in (401, 422)


def test_alta_area_sin_token():
    client = TestClient(app)
    response = client.post("/api/areas", json={"nombre_area": "Comercial"})

    assert response.status_code in (401, 422)
