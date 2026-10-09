"""Transporte de /api/terminal/*: alcance exacto del prefijo, cabeceras en TODA respuesta, 422 fijo sin eco y pruebas contra un
uvicorn REAL (no TestClient) del límite de cuerpo. Mocks; nunca la base real."""

import socket
import threading
import time
from unittest.mock import MagicMock

import pytest
import uvicorn
from fastapi import APIRouter
from fastapi.testclient import TestClient
from pydantic import BaseModel

from _mocks_supabase import Resultado, rpc_con_firma_real
from app.config import Settings, get_settings
from app.deps import get_service_client
from app.main import app
from app.terminal_auth import LimiteCuerpoTerminal, CabecerasTerminal, es_ruta_terminal

LLAVE = "scjt_" + "F" * 43
AUTENTICADA = {"terminal_id": 7, "serie": "TERM-FICTICIA-01", "credencial_id": 3, "ip_cambio": False}


def _db():
    db = MagicMock()
    rpc = rpc_con_firma_real()
    db.postgrest.schema.return_value.rpc = rpc

    def segun(nombre, params):
        r = MagicMock()
        r.execute.return_value = Resultado(AUTENTICADA if nombre == "fn_terminal_autenticar" else {})
        return r

    rpc.side_effect = segun
    return db, rpc


@pytest.fixture
def cliente():
    db, rpc = _db()
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url="http://x.invalido", supabase_anon_key="a", supabase_service_role_key="s"
    )
    c = TestClient(app, base_url="https://testserver", client=("198.51.100.7", 1), raise_server_exceptions=False)
    c.rpc = rpc
    return c


def _auth():
    return {"Authorization": f"Bearer {LLAVE}"}


# --- alcance exacto del prefijo (B1 de security) ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "ruta,esperado",
    [
        ("/api/terminal", True), ("/api/terminal/", True), ("/api/terminal/marcas", True), ("/api/terminal/x/y", True),
        ("/api/terminales", False), ("/api/terminales/1/usuarios", False), ("/api/terminalx", False),
        ("/api/terminal-algo", False), ("/api", False), ("/", False), ("/salud", False), ("/API/terminal/marcas", False),
    ],
)
def test_es_ruta_terminal(ruta, esperado):
    assert es_ruta_terminal(ruta) is esperado


def test_la_api_web_de_terminales_no_recibe_el_limite_ni_las_cabeceras_de_la_terminal(cliente):
    """/api/terminales/* empieza con «/api/terminal» pero NO es la API del puente."""
    r = cliente.post("/api/terminales/1/usuarios", content=b"x" * (300 * 1024), headers={"Authorization": "Bearer jwt-falso"})
    assert r.status_code != 413
    assert "strict-transport-security" not in r.headers and r.headers.get("cache-control") != "no-store"


def test_el_prefijo_real_si_recibe_ambas_cosas(cliente):
    r = cliente.post("/api/terminal/marcas", content=b"x" * (300 * 1024), headers=_auth())
    assert r.status_code == 413 and "strict-transport-security" in r.headers


# --- cabeceras en TODA respuesta (B5) ------------------------------------------------------------------------------------------------


def _ruta_temporal(ruta, funcion):
    router = APIRouter()
    router.get(ruta)(funcion)
    app.include_router(router)


def _quitar(ruta):
    app.router.routes[:] = [x for x in app.router.routes if getattr(x, "path", "") != ruta]


def test_los_401_422_413_y_500_de_la_terminal_llevan_hsts_y_no_store(cliente):
    def explota():
        raise RuntimeError("secreto-interno")

    _ruta_temporal("/api/terminal/_explota", explota)
    try:
        respuestas = [
            cliente.post("/api/terminal/marcas", json={}),                                       # 401
            cliente.post("/api/terminal/marcas", json={"x": 1}, headers=_auth()),                 # 422
            cliente.post("/api/terminal/marcas", content=b"x" * (300 * 1024), headers=_auth()),   # 413
            cliente.get("/api/terminal/_explota"),                                                 # 500 (handler global)
            cliente.get("/api/terminal/no-existe"),                                                # 404
            cliente.delete("/api/terminal/marcas"),                                                # 405
        ]
    finally:
        _quitar("/api/terminal/_explota")
    assert [r.status_code for r in respuestas] == [401, 422, 413, 500, 404, 405]
    for r in respuestas:
        assert "strict-transport-security" in r.headers and r.headers["cache-control"] == "no-store", r.status_code
    assert "secreto-interno" not in respuestas[3].text


def test_una_ruta_que_no_es_de_la_terminal_no_recibe_hsts_ni_no_store(cliente):
    r = cliente.get("/salud")
    assert r.status_code == 200 and "strict-transport-security" not in r.headers


def test_no_duplica_las_cabeceras_cuando_la_respuesta_ya_las_trae(cliente):
    r = cliente.post("/api/terminal/marcas", content=b"x" * (300 * 1024), headers=_auth())
    assert r.headers.get_list("strict-transport-security") == ["max-age=31536000"]
    assert r.headers.get_list("cache-control") == ["no-store"]


# --- 422 fijo sin eco y JSON mal formado (B3) -----------------------------------------------------------------------------------------


def test_la_validacion_de_la_terminal_no_repite_lo_que_mando_el_cliente(cliente):
    r = cliente.post("/api/terminal/latido", json={"hora_terminal": "SECRETO-NO-ECO-991", "extra": "otro"}, headers=_auth())
    assert r.status_code == 422 and r.json() == {"detail": "Los datos enviados no son válidos."}
    assert "SECRETO" not in r.text and "991" not in r.text


@pytest.mark.parametrize("cuerpo", [b"{no es json", b"", b"[1,2,3", b"\xff\xfe", b'{"a": }'])
def test_un_json_mal_formado_tambien_es_422_fijo(cliente, cuerpo):
    r = cliente.post("/api/terminal/marcas", content=cuerpo, headers={**_auth(), "Content-Type": "application/json"})
    assert r.status_code == 422 and r.json() == {"detail": "Los datos enviados no son válidos."}


def test_fuera_de_la_terminal_el_422_estandar_de_fastapi_se_conserva(cliente):
    class Cuerpo(BaseModel):
        n: int

    router = APIRouter()

    @router.post("/api/_prueba_validacion")
    def f(c: Cuerpo):
        return {}

    app.include_router(router)
    try:
        r = cliente.post("/api/_prueba_validacion", json={"n": "no-es-numero"})
        j = cliente.post("/api/_prueba_validacion", content=b"{roto", headers={"Content-Type": "application/json"})
    finally:
        _quitar("/api/_prueba_validacion")
    assert r.status_code == 422 and isinstance(r.json()["detail"], list)
    assert j.status_code in (400, 422) and j.json() != {"detail": "Los datos enviados no son válidos."}


def test_los_demas_http_exception_de_la_terminal_no_se_alteran(cliente):
    assert cliente.post("/api/terminal/marcas", json={}).status_code == 401
    assert cliente.get("/api/terminal/cola").status_code == 401


# --- uvicorn REAL (no TestClient) ------------------------------------------------------------------------------------------------------


@pytest.fixture
def servidor():
    db, _ = _db()
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url="http://x.invalido", supabase_anon_key="a", supabase_service_role_key="s", terminal_requiere_https=False
    )
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    puerto = sock.getsockname()[1]
    sock.close()
    config = uvicorn.Config(app, host="127.0.0.1", port=puerto, log_level="error", lifespan="off")
    server = uvicorn.Server(config)
    hilo = threading.Thread(target=server.run, daemon=True)
    hilo.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    assert server.started
    yield puerto
    server.should_exit = True
    hilo.join(timeout=5)
    app.dependency_overrides.clear()


def _leer_respuesta(s: socket.socket) -> bytes:
    s.settimeout(5)
    datos = b""
    while b"\r\n\r\n" not in datos:
        trozo = s.recv(4096)
        if not trozo:
            break
        datos += trozo
    return datos


def _estado(respuesta: bytes) -> int:
    return int(respuesta.split(b" ", 2)[1])


def _salud(puerto) -> int:
    s = socket.create_connection(("127.0.0.1", puerto), timeout=5)
    s.sendall(b"GET /salud HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    r = _leer_respuesta(s)
    s.close()
    return _estado(r)


def test_uvicorn_real_chunked_de_1_mb_sin_credencial_es_413_y_el_servidor_sigue_sano(servidor):
    s = socket.create_connection(("127.0.0.1", servidor), timeout=5)
    s.sendall(b"POST /api/terminal/marcas HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n")
    trozo = b"x" * 65536
    try:
        for _ in range(16):  # 1 MB
            s.sendall(f"{len(trozo):x}\r\n".encode() + trozo + b"\r\n")
    except (BrokenPipeError, ConnectionResetError):
        pass  # el servidor ya respondió y cerró: es lo esperado
    respuesta = _leer_respuesta(s)
    s.close()
    assert _estado(respuesta) == 413 and b"strict-transport-security" in respuesta.lower()
    assert _salud(servidor) == 200  # el servidor sigue atendiendo


def test_uvicorn_real_content_length_falso_no_pasa_el_limite(servidor):
    """Declara 100 bytes y manda mucho más: h11 corta la petición inconsistente (400) o el límite responde 413; nunca llega al app."""
    s = socket.create_connection(("127.0.0.1", servidor), timeout=5)
    s.sendall(b"POST /api/terminal/marcas HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nContent-Type: application/json\r\n\r\n")
    try:
        s.sendall(b"x" * (400 * 1024))
    except (BrokenPipeError, ConnectionResetError):
        pass
    respuesta = _leer_respuesta(s)
    s.close()
    assert not respuesta or _estado(respuesta) in (400, 401, 413, 422)
    assert _salud(servidor) == 200


def test_uvicorn_real_expect_100_continue_con_cuerpo_grande_se_rechaza_sin_pedir_el_cuerpo(servidor):
    s = socket.create_connection(("127.0.0.1", servidor), timeout=5)
    s.sendall(
        b"POST /api/terminal/marcas HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: "
        + str(5 * 1024 * 1024).encode()
        + b"\r\nContent-Type: application/json\r\n\r\n"
    )
    respuesta = _leer_respuesta(s)  # NO se manda el cuerpo: el servidor debe contestar con las cabeceras solas
    s.close()
    assert b"100 Continue" not in respuesta.split(b"\r\n\r\n")[0] and _estado(respuesta) == 413
    assert _salud(servidor) == 200


def test_uvicorn_real_una_peticion_normal_sigue_funcionando(servidor):
    s = socket.create_connection(("127.0.0.1", servidor), timeout=5)
    s.sendall(b"POST /api/terminal/marcas HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}")
    respuesta = _leer_respuesta(s)
    s.close()
    assert _estado(respuesta) == 401  # sin credencial: llegó al app, no al límite
