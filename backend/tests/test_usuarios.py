from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError
from supabase_auth.errors import AuthApiError, AuthUnknownError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

PERSONA_ID = "11111111-1111-1111-1111-111111111111"
AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"

# alta_usuario ahora exige requiere_permiso("alta_personas_usuarios") -- usa get_caller_client
# (independiente del get_service_client de la lógica de negocio propia) para el gate. Ver
# test_areas.py para el razonamiento completo.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id=AUTH_USER_ID, correo="gate-ficticio@example.com")


def _fake_caller_client_gate():
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
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
                {"puesto_id": GATE_PUESTO_ID}
            ]
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _override_gate():
    app.dependency_overrides[get_caller_client] = lambda: _fake_caller_client_gate()
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _fake_client_sin_usuario_existente():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.execute.return_value.data = (
        []
    )
    return fake_client


def test_alta_usuario_invita_y_crea_fila_usuario():
    fake_client = _fake_client_sin_usuario_existente()
    fake_invite = MagicMock()
    fake_invite.user.id = AUTH_USER_ID
    fake_client.auth.admin.invite_user_by_email.return_value = fake_invite
    fake_client.postgrest.schema.return_value.table.return_value.insert.return_value.execute.return_value.data = [
        {
            "auth_user_id": AUTH_USER_ID,
            "persona_id": PERSONA_ID,
            "nombre_usuario": "mariana.alcantara",
            "estado": "activo",
        }
    ]
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    fake_client.auth.admin.invite_user_by_email.assert_called_once_with(
        "mariana.alcantara@example.com",
        {"redirect_to": "http://localhost:5173/completar-invitacion"},
    )
    assert response.json()["auth_user_id"] == "22222222-2222-2222-2222-222222222222"


def test_alta_usuario_rechaza_sin_token():
    fake_client = MagicMock()
    app.dependency_overrides[get_service_client] = lambda: fake_client

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": "11111111-1111-1111-1111-111111111111",
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
    )

    app.dependency_overrides.clear()
    assert response.status_code in (401, 422)
    fake_client.auth.admin.invite_user_by_email.assert_not_called()


def test_alta_usuario_rechaza_persona_con_usuario_existente():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [
        {"auth_user_id": AUTH_USER_ID}
    ]
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409
    fake_client.auth.admin.invite_user_by_email.assert_not_called()


def test_alta_usuario_carrera_en_insert_revierte_invitacion_y_devuelve_409():
    fake_client = _fake_client_sin_usuario_existente()
    fake_invite = MagicMock()
    fake_invite.user.id = AUTH_USER_ID
    fake_client.auth.admin.invite_user_by_email.return_value = fake_invite
    fake_client.postgrest.schema.return_value.table.return_value.insert.return_value.execute.side_effect = APIError(
        {
            "code": "23505",
            "message": 'duplicate key value violates unique constraint "uq_usuario_persona"',
        }
    )
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409
    fake_client.auth.admin.delete_user.assert_called_once_with(AUTH_USER_ID)


def test_alta_usuario_invitacion_redirect_no_permitido_devuelve_422():
    """Bug real (2026-09-11): redirect_to fuera de la allowlist de Redirect URLs de Supabase Auth
    da 403 -- antes subía como 500 crudo sin capturar, reproducido en vivo desde el Pi de
    pruebas."""
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = AuthApiError(
        "Redirect not allowed", 403, "redirect_url_not_allowed"
    )
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422, response.text
    assert response.json()["detail"] == (
        "No se pudo enviar la invitación: la URL de redirect no está permitida en la "
        "configuración de Supabase Auth (Authentication > URL Configuration > Redirect URLs)."
    )
    fake_client.postgrest.schema.return_value.table.return_value.insert.assert_not_called()


def test_alta_usuario_invitacion_correo_invalido_devuelve_422():
    """422 de AuthApiError (Supabase Auth ya rechazó el correo -- ej. dominio inexistente,
    formato que Pydantic sí acepta pero GoTrue no) -- distinto del 422 que ya tira Pydantic para
    un correo sintácticamente inválido, que ni siquiera llega a este código."""
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = AuthApiError(
        "Unable to validate email address", 422, "validation_failed"
    )
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@dominio-inexistente.example",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422, response.text
    assert response.json()["detail"] == "El correo no es válido o ya tiene una cuenta de acceso."


def test_alta_usuario_invitacion_limite_excedido_devuelve_422():
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = AuthApiError(
        "Email rate limit exceeded", 429, "over_email_send_rate_limit"
    )
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422, response.text
    assert "límite" in response.json()["detail"]


def test_alta_usuario_invitacion_error_desconocido_devuelve_422_catch_all():
    """AuthUnknownError -- el cuerpo de la respuesta no era JSON (ej. un 403 crudo de un proxy
    delante de GoTrue). No expone `.status`, cae al mensaje catch-all."""
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = AuthUnknownError(
        "algo raro pasó", RuntimeError("cuerpo no era JSON")
    )
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422, response.text
    assert response.json()["detail"] == "No se pudo enviar la invitación de acceso."


def test_alta_usuario_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin alta_personas_usuarios -- el gate debe rechazar
    antes de invitar a nadie."""
    fake_client_service = MagicMock()

    fake_caller = MagicMock()

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

    fake_caller.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_service_client] = lambda: fake_client_service
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY

    client = TestClient(app)
    response = client.post(
        "/api/usuarios",
        json={
            "persona_id": PERSONA_ID,
            "correo": "mariana.alcantara@example.com",
            "nombre_usuario": "mariana.alcantara",
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403
    fake_client_service.auth.admin.invite_user_by_email.assert_not_called()
