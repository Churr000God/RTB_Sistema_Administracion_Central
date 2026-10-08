"""C7 del contrato de Terminales: variables de configuración (GET/PATCH/historial/simular), valor vigente por RPC
tolerante y jobs de caducidad y purga. Mocks por NOMBRE de tabla; NUNCA contra la base real ni RPC de escritura reales."""

import logging
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, TablaConCadenas, cliente_rpc, db_por_nombre, llamadas, tabla
from app import permisos
from app.batches import terminales as jobs
from app.catalogo_terminal import CATALOGO_TERMINAL, valor_vigente
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
CRUDO = "texto-crudo-id-interno-9921"
RUTA = "/api/terminales/configuracion/variables"
CAD = "terminal_caducidad_alta_horas"
AHORA = datetime.now(timezone.utc)


def _param(clave, valor, desde="2026-01-01", hasta=None, autor=None):
    return {"clave": clave, "valor": valor, "vigente_desde": desde, "vigente_hasta": hasta, "registrado_por": autor, "id": 1}


@pytest.fixture
def entorno(monkeypatch):
    entorno.codigos = []
    entorno.permitido = True
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return entorno.permitido

    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)

    def configurar(parametro=None, rpc_valor=None, rpc_error=None, **tablas):
        """`parametro`: filas de tiempo.parametro que ve service_role. `rpc_*`: lo que responde el RPC de escritura."""
        db = db_por_nombre(estricto=True, **tablas)
        crpc = db.postgrest.schema.return_value.rpc
        if rpc_error is not None:
            crpc.return_value.execute.side_effect = rpc_error
        else:
            crpc.return_value.execute.return_value = Resultado(rpc_valor)
        servicio = db_por_nombre(parametro=parametro if parametro is not None else tabla([]))
        srpc = servicio.postgrest.schema.return_value.rpc
        srpc.return_value.execute.return_value = Resultado(None)  # fn_terminal_config_valor: sin respuesta útil
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_service_client] = lambda: servicio
        entorno.db, entorno.servicio, entorno.rpc = db, servicio, crpc
        return db

    entorno.configurar = configurar
    return entorno


def _c():
    return TestClient(app, raise_server_exceptions=False)


def _get(ruta):
    return _c().get(ruta, headers=AUTH)


# --- valor_vigente por RPC (tolerante) -----------------------------------------------------------------------------------


@pytest.mark.parametrize("rpc,esperado", [(48, 48), (4, 4), (168, 168)])
def test_valor_vigente_prefiere_el_rpc(rpc, esperado):
    servicio, llamada = cliente_rpc(rpc)
    assert valor_vigente(servicio, CAD) == esperado
    assert llamada.call_args.args == ("fn_terminal_config_valor", {"p_clave": CAD})


@pytest.mark.parametrize("rpc", [None, 3, 169, True, "48", 48.0, [], {"v": 1}])
def test_si_el_rpc_no_da_un_entero_valido_cae_a_la_tabla_y_luego_al_defecto(rpc):
    servicio, _ = cliente_rpc(rpc)
    servicio.postgrest.schema.return_value.table.return_value = tabla([{"valor": "72"}])
    assert valor_vigente(servicio, CAD) == 72
    servicio.postgrest.schema.return_value.table.return_value = tabla([])
    assert valor_vigente(servicio, CAD) == 24


def test_si_el_rpc_falla_por_89_sin_aplicar_usa_la_tabla_y_el_defecto():
    servicio, _ = cliente_rpc(error=APIError({"code": "PGRST202", "message": CRUDO}))
    servicio.postgrest.schema.return_value.table.return_value = tabla([])
    assert valor_vigente(servicio, CAD) == 24


def test_con_todo_roto_devuelve_el_defecto_sin_levantar():
    servicio = MagicMock()
    servicio.postgrest.schema.side_effect = ConnectionError(CRUDO)
    assert valor_vigente(servicio, CAD) == 24


# --- GET variables ---------------------------------------------------------------------------------------------------------


def test_lista_las_cinco_variables_con_su_valor_y_autor(entorno):
    filas = [
        _param(CAD, "48", desde="2026-10-08", autor="auth-ti"),
        _param("terminal_llave_max_meses", "12"),
        _param("terminal_traslape_llave_max_dias", "7"),
        _param("terminal_anomalias_ventana_dias", "7"),
        _param("terminal_retencion_rechazos_dias", "90"),
    ]
    entorno.configurar(parametro=tabla(filas), usuario=tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "carlos.ruiz"}]))
    r = _get(RUTA)
    assert r.status_code == 200, r.text
    por_clave = {v["clave"]: v for v in r.json()}
    assert set(por_clave) == set(CATALOGO_TERMINAL)
    cad = por_clave[CAD]
    assert (cad["valor"], cad["minimo"], cad["maximo"], cad["valor_defecto"], cad["unidad"]) == (48, 4, 168, 24, "horas")
    assert cad["vigente_desde"] == "2026-10-08" and cad["modificado_por_nombre"] == "carlos.ruiz"
    assert cad["etiqueta"] and cad["descripcion"]
    assert por_clave["terminal_llave_max_meses"]["modificado_por_nombre"] is None


@pytest.mark.parametrize("valor", ["abc", "", None, "3", "169", "-5", "1e3"])
def test_clave_corrupta_o_fuera_de_rango_devuelve_el_defecto_con_vigente_desde_nulo(entorno, valor):
    entorno.configurar(parametro=tabla([_param(CAD, valor)]), usuario=tabla([]))
    cad = next(v for v in _get(RUTA).json() if v["clave"] == CAD)
    assert cad["valor"] == 24 and cad["vigente_desde"] is None and cad["modificado_por_nombre"] is None


def test_clave_faltante_devuelve_el_defecto(entorno):
    entorno.configurar(parametro=tabla([]), usuario=tabla([]))
    r = _get(RUTA).json()
    assert len(r) == 5 and all(v["valor"] == v["valor_defecto"] and v["vigente_desde"] is None for v in r)


def test_la_lectura_usa_service_role_acotada_a_la_lista_blanca_y_a_la_vigencia_abierta(entorno):
    t = TablaConCadenas([], [])
    entorno.configurar(parametro=t, usuario=tabla([]))
    _get(RUTA)
    c = t.cadenas[0]
    assert llamadas(c, "in_") == [(("clave", list(CATALOGO_TERMINAL)), {})]
    assert llamadas(c, "is_") == [(("vigente_hasta", "null"), {})]


def test_get_variables_gate_incluye_config(entorno):
    entorno.configurar(parametro=tabla([]), usuario=tabla([]))
    assert _get(RUTA).status_code == 200
    assert entorno.codigos[-1] == ("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
    entorno.permitido = False
    assert _get(RUTA).status_code == 403


# --- historial -------------------------------------------------------------------------------------------------------------


def test_historial_con_estado_y_filtros(entorno):
    t = TablaConCadenas([
        _param(CAD, "48", desde="2026-10-08", autor="auth-ti"),
        _param(CAD, "24", desde="2026-01-01", hasta="2026-10-07"),
    ])
    entorno.configurar(parametro=t, usuario=tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "carlos.ruiz"}]))
    r = _get(f"{RUTA}/historial?clave={CAD}&desde=2026-01-01")
    assert r.status_code == 200, r.text
    assert [x["estado"] for x in r.json()] == ["vigente", "reemplazada"]
    assert r.json()[0]["modificado_por_nombre"] == "carlos.ruiz" and r.json()[1]["vigente_hasta"] == "2026-10-07"
    c = t.cadenas[0]
    assert llamadas(c, "in_") == [(("clave", [CAD]), {})]
    assert llamadas(c, "gte") == [(("vigente_desde", "2026-01-01"), {})]
    assert llamadas(c, "limit") == [((200,), {})]
    assert llamadas(c, "order") == [(("vigente_desde",), {"desc": True}), (("id",), {"desc": True})]


def test_historial_sin_clave_solo_cubre_la_lista_blanca(entorno):
    t = TablaConCadenas([])
    entorno.configurar(parametro=t, usuario=tabla([]))
    _get(f"{RUTA}/historial")
    assert llamadas(t.cadenas[0], "in_") == [(("clave", list(CATALOGO_TERMINAL)), {})]


@pytest.mark.parametrize("clave", ["tolerancia_retardo_min", "terminal_otra", "x" * 65])
def test_historial_de_una_clave_ajena_no_se_expone(entorno, clave):
    t = TablaConCadenas([])
    entorno.configurar(parametro=t, usuario=tabla([]))
    assert _get(f"{RUTA}/historial?clave={clave}").status_code in (404, 422)
    assert t.cadenas == []


def test_historial_fecha_invalida_422(entorno):
    entorno.configurar(parametro=tabla([]), usuario=tabla([]))
    assert _get(f"{RUTA}/historial?desde=ayer").status_code == 422


# --- PATCH ---------------------------------------------------------------------------------------------------------------


OK_RPC = {"resultado": "actualizada", "clave": CAD, "valor": "48", "vigente_desde": "2026-10-08"}


def _patch(cuerpo, clave=CAD):
    return _c().patch(f"{RUTA}/{clave}", json=cuerpo, headers=AUTH)


def _rpc_llamadas(entorno):
    return [c for c in entorno.rpc.call_args_list if c.args[0] == "fn_terminal_config_actualizar"]


def test_edita_con_el_rpc_del_caller_y_devuelve_el_valor(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor=OK_RPC)
    r = _patch({"valor": 48, "valor_base": 24})
    assert r.status_code == 200, r.text
    assert r.json() == {"resultado": "actualizada", "clave": CAD, "valor": 48, "vigente_desde": "2026-10-08"}
    nombre, params = _rpc_llamadas(entorno)[0].args
    assert params == {"p_clave": CAD, "p_valor": "48"}  # el RPC recibe texto, como su firma
    assert entorno.codigos[-1] == ("terminal_config_edicion",)


def test_sin_cambio(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]),
                       rpc_valor={"resultado": "sin_cambio", "clave": CAD, "valor": "24", "vigente_desde": "2026-01-01"})
    assert _patch({"valor": 24, "valor_base": 24}).json()["resultado"] == "sin_cambio"


def test_valor_base_distinto_del_vigente_da_409_con_valor_actual_y_no_escribe(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "36")]), rpc_valor=OK_RPC)
    r = _patch({"valor": 48, "valor_base": 24})
    assert r.status_code == 409
    assert r.json() == {
        "detail": "La variable cambió mientras la editabas; vuelve a leerla.",
        "codigo": "valor_desactualizado",
        "valor_actual": 36,
    }
    assert _rpc_llamadas(entorno) == []


def test_valor_base_se_compara_con_el_defecto_si_la_clave_falta(entorno):
    entorno.configurar(parametro=tabla([]), rpc_valor=OK_RPC)
    assert _patch({"valor": 48, "valor_base": 24}).status_code == 200


@pytest.mark.parametrize("valor", [3, 169, -1, 0, 10**9])
def test_valor_fuera_de_rango_422_con_mensaje_del_catalogo_sin_rpc(entorno, valor):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor=OK_RPC)
    r = _patch({"valor": valor, "valor_base": 24})
    assert r.status_code == 422 and r.json()["detail"] == "El valor debe ser un entero entre 4 y 168."
    assert _rpc_llamadas(entorno) == []


@pytest.mark.parametrize("valor,esperado", [(4, 200), (168, 200)])
def test_bordes_del_rango_pasan(entorno, valor, esperado):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor={**OK_RPC, "valor": str(valor)})
    assert _patch({"valor": valor, "valor_base": 24}).status_code == esperado


@pytest.mark.parametrize(
    "cuerpo",
    [{"valor": "48", "valor_base": 24}, {"valor": 48.5, "valor_base": 24}, {"valor": 48}, {"valor_base": 24},
     {"valor": 48, "valor_base": 24, "clave": "x"}, {"valor": None, "valor_base": 24}, {"valor": True, "valor_base": 24}],
)
def test_cuerpos_invalidos_422_sin_rpc(entorno, cuerpo):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor=OK_RPC)
    assert _patch(cuerpo).status_code == 422
    assert _rpc_llamadas(entorno) == []


@pytest.mark.parametrize("clave", ["tolerancia_retardo_min", "terminal_otra", "TERMINAL_CADUCIDAD_ALTA_HORAS", "x"])
def test_clave_fuera_de_la_lista_blanca_404_sin_rpc(entorno, clave):
    entorno.configurar(parametro=tabla([]), rpc_valor=OK_RPC)
    r = _patch({"valor": 48, "valor_base": 24}, clave=clave)
    assert r.status_code == 404 and r.json()["detail"] == "La variable no existe."
    assert _rpc_llamadas(entorno) == []


def test_regla_cruzada_de_llaves_da_mensajes_fijos(entorno):
    err = APIError({"code": "22023", "hint": "valor_invalido", "message": CRUDO})
    entorno.configurar(parametro=tabla([_param("terminal_traslape_llave_max_dias", "7")]), rpc_error=err)
    r = _patch({"valor": 30, "valor_base": 7}, clave="terminal_traslape_llave_max_dias")
    assert r.status_code == 422 and "mitad" in r.json()["detail"] and "9921" not in r.text
    entorno.configurar(parametro=tabla([_param("terminal_llave_max_meses", "12")]), rpc_error=err)
    r = _patch({"valor": 3, "valor_base": 12}, clave="terminal_llave_max_meses")
    assert r.status_code == 422 and "doble del traslape" in r.json()["detail"] and "9921" not in r.text


def test_valor_invalido_del_rpc_en_otra_clave_usa_el_rango_del_catalogo(entorno):
    err = APIError({"code": "22023", "hint": "valor_invalido", "message": CRUDO})
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_error=err)
    r = _patch({"valor": 48, "valor_base": 24})
    assert r.status_code == 422 and r.json()["detail"] == "El valor debe ser un entero entre 4 y 168."


@pytest.mark.parametrize(
    "codigo,hint,estado",
    [("SCJ02", "", 404), ("42501", "sin_permiso", 403), ("22023", "clave_no_editable", 404), ("XX999", "", 500)],
)
def test_errores_del_rpc_con_mensaje_fijo(entorno, codigo, hint, estado):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_error=APIError({"code": codigo, "hint": hint, "message": CRUDO}))
    r = _patch({"valor": 48, "valor_base": 24})
    assert r.status_code == estado and "9921" not in r.text


@pytest.mark.parametrize("forma", [None, [], "x", {"resultado": "rara"}, {"resultado": "actualizada", "clave": "otra", "valor": "4"},
                                    {"resultado": "actualizada", "clave": CAD, "valor": "abc"}])
def test_respuesta_inesperada_del_rpc_503(entorno, forma):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor=forma)
    r = _patch({"valor": 48, "valor_base": 24})
    assert r.status_code == 503 and "no respondió como se esperaba" in r.json()["detail"]


def test_editar_exige_config_y_sin_permiso_no_lee_ni_escribe(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), rpc_valor=OK_RPC)
    entorno.permitido = False
    assert _patch({"valor": 48, "valor_base": 24}).status_code == 403
    assert _rpc_llamadas(entorno) == []


# --- simular ---------------------------------------------------------------------------------------------------------------


def _alta(id_, horas, persona="p1"):
    return {"id": id_, "persona_id": persona, "usuario_creado_en": (AHORA - timedelta(hours=horas)).isoformat()}


def _simular(entorno, filas, propuesto, actual="24", extra=None):
    entorno.configurar(
        parametro=tabla([_param(CAD, actual)]),
        terminal_usuario=tabla(filas),
        persona=tabla([{"id": "p1", "primer_nombre": "Luis", "apellido_paterno": "Ramírez"}]),
    )
    # el servicio responde al RPC fn_terminal_config_valor
    entorno.servicio.postgrest.schema.return_value.rpc.return_value.execute.return_value = Resultado(int(actual))
    return _c().post(f"{RUTA}/{CAD}/simular", json={"valor": propuesto, **(extra or {})}, headers=AUTH)


def test_simula_acortar_cuenta_las_que_caducarian_ya(entorno):
    r = _simular(entorno, [_alta(1, 30), _alta(2, 15), _alta(3, 5), _alta(4, 2)], propuesto=12)
    assert r.status_code == 200, r.text
    cuerpo = r.json()
    assert cuerpo["valor_actual"] == 24 and cuerpo["valor_propuesto"] == 12 and cuerpo["acorta"] is True
    assert cuerpo["altas_en_espera"] == 4
    # la 1 (30 h) ya caduca con el plazo actual; con 12 h caducarían ya SÓLO las que llevan entre 12 y 24 h: la 2
    assert [a["tu_id"] for a in cuerpo["altas_que_caducarian_ya"]] == [2]
    assert cuerpo["altas_que_caducarian_ya"][0]["persona_nombre"] == "Luis Ramírez"
    assert cuerpo["altas_que_caducarian_ya_total"] == 1 and cuerpo["altas_que_ganan_plazo"] == 0
    assert cuerpo["tope_por_corrida"] == 50


def test_simula_alargar_cuenta_las_que_ganan_plazo(entorno):
    r = _simular(entorno, [_alta(1, 30), _alta(2, 15), _alta(3, 26)], propuesto=48).json()
    assert r["acorta"] is False and r["altas_que_ganan_plazo"] == 2 and r["altas_que_caducarian_ya"] == []


def test_por_caducar_son_las_que_quedan_a_menos_de_una_hora(entorno):
    r = _simular(entorno, [_alta(1, 11.5), _alta(2, 5), _alta(3, 12.5)], propuesto=12).json()
    assert r["altas_por_caducar_nuevas"] == 1  # sólo la de 11.5 h (falta media hora); la de 12.5 ya pasó


def test_la_lista_de_nombres_se_corta_en_50_con_total_aparte(entorno):
    r = _simular(entorno, [_alta(i, 20) for i in range(1, 71)], propuesto=12).json()
    assert len(r["altas_que_caducarian_ya"]) == 50 and r["altas_que_caducarian_ya_total"] == 70


def test_altas_sin_usuario_creado_no_entran_en_los_calculos(entorno):
    fila = {"id": 1, "persona_id": "p1", "usuario_creado_en": None}
    r = _simular(entorno, [fila], propuesto=12).json()
    assert r["altas_en_espera"] == 1 and r["altas_que_caducarian_ya_total"] == 0


def test_simular_no_escribe_nada(entorno):
    _simular(entorno, [_alta(1, 15)], propuesto=12)
    assert _rpc_llamadas(entorno) == []
    entorno.db.postgrest.schema.return_value.table.return_value.insert.assert_not_called()


def test_simular_valida_rango_clave_y_cuerpo(entorno):
    assert _simular(entorno, [], propuesto=3).status_code == 422
    assert _simular(entorno, [], propuesto=169).status_code == 422
    assert _c().post(f"{RUTA}/terminal_llave_max_meses/simular", json={"valor": 12}, headers=AUTH).status_code == 404
    assert _simular(entorno, [], propuesto=12, extra={"otro": 1}).status_code == 422


def test_simular_exige_config_y_ver_las_altas(entorno):
    entorno.configurar(parametro=tabla([]), terminal_usuario=tabla([]), persona=tabla([]))
    entorno.permitido = False
    assert _c().post(f"{RUTA}/{CAD}/simular", json={"valor": 12}, headers=AUTH).status_code == 403
    entorno.permitido = True
    _c().post(f"{RUTA}/{CAD}/simular", json={"valor": 12}, headers=AUTH)
    assert ("terminal_config_edicion",) in entorno.codigos
    assert ("terminal_usuario_lectura", "terminal_usuario_edicion") in entorno.codigos


# --- jobs ------------------------------------------------------------------------------------------------------------------


def _db_job(valor_tabla="48", valor_rpc=48, accion=3, error_tabla=None, error_valor=None, error_accion=None):
    """Cliente de un job: tiempo.parametro (lectura estricta), fn_terminal_config_valor y la función destructiva."""
    db = MagicMock()
    if error_tabla is not None:
        t = MagicMock()
        t.select.return_value = t
        t.eq.return_value = t
        t.is_.return_value = t
        t.execute.side_effect = error_tabla
        db.postgrest.schema.return_value.table.return_value = t
    else:
        db.postgrest.schema.return_value.table.return_value = tabla([] if valor_tabla is None else [{"valor": valor_tabla}])
    rpc = db.postgrest.schema.return_value.rpc

    def segun(nombre, params=None):
        r = MagicMock()
        if nombre == "fn_terminal_config_valor":
            if error_valor is not None:
                r.execute.side_effect = error_valor
            else:
                r.execute.return_value = Resultado(valor_rpc)
        else:
            if error_accion is not None:
                r.execute.side_effect = error_accion
            else:
                r.execute.return_value = Resultado(accion)
        return r

    rpc.side_effect = segun
    return db, rpc


def _destructivas(rpc):
    return [c.args for c in rpc.call_args_list if c.args[0] != "fn_terminal_config_valor"]


def test_job_de_caducidad_lee_la_variable_vigente_cada_corrida_y_llama_al_rpc():
    db, rpc = _db_job()
    assert jobs.ejecutar_baja_por_caducidad(db) == 3
    assert _destructivas(rpc) == [("fn_terminal_baja_por_caducidad", {"p_horas": 48})]


def test_job_de_caducidad_usa_24_solo_si_la_clave_aun_no_existe_y_avisa(caplog):
    db, rpc = _db_job(valor_tabla=None, accion=0)
    with caplog.at_level(logging.WARNING):
        assert jobs.ejecutar_baja_por_caducidad(db) == 0
    assert _destructivas(rpc) == [("fn_terminal_baja_por_caducidad", {"p_horas": 24})]
    assert any(x.levelno == logging.WARNING and "todavía no existe" in x.getMessage() for x in caplog.records)


@pytest.mark.parametrize("valor_tabla", ["abc", "", "3", "169", "-5", "1e3", "48 horas"])
def test_valor_ilegible_en_la_base_omite_la_corrida_sin_llamar_a_la_funcion_destructiva(valor_tabla, caplog):
    db, rpc = _db_job(valor_tabla=valor_tabla)
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_baja_por_caducidad(db) is None
    assert _destructivas(rpc) == []
    assert any("se omite la corrida" in x.getMessage() and x.levelno >= logging.ERROR for x in caplog.records)


@pytest.mark.parametrize("error", [APIError({"code": "XX999", "message": CRUDO}), ConnectionError(CRUDO), TimeoutError(CRUDO)])
def test_si_la_lectura_de_la_variable_falla_se_omite_la_corrida(error, caplog):
    db, rpc = _db_job(error_tabla=error)
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_baja_por_caducidad(db) is None
    assert _destructivas(rpc) == [] and "9921" not in caplog.text
    db, rpc = _db_job(error_valor=error)
    assert jobs.ejecutar_baja_por_caducidad(db) is None and _destructivas(rpc) == []


@pytest.mark.parametrize("forma", [None, True, "48", 48.0, 3, 169, [], {"v": 48}])
def test_forma_inesperada_del_rpc_lector_omite_la_corrida(forma):
    db, rpc = _db_job(valor_rpc=forma)
    assert jobs.ejecutar_baja_por_caducidad(db) is None and _destructivas(rpc) == []


def test_si_falta_la_funcion_lectora_pero_la_fila_es_legible_se_usa_la_fila():
    db, rpc = _db_job(valor_tabla="72", error_valor=APIError({"code": "PGRST202", "message": CRUDO}))
    assert jobs.ejecutar_baja_por_caducidad(db) == 3
    assert _destructivas(rpc) == [("fn_terminal_baja_por_caducidad", {"p_horas": 72})]


def test_valor_vigente_estricto_directo():
    from app.catalogo_terminal import valor_vigente_estricto

    db, _ = _db_job(valor_tabla="48", valor_rpc=48)
    assert valor_vigente_estricto(db, CAD) == 48
    db, _ = _db_job(valor_tabla="abc")
    assert valor_vigente_estricto(db, CAD) is None
    db, _ = _db_job(valor_tabla=None)
    assert valor_vigente_estricto(db, CAD) == 24


@pytest.mark.parametrize("fallo", [APIError({"code": "XX999", "message": CRUDO}), ConnectionError(CRUDO), TimeoutError(CRUDO)])
def test_un_job_que_falla_en_la_funcion_destructiva_no_propaga_y_deja_error(fallo, caplog):
    db, _ = _db_job(error_accion=fallo)
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_baja_por_caducidad(db) is None
    assert any(x.levelno >= logging.ERROR for x in caplog.records) and "9921" not in caplog.text


@pytest.mark.parametrize("devuelve", [-1, None, True, "x", 2.0])
def test_resultado_inesperado_de_la_funcion_destructiva_es_none_con_log(devuelve, caplog):
    db, _ = _db_job(accion=devuelve)
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_baja_por_caducidad(db) is None
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_corrida_que_llega_al_tope_de_50_avisa_con_warning(caplog):
    db, _ = _db_job(accion=50)
    with caplog.at_level(logging.WARNING):
        assert jobs.ejecutar_baja_por_caducidad(db) == 50
    assert any("tope de 50" in x.getMessage() and x.levelno == logging.WARNING for x in caplog.records)
    caplog.clear()
    db, _ = _db_job(accion=49)
    with caplog.at_level(logging.WARNING):
        jobs.ejecutar_baja_por_caducidad(db)
    assert not any("tope de 50" in x.getMessage() for x in caplog.records)


def test_las_corridas_destructivas_dejan_un_warning_estructurado(caplog):
    db, _ = _db_job(accion=4)
    with caplog.at_level(logging.WARNING):
        jobs.ejecutar_baja_por_caducidad(db)
    m = next(x.getMessage() for x in caplog.records if x.getMessage().startswith("baja por caducidad: altas="))
    assert "altas=4" in m and "plazo_horas=48" in m and "fecha=" in m
    caplog.clear()
    db, _ = _db_job(valor_tabla="120", valor_rpc=120, accion=17)
    with caplog.at_level(logging.WARNING):
        jobs.ejecutar_purga_rechazos(db)
    m = next(x.getMessage() for x in caplog.records if x.getMessage().startswith("purga de rechazos: filas="))
    assert "filas=17" in m and "retencion_dias=120" in m and "fecha=" in m


def test_purga_lee_la_retencion_vigente_y_llama_al_rpc():
    db, rpc = _db_job(valor_tabla="120", valor_rpc=120, accion=17)
    assert jobs.ejecutar_purga_rechazos(db) == 17
    assert _destructivas(rpc) == [("fn_marca_rechazada_purgar", {"p_dias": 120})]


def test_purga_con_variable_ilegible_no_borra_nada(caplog):
    db, rpc = _db_job(valor_tabla="basura")
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_purga_rechazos(db) is None
    assert _destructivas(rpc) == []
    assert any("se omite la corrida" in x.getMessage() for x in caplog.records)


def test_job_que_no_puede_ni_arrancar_no_propaga(monkeypatch, caplog):
    monkeypatch.setattr(jobs, "_cliente", lambda: (_ for _ in ()).throw(RuntimeError(CRUDO)))
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_baja_por_caducidad() is None
        assert jobs.ejecutar_purga_rechazos() is None


def test_el_scheduler_registra_los_dos_jobs_sin_solapes():
    import asyncio
    from unittest.mock import patch

    from app.scheduler import lifespan

    falso = MagicMock()

    async def escenario():
        with patch("app.scheduler.BackgroundScheduler", return_value=falso), patch(
            "app.scheduler._leer_hora_corrida_cierre_dia", return_value=(3, 0)
        ):
            async with lifespan(MagicMock()):
                por_id = {c.kwargs["id"]: c for c in falso.add_job.call_args_list}
                cad, purga = por_id["terminales_baja_por_caducidad"], por_id["terminales_purga_rechazos"]
                assert cad.args[0] is jobs.ejecutar_baja_por_caducidad or cad.args[0].__name__ == "ejecutar_baja_por_caducidad"
                assert cad.kwargs["trigger"] == "interval" and cad.kwargs["minutes"] == 10
                assert purga.kwargs["trigger"] == "cron"
                for c in (cad, purga):
                    assert c.kwargs["max_instances"] == 1 and c.kwargs["coalesce"] is True and c.kwargs["replace_existing"]

    asyncio.run(escenario())


# --- contratos RPC <-> DDL (85_, 84_, 89_) -------------------------------------------------------------------------------------


def _ddl(prefijo):
    return next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob(f"{prefijo}_*.sql")).read_text(encoding="utf-8")


def test_firmas_de_los_rpc_que_usa_c7():
    s89, s85, s84 = _ddl("89"), _ddl("85"), _ddl("84")
    assert "fn_terminal_config_actualizar(p_clave text, p_valor text)" in s89
    assert "GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) TO authenticated" in s89
    assert "fn_terminal_config_valor(p_clave text)" in s89 and "fn_terminal_config_valor(text) TO service_role" in s89
    assert "fn_terminal_baja_por_caducidad(p_horas integer DEFAULT 24)" in s85 and "fn_terminal_baja_por_caducidad(integer) TO service_role" in s85
    assert "fn_marca_rechazada_purgar(p_dias integer DEFAULT 90)" in s84 and "fn_marca_rechazada_purgar(integer) TO service_role" in s84


def test_el_catalogo_del_backend_coincide_con_el_de_la_base_89():
    sql = _ddl("89")
    bloque = re.search(r"fn_terminal_config_catalogo\(\).*?\$\$;", sql, re.S).group(0)
    filas = re.findall(r"\('(terminal_[a-z_]+)'(?:::text)?,\s*(\d+),\s*(\d+),\s*(\d+)\)", bloque)
    assert len(filas) == 5
    assert {c: (int(d), int(mi), int(ma)) for c, d, mi, ma in filas} == {
        c: (v.defecto, v.minimo, v.maximo) for c, v in CATALOGO_TERMINAL.items()
    }


def test_los_hints_de_la_base_que_mapea_c7_existen_en_89():
    sql = _ddl("89")
    for hint in ("clave_no_editable", "valor_invalido", "sin_permiso"):
        assert f"HINT = '{hint}'" in sql
    assert "ERRCODE = 'SCJ02'" in sql


# --- ajustes de security a C7 y pedido de frontend -----------------------------------------------------------------------


def test_listado_marca_el_valor_ilegible(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "abc"), _param("terminal_llave_max_meses", "12")]), usuario=tabla([]))
    por_clave = {v["clave"]: v for v in _get(RUTA).json()}
    assert por_clave[CAD]["valor_ilegible"] is True and por_clave[CAD]["valor"] == 24
    assert por_clave["terminal_llave_max_meses"]["valor_ilegible"] is False
    assert por_clave["terminal_retencion_rechazos_dias"]["valor_ilegible"] is False  # faltante != ilegible


def test_historial_marca_el_valor_ilegible_por_fila(entorno):
    entorno.configurar(parametro=tabla([_param(CAD, "abc"), _param(CAD, "999", hasta="2026-01-01"), _param(CAD, "48")]),
                       usuario=tabla([]))
    assert [x["valor_ilegible"] for x in _get(f"{RUTA}/historial").json()] == [True, True, False]


@pytest.mark.parametrize("error", [APIError({"code": "XX999", "message": CRUDO}), ConnectionError(CRUDO), TimeoutError(CRUDO)])
def test_simular_que_no_puede_calcular_da_503_claro(entorno, error, caplog):
    roto = MagicMock()
    for nombre in ("select", "eq", "order"):
        getattr(roto, nombre).return_value = roto
    roto.execute.side_effect = error
    entorno.configurar(parametro=tabla([_param(CAD, "24")]), terminal_usuario=roto, persona=tabla([]))
    with caplog.at_level(logging.ERROR):
        r = _c().post(f"{RUTA}/{CAD}/simular", json={"valor": 12}, headers=AUTH)
    assert r.status_code == 503 and r.json() == {"detail": "No se pudo calcular el impacto; intenta de nuevo."}
    assert "9921" not in r.text and "9921" not in caplog.text
