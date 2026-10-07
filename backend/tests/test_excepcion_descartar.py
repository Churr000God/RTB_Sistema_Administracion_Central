"""POST /api/excepciones/{id}/descartar (86_*.sql). Mocks del cliente de Supabase -- NUNCA contra la
base real. La autorización real es la base (RPC SECURITY DEFINER con EXECUTE sólo para
`authenticated`); aquí se verifica el contrato HTTP, que se use el cliente del CALLER y nunca
service_role, y que el texto de la base no llegue a la respuesta."""

from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

EXCEPCION_ID = 77
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
CRUDO = "texto-crudo-id-interno-5512"
AUTH = {"Authorization": "Bearer fake-token"}


@pytest.fixture
def entorno(monkeypatch):
    """Gate débil aprobado por defecto; el RPC devuelve lo que se le configure."""
    codigos_pedidos = []

    def tiene_alguno(db, persona_id, *codigos):
        codigos_pedidos.append(codigos)
        return entorno.permitido

    entorno.permitido = True
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)

    db_caller = MagicMock()
    rpc = db_caller.postgrest.schema.return_value.rpc

    def configurar(data=None, error=None):
        constructor = MagicMock()
        if error is not None:
            constructor.execute.side_effect = error
        else:
            constructor.execute.return_value.data = data
        rpc.return_value = constructor

    def service_prohibido():
        raise AssertionError("el descarte NUNCA debe usar service_role")

    app.dependency_overrides[get_caller_client] = lambda: db_caller
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    app.dependency_overrides[get_service_client] = service_prohibido
    cliente = TestClient(app, raise_server_exceptions=False)

    class Entorno:
        pass

    e = Entorno()
    e.cliente, e.db, e.rpc, e.configurar, e.codigos = cliente, db_caller, rpc, configurar, codigos_pedidos
    e.sesion = entorno
    return e


def _post(e, cuerpo=None, excepcion_id=EXCEPCION_ID):
    return e.cliente.post(
        f"/api/excepciones/{excepcion_id}/descartar",
        json={"motivo": "La marca tardía es un duplicado"} if cuerpo is None else cuerpo,
        headers=AUTH,
    )


def test_descartada_devuelve_200_con_el_resultado(entorno):
    entorno.configurar({"resultado": "descartada", "excepcion_id": EXCEPCION_ID, "dia_id": 5})
    r = _post(entorno)
    assert r.status_code == 200
    assert r.json() == {"resultado": "descartada", "excepcion_id": EXCEPCION_ID, "dia_id": 5}


def test_ya_descartada_es_idempotente_200(entorno):
    entorno.configurar({"resultado": "ya_descartada", "excepcion_id": EXCEPCION_ID})
    r = _post(entorno)
    assert r.status_code == 200
    assert r.json()["resultado"] == "ya_descartada"
    assert r.json()["dia_id"] is None


def test_no_encontrada_es_404(entorno):
    entorno.configurar({"resultado": "no_encontrada"})
    r = _post(entorno)
    assert r.status_code == 404
    assert r.json()["detail"] == "La excepción no existe."


def test_llama_al_rpc_correcto_con_el_cliente_del_caller_y_no_con_service_role(entorno):
    entorno.configurar({"resultado": "descartada", "excepcion_id": EXCEPCION_ID, "dia_id": 5})
    _post(entorno, {"motivo": "Duplicada por reloj"})
    entorno.db.postgrest.schema.assert_called_with("tiempo")
    nombre, parametros = entorno.rpc.call_args.args
    assert nombre == "fn_excepcion_dia_cerrado_descartar"
    assert parametros == {"p_excepcion_id": EXCEPCION_ID, "p_motivo": "Duplicada por reloj"}
    # service_prohibido() levantaría AssertionError (-> 500) si se hubiera usado: no pasó


def test_el_gate_debil_exige_el_permiso_de_accion_no_heredable(entorno):
    entorno.configurar({"resultado": "descartada", "excepcion_id": EXCEPCION_ID, "dia_id": 5})
    _post(entorno)
    assert entorno.codigos == [("excepcion_dia_cerrado_descarte",)]


def test_sin_el_permiso_el_gate_da_403_legible_sin_llamar_al_rpc(entorno):
    entorno.sesion.permitido = False
    r = _post(entorno)
    assert r.status_code == 403
    entorno.rpc.assert_not_called()


@pytest.mark.parametrize(
    "code,hint,estado",
    [
        ("42501", "sin_permiso", 403),
        ("22023", "motivo_invalido", 422),
        ("SCJ15", "dia_no_revisado", 409),
        ("SCJ15", "excepcion_no_descartable", 409),
        ("SCJ15", "dia_cerrado_requiere_revision", 409),
    ],
)
def test_los_errores_del_rpc_se_traducen_sin_el_texto_de_la_base(entorno, code, hint, estado):
    entorno.configurar(error=APIError({"code": code, "hint": hint, "message": CRUDO}))
    r = _post(entorno)
    assert r.status_code == estado
    assert "5512" not in r.text and "texto-crudo" not in r.text


def test_un_error_desconocido_de_la_base_es_500_generico_sin_texto(entorno):
    entorno.configurar(error=APIError({"code": "XX999", "message": CRUDO}))
    r = _post(entorno)
    assert r.status_code == 500
    assert "5512" not in r.text
    assert r.json() == {"detail": "Error interno del servidor."}


@pytest.mark.parametrize(
    "cuerpo",
    [{}, {"motivo": ""}, {"motivo": "x" * 501}, {"motivo": 5}, {"otro": "campo"}],
)
def test_cuerpo_invalido_da_422_sin_llamar_al_rpc(entorno, cuerpo):
    r = _post(entorno, cuerpo)
    assert r.status_code == 422
    entorno.rpc.assert_not_called()


def test_motivo_de_500_caracteres_es_valido(entorno):
    entorno.configurar({"resultado": "descartada", "excepcion_id": EXCEPCION_ID, "dia_id": 5})
    assert _post(entorno, {"motivo": "x" * 500}).status_code == 200


def test_motivo_de_solo_espacios_lo_rechaza_la_base_con_422(entorno):
    entorno.configurar(error=APIError({"code": "22023", "hint": "motivo_invalido", "message": CRUDO}))
    r = _post(entorno, {"motivo": "   "})
    assert r.status_code == 422
    assert "5512" not in r.text


@pytest.mark.parametrize("forma", [None, {}, {"resultado": "raro"}, [], "texto", {"excepcion_id": 1}])
def test_respuesta_del_rpc_con_forma_inesperada_da_503(entorno, forma):
    entorno.configurar(forma)
    r = _post(entorno)
    assert r.status_code == 503
    assert r.json()["detail"] == "Servicio no disponible; reintenta."


def test_el_id_de_la_ruta_debe_ser_entero(entorno):
    r = entorno.cliente.post("/api/excepciones/abc/descartar", json={"motivo": "x"}, headers=AUTH)
    assert r.status_code == 422
    entorno.rpc.assert_not_called()
