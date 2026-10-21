"""125_*.sql: descarte AUDITADO de alertas de horario (fuera_de_horario) en días cerrados o revisados. Endpoint POST /api/excepciones/{id}/descartar-alerta-horario, mapeo por HINT de SCJ28 y 42501,
y el flag `puede_descartar_alerta_horario` de GET /api/marcas. Mocks del cliente de Supabase: NUNCA contra la base real."""

import re
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import errores, permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers import marcas as router_marcas

from _mocks_supabase import db_por_nombre as _db  # noqa: E402
from _mocks_supabase import tabla as _tabla  # noqa: E402

CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
AUTH = {"Authorization": "Bearer fake-token"}
PERSONA_AJENA = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_CALLER = "cccccccc-0000-0000-0000-000000000009"
CRUDO = "texto-crudo-id-interno-3377"
URL = "/api/excepciones/7/descartar-alerta-horario"
MOTIVO = "Marca válida: llegó antes por una junta autorizada."
SQL_125 = sorted((Path(__file__).resolve().parents[2] / "db" / "ddl").glob("125_*.sql"))


@pytest.fixture(autouse=True)
def _limpiar():
    yield
    app.dependency_overrides.clear()


@pytest.fixture
def permitir(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-gate")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona_id, *codigos: True)
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona_id, codigo: True)


def _cliente(db):
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    return TestClient(app, raise_server_exceptions=False)


def _scj28(hint):
    return APIError({"code": "SCJ28", "hint": hint, "message": CRUDO, "details": CRUDO})


# --- mapeo de cada hint ----------------------------------------------------------------------------------------------------------------------------

ESPERADO = {
    "motivo_obligatorio": (422, "El motivo es obligatorio."),
    "motivo_corto": (422, "El motivo es demasiado corto: escribe al menos 10 caracteres."),
    "motivo_largo": (422, "El motivo es demasiado largo: máximo 500 caracteres."),
    "excepcion_inexistente": (404, "La excepción no existe."),
    "no_es_alerta_de_horario": (409, "Esta excepción no es una alerta de horario."),
    "ya_resuelta": (409, "Esta alerta ya fue resuelta."),
    "dia_no_cerrado": (409, "El día de la marca no está cerrado ni revisado: corrige la marca o revisa el día."),
    "alerta_propia": (403, "No puedes descartar la alerta de tu propia marca."),
}


@pytest.mark.parametrize("hint,esperado", list(ESPERADO.items()))
def test_cada_hint_de_scj28_se_traduce_a_su_estado_y_mensaje_fijo_sin_texto_de_la_base(permitir, hint, esperado):
    db = _db()
    db.postgrest.schema.return_value.rpc.side_effect = None
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = _scj28(hint)
    r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
    assert (r.status_code, r.json()["detail"]) == esperado
    assert "3377" not in r.text


def test_scj28_con_hint_desconocido_o_sin_hint_da_409_generico_fijo(permitir):
    for hint in ("hint_nuevo", None):
        db = _db()
        db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = _scj28(hint)
        r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
        assert r.status_code == 409 and r.json()["detail"] == errores.MENSAJE_ALERTA_HORARIO_GENERICO and "3377" not in r.text


def test_42501_sin_permiso_es_403_con_el_mensaje_de_sin_permiso(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError({"code": "42501", "hint": "sin_permiso", "message": CRUDO})
    r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
    assert r.status_code == 403 and r.json()["detail"] == errores.MENSAJE_SIN_PERMISO and "3377" not in r.text


def test_el_hint_de_scj28_no_se_confunde_con_otro_sqlstate():
    assert errores.traducir_error_alerta_horario(APIError({"code": "SCJ15", "hint": "alerta_propia", "message": "x"})) is None
    assert errores.traducir_error_alerta_horario(APIError({"code": "23505", "hint": "ya_resuelta", "message": "x"})) is None


def test_otro_error_de_la_base_se_relanza_al_manejador_global_sin_texto(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError({"code": "XX000", "message": CRUDO})
    r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
    assert r.status_code == 500 and "3377" not in r.text


# --- camino feliz y body ---------------------------------------------------------------------------------------------------------------------------


def test_camino_feliz_llama_a_la_rpc_con_argumentos_nombrados_y_el_motivo_recortado(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 41
    r = _cliente(db).post(URL, json={"motivo": f"   {MOTIVO}   "}, headers=AUTH)
    assert r.status_code == 200 and r.json() == {"auditoria_id": 41, "excepcion_id": 7}
    db.postgrest.schema.assert_called_with("tiempo")
    db.postgrest.schema.return_value.rpc.assert_called_once_with("fn_excepcion_horario_descartar", {"p_excepcion_id": 7, "p_motivo": MOTIVO})


@pytest.mark.parametrize("cuerpo", [{}, {"motivo": ""}, {"motivo": "corto"}, {"motivo": "   123456789   "}, {"motivo": "x" * 501}, {"motivo": None}, {"motivo": 12345678901}, {"otro": MOTIVO}])
def test_un_body_invalido_da_422_sin_llamar_a_la_base(permitir, cuerpo):
    db = _db()
    r = _cliente(db).post(URL, json=cuerpo, headers=AUTH)
    assert r.status_code == 422
    db.postgrest.schema.return_value.rpc.assert_not_called()


@pytest.mark.parametrize("motivo", ["x" * 10, "x" * 500, f" {'y' * 10} "])
def test_los_limites_10_y_500_del_motivo_se_aceptan(permitir, motivo):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 1
    assert _cliente(db).post(URL, json={"motivo": motivo}, headers=AUTH).status_code == 200


def test_una_respuesta_inesperada_de_la_rpc_da_503_fijo(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = {"inesperado": True}
    r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
    assert r.status_code == 503


def test_el_gate_legible_sin_permiso_da_403_antes_de_llamar_a_la_base(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-gate")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona_id, *codigos: False)
    db = _db()
    r = _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH)
    assert r.status_code == 403
    db.postgrest.schema.return_value.rpc.assert_not_called()


def test_se_llama_con_el_cliente_del_caller_no_con_el_de_servicio(permitir):
    servicio = MagicMock()
    app.dependency_overrides[get_service_client] = lambda: servicio
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 5
    assert _cliente(db).post(URL, json={"motivo": MOTIVO}, headers=AUTH).status_code == 200
    servicio.postgrest.schema.assert_not_called()


# --- flag puede_descartar_alerta_horario en GET /api/marcas -------------------------------------------------------------------------------------


def _marca(id_, persona=PERSONA_AJENA):
    return {
        "id": id_, "evento_id": f"00000000-0000-0000-0000-{id_:012d}", "persona_id": persona, "terminal_id": "T-1", "secuencia_local": id_,
        "momento_dispositivo": "2026-10-06T15:00:00+00:00", "momento_recepcion": "2026-10-07T15:00:00+00:00", "desfase_local": "-06:00",
        "estado_reloj": "sincronizado", "version_software": "1.0.0", "origen": "terminal", "requiere_revision": True,
    }


def _exc(id_, marca_id, motivo, estado="pendiente"):
    return {"id": id_, "marca_id": marca_id, "motivo_revision": motivo, "estado": estado}


def _listar(monkeypatch, excepciones, estado_dia="cerrado", persona_marca=PERSONA_AJENA, con_permiso=True, con_dia=True):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-gate")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona_id, *codigos: True)
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona_id, codigo: True)
    consultado = []
    monkeypatch.setattr(router_marcas, "resolver_persona_id", lambda db, caller: consultado.append("persona") or PERSONA_CALLER)
    monkeypatch.setattr(router_marcas, "tiene_permiso", lambda db, persona, codigo: consultado.append(codigo) or con_permiso)
    dias = [{"id": 70, "persona_id": persona_marca, "fecha": "2026-10-06", "estado": estado_dia}] if con_dia else []
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=_tabla([]), dia=_tabla(dias))
    db = _db(
        marca=_tabla([_marca(1, persona_marca)], count=1),
        persona=_tabla([{"id": persona_marca, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=_tabla(excepciones),
        correccion=_tabla([]),
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["marcas"][0], consultado


@pytest.mark.parametrize("estado_dia", ["cerrado", "revisado"])
def test_flag_si_alerta_pendiente_dia_cerrado_o_revisado_marca_ajena_y_con_permiso(monkeypatch, estado_dia):
    marca, consultado = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario")], estado_dia=estado_dia)
    assert marca["puede_descartar_alerta_horario"] is True and marca["excepcion_horario_pendiente_id"] == 10
    assert "excepcion_dia_cerrado_descarte" in consultado


def test_flag_si_el_motivo_trae_sufijo_de_una_reapertura(monkeypatch):
    marca, _ = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario — resuelto por corrección 3")])
    assert marca["puede_descartar_alerta_horario"] is True


@pytest.mark.parametrize("estado_dia", ["abierto", "bloqueado"])
def test_flag_no_con_el_dia_abierto_o_bloqueado(monkeypatch, estado_dia):
    marca, consultado = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario")], estado_dia=estado_dia)
    assert marca["puede_descartar_alerta_horario"] is False
    assert consultado == []                           # sin candidatas no se consulta ni persona ni permiso


def test_flag_no_si_el_dia_no_existe(monkeypatch):
    assert _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario")], con_dia=False)[0]["puede_descartar_alerta_horario"] is False


@pytest.mark.parametrize("motivo", ["reloj_no_sincronizado", "dia_cerrado", "persona_inactiva", "paridad_impar"])
def test_flag_no_con_otro_motivo(monkeypatch, motivo):
    marca, _ = _listar(monkeypatch, [_exc(10, 1, motivo)])
    assert marca["puede_descartar_alerta_horario"] is False and marca["excepcion_horario_pendiente_id"] is None


def test_flag_no_si_la_alerta_ya_esta_resuelta(monkeypatch):
    marca, _ = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario — descartada por abc: ok", estado="resuelto")])
    assert marca["puede_descartar_alerta_horario"] is False and marca["excepcion_horario_pendiente_id"] is None


def test_flag_no_en_la_marca_propia(monkeypatch):
    marca, _ = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario")], persona_marca=PERSONA_CALLER)
    assert marca["puede_descartar_alerta_horario"] is False


def test_flag_no_sin_el_permiso_de_accion(monkeypatch):
    marca, _ = _listar(monkeypatch, [_exc(10, 1, "fuera_de_horario")], con_permiso=False)
    assert marca["puede_descartar_alerta_horario"] is False and marca["excepcion_horario_pendiente_id"] == 10


# --- contrato con db/ddl/125_*.sql -----------------------------------------------------------------------------------------------------------------


@pytest.mark.skipif(not SQL_125, reason="db/ddl/125_*.sql todavía no existe")
def test_el_contrato_nombres_de_parametros_y_hints_existen_en_125():
    sql = SQL_125[0].read_text(encoding="utf-8")
    firma = re.search(r"CREATE FUNCTION tiempo\.fn_excepcion_horario_descartar\((.*?)\)\s*RETURNS bigint", sql, re.S).group(1)
    assert [p.strip().split()[0] for p in firma.split(",")] == ["p_excepcion_id", "p_motivo"]
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 1
    app.dependency_overrides[get_caller_client] = lambda: db
    from app.routers.excepciones import descartar_alerta_horario
    from app.schemas.excepciones import DescartarAlertaHorarioIn

    descartar_alerta_horario(7, DescartarAlertaHorarioIn(motivo=MOTIVO), db, None)
    nombre, argumentos = db.postgrest.schema.return_value.rpc.call_args.args
    assert nombre == "fn_excepcion_horario_descartar" and list(argumentos) == ["p_excepcion_id", "p_motivo"]
    for hint in ESPERADO:
        assert f"HINT = '{hint}'" in sql, hint
    assert "ERRCODE = 'SCJ28'" in sql and errores.CODIGO_ALERTA_HORARIO == "SCJ28"
    assert "HINT = 'sin_permiso'" in sql
    assert re.search(r"GRANT EXECUTE ON FUNCTION tiempo\.fn_excepcion_horario_descartar\(bigint, text\) TO authenticated;", sql)
    assert not re.search(r"GRANT EXECUTE ON FUNCTION tiempo\.fn_excepcion_horario_descartar\(bigint, text\) TO (anon|service_role)", sql)
    assert "excepcion_dia_cerrado_descarte" in sql and router_marcas.PERMISO_DESCARTE == "excepcion_dia_cerrado_descarte"
    assert "fuera\\_de\\_horario%" in sql and router_marcas.PREFIJO_FUERA_DE_HORARIO == "fuera_de_horario"


@pytest.mark.skipif(not SQL_125, reason="db/ddl/125_*.sql todavía no existe")
def test_el_mapa_de_hints_del_backend_cubre_exactamente_los_scj28_del_sql():
    sql = SQL_125[0].read_text(encoding="utf-8")
    en_sql = set(re.findall(r"ERRCODE = 'SCJ28', HINT = '(\w+)'", sql))
    assert en_sql == set(errores._SCJ28_POR_HINT) == set(ESPERADO)


def test_los_hints_de_scj28_estan_en_la_lista_cerrada_de_registro():
    from app.registro_seguro import HINTS_CONOCIDOS

    assert set(ESPERADO) <= HINTS_CONOCIDOS
