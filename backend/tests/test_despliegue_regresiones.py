"""Regresiones de DESPLIEGUE que los mocks no detectaron (verificación en el Pi, 2026-10-08):

1. `.rpc("fn")` sin el segundo argumento: la postgrest-py de la imagen exige `params` posicional (TypeError en producción).
2. `@app.exception_handler(Exception)` quedó pegado a otra función: el handler global de 500 era `ruta_para_log` y cualquier
   excepción no capturada devolvía un 500 pelado, sin JSON, sin CORS y sin HSTS en /api/terminal/*."""

import ast
import inspect
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient
from postgrest import SyncPostgrestClient

from _mocks_supabase import cliente_rpc, db_por_nombre, rpc_con_firma_real
from app.main import ORIGENES_PERMITIDOS, app, manejador_excepciones_no_capturadas

APP = Path(__file__).resolve().parents[1] / "app"


# --- 1. firma de .rpc ------------------------------------------------------------------------------------------------------------------


def test_la_libreria_real_exige_params_posicional():
    """Ancla del fake: si la firma real cambia, esta prueba lo avisa."""
    parametros = inspect.signature(SyncPostgrestClient.rpc).parameters
    assert parametros["params"].default is inspect.Parameter.empty


def test_el_fake_rechaza_rpc_sin_params_como_la_libreria_real():
    rpc = rpc_con_firma_real()
    with pytest.raises(TypeError):
        rpc("fn_sin_params")
    rpc("fn", {})
    rpc("fn", {"p": 1}, count=None)
    assert rpc.call_count == 2


def test_los_fakes_compartidos_usan_la_firma_real():
    for db in (db_por_nombre(), cliente_rpc(1)[0]):
        with pytest.raises(TypeError):
            db.postgrest.schema("tiempo").rpc("fn_sin_params")


def _llamadas_rpc(arbol):
    for n in ast.walk(arbol):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "rpc":
            yield n


def test_toda_llamada_a_rpc_en_app_lleva_params():
    """Regla por AST: `.rpc(func, params, ...)` — al menos dos argumentos posicionales, o `params=` por nombre."""
    sin_params = []
    for p in sorted(APP.rglob("*.py")):
        for n in _llamadas_rpc(ast.parse(p.read_text(encoding="utf-8"))):
            if len(n.args) < 2 and not any(k.arg == "params" for k in n.keywords):
                sin_params.append(f"{p.relative_to(APP)}:{n.lineno}")
    assert sin_params == [], sin_params


@pytest.mark.parametrize(
    "fuente,debe_fallar",
    [
        ('db.postgrest.schema("t").rpc("fn").execute()', True),
        ('db.postgrest.schema("t").rpc("fn", {}).execute()', False),
        ('db.postgrest.schema("t").rpc("fn", {"a": 1}).execute()', False),
        ('db.postgrest.schema("t").rpc("fn", params={}).execute()', False),
        ('db.postgrest.schema("t").rpc(\n    "fn"\n).execute()', True),
    ],
)
def test_la_regla_ast_de_rpc_detecta_la_llamada_sin_params(fuente, debe_fallar):
    falla = any(len(n.args) < 2 and not any(k.arg == "params" for k in n.keywords) for n in _llamadas_rpc(ast.parse(fuente)))
    assert falla is debe_fallar


# --- 2. handler global de 500 -----------------------------------------------------------------------------------------------------------------


def test_el_handler_registrado_para_exception_es_el_correcto():
    assert app.exception_handlers[Exception] is manejador_excepciones_no_capturadas


def test_ningun_decorador_de_handler_queda_pegado_a_una_funcion_que_no_es_handler():
    """Todo @app.exception_handler(...) decora una función async con (request, exc)."""
    arbol = ast.parse((APP / "main.py").read_text(encoding="utf-8"))
    for n in ast.walk(arbol):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for d in n.decorator_list:
                if isinstance(d, ast.Call) and getattr(d.func, "attr", "") == "exception_handler":
                    assert isinstance(n, ast.AsyncFunctionDef) and [a.arg for a in n.args.args] == ["request", "exc"], n.name


def test_una_excepcion_no_capturada_da_500_json_con_cors():
    ruta = APIRouter()

    @ruta.get("/api/_prueba_explota")
    def explota():
        raise RuntimeError("secreto-interno-5521")

    app.include_router(ruta)
    try:
        origen = ORIGENES_PERMITIDOS[0]
        r = TestClient(app, raise_server_exceptions=False).get("/api/_prueba_explota", headers={"Origin": origen})
    finally:
        app.router.routes[:] = [x for x in app.router.routes if getattr(x, "path", "") != "/api/_prueba_explota"]
    assert r.status_code == 500
    assert r.json() == {"detail": "Error interno del servidor."}
    assert r.headers["access-control-allow-origin"] == origen
    assert "5521" not in r.text


def test_el_500_no_lleva_cors_para_un_origen_no_permitido():
    ruta = APIRouter()

    @ruta.get("/api/_prueba_explota2")
    def explota():
        raise RuntimeError("x")

    app.include_router(ruta)
    try:
        r = TestClient(app, raise_server_exceptions=False).get("/api/_prueba_explota2", headers={"Origin": "http://malo.example"})
    finally:
        app.router.routes[:] = [x for x in app.router.routes if getattr(x, "path", "") != "/api/_prueba_explota2"]
    assert r.status_code == 500 and r.json() == {"detail": "Error interno del servidor."}
    assert "access-control-allow-origin" not in r.headers


def test_el_500_de_la_terminal_lleva_hsts():
    ruta = APIRouter()

    @ruta.get("/api/terminal/_prueba_explota")
    def explota():
        raise RuntimeError("x")

    app.include_router(ruta)
    try:
        r = TestClient(app, raise_server_exceptions=False).get("/api/terminal/_prueba_explota")
    finally:
        app.router.routes[:] = [x for x in app.router.routes if getattr(x, "path", "") != "/api/terminal/_prueba_explota"]
    assert r.status_code == 500 and r.json() == {"detail": "Error interno del servidor."}
    assert "strict-transport-security" in r.headers


def test_un_apierror_no_anticipado_tambien_da_500_json_con_cors():
    from postgrest.exceptions import APIError

    ruta = APIRouter()

    @ruta.get("/api/_prueba_apierror")
    def explota():
        raise APIError({"code": "XX999", "message": "texto-de-la-base-7788"})

    app.include_router(ruta)
    try:
        origen = ORIGENES_PERMITIDOS[0]
        r = TestClient(app, raise_server_exceptions=False).get("/api/_prueba_apierror", headers={"Origin": origen})
    finally:
        app.router.routes[:] = [x for x in app.router.routes if getattr(x, "path", "") != "/api/_prueba_apierror"]
    assert r.status_code == 500 and r.json() == {"detail": "Error interno del servidor."}
    assert r.headers["access-control-allow-origin"] == origen and "7788" not in r.text
