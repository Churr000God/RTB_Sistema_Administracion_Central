"""Prueba 14 del contrato del interruptor (opción B, solo pruebas): la ruta /api/terminal/marcas NO decide ni lee el interruptor de la activación por huella. La barrera vive en
fn_marca_terminal_registrar (98_), que lee fn_terminal_inferir_huella_estado() UNA vez por lote, dentro de la transacción, y falla cerrado. La ruta sólo relaya `modo_verificacion='huella'` (lista
blanca exacta) y delega SIEMPRE la decisión a la base: sin caché del estado, sin lectura propia (evita una ventana de desfase entre ruta y base) y sin registrar valores."""

import logging
import re
from pathlib import Path

import pytest

from app.routers import terminal as ruta_terminal
from test_terminal_marcas import LLAVE, _cuerpo, _evento, _ok, entorno  # noqa: F401  (fixture `entorno`)

DDL_98 = Path(__file__).resolve().parents[2] / "db" / "ddl" / "98_tiempo_marca_respeta_interruptor_huella.sql"
FUENTE_RUTA = Path(ruta_terminal.__file__).read_text(encoding="utf-8")
SECRETO = "valor-secreto-del-estado-7741"


def _con_huella(i=0, **extra):
    return _evento(i, modo_verificacion="huella", **extra)


def test_la_ruta_no_lee_el_estado_del_interruptor_ni_el_parametro(entorno):
    e = entorno(_ok(1))
    r = e.post(_cuerpo(1, eventos=[_con_huella()]))
    assert r.status_code == 200
    nombres = [c.args[0] for c in e.rpc.call_args_list]
    assert "fn_terminal_inferir_huella_estado" not in nombres and "fn_terminal_config_valor" not in nombres
    assert set(nombres) <= {"fn_terminal_autenticar", "fn_marca_terminal_registrar"}
    tablas = [c.args[0] for c in e.db.postgrest.schema.return_value.table.call_args_list]
    assert "parametro" not in tablas and "bitacora_config_terminal" not in tablas


def test_el_codigo_de_la_ruta_no_menciona_el_interruptor():
    for palabra in ("inferir_huella", "terminal_inferir", "interruptor", "fn_terminal_config_valor"):
        assert palabra not in FUENTE_RUTA, palabra


def test_la_ruta_siempre_relaya_el_modo_huella_y_deja_que_la_base_decida_en_cada_peticion(entorno):
    """Sin caché ni memoria: cada petición manda el mismo lote tal cual y es la base quien (no) activa. Dos peticiones seguidas = dos llamadas con modo huella."""
    e = entorno(_ok(1))
    for _ in range(3):
        assert e.post(_cuerpo(1, eventos=[_con_huella()])).status_code == 200
    llamadas = e.llamadas_marcas()
    assert len(llamadas) == 3
    assert all(l[1]["p_eventos"][0].get("modo_verificacion") == "huella" for l in llamadas)
    assert all(set(l[1]) == {"p_terminal_id", "p_eventos"} for l in llamadas)             # ninguna bandera del estado viaja a la base


def test_la_ruta_no_cambia_lo_que_manda_segun_respuestas_anteriores(entorno):
    """El estado del interruptor puede cambiar entre dos lotes (se enciende, se apaga): la ruta no recuerda nada. La respuesta de la base no altera el siguiente lote."""
    e = entorno(_ok(1))
    e.post(_cuerpo(1, eventos=[_con_huella()]))
    e.respuesta = {"momento_recepcion": "2026-10-09T16:00:00+00:00", "resultados": [{"indice": 0, "evento_id": _evento()["evento_id"], "estado": "duplicado"}]}
    e.post(_cuerpo(1, eventos=[_con_huella()]))
    e.post(_cuerpo(1, eventos=[_evento()]))
    modos = [l[1]["p_eventos"][0].get("modo_verificacion") for l in e.llamadas_marcas()]
    assert modos == ["huella", "huella", None]


@pytest.mark.parametrize("modo", ["Huella", "HUELLA", " huella", "huella ", "fingerprint", "huella\x00", 1, True, ["huella"], {"huella": 1}, None, "", "h" * 70])
def test_solo_la_cadena_exacta_huella_pasa_cualquier_otra_cosa_se_descarta_antes_de_la_base(entorno, modo):
    e = entorno(_ok(1))
    assert e.post(_cuerpo(1, eventos=[_evento(modo_verificacion=modo)])).status_code in (200, 422)
    for l in e.llamadas_marcas():
        assert "modo_verificacion" not in l[1]["p_eventos"][0]


def test_el_estado_ilegible_no_existe_para_la_ruta_la_falla_de_la_base_es_503_y_no_se_asume_nada(entorno):
    """Si la base falla al registrar (incluida su lectura del interruptor, que ella misma tolera), la ruta responde 503 y NO reintenta con otro modo ni recorta el lote por su cuenta."""
    from postgrest.exceptions import APIError

    e = entorno(error=APIError({"code": "XX000", "message": SECRETO}))
    r = e.post(_cuerpo(1, eventos=[_con_huella()]))
    assert r.status_code in (500, 503) and SECRETO not in r.text
    assert len(e.llamadas_marcas()) == 1


def test_la_ruta_no_registra_valores_del_lote_ni_del_estado(entorno, caplog):
    e = entorno(_ok(1))
    with caplog.at_level(logging.DEBUG):
        e.post(_cuerpo(1, eventos=[_con_huella(employee_no=424242)]))
    texto = caplog.text
    assert "424242" not in texto and "huella" not in texto.lower() and "inferir" not in texto.lower()


@pytest.mark.parametrize("codigo", ["XX000", "23505", "23514", "P0001", "SCJ99", None])
def test_los_errores_de_la_ruta_tampoco_registran_valores(entorno, caplog, codigo):
    """Hallazgo corregido: un APIError desconocido registraba su message/DETAIL (valores de la fila) vía logger.exception. Ahora solo el SQLSTATE; la respuesta sigue siendo el 500 genérico."""
    from postgrest.exceptions import APIError

    e = entorno(error=APIError({"code": codigo, "message": f"boom {SECRETO}", "details": f"Key (employee_no)=(424242) {SECRETO}", "hint": SECRETO}))
    with caplog.at_level(logging.DEBUG):
        r = e.post(_cuerpo(1, eventos=[_con_huella(employee_no=424242)]))
    assert r.status_code == 500 and r.json() == {"detail": "Error interno del servidor."}
    assert SECRETO not in caplog.text and "424242" not in caplog.text and "Traceback" not in caplog.text
    assert not any(rec.exc_info for rec in caplog.records if rec.name.startswith("app"))


@pytest.mark.parametrize("excepcion", ["httpx", "httpcore", "supabase", "postgrest"])
def test_las_excepciones_de_clientes_externos_se_registran_con_tipo_y_traza_sin_el_texto(entorno, caplog, excepcion):
    """Un httpx.ConnectError, etc. que escape de cualquier ruta: tipo y traza, jamás el mensaje (puede llevar la URL con parámetros o el cuerpo)."""
    import importlib

    if excepcion == "httpx":
        clase = importlib.import_module("httpx").ReadError
    elif excepcion == "httpcore":
        clase = importlib.import_module("httpcore").ReadError
    elif excepcion == "postgrest":
        clase = importlib.import_module("postgrest.exceptions").APIError
    else:
        pytest.skip("sin excepción pública estable de supabase en esta versión")
    from app.main import registrar_excepcion_no_capturada
    from types import SimpleNamespace

    peticion = SimpleNamespace(method="POST", scope={"route": SimpleNamespace(path="/api/terminal/marcas")}, url=SimpleNamespace(path="/api/terminal/marcas?x=1"), headers={})
    try:
        raise clase({"code": "X", "message": SECRETO}) if excepcion == "postgrest" else clase(f"fallo con {SECRETO}")
    except Exception as error:  # noqa: BLE001
        with caplog.at_level(logging.DEBUG):
            registrar_excepcion_no_capturada(peticion, error)
    assert SECRETO not in caplog.text and "/api/terminal/marcas" in caplog.text and "?x=1" not in caplog.text


def test_la_traza_sin_mensaje_no_incluye_el_texto_de_la_excepcion_ni_el_de_su_causa():
    from app.main import traza_sin_mensaje

    try:
        try:
            raise ConnectionError(f"causa con {SECRETO}")
        except ConnectionError as causa:
            raise RuntimeError(f"principal con {SECRETO}") from causa
    except RuntimeError as error:
        texto = traza_sin_mensaje(error)
    assert SECRETO not in texto and "RuntimeError" in texto and "test_la_traza_sin_mensaje" in texto


@pytest.mark.parametrize("codigo", ["PGRST202", "PGRST204", "PGRST205", "42P01"])
def test_una_migracion_sin_aplicar_sigue_siendo_503_con_mensaje_fijo_y_sin_texto_de_la_base(entorno, caplog, codigo):
    from postgrest.exceptions import APIError

    e = entorno(error=APIError({"code": codigo, "message": f"boom {SECRETO}"}))
    with caplog.at_level(logging.DEBUG):
        r = e.post(_cuerpo(1, eventos=[_con_huella()]))
    assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible. Avisa a Sistemas."} and SECRETO not in caplog.text + r.text


@pytest.mark.parametrize("codigo,http", [("42501", 503), ("22023", 422), ("22P02", 422)])
def test_los_codigos_que_el_puente_ya_consume_no_cambian(entorno, codigo, http):
    from postgrest.exceptions import APIError

    r = entorno(error=APIError({"code": codigo, "message": SECRETO})).post(_cuerpo(1, eventos=[_con_huella()]))
    assert r.status_code == http and SECRETO not in r.text


def test_el_manejador_global_no_registra_el_texto_de_un_apierror_de_ninguna_ruta(caplog):
    """Cualquier router que deje escapar un APIError: el log lleva solo el SQLSTATE."""
    import asyncio
    from types import SimpleNamespace

    from postgrest.exceptions import APIError

    from app.main import manejador_excepciones_no_capturadas

    peticion = SimpleNamespace(method="POST", scope={}, url=SimpleNamespace(path="/api/x"), headers={})
    with caplog.at_level(logging.DEBUG):
        r = asyncio.run(manejador_excepciones_no_capturadas(peticion, APIError({"code": "23505", "message": SECRETO, "details": SECRETO + "-d", "hint": SECRETO + "-h"})))
    assert r.status_code == 500 and SECRETO not in caplog.text and "23505" in caplog.text


# --- contrato sobre 98_: la barrera vive en el RPC ---------------------------------------------------------------------------------------------------------------


def test_98_lee_el_estado_efectivo_una_vez_por_lote_antes_del_bucle_y_con_la_unica_definicion():
    sql = DDL_98.read_text(encoding="utf-8")
    lectura = "v_inferir := COALESCE((tiempo.fn_terminal_inferir_huella_estado() ->> 'activo')::boolean, false);"
    assert sql.count(lectura) == 1                                                       # UNA sola lectura
    assert sql.index(lectura) < sql.index("FOR ")                                        # antes de recorrer los eventos del lote (no una lectura por evento)
    assert "fn_terminal_config_valor" not in re.sub(r"--.*", "", sql)                    # sin el lector tolerante (acota el valor: leería '7' como 1) fuera de comentarios
    assert "v_inferir        boolean := false;" in sql                                   # apagado por omisión


def test_98_falla_cerrado_ante_cualquier_error_de_lectura_y_solo_registra_sqlstate():
    sql = DDL_98.read_text(encoding="utf-8")
    bloque = sql[sql.index("BEGIN\n    v_inferir"):]
    bloque = bloque[: bloque.index("END;") + 4]
    assert "EXCEPTION WHEN OTHERS THEN" in bloque and "v_inferir := false;" in bloque
    assert "RAISE WARNING" in bloque and "sqlstate=%" in bloque and "SQLSTATE" in bloque
    assert "SQLERRM" not in bloque                                                       # nunca el texto del error


def test_98_la_activacion_exige_v_inferir_ademas_del_modo_huella_y_el_alta_esperando():
    sql = DDL_98.read_text(encoding="utf-8")
    condicion = sql[sql.index("IF v_estado IN ('confirmado', 'duplicado')"):]
    condicion = condicion[: condicion.index("THEN")]
    assert "AND v_inferir" in condicion and "v_modo = 'huella'" in condicion and "v_estado_alta = 'esperando_huella'" in condicion
    assert re.sub(r"--.*", "", sql).count("AND v_inferir") == 1                                               # un solo punto de activación; no hay otra rama que active sin el interruptor


def test_98_apagado_no_cambia_la_respuesta_al_puente():
    """Documentado en el propio archivo: con el interruptor apagado la marca se registra y se responde EXACTAMENTE igual; el lote nunca se rechaza por esto."""
    sql = DDL_98.read_text(encoding="utf-8")
    assert "la marca se registra y se responde exactamente igual" in sql.lower() or "se registra y se\n-- responde exactamente igual" in sql.lower().replace("  ", " ")
