"""El código que llama a fn_excepcion_dia_cerrado_descartar debe coincidir con la firma REAL de
db/ddl/86_*.sql, y su EXECUTE debe ser SOLO para `authenticated` (el descarte se hace con el cliente
del usuario, nunca con service_role). Si alguien cambia el SQL, esta prueba falla antes que producción."""

import re
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app import errores, permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

DDL = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/86_*.sql"))
FUNCION = "fn_excepcion_dia_cerrado_descartar"
FIRMA = "fn_excepcion_dia_cerrado_descartar(bigint, text)"


@pytest.fixture(scope="module")
def sql() -> str:
    assert DDL, "no se encontró db/ddl/86_*.sql"
    return DDL[0].read_text(encoding="utf-8")


def _parametros_sql(sql: str) -> list[str]:
    coincidencia = re.search(rf"CREATE FUNCTION tiempo\.{FUNCION}\((.*?)\)\s*RETURNS", sql, re.S | re.I)
    assert coincidencia, "no se encontró la firma"
    return [p.strip().split()[0] for p in coincidencia.group(1).split(",") if p.strip()]


def _tipos_sql(sql: str) -> list[str]:
    coincidencia = re.search(rf"CREATE FUNCTION tiempo\.{FUNCION}\((.*?)\)\s*RETURNS", sql, re.S | re.I)
    return [p.strip().split()[1] for p in coincidencia.group(1).split(",") if p.strip()]


def _parametros_enviados(monkeypatch) -> dict:
    capturado = {}
    db = MagicMock()

    def rpc(nombre, params=None):
        capturado["nombre"] = nombre
        capturado["params"] = params
        constructor = MagicMock()
        constructor.execute.return_value.data = {"resultado": "descartada", "excepcion_id": 1, "dia_id": 2}
        return constructor

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda d, c: "p")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda d, p, *c: True)
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(auth_user_id="a", correo=None)
    r = TestClient(app).post("/api/excepciones/1/descartar", json={"motivo": "x"}, headers={"Authorization": "Bearer t"})
    assert r.status_code == 200, r.text
    return capturado


def test_los_argumentos_enviados_coinciden_con_la_firma_del_ddl(sql, monkeypatch):
    enviado = _parametros_enviados(monkeypatch)
    assert enviado["nombre"] == FUNCION
    assert list(enviado["params"]) == _parametros_sql(sql) == ["p_excepcion_id", "p_motivo"]


def test_los_tipos_de_la_firma_son_bigint_y_text(sql):
    assert _tipos_sql(sql) == ["bigint", "text"]


def test_execute_es_solo_para_authenticated(sql):
    assert re.search(
        rf"REVOKE EXECUTE ON FUNCTION tiempo\.{re.escape(FIRMA)}\s+FROM PUBLIC, anon, authenticated, service_role",
        sql,
        re.I,
    )
    assert re.search(
        rf"GRANT EXECUTE ON FUNCTION tiempo\.{re.escape(FIRMA)} TO authenticated;", sql, re.I
    )
    # ninguna otra concesión de EXECUTE sobre esta función (ni a service_role, ni a anon)
    concesiones = re.findall(rf"GRANT EXECUTE ON FUNCTION tiempo\.{re.escape(FIRMA)}\s+TO\s+([^;]+);", sql, re.I)
    assert [c.strip() for c in concesiones] == ["authenticated"]


def test_la_funcion_es_security_definer_con_search_path_fijo(sql):
    cuerpo = re.search(rf"CREATE FUNCTION tiempo\.{FUNCION}.*?\$\$;", sql, re.S | re.I)
    assert cuerpo
    assert re.search(r"SECURITY DEFINER", cuerpo.group(0), re.I)
    assert re.search(r"SET search_path = tiempo, personas, pg_temp", cuerpo.group(0), re.I)


def test_el_gate_esta_dentro_de_la_funcion(sql):
    cuerpo = re.search(rf"CREATE FUNCTION tiempo\.{FUNCION}.*?\$\$;", sql, re.S | re.I).group(0)
    assert "personas.fn_caller_activo()" in cuerpo
    assert "excepcion_dia_cerrado_descarte" in cuerpo


def test_los_resultados_que_el_backend_entiende_existen_en_el_ddl(sql):
    cuerpo = re.search(rf"CREATE FUNCTION tiempo\.{FUNCION}.*?\$\$;", sql, re.S | re.I).group(0)
    for resultado in ("descartada", "ya_descartada", "no_encontrada"):
        assert f"'{resultado}'" in cuerpo


DDL_87 = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/87_*.sql"))


def test_cada_hint_scj15_que_el_backend_traduce_existe_en_el_ddl(sql):
    # 86_ y, cuando existe (db lo escribió; puede estar sin aplicar), 87_
    texto = sql + "".join(a.read_text(encoding="utf-8") for a in DDL_87)
    hints_sql = set(re.findall(r"HINT\s*=\s*'([a-z_]+)'", texto))
    for hint in errores._SCJ15_POR_HINT:
        assert hint in hints_sql, f"el backend traduce '{hint}' pero el DDL ya no lo emite"
    assert {"sin_permiso", "motivo_invalido"} <= hints_sql
    assert "SCJ15" in sql


def test_el_limite_de_motivo_del_ddl_coincide_con_el_del_esquema_pydantic(sql):
    from app.schemas.excepciones import DescartarExcepcionIn

    maximo = int(re.search(r"c_motivo_max\s+constant integer := (\d+);", sql).group(1))
    assert DescartarExcepcionIn.model_fields["motivo"].metadata[1].max_length == maximo


@pytest.mark.skipif(not DDL_87, reason="db/ddl/87_*.sql todavía no existe")
def test_el_87_bloquea_en_la_base_lo_mismo_que_el_guard_del_backend():
    """87_ (BEFORE INSERT en tiempo.correccion) rechaza con SCJ15/marca_en_tramo la corrección de una marca
    que es apertura o cierre de CUALQUIER tramo: es el criterio de app/marca_en_tramo.py (en_tramo y
    en_tramo_cerrado). Si el SQL cambia de criterio, hay que revisar el guard y el mapeo."""
    sql87 = DDL_87[0].read_text(encoding="utf-8")
    assert re.search(r"BEFORE INSERT ON tiempo\.correccion", sql87)
    assert "ERRCODE = 'SCJ15', HINT = 'marca_en_tramo'" in sql87
    assert re.search(r"t\.marca_apertura_id = NEW\.marca_id OR t\.marca_cierre_id = NEW\.marca_id", sql87)
    assert "marca_en_tramo" in errores._SCJ15_POR_HINT
