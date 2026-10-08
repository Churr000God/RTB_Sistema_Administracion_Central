"""C3 del contrato de Terminales: hook de baja de terminal al suspender o dar de baja a una persona,
y `advertencias` / `bajas_terminal_emitidas` en POST /api/personas/{id}/movimientos. Mocks del cliente de
Supabase -- NUNCA contra la base real ni RPC de escritura reales."""

import logging
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import cliente_rpc, db_por_nombre, tabla
from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

PERSONA_ID = "11111111-1111-1111-1111-111111111111"
AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"
CRUDO = "texto-crudo-id-interno-5190"
AUTH = {"Authorization": "Bearer fake-token"}


def _movimiento(tipo):
    return {
        "id": "33333333-3333-3333-3333-333333333333",
        "persona_id": PERSONA_ID,
        "tipo_movimiento": tipo,
        "fecha_efectiva": "2026-10-08T10:00:00+00:00",
        "motivo": "motivo ficticio",
        "documento_ref": None,
        "registrado_por": AUTH_USER_ID,
    }


@pytest.fixture
def entorno(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    entorno.permitido = True
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, p, *c: entorno.permitido)

    orden = []  # ORDEN de llamadas entre el insert del movimiento y el RPC de baja

    def configurar(tipo, resultado=0, error=None, error_insert=None):
        bit = tabla([_movimiento(tipo)])
        bit.insert.side_effect = lambda *a, **k: orden.append("insert") or bit
        if error_insert is not None:
            bit.execute.side_effect = error_insert
        caller_db = db_por_nombre(bitacora_movimiento_persona=bit)
        servicio, rpc = cliente_rpc(resultado, error)
        rpc.side_effect = lambda *a, **k: orden.append("rpc") or rpc.return_value
        app.dependency_overrides[get_caller_client] = lambda: caller_db
        app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
            auth_user_id=AUTH_USER_ID, correo="x@example.com"
        )
        app.dependency_overrides[get_service_client] = lambda: servicio
        entorno.rpc, entorno.orden, entorno.caller_db, entorno.tabla = rpc, orden, caller_db, bit

    entorno.configurar = configurar
    return entorno


def _post(tipo, e=None):
    return TestClient(app, raise_server_exceptions=False).post(
        f"/api/personas/{PERSONA_ID}/movimientos", json={"tipo_movimiento": tipo, "motivo": "motivo ficticio"}, headers=AUTH
    )


@pytest.mark.parametrize("tipo", ["suspension", "baja_definitiva"])
def test_suspender_o_dar_de_baja_pide_la_baja_en_las_terminales(entorno, tipo):
    entorno.configurar(tipo, resultado=2)
    r = _post(tipo)
    assert r.status_code == 201, r.text
    cuerpo = r.json()
    assert cuerpo["advertencias"] == []
    assert cuerpo["bajas_terminal_emitidas"] == 2
    nombre, parametros = entorno.rpc.call_args.args
    assert nombre == "fn_terminal_baja_por_persona_inactiva"
    assert parametros == {"p_persona_id": PERSONA_ID}


@pytest.mark.parametrize("tipo", ["reactivacion", "alta"])
def test_reactivar_o_dar_de_alta_no_llama_al_rpc(entorno, tipo):
    entorno.configurar(tipo)
    r = _post(tipo)
    assert r.status_code == 201
    assert r.json()["advertencias"] == []
    assert r.json()["bajas_terminal_emitidas"] == 0
    entorno.rpc.assert_not_called()


def test_cero_bajas_es_un_exito_sin_advertencia(entorno):
    entorno.configurar("suspension", resultado=0)
    cuerpo = _post("suspension").json()
    assert cuerpo["advertencias"] == [] and cuerpo["bajas_terminal_emitidas"] == 0


def test_el_rpc_corre_con_service_role_y_despues_del_insert(entorno):
    entorno.configurar("suspension", resultado=1)
    _post("suspension")
    entorno.caller_db.postgrest.schema.return_value.rpc.assert_not_called()  # el caller nunca lo ejecuta
    assert entorno.orden == ["insert", "rpc"]


def test_si_el_insert_falla_no_se_pide_ninguna_baja(entorno):
    entorno.configurar("suspension", error_insert=APIError({"code": "XX000", "message": CRUDO}))
    r = _post("suspension")
    assert r.status_code == 500
    entorno.rpc.assert_not_called()


def test_sin_permiso_no_inserta_ni_pide_baja(entorno):
    entorno.configurar("suspension")
    entorno.permitido = False
    r = _post("suspension")
    assert r.status_code == 403
    entorno.tabla.insert.assert_not_called()
    entorno.rpc.assert_not_called()


@pytest.mark.parametrize(
    "error",
    [
        APIError({"code": "42501", "message": CRUDO}),
        APIError({"code": "XX999", "message": CRUDO}),
        ConnectionError(CRUDO),
        TimeoutError(CRUDO),
    ],
)
def test_si_el_rpc_falla_el_movimiento_sigue_siendo_201_con_la_advertencia(entorno, error, caplog):
    entorno.configurar("suspension", error=error)
    with caplog.at_level(logging.ERROR):
        r = _post("suspension")
    assert r.status_code == 201, r.text
    cuerpo = r.json()
    assert cuerpo["advertencias"] == ["baja_terminal_pendiente"]
    assert cuerpo["bajas_terminal_emitidas"] == 0
    assert cuerpo["tipo_movimiento"] == "suspension"  # el movimiento de persona ya está confirmado
    assert "5190" not in r.text and "5190" not in caplog.text  # ni respuesta ni log llevan el texto crudo
    assert any(x.levelno >= logging.ERROR and PERSONA_ID in x.getMessage() for x in caplog.records)


@pytest.mark.parametrize("resultado", [-1, None, "x", True, [], {"n": 1}, -5])
def test_resultado_menos_uno_o_inesperado_es_advertencia_no_reintento(entorno, resultado, caplog):
    """-1 = sin autor derivable. Se avisa; no se reintenta en bucle (un solo RPC por petición)."""
    entorno.configurar("baja_definitiva", resultado=resultado)
    with caplog.at_level(logging.ERROR):
        r = _post("baja_definitiva")
    assert r.status_code == 201
    assert r.json()["advertencias"] == ["baja_terminal_pendiente"]
    assert r.json()["bajas_terminal_emitidas"] == 0
    assert entorno.rpc.call_count == 1
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_los_campos_del_movimiento_siguen_igual(entorno):
    entorno.configurar("suspension", resultado=1)
    cuerpo = _post("suspension").json()
    assert cuerpo["id"] == "33333333-3333-3333-3333-333333333333"
    assert cuerpo["persona_id"] == PERSONA_ID
    assert cuerpo["registrado_por"] == AUTH_USER_ID
    assert entorno.tabla.insert.call_args[0][0]["registrado_por"] == AUTH_USER_ID


def test_el_get_de_movimientos_no_cambia_ni_toca_el_servicio():
    """Los campos nuevos tienen default: un movimiento listado sin ellos sigue siendo válido."""
    from app.schemas.movimientos import MovimientoOut

    m = MovimientoOut(
        id="x", persona_id="p", tipo_movimiento="alta", fecha_efectiva="2026-10-08T10:00:00+00:00",
        motivo=None, registrado_por=None,
    )
    assert m.advertencias == [] and m.bajas_terminal_emitidas == 0


def test_contrato_con_el_rpc_del_83():
    """Firma real de fn_terminal_baja_por_persona_inactiva(p_persona_id uuid) RETURNS integer y su EXECUTE."""
    import re
    from pathlib import Path

    archivos = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/83_*.sql"))
    assert archivos
    sql = archivos[0].read_text(encoding="utf-8")
    assert re.search(r"CREATE FUNCTION tiempo\.fn_terminal_baja_por_persona_inactiva\(p_persona_id uuid\)\s+RETURNS integer", sql)
    assert re.search(
        r"GRANT EXECUTE ON FUNCTION tiempo\.fn_terminal_baja_por_persona_inactiva\(uuid\)\s+TO service_role", sql
    )
    assert "RETURN -1" in sql  # el caso «sin autor derivable» que el backend trata como advertencia


# --- ajustes de revisión ------------------------------------------------------------------------------------------


def test_get_real_de_movimientos_no_toca_el_servicio_y_trae_defaults(entorno):
    """El GET responde con los defaults de los campos nuevos y no construye ni usa service_role."""
    filas = [
        {"id": "m1", "persona_id": PERSONA_ID, "tipo_movimiento": "alta", "fecha_efectiva": "2026-10-08T10:00:00+00:00",
         "motivo": None, "documento_ref": None, "registrado_por": None},
        {"id": "m2", "persona_id": PERSONA_ID, "tipo_movimiento": "suspension", "fecha_efectiva": "2026-10-08T11:00:00+00:00",
         "motivo": "x", "documento_ref": None, "registrado_por": None},
    ]
    caller_db = db_por_nombre(bitacora_movimiento_persona=tabla(filas), usuario=tabla([]))

    def servicio_prohibido():
        raise AssertionError("el GET no debe construir service_role")

    app.dependency_overrides[get_caller_client] = lambda: caller_db
    app.dependency_overrides[get_service_client] = servicio_prohibido
    r = TestClient(app, raise_server_exceptions=False).get(f"/api/personas/{PERSONA_ID}/movimientos", headers=AUTH)
    assert r.status_code == 200, r.text
    assert len(r.json()) == 2
    for item in r.json():
        assert item["advertencias"] == [] and item["bajas_terminal_emitidas"] == 0


def test_resultado_entero_grande_se_acepta_tal_cual(entorno):
    entorno.configurar("suspension", resultado=2**31)
    cuerpo = _post("suspension").json()
    assert cuerpo["advertencias"] == [] and cuerpo["bajas_terminal_emitidas"] == 2**31


def test_resultado_float_se_trata_como_inesperado_integer_estricto(entorno, caplog):
    """El DDL dice RETURNS integer: un 2.0 no es contrato; se avisa en vez de aceptarlo en silencio."""
    entorno.configurar("suspension", resultado=2.0)
    with caplog.at_level(logging.ERROR):
        cuerpo = _post("suspension").json()
    assert cuerpo["advertencias"] == ["baja_terminal_pendiente"] and cuerpo["bajas_terminal_emitidas"] == 0
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_todo_tipo_que_deja_a_la_persona_fuera_de_activo_da_de_baja_en_terminales():
    """Contrato con el DDL: si un tipo nuevo del CHECK deja a la persona inactiva, debe estar en el hook."""
    import re
    from pathlib import Path

    from app.routers.movimientos import TIPOS_QUE_DAN_DE_BAJA_EN_TERMINALES

    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    sql = (ddl / "05_personas_estructura.sql").read_text(encoding="utf-8")
    tipos = set(re.findall(r"'([a-z_]+)'", re.search(r"CHECK \(tipo_movimiento IN \(([^)]*)\)", sql).group(1)))
    assert tipos >= {"alta", "suspension", "reactivacion", "baja_definitiva"}
    deja_activo = {"alta", "reactivacion"}  # los que dejan/ponen a la persona en 'activo'
    assert set(TIPOS_QUE_DAN_DE_BAJA_EN_TERMINALES) == tipos - deja_activo


def test_sin_permiso_es_403_aunque_service_role_no_pueda_construirse(entorno):
    entorno.configurar("suspension")
    entorno.permitido = False

    def servicio_roto():
        raise RuntimeError("no se puede construir service_role")

    app.dependency_overrides[get_service_client] = servicio_roto
    assert _post("suspension").status_code == 403
