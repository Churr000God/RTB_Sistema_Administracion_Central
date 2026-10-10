"""Interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md), parte 1: lógica pura, estado (GET) y cabeceras. Mocks por NOMBRE de tabla; NUNCA contra la base real."""

import logging
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, db_por_nombre, tabla
from app import interruptor_huella as ih
from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers import interruptor_huella as router_ih

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
AUTOR = "aaaaaaaa-1111-2222-3333-444444444444"
RUTA = ih.PREFIJO
AHORA = datetime(2026, 10, 12, 18, 0, 0, tzinfo=timezone.utc)      # 12:00 en México
MX = ih.ZONA_MEXICO


def _estado(**cambios):
    base = {"activo": False, "vencido": False, "motivo": "apagado", "valor": "0", "hasta": "1970-01-01T00:00:00Z", "encendido_por": None, "encendido_en": None,
            "ultimo_cambio_via_funcion": None, "sin_registro": False}
    return base | cambios


ENCENDIDO = _estado(activo=True, motivo=None, valor="1", hasta="2026-11-03T05:59:59Z", encendido_por=AUTOR, encendido_en="2026-10-12T16:03:11Z", ultimo_cambio_via_funcion=True)


# --- rango de fechas y «activo hasta» ----------------------------------------------------------------------------------------------------


def test_una_fecha_vence_a_las_23_59_59_de_mexico():
    assert ih.instante_de_fecha(date(2026, 11, 2)) == datetime(2026, 11, 3, 5, 59, 59, tzinfo=timezone.utc)


@pytest.mark.parametrize("ahora,minima,maxima", [
    (datetime(2026, 10, 12, 18, 0, tzinfo=timezone.utc), date(2026, 10, 12), date(2026, 11, 10)),      # 12:00 MX: el límite cae a las 12:00 MX del 11-11; el día completo más cercano es el 11-10
    (datetime(2026, 10, 13, 5, 58, 0, tzinfo=timezone.utc), date(2026, 10, 12), date(2026, 11, 10)),   # 23:58:00 MX del 12: faltan 119 s para su 23:59:59 -> aún se puede elegir hoy
    (datetime(2026, 10, 13, 5, 57, 30, tzinfo=timezone.utc), date(2026, 10, 12), date(2026, 11, 10)),
    (datetime(2026, 10, 13, 5, 59, 0, tzinfo=timezone.utc), date(2026, 10, 13), date(2026, 11, 10)),   # 23:59:00 MX del 12: quedan 59 s < holgura de 60 s -> mañana
    (datetime(2026, 10, 13, 5, 59, 59, tzinfo=timezone.utc), date(2026, 10, 13), date(2026, 11, 10)),
])
def test_rango_de_fechas_con_holgura_de_60_s(ahora, minima, maxima):
    assert ih.rango_de_fechas(ahora) == (minima, maxima)


def test_la_fecha_maxima_nunca_pasa_el_tope_de_30_dias_de_la_base_en_ninguna_hora_del_dia():
    for minuto in range(0, 24 * 60, 7):
        ahora = datetime(2026, 10, 12, 0, 0, tzinfo=timezone.utc) + timedelta(minutes=minuto)
        minima, maxima = ih.rango_de_fechas(ahora)
        assert ih.instante_de_fecha(maxima) <= ahora + timedelta(days=30) - timedelta(seconds=ih.MARGEN_S)
        assert ih.instante_de_fecha(maxima + timedelta(days=1)) > ahora + timedelta(days=30) - timedelta(seconds=ih.MARGEN_S)
        assert ih.instante_de_fecha(minima) > ahora + timedelta(seconds=ih.MARGEN_S)
        assert ih.fecha_valida(minima, ahora) and ih.fecha_valida(maxima, ahora)
        assert not ih.fecha_valida(minima - timedelta(days=1), ahora) and not ih.fecha_valida(maxima + timedelta(days=1), ahora)


# --- alarma (función pura) ----------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("estado,nivel,codigo", [
    (_estado(), None, None),
    (_estado(activo=False, vencido=True, motivo="vencido", valor="1", hasta="2026-10-01T00:00:00Z"), None, None),
    (ENCENDIDO, None, None),
    (_estado(motivo="sin_respaldo_de_la_funcion", valor="1", hasta="2026-11-03T05:59:59Z"), "atender", "sin_respaldo_de_la_funcion"),
    (ENCENDIDO | {"ultimo_cambio_via_funcion": False}, "atender", "cambio_fuera_de_la_funcion"),
    (ENCENDIDO | {"sin_registro": True, "ultimo_cambio_via_funcion": None}, "atender", "sin_registro"),
    (_estado(motivo="vigencias_inconsistentes"), "revisar", "vigencias_inconsistentes"),
    (_estado(motivo="valor_invalido", valor="7"), "revisar", "valor_invalido"),
    (_estado(motivo="hasta_ilegible", valor="1"), "revisar", "hasta_ilegible"),
    (_estado(motivo="hasta_excede_tope", valor="1"), "revisar", "hasta_excede_tope"),
    (_estado(motivo="error"), "revisar", "error"),
    (_estado(motivo="algo_nuevo"), "revisar", "estado_ilegible"),         # un motivo desconocido nunca es silencio
])
def test_tabla_de_verdad_de_la_alarma(estado, nivel, codigo):
    a = ih.alarma_de(estado)
    assert (a["nivel"], a["codigo"]) == (nivel, codigo) and a["activa"] is (nivel is not None)
    if nivel:
        assert a["mensaje"] and "Sistemas" in a["mensaje"]
        assert not any(c.isdigit() for c in a["mensaje"])               # texto fijo, sin valores


@pytest.mark.parametrize("ilegible", [None, [], "texto", 7, {}, {"activo": True}, {"activo": "si", "vencido": False, "motivo": None, "sin_registro": False}, _estado(activo=True),
                                       _estado(motivo=None), ENCENDIDO | {"ultimo_cambio_via_funcion": "si"}, _estado(hasta=7)])
def test_un_estado_ilegible_es_alarma_revisar_nunca_sin_alarma(ilegible):
    a = ih.alarma_de(ilegible)
    assert a == {"activa": True, "nivel": "revisar", "codigo": "estado_ilegible", "mensaje": ih.MENSAJE_ESTADO_ILEGIBLE}


def test_la_alarma_no_depende_del_conteo_ni_de_nombres():
    assert ih.alarma_de(ENCENDIDO | {"altas_activadas": 9999, "nombre": "Ana"}) == ih.alarma_de(ENCENDIDO)
    import inspect
    fuente = inspect.getsource(ih.alarma_de)
    assert not any(campo in fuente for campo in ("altas_activadas", "nombre_autor", "encendido_por", "encendido_en"))


# --- forma pública del estado ---------------------------------------------------------------------------------------------------------------


def _construir(crudo, **kw):
    kw.setdefault("nombre_autor", None)
    kw.setdefault("altas_activadas", None)
    kw.setdefault("requisitos", {})
    return ih.construir_estado(crudo, ahora=AHORA, **kw)


def test_apagado_no_expone_el_centinela_ni_el_autor():
    e = _construir(_estado())
    assert (e["estado"], e["activo"], e["hasta"], e["hasta_fecha"], e["mensaje"], e["encendido_por_nombre"], e["altas_activadas_desde_encendido"]) == ("apagado", False, None, None, None, None, None)
    assert "1970" not in str(e)


def test_encendido_expone_hasta_como_instante_y_como_fecha_de_mexico():
    e = _construir(ENCENDIDO, nombre_autor="Carlos Ruiz", altas_activadas=7)
    assert (e["estado"], e["hasta"], e["hasta_fecha"], e["encendido_en"], e["encendido_por_nombre"], e["altas_activadas_desde_encendido"]) == (
        "encendido", "2026-11-03T05:59:59Z", "2026-11-02", "2026-10-12T16:03:11Z", "Carlos Ruiz", 7)
    assert (e["fecha_minima"], e["fecha_maxima"], e["maximo_dias"], e["nota_minimo"], e["nota_maximo"]) == ("2026-10-12", "2026-11-10", 30, 10, 500)
    assert AUTOR not in str(e)


def test_vencido_conserva_la_fecha_vencida_y_sin_conteo():
    e = _construir(_estado(motivo="vencido", vencido=True, valor="1", hasta="2026-10-01T05:59:59Z", encendido_en="2026-09-20T10:00:00Z"), altas_activadas=3)
    assert (e["estado"], e["vencido"], e["hasta"], e["hasta_fecha"], e["altas_activadas_desde_encendido"]) == ("vencido", True, "2026-10-01T05:59:59Z", "2026-09-30", None)
    assert e["mensaje"] == ih.MENSAJES_MOTIVO["vencido"]


@pytest.mark.parametrize("motivo", sorted(ih.MOTIVOS_FALLA_CERRADA | {"sin_respaldo_de_la_funcion"}))
def test_los_motivos_de_falla_cerrada_son_inconsistentes_con_mensaje_fijo_y_sin_fecha(motivo):
    e = _construir(_estado(motivo=motivo, valor="1", hasta="2026-11-03T05:59:59Z"))
    assert (e["estado"], e["activo"], e["hasta"], e["mensaje"]) == ("inconsistente", False, None, ih.MENSAJES_MOTIVO[motivo]) and "Sistemas" in e["mensaje"]


def test_sin_encendido_en_no_hay_conteo_aunque_este_encendido():
    assert _construir(ENCENDIDO | {"encendido_en": None, "sin_registro": True}, altas_activadas=5)["altas_activadas_desde_encendido"] is None


def test_un_estado_ilegible_no_se_construye():
    assert _construir({"activo": True}) is None and _construir(None) is None


# --- GET: gates, nombres, conteo, requisitos y 503 ---------------------------------------------------------------------------------------------


@pytest.fixture
def entorno(monkeypatch):
    entorno.codigos = {"terminal_config_edicion"}
    entorno.estado = ENCENDIDO
    entorno.conteo = 7
    entorno.llamadas = []
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona, *codigos: bool(set(codigos) & entorno.codigos))
    monkeypatch.setattr(router_ih, "_ahora", lambda: AHORA)

    def configurar(usuario=None, servicio=None, **extra_servicio):
        caller_db = db_por_nombre(estricto=True, usuario=usuario if usuario is not None else tabla([{"auth_user_id": AUTOR, "nombre_usuario": "Carlos Ruiz"}]))
        tablas = {
            "bitacora_movimiento_terminal_usuario": tabla([], count=entorno.conteo),
            "terminal_consentimiento": tabla([{"provisional": False}]),
            "terminal": tabla([{"id": 1}]),
        } | extra_servicio
        svc = servicio or db_por_nombre(estricto=True, **tablas)
        svc.postgrest.schema.return_value.rpc.return_value.execute.return_value = Resultado(entorno.estado)
        app.dependency_overrides[get_caller_client] = lambda: caller_db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_service_client] = lambda: svc
        entorno.caller_db, entorno.svc = caller_db, svc
        return caller_db, svc

    entorno.configurar = configurar
    yield entorno
    app.dependency_overrides.clear()


def _get(ruta=RUTA):
    return TestClient(app, raise_server_exceptions=False).get(ruta, headers=AUTH)


def test_el_estado_encendido_trae_nombre_conteo_y_requisitos(entorno):
    entorno.configurar()
    r = _get()
    cuerpo = r.json()
    assert r.status_code == 200
    assert cuerpo["estado"] == "encendido" and cuerpo["encendido_por_nombre"] == "Carlos Ruiz" and cuerpo["altas_activadas_desde_encendido"] == 7
    assert cuerpo["requisitos"] == {"consentimiento_publicado": True, "terminal_activa": True}
    assert cuerpo["alarma"] == {"activa": False, "nivel": None, "codigo": None, "mensaje": None}
    assert AUTOR not in r.text


def test_la_lectura_del_estado_usa_el_cliente_de_servicio_y_el_rpc_sin_parametros_reales(entorno):
    entorno.configurar()
    _get()
    rpc = entorno.svc.postgrest.schema.return_value.rpc
    assert [c.args for c in rpc.call_args_list] == [("fn_terminal_inferir_huella_estado", {})]
    entorno.svc.postgrest.schema.assert_any_call("tiempo")
    assert not entorno.caller_db.postgrest.schema.return_value.rpc.called


def test_el_conteo_es_un_count_exacto_de_huella_inferida_desde_encendido_en_sin_traer_filas(entorno):
    entorno.configurar()
    _get()
    t = entorno.svc.postgrest.schema.return_value.table
    consulta = t("bitacora_movimiento_terminal_usuario")
    consulta.select.assert_called_with("id", count="exact", head=True)
    consulta.eq.assert_called_with("tipo_movimiento", "huella_inferida")
    consulta.gte.assert_called_with("creado_en", "2026-10-12T16:03:11Z")


def test_el_conteo_es_null_si_no_esta_encendido_o_si_la_consulta_falla_sin_tumbar_el_get(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    assert _get().json()["altas_activadas_desde_encendido"] is None
    entorno.estado = ENCENDIDO
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "XX000", "message": "boom"})
    entorno.configurar(bitacora_movimiento_terminal_usuario=roto)
    r = _get()
    assert r.status_code == 200 and r.json()["altas_activadas_desde_encendido"] is None


def test_los_requisitos_son_null_si_su_lectura_falla(entorno):
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "42501", "message": "x"})
    entorno.configurar(terminal_consentimiento=roto, terminal=roto)
    r = _get()
    assert r.status_code == 200 and r.json()["requisitos"] == {"consentimiento_publicado": None, "terminal_activa": None}


def test_con_solo_el_consentimiento_provisional_el_requisito_es_falso(entorno):
    entorno.configurar(terminal_consentimiento=tabla([{"provisional": True}]), terminal=tabla([]))
    assert _get().json()["requisitos"] == {"consentimiento_publicado": False, "terminal_activa": False}


@pytest.mark.parametrize("codigos,nombre", [({"terminal_usuario_lectura"}, None), ({"terminal_usuario_edicion"}, "Carlos Ruiz"), ({"terminal_config_edicion"}, "Carlos Ruiz")])
def test_el_nombre_del_autor_solo_para_quien_edita_terminales(entorno, codigos, nombre):
    entorno.codigos = codigos
    entorno.configurar()
    r = _get()
    assert r.status_code == 200 and r.json()["encendido_por_nombre"] == nombre


def test_sin_ningun_permiso_de_terminales_es_403(entorno):
    entorno.codigos = set()
    entorno.configurar()
    assert _get().status_code == 403


def test_el_nombre_se_resuelve_con_el_cliente_del_caller_y_nunca_con_el_de_servicio(entorno):
    entorno.configurar()
    _get()
    entorno.caller_db.postgrest.schema.assert_any_call("personas")
    assert not [c for c in entorno.svc.postgrest.schema.call_args_list if c.args == ("personas",)]


def test_si_la_persona_no_se_resuelve_el_nombre_es_null_y_no_el_uuid(entorno):
    entorno.configurar(usuario=tabla([]))
    r = _get()
    assert r.json()["encendido_por_nombre"] is None and AUTOR not in r.text
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "42501", "message": "x"})
    entorno.configurar(usuario=roto)
    r = _get()
    assert r.status_code == 200 and r.json()["encendido_por_nombre"] is None and AUTOR not in r.text


def test_si_la_funcion_falla_es_503_y_no_un_apagado_inventado(entorno, caplog):
    entorno.configurar()
    entorno.svc.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError({"code": "XX000", "message": "texto crudo de la base"})
    with caplog.at_level(logging.ERROR):
        r = _get()
    assert r.status_code == 503 and r.json() == {"detail": router_ih.MENSAJE_RESPUESTA_INESPERADA}
    assert "texto crudo" not in caplog.text and "XX000" in caplog.text


def test_una_migracion_sin_aplicar_es_503_del_handler_global(entorno):
    entorno.configurar()
    entorno.svc.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError({"code": "PGRST202", "message": "no function"})
    r = _get()
    assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible. Avisa a Sistemas."}


@pytest.mark.parametrize("ilegible", [None, [], {"activo": True}, "texto", _estado(activo=True)])
def test_una_forma_inesperada_de_la_funcion_es_503(entorno, ilegible):
    entorno.estado = ilegible
    entorno.configurar()
    r = _get()
    assert r.status_code == 503 and r.json() == {"detail": router_ih.MENSAJE_RESPUESTA_INESPERADA}


@pytest.mark.parametrize("motivo", sorted(ih.MOTIVOS_FALLA_CERRADA))
def test_la_alarma_viaja_en_el_estado(entorno, motivo):
    entorno.estado = _estado(motivo=motivo)
    entorno.configurar()
    a = _get().json()["alarma"]
    assert a["activa"] is True and a["nivel"] == "revisar" and a["codigo"] == motivo


def test_sin_sesion_es_401(entorno):
    app.dependency_overrides.clear()
    assert TestClient(app, raise_server_exceptions=False).get(RUTA).status_code in (401, 422)


# --- F1: Cache-Control: no-store en todo el prefijo ------------------------------------------------------------------------------------------------


def test_toda_respuesta_del_prefijo_lleva_no_store_incluidos_los_errores(entorno):
    entorno.configurar()
    exito = _get()
    assert exito.headers["cache-control"] == "no-store" and exito.headers["pragma"] == "no-cache"
    entorno.codigos = set()
    assert _get().status_code == 403 and _get().headers["cache-control"] == "no-store"
    entorno.codigos = {"terminal_config_edicion"}
    entorno.svc.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError({"code": "XX000", "message": "x"})
    assert _get().status_code == 503 and _get().headers["cache-control"] == "no-store"
    assert _get(RUTA + "/no-existe").headers["cache-control"] == "no-store"            # 404/405 del propio prefijo


def test_fuera_del_prefijo_no_se_toca_la_cache(entorno):
    r = TestClient(app).get("/salud")
    assert r.headers.get("cache-control") != "no-store"


def test_un_error_no_capturado_en_el_prefijo_tambien_lleva_no_store(entorno, monkeypatch):
    entorno.configurar()
    monkeypatch.setattr(router_ih, "armar_estado", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    r = _get()
    assert r.status_code == 500 and r.headers["cache-control"] == "no-store"


# --- contrato RPC <-> DDL ----------------------------------------------------------------------------------------------------------------------------


DDL = Path(__file__).resolve().parents[2] / "db" / "ddl" / "97_tiempo_terminal_inferir_huella_interruptor.sql"


def test_las_claves_del_estado_coinciden_con_las_que_arma_la_funcion_de_la_base():
    sql = DDL.read_text(encoding="utf-8")
    cuerpo = sql[sql.index("RETURN jsonb_build_object(\n    'activo'"):]
    claves = {linea.split("'")[1] for linea in cuerpo.split("RETURN jsonb_build_object(")[1].split(");")[0].splitlines() if linea.strip().startswith("'")}
    assert claves == {"activo", "vencido", "motivo", "valor", "hasta", "encendido_por", "encendido_en", "ultimo_cambio_via_funcion", "sin_registro"}
    assert set(_estado()) == claves


def test_los_motivos_que_conoce_el_backend_son_los_que_la_base_puede_devolver():
    sql = DDL.read_text(encoding="utf-8")
    for motivo in ("apagado", "valor_invalido", "vigencias_inconsistentes", "hasta_ilegible", "vencido", "hasta_excede_tope", "sin_respaldo_de_la_funcion", "error"):
        assert f"'{motivo}'" in sql
        assert motivo in ih.MENSAJES_MOTIVO


# ===== PARTE 2: escrituras (encender / renovar / apagar) ======================================================================================================

NOTA = "Primer día de la puesta en marcha supervisada con RH"
NOTA_SECRETA = "ZZ-nota-libre-9137-no-debe-salir"
HASTA_BASE = "2026-11-03T05:59:59Z"
FECHA_OK = "2026-11-02"


def _post(ruta, cuerpo, raw=None):
    c = TestClient(app, raise_server_exceptions=False)
    if raw is not None:
        return c.post(RUTA + ruta, content=raw, headers=AUTH | {"Content-Type": "application/json"})
    return c.post(RUTA + ruta, json=cuerpo, headers=AUTH)


def _rpc_cambiar(entorno, resultado=None, error=None):
    """Prepara el cliente del CALLER para la función de cambio y devuelve su mock `rpc`."""
    rpc = entorno.caller_db.postgrest.schema.return_value.rpc
    ejecucion = rpc.return_value.execute
    if error is not None:
        ejecucion.side_effect = error
    else:
        ejecucion.return_value = Resultado(resultado if resultado is not None else {"resultado": "actualizada", "estado": ENCENDIDO})
    return rpc


def _llamadas_cambiar(entorno):
    return [c for c in entorno.caller_db.postgrest.schema.return_value.rpc.call_args_list if c.args[0] == "fn_terminal_inferir_huella_cambiar"]


def test_encender_llama_la_funcion_con_el_cliente_del_caller_y_los_parametros_exactos(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    r = _post("/encender", {"nota": f"  {NOTA}  ", "hasta_fecha": FECHA_OK})
    assert r.status_code == 200
    assert [c.args for c in _llamadas_cambiar(entorno)] == [("fn_terminal_inferir_huella_cambiar", {"p_activa": True, "p_nota": NOTA, "p_hasta": "2026-11-03T05:59:59+00:00"})]
    cuerpo = r.json()
    assert cuerpo["resultado"] == "actualizada" and cuerpo["estado"]["estado"] == "encendido" and cuerpo["estado"]["hasta_fecha"] == "2026-11-02"
    assert cuerpo["estado"]["encendido_por_nombre"] == "Carlos Ruiz" and AUTOR not in r.text


def _servicio_que_no_escribe(entorno):
    """Deja el cliente de servicio de la prueba estricto: solo puede llamar la función de ESTADO y no puede escribir en parametro ni en la bitácora."""
    svc = entorno.svc
    llamadas_rpc = []
    rpc = svc.postgrest.schema.return_value.rpc

    def solo_estado(nombre, params):
        llamadas_rpc.append(nombre)
        assert nombre == "fn_terminal_inferir_huella_estado", f"el cliente de servicio llamó {nombre}"
        return rpc.return_value

    rpc.side_effect = solo_estado
    previo = svc.postgrest.schema.return_value.table.side_effect
    prohibidas = {}
    for nombre in ("parametro", "bitacora_config_terminal"):
        t = tabla([])
        for metodo in ("insert", "update", "delete", "upsert"):
            getattr(t, metodo).side_effect = AssertionError(f"escritura con service_role en {nombre}.{metodo}")
        prohibidas[nombre] = t
    svc.postgrest.schema.return_value.table.side_effect = lambda n: prohibidas[n] if n in prohibidas else previo(n)
    return llamadas_rpc


def test_el_router_no_escribe_con_el_cliente_de_servicio(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    llamadas = _servicio_que_no_escribe(entorno)
    _rpc_cambiar(entorno)
    assert _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK}).status_code == 200
    assert _post("/apagar", {}).status_code == 200
    assert set(llamadas) == {"fn_terminal_inferir_huella_estado"}


def test_apagar_pasa_p_activa_falso_nota_opcional_y_hasta_nulo(entorno):
    entorno.configurar()
    _rpc_cambiar(entorno, {"resultado": "actualizada", "estado": _estado()})
    assert _post("/apagar", {}).status_code == 200
    assert _post("/apagar", {"nota": "  Fin de la prueba  "}).status_code == 200
    assert [c.args[1] for c in _llamadas_cambiar(entorno)] == [
        {"p_activa": False, "p_nota": None, "p_hasta": None}, {"p_activa": False, "p_nota": "Fin de la prueba", "p_hasta": None}]


def test_apagar_estando_apagado_es_sin_cambio_y_se_pasa_tal_cual(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, {"resultado": "sin_cambio", "estado": _estado()})
    r = _post("/apagar", {})
    assert r.status_code == 200 and r.json()["resultado"] == "sin_cambio" and r.json()["estado"]["estado"] == "apagado"


def test_renovar_con_nota_nueva_hasta_base_igual_y_estado_encendido(entorno):
    entorno.configurar(bitacora_config_terminal=tabla([{"nota": "La nota anterior de la puesta en marcha"}]))
    _rpc_cambiar(entorno)
    r = _post("/renovar", {"nota": NOTA, "hasta_fecha": "2026-11-09", "hasta_base": HASTA_BASE})
    assert r.status_code == 200
    assert [c.args[1] for c in _llamadas_cambiar(entorno)] == [{"p_activa": True, "p_nota": NOTA, "p_hasta": "2026-11-10T05:59:59+00:00"}]


def test_la_funcion_de_cambio_nunca_se_llama_con_el_cliente_de_servicio_ni_a_la_inversa(entorno):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    _post("/renovar", {"nota": NOTA, "hasta_fecha": "2026-11-09", "hasta_base": HASTA_BASE})
    assert not [c for c in entorno.svc.postgrest.schema.return_value.rpc.call_args_list if c.args[0] == "fn_terminal_inferir_huella_cambiar"]
    assert not [c for c in entorno.caller_db.postgrest.schema.return_value.rpc.call_args_list if c.args[0] == "fn_terminal_inferir_huella_estado"]


# --- gates -----------------------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("codigos", [{"terminal_usuario_lectura"}, {"terminal_usuario_edicion"}, set()])
@pytest.mark.parametrize("ruta,cuerpo", [("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK}), ("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE}), ("/apagar", {})])
def test_solo_terminal_config_edicion_puede_cambiar(entorno, codigos, ruta, cuerpo):
    entorno.codigos = codigos
    entorno.configurar()
    _rpc_cambiar(entorno)
    assert _post(ruta, cuerpo).status_code == 403 and not _llamadas_cambiar(entorno)


def test_un_42501_de_la_base_es_403_con_mensaje_fijo(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, error=APIError({"code": "42501", "message": "texto crudo", "hint": "sin_permiso"}))
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 403 and r.json() == {"detail": "No tienes permiso para cambiar el interruptor de la activación por huella."}


# --- validación sin eco (C3) -------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("cuerpo,codigo", [
    ({"nota": "corta ", "hasta_fecha": FECHA_OK}, "nota_requerida"),                       # 5 caracteres
    ({"nota": "123456789", "hasta_fecha": FECHA_OK}, "nota_requerida"),                    # 9
    ({"nota": "x" * 501, "hasta_fecha": FECHA_OK}, "nota_requerida"),                      # 501
    ({"nota": "         " + "a" * 4 + "         ", "hasta_fecha": FECHA_OK}, "nota_requerida"),   # el strip lo deja en 4
    ({"nota": NOTA_SECRETA, "hasta_fecha": "no-es-fecha"}, "hasta_invalido"),
    ({"nota": NOTA_SECRETA, "hasta_fecha": 20261102}, "hasta_invalido"),
    ({"nota": NOTA_SECRETA, "hasta_fecha": FECHA_OK, "extra": "x"}, "cuerpo_invalido"),
    ({"nota": 12345678901234, "hasta_fecha": FECHA_OK}, "nota_requerida"),
    ({"hasta_fecha": FECHA_OK}, "nota_requerida"),
    ({"nota": NOTA_SECRETA}, "hasta_invalido"),
])
def test_los_422_de_validacion_son_fijos_y_no_repiten_nada_de_lo_enviado(entorno, cuerpo, codigo):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    r = _post("/encender", cuerpo)
    assert r.status_code == 422 and set(r.json()) == {"detail", "codigo"} and r.json()["codigo"] == codigo
    assert NOTA_SECRETA not in r.text and "no-es-fecha" not in r.text and "20261102" not in r.text and "input" not in r.text and "ctx" not in r.text and "loc" not in r.text
    assert not _llamadas_cambiar(entorno)


def test_el_cuerpo_que_no_es_json_tambien_es_422_fijo(entorno):
    entorno.configurar()
    r = _post("/encender", None, raw=b'{"nota": "' + NOTA_SECRETA.encode() + b'", ')
    assert r.status_code == 422 and r.json() == {"detail": "La solicitud no es válida.", "codigo": "cuerpo_invalido"} and NOTA_SECRETA not in r.text


def test_apagar_con_una_nota_demasiado_larga_es_nota_invalida_sin_eco(entorno):
    entorno.configurar()
    r = _post("/apagar", {"nota": NOTA_SECRETA + "x" * 600})
    assert r.status_code == 422 and r.json() == {"detail": "La nota no puede pasar de 500 caracteres.", "codigo": "nota_invalida"} and NOTA_SECRETA not in r.text


def test_hasta_base_sin_zona_o_ilegible_es_422_hasta_invalido(entorno):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    for malo in ("2026-11-03T05:59:59", "mañana", "", "2026-13-45T00:00:00Z"):
        r = _post("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": malo})
        assert r.status_code == 422 and r.json()["codigo"] == "hasta_invalido" and malo not in r.text or malo == ""


def test_el_manejador_de_validacion_por_omision_no_cambio_fuera_del_prefijo(entorno):
    entorno.configurar()
    r = TestClient(app, raise_server_exceptions=False).patch("/api/terminales/configuracion/variables/terminal_caducidad_alta_horas", json={"valor": "no-es-entero"}, headers=AUTH)
    assert r.status_code == 422 and isinstance(r.json()["detail"], list) and "codigo" not in r.json()


# --- rango recalculado en el POST (1a) -----------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("fecha", ["2026-10-11", "2026-11-11", "2027-01-01", "2020-01-01"])
def test_una_fecha_fuera_de_rango_es_422_hasta_invalido_sin_llamar_a_la_base(entorno, fecha):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": fecha})
    assert r.status_code == 422 and r.json() == {"detail": "El vencimiento debe ser una fecha futura de a lo más 30 días.", "codigo": "hasta_invalido"} and not _llamadas_cambiar(entorno)


def test_la_fecha_buena_en_el_get_pero_fuera_de_rango_en_el_post_es_422_y_no_error_de_base(entorno, monkeypatch):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    minima = _get().json()["fecha_minima"]
    assert minima == "2026-10-12"
    monkeypatch.setattr(router_ih, "_ahora", lambda: AHORA + timedelta(days=1))          # pasó la medianoche entre el GET y el POST
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": minima})
    assert r.status_code == 422 and r.json()["codigo"] == "hasta_invalido" and not _llamadas_cambiar(entorno)


def test_la_fecha_minima_y_la_maxima_se_aceptan(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    for fecha in ("2026-10-12", "2026-11-10"):
        assert _post("/encender", {"nota": NOTA, "hasta_fecha": fecha}).status_code == 200


# --- cortesía: ya encendido / no encendido / desactualizado / nota repetida -------------------------------------------------------------------------------------------


def test_encender_estando_encendido_es_409_con_el_estado_actual(entorno):
    entorno.configurar()
    _rpc_cambiar(entorno)
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 409 and r.json()["codigo"] == "ya_esta_encendido" and r.json()["detail"] == router_ih.MENSAJE_YA_ENCENDIDO
    assert r.json()["estado"]["estado"] == "encendido" and AUTOR not in r.text and not _llamadas_cambiar(entorno)


def test_renovar_sin_estar_encendido_es_409(entorno):
    entorno.estado = _estado()
    entorno.configurar(bitacora_config_terminal=tabla([]))
    r = _post("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE})
    assert r.status_code == 409 and r.json() == {"detail": router_ih.MENSAJE_NO_ENCENDIDO, "codigo": "no_esta_encendido"}


@pytest.mark.parametrize("base,coincide", [
    ("2026-11-03T05:59:59Z", True), ("2026-11-02T23:59:59-06:00", True), ("2026-11-03T05:59:59.900000+00:00", True),     # mismo instante a la precisión de un segundo
    ("2026-11-03T05:59:58Z", False), ("2026-11-03T06:00:00Z", False), ("2026-11-02T23:59:59Z", False),
])
def test_hasta_base_se_compara_por_instante(entorno, base, coincide):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    r = _post("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": base})
    if coincide:
        assert r.status_code == 200
    else:
        assert r.status_code == 409 and r.json()["codigo"] == "estado_desactualizado" and r.json()["estado"]["hasta"] == HASTA_BASE and not _llamadas_cambiar(entorno)


@pytest.mark.parametrize("repetida", [NOTA, "  " + NOTA.upper() + "  ", NOTA.replace(" ", "   "), NOTA.replace(" ", "\t")])
def test_renovar_con_la_misma_nota_es_422_nota_repetida(entorno, repetida):
    entorno.configurar(bitacora_config_terminal=tabla([{"nota": NOTA}]))
    _rpc_cambiar(entorno)
    r = _post("/renovar", {"nota": repetida, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE})
    assert r.status_code == 422 and r.json() == {"detail": router_ih.MENSAJE_NOTA_REPETIDA, "codigo": "nota_repetida"} and not _llamadas_cambiar(entorno)
    assert NOTA not in r.text


def test_la_nota_anterior_se_lee_solo_para_comparar(entorno):
    entorno.configurar(bitacora_config_terminal=tabla([{"nota": "Una nota distinta de la anterior"}]))
    _rpc_cambiar(entorno)
    r = _post("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE})
    assert r.status_code == 200 and "Una nota distinta" not in r.text


def test_si_no_se_puede_leer_la_ultima_nota_la_renovacion_sigue(entorno):
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "XX000", "message": "x"})
    entorno.configurar(bitacora_config_terminal=roto)
    _rpc_cambiar(entorno)
    assert _post("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE}).status_code == 200


# --- mapeo de errores de la base ---------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("sqlstate,hint,http,codigo,detalle", [
    ("22023", "nota_requerida", 422, "nota_requerida", "La nota debe tener entre 10 y 500 caracteres."),
    ("22023", "hasta_invalido", 422, "hasta_invalido", "El vencimiento debe ser una fecha futura de a lo más 30 días."),
    ("22023", "terminal_no_activa", 409, "terminal_no_activa", "No hay ninguna terminal activa; no se puede encender."),
    ("22023", "vigencias_inconsistentes", 409, "vigencias_inconsistentes", "El ajuste está en un estado inconsistente; avisa a Sistemas."),
    ("SCJ16", "sin_consentimiento_vigente", 409, "sin_consentimiento_vigente",
     "Falta publicar el texto de consentimiento biométrico definitivo; mientras solo exista el provisional no se puede encender."),
    ("22023", "parametros_invalidos", 500, None, "Error interno del servidor."),
    ("22023", "clave_no_editable", 503, None, "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."),
    ("SCJ02", "", 503, None, "Servicio no disponible. Avisa a Sistemas."),
    ("55P03", "", 503, "reintentar", "El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo."),
    ("40P01", "", 503, "reintentar", "El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo."),
    ("40001", "", 503, "reintentar", "El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo."),
    ("42501", "sin_permiso", 403, None, "No tienes permiso para cambiar el interruptor de la activación por huella."),
    ("XX000", "", 500, None, "Error interno del servidor."),
    ("23514", "", 500, None, "Error interno del servidor."),
])
def test_mapeo_de_errores_de_la_funcion_de_cambio(entorno, sqlstate, hint, http, codigo, detalle):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, error=APIError({"code": sqlstate, "message": f"texto crudo con {NOTA_SECRETA}", "hint": hint or None, "details": f"Failing row contains ({NOTA_SECRETA})"}))
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    esperado = {"detail": detalle} | ({"codigo": codigo} if codigo else {})
    assert r.status_code == http and r.json() == esperado
    assert NOTA_SECRETA not in r.text and "texto crudo" not in r.text


def test_una_migracion_sin_aplicar_al_cambiar_es_503_del_handler_global(entorno):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, error=APIError({"code": "PGRST202", "message": "no function"}))
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 503 and r.json() == {"detail": "Servicio no disponible. Avisa a Sistemas."}


@pytest.mark.parametrize("devuelto", [None, [], {"resultado": "rara", "estado": ENCENDIDO}, {"estado": ENCENDIDO}])
def test_una_respuesta_inesperada_de_la_funcion_es_503(entorno, devuelto):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, resultado=devuelto if devuelto is not None else [])
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 503 and r.json() == {"detail": router_ih.MENSAJE_RESPUESTA_INESPERADA}


@pytest.mark.parametrize("estado_devuelto", [{"activo": True}, "texto", None, [], 7])
def test_n1_si_el_cambio_se_aplico_pero_el_estado_no_se_puede_armar_es_200_con_estado_null(entorno, estado_devuelto, caplog):
    """El cambio ya se aplicó: un error aquí haría creer que no pasó nada. Se responde el resultado y `estado: null` (la pantalla recarga con el GET); ni apagado inventado ni 503."""
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, {"resultado": "actualizada", "estado": estado_devuelto})
    with caplog.at_level(logging.WARNING):
        r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 200 and r.json() == {"resultado": "actualizada", "estado": None}
    assert NOTA not in r.text + caplog.text


def test_n1_si_falla_una_lectura_accesoria_despues_del_cambio_tambien_es_200(entorno, monkeypatch):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    monkeypatch.setattr(router_ih, "armar_estado", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")) if a else None)
    r = _post("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK})
    assert r.status_code == 200 and r.json()["resultado"] == "actualizada" and r.json()["estado"] is None


# --- privacidad de logs y respuestas --------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("error", [APIError({"code": "XX000", "message": f"boom {NOTA_SECRETA}", "details": f"({NOTA_SECRETA})"}), APIError({"code": "22023", "message": NOTA_SECRETA, "hint": "parametros_invalidos"}),
                                   APIError({"code": "55P03", "message": NOTA_SECRETA}), APIError({"code": "SCJ02", "message": NOTA_SECRETA})])
def test_ni_las_respuestas_ni_los_logs_de_error_contienen_la_nota(entorno, caplog, error):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno, error=error)
    with caplog.at_level(logging.DEBUG):
        r = _post("/encender", {"nota": NOTA_SECRETA + " con diez o más caracteres", "hasta_fecha": FECHA_OK})
    assert NOTA_SECRETA not in r.text and NOTA_SECRETA not in caplog.text
    assert NOTA_SECRETA not in "".join(str(getattr(rec, "args", "")) for rec in caplog.records)


def test_los_exitos_tampoco_registran_la_nota(entorno, caplog):
    entorno.estado = _estado()
    entorno.configurar()
    _rpc_cambiar(entorno)
    with caplog.at_level(logging.DEBUG):
        r = _post("/encender", {"nota": NOTA_SECRETA + " otra vez", "hasta_fecha": FECHA_OK})
    assert r.status_code == 200 and NOTA_SECRETA not in caplog.text and NOTA_SECRETA not in r.text


@pytest.mark.parametrize("ruta,cuerpo", [("/encender", {"nota": NOTA, "hasta_fecha": FECHA_OK}), ("/renovar", {"nota": NOTA, "hasta_fecha": FECHA_OK, "hasta_base": HASTA_BASE}), ("/apagar", {})])
def test_los_post_llevan_no_store_en_exito_y_en_error(entorno, ruta, cuerpo):
    entorno.configurar(bitacora_config_terminal=tabla([]))
    _rpc_cambiar(entorno)
    assert _post(ruta, cuerpo).headers["cache-control"] == "no-store"
    assert _post(ruta, {"nota": 1, "x": 2}).headers["cache-control"] == "no-store"          # 422
    entorno.codigos = set()
    assert _post(ruta, cuerpo).headers["cache-control"] == "no-store"                      # 403


def test_el_diseno_de_los_hint_coincide_con_la_funcion_de_la_base():
    sql = DDL.read_text(encoding="utf-8")
    for hint in ("sin_permiso", "nota_requerida", "hasta_invalido", "terminal_no_activa", "parametros_invalidos", "vigencias_inconsistentes", "sin_consentimiento_vigente", "clave_no_editable"):
        assert f"'{hint}'" in sql
    assert "fn_terminal_inferir_huella_cambiar(p_activa boolean, p_nota text, p_hasta timestamptz DEFAULT NULL)" in sql
    assert "ERRCODE = 'SCJ16'" in sql


# ===== PARTE 4: historial ===============================================================================================================================================


def _fila(i, **cambios):
    base = {"id": i, "creado_en": "2026-10-12T16:03:11+00:00", "clave": "terminal_inferir_huella_activa", "operacion": "UPDATE", "valor_anterior": "0", "valor_nuevo": "1",
            "nota": NOTA, "registrado_por": AUTOR, "via_funcion": True}
    return base | cambios


def _historial(entorno, filas, **kw):
    entorno.configurar(usuario=kw.pop("usuario", None), bitacora_config_terminal=tabla(filas))
    # el historial se lee con el cliente del CALLER: la tabla va en su base
    entorno.caller_db.postgrest.schema.return_value.table.side_effect = lambda n: {
        "bitacora_config_terminal": tabla(filas), "usuario": tabla([{"auth_user_id": AUTOR, "nombre_usuario": "Carlos Ruiz"}]) if kw.get("autor", True) else tabla([])}[n]
    return TestClient(app, raise_server_exceptions=False).get(RUTA + "/historial", headers=AUTH)


def test_el_historial_trae_solo_columnas_seguras_y_el_nombre_del_autor(entorno):
    r = _historial(entorno, [_fila(2, clave="terminal_inferir_huella_hasta", valor_anterior="1970-01-01T00:00:00Z", valor_nuevo="2026-11-03T05:59:59Z"), _fila(1)])
    assert r.status_code == 200
    items = r.json()["items"]
    assert [i["id"] for i in items] == [2, 1] and items[0]["clave"] == "terminal_inferir_huella_hasta" and items[0]["autor_nombre"] == "Carlos Ruiz" and items[0]["nota"] == NOTA
    assert set(items[0]) == {"id", "creado_en", "clave", "operacion", "valor_anterior", "valor_nuevo", "nota", "autor_nombre", "via_funcion"}
    assert AUTOR not in r.text and r.headers["cache-control"] == "no-store"


def test_el_historial_pide_solo_esas_columnas_ordenado_y_acotado_con_el_cliente_del_caller(entorno):
    entorno.configurar()
    tablas = {}

    def resolver(nombre):
        tablas.setdefault(nombre, tabla([_fila(1)] if nombre == "bitacora_config_terminal" else []))
        return tablas[nombre]

    entorno.caller_db.postgrest.schema.return_value.table.side_effect = resolver
    r = TestClient(app, raise_server_exceptions=False).get(RUTA + "/historial?limite=7", headers=AUTH)
    assert r.status_code == 200
    t = tablas["bitacora_config_terminal"]
    t.select.assert_called_with(router_ih.COLUMNAS_HISTORIAL)
    t.order.assert_called_with("id", desc=True)
    t.limit.assert_called_with(7)
    for prohibida in ("rol_jwt", "usuario_sesion", "txid"):
        assert prohibida not in router_ih.COLUMNAS_HISTORIAL
    assert not [c for c in entorno.svc.postgrest.schema.return_value.table.call_args_list if c.args == ("bitacora_config_terminal",)]    # nunca con service_role


@pytest.mark.parametrize("limite", ["0", "101", "x", "-1"])
def test_el_limite_del_historial_esta_acotado(entorno, limite):
    entorno.configurar()
    r = TestClient(app, raise_server_exceptions=False).get(RUTA + f"/historial?limite={limite}", headers=AUTH)
    assert r.status_code == 422 and set(r.json()) == {"detail", "codigo"}


@pytest.mark.parametrize("codigos,http", [({"terminal_usuario_lectura"}, 403), (set(), 403), ({"terminal_usuario_edicion"}, 200), ({"terminal_config_edicion"}, 200)])
def test_el_historial_es_solo_para_quien_edita_terminales(entorno, codigos, http):
    entorno.codigos = codigos
    r = _historial(entorno, [_fila(1)])
    assert r.status_code == http
    if http == 403:
        assert NOTA not in r.text


def test_si_la_persona_no_se_resuelve_el_autor_es_null_y_no_el_uuid(entorno):
    r = _historial(entorno, [_fila(1)], autor=False)
    assert r.status_code == 200 and r.json()["items"][0]["autor_nombre"] is None and AUTOR not in r.text


def test_un_cambio_directo_sin_autor_ni_nota_se_muestra_con_via_funcion_falsa(entorno):
    r = _historial(entorno, [_fila(5, registrado_por=None, nota=None, via_funcion=False, operacion="UPDATE_VIGENCIA", valor_anterior="1", valor_nuevo="1")])
    i = r.json()["items"][0]
    assert i["via_funcion"] is False and i["autor_nombre"] is None and i["nota"] is None and i["operacion"] == "UPDATE_VIGENCIA"


@pytest.mark.parametrize("mala", [_fila(1, clave="otra_clave"), _fila(1, operacion="TRUNCATE"), _fila(1, via_funcion=None)])
def test_una_fila_fuera_del_contrato_no_se_devuelve_como_si_nada(entorno, mala):
    r = _historial(entorno, [mala])
    assert r.status_code == 500 or r.status_code == 503                       # la respuesta no cumple el esquema: nunca se entrega tal cual
    assert NOTA not in r.text


def test_si_falla_la_lectura_del_historial_es_503_sin_texto_de_la_base(entorno, caplog):
    entorno.configurar()
    roto = tabla([])
    roto.execute.side_effect = APIError({"code": "XX000", "message": f"boom {NOTA_SECRETA}"})
    entorno.caller_db.postgrest.schema.return_value.table.side_effect = lambda n: roto
    with caplog.at_level(logging.DEBUG):
        r = TestClient(app, raise_server_exceptions=False).get(RUTA + "/historial", headers=AUTH)
    assert r.status_code == 503 and r.json() == {"detail": router_ih.MENSAJE_RESPUESTA_INESPERADA} and NOTA_SECRETA not in r.text + caplog.text


def test_la_forma_inesperada_de_la_bitacora_es_503(entorno):
    entorno.configurar()
    entorno.caller_db.postgrest.schema.return_value.table.side_effect = lambda n: tabla({"no": "es lista"})
    assert TestClient(app, raise_server_exceptions=False).get(RUTA + "/historial", headers=AUTH).status_code == 503


def test_los_valores_de_clave_y_operacion_son_los_del_check_de_la_base():
    sql = DDL.read_text(encoding="utf-8")
    for valor in ("terminal_inferir_huella_activa", "terminal_inferir_huella_hasta", "INSERT", "UPDATE", "UPDATE_VIGENCIA", "DELETE"):
        assert f"'{valor}'" in sql
    import re
    assert re.search(r"via_funcion\s+boolean NOT NULL", sql)


# --- N4: sin permiso manda el 403, no el 422 de validación ------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("ruta,cuerpo", [
    ("/encender", {"nota": "x", "hasta_fecha": "no-es-fecha", "extra": 1}), ("/renovar", {"nota": "x"}), ("/apagar", {"nota": "y" * 900}), ("/encender", {}),
])
def test_n4_un_llamador_sin_permiso_con_cuerpo_invalido_recibe_403_y_no_422(entorno, ruta, cuerpo):
    entorno.codigos = {"terminal_usuario_lectura"}
    entorno.configurar()
    _rpc_cambiar(entorno)
    r = _post(ruta, cuerpo)
    assert r.status_code == 403 and "codigo" not in r.json() and not _llamadas_cambiar(entorno)
    assert r.headers["cache-control"] == "no-store"


def test_n4_tampoco_se_filtra_el_cuerpo_a_quien_no_tiene_permiso(entorno):
    entorno.codigos = set()
    entorno.configurar()
    r = _post("/encender", {"nota": NOTA_SECRETA, "hasta_fecha": "no-es-fecha"})
    assert r.status_code == 403 and NOTA_SECRETA not in r.text
