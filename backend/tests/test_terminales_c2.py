"""C2 del contrato de Terminales: GET /api/terminales y /{id} con el estado de contacto del puente.
Mocks del cliente de Supabase -- NUNCA contra la base real."""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app import permisos
from app.config import Settings, get_settings
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers.terminales import COLUMNAS_TERMINAL, estado_contacto

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
AHORA = datetime(2026, 10, 8, 15, 0, 0, tzinfo=timezone.utc)


def _settings(**cambios):
    base = {"supabase_url": "http://x", "supabase_anon_key": "a", "supabase_service_role_key": "s"}
    base.update(cambios)
    return Settings(_env_file=None, **base)


from _mocks_supabase import tabla as _tabla  # noqa: E402


def _fila(id_=1, serie="SERIE-FICTICIA-1", nombre="Entrada principal", activa=True, hace_seg=40, **extra):
    fila = {
        "id": id_,
        "terminal_id": serie,
        "nombre": nombre,
        "modelo": "DS-K1A8503EF-B",
        "activa": activa,
        "ultimo_contacto_en": None if hace_seg is None else (datetime.now(timezone.utc) - timedelta(seconds=hace_seg)).isoformat(),
        "terminal_alcanzable": True,
        "reloj_desfase_seg": 2,
        "version_pi": "1.4.0",
        "marcas_pendientes": 0,
    }
    fila.update(extra)
    return fila


@pytest.fixture
def entorno(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    entorno.codigos = []

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return entorno.permitido

    entorno.permitido = True
    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)

    def configurar(filas, settings=None):
        tabla = _tabla(filas)
        db = MagicMock()
        db.postgrest.schema.return_value.table.return_value = tabla
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_settings] = lambda: settings or _settings()
        app.dependency_overrides[get_service_client] = lambda: (_ for _ in ()).throw(
            AssertionError("la lista de terminales NUNCA usa service_role")
        )
        return db, tabla

    entorno.configurar = configurar
    return entorno


def _get(ruta="/api/terminales"):
    return TestClient(app, raise_server_exceptions=False).get(ruta, headers=AUTH)


# --- estado_contacto (función pura) ---------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "activa,hace,esperado",
    [
        (True, 10, ("en_linea", 10)),
        (True, 299, ("en_linea", 299)),
        (True, 300, ("sin_contacto", 300)),  # el umbral es inclusivo
        (True, 5000, ("sin_contacto", 5000)),
        (True, None, ("nunca", None)),
        (False, 10, ("inactiva", 10)),  # inactiva manda aunque haya contacto reciente
        (False, None, ("inactiva", None)),
        (True, -30, ("en_linea", 0)),  # reloj del puente adelantado: 0 s, no negativo
    ],
)
def test_estado_contacto(activa, hace, esperado):
    ultimo = None if hace is None else AHORA - timedelta(seconds=hace)
    assert estado_contacto(activa, ultimo, AHORA, 300) == esperado


def test_el_umbral_es_el_que_se_le_pasa():
    ultimo = AHORA - timedelta(seconds=100)
    assert estado_contacto(True, ultimo, AHORA, 60)[0] == "sin_contacto"
    assert estado_contacto(True, ultimo, AHORA, 120)[0] == "en_linea"


# --- GET /api/terminales ---------------------------------------------------------------------------------------------


def test_lista_las_terminales_con_su_estado(entorno):
    entorno.configurar([_fila(1, hace_seg=40), _fila(2, serie="S2", nombre="Bodega", hace_seg=1800), _fila(3, serie="S3", nombre="Vieja", activa=False)])
    r = _get()
    assert r.status_code == 200, r.text
    por_id = {t["id"]: t for t in r.json()}
    assert por_id[1]["estado_contacto"] == "en_linea"
    assert 0 <= por_id[1]["segundos_sin_contacto"] < 120
    assert por_id[2]["estado_contacto"] == "sin_contacto"
    assert por_id[3]["estado_contacto"] == "inactiva"
    assert por_id[1]["serie"] == "SERIE-FICTICIA-1"
    assert por_id[1]["terminal_alcanzable"] is True
    assert por_id[1]["reloj_desfase_seg"] == 2
    assert por_id[1]["version_pi"] == "1.4.0"
    assert por_id[1]["marcas_pendientes"] == 0


def test_terminal_que_nunca_hablo_es_nunca_con_campos_nulos(entorno):
    entorno.configurar(
        [_fila(hace_seg=None, terminal_alcanzable=None, reloj_desfase_seg=None, version_pi=None, marcas_pendientes=None)]
    )
    t = _get().json()[0]
    assert t["estado_contacto"] == "nunca"
    assert t["ultimo_contacto_en"] is None
    assert t["segundos_sin_contacto"] is None
    assert t["terminal_alcanzable"] is None
    assert t["reloj_desfase_seg"] is None


def test_el_umbral_sale_de_settings(entorno):
    entorno.configurar([_fila(hace_seg=100)], settings=_settings(terminal_umbral_sin_contacto_seg=60))
    assert _get().json()[0]["estado_contacto"] == "sin_contacto"
    entorno.configurar([_fila(hace_seg=100)], settings=_settings(terminal_umbral_sin_contacto_seg=600))
    assert _get().json()[0]["estado_contacto"] == "en_linea"


def test_el_umbral_por_defecto_es_300_y_se_lee_de_la_variable_de_entorno(monkeypatch):
    monkeypatch.delenv("TERMINAL_UMBRAL_SIN_CONTACTO_SEG", raising=False)
    assert _settings().terminal_umbral_sin_contacto_seg == 300
    monkeypatch.setenv("TERMINAL_UMBRAL_SIN_CONTACTO_SEG", "90")
    assert _settings().terminal_umbral_sin_contacto_seg == 90


def test_lista_vacia(entorno):
    entorno.configurar([])
    r = _get()
    assert r.status_code == 200
    assert r.json() == []


def test_ordena_por_nombre_y_solo_pide_las_columnas_del_contrato(entorno):
    _, tabla = entorno.configurar([_fila()])
    _get()
    tabla.select.assert_called_once_with(COLUMNAS_TERMINAL)
    tabla.order.assert_called_once_with("nombre")
    for prohibida in ("hash", "credencial", "ultima_ip", "password", "llave"):
        assert prohibida not in COLUMNAS_TERMINAL


def test_la_respuesta_no_expone_nada_de_credenciales(entorno):
    entorno.configurar([_fila(hash="no-debe-salir", ultima_ip="10.0.0.1")])
    t = _get().json()[0]
    assert set(t) == {
        "id", "serie", "nombre", "modelo", "activa", "estado_contacto", "ultimo_contacto_en",
        "segundos_sin_contacto", "terminal_alcanzable", "reloj_desfase_seg", "version_pi", "marcas_pendientes",
    }


def test_usa_el_cliente_del_caller_nunca_service_role(entorno):
    entorno.configurar([_fila()])
    assert _get().status_code == 200  # service_role levantaría AssertionError (-> 500) si se usara


def test_gate_lectura_o_edicion(entorno):
    entorno.configurar([_fila()])
    _get()
    assert entorno.codigos == [("terminal_usuario_lectura", "terminal_usuario_edicion")]


def test_sin_permiso_da_403_sin_consultar(entorno):
    _, tabla = entorno.configurar([_fila()])
    entorno.permitido = False
    assert _get().status_code == 403
    tabla.execute.assert_not_called()


# --- GET /api/terminales/{id} -------------------------------------------------------------------------------------------


def test_obtiene_una_terminal(entorno):
    _, tabla = entorno.configurar([_fila(7)])
    r = _get("/api/terminales/7")
    assert r.status_code == 200
    assert r.json()["id"] == 7
    tabla.eq.assert_called_once_with("id", 7)


def test_terminal_inexistente_da_404_fijo(entorno):
    entorno.configurar([])
    r = _get("/api/terminales/99")
    assert r.status_code == 404
    assert r.json()["detail"] == "La terminal no existe."


def test_id_no_entero_da_422(entorno):
    entorno.configurar([_fila()])
    assert _get("/api/terminales/abc").status_code == 422


def test_obtener_tambien_exige_el_permiso(entorno):
    entorno.configurar([_fila()])
    entorno.permitido = False
    assert _get("/api/terminales/1").status_code == 403


# --- ajustes de revisión: datos mal formados, fronteras y contrato de columnas ---------------------------------------


@pytest.mark.parametrize("malo", ["no-es-fecha", "2026-13-45T99:99:99", 12345, "   "])
def test_ultimo_contacto_no_parseable_degrada_a_nunca_con_error_en_el_log(entorno, malo, caplog):
    import logging

    entorno.configurar([_fila(7, ultimo_contacto_en=malo)])
    with caplog.at_level(logging.ERROR):
        r = _get("/api/terminales")
    assert r.status_code == 200, r.text
    t = r.json()[0]
    assert t["estado_contacto"] == "nunca" and t["ultimo_contacto_en"] is None
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


@pytest.mark.parametrize("nombre", [None, ""])
def test_nombre_ausente_usa_la_serie_en_vez_de_dar_500(entorno, nombre):
    entorno.configurar([_fila(7, serie="SERIE-9", nombre=nombre)])
    r = _get("/api/terminales")
    assert r.status_code == 200 and r.json()[0]["nombre"] == "SERIE-9"


@pytest.mark.parametrize("valor", ["0", "-1", "9223372036854775808", "99999999999999999999"])
def test_fronteras_de_terminal_id_dan_422_sin_consultar(entorno, valor):
    _, tabla = entorno.configurar([_fila(7)])
    r = _get(f"/api/terminales/{valor}")
    assert r.status_code == 422
    tabla.execute.assert_not_called()


def test_terminal_id_maximo_de_bigint_llega_a_la_consulta_y_da_404(entorno):
    entorno.configurar([])
    assert _get("/api/terminales/9223372036854775807").status_code == 404


def test_las_columnas_del_contrato_existen_en_tiempo_terminal():
    import re
    from pathlib import Path

    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    texto = "\n".join(
        p.read_text(encoding="utf-8")
        for p in sorted(ddl.glob("0[2]_*.sql")) + sorted(ddl.glob("8[0-5]_*.sql"))
    )
    cuerpo = re.search(r"CREATE TABLE tiempo\.terminal\s*\((.*?)\n\);", texto, re.S)
    assert cuerpo, "no se encontró CREATE TABLE tiempo.terminal"
    definidas = set(re.findall(r"^\s+([a-z_]+)\s+[a-z]", cuerpo.group(1), re.M))
    definidas |= set(re.findall(r"ALTER TABLE tiempo\.terminal.*?ADD COLUMN\s+([a-z_]+)", texto, re.S))
    definidas |= set(re.findall(r"^\s+ADD COLUMN\s+([a-z_]+)", texto, re.M))
    pedidas = {c.strip() for c in COLUMNAS_TERMINAL.split(",")}
    assert len(pedidas) == 10
    assert pedidas <= definidas, f"faltan en el DDL: {pedidas - definidas}"
