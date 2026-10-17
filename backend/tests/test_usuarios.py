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


def test_alta_usuario_invitacion_bloqueo_cloudflare_devuelve_422_catch_all():
    """Bug real (2026-09-11), reproducido en vivo desde el Pi de pruebas: la IP pública del Pi
    está bloqueada por reputación en el Cloudflare que protege a Supabase, específico de
    /auth/v1/invite -- un 403 con página HTML de Cloudflare, no un error JSON de GoTrue. Eso
    revienta el parseo de error.response.json() dentro del SDK y llega como AuthUnknownError
    (sin .status confiable), no como AuthApiError -- cae al catch-all genérico, sin prometer una
    causa (ni mencionar "redirect URL", primera hipótesis que se descartó con evidencia real).
    Nada que el código de este repo pueda arreglar -- sólo evita el 500 crudo."""
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = AuthUnknownError(
        "Client error '403 Forbidden' for url "
        "'https://lzueucmdqjacaemdfxad.supabase.co/auth/v1/invite'",
        RuntimeError("cuerpo de la respuesta no es JSON (página HTML de Cloudflare)"),
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
        "No se pudo enviar la invitación -- intenta de nuevo o contacta a Sistemas."
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
    assert response.json()["detail"] == (
        "No se pudo enviar la invitación -- intenta de nuevo o contacta a Sistemas."
    )


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


# --- la causa de una invitación fallida queda en el log SOLO como clases y enteros ---------------------------------------------------------------------

import logging  # noqa: E402

import httpx  # noqa: E402
from supabase_auth.errors import AuthRetryableError  # noqa: E402

CORREO_SECRETO = "persona.secreta@example.com"
TEXTO_SECRETO = "https://proyecto-secreto.supabase.co/auth/v1/invite?redirect_to=http://100.64.0.9:8080/completar-invitacion"


def _invitar_con_error(error, caplog):
    fake_client = _fake_client_sin_usuario_existente()
    fake_client.auth.admin.invite_user_by_email.side_effect = error
    app.dependency_overrides[get_service_client] = lambda: fake_client
    _override_gate()
    try:
        with caplog.at_level(logging.WARNING, logger="app.usuarios"):
            respuesta = TestClient(app).post(
                "/api/usuarios",
                json={"persona_id": PERSONA_ID, "correo": CORREO_SECRETO, "nombre_usuario": "persona.secreta"},
                headers={"Authorization": "Bearer fake-token"},
            )
    finally:
        app.dependency_overrides.clear()
    avisos = [r.getMessage() for r in caplog.records if r.name == "app.usuarios"]
    return respuesta, avisos


def _sin_datos_sensibles(avisos, respuesta):
    texto = " ".join(avisos) + respuesta.text
    for prohibido in (CORREO_SECRETO, "persona.secreta", "proyecto-secreto", "supabase.co", "redirect_to", "completar-invitacion", "100.64.0.9", "Forbidden", "mensaje con texto"):
        assert prohibido not in texto, prohibido


def test_invitacion_422_de_gotrue_registra_clase_estado_y_codigo_sin_correo_ni_texto(caplog):
    respuesta, avisos = _invitar_con_error(AuthApiError(f"Unable to validate email address {CORREO_SECRETO} {TEXTO_SECRETO}", 422, "validation_failed"), caplog)
    assert respuesta.status_code == 422 and "correo no es válido" in respuesta.json()["detail"]
    assert len(avisos) == 1
    assert "error=AuthApiError" in avisos[0] and "status=422" in avisos[0] and "code=validation_failed" in avisos[0]
    _sin_datos_sensibles(avisos, respuesta)


def test_invitacion_429_registra_clase_estado_y_codigo_sin_correo_ni_texto(caplog):
    respuesta, avisos = _invitar_con_error(AuthApiError(f"Email rate limit exceeded for {CORREO_SECRETO}", 429, "over_email_send_rate_limit"), caplog)
    assert respuesta.status_code == 422 and "límite" in respuesta.json()["detail"]
    assert len(avisos) == 1 and "error=AuthApiError" in avisos[0] and "status=429" in avisos[0] and "code=over_email_send_rate_limit" in avisos[0]
    _sin_datos_sensibles(avisos, respuesta)


def _con_cadena_httpx():
    """Un AuthUnknownError levantado dentro de la cadena que arma supabase-auth: ConnectError ← (gaierror) y un HTTPStatusError 403 en el contexto."""
    import socket

    try:
        try:
            try:
                raise socket.gaierror(-2, f"Name or service not known {TEXTO_SECRETO}")
            except OSError as raiz:
                raise httpx.ConnectError(f"mensaje con texto {TEXTO_SECRETO} {CORREO_SECRETO}") from raiz
        except httpx.ConnectError:
            peticion = httpx.Request("POST", TEXTO_SECRETO)
            raise httpx.HTTPStatusError("Client error '403 Forbidden' for url " + TEXTO_SECRETO, request=peticion, response=httpx.Response(403, request=peticion))
    except httpx.HTTPStatusError as e:
        try:
            raise AuthUnknownError(f"mensaje con texto {TEXTO_SECRETO} {CORREO_SECRETO}", ValueError("cuerpo HTML"))
        except AuthUnknownError as final:
            final.__cause__ = None
            return final, e


def test_invitacion_catch_all_registra_la_cadena_de_causas_y_el_http_sin_texto(caplog):
    error, _ = _con_cadena_httpx()
    respuesta, avisos = _invitar_con_error(error, caplog)
    assert respuesta.status_code == 422 and respuesta.json()["detail"] == "No se pudo enviar la invitación -- intenta de nuevo o contacta a Sistemas."
    assert len(avisos) == 1
    aviso = avisos[0]
    assert "error=AuthUnknownError" in aviso and "status=None" in aviso and "code=None" in aviso
    assert "HTTPStatusError" in aviso and "ConnectError" in aviso and "gaierror" in aviso            # la cadena de CLASES (por __context__ y __cause__)
    assert "original=ValueError" in aviso and "http=403" in aviso
    _sin_datos_sensibles(avisos, respuesta)


def test_invitacion_runtimeerror_del_cliente_llega_como_authretryable_status_0(caplog):
    """handle_exception de supabase-auth convierte un RuntimeError (p. ej. cliente cerrado) en AuthRetryableError con status 0: la prueba fija que se ve en el log."""
    try:
        try:
            raise RuntimeError(f"Cannot send a request, as the client has been closed. {CORREO_SECRETO}")
        except RuntimeError:
            raise AuthRetryableError(f"mensaje con texto {CORREO_SECRETO}", 0)
    except AuthRetryableError as error:
        respuesta, avisos = _invitar_con_error(error, caplog)
    assert respuesta.status_code == 422
    assert "error=AuthRetryableError" in avisos[0] and "status=0" in avisos[0] and "contextos=RuntimeError" in avisos[0]
    _sin_datos_sensibles(avisos, respuesta)


def test_el_codigo_de_gotrue_solo_se_registra_si_es_un_identificador_enumerado(caplog):
    respuesta, avisos = _invitar_con_error(AuthApiError("x", 500, f"codigo con espacios y {CORREO_SECRETO}"), caplog)
    assert "code=otro" in avisos[0] and CORREO_SECRETO not in avisos[0] and "codigo con espacios" not in avisos[0]


def test_resumen_de_cadena_acota_a_5_niveles_y_no_se_cicla():
    from app.registro_seguro import resumen_de_cadena

    raiz = ValueError("fin")
    actual = raiz
    for _ in range(10):
        siguiente = RuntimeError("nivel")
        siguiente.__cause__ = actual
        actual = siguiente
    assert len(resumen_de_cadena(actual)["causas"]) == 5
    a, b = RuntimeError("a"), RuntimeError("b")
    a.__context__, b.__context__ = b, a                                       # ciclo
    assert resumen_de_cadena(a)["contextos"] == ["RuntimeError"]


def test_un_codigo_conocido_de_gotrue_se_registra_tal_cual_y_uno_desconocido_como_otro(caplog):
    _, conocido = _invitar_con_error(AuthApiError("x", 400, "email_address_invalid"), caplog)
    assert "code=email_address_invalid" in conocido[0]
    caplog.clear()
    _, desconocido = _invitar_con_error(AuthApiError("x", 400, "un_codigo_que_gotrue_agrego_despues"), caplog)
    assert "code=otro" in desconocido[0] and "un_codigo_que_gotrue" not in desconocido[0]


class _ErrorQueLanzaAlLeerSusAtributos(AuthApiError):
    """Un error «raro»: leer `code` o `status` lanza (un descriptor roto, un objeto a medio construir)."""

    @property
    def code(self):
        raise RuntimeError(f"no se puede leer el código de {CORREO_SECRETO}")

    @code.setter
    def code(self, valor):
        pass

    @property
    def status(self):
        raise RuntimeError(f"no se puede leer el estado de {CORREO_SECRETO}")

    @status.setter
    def status(self, valor):
        pass


def test_si_leer_los_atributos_del_error_lanza_el_422_controlado_se_mantiene(caplog):
    error = _ErrorQueLanzaAlLeerSusAtributos("mensaje con texto", 500, "otro")
    respuesta, avisos = _invitar_con_error(error, caplog)
    assert respuesta.status_code == 422 and respuesta.json()["detail"] == "No se pudo enviar la invitación -- intenta de nuevo o contacta a Sistemas."
    _sin_datos_sensibles(avisos, respuesta)


def test_si_el_formateo_del_resumen_lanza_el_422_controlado_se_mantiene(monkeypatch, caplog):
    import app.routers.usuarios as modulo

    def roto(*args, **kwargs):
        raise ValueError(f"fallo de formateo con {CORREO_SECRETO}")

    monkeypatch.setattr(modulo, "resumen_de_cadena", roto)
    respuesta, avisos = _invitar_con_error(AuthApiError("x", 422, "validation_failed"), caplog)
    assert respuesta.status_code == 422 and "correo no es válido" in respuesta.json()["detail"]      # la rama de estado sigue funcionando
    assert not any(CORREO_SECRETO in a for a in avisos)
