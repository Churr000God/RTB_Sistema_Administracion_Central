from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"
PERSONA_ID = "11111111-1111-1111-1111-111111111111"

# El POST de movimientos ahora exige requiere_permiso("cambio_estado_persona") -- el gate toca
# usuario/asignacion/puesto_permiso ANTES del insert propio del router. Ver test_areas.py para
# el razonamiento completo.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"


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


def test_crear_movimiento_de_suspension_guarda_registrado_por():
    tabla_bitacora = MagicMock()
    tabla_bitacora.insert.return_value.execute.return_value.data = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "suspension",
            "fecha_efectiva": "2026-09-03T10:00:00+00:00",
            "motivo": "Licencia sin goce de sueldo",
            "documento_ref": None,
            "registrado_por": AUTH_USER_ID,
        }
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_bitacora if nombre == "bitacora_movimiento_persona" else _tabla_gate(nombre)
    )
    insert_mock = tabla_bitacora.insert
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo="mariana.alcantara@example.com"
    )

    client = TestClient(app)
    response = client.post(
        f"/api/personas/{PERSONA_ID}/movimientos",
        json={"tipo_movimiento": "suspension", "motivo": "Licencia sin goce de sueldo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["tipo_movimiento"] == "suspension"
    assert insert_mock.call_args[0][0]["registrado_por"] == AUTH_USER_ID


def test_crear_movimiento_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin cambio_estado_persona -- el gate debe rechazar
    antes de insertar el movimiento."""
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
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo="mariana.alcantara@example.com"
    )

    client = TestClient(app)
    response = client.post(
        f"/api/personas/{PERSONA_ID}/movimientos",
        json={"tipo_movimiento": "suspension", "motivo": "Licencia sin goce de sueldo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def _fake_db_get(movimientos, filas_usuario=None):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "bitacora_movimiento_persona":
            tabla.select.return_value.eq.return_value.order.return_value.execute.return_value.data = (
                movimientos
            )
        elif nombre_tabla == "usuario":
            tabla.select.return_value.in_.return_value.execute.return_value.data = (
                filas_usuario or []
            )
        return tabla

    tabla_mock.side_effect = side_effect
    return fake_client, tabla_mock


def test_listar_movimientos_resuelve_autor_con_mezcla_de_registros():
    movimientos = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "alta",
            "fecha_efectiva": "2026-01-01T09:00:00+00:00",
            "motivo": None,
            "documento_ref": None,
            "registrado_por": AUTH_USER_ID,
        },
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "suspension",
            "fecha_efectiva": "2026-02-01T09:00:00+00:00",
            "motivo": "Motivo X",
            "documento_ref": None,
            "registrado_por": None,
        },
    ]
    fake_client, _ = _fake_db_get(
        movimientos,
        filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "mariana.alcantara"}],
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert cuerpo[0]["registrado_por_nombre"] == "mariana.alcantara"
    assert cuerpo[1]["registrado_por_nombre"] is None


def test_listar_movimientos_sin_autores_no_dispara_segunda_consulta():
    movimientos = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "alta",
            "fecha_efectiva": "2026-01-01T09:00:00+00:00",
            "motivo": None,
            "documento_ref": None,
            "registrado_por": None,
        },
    ]
    fake_client, tabla_mock = _fake_db_get(movimientos)
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()[0]["registrado_por_nombre"] is None
    assert tabla_mock.call_count == 1
    assert tabla_mock.call_args[0][0] == "bitacora_movimiento_persona"
