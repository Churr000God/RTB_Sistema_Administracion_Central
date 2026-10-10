"""CONTRATO_API_PUENTE_TERMINAL.md §1: POST /api/terminal/marcas. Mocks del cliente de Supabase con la firma REAL de
`.rpc(...)`; nunca contra la base real."""

import logging
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, rpc_con_firma_real
from app.config import Settings, get_settings
from app.deps import get_service_client
from app.main import app
from app.schemas.terminal import CODIGOS_DEFINITIVOS, CODIGOS_TRANSITORIOS, CLAVES_EVENTO

LLAVE = "scjt_" + "C" * 43
SERIE = "TERM-FICTICIA-01"
AUTENTICADA = {"terminal_id": 7, "serie": SERIE, "credencial_id": 3, "ip_cambio": False}
CRUDO = "texto-crudo-id-interno-3318"
UUID_A = "6f1c0a52-8f6e-5f0a-9d1e-0b7a3c2d4e10"
UUID_B = "7a2d1b63-9a7f-5a1b-8e2f-1c8b4d3e5f21"


def _evento(i=0, **extra):
    base = {
        "evento_id": UUID_A, "employee_no": 17 + i, "secuencia_local": 4417 + i,
        "momento_dispositivo": "2026-10-06T15:03:00Z", "desfase_local": "-06:00", "estado_reloj": "sincronizado",
    }
    base.update(extra)
    return base


def _cuerpo(n=1, **extra):
    c = {"terminal_id": SERIE, "version_software": "1.0.0", "eventos": [_evento(i) for i in range(n)]}
    c.update(extra)
    return c


def _ok(n):
    return {
        "momento_recepcion": "2026-10-09T16:00:00.123456+00:00",
        "resultados": [{"indice": i, "evento_id": UUID_A, "estado": "confirmado"} for i in range(n)],
    }


class Entorno:
    def __init__(self, respuesta=None, error=None):
        from unittest.mock import MagicMock

        self.db = MagicMock()
        self.rpc = rpc_con_firma_real()
        self.db.postgrest.schema.return_value.rpc = self.rpc
        self.respuesta, self.error = respuesta, error

        def segun(nombre, params):
            r = MagicMock()
            if nombre == "fn_terminal_autenticar":
                r.execute.return_value = Resultado(AUTENTICADA)
            elif self.error is not None:
                r.execute.side_effect = self.error
            else:
                r.execute.return_value = Resultado(self.respuesta)
            return r

        self.rpc.side_effect = segun
        app.dependency_overrides[get_service_client] = lambda: self.db
        app.dependency_overrides[get_settings] = lambda: Settings(
            supabase_url="http://supabase.invalido", supabase_anon_key="a", supabase_service_role_key="s"
        )
        self.cliente = TestClient(app, base_url="https://testserver", client=("198.51.100.7", 1), raise_server_exceptions=False)

    def post(self, cuerpo, llave=LLAVE, **kw):
        cabeceras = {"Authorization": f"Bearer {llave}"} if llave else {}
        return self.cliente.post("/api/terminal/marcas", json=cuerpo, headers=cabeceras, **kw)

    def llamadas_marcas(self):
        return [c.args for c in self.rpc.call_args_list if c.args[0] == "fn_marca_terminal_registrar"]


@pytest.fixture
def entorno():
    def crear(respuesta=None, error=None):
        return Entorno(respuesta, error)

    return crear


# --- camino feliz y lista blanca ---------------------------------------------------------------------------------------------


def test_registra_el_lote_con_el_id_de_la_credencial_y_responde_la_confirmacion(entorno):
    e = entorno(_ok(2))
    r = e.post(_cuerpo(2))
    assert r.status_code == 200, r.text
    assert r.json() == {
        "momento_recepcion": "2026-10-09T16:00:00.123456Z",
        "resultados": [{"indice": i, "evento_id": UUID_A, "estado": "confirmado", "codigo": None} for i in range(2)],
    }
    (nombre, params), = e.llamadas_marcas()
    assert params["p_terminal_id"] == 7  # el de la CREDENCIAL, no del cuerpo
    assert [x["employee_no"] for x in params["p_eventos"]] == [17, 18]
    assert all(x["version_software"] == "1.0.0" for x in params["p_eventos"])


def test_la_lista_blanca_descarta_origen_persona_fingerdata_y_lo_demas(entorno):
    e = entorno(_ok(1))
    sucio = _evento(
        origen="captura_manual", requiere_revision=True, persona_id="uuid-de-persona", fingerData="AAAA", terminal_id="otra",
        version_software="9.9.9", id=5, extra={"a": 1},
    )
    e.post(_cuerpo(1, eventos=[sucio]))
    evento = e.llamadas_marcas()[0][1]["p_eventos"][0]
    assert set(evento) == set(CLAVES_EVENTO) | {"version_software"}
    assert evento["version_software"] == "1.0.0"  # la pone el backend, no el evento
    texto = str(e.llamadas_marcas()[0][1])
    for prohibido in ("persona_id", "fingerData", "origen", "requiere_revision", "9.9.9"):
        assert prohibido not in texto


@pytest.mark.parametrize(
    "valor", [True, False, None, 1.5, 17.0, "17", {"a": 1}, [1], "x" * 65, 2**63, -(2**63)],
    ids=["true", "false", "none", "float", "float_entero", "cadena", "dict", "list", "cadena_larga", "entero_enorme", "entero_enorme_negativo"],
)
def test_un_entero_que_no_es_entero_estricto_o_se_pasa_de_rango_se_omite_y_lo_decide_el_rpc(entorno, valor):
    e = entorno(_ok(1))
    e.post(_cuerpo(1, eventos=[_evento(employee_no=valor)]))
    assert "employee_no" not in e.llamadas_marcas()[0][1]["p_eventos"][0]


@pytest.mark.parametrize("campo", ["evento_id", "momento_dispositivo", "desfase_local", "estado_reloj"])
@pytest.mark.parametrize("valor", [5, 1.5, True, None, ["x"], {"a": 1}], ids=["int", "float", "bool", "none", "lista", "dict"])
def test_un_campo_de_texto_con_otro_tipo_se_omite(entorno, campo, valor):
    e = entorno(_ok(1))
    e.post(_cuerpo(1, eventos=[_evento(**{campo: valor})]))
    assert campo not in e.llamadas_marcas()[0][1]["p_eventos"][0]


@pytest.mark.parametrize(
    "malo",
    ["a\u0000b", "\u0000", "a\nb", "a\tb", "a\x1bb", "a\x7fb", "a\x85b", "a\x9fb", "\ud800", "ab\udc00"],
    ids=["nul_en_medio", "solo_nul", "salto", "tab", "esc", "del", "c1_85", "c1_9f", "sustituto_alto", "sustituto_bajo"],
)
def test_un_texto_con_nul_controles_o_sustitutos_sueltos_se_omite_y_no_llega_a_la_base(entorno, malo):
    """Un \\u0000 dispara 22P05 en Postgres y tumbaría el LOTE; un sustituto suelto no se puede serializar. Se omite el campo y el
    RPC rechaza ESE evento (forma_invalida)."""
    e = entorno(_ok(2))
    r = e.cliente.post(
        "/api/terminal/marcas",
        content=__import__("json").dumps(_cuerpo(2, eventos=[_evento(0), _evento(1, desfase_local=malo)]), ensure_ascii=True),
        headers={"Authorization": f"Bearer {LLAVE}", "Content-Type": "application/json"},
    )
    assert r.status_code == 200, r.text
    eventos = e.llamadas_marcas()[0][1]["p_eventos"]
    assert "desfase_local" not in eventos[1] and eventos[0]["desfase_local"] == "-06:00"
    assert malo not in str(eventos)


def test_un_texto_valido_con_acentos_y_en_el_limite_pasa(entorno):
    e = entorno(_ok(1))
    e.post(_cuerpo(1, eventos=[_evento(momento_dispositivo="ñ" * 64)]))
    assert e.llamadas_marcas()[0][1]["p_eventos"][0]["momento_dispositivo"] == "ñ" * 64


@pytest.mark.parametrize("malo", ["texto", 5, None, [1, 2], True])
def test_un_evento_que_no_es_objeto_conserva_su_indice_y_no_tumba_el_lote(entorno, malo):
    e = entorno(_ok(2))
    r = e.post(_cuerpo(2, eventos=[_evento(0), malo]))
    assert r.status_code == 200
    eventos = e.llamadas_marcas()[0][1]["p_eventos"]
    assert len(eventos) == 2 and eventos[1] == {"version_software": "1.0.0"}


# --- validación del envoltorio --------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "cuerpo",
    [
        _cuerpo(0),
        {**_cuerpo(1), "eventos": []},
        {**_cuerpo(1), "eventos": list(range(201))},
        {k: v for k, v in _cuerpo(1).items() if k != "version_software"},
        _cuerpo(1, version_software=""),
        _cuerpo(1, version_software="x" * 17),
        _cuerpo(1, terminal_id="x" * 33),
        _cuerpo(1, persona_id="uuid"),
        _cuerpo(1, origen="captura_manual"),
        _cuerpo(1, eventos="no-es-lista"),
        _cuerpo(1, eventos={"a": 1}),
        _cuerpo(1, version_software=5),
    ],
)
def test_estructura_invalida_del_lote_es_422_sin_llamar_al_rpc(entorno, cuerpo):
    e = entorno(_ok(1))
    assert e.post(cuerpo).status_code == 422
    assert e.llamadas_marcas() == []


def test_200_eventos_pasan_y_201_no(entorno):
    e = entorno(_ok(200))
    assert e.post(_cuerpo(200)).status_code == 200
    assert e.post(_cuerpo(201)).status_code == 422


def test_la_serie_del_cuerpo_debe_coincidir_con_la_credencial(entorno):
    e = entorno(_ok(1))
    r = e.post(_cuerpo(1, terminal_id="OTRA-SERIE"))
    assert r.status_code == 403 and r.json()["detail"] == "La credencial no corresponde a esa terminal."
    assert e.llamadas_marcas() == []
    sin = {k: v for k, v in _cuerpo(1).items() if k != "terminal_id"}
    assert e.post(sin).status_code == 200


def test_sin_credencial_o_con_una_mala_es_401_y_no_llega_al_rpc_de_marcas(entorno):
    e = entorno(_ok(1))
    assert e.post(_cuerpo(1), llave=None).status_code == 401
    assert e.post(_cuerpo(1), llave="no-es-una-llave").status_code == 401
    assert e.llamadas_marcas() == []


# --- confirmación individual -----------------------------------------------------------------------------------------------------


def test_pasa_cada_estado_y_codigo_de_la_lista_cerrada(entorno):
    resultados = [
        {"indice": 0, "evento_id": UUID_A, "estado": "confirmado"},
        {"indice": 1, "evento_id": UUID_B, "estado": "duplicado"},
        {"indice": 2, "evento_id": UUID_A, "estado": "rechazo_definitivo", "codigo": "no_enrolado"},
        {"indice": 3, "evento_id": UUID_B, "estado": "rechazo_transitorio", "codigo": "tope_terminal"},
        {"indice": 4, "evento_id": None, "estado": "rechazo_definitivo", "codigo": "forma_invalida"},
    ]
    e = entorno({"momento_recepcion": "2026-10-09T16:00:00+00:00", "resultados": resultados})
    r = e.post(_cuerpo(5))
    assert r.status_code == 200
    assert [(x["estado"], x["codigo"]) for x in r.json()["resultados"]] == [
        ("confirmado", None), ("duplicado", None), ("rechazo_definitivo", "no_enrolado"),
        ("rechazo_transitorio", "tope_terminal"), ("rechazo_definitivo", "forma_invalida"),
    ]
    assert r.json()["resultados"][4]["evento_id"] is None


@pytest.mark.parametrize("codigo", CODIGOS_DEFINITIVOS)
def test_todos_los_codigos_definitivos_pasan(entorno, codigo):
    e = entorno({"momento_recepcion": "2026-10-09T16:00:00+00:00",
                 "resultados": [{"indice": 0, "evento_id": UUID_A, "estado": "rechazo_definitivo", "codigo": codigo}]})
    assert e.post(_cuerpo(1)).json()["resultados"][0]["codigo"] == codigo


@pytest.mark.parametrize("codigo", CODIGOS_TRANSITORIOS)
def test_todos_los_codigos_transitorios_pasan(entorno, codigo):
    e = entorno({"momento_recepcion": "2026-10-09T16:00:00+00:00",
                 "resultados": [{"indice": 0, "evento_id": UUID_A, "estado": "rechazo_transitorio", "codigo": codigo}]})
    assert e.post(_cuerpo(1)).json()["resultados"][0]["codigo"] == codigo


def _r(**kw):
    base = {"indice": 0, "evento_id": UUID_A, "estado": "confirmado"}
    base.update(kw)
    return base


MOMENTO = "2026-10-09T16:00:00+00:00"


@pytest.mark.parametrize(
    "respuesta",
    [
        None, [], "ok", {}, {"resultados": []},
        {"momento_recepcion": MOMENTO},
        {"momento_recepcion": MOMENTO, "resultados": []},                                            # faltan resultados
        {"momento_recepcion": MOMENTO, "resultados": [_r(), _r(indice=1)]},                          # sobran
        {"momento_recepcion": MOMENTO, "resultados": [_r(indice=1)]},                                # indice empieza en 1
        {"momento_recepcion": "no-es-fecha", "resultados": [_r()]},
        {"momento_recepcion": MOMENTO, "resultados": [_r(estado="aceptado")]},                       # estado fuera del vocabulario
        {"momento_recepcion": MOMENTO, "resultados": [_r(codigo="no_enrolado")]},                    # código con confirmado
        {"momento_recepcion": MOMENTO, "resultados": [_r(estado="rechazo_definitivo")]},             # definitivo sin código
        {"momento_recepcion": MOMENTO, "resultados": [_r(estado="rechazo_definitivo", codigo="tope_terminal")]},
        {"momento_recepcion": MOMENTO, "resultados": [_r(estado="rechazo_transitorio", codigo="no_enrolado")]},
        {"momento_recepcion": MOMENTO, "resultados": [_r(estado="rechazo_definitivo", codigo="inventado")]},
        {"momento_recepcion": MOMENTO, "resultados": [_r(persona_id="uuid-secreto")]},               # clave de más: no se reenvía
        {"momento_recepcion": MOMENTO, "resultados": [_r(), _r(indice=0)]},                          # índice repetido
        {"momento_recepcion": MOMENTO, "resultados": [_r(indice=-1)]},
        {"momento_recepcion": MOMENTO, "resultados": ["x"]},
        {"momento_recepcion": MOMENTO, "resultados": [_r(evento_id="x" * 37)]},
    ],
)
def test_una_respuesta_rara_del_rpc_es_503_y_nunca_se_reenvia(entorno, respuesta, caplog):
    e = entorno(respuesta)
    with caplog.at_level(logging.ERROR):
        r = e.post(_cuerpo(1))
    assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible; reintenta."}
    assert "uuid-secreto" not in r.text
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_resultados_desordenados_son_503(entorno):
    e = entorno({"momento_recepcion": MOMENTO, "resultados": [_r(indice=1), _r(indice=0)]})
    assert e.post(_cuerpo(2)).status_code == 503


# --- errores de la base ------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "error,estado",
    [
        (APIError({"code": "SCJ12", "hint": "terminal_no_valida", "message": CRUDO}), 401),
        (APIError({"code": "22023", "hint": "lote_invalido", "message": CRUDO}), 422),
        (APIError({"code": "22003", "message": CRUDO}), 422),
        (APIError({"code": "42501", "message": CRUDO}), 503),
        (APIError({"code": "PGRST202", "message": CRUDO}), 503),
        (APIError({"code": "42P01", "message": CRUDO}), 503),
        (APIError({"code": "XX999", "message": CRUDO}), 500),
        (ConnectionError(CRUDO), 503),
        (TimeoutError(CRUDO), 503),
        (RuntimeError(CRUDO), 503),
    ],
)
def test_errores_del_rpc_con_estado_fijo_y_sin_texto_de_la_base(entorno, error, estado, caplog):
    e = entorno(error=error)
    with caplog.at_level(logging.ERROR):
        r = e.post(_cuerpo(1))
    assert r.status_code == estado
    assert "3318" not in r.text  # ni en la respuesta (el log del 500 sí lleva el traceback del servidor)
    if estado != 500:
        assert "3318" not in caplog.text


def test_el_401_por_terminal_desactivada_pide_reautenticar(entorno):
    e = entorno(error=APIError({"code": "SCJ12", "hint": "terminal_no_valida", "message": "x"}))
    r = e.post(_cuerpo(1))
    assert r.status_code == 401 and r.headers["www-authenticate"] == "Bearer"


# --- tamaño del cuerpo ---------------------------------------------------------------------------------------------------------------


def test_un_cuerpo_de_mas_de_256_kb_es_413_con_hsts_y_sin_llegar_a_nada(entorno):
    e = entorno(_ok(1))
    r = e.post(_cuerpo(1, relleno="x" * (300 * 1024)))
    assert r.status_code == 413
    assert r.json() == {"detail": "El cuerpo de la petición es demasiado grande."}
    assert "strict-transport-security" in r.headers and r.headers["cache-control"] == "no-store"
    assert e.llamadas_marcas() == []


def test_un_cuerpo_chunked_de_1_mb_sin_credencial_es_413_sin_parsear_ni_autenticar(entorno):
    """M1 de security: el límite va ANTES de autenticar y de parsear; sin Content-Length se cuentan los bytes recibidos."""
    e = entorno(_ok(1))

    def trozos():
        for _ in range(100):
            yield b"x" * (10 * 1024)

    r = e.cliente.post("/api/terminal/marcas", content=trozos(), headers={"Content-Type": "application/json"})
    assert r.status_code == 413 and r.json() == {"detail": "El cuerpo de la petición es demasiado grande."}
    assert "content-length" not in r.request.headers  # chunked de verdad
    llamadas = [c.args[0] for c in e.rpc.call_args_list]
    assert llamadas == []  # ni siquiera se intentó autenticar (fn_terminal_autenticar)


def test_un_content_length_mentiroso_no_evita_el_limite(entorno):
    e = entorno(_ok(1))

    def trozos():
        for _ in range(100):
            yield b"x" * (10 * 1024)

    r = e.cliente.post(
        "/api/terminal/marcas", content=trozos(),
        headers={"Content-Type": "application/json", "Content-Length": "100", "Authorization": f"Bearer {LLAVE}"},
    )
    assert r.status_code in (400, 413)  # h11 corta una petición inconsistente; si llegara al app, sería 413
    assert e.llamadas_marcas() == []


def test_un_cuerpo_justo_bajo_el_limite_pasa(entorno):
    e = entorno(_ok(1))
    r = e.post(_cuerpo(1, relleno="x" * (250 * 1024)))
    assert r.status_code == 422  # llega al app (extra=forbid del envoltorio), no es 413


def test_un_lote_grande_pero_bajo_el_limite_pasa(entorno):
    e = entorno(_ok(200))
    r = e.post(_cuerpo(200))
    assert len(r.request.content) < 256 * 1024 and r.status_code == 200


def test_el_limite_solo_aplica_a_la_terminal(entorno):
    """Otras rutas no se ven afectadas por el tope de /api/terminal/*."""
    e = entorno(_ok(1))
    r = e.cliente.post("/salud", content=b"x" * (600 * 1024))
    assert r.status_code != 413  # /salud no admite POST (405), pero no es un 413


# --- contrato con el DDL (83_/84_) ---------------------------------------------------------------------------------------------------


def _ddl(prefijo):
    return next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob(f"{prefijo}_*.sql")).read_text(encoding="utf-8")


def test_la_firma_del_rpc_y_su_grant_coinciden_con_83():
    sql = _ddl("83")
    assert "fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)" in sql
    assert "fn_marca_terminal_registrar(bigint, jsonb) TO service_role" in sql


def test_el_vocabulario_de_codigos_coincide_con_el_del_rpc_y_el_check_de_84():
    sql83 = _ddl("83")
    usados = set(re.findall(r"v_codigo := '([a-z_]+)'", sql83))
    assert usados == set(CODIGOS_DEFINITIVOS) | set(CODIGOS_TRANSITORIOS)
    bloque = re.search(r"ck_marca_rechazada_codigo CHECK \(\s*codigo IN \((.*?)\)\s*\)", _ddl("84"), re.S).group(1)
    assert set(re.findall(r"'([a-z_]+)'", bloque)) == set(CODIGOS_DEFINITIVOS)


def test_las_claves_del_evento_son_las_que_lee_el_rpc():
    sql = _ddl("83")
    leidas = set(re.findall(r"v_evento->>'([a-z_]+)'", sql))
    assert set(CLAVES_EVENTO) <= leidas | {"evento_id"} and leidas <= set(CLAVES_EVENTO) | {"version_software"}


def test_el_contrato_documenta_los_mismos_codigos():
    doc = (Path(__file__).resolve().parents[2] / "docs" / "07-procesos" / "CONTRATO_API_PUENTE_TERMINAL.md").read_text(encoding="utf-8")
    for codigo in (*CODIGOS_DEFINITIVOS, *CODIGOS_TRANSITORIOS):
        assert f"`{codigo}`" in doc, codigo


def test_toda_respuesta_de_la_terminal_lleva_no_store_y_hsts(entorno):
    e = entorno(_ok(1))
    for r in (e.post(_cuerpo(1)), e.post(_cuerpo(1), llave=None), e.post({"x": 1})):
        assert r.headers["cache-control"] == "no-store" and "strict-transport-security" in r.headers


def test_un_content_length_declarado_enorme_se_rechaza_sin_leer_ni_un_byte():
    """El rechazo por cabecera ocurre antes de pedir el cuerpo (no se lee nada del cliente)."""
    import asyncio

    from app.terminal_auth import LimiteCuerpoTerminal

    leido = []
    enviado = []

    async def app_falso(scope, receive, send):  # pragma: no cover - no debe invocarse
        leido.append("app")

    async def receive():  # pragma: no cover - no debe invocarse
        leido.append("receive")
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(mensaje):
        enviado.append(mensaje)

    scope = {"type": "http", "path": "/api/terminal/marcas", "headers": [(b"content-length", str(10 * 1024 * 1024).encode())]}
    asyncio.run(LimiteCuerpoTerminal(app_falso)(scope, receive, send))
    assert leido == [] and enviado[0]["status"] == 413
    assert dict(enviado[0]["headers"])[b"strict-transport-security"]


# --- 95_: modo_verificacion (campo OPCIONAL; único valor significativo: la cadena exacta «huella») ----------------------------------------------------


def test_modo_verificacion_huella_pasa_al_rpc_y_ausente_no_agrega_la_clave(entorno):
    e = entorno(_ok(2))
    e.post(_cuerpo(2, eventos=[_evento(0, modo_verificacion="huella"), _evento(1)]))
    eventos = e.llamadas_marcas()[0][1]["p_eventos"]
    assert eventos[0]["modo_verificacion"] == "huella" and "modo_verificacion" not in eventos[1]


@pytest.mark.parametrize("valor", [
    "Huella", "HUELLA", " huella", "huella ", "huella\x00", "huella\n", "fp", "fingerprint", "huellas", "", "x" * 65, "h" * 1000, None, True, False, 1, 1.5, ["huella"],
    {"a": "huella"}, "hue​lla", "huella​",
], ids=lambda v: repr(v)[:20])
def test_cualquier_otro_valor_tipo_o_largo_de_modo_verificacion_se_descarta_antes_del_rpc(entorno, valor):
    e = entorno(_ok(1))
    e.post(_cuerpo(1, eventos=[_evento(0, modo_verificacion=valor)]))
    evento = e.llamadas_marcas()[0][1]["p_eventos"][0]
    assert "modo_verificacion" not in evento and set(evento) == set(CLAVES_EVENTO) | {"version_software"}
    assert "fingerprint" not in str(e.llamadas_marcas()[0][1]) and "HUELLA" not in str(e.llamadas_marcas()[0][1])


def test_el_evento_con_modo_verificacion_no_es_forma_invalida_ni_cambia_el_resto_del_contrato(entorno):
    e = entorno(_ok(1))
    r = e.post(_cuerpo(1, eventos=[_evento(0, modo_verificacion="huella", persona_id="x", origen="captura_manual")]))
    assert r.status_code == 200
    evento = e.llamadas_marcas()[0][1]["p_eventos"][0]
    assert set(evento) == set(CLAVES_EVENTO) | {"version_software", "modo_verificacion"} and "persona_id" not in evento and "origen" not in evento
