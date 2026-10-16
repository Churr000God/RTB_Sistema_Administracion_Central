"""Middleware de latencia: una línea por petición (método, plantilla, status, ms) sin ids, query, cabeceras ni cuerpo; excluye /salud y /api/terminal/*; registra el 500 sin alterar la
respuesta; y un WARNING agregado por minuto con las lentas."""

import logging
import re

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.latencia import AgregadorDeLentas, MedirLatencia, linea_de_latencia

SECRETO = "SECRETO-9f3a"
ID_REAL = "11111111-2222-3333-4444-555555555555"


def _app(con_middleware=True, reloj=None):
    app = FastAPI()
    if con_middleware:
        app.add_middleware(MedirLatencia, **({"reloj": reloj} if reloj else {}))

    @app.get("/api/personas/{persona_id}")
    def persona(persona_id: str):
        return {"id": persona_id}

    @app.get("/salud")
    def salud():
        return {"estado": "ok"}

    @app.post("/api/terminal/latido")
    def latido():
        return {"ok": True}

    @app.get("/api/terminales/{terminal_id}/usuarios")
    def usuarios(terminal_id: str):
        return []

    @app.get("/api/falla")
    def falla():
        raise RuntimeError(f"boom con {SECRETO}")

    @app.get("/api/prohibido")
    def prohibido():
        raise HTTPException(403, "No tienes permiso.")

    return app


def _lineas(caplog):
    return [r.getMessage() for r in caplog.records if r.name == "app.latencia" and r.levelno == logging.INFO]


def test_la_linea_lleva_metodo_plantilla_status_y_duracion_sin_ids_ni_query_ni_cabeceras(caplog):
    cliente = TestClient(_app())
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        r = cliente.get(f"/api/personas/{ID_REAL}?token={SECRETO}&correo=ana@example.com", headers={"Authorization": f"Bearer {SECRETO}", "Cookie": f"s={SECRETO}"})
    assert r.status_code == 200
    lineas = _lineas(caplog)
    assert len(lineas) == 1
    assert re.fullmatch(r"GET /api/personas/\{persona_id\} status=200 duracion_ms=\d+", lineas[0]), lineas[0]
    for prohibido in (ID_REAL, SECRETO, "ana@example.com", "correo", "token", "Bearer", "Authorization", "Cookie"):
        assert prohibido not in " ".join(r_.getMessage() for r_ in caplog.records), prohibido


def test_una_plantilla_con_varios_parametros_y_otro_metodo_y_status(caplog):
    cliente = TestClient(_app())
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        cliente.get("/api/terminales/7/usuarios")
        cliente.get("/api/prohibido")
    assert _lineas(caplog)[0].startswith("GET /api/terminales/{terminal_id}/usuarios status=200 duracion_ms=")      # /api/terminales (web) SÍ se mide
    assert re.fullmatch(r"GET /api/prohibido status=403 duracion_ms=\d+", _lineas(caplog)[1])


def test_una_ruta_inexistente_no_deja_el_path_real_en_el_log(caplog):
    cliente = TestClient(_app())
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        r = cliente.get(f"/api/no-existe/{ID_REAL}")
    assert r.status_code == 404
    assert _lineas(caplog) == [_lineas(caplog)[0]] and re.fullmatch(r"GET \(sin ruta\) status=404 duracion_ms=\d+", _lineas(caplog)[0])
    assert ID_REAL not in " ".join(x.getMessage() for x in caplog.records)


def test_salud_y_la_api_del_puente_quedan_excluidas(caplog):
    cliente = TestClient(_app())
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        assert cliente.get("/salud").status_code == 200
        assert cliente.post("/api/terminal/latido").status_code == 200
    assert _lineas(caplog) == []


def test_una_excepcion_no_capturada_se_registra_con_500_y_la_respuesta_no_cambia(caplog):
    con = TestClient(_app(), raise_server_exceptions=False)
    sin = TestClient(_app(con_middleware=False), raise_server_exceptions=False)
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        r_con = con.get("/api/falla")
    r_sin = sin.get("/api/falla")
    assert (r_con.status_code, r_con.text, dict(r_con.headers)) == (r_sin.status_code, r_sin.text, dict(r_sin.headers))      # respuesta idéntica con y sin middleware
    assert r_con.status_code == 500
    lineas = _lineas(caplog)
    assert len(lineas) == 1 and re.fullmatch(r"GET /api/falla status=500 duracion_ms=\d+", lineas[0])
    assert SECRETO not in " ".join(x.getMessage() for x in caplog.records)


def test_la_excepcion_se_re_lanza_al_cliente_de_pruebas_sin_alterarla():
    cliente = TestClient(_app())                       # raise_server_exceptions=True: el RuntimeError original llega intacto
    with pytest.raises(RuntimeError, match="boom"):
        cliente.get("/api/falla")


def test_la_duracion_usa_el_reloj_monotonico_inyectado(caplog):
    tiempos = iter([100.0, 100.250, 100.250, 100.250])
    cliente = TestClient(_app(reloj=lambda: next(tiempos)))
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        cliente.get("/api/prohibido")
    assert "duracion_ms=250" in _lineas(caplog)[0]


def test_si_el_registro_falla_la_peticion_sigue_y_responde_lo_mismo(monkeypatch):
    import app.latencia as modulo

    monkeypatch.setattr(modulo, "linea_de_latencia", lambda *a: (_ for _ in ()).throw(ValueError("fallo del log")))
    r = TestClient(_app()).get(f"/api/personas/{ID_REAL}")
    assert r.status_code == 200 and r.json() == {"id": ID_REAL}


def test_el_formato_exacto_de_la_linea():
    assert linea_de_latencia("GET", "/api/sesion", 200, 153) == "GET /api/sesion status=200 duracion_ms=153"


# --- agregado por minuto de las lentas ------------------------------------------------------------------------------------------------------------------


def test_el_agregado_emite_un_solo_warning_por_minuto_con_lentas_y_nada_si_no_hubo(caplog):
    t = [0.0]
    agregador = AgregadorDeLentas(reloj=lambda: t[0])
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        for duracion in (0.1, 2.5, 6.0, 0.3):
            agregador.registrar(duracion)
        assert [r for r in caplog.records if r.levelno == logging.WARNING] == []         # aún dentro del minuto
        t[0] = 61.0
        agregador.registrar(0.2)                                                           # cambia el minuto: se informa el ANTERIOR
        t[0] = 125.0
        agregador.registrar(0.2)                                                           # el minuto 1 no tuvo lentas: sin warning
    avisos = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert avisos == ["latencia: en el minuto anterior 2 de 4 peticiones tardaron más de 2 s y 1 más de 5 s"]


def test_el_agregado_no_lleva_rutas_ni_datos(caplog):
    agregador = AgregadorDeLentas(reloj=lambda: 0.0)
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        agregador.registrar(9.0)
    assert not caplog.records                                                              # nada hasta que cambie el minuto


# --- cableado en la app real ----------------------------------------------------------------------------------------------------------------------------


def test_la_app_real_tiene_el_middleware_y_mide_sin_exponer_nada(caplog):
    from app.main import app

    assert any(m.cls is MedirLatencia for m in app.user_middleware)
    cliente = TestClient(app, raise_server_exceptions=False)
    with caplog.at_level(logging.INFO, logger="app.latencia"):
        assert cliente.get("/salud").status_code == 200
        r = cliente.get("/api/sesion?x=" + SECRETO)                    # sin Authorization: la validación lo rechaza (422), pero se mide
    assert r.status_code == 422
    lineas = _lineas(caplog)
    assert len(lineas) == 1 and re.fullmatch(r"GET /api/sesion status=422 duracion_ms=\d+", lineas[0])
    assert SECRETO not in lineas[0]


def test_la_configuracion_deja_el_logger_en_info_con_manejador_solo_si_la_raiz_no_tiene(monkeypatch):
    import app.latencia as modulo

    raiz = logging.getLogger()
    # raíz SIN manejadores (producción con uvicorn): el logger recibe el suyo, con hora, y nivel INFO
    monkeypatch.setattr(raiz, "handlers", [])
    monkeypatch.setattr(modulo.logger, "handlers", [])
    modulo.configurar_registro_de_latencia()
    modulo.configurar_registro_de_latencia()                       # idempotente
    assert modulo.logger.level == logging.INFO and len(modulo.logger.handlers) == 1
    assert "%(asctime)s" in modulo.logger.handlers[0].formatter._fmt
    # raíz CON manejadores: no se agrega otro (nada de líneas duplicadas)
    monkeypatch.setattr(raiz, "handlers", [logging.NullHandler()])
    monkeypatch.setattr(modulo.logger, "handlers", [])
    modulo.configurar_registro_de_latencia()
    assert modulo.logger.handlers == []


# --- condición de security: ningún valor de path, query ni cabecera llega al texto registrado ------------------------------------------------------------


def _todo_el_texto_registrado(caplog) -> str:
    """Mensaje formateado, argumentos y nombre de CADA registro del SERVIDOR (app, uvicorn, starlette, fastapi: no solo `app.latencia`). Se excluyen httpx/httpcore/asyncio porque son el
    CLIENTE de pruebas (TestClient), que sí registra la URL que él mismo pide, no la aplicación."""
    partes = []
    for r in caplog.records:
        if r.name.split(".")[0] not in ("app", "uvicorn", "starlette", "fastapi"):
            continue
        partes += [r.getMessage(), str(r.msg), str(r.args), r.name, r.pathname, str(getattr(r, "exc_text", ""))]
    return " | ".join(partes)


def test_un_uuid_y_un_correo_en_el_path_no_aparecen_en_el_texto_registrado(caplog):
    correo = "mariana.alcantara@ejemplo-privado.com"
    cliente = TestClient(_app())
    with caplog.at_level(logging.DEBUG):
        for valor in (ID_REAL, correo, correo.replace("@", "%40")):
            assert cliente.get(f"/api/personas/{valor}").status_code == 200
    lineas = _lineas(caplog)
    assert len(lineas) == 3 and all(l.startswith("GET /api/personas/{persona_id} status=200 duracion_ms=") for l in lineas)
    texto = _todo_el_texto_registrado(caplog)
    for prohibido in (ID_REAL, "11111111", correo, "mariana", "alcantara", "ejemplo-privado", "%40"):
        assert prohibido not in texto, prohibido


def test_una_query_con_curp_y_la_cabecera_authorization_no_aparecen_en_el_texto_registrado(caplog):
    curp = "AARM910427MDFLVR03"
    cliente = TestClient(_app())
    with caplog.at_level(logging.DEBUG):
        r = cliente.get(f"/api/personas/{ID_REAL}?curp={curp}&rfc=AARM910427H8A", headers={"Authorization": f"Bearer {SECRETO}", "X-Otra": "valor-de-cabecera"})
    assert r.status_code == 200
    texto = _todo_el_texto_registrado(caplog)
    for prohibido in (curp, "AARM910427", "curp", "rfc", "?", SECRETO, "Bearer", "Authorization", "valor-de-cabecera", "X-Otra"):
        assert prohibido not in texto, prohibido


def test_el_texto_registrado_en_una_ruta_inexistente_y_en_un_error_tampoco_lleva_path_query_ni_cabeceras(caplog):
    cliente = TestClient(_app(), raise_server_exceptions=False)
    with caplog.at_level(logging.DEBUG):
        cliente.get(f"/api/no-existe/{ID_REAL}?curp=AARM910427MDFLVR03", headers={"Authorization": f"Bearer {SECRETO}"})
        cliente.get(f"/api/falla?curp=AARM910427MDFLVR03", headers={"Authorization": f"Bearer {SECRETO}"})
    latencia = " | ".join(_lineas(caplog))
    for prohibido in (ID_REAL, "AARM910427", SECRETO, "Bearer", "no-existe"):
        assert prohibido not in latencia, prohibido
