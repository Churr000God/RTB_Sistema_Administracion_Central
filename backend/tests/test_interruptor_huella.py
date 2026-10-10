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
