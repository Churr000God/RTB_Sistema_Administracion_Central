"""get_caller_identity y el 401/503 de los tokens que no validan: un Bearer mal formado, vencido o con firma inválida NUNCA es un 500, y GoTrue caído no es «token malo»."""

from unittest.mock import MagicMock, patch

import httpx
import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError
from supabase_auth.errors import AuthApiError, AuthInvalidJwtError, AuthRetryableError, AuthSessionMissingError, AuthUnknownError

from app.deps import get_caller_client, get_service_client
from app.main import app

TEXTO_DEL_SDK = "invalid JWT: unable to parse or verify signature, token is malformed: invalid number of segments"


TOKEN_BIEN_FORMADO = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.firma_ficticia-1"


def _get_sesion(error_o_respuesta, token=TOKEN_BIEN_FORMADO):
    cliente_auth = MagicMock()
    if isinstance(error_o_respuesta, Exception):
        cliente_auth.auth.get_user.side_effect = error_o_respuesta
    else:
        cliente_auth.auth.get_user.return_value = error_o_respuesta
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    try:
        with patch("app.deps.create_client", return_value=cliente_auth):
            return TestClient(app).get("/api/sesion", headers={"Authorization": f"Bearer {token}"})
    finally:
        app.dependency_overrides.clear()


@pytest.mark.parametrize("error", [
    AuthApiError(TEXTO_DEL_SDK, 401, "bad_jwt"),                  # mal formado
    AuthApiError("token is expired", 401, "bad_jwt"),             # vencido
    AuthApiError("signature is invalid", 403, "bad_jwt"),         # firma inválida
    AuthApiError("User from sub claim in JWT does not exist", 403, "user_not_found"),
    AuthInvalidJwtError("jwt"),
    AuthSessionMissingError(),
])
def test_un_token_que_no_valida_es_401_con_mensaje_fijo_sin_el_texto_del_sdk(error):
    r = _get_sesion(error)
    assert r.status_code == 401 and r.json() == {"detail": "Token inválido o expirado."}
    assert "segments" not in r.text and "signature" not in r.text and r.headers.get("www-authenticate") == "Bearer"


@pytest.mark.parametrize("error", [
    AuthApiError("upstream error", 502, None),
    AuthRetryableError("sin red", 0),
    AuthUnknownError("<html>bloqueo</html>", ValueError("x")),
    httpx.ConnectError("sin red"),
])
def test_un_fallo_de_gotrue_es_503_con_retry_after_no_401_ni_500(error):
    r = _get_sesion(error)
    assert r.status_code == 503 and r.headers["retry-after"] == "2" and "bloqueo" not in r.text and "sin red" not in r.text


def test_sin_usuario_en_la_respuesta_sigue_siendo_401():
    respuesta = MagicMock()
    respuesta.user = None
    assert _get_sesion(respuesta).status_code == 401


def _peticion(**estado):
    from starlette.requests import Request

    request = Request({"type": "http", "method": "GET", "path": "/api/areas", "headers": [(b"origin", b"http://localhost:5173")], "query_string": b""})
    for clave, valor in estado.items():
        setattr(request.state, clave, valor)
    return request


@pytest.mark.parametrize("codigo", ["PGRST301", "PGRST302", "PGRST303"])
def test_un_jwt_que_postgrest_rechaza_con_el_cliente_del_caller_es_401_con_log_warning(codigo, caplog):
    """get_caller_client no valida el token: lo rechaza PostgREST al primer uso y eso no puede salir como 500. El manejador del APIError es común a todos los routers."""
    import asyncio
    import json
    import logging

    from app.main import manejador_error_postgrest

    with caplog.at_level(logging.WARNING, logger="app.main"):
        r = asyncio.run(manejador_error_postgrest(_peticion(usa_cliente_caller=True), APIError({"code": codigo, "message": "JWT expired at 2026-10-17 token=secreto"})))
    assert r.status_code == 401 and json.loads(r.body) == {"detail": "Token inválido o expirado."} and b"secreto" not in r.body
    assert r.headers["www-authenticate"] == "Bearer" and r.headers["access-control-allow-origin"] == "http://localhost:5173"
    registro = " ".join(x.getMessage() for x in caplog.records)
    assert codigo in registro and "GET" in registro and "secreto" not in registro and "expired" not in registro


@pytest.mark.parametrize("estado", [{"usa_cliente_servicio": True}, {"usa_cliente_caller": True, "usa_cliente_servicio": True}, {}])
def test_un_jwt_rechazado_con_cliente_de_servicio_o_desconocido_es_500_con_error_en_el_log_no_401(estado, caplog):
    """Un secreto de service_role rotado o mal pegado NO se presenta como «token inválido» (el frontend cierra la sesión con un 401)."""
    import asyncio
    import logging

    from app.main import manejador_error_postgrest

    with caplog.at_level(logging.ERROR, logger="app.main"):
        r = asyncio.run(manejador_error_postgrest(_peticion(**estado), APIError({"code": "PGRST301", "message": "JWT invalid XYZ-VALOR-REAL"})))
    assert r.status_code == 500 and b"XYZ-VALOR-REAL" not in r.body
    mensajes = [x for x in caplog.records if x.levelno >= logging.ERROR and "PGRST301" in x.getMessage()]
    assert mensajes and all("XYZ-VALOR-REAL" not in x.getMessage() for x in mensajes)


def test_las_dependencias_marcan_que_cliente_se_creo():
    import app.deps as deps
    from app.config import Settings

    ajustes = Settings(supabase_url="http://supabase.invalido", supabase_anon_key="anon-ficticia", supabase_service_role_key="service-ficticia")
    with patch("app.deps.create_client", return_value=MagicMock()):
        a, b = _peticion(), _peticion()
        deps.get_caller_client(a, f"Bearer {TOKEN_BIEN_FORMADO}", ajustes)
        deps.get_service_client(b, ajustes)
    assert a.state.usa_cliente_caller is True and not hasattr(a.state, "usa_cliente_servicio")
    assert b.state.usa_cliente_servicio is True and not hasattr(b.state, "usa_cliente_caller")


def test_otro_apierror_sigue_siendo_500_generico():
    import asyncio

    from starlette.requests import Request

    from app.main import manejador_error_postgrest

    request = Request({"type": "http", "method": "GET", "path": "/api/areas", "headers": [], "query_string": b""})
    assert asyncio.run(manejador_error_postgrest(request, APIError({"code": "XX000", "message": "x"}))).status_code == 500


# --- M1: lista cerrada de errores de GoTrue que son «token inválido» ----------------------------------------------------------------------------------------


@pytest.mark.parametrize("codigo", ["bad_jwt", "no_authorization", "session_not_found", "session_expired", "user_not_found", "user_banned"])
def test_m1_los_codigos_de_token_invalido_son_401_aunque_el_status_sea_raro(codigo):
    assert _get_sesion(AuthApiError("x", 418, codigo)).status_code == 401


@pytest.mark.parametrize("status_http", [400, 401, 403, 404, 422])
def test_m1_sin_codigo_o_con_codigo_desconocido_se_respalda_por_status(status_http):
    assert _get_sesion(AuthApiError("x", status_http, None)).status_code == 401
    assert _get_sesion(AuthApiError("x", status_http, "otro_codigo_nuevo")).status_code == 401


@pytest.mark.parametrize("error", [
    AuthApiError("rate limit", 429, "over_request_rate_limit"),     # todas las validaciones salen de la IP del backend
    AuthApiError("rate limit", 429, None),
    AuthApiError("tiempo agotado", 408, None),
    AuthApiError("raro del borde", 418, None),
    AuthApiError("rate limit con status de la lista", 400, "over_request_rate_limit"),
])
def test_m1_un_429_un_408_o_un_4xx_desconocido_no_cierran_la_sesion_503_con_retry_after(error):
    r = _get_sesion(error)
    assert r.status_code == 503 and r.headers["retry-after"] == "2" and "rate limit" not in r.text


# --- B1+B2: prefiltro de la forma del token, sin salir a GoTrue ----------------------------------------------------------------------------------------------


def _llamadas_a_gotrue(token):
    cliente_auth = MagicMock()
    cliente_auth.auth.get_user.side_effect = AuthApiError("x", 401, "bad_jwt")
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    try:
        with patch("app.deps.create_client", return_value=cliente_auth):
            r = TestClient(app).get("/api/sesion", headers={"Authorization": f"Bearer {token}"})
    finally:
        app.dependency_overrides.clear()
    return r, cliente_auth.auth.get_user.call_count


@pytest.mark.parametrize("token", ["x", "basura sin forma", "a.b", "a.b.c.d", "a..c", "a.b.c d", "a.b.c;", "<script>.b.c", "a" * 5000, ("a" * 2000 + ".") * 2 + "a" * 1000])
def test_b1_un_token_sin_la_forma_de_jwt_o_enorme_es_401_sin_salir_a_gotrue(token):
    r, llamadas = _llamadas_a_gotrue(token)
    assert r.status_code == 401 and r.json() == {"detail": "Token inválido o expirado."} and llamadas == 0


def test_b1_un_jwt_bien_formado_si_sale_a_validar():
    r, llamadas = _llamadas_a_gotrue(TOKEN_BIEN_FORMADO)
    assert r.status_code == 401 and llamadas == 1


def test_b1_el_limite_de_largo_es_4096():
    tres = "a" * 1365 + "." + "b" * 1365 + "." + "c" * 1365                      # 4097
    assert len(tres) == 4097 and _llamadas_a_gotrue(tres)[1] == 0
    ok = "a" * 1365 + "." + "b" * 1365 + "." + "c" * 1364                          # 4096
    assert len(ok) == 4096 and _llamadas_a_gotrue(ok)[1] == 1


# --- token vencido a mitad de sesión en un router con gate (caller) y datos (servicio): las dos marcas ---------------------------------------------------------


def _manejar(estado, mensaje, codigo="PGRST301"):
    import asyncio

    from app.main import manejador_error_postgrest

    return asyncio.run(manejador_error_postgrest(_peticion(**estado), APIError({"code": codigo, "message": mensaje})))


def test_dos_marcas_y_jwt_expired_es_401_con_warning_y_sin_el_texto(caplog):
    import json
    import logging

    with caplog.at_level(logging.WARNING, logger="app.main"):
        r = _manejar({"usa_cliente_caller": True, "usa_cliente_servicio": True}, "JWT expired")
    assert r.status_code == 401 and json.loads(r.body) == {"detail": "Token inválido o expirado."} and b"expired" not in r.body.lower()
    assert [x.levelno for x in caplog.records if "PGRST301" in x.getMessage()] == [logging.WARNING]
    assert not any("expired" in x.getMessage().lower() for x in caplog.records)


@pytest.mark.parametrize("mensaje,codigo", [("JWT cryptographic operation failed", "PGRST301"), ("Server lacks JWT secret", "PGRST300"), ("JWT expired", "PGRST302"), ("JWT expired", "PGRST303")])
def test_dos_marcas_y_firma_invalida_claims_u_otro_codigo_sigue_en_500_con_error(mensaje, codigo, caplog):
    import logging

    with caplog.at_level(logging.ERROR, logger="app.main"):
        r = _manejar({"usa_cliente_caller": True, "usa_cliente_servicio": True}, mensaje, codigo)
    assert r.status_code == 500 and r.body == b'{"detail":"Error interno del servidor."}'
    assert any(x.levelno == logging.ERROR for x in caplog.records)


def test_solo_servicio_o_sin_marcas_y_jwt_expired_es_500_no_se_culpa_al_usuario():
    assert _manejar({"usa_cliente_servicio": True}, "JWT expired").status_code == 500
    assert _manejar({}, "JWT expired").status_code == 500
