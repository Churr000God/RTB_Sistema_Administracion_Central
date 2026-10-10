"""Interruptor de la activación por huella: bordes y huecos que la mutación manual dejó al descubierto en test_interruptor_huella.py (reutiliza su fixture `entorno` y sus ayudantes).
Cada prueba mata al menos un mutante que sobrevivía. Mocks por nombre de tabla; NUNCA contra la base real."""

import asyncio
import logging
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import tabla
from app import interruptor_huella as ih
from app import precondiciones
from app.errores import MENSAJE_INTERRUPTOR_HASTA, traducir_error_interruptor_huella
from app.main import app, registrar_excepcion_no_capturada
from app.precondiciones import PrecondicionNoVerificable, faltantes
from app.registro_seguro import tiene_mensaje_registrable, traza_sin_mensaje
from app.routers import interruptor_huella as router_ih
from test_interruptor_huella import (  # noqa: F401  (entorno es un fixture)
    AUTH, AUTOR, ENCENDIDO, FECHA_OK, HASTA_BASE, NOTA, RUTA, _estado, _get, _llamadas_cambiar, _post, _rpc_cambiar, entorno,
)


def _renovar(cuerpo_extra=None, **cambios):
    cuerpo = {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE} | cambios
    return _post("/renovar", cuerpo | (cuerpo_extra or {}))


# --- 1. renovar valida la fecha contra el rango (no sólo encender) ------------------------------------------------------------------------------------


@pytest.mark.parametrize("fecha", ["2026-10-11", "2026-11-11"])
def test_renovar_con_una_fecha_fuera_de_rango_es_422_hasta_invalido_sin_llamar_a_la_base(entorno, fecha):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    r = _renovar(hasta_fecha=fecha)
    assert r.status_code == 422 and r.json() == {"detail": MENSAJE_INTERRUPTOR_HASTA, "codigo": "hasta_invalido"}
    assert not _llamadas_cambiar(entorno)


@pytest.mark.parametrize("fecha", ["2026-10-12", "2026-11-10"])
def test_renovar_acepta_la_fecha_minima_y_la_maxima(entorno, fecha):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    assert _renovar(hasta_fecha=fecha).status_code == 200


# --- 2. nota_repetida compara con la ÚLTIMA nota REAL ----------------------------------------------------------------------------------------------------


def test_la_nota_anterior_se_busca_entre_las_filas_con_nota_y_la_mas_reciente(entorno):
    bitacora = tabla([{"nota": "Una nota anterior totalmente distinta"}])
    entorno.configurar(bitacora_config_terminal=bitacora)
    _rpc_cambiar(entorno)
    assert _renovar().status_code == 200
    bitacora.select.assert_called_with("nota")
    bitacora.is_.assert_called_with("nota", "null")          # un apagado sin nota no puede ser «la última nota»
    bitacora.order.assert_called_with("id", desc=True)       # la más reciente, no la primera
    bitacora.limit.assert_called_with(1)


def test_la_nota_anterior_se_lee_con_el_cliente_de_servicio_y_nunca_se_devuelve(entorno):
    entorno.configurar(bitacora_config_terminal=tabla([{"nota": "Nota previa que no debe salir en la respuesta"}]))
    _rpc_cambiar(entorno)
    r = _renovar()
    assert "Nota previa" not in r.text and not [c for c in entorno.caller_db.postgrest.schema.return_value.table.call_args_list if c.args == ("bitacora_config_terminal",)]


# --- 3. la alarma de «cambio fuera de la función»/«sin registro» exige el interruptor ENCENDIDO ------------------------------------------------------------


@pytest.mark.parametrize("estado", [
    _estado(ultimo_cambio_via_funcion=False),
    _estado(sin_registro=True),
    _estado(vencido=True, motivo="vencido", valor="1", hasta="2026-10-01T05:59:59Z", ultimo_cambio_via_funcion=False, sin_registro=True),
])
def test_un_interruptor_apagado_o_vencido_no_alarma_por_via_funcion_ni_por_sin_registro(estado):
    assert ih.alarma_de(estado) == {"activa": False, "nivel": None, "codigo": None, "mensaje": None}


# --- 4. rango de fechas: bordes exactos de la holgura de 60 s ---------------------------------------------------------------------------------------------


FIN_HOY = ih.instante_de_fecha(date(2026, 10, 12))                      # 2026-10-13T05:59:59Z


@pytest.mark.parametrize("delta,minima", [(-61, date(2026, 10, 12)), (-60, date(2026, 10, 13)), (-59, date(2026, 10, 13))])
def test_la_fecha_minima_es_hoy_solo_si_faltan_mas_de_60_s_para_su_23_59_59(delta, minima):
    assert ih.rango_de_fechas(FIN_HOY + timedelta(seconds=delta))[0] == minima


FIN_MAXIMA = ih.instante_de_fecha(date(2026, 11, 10))


@pytest.mark.parametrize("delta,maxima", [(-1, date(2026, 11, 9)), (0, date(2026, 11, 10)), (1, date(2026, 11, 10))])
def test_la_fecha_maxima_incluye_el_dia_cuyo_23_59_59_cae_justo_en_el_limite(delta, maxima):
    ahora = FIN_MAXIMA - timedelta(days=30) + timedelta(seconds=60 + delta)
    assert ih.rango_de_fechas(ahora)[1] == maxima


# --- 5. middleware no-store ---------------------------------------------------------------------------------------------------------------------------------


def _pasar_por_el_middleware(scope, cabeceras_de_la_app):
    recibidos = []

    async def app_(sc, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": cabeceras_de_la_app})
        await send({"type": "http.response.body", "body": b""})

    async def enviar(mensaje):
        recibidos.append(mensaje)

    asyncio.run(ih.SinCacheInterruptor(app_)(scope, None, enviar))
    return recibidos


def test_no_store_reemplaza_una_cabecera_previa_en_vez_de_duplicarla():
    enviados = _pasar_por_el_middleware({"type": "http", "path": RUTA + "/historial"}, [(b"Cache-Control", b"max-age=3600"), (b"PRAGMA", b"public"), (b"x-otro", b"1")])
    cabeceras = enviados[0]["headers"]
    assert [v for k, v in cabeceras if k.lower() == b"cache-control"] == [b"no-store"]
    assert [v for k, v in cabeceras if k.lower() == b"pragma"] == [b"no-cache"]
    assert (b"x-otro", b"1") in cabeceras


def test_fuera_del_prefijo_las_cabeceras_quedan_tal_cual():
    original = [(b"cache-control", b"max-age=60")]
    assert _pasar_por_el_middleware({"type": "http", "path": "/api/otra-cosa"}, original)[0]["headers"] == original


def test_un_scope_que_no_es_http_pasa_de_largo_sin_leer_path():
    vistos = []

    async def app_(scope, receive, send):
        vistos.append(scope)

    asyncio.run(ih.SinCacheInterruptor(app_)({"type": "lifespan"}, None, None))       # un scope lifespan no trae `path`
    assert vistos == [{"type": "lifespan"}]


# --- 6/7. cuerpos cerrados, apagar y sus bordes de nota -----------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("ruta,cuerpo", [
    ("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK, "extra": 1}),
    ("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE, "extra": 1}),
    ("/apagar", {"nota": NOTA, "extra": 1}),
])
def test_una_clave_de_mas_es_422_cuerpo_invalido_sin_eco_y_sin_llamar_a_la_base(entorno, ruta, cuerpo):
    entorno.estado = _estado()
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    r = _post(ruta, cuerpo)
    assert r.status_code == 422 and set(r.json()) == {"detail", "codigo"} and r.json()["codigo"] == "cuerpo_invalido" and "extra" not in r.text
    assert not _llamadas_cambiar(entorno)


@pytest.mark.parametrize("largo,http", [(500, 200), (501, 422)])
def test_apagar_acepta_500_caracteres_de_nota_y_rechaza_501(entorno, largo, http):
    entorno.configurar()
    _rpc_cambiar(entorno, {"resultado": "actualizada", "estado": _estado()})
    r = _post("/apagar", {"nota": "a" * largo})
    assert r.status_code == http
    if http == 422:
        assert r.json()["codigo"] == "nota_invalida" and not _llamadas_cambiar(entorno)


def test_apagar_con_una_nota_de_solo_espacios_manda_p_nota_nulo_no_vacio(entorno):
    entorno.configurar()
    _rpc_cambiar(entorno, {"resultado": "actualizada", "estado": _estado()})
    assert _post("/apagar", {"nota": "     \t "}).status_code == 200
    assert [c.args[1]["p_nota"] for c in _llamadas_cambiar(entorno)] == [None]


# --- 8. 422 por campo: hasta_base y precedencia ---------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("cuerpo", [
    {"nota": NOTA, "hasta_fecha": FECHA_OK},                                       # falta hasta_base
    {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": 5},                      # no es texto
    {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": None},
])
def test_renovar_sin_hasta_base_valido_es_422_hasta_invalido(entorno, cuerpo):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    r = _post("/renovar", cuerpo)
    assert r.status_code == 422 and r.json()["codigo"] == "hasta_invalido" and not _llamadas_cambiar(entorno)


def test_si_fallan_la_nota_y_la_fecha_a_la_vez_gana_la_nota(entorno):
    entorno.configurar()
    r = _post("/encender", {"nota": "corta", "hasta_fecha": "no-es-fecha"})
    assert r.status_code == 422 and r.json()["codigo"] == "nota_requerida"


def test_una_fecha_malformada_sola_es_hasta_invalido(entorno):
    entorno.configurar()
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": "no-es-fecha"})
    assert r.status_code == 422 and r.json()["codigo"] == "hasta_invalido"


# --- 9. hasta_base: precisión de un segundo y estado sin hasta -----------------------------------------------------------------------------------------------------


def test_el_hasta_guardado_con_fraccion_coincide_con_el_hasta_base_sin_fraccion(entorno):
    entorno.estado = ENCENDIDO | {"hasta": "2026-11-03T05:59:59.500000Z"}
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    assert _renovar(hasta_base="2026-11-03T05:59:59Z").status_code == 200


def test_renovar_con_el_estado_encendido_pero_sin_hasta_es_409_desactualizado_no_500(entorno):
    entorno.estado = ENCENDIDO | {"hasta": None}
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    r = _renovar()
    assert r.status_code == 409 and r.json()["codigo"] == "estado_desactualizado" and not _llamadas_cambiar(entorno)


def test_mismo_instante_exige_ambos_instantes():
    assert ih.mismo_instante(None, datetime(2026, 1, 1, tzinfo=timezone.utc)) is False
    assert ih.mismo_instante(datetime(2026, 1, 1, tzinfo=timezone.utc), None) is False
    assert ih.mismo_instante(None, None) is False
    assert ih.mismo_instante(datetime(2026, 1, 1, 0, 0, 0, 900000, tzinfo=timezone.utc), datetime(2026, 1, 1, 0, 0, 0, 100000, tzinfo=timezone.utc)) is True


# --- 10. requisitos informativos -----------------------------------------------------------------------------------------------------------------------------------


def test_sin_ninguna_fila_de_consentimiento_el_requisito_es_falso_no_null(entorno):
    entorno.configurar(terminal_consentimiento=tabla([]))
    assert _get().json()["requisitos"]["consentimiento_publicado"] is False


def test_los_requisitos_leen_la_ultima_version_del_consentimiento_y_solo_terminales_activas(entorno):
    consentimiento, terminal = tabla([{"provisional": False}]), tabla([{"id": 1}])
    entorno.configurar(terminal_consentimiento=consentimiento, terminal=terminal)
    _get()
    consentimiento.order.assert_called_with("version", desc=True)
    consentimiento.limit.assert_called_with(1)
    terminal.eq.assert_called_with("activa", True)


def test_el_consentimiento_definitivo_es_provisional_falso_exacto(entorno):
    for fila, esperado in (({"provisional": False}, True), ({"provisional": True}, False), ({"provisional": None}, False), ({}, False)):
        entorno.configurar(terminal_consentimiento=tabla([fila]))
        assert _get().json()["requisitos"]["consentimiento_publicado"] is esperado


# --- 11. historial -------------------------------------------------------------------------------------------------------------------------------------------------


COLUMNAS_SEGURAS = "id, creado_en, clave, operacion, valor_anterior, valor_nuevo, nota, registrado_por, via_funcion"


def _pedir_historial(entorno, consulta="", tabla_historial=None):
    entorno.configurar()
    historial = tabla_historial or tabla([])
    entorno.caller_db.postgrest.schema.return_value.table.side_effect = lambda n: historial if n == "bitacora_config_terminal" else tabla([])
    return TestClient(app, raise_server_exceptions=False).get(RUTA + "/historial" + consulta, headers=AUTH), historial


def test_el_historial_pide_exactamente_las_columnas_seguras_y_nunca_todas(entorno):
    r, historial = _pedir_historial(entorno)
    assert r.status_code == 200
    historial.select.assert_called_with(COLUMNAS_SEGURAS)
    assert router_ih.COLUMNAS_HISTORIAL == COLUMNAS_SEGURAS and "*" not in COLUMNAS_SEGURAS


def test_el_limite_por_omision_del_historial_es_50_y_el_maximo_100(entorno):
    _, historial = _pedir_historial(entorno)
    historial.limit.assert_called_with(50)
    _, historial = _pedir_historial(entorno, "?limite=100")
    historial.limit.assert_called_with(100)
    _, historial = _pedir_historial(entorno, "?limite=1")
    historial.limit.assert_called_with(1)


def test_una_migracion_sin_aplicar_en_el_historial_es_503_del_handler_global(entorno):
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "42P01", "message": "relation does not exist"})
    r, _ = _pedir_historial(entorno, tabla_historial=roto)
    assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible. Avisa a Sistemas."}


# --- 12. nombre y conteo -----------------------------------------------------------------------------------------------------------------------------------------------


def test_sin_autor_registrado_no_se_consulta_a_nadie_y_el_nombre_es_null(entorno):
    entorno.estado = ENCENDIDO | {"encendido_por": None}
    entorno.configurar()
    r = _get()
    assert r.status_code == 200 and r.json()["encendido_por_nombre"] is None
    assert not entorno.caller_db.postgrest.schema.called


@pytest.mark.parametrize("conteo,esperado", [(0, 0), (7, 7), (-1, None), (True, None), (None, None)])
def test_el_conteo_de_activaciones_es_un_entero_no_negativo_o_null(entorno, conteo, esperado):
    entorno.configurar(bitacora_movimiento_terminal_usuario=tabla([], count=conteo))
    assert _get().json()["altas_activadas_desde_encendido"] == esperado


def test_un_interruptor_vencido_no_consulta_el_conteo(entorno):
    entorno.estado = _estado(motivo="vencido", vencido=True, valor="1", hasta="2026-10-01T05:59:59Z", encendido_en="2026-09-20T10:00:00Z")
    conteo = tabla([], count=5)
    entorno.configurar(bitacora_movimiento_terminal_usuario=conteo)
    assert _get().json()["altas_activadas_desde_encendido"] is None
    conteo.select.assert_not_called()


# --- 13. errores de la base y precondiciones ----------------------------------------------------------------------------------------------------------------------------


def test_scj16_con_otro_hint_no_se_traduce_como_falta_de_consentimiento():
    assert traducir_error_interruptor_huella(APIError({"code": "SCJ16", "message": "x", "hint": "otra_cosa"})) is None
    assert traducir_error_interruptor_huella(APIError({"code": "SCJ16", "message": "x"})) is None


def test_un_42501_sin_hint_es_403_y_deja_un_error_en_el_log_pero_con_hint_no(caplog):
    with caplog.at_level(logging.ERROR):
        sin_hint = traducir_error_interruptor_huella(APIError({"code": "42501", "message": "x"}))
    assert sin_hint.status_code == 403 and "42501 sin hint" in caplog.text
    caplog.clear()
    with caplog.at_level(logging.ERROR):
        con_hint = traducir_error_interruptor_huella(APIError({"code": "42501", "message": "x", "hint": "sin_permiso"}))
    assert con_hint.status_code == 403 and "42501 sin hint" not in caplog.text


def _cliente_con_funciones(codigo_cambiar, codigo_estado=None):
    cliente = MagicMock()

    def rpc(nombre, params):
        r = MagicMock()
        codigo = codigo_cambiar if nombre.endswith("cambiar") else codigo_estado
        if codigo:
            r.execute.side_effect = APIError({"code": codigo, "message": "x"})
        return r

    cliente.postgrest.schema.return_value.rpc.side_effect = rpc
    return cliente


@pytest.mark.parametrize("codigo", ["22023", "42501"])
def test_la_funcion_de_cambio_que_responde_22023_o_42501_existe(codigo):
    assert faltantes(_cliente_con_funciones(codigo)) == []


def test_la_funcion_inexistente_es_un_faltante_y_otro_codigo_no_es_verificable():
    perdidas = faltantes(_cliente_con_funciones("PGRST202"))
    assert [(p[1], p[2]) for p in perdidas] == [("fn_terminal_inferir_huella_cambiar", "función")]
    with pytest.raises(PrecondicionNoVerificable):
        faltantes(_cliente_con_funciones("XX999"))


# --- 14. normalización del estado de la base ----------------------------------------------------------------------------------------------------------------------------


def test_un_apagado_sin_motivo_o_un_encendido_con_motivo_no_se_normalizan():
    assert ih.normalizar_estado(_estado(motivo=None)) is None
    assert ih.normalizar_estado(_estado(motivo="")) is None
    assert ih.normalizar_estado(_estado(activo=True)) is None


def test_un_hasta_de_1970_es_el_centinela_aunque_el_interruptor_este_encendido():
    estado = ih.construir_estado(ENCENDIDO | {"hasta": "1970-06-01T12:00:00Z"}, nombre_autor=None, altas_activadas=None, requisitos={}, ahora=datetime(2026, 10, 12, 18, tzinfo=timezone.utc))
    assert estado["hasta"] is None and estado["hasta_fecha"] is None


# --- 15. registro seguro de excepciones ------------------------------------------------------------------------------------------------------------------------------------


SECRETO = "dato-de-la-peticion-reconocible-7741"


def _peticion():
    return SimpleNamespace(method="POST", scope={"route": SimpleNamespace(path="/api/x")}, url=SimpleNamespace(path="/api/x"), headers={})


class _Propia(Exception):
    mensaje_registrable = True


def _registrar(excepcion, caplog):
    try:
        raise excepcion
    except Exception as capturada:  # noqa: BLE001
        with caplog.at_level(logging.DEBUG):
            registrar_excepcion_no_capturada(_peticion(), capturada)


def test_una_excepcion_propia_que_lo_declara_si_registra_su_mensaje(caplog):
    _registrar(_Propia("texto escrito por este mismo código"), caplog)
    assert "texto escrito por este mismo código" in caplog.text and "Excepción propia no capturada" in caplog.text


def test_el_atributo_en_la_instancia_no_autoriza_a_registrar_el_mensaje(caplog):
    error = ValueError(SECRETO)
    error.mensaje_registrable = True
    assert tiene_mensaje_registrable(error) is False
    _registrar(error, caplog)
    assert SECRETO not in caplog.text


@pytest.mark.parametrize("valor", [1, "si", object(), None])
def test_solo_true_exacto_en_la_clase_cuenta_como_mensaje_registrable(valor):
    clase = type("Rara", (Exception,), {"mensaje_registrable": valor})
    assert tiene_mensaje_registrable(clase("x")) is False


def test_la_traza_sin_mensaje_lleva_el_modulo_y_el_nombre_del_tipo_pero_no_el_texto():
    try:
        raise ValueError(SECRETO)
    except ValueError as error:
        traza = traza_sin_mensaje(error)
    assert traza.splitlines()[0] == "builtins.ValueError" and SECRETO not in traza and "test_interruptor_huella_bordes" in traza
