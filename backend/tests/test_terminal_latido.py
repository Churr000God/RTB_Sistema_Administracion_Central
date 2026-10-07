"""SCJ-DEC-12 §3 (corte 1): POST /api/terminal/latido -- cuerpo validado, RPC
`tiempo.fn_terminal_latido(p_terminal_id, …)` con el id de la CREDENCIAL (nunca del cuerpo), y
mapeo de errores sin retransmitir texto de la base. Mocks del cliente de Supabase."""

import logging
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import terminal_auth
from app.config import Settings, get_settings
from app.deps import get_service_client
from app.errores import manejar_error_terminal
from app.main import app

LLAVE = "scjt_" + "B" * 43
SERIE = "TERM-FICTICIA-01"
AUTENTICADA = {"terminal_id": 7, "serie": SERIE, "credencial_id": 3, "ip_cambio": False}
LATIDO_OK = {
    "hora_servidor": "2026-10-06T15:00:00.123456+00:00",
    "desfase_reloj_seg": -4,
    "ultima_secuencia_recibida": 4419,
}


def _settings() -> Settings:
    return Settings(
        supabase_url="http://supabase.invalido",
        supabase_anon_key="anon-ficticia",
        supabase_service_role_key="service-ficticia",
    )


def _db(latido=LATIDO_OK, error_latido=None):
    db = MagicMock()

    def rpc(nombre, params=None):
        constructor = MagicMock()
        if nombre == "fn_terminal_autenticar":
            constructor.execute.return_value.data = AUTENTICADA
        elif error_latido is not None:
            constructor.execute.side_effect = error_latido
        else:
            constructor.execute.return_value.data = latido
        return constructor

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    return db


def _cliente(db):
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = _settings
    return TestClient(
        app, base_url="https://testserver", client=("198.51.100.7", 1), raise_server_exceptions=False
    )


def _post(cliente, cuerpo):
    return cliente.post(
        "/api/terminal/latido", json=cuerpo, headers={"Authorization": f"Bearer {LLAVE}"}
    )


def _params_latido(db):
    llamadas = db.postgrest.schema.return_value.rpc.call_args_list
    return [c for c in llamadas if c.args[0] == "fn_terminal_latido"][0].args[1]


def test_latido_completo_pasa_los_parametros_al_rpc_y_devuelve_el_resultado():
    db = _db()
    r = _post(
        _cliente(db),
        {
            "terminal_id": SERIE,
            "hora_terminal": "2026-10-06T15:00:04Z",
            "terminal_alcanzable": True,
            "reloj_sincronizado": False,
            "version_pi": "1.0.0",
            "marcas_pendientes": 12,
        },
    )
    assert r.status_code == 200
    assert r.json() == {
        "hora_servidor": "2026-10-06T15:00:00.123456Z",
        "desfase_reloj_seg": -4,
        "ultima_secuencia_recibida": 4419,
    }
    p = _params_latido(db)
    assert p["p_terminal_id"] == 7
    assert p["p_alcanzable"] is True
    assert p["p_reloj_sincronizado"] is False
    assert p["p_version_pi"] == "1.0.0"
    assert p["p_marcas_pendientes"] == 12
    assert p["p_hora_terminal"].startswith("2026-10-06T15:00:04")


def test_latido_con_cuerpo_vacio_manda_nulos():
    db = _db(latido={**LATIDO_OK, "desfase_reloj_seg": None})
    r = _post(_cliente(db), {})
    assert r.status_code == 200
    assert r.json()["desfase_reloj_seg"] is None
    p = _params_latido(db)
    assert p == {
        "p_terminal_id": 7,
        "p_hora_terminal": None,
        "p_alcanzable": None,
        "p_reloj_sincronizado": None,
        "p_version_pi": None,
        "p_marcas_pendientes": None,
    }


def test_el_id_de_terminal_sale_de_la_credencial_no_del_cuerpo():
    db = _db()
    _post(_cliente(db), {"terminal_id": SERIE})
    assert _params_latido(db)["p_terminal_id"] == 7


def test_terminal_id_del_cuerpo_que_no_coincide_con_la_credencial_da_403_sin_llamar_al_rpc():
    db = _db()
    r = _post(_cliente(db), {"terminal_id": "OTRA-TERMINAL"})
    assert r.status_code == 403
    assert r.json()["detail"] == "La credencial no corresponde a esa terminal."
    nombres = [c.args[0] for c in db.postgrest.schema.return_value.rpc.call_args_list]
    assert "fn_terminal_latido" not in nombres


@pytest.mark.parametrize(
    "cuerpo",
    [
        {"version_pi": "x" * 17},
        {"marcas_pendientes": -1},
        {"marcas_pendientes": 10**9},
        {"marcas_pendientes": "muchas"},
        {"hora_terminal": "2026-10-06T15:00:00"},  # sin zona horaria
        {"hora_terminal": "no-es-fecha"},
        {"terminal_alcanzable": "quizá"},
        {"terminal_id": "x" * 33},
        {"campo_inventado": 1},
        {"persona_id": "no debe viajar"},
    ],
)
def test_cuerpo_invalido_da_422_sin_llamar_al_rpc(cuerpo):
    db = _db()
    r = _post(_cliente(db), cuerpo)
    assert r.status_code == 422
    nombres = [c.args[0] for c in db.postgrest.schema.return_value.rpc.call_args_list]
    assert "fn_terminal_latido" not in nombres


def test_cuerpo_demasiado_grande_se_rechaza_por_max_length():
    r = _post(_cliente(_db()), {"version_pi": "x" * 5000})
    assert r.status_code == 422


# --- mapeo de errores ----------------------------------------------------------------------------


def test_terminal_no_valida_a_mitad_de_camino_da_401_sin_texto_crudo():
    error = APIError(
        {
            "code": "SCJ12",
            "hint": "terminal_no_valida",
            "message": "La terminal 7 no existe o no está activa (id-interno-9999)",
        }
    )
    r = _post(_cliente(_db(error_latido=error)), {})
    assert r.status_code == 401
    assert "9999" not in r.text and "id-interno" not in r.text
    assert r.json()["detail"] == "Credencial de terminal inválida."


def test_42501_en_el_latido_da_503_generico_y_siempre_log_error(caplog):
    error = APIError({"code": "42501", "message": "permission denied for table secreta-123"})
    with caplog.at_level(logging.DEBUG):
        r = _post(_cliente(_db(error_latido=error)), {})
    assert r.status_code == 503
    assert "secreta-123" not in r.text
    assert any(x.levelno >= logging.ERROR and "42501" in x.getMessage() for x in caplog.records)


def test_dato_invalido_de_la_base_clase_22_da_422_generico():
    error = APIError({"code": "22003", "message": "integer out of range para 4444"})
    r = _post(_cliente(_db(error_latido=error)), {})
    assert r.status_code == 422
    assert "4444" not in r.text


def test_error_desconocido_de_la_base_cae_al_500_generico_sin_texto():
    error = APIError({"code": "XX999", "message": "interno-con-ids-777"})
    r = _post(_cliente(_db(error_latido=error)), {})
    assert r.status_code == 500
    assert "777" not in r.text
    assert r.json() == {"detail": "Error interno del servidor."}


# --- el helper de errores.py -----------------------------------------------------------------------


@pytest.mark.parametrize(
    "codigo,hint,esperado",
    [
        ("SCJ12", "terminal_no_valida", 401),
        ("42501", None, 503),
        ("22003", None, 422),
        ("22P02", None, 422),
    ],
)
def test_manejar_error_terminal_traduce_codigos_conocidos(codigo, hint, esperado):
    from fastapi import HTTPException

    error = APIError({"code": codigo, "hint": hint, "message": "texto-crudo-no-retransmitir"})
    with pytest.raises(HTTPException) as excinfo:
        manejar_error_terminal(error)
    assert excinfo.value.status_code == esperado
    assert "texto-crudo-no-retransmitir" not in str(excinfo.value.detail)


@pytest.mark.parametrize(
    "codigo,hint",
    [("SCJ12", "otro_hint"), ("SCJ11", "transicion_invalida"), ("XX000", None), (None, None)],
)
def test_manejar_error_terminal_relanza_lo_no_reconocido(codigo, hint):
    error = APIError({"code": codigo, "hint": hint, "message": "m"})
    with pytest.raises(APIError):
        manejar_error_terminal(error)


# --- 500/503 del latido ----------------------------------------------------------------------------------


def test_el_500_de_un_error_desconocido_lleva_hsts():
    error = APIError({"code": "XX999", "message": "interno"})
    r = _post(_cliente(_db(error_latido=error)), {})
    assert r.status_code == 500
    assert r.headers["Strict-Transport-Security"] == "max-age=31536000"


@pytest.mark.parametrize("forma", [None, {}, {"hora_servidor": "2026-10-06T15:00:00+00:00"}, [], "texto"])
def test_respuesta_del_rpc_con_forma_inesperada_da_503(forma):
    r = _post(_cliente(_db(latido=forma)), {})
    assert r.status_code == 503
    assert r.json()["detail"] == "Servicio no disponible; reintenta."
    assert r.headers["Strict-Transport-Security"] == "max-age=31536000"


def test_error_de_red_hacia_supabase_en_el_latido_da_503_sin_texto(caplog):
    with caplog.at_level(logging.ERROR):
        r = _post(_cliente(_db(error_latido=ConnectionError("timeout con secreto-red-55"))), {})
    assert r.status_code == 503
    assert "secreto-red-55" not in r.text
    assert "secreto-red-55" not in caplog.text
    assert any(x.levelno == logging.ERROR for x in caplog.records)
