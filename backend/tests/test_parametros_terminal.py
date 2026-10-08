"""C0 del contrato de Terminales (Paquete 2): las claves terminal_* (89_*.sql) conviven en
tiempo.parametro con las 8 del catálogo, pero NO se muestran ni se editan desde la pantalla genérica
de Parámetros. Sin el filtro, la primera fila terminal_* sembrada hacía reventar GET /api/parametros
(KeyError -> 500). Mocks del cliente de Supabase -- NUNCA contra la base real."""

import logging
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
CRUDO = "texto-crudo-id-interno-8841"

FILA_CATALOGO = {"clave": "tolerancia_retardo_min", "valor": "15", "vigente_desde": "2026-01-01"}
FILAS_TERMINAL = [
    {"clave": "terminal_caducidad_alta_horas", "valor": "24", "vigente_desde": "2026-01-01"},
    {"clave": "terminal_retencion_rechazos_dias", "valor": "90", "vigente_desde": "2026-01-01"},
]


@pytest.fixture
def autorizar(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona, *codigos: True)
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona, codigo: True)
    app.dependency_overrides[get_caller_client] = lambda: MagicMock()
    app.dependency_overrides[get_caller_identity] = lambda: CALLER


def _servicio(filas=(), historial=(), rpc_error=None, rpc_data=None, usuarios=()):
    """tiempo.parametro y personas.usuario por separado (el historial resuelve autores en la segunda)."""
    servicio = MagicMock()
    tabla = MagicMock()
    tabla.select.return_value.is_.return_value.execute.return_value.data = list(filas)
    tabla.select.return_value.order.return_value.execute.return_value.data = [dict(f) for f in historial]
    tabla_usuario = MagicMock()
    tabla_usuario.select.return_value.in_.return_value.execute.return_value.data = list(usuarios)

    def esquema(nombre):
        espacio = MagicMock()
        espacio.table.return_value = tabla_usuario if nombre == "personas" else tabla
        espacio.rpc = servicio.rpc
        return espacio

    servicio.postgrest.schema.side_effect = esquema
    rpc = servicio.rpc
    if rpc_error is not None:
        rpc.return_value.execute.side_effect = rpc_error
    else:
        rpc.return_value.execute.return_value.data = rpc_data
    servicio.tabla_parametro = tabla
    servicio.tabla_usuario = tabla_usuario
    app.dependency_overrides[get_service_client] = lambda: servicio
    return servicio


def _cliente():
    return TestClient(app, raise_server_exceptions=False)


def test_el_listado_ignora_las_claves_terminal_sin_reventar(autorizar):
    _servicio(filas=[FILA_CATALOGO, *FILAS_TERMINAL])
    r = _cliente().get("/api/parametros", headers=AUTH)
    assert r.status_code == 200, r.text
    assert [f["clave"] for f in r.json()] == ["tolerancia_retardo_min"]


def test_el_listado_ignora_cualquier_clave_fuera_del_catalogo(autorizar):
    _servicio(filas=[FILA_CATALOGO, {"clave": "clave_rara", "valor": "1", "vigente_desde": "2026-01-01"}])
    r = _cliente().get("/api/parametros", headers=AUTH)
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_el_historial_ignora_las_claves_terminal_sin_reventar(autorizar):
    historial = [
        {"id": 1, **FILA_CATALOGO, "vigente_hasta": None, "registrado_por": None},
        {"id": 2, **FILAS_TERMINAL[0], "vigente_hasta": None, "registrado_por": None},
    ]
    _servicio(historial=historial)
    r = _cliente().get("/api/parametros/historial", headers=AUTH)
    assert r.status_code == 200, r.text
    assert [f["clave"] for f in r.json()] == ["tolerancia_retardo_min"]


@pytest.mark.parametrize("clave", ["terminal_caducidad_alta_horas", "terminal_llave_max_meses", "terminal_inventada"])
def test_editar_una_clave_terminal_da_403_fijo_sin_validar_ni_llamar_al_rpc(autorizar, clave):
    servicio = _servicio()
    r = _cliente().put(f"/api/parametros/{clave}", json={"valor": "48"}, headers=AUTH)
    assert r.status_code == 403
    assert r.json()["detail"] == "Esa variable se edita desde Terminales → Configuración."
    servicio.rpc.assert_not_called()


def test_editar_una_clave_terminal_con_valor_invalido_sigue_siendo_403_no_422(autorizar):
    r = _cliente().put("/api/parametros/terminal_caducidad_alta_horas", json={"valor": "no-es-numero"}, headers=AUTH)
    assert r.status_code == 403


def test_scj17_de_la_base_se_traduce_a_403_fijo(autorizar):
    """Red de seguridad: el guard SQL de 89_ en fn_parametro_actualizar_valor."""
    _servicio(rpc_error=APIError({"code": "SCJ17", "hint": "clave_reservada", "message": CRUDO}))
    r = _cliente().put("/api/parametros/tolerancia_retardo_min", json={"valor": "20"}, headers=AUTH)
    assert r.status_code == 403
    assert r.json()["detail"] == "Esa variable se edita desde Terminales → Configuración."
    assert "8841" not in r.text


def test_un_error_desconocido_de_la_base_da_422_fijo_con_log_sin_texto_crudo(autorizar, caplog):
    _servicio(rpc_error=APIError({"code": "XX999", "hint": "h\ninyectado", "message": CRUDO}))
    with caplog.at_level(logging.ERROR):
        r = _cliente().put("/api/parametros/tolerancia_retardo_min", json={"valor": "20"}, headers=AUTH)
    assert r.status_code == 422
    assert r.json()["detail"] == "No se pudo actualizar el parámetro."
    assert "8841" not in r.text
    mensaje = [x.getMessage() for x in caplog.records if "parámetro rechazado" in x.getMessage()]
    assert mensaje and "XX999" in mensaje[0] and "\n" not in mensaje[0]
    assert "8841" not in caplog.text  # el log lleva código y hint, no el mensaje crudo


def test_scj02_sigue_siendo_404(autorizar):
    _servicio(rpc_error=APIError({"code": "SCJ02", "message": "x"}))
    r = _cliente().put("/api/parametros/tolerancia_retardo_min", json={"valor": "20"}, headers=AUTH)
    assert r.status_code == 404
    assert r.json()["detail"] == "No existe un parámetro activo con esa clave."


def test_el_caso_feliz_no_cambia_y_manda_al_rpc_clave_valor_y_autor(autorizar):
    servicio = _servicio(rpc_data={"clave": "tolerancia_retardo_min", "valor": "20", "vigente_desde": "2026-10-08"})
    r = _cliente().put("/api/parametros/tolerancia_retardo_min", json={"valor": "20"}, headers=AUTH)
    assert r.status_code == 200
    assert r.json()["valor"] == "20"
    nombre, parametros = servicio.rpc.call_args.args
    assert nombre == "fn_parametro_actualizar_valor"
    assert parametros == {
        "p_clave": "tolerancia_retardo_min",
        "p_valor": "20",
        "p_registrado_por": CALLER.auth_user_id,
    }


def test_una_clave_desconocida_no_terminal_conserva_su_422(autorizar):
    _servicio()
    r = _cliente().put("/api/parametros/clave_que_no_existe", json={"valor": "1"}, headers=AUTH)
    assert r.status_code == 422


# --- ajustes de la revisión de testing de C0 ---------------------------------------------------------------------


def test_listado_con_solo_filas_terminal_da_200_y_lista_vacia(autorizar):
    _servicio(filas=FILAS_TERMINAL)
    r = _cliente().get("/api/parametros", headers=AUTH)
    assert r.status_code == 200
    assert r.json() == []


def test_historial_con_solo_filas_terminal_da_200_y_lista_vacia_sin_consultar_autores(autorizar):
    historial = [{"id": 9, **FILAS_TERMINAL[0], "vigente_hasta": None, "registrado_por": "auth-b"}]
    servicio = _servicio(historial=historial)
    r = _cliente().get("/api/parametros/historial", headers=AUTH)
    assert r.status_code == 200
    assert r.json() == []
    servicio.tabla_usuario.select.assert_not_called()


def test_historial_mixto_solo_resuelve_autores_de_filas_del_catalogo(autorizar):
    historial = [
        {"id": 1, **FILA_CATALOGO, "vigente_hasta": None, "registrado_por": "auth-a"},
        {"id": 2, **FILAS_TERMINAL[0], "vigente_hasta": None, "registrado_por": "auth-b"},
    ]
    servicio = _servicio(historial=historial, usuarios=[{"auth_user_id": "auth-a", "nombre_usuario": "Ana"}])
    r = _cliente().get("/api/parametros/historial", headers=AUTH)
    assert r.status_code == 200
    assert [f["clave"] for f in r.json()] == ["tolerancia_retardo_min"]
    assert r.json()[0]["nombre_registrado_por"] == "Ana"
    servicio.tabla_usuario.select.return_value.in_.assert_called_once_with("auth_user_id", ["auth-a"])


def test_sin_parametro_edicion_una_clave_terminal_da_el_403_del_gate_no_el_de_terminales(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona, *codigos: False)
    app.dependency_overrides[get_caller_client] = lambda: MagicMock()
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    servicio = _servicio()
    r = _cliente().put("/api/parametros/terminal_caducidad_alta_horas", json={"valor": "48"}, headers=AUTH)
    assert r.status_code == 403
    assert "Terminales" not in r.json()["detail"]
    assert "parametro_edicion" in r.json()["detail"]
    servicio.rpc.assert_not_called()


@pytest.mark.parametrize("clave", ["terminalx", "Terminal_caducidad_alta_horas", "TERMINAL_X", "xterminal_"])
def test_claves_parecidas_pero_no_terminal_siguen_siendo_422_no_403(autorizar, clave):
    _servicio()
    r = _cliente().put(f"/api/parametros/{clave}", json={"valor": "1"}, headers=AUTH)
    assert r.status_code == 422


def test_la_clave_desconocida_no_se_repite_en_la_respuesta(autorizar):
    _servicio()
    r = _cliente().put("/api/parametros/clave-con-id-7719", json={"valor": "1"}, headers=AUTH)
    assert r.status_code == 422
    assert "7719" not in r.text
    assert r.json()["detail"] == "clave desconocida"


def test_el_hint_largo_se_recorta_a_100_caracteres_en_el_log(autorizar, caplog):
    _servicio(rpc_error=APIError({"code": "XX999", "hint": "h" * 500, "message": CRUDO}))
    with caplog.at_level(logging.ERROR):
        _cliente().put("/api/parametros/tolerancia_retardo_min", json={"valor": "20"}, headers=AUTH)
    mensaje = [x.getMessage() for x in caplog.records if "parámetro rechazado" in x.getMessage()][0]
    assert "h" * 100 in mensaje and "h" * 101 not in mensaje


def test_contrato_con_el_guard_de_89_codigo_hint_y_prefijo():
    import re
    from pathlib import Path

    from app.routers.parametros import CODIGO_CLAVE_RESERVADA, PREFIJO_CLAVES_TERMINAL

    archivos = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/89_*.sql"))
    if not archivos:
        pytest.skip("db/ddl/89_*.sql todavía no existe")
    sql = archivos[0].read_text(encoding="utf-8")
    guard = re.search(r"IF p_clave LIKE '([^']+)' THEN\s+RAISE EXCEPTION[^;]*?ERRCODE = '(SCJ\d+)', HINT = '([a-z_]+)'", sql, re.S)
    assert guard, "el guard de fn_parametro_actualizar_valor ya no tiene la forma esperada"
    patron, errcode, hint = guard.groups()
    assert errcode == CODIGO_CLAVE_RESERVADA
    assert hint == "clave_reservada"
    assert patron == PREFIJO_CLAVES_TERMINAL.replace("_", "\\_") + "%"


@pytest.mark.parametrize(
    "ruta,estado",
    [("Terminal_x", 422), ("%74erminal_x", 403), ("terminal%5Fx", 403), ("TERMINAL_x", 422)],
)
def test_variantes_de_mayusculas_o_codificadas_nunca_llegan_al_rpc(autorizar, ruta, estado):
    """'%74' decodifica a 't': Starlette entrega 'terminal_x' al router, que lo bloquea; las variantes en
    mayúsculas no son claves del catálogo y fallan la validación. Ninguna llega al RPC."""
    servicio = _servicio()
    r = _cliente().put(f"/api/parametros/{ruta}", json={"valor": "1"}, headers=AUTH)
    assert r.status_code == estado
    servicio.rpc.assert_not_called()
