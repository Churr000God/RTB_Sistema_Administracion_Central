"""El código que llama a los RPC debe coincidir con las firmas REALES del DDL (db/ddl/83_*.sql):
si alguien renombra o agrega un parámetro en SQL, esta prueba falla antes que producción."""

import re
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.deps import get_service_client
from app.main import app

DDL = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/83_*.sql"))
LLAVE = "scjt_" + "C" * 43


@pytest.fixture(scope="module")
def sql() -> str:
    assert DDL, "no se encontró db/ddl/83_*.sql"
    return DDL[0].read_text(encoding="utf-8")


def _parametros_sql(sql: str, funcion: str) -> list[str]:
    coincidencia = re.search(
        rf"CREATE FUNCTION tiempo\.{funcion}\((.*?)\)\s*RETURNS", sql, re.S | re.I
    )
    assert coincidencia, f"no se encontró la firma de {funcion}"
    return [
        parte.strip().split()[0]
        for parte in coincidencia.group(1).split(",")
        if parte.strip()
    ]


def _llamadas_reales() -> dict[str, dict]:
    db = MagicMock()
    capturadas: dict[str, dict] = {}

    def rpc(nombre, params=None):
        capturadas[nombre] = params
        constructor = MagicMock()
        constructor.execute.return_value.data = (
            {"terminal_id": 7, "serie": "T-1", "credencial_id": 1, "ip_cambio": False}
            if nombre == "fn_terminal_autenticar"
            else {
                "hora_servidor": "2026-10-06T15:00:00+00:00",
                "desfase_reloj_seg": 0,
                "ultima_secuencia_recibida": 0,
            }
        )
        return constructor

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url="http://x", supabase_anon_key="a", supabase_service_role_key="s"
    )
    cliente = TestClient(app, base_url="https://testserver", client=("198.51.100.7", 1))
    r = cliente.post(
        "/api/terminal/latido",
        json={
            "hora_terminal": "2026-10-06T15:00:00Z",
            "terminal_alcanzable": True,
            "reloj_sincronizado": True,
            "version_pi": "1.0.0",
            "marcas_pendientes": 1,
        },
        headers={"Authorization": f"Bearer {LLAVE}"},
    )
    assert r.status_code == 200
    return capturadas


@pytest.mark.parametrize("funcion", ["fn_terminal_autenticar", "fn_terminal_latido"])
def test_los_argumentos_enviados_coinciden_con_la_firma_del_ddl(sql, funcion):
    enviados = _llamadas_reales()[funcion]
    assert list(enviados) == _parametros_sql(sql, funcion)


def test_las_firmas_esperadas_siguen_siendo_las_que_el_codigo_asume(sql):
    assert _parametros_sql(sql, "fn_terminal_autenticar") == ["p_hash", "p_ip"]
    assert _parametros_sql(sql, "fn_terminal_latido") == [
        "p_terminal_id",
        "p_hora_terminal",
        "p_alcanzable",
        "p_reloj_sincronizado",
        "p_version_pi",
        "p_marcas_pendientes",
    ]


def test_fn_terminal_autenticar_tolera_una_ip_invalida_convirtiendola_en_null(sql):
    """Request sin cliente -> p_ip='desconocida': el RPC no debe fallar, debe tratarla como NULL."""
    cuerpo = re.search(
        r"CREATE FUNCTION tiempo\.fn_terminal_autenticar.*?\$\$;", sql, re.S | re.I
    )
    assert cuerpo
    assert re.search(
        r"BEGIN\s+v_ip\s*:=\s*p_ip::inet;\s*EXCEPTION\s+WHEN\s+OTHERS\s+THEN\s+v_ip\s*:=\s*NULL;",
        cuerpo.group(0),
        re.S | re.I,
    )


def test_los_dos_rpc_son_solo_para_service_role(sql):
    for firma in ("fn_terminal_autenticar(text, text)", "fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer)"):
        assert re.search(
            rf"REVOKE EXECUTE ON FUNCTION tiempo\.{re.escape(firma)}\s+FROM PUBLIC, anon, authenticated",
            sql,
            re.I,
        )
        assert re.search(
            rf"GRANT EXECUTE ON FUNCTION tiempo\.{re.escape(firma)}\s+TO service_role", sql, re.I
        )


# --- 99_: el RPC de latido con 7 argumentos --------------------------------------------------------------------------------------------------------


def test_99_los_argumentos_con_ingesta_detenida_coinciden_con_la_firma_de_99(monkeypatch):
    sql99 = next(iter(sorted(Path(__file__).resolve().parents[2].glob("db/ddl/99_*.sql")))).read_text(encoding="utf-8")
    firma = _parametros_sql(sql99, "fn_terminal_latido")
    assert firma == ["p_terminal_id", "p_hora_terminal", "p_alcanzable", "p_reloj_sincronizado", "p_version_pi", "p_marcas_pendientes", "p_ingesta_detenida"]
    assert re.search(r"p_ingesta_detenida\s+boolean\s+DEFAULT NULL", sql99)                  # opcional: la llamada de 6 argumentos sigue válida
    db = MagicMock()
    capturadas = {}

    def rpc(nombre, params=None):
        capturadas[nombre] = params
        c = MagicMock()
        c.execute.return_value.data = ({"terminal_id": 7, "serie": "T-1", "credencial_id": 1, "ip_cambio": False} if nombre == "fn_terminal_autenticar"
                                       else {"hora_servidor": "2026-10-06T15:00:00+00:00", "desfase_reloj_seg": 0, "ultima_secuencia_recibida": 0})
        return c

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_settings] = lambda: Settings(supabase_url="http://x", supabase_anon_key="a", supabase_service_role_key="s")
    r = TestClient(app, base_url="https://testserver", client=("198.51.100.7", 1)).post(
        "/api/terminal/latido", json={"ingesta_detenida": True, "marcas_pendientes": 1}, headers={"Authorization": f"Bearer {LLAVE}"})
    assert r.status_code == 200 and list(capturadas["fn_terminal_latido"]) == firma


def test_99_el_rpc_de_latido_nuevo_sigue_siendo_solo_para_service_role():
    sql99 = next(iter(sorted(Path(__file__).resolve().parents[2].glob("db/ddl/99_*.sql")))).read_text(encoding="utf-8")
    assert re.search(r"REVOKE EXECUTE ON FUNCTION tiempo\.fn_terminal_latido\(bigint, timestamptz, boolean, boolean, text, integer, boolean\)\s+FROM PUBLIC, anon, authenticated", sql99)
    assert re.search(r"GRANT EXECUTE ON FUNCTION tiempo\.fn_terminal_latido\(bigint, timestamptz, boolean, boolean, text, integer, boolean\)\s+TO service_role", sql99)
