"""CONTRATO_API_PUENTE_TERMINAL.md §2-§3: GET /api/terminal/cola y /mapa. Mocks con la firma real de `.rpc(...)`."""

import logging
import re
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, rpc_con_firma_real
from app.config import Settings, get_settings
from app.deps import get_service_client
from app.main import app

LLAVE = "scjt_" + "D" * 43
AUTENTICADA = {"terminal_id": 7, "serie": "TERM-FICTICIA-01", "credencial_id": 3, "ip_cambio": False}
CRUDO = "texto-crudo-id-interno-6642"


def _alta(id_, emp, estado, huellas=0):
    return {"terminal_usuario_id": id_, "employee_no": emp, "estado": estado, "huellas_capturadas": huellas}


MAPA = [
    _alta(80, 1001, "activo", 2),
    _alta(77, 1042, "pendiente_alta"),
    _alta(78, 1043, "esperando_huella"),
    _alta(79, 1010, "pendiente_baja", 2),
]


class Entorno:
    def __init__(self, mapa=MAPA, error=None, base="https://testserver"):
        self.db = MagicMock()
        self.rpc = rpc_con_firma_real()
        self.db.postgrest.schema.return_value.rpc = self.rpc

        def segun(nombre, params):
            r = MagicMock()
            if nombre == "fn_terminal_autenticar":
                r.execute.return_value = Resultado(AUTENTICADA)
            elif error is not None:
                r.execute.side_effect = error
            else:
                r.execute.return_value = Resultado(mapa)
            return r

        self.rpc.side_effect = segun
        app.dependency_overrides[get_service_client] = lambda: self.db
        app.dependency_overrides[get_settings] = lambda: Settings(
            supabase_url="http://x.invalido", supabase_anon_key="a", supabase_service_role_key="s"
        )
        self.cliente = TestClient(app, base_url=base, client=("198.51.100.7", 1), raise_server_exceptions=False)

    def get(self, ruta, llave=LLAVE):
        return self.cliente.get(ruta, headers={"Authorization": f"Bearer {llave}"} if llave else {})

    def llamadas(self):
        return [c.args for c in self.rpc.call_args_list if c.args[0] == "fn_terminal_mapa"]


# --- cola ---------------------------------------------------------------------------------------------------------------------


def test_la_cola_solo_trae_el_trabajo_pendiente_con_su_accion_y_ordenado():
    e = Entorno()
    r = e.get("/api/terminal/cola")
    assert r.status_code == 200, r.text
    assert [(a["employee_no"], a["estado"], a["accion"]) for a in r.json()["altas"]] == [
        (1010, "pendiente_baja", "borrar_usuario"),
        (1042, "pendiente_alta", "crear_usuario"),
        (1043, "esperando_huella", "sondear_huellas"),
    ]
    assert r.json()["hora_servidor"]
    assert all(set(a) == {"terminal_usuario_id", "employee_no", "estado", "huellas_capturadas", "accion"} for a in r.json()["altas"])


def test_la_cola_vacia_es_una_lista_vacia():
    assert Entorno(mapa=[]).get("/api/terminal/cola").json()["altas"] == []
    assert Entorno(mapa=[_alta(1, 1000, "activo", 1)]).get("/api/terminal/cola").json()["altas"] == []


# --- mapa ---------------------------------------------------------------------------------------------------------------------


def test_el_mapa_trae_todas_las_altas_no_baja_con_accion_nula_para_las_activas():
    r = Entorno().get("/api/terminal/mapa")
    assert r.status_code == 200
    por_emp = {a["employee_no"]: a for a in r.json()["altas"]}
    assert set(por_emp) == {1001, 1010, 1042, 1043}
    assert por_emp[1001]["accion"] is None and por_emp[1001]["huellas_capturadas"] == 2
    assert por_emp[1010]["accion"] == "borrar_usuario"
    assert [a["employee_no"] for a in r.json()["altas"]] == sorted(por_emp)


# --- comunes -----------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("ruta", ["/api/terminal/cola", "/api/terminal/mapa"])
class TestComunes:
    def test_llama_al_rpc_con_el_id_de_la_credencial_y_nada_mas(self, ruta):
        e = Entorno()
        e.get(ruta)
        assert e.llamadas() == [("fn_terminal_mapa", {"p_terminal_id": 7})]

    def test_sin_credencial_o_con_una_mala_es_401_y_no_consulta_el_mapa(self, ruta):
        e = Entorno()
        assert e.get(ruta, llave=None).status_code == 401
        assert e.get(ruta, llave="mala").status_code == 401
        assert e.llamadas() == []

    def test_sin_https_es_403(self, ruta):
        e = Entorno(base="http://testserver")
        assert e.get(ruta).status_code == 403 and e.llamadas() == []

    def test_lleva_no_store_y_hsts(self, ruta):
        r = Entorno().get(ruta)
        assert r.headers["cache-control"] == "no-store" and "strict-transport-security" in r.headers

    def test_no_acepta_otro_metodo(self, ruta):
        assert Entorno().cliente.post(ruta, headers={"Authorization": f"Bearer {LLAVE}"}, json={}).status_code == 405

    @pytest.mark.parametrize(
        "mapa",
        [
            None, {}, "x", 5,
            [_alta(1, 1000, "activo") | {"persona_id": "uuid-secreto"}],           # fuga de identidad: NO se reenvía
            [_alta(1, 1000, "activo") | {"nombre": "Ana Torres"}],
            [_alta(1, 1000, "activo") | {"persona_activa": True}],
            [_alta(1, 1000, "baja")],                                              # baja no existe en el vocabulario del Pi
            [_alta(1, 1000, "inventado")],
            [{"terminal_usuario_id": 1, "employee_no": 1000, "estado": "activo"}],  # falta huellas_capturadas
            [_alta(0, 1000, "activo")],
            [_alta(1, 0, "activo")],
            [_alta(1, 100_000_000, "activo")],
            [_alta(1, 1000, "activo", huellas=11)],
            [_alta(1, 1000, "activo", huellas=-1)],
            [_alta(True, 1000, "activo")], [_alta(1, True, "activo")],                  # bool NO es entero
            [_alta("1", 1000, "activo")], [_alta(1, "1000", "activo")],                # cadena NO es entero
            [_alta(1.0, 1000, "activo")], [_alta(1, 1000.0, "activo")],                # float NO es entero
            [_alta(1, 1000, "activo", huellas=2.0)], [_alta(1, 1000, "activo", huellas="2")],
            [_alta(1, 1000, "activo", huellas=True)],
            ["x"], [None], [[1, 2]],
        ],
    )
    def test_una_respuesta_rara_del_rpc_es_503_y_nunca_se_reenvia(self, ruta, mapa, caplog):
        with caplog.at_level(logging.ERROR):
            r = Entorno(mapa=mapa).get(ruta)
        assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible; reintenta."}
        assert "uuid-secreto" not in r.text and "Ana" not in r.text
        assert any(x.levelno >= logging.ERROR for x in caplog.records)

    @pytest.mark.parametrize(
        "error,estado",
        [
            (APIError({"code": "SCJ12", "hint": "terminal_no_valida", "message": CRUDO}), 401),
            (APIError({"code": "22023", "message": CRUDO}), 422),
            (APIError({"code": "42501", "message": CRUDO}), 503),
            (APIError({"code": "PGRST202", "message": CRUDO}), 503),
            (APIError({"code": "XX999", "message": CRUDO}), 500),
            (ConnectionError(CRUDO), 503),
            (TimeoutError(CRUDO), 503),
        ],
    )
    def test_errores_con_estado_fijo_y_sin_texto_de_la_base(self, ruta, error, estado):
        r = Entorno(error=error).get(ruta)
        assert r.status_code == estado and "6642" not in r.text


def test_la_misma_alta_no_aparece_dos_veces_ni_se_inventan_filas():
    r = Entorno().get("/api/terminal/mapa")
    ids = [a["terminal_usuario_id"] for a in r.json()["altas"]]
    assert len(ids) == len(set(ids)) == 4


# --- contrato con el DDL --------------------------------------------------------------------------------------------------------------


def _sql83():
    return next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob("83_*.sql")).read_text(encoding="utf-8")


def test_firma_y_claves_del_mapa_coinciden_con_83():
    sql = _sql83()
    assert "fn_terminal_mapa(p_terminal_id bigint)" in sql and "fn_terminal_mapa(bigint) TO service_role" in sql
    bloque = re.search(r"fn_terminal_mapa\(p_terminal_id bigint\).*?\$\$;", sql, re.S).group(0)
    claves = set(re.findall(r"'([a-z_]+)',\s+tu\.", bloque))
    assert claves == {"terminal_usuario_id", "employee_no", "estado", "huellas_capturadas"}
    assert "persona_id" not in bloque.split("jsonb_build_object")[1].split("ORDER BY")[0]
    assert "tu.estado <> 'baja'" in bloque


def test_las_acciones_cubren_exactamente_los_estados_con_trabajo():
    from app.schemas.terminal import ACCION_POR_ESTADO

    assert ACCION_POR_ESTADO == {
        "pendiente_alta": "crear_usuario", "esperando_huella": "sondear_huellas", "pendiente_baja": "borrar_usuario"}
