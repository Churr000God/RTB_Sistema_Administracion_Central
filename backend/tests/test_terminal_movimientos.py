"""CONTRATO_API_PUENTE_TERMINAL.md §4: POST /api/terminal/movimientos. Mocks con la firma real de `.rpc(...)`."""

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
from app.detalle_terminal import DetalleProhibido, sanear_detalle
from app.main import app

LLAVE = "scjt_" + "E" * 43
AUTENTICADA = {"terminal_id": 7, "serie": "TERM-FICTICIA-01", "credencial_id": 3, "ip_cambio": False}
CRUDO = "texto-crudo-id-interno-7710"


class Entorno:
    def __init__(self, respuesta=None, error=None):
        self.db = MagicMock()
        self.rpc = rpc_con_firma_real()
        self.db.postgrest.schema.return_value.rpc = self.rpc
        self.respuesta = respuesta if respuesta is not None else {"resultado": "registrado", "estado": "esperando_huella"}

        def segun(nombre, params):
            r = MagicMock()
            if nombre == "fn_terminal_autenticar":
                r.execute.return_value = Resultado(AUTENTICADA)
            elif error is not None:
                r.execute.side_effect = error
            else:
                r.execute.return_value = Resultado(self.respuesta)
            return r

        self.rpc.side_effect = segun
        app.dependency_overrides[get_service_client] = lambda: self.db
        app.dependency_overrides[get_settings] = lambda: Settings(
            supabase_url="http://x.invalido", supabase_anon_key="a", supabase_service_role_key="s"
        )
        self.cliente = TestClient(app, base_url="https://testserver", client=("198.51.100.7", 1), raise_server_exceptions=False)

    def post(self, cuerpo, llave=LLAVE):
        return self.cliente.post(
            "/api/terminal/movimientos", json=cuerpo, headers={"Authorization": f"Bearer {llave}"} if llave else {}
        )

    def llamadas(self):
        return [c.args[1] for c in self.rpc.call_args_list if c.args[0] == "fn_terminal_movimiento_registrar"]


def _m(tipo="usuario_creado", **extra):
    return {"terminal_usuario_id": 77, "tipo": tipo, **extra}


# --- camino feliz por tipo ----------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "cuerpo,esperado",
    [
        (_m("usuario_creado"), {"p_tipo": "usuario_creado", "p_huellas": None, "p_detalle": None}),
        (_m("huella_capturada", huellas=2), {"p_tipo": "huella_capturada", "p_huellas": 2, "p_detalle": None}),
        (_m("baja_confirmada"), {"p_tipo": "baja_confirmada", "p_huellas": None, "p_detalle": None}),
        (_m("error", codigo="usuario_ya_existe", detalle="el aparato ya tenía ese employeeNo"),
         {"p_tipo": "error", "p_huellas": None, "p_detalle": "usuario_ya_existe: el aparato ya tenía ese employeeNo"}),
        (_m("error", codigo="sin_detalle"), {"p_tipo": "error", "p_huellas": None, "p_detalle": "sin_detalle"}),
    ],
)
def test_cada_tipo_llama_al_rpc_con_el_id_de_la_credencial(cuerpo, esperado):
    e = Entorno()
    r = e.post(cuerpo)
    assert r.status_code == 200, r.text
    assert e.llamadas() == [{"p_terminal_id": 7, "p_terminal_usuario_id": 77, **esperado}]


@pytest.mark.parametrize("resultado", ["registrado", "ya_aplicado"])
@pytest.mark.parametrize("estado", ["esperando_huella", "activo", "baja", "pendiente_baja", "pendiente_alta"])
def test_registrado_y_ya_aplicado_son_200_con_el_estado_actual(resultado, estado):
    r = Entorno({"resultado": resultado, "estado": estado}).post(_m())
    assert r.status_code == 200 and r.json() == {"resultado": resultado, "estado": estado}


def test_no_encontrado_es_404_identico_para_una_alta_de_otra_terminal_y_una_inexistente():
    """B9 de security: el RPC no distingue (alta de OTRA terminal = inexistente) y el endpoint tampoco."""
    otra = Entorno({"resultado": "no_encontrado"}).post(_m())
    inexistente = Entorno({"resultado": "no_encontrado"}).post({**_m(), "terminal_usuario_id": 999_999})
    assert otra.status_code == inexistente.status_code == 404
    assert otra.json() == inexistente.json() == {"detail": "La alta no existe."}
    assert dict(otra.headers).keys() - {"date"} == dict(inexistente.headers).keys() - {"date"}


def test_el_rpc_solo_recibe_la_terminal_de_la_credencial_nunca_otra():
    e = Entorno()
    e.post({**_m(), "terminal_usuario_id": 123})
    assert all(p["p_terminal_id"] == 7 for p in e.llamadas())


def test_limitado_es_429_con_retry_after():
    r = Entorno({"resultado": "limitado"}).post(_m("error", codigo="x"))
    assert r.status_code == 429 and r.headers["retry-after"] == "300"
    assert r.json() == {"detail": "Demasiados errores reportados para esta alta; reintenta más tarde."}


# --- validación del cuerpo --------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "cuerpo",
    [
        {}, {"tipo": "usuario_creado"}, {"terminal_usuario_id": 77},
        {"terminal_usuario_id": 0, "tipo": "usuario_creado"},
        {"terminal_usuario_id": -1, "tipo": "usuario_creado"},
        {"terminal_usuario_id": 2**63, "tipo": "usuario_creado"},
        {"terminal_usuario_id": "77", "tipo": "usuario_creado"},
        {"terminal_usuario_id": 77.0, "tipo": "usuario_creado"},
        {"terminal_usuario_id": True, "tipo": "usuario_creado"},
        _m("asignado"), _m("reconsentido"), _m("baja_solicitada"), _m("USUARIO_CREADO"), _m(""),
        _m("huella_capturada"),                                   # falta el conteo
        _m("huella_capturada", huellas=0),
        _m("huella_capturada", huellas=11),
        _m("huella_capturada", huellas=-1),
        _m("huella_capturada", huellas="2"),
        _m("huella_capturada", huellas=2.0),
        _m("huella_capturada", huellas=True),
        _m("usuario_creado", huellas=1),                          # huellas prohibido fuera de huella_capturada
        _m("baja_confirmada", huellas=1),
        _m("error", huellas=1, codigo="x"),
        _m("error"),                                               # error sin código
        _m("error", codigo=""),
        _m("error", codigo="Con Mayusculas"),
        _m("error", codigo="con-guion"),
        _m("error", codigo="x" * 41),
        _m("usuario_creado", codigo="x"),                          # codigo/detalle prohibidos fuera de error
        _m("usuario_creado", detalle="x"),
        _m("huella_capturada", huellas=2, detalle="x"),
        _m("error", codigo="x", detalle="y" * 2001),
        _m("usuario_creado", employee_no=17),                      # el Pi no manda employee_no aquí
        _m("usuario_creado", persona_id="uuid"),
        _m("usuario_creado", terminal_id="otra"),
    ],
)
def test_cuerpo_invalido_es_422_fijo_sin_eco_y_no_llama_al_rpc(cuerpo):
    e = Entorno()
    r = e.post(cuerpo)
    assert r.status_code == 422 and r.json() == {"detail": "Los datos enviados no son válidos."}
    assert e.llamadas() == []


def test_sin_credencial_es_401():
    e = Entorno()
    assert e.post(_m(), llave=None).status_code == 401 and e.llamadas() == []


# --- saneo del detalle (M3 de security) ---------------------------------------------------------------------------------------------


def test_el_detalle_se_limpia_y_se_acota_a_500():
    sucio = "  hola\x00 \x07mundo\u200b  <b>negrita</b>\n\n\ttexto   final \u202e"
    assert sanear_detalle("err", sucio) == "err: hola mundo negrita texto final"
    largo = sanear_detalle("err", "a b " * 400)
    assert len(largo) == 500 and largo.startswith("err: a b a b")


def test_el_marcado_incompleto_tambien_se_quita():
    assert "<" not in sanear_detalle("e", "antes <script src=x") and "script" not in sanear_detalle("e", "antes <script src=x")


def test_nfkc_normaliza_ancho_completo_y_compatibilidad():
    assert sanear_detalle("e", "ｈｏｌａ") == "e: hola"


@pytest.mark.parametrize(
    "detalle",
    [
        "fingerData", "FINGERDATA", "{\"fingerData\": \"AAAA\"}", "FingerPrint", "fingerprintdata", "CaptureFingerPrint",
        "template", "TEMPLATE", "plantilla", "Plantilla de huella", "base64", "Base64:",
        "finger Data", "finger-data", "f i n g e r d a t a", "finger\u200bData", "fin\u00adger\u2060Data",
        "ｆｉｎｇｅｒＤａｔａ", "ﬁngerdata", "finger_Print", "temp late", "plan-tilla",
        "A" * 64, "a1b2" * 16, "0123456789abcdef" * 4, "x" * 200,
        "ok " + "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=" * 3,
        ("relleno " * 70) + "fingerData",                          # más allá de los 500: igual se juzga
    ],
)
def test_lo_que_huele_a_plantilla_o_carga_binaria_se_rechaza(detalle):
    with pytest.raises(DetalleProhibido):
        sanear_detalle("err", detalle)


@pytest.mark.parametrize(
    "detalle",
    ["el usuario ya existe en el aparato", "timeout al hablar con la terminal (5 s)", "http 409: conflict", "código 0x1f2e", "a" * 63],
)
def test_los_mensajes_normales_pasan(detalle):
    assert sanear_detalle("err", detalle).startswith("err")


def test_un_detalle_prohibido_es_422_y_no_llega_al_rpc():
    e = Entorno()
    r = e.post(_m("error", codigo="x", detalle='{"fingerData":"AAAA"}'))
    assert r.status_code == 422 and r.json() == {"detail": "El detalle contiene contenido no permitido."}
    assert e.llamadas() == [] and "AAAA" not in r.text


def test_el_codigo_tambien_se_juzga():
    e = Entorno()
    assert e.post(_m("error", codigo="fingerdata")).status_code == 422
    assert e.post(_m("error", codigo="plantilla_x")).status_code == 422
    assert e.llamadas() == []


# --- errores de la base --------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "error,estado",
    [
        (APIError({"code": "SCJ11", "hint": "transicion_invalida", "message": CRUDO}), 409),
        (APIError({"code": "22023", "hint": "huellas_invalidas", "message": CRUDO}), 422),
        (APIError({"code": "SCJ12", "hint": "terminal_no_valida", "message": CRUDO}), 401),
        (APIError({"code": "42501", "message": CRUDO}), 503),
        (APIError({"code": "PGRST202", "message": CRUDO}), 503),
        (APIError({"code": "XX999", "message": CRUDO}), 500),
        (ConnectionError(CRUDO), 503),
        (TimeoutError(CRUDO), 503),
    ],
)
def test_errores_con_estado_fijo_y_sin_texto_de_la_base(error, estado):
    r = Entorno(error=error).post(_m())
    assert r.status_code == estado and "7710" not in r.text


def test_el_409_pide_releer_la_cola_con_mensaje_fijo():
    r = Entorno(error=APIError({"code": "SCJ11", "message": CRUDO})).post(_m())
    assert r.json() == {"detail": "El movimiento no es válido para el estado actual del alta."}


@pytest.mark.parametrize(
    "respuesta",
    [None, [], "ok", {}, {"resultado": "rara"}, {"resultado": "registrado"}, {"resultado": "registrado", "estado": "inventado"},
     {"resultado": "ya_aplicado", "estado": None}, {"resultado": "registrado", "estado": "activo", "persona_id": "x"}],
)
def test_respuesta_rara_del_rpc_es_503(respuesta):
    e = Entorno()
    e.respuesta = respuesta
    # el fake devuelve `respuesta` tal cual; None se cuela como Resultado(None)
    r = e.post(_m())
    assert r.status_code == 503 or (respuesta == {"resultado": "registrado", "estado": "activo", "persona_id": "x"} and r.status_code == 200)
    assert "persona_id" not in r.text


# --- contrato con el DDL ----------------------------------------------------------------------------------------------------------------------


def _ddl(prefijo):
    return next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob(f"{prefijo}_*.sql")).read_text(encoding="utf-8")


def test_firma_tipos_y_resultados_del_rpc_coinciden_con_83_y_91():
    for sql in (_ddl("83"), _ddl("91")):
        assert re.search(r"fn_terminal_movimiento_registrar\(\s*p_terminal_id\s+bigint,\s*p_terminal_usuario_id\s+bigint,\s*p_tipo\s+text,\s*p_huellas\s+integer,\s*p_detalle\s+text", sql)
    sql = _ddl("91")
    assert "fn_terminal_movimiento_registrar(bigint, bigint, text, integer, text)" in sql and "TO service_role" in sql
    cuerpo = _ddl("83")
    for tipo in ("usuario_creado", "huella_capturada", "baja_confirmada", "error"):
        assert f"'{tipo}'" in cuerpo
    for res in ("registrado", "ya_aplicado", "no_encontrado", "limitado"):
        assert f"'{res}'" in sql or f"'{res}'" in cuerpo
    assert "c_tope_error_hora  constant integer := 20" in cuerpo


# --- bajos de security (B2/B4 de la revisión de B2-B3) -----------------------------------------------------------------------------


@pytest.mark.parametrize("sucio", ["x\ud800y", "\udc00inicio", "fin\udfff", "a𐀀b"])
def test_un_sustituto_suelto_en_el_detalle_no_llega_al_rpc(sucio):
    """Un sustituto no se puede codificar en UTF-8: llegaría al RPC como 22P05 y se perdería el reporte."""
    limpio = sanear_detalle("err", sucio)
    limpio.encode("utf-8")  # no levanta
    assert not any(0xD800 <= ord(c) <= 0xDFFF for c in limpio) and limpio.startswith("err")


def test_los_invisibles_del_filtro_estan_escritos_con_escapes_en_el_codigo():
    """B4: ningún carácter invisible literal en el fuente (se revisaría mal y podría ocultar texto)."""
    fuente = (Path(__file__).resolve().parents[1] / "app" / "detalle_terminal.py").read_text(encoding="utf-8")
    invisibles = [c for c in fuente if ord(c) in (0xAD, 0x61C, 0xFEFF) or 0x200B <= ord(c) <= 0x200F or 0x2028 <= ord(c) <= 0x202E
                  or 0x2060 <= ord(c) <= 0x2069 or ord(c) >= 0xE0000]
    assert invisibles == []
    barra = chr(92)
    assert barra + "u200b-" + barra + "u200f" in fuente and barra + "ufeff" in fuente


def test_el_detalle_con_sustituto_suelto_por_http_es_un_422_de_protocolo():
    """El envoltorio (Pydantic) ya rechaza una cadena no codificable en UTF-8: 422 fijo, sin eco; el saneo es la segunda barrera."""
    e = Entorno()
    r = e.cliente.post(
        "/api/terminal/movimientos",
        content=__import__("json").dumps(_m("error", codigo="x", detalle="a" + chr(0xD800) + "b"), ensure_ascii=True),
        headers={"Authorization": f"Bearer {LLAVE}", "Content-Type": "application/json"},
    )
    assert r.status_code == 422 and r.json() == {"detail": "Los datos enviados no son válidos."} and e.llamadas() == []


@pytest.mark.parametrize("codigo", ["huella_no_capturada", "usuario_ya_existe", "timeout_terminal", "sin_respuesta", "isapi_401"])
def test_los_codigos_neutros_pasan(codigo):
    """B3: el filtro también juzga `codigo`; los códigos del Pi deben ser neutros (sin los términos reservados)."""
    e = Entorno()
    assert e.post(_m("error", codigo=codigo)).status_code == 200


def test_el_contrato_publica_los_terminos_reservados():
    doc = (Path(__file__).resolve().parents[2] / "docs" / "07-procesos" / "CONTRATO_API_PUENTE_TERMINAL.md").read_text(encoding="utf-8")
    for termino in ("fingerprint", "fingerdata", "template", "plantilla", "base64"):
        assert f"`{termino}`" in doc, termino
