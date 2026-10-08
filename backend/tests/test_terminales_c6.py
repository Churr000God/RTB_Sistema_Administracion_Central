"""C6 del contrato de Terminales: reconsentimiento (por alta y en lote), elegibilidad con razones, filtro/contador y
lista de ids pendientes. Mocks por NOMBRE de tabla; NUNCA contra la base real."""

import logging
import re
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, TablaConCadenas, db_por_nombre, llamadas, tabla
from app import permisos
from app.altas_terminal import razon_no_elegible
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
PROPIA = "pppppppp-0000-0000-0000-000000000009"
OTRA = "aaaaaaaa-0000-0000-0000-000000000001"
CRUDO = "texto-crudo-id-interno-6613"
VIGENTE = {
    "id": 4, "version": 4, "texto": "Texto v4", "texto_sha256": "a" * 64, "provisional": False,
    "cambio_material": True, "nota": None, "creado_por": "p", "creado_en": "2026-10-08T10:00:00+00:00",
}


def _alta(id_, estado="activo", persona=OTRA, terminal=1, consentimiento_id=2):
    return {
        "id": id_, "terminal_id": terminal, "employee_no": 1000 + id_, "persona_id": persona, "estado": estado,
        "huellas_capturadas": 2, "error_detalle": None, "creado_en": "2026-10-07T09:00:00+00:00",
        "actualizado_en": "2026-10-07T09:30:00+00:00", "usuario_creado_en": None, "consentimiento_id": consentimiento_id,
    }


@pytest.fixture
def entorno(monkeypatch):
    entorno.codigos = []
    entorno.permitido = True
    entorno.admin_generico = False
    entorno.pendientes = []
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: PROPIA)

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return entorno.permitido

    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)
    monkeypatch.setattr(permisos, "es_administrador_generico", lambda db, persona: entorno.admin_generico)

    def configurar(**tablas):
        tablas.setdefault("terminal", tabla([{"id": 1}]))
        tablas.setdefault("terminal_consentimiento", tabla([VIGENTE]))
        tablas.setdefault("persona", tabla([
            {"id": OTRA, "primer_nombre": "Ana", "apellido_paterno": "Torres"},
            {"id": PROPIA, "primer_nombre": "Yo", "apellido_paterno": "Mismo"},
        ]))
        db = db_por_nombre(estricto=True, **tablas)
        rpc = db.postgrest.schema.return_value.rpc

        def segun_funcion(nombre, params):
            r = rpc.return_value
            if nombre == "fn_terminal_reconsentimiento_pendiente_ids":
                r.execute.side_effect = None  # el mock del RPC es compartido: no heredar el error del otro RPC
                r.execute.return_value = Resultado(entorno.pendientes)
            return r

        rpc.side_effect = segun_funcion
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_service_client] = lambda: db_por_nombre(parametro=tabla([]))
        entorno.db, entorno.rpc = db, rpc
        return db

    entorno.configurar = configurar
    return entorno


def _cliente():
    return TestClient(app, raise_server_exceptions=False)


def _get(ruta):
    return _cliente().get(ruta, headers=AUTH)


def _post(ruta, cuerpo):
    return _cliente().post(ruta, json=cuerpo, headers=AUTH)


def _llamadas_rpc(entorno, nombre):
    return [c for c in entorno.rpc.call_args_list if c.args[0] == nombre]


# --- regla de elegibilidad -------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "estado,persona,es_admin,pendiente,esperado",
    [
        ("activo", OTRA, False, True, None),
        ("esperando_huella", OTRA, False, True, None),
        ("pendiente_alta", OTRA, False, True, None),
        ("activo", OTRA, False, False, "ya_al_corriente"),
        ("pendiente_baja", OTRA, False, True, "en_baja"),
        ("baja", OTRA, False, False, "en_baja"),
        ("activo", PROPIA, False, True, "es_propia"),
        ("activo", PROPIA, True, True, None),  # el administrador genérico sí puede con la suya
        ("activo", PROPIA, False, False, "es_propia"),  # prioridad: es_propia antes que ya_al_corriente
        ("baja", PROPIA, False, True, "en_baja"),  # prioridad: en_baja antes que es_propia
        ("activo", PROPIA, True, False, "ya_al_corriente"),
    ],
)
def test_razon_no_elegible(estado, persona, es_admin, pendiente, esperado):
    ctx = SimpleNamespace(es_propia=lambda p: p == PROPIA, es_admin=es_admin)
    assert razon_no_elegible(estado, persona, ctx, pendiente) == esperado


def test_la_consulta_de_administrador_solo_ocurre_si_la_alta_es_propia():
    """B3: es_admin es perezoso; una alta ajena nunca lo consulta (y no depende de qué altas se armen)."""
    consultas = []

    class Ctx:
        es_propia = staticmethod(lambda p: p == PROPIA)

        @property
        def es_admin(self):
            consultas.append(1)
            return False

    razon_no_elegible("activo", OTRA, Ctx(), True)
    assert consultas == []
    razon_no_elegible("activo", PROPIA, Ctx(), True)
    assert consultas == [1]


# --- listado: filtro, contador y campos por alta -------------------------------------------------------------------------


def _lista(altas, pend=None):
    """Orden de lecturas de terminal_usuario: (si hay pendientes) las altas de la terminal para intersectar; la
    página; y los 5 conteos por estado."""
    return TablaConCadenas(*([Resultado(pend)] if pend else []), Resultado(altas, len(altas)), *([Resultado([], 0)] * 5))


def _fila(id_, persona=OTRA):
    return {"id": id_, "persona_id": persona}


@pytest.mark.parametrize("filtro,metodo", [("pendiente", False), ("al_corriente", True)])
def test_filtro_de_reconsentimiento_usa_los_pendientes_de_esta_terminal_no_los_globales(entorno, filtro, metodo):
    entorno.pendientes = [78, 79, 5000, 5001]  # 5000 y 5001 son de otras terminales
    tu = _lista([_alta(78)], pend=[_fila(78), _fila(79), _fila(80)])
    entorno.configurar(terminal_usuario=tu)
    assert _get(f"/api/terminales/1/usuarios?reconsentimiento={filtro}").status_code == 200
    pend_query, principal = tu.cadenas[1], tu.cadenas[0]
    assert llamadas(pend_query, "eq") == [(("terminal_id", 1), {})]  # primero se acota por terminal
    assert llamadas(principal, "in_") == [(("id", [78, 79]), {})]  # la URL del filtro sólo lleva ids de ESTA terminal
    assert ("not_" in [m for m, _, _ in principal]) is metodo


def test_filtro_pendiente_sin_pendientes_devuelve_vacio_sin_consultar_las_altas(entorno):
    tu = TablaConCadenas(*([Resultado([], 0)] * 5))
    entorno.configurar(terminal_usuario=tu)
    r = _get("/api/terminales/1/usuarios?reconsentimiento=pendiente").json()
    assert r["total"] == 0 and r["altas"] == []
    assert tu._resultados == []  # las 5 del resumen consumieron todo: la principal no se ejecutó


def test_filtro_pendiente_con_pendientes_solo_de_otras_terminales_tambien_es_vacio(entorno):
    entorno.pendientes = [5000]
    tu = TablaConCadenas(Resultado([_fila(78)]), *([Resultado([], 0)] * 5))
    entorno.configurar(terminal_usuario=tu)
    r = _get("/api/terminales/1/usuarios?reconsentimiento=pendiente").json()
    assert r["total"] == 0 and r["resumen"]["reconsentimiento_pendiente"] == 0


def test_filtro_al_corriente_sin_pendientes_no_agrega_exclusion(entorno):
    tu = _lista([_alta(78)])
    entorno.configurar(terminal_usuario=tu)
    _get("/api/terminales/1/usuarios?reconsentimiento=al_corriente")
    assert "not_" not in [m for m, _, _ in tu.cadenas[0]]


def test_valor_de_filtro_invalido_da_422(entorno):
    entorno.configurar(terminal_usuario=_lista([]))
    assert _get("/api/terminales/1/usuarios?reconsentimiento=otro").status_code == 422


def test_resumen_cuenta_los_pendientes_de_esta_terminal(entorno):
    entorno.pendientes = [78, 90]  # 90 es de otra terminal
    tu = _lista([_alta(78)], pend=[_fila(78), _fila(79)])
    entorno.configurar(terminal_usuario=tu)
    r = _get("/api/terminales/1/usuarios").json()
    assert r["resumen"]["reconsentimiento_pendiente"] == 1


def test_cada_alta_trae_es_propia_elegible_y_razon(entorno):
    entorno.pendientes = [1, 2, 4]
    altas = [
        _alta(1, "activo", OTRA),
        _alta(2, "activo", PROPIA),
        _alta(3, "activo", OTRA),
        _alta(4, "pendiente_baja", OTRA),
    ]
    tu = _lista(altas, pend=[_fila(1), _fila(2, PROPIA)])
    entorno.configurar(terminal_usuario=tu)
    por_id = {a["id"]: a for a in _get("/api/terminales/1/usuarios").json()["altas"]}
    assert (por_id[1]["es_propia"], por_id[1]["reconsentimiento_elegible"], por_id[1]["reconsentimiento_razon"]) == (False, True, None)
    assert (por_id[2]["es_propia"], por_id[2]["reconsentimiento_elegible"], por_id[2]["reconsentimiento_razon"]) == (True, False, "es_propia")
    assert (por_id[3]["reconsentimiento_elegible"], por_id[3]["reconsentimiento_razon"]) == (False, "ya_al_corriente")
    assert (por_id[4]["reconsentimiento_elegible"], por_id[4]["reconsentimiento_razon"]) == (False, "en_baja")


def test_el_administrador_generico_puede_reconsentir_la_suya(entorno):
    entorno.admin_generico = True
    entorno.pendientes = [2]
    tu = _lista([_alta(2, "activo", PROPIA)], pend=[_fila(2, PROPIA)])
    entorno.configurar(terminal_usuario=tu)
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert a["es_propia"] is True and a["reconsentimiento_elegible"] is True and a["reconsentimiento_razon"] is None


# --- GET reconsentimientos-pendientes --------------------------------------------------------------------------------


def _ids(entorno, tu, ruta="/api/terminales/1/reconsentimientos-pendientes"):
    entorno.configurar(terminal_usuario=tu)
    return _get(ruta)


def test_pendientes_de_la_terminal_excluyen_la_alta_propia(entorno):
    entorno.pendientes = [5, 6, 7, 9000]
    tu = TablaConCadenas(Resultado([_fila(5), _fila(6, PROPIA), _fila(7), _fila(8)]))  # 8 ya está al corriente
    r = _ids(entorno, tu)
    assert r.status_code == 200, r.text
    assert r.json() == {"total": 2, "ids": [5, 7], "hay_mas": False}
    cadena = tu.cadenas[0]
    assert llamadas(cadena, "eq") == [(("terminal_id", 1), {})]
    assert llamadas(cadena, "in_") == [(("estado", ["pendiente_alta", "esperando_huella", "activo"]), {})]
    assert llamadas(cadena, "limit") == [((1000,), {})]  # nunca una URL con los ids pendientes de todo el sistema


def test_el_administrador_generico_ve_tambien_la_suya(entorno):
    entorno.admin_generico = True
    entorno.pendientes = [5, 6]
    tu = TablaConCadenas(Resultado([_fila(5), _fila(6, PROPIA)]))
    assert _ids(entorno, tu).json()["ids"] == [5, 6]


def test_hay_mas_cuando_el_total_pasa_de_200(entorno):
    entorno.pendientes = list(range(1, 301))
    tu = TablaConCadenas(Resultado([_fila(i) for i in range(1, 301)]))
    r = _ids(entorno, tu).json()
    assert r["total"] == 300 and len(r["ids"]) == 200 and r["hay_mas"] is True


def test_sin_pendientes_no_consulta_las_altas(entorno):
    tu = TablaConCadenas()
    r = _ids(entorno, tu)
    assert r.json() == {"total": 0, "ids": [], "hay_mas": False} and tu.cadenas == []


def test_la_consulta_de_administrador_no_ocurre_si_no_hay_altas_propias(entorno):
    entorno.pendientes = [5]
    consultas = []
    import app.permisos as p

    original = p.es_administrador_generico
    p.es_administrador_generico = lambda db, persona: consultas.append(1) or False
    try:
        _ids(entorno, TablaConCadenas(Resultado([_fila(5)])))
    finally:
        p.es_administrador_generico = original
    assert consultas == []


def test_pendientes_exige_lectura_y_terminal_existente(entorno):
    entorno.pendientes = [5]
    tu = TablaConCadenas(Resultado([]))
    entorno.configurar(terminal_usuario=tu, terminal=tabla([]))
    assert _get("/api/terminales/9/reconsentimientos-pendientes").status_code == 404
    entorno.permitido = False
    assert _get("/api/terminales/1/reconsentimientos-pendientes").status_code == 403
    assert entorno.codigos[-1] == ("terminal_usuario_lectura", "terminal_usuario_edicion")


# --- POST lote y por alta ----------------------------------------------------------------------------------------------


RUTA_LOTE = "/api/terminales/1/usuarios/reconsentimientos"
CUERPO = {"tu_ids": [5, 6], "consentimiento_id": 4, "declaracion_documentos": True}


def _con_rpc(entorno, resultado=None, error=None, altas=None, pendientes=(5, 6)):
    entorno.pendientes = list(pendientes)
    altas = altas if altas is not None else [_alta(5), _alta(6)]
    db = entorno.configurar(terminal_usuario=tabla(altas))
    base = entorno.rpc.side_effect

    def segun(nombre, params):
        r = base(nombre, params)
        if nombre == "fn_terminal_reconsentir":
            if error is not None:
                r.execute.side_effect = error
            else:
                r.execute.return_value = Resultado(
                    resultado if resultado is not None else {"resultado": "ok", "registradas": 2, "omitidas": [], "motivos_omision": {}}
                )
        return r

    entorno.rpc.side_effect = segun
    return db


def test_lote_exitoso_llama_al_rpc_estricto_con_ids_unicos_y_ordenados(entorno):
    _con_rpc(entorno)
    r = _post(RUTA_LOTE, {**CUERPO, "tu_ids": [6, 5, 5, 6]})
    assert r.status_code == 201, r.text
    assert r.json() == {"registradas": 2, "pendientes_restantes": 2, "omitidas": []}
    nombre, params = _llamadas_rpc(entorno, "fn_terminal_reconsentir")[0].args
    assert params == {"p_altas": [5, 6], "p_consentimiento_id": 4, "p_estricto": True}
    assert entorno.codigos == [("terminal_usuario_edicion",)]


def test_por_alta_equivale_a_un_lote_de_uno(entorno):
    _con_rpc(entorno, resultado={"resultado": "ok", "registradas": 1, "omitidas": [], "motivos_omision": {}}, pendientes=(5,))
    r = _post("/api/terminales/1/usuarios/5/reconsentimiento", {"consentimiento_id": 4, "declaracion_documentos": True})
    assert r.status_code == 201 and r.json()["registradas"] == 1
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir")[0].args[1]["p_altas"] == [5]


@pytest.mark.parametrize(
    "cuerpo",
    [
        {**CUERPO, "declaracion_documentos": False},
        {**CUERPO, "tu_ids": []},
        {**CUERPO, "tu_ids": list(range(1, 202))},
        {**CUERPO, "tu_ids": [0]},
        {**CUERPO, "tu_ids": ["x"]},
        {**CUERPO, "consentimiento_id": 0},
        {**CUERPO, "otro": 1},
        {"tu_ids": [5], "consentimiento_id": 4},
        {**CUERPO, "tu_ids": list(range(1, 1002))},
    ],
)
def test_cuerpos_invalidos_dan_422_sin_llamar_al_rpc(entorno, cuerpo):
    _con_rpc(entorno)
    assert _post(RUTA_LOTE, cuerpo).status_code == 422
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir") == []


def test_mensajes_fijos_de_lote_invalido_y_declaracion(entorno):
    _con_rpc(entorno)
    assert _post(RUTA_LOTE, {**CUERPO, "tu_ids": []}).json()["detail"] == "El lote debe traer entre 1 y 200 altas."
    assert "documentos firmados" in _post(RUTA_LOTE, {**CUERPO, "declaracion_documentos": False}).json()["detail"]


def test_exactamente_200_ids_pasan(entorno):
    _con_rpc(entorno, resultado={"resultado": "ok", "registradas": 200, "omitidas": [], "motivos_omision": {}},
             altas=[_alta(i) for i in range(1, 201)], pendientes=range(1, 201))
    assert _post(RUTA_LOTE, {**CUERPO, "tu_ids": list(range(1, 201))}).status_code == 201


def test_consentimiento_que_no_es_el_vigente_da_409_con_texto_y_no_llama_al_rpc(entorno):
    _con_rpc(entorno)
    r = _post(RUTA_LOTE, {**CUERPO, "consentimiento_id": 3})
    assert r.status_code == 409 and r.json()["consentimiento_vigente"]["id"] == 4
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir") == []


def test_no_elegibles_409_con_razones_nombres_y_sin_escribir(entorno):
    altas = [
        _alta(5, "activo", OTRA),            # elegible (pendiente)
        _alta(6, "activo", OTRA),            # ya al corriente
        _alta(7, "pendiente_baja", OTRA),    # en baja
        _alta(8, "activo", PROPIA),          # propia
    ]
    _con_rpc(entorno, altas=altas, pendientes=(5, 8))
    r = _post(RUTA_LOTE, {**CUERPO, "tu_ids": [5, 6, 7, 8, 99]})
    assert r.status_code == 409
    cuerpo = r.json()
    assert cuerpo["detail"] == "No se registró nada: algunas altas ya no son elegibles."
    assert cuerpo["no_elegibles"] == [
        {"tu_id": 6, "persona_nombre": "Ana Torres", "razon": "ya_al_corriente"},
        {"tu_id": 7, "persona_nombre": "Ana Torres", "razon": "en_baja"},
        {"tu_id": 8, "persona_nombre": "Yo Mismo", "razon": "es_propia"},
        {"tu_id": 99, "persona_nombre": None, "razon": "no_encontrada"},
    ]
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir") == []


def test_la_verificacion_se_acota_a_la_terminal_de_la_url(entorno):
    tu = tabla([])
    entorno.pendientes = [5]
    entorno.configurar(terminal_usuario=tu)
    r = _post(RUTA_LOTE, {**CUERPO, "tu_ids": [5]})
    assert r.status_code == 409 and r.json()["no_elegibles"][0]["razon"] == "no_encontrada"
    assert ("terminal_id", 1) in [c.args for c in tu.eq.call_args_list]


def test_el_administrador_generico_puede_incluir_la_suya(entorno):
    entorno.admin_generico = True
    _con_rpc(entorno, altas=[_alta(8, "activo", PROPIA)], pendientes=(8,),
             resultado={"resultado": "ok", "registradas": 1, "omitidas": [], "motivos_omision": {}})
    assert _post(RUTA_LOTE, {**CUERPO, "tu_ids": [8]}).status_code == 201


def test_carrera_con_lista_reconstruida_vacia_da_mensaje_fijo_de_reintento(entorno):
    """B1: si tras la carrera todo vuelve a ser elegible, no se devuelve un 409 con no_elegibles=[] incomprensible."""
    error = APIError({"code": "22023", "hint": "lote_no_elegible", "message": CRUDO, "details": "5,6"})
    _con_rpc(entorno, error=error)
    r = _post(RUTA_LOTE, CUERPO)
    assert r.status_code == 409 and "6613" not in r.text and "5,6" not in r.text
    assert r.json() == {
        "detail": "No se registró nada porque el estado de las altas cambió; vuelve a intentarlo.",
        "codigo": "lote_reintentar",
    }


def test_carrera_con_lista_reconstruida_no_vacia_devuelve_no_elegibles(entorno):
    """El RPC rechaza por carrera; al reconstruir, la 6 ya no está pendiente: se devuelve esa lista (sin el DETAIL)."""
    error = APIError({"code": "22023", "hint": "lote_no_elegible", "message": CRUDO, "details": "6"})
    _con_rpc(entorno, error=error)
    cambios = iter([[5, 6], [5]])  # 1a lectura (verificación previa): ambas pendientes; 2a (tras el RPC): sólo la 5

    base = entorno.rpc.side_effect

    def segun(nombre, params):
        r = base(nombre, params)
        if nombre == "fn_terminal_reconsentimiento_pendiente_ids":
            r.execute.return_value = Resultado(next(cambios))
        return r

    entorno.rpc.side_effect = segun
    r = _post(RUTA_LOTE, CUERPO)
    assert r.status_code == 409
    assert [x["tu_id"] for x in r.json()["no_elegibles"]] == [6] and r.json()["no_elegibles"][0]["razon"] == "ya_al_corriente"
    assert "6613" not in r.text


def test_ids_de_otra_terminal_e_inexistentes_mezclados_dan_la_misma_razon_sin_nombre(entorno):
    """B6: del lado del caller, «otra terminal» e «inexistente» son indistinguibles (no se filtra existencia)."""
    _con_rpc(entorno, altas=[_alta(5)], pendientes=(5,))  # sólo la 5 existe EN ESTA terminal
    r = _post(RUTA_LOTE, {**CUERPO, "tu_ids": [5, 777, 999999]})  # 777: de otra terminal; 999999: no existe
    assert r.status_code == 409
    assert r.json()["no_elegibles"] == [
        {"tu_id": 777, "persona_nombre": None, "razon": "no_encontrada"},
        {"tu_id": 999999, "persona_nombre": None, "razon": "no_encontrada"},
    ]
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir") == []


@pytest.mark.parametrize(
    "codigo,hint,estado,fragmento",
    [
        ("SCJ12", "auto_reconsentimiento_prohibido", 422, "No puedes registrar tu propio reconsentimiento"),
        ("SCJ16", "consentimiento_desactualizado", 409, "El texto de consentimiento cambió"),
        ("SCJ11", "transicion_invalida", 409, "no es válido para el estado actual"),
        ("22023", "lote_invalido", 422, "entre 1 y 200"),
        ("42501", "sin_permiso", 403, "No tienes permiso"),
    ],
)
def test_errores_del_rpc_con_mensaje_fijo(entorno, codigo, hint, estado, fragmento):
    _con_rpc(entorno, error=APIError({"code": codigo, "hint": hint, "message": CRUDO}))
    r = _post(RUTA_LOTE, CUERPO)
    assert r.status_code == estado and fragmento in r.json()["detail"] and "6613" not in r.text


def test_carrera_de_version_trae_el_vigente(entorno):
    _con_rpc(entorno, error=APIError({"code": "SCJ16", "hint": "consentimiento_desactualizado", "message": CRUDO}))
    assert _post(RUTA_LOTE, CUERPO).json()["consentimiento_vigente"]["id"] == 4


def test_error_desconocido_es_500_sin_texto(entorno):
    _con_rpc(entorno, error=APIError({"code": "XX999", "message": CRUDO}))
    r = _post(RUTA_LOTE, CUERPO)
    assert r.status_code == 500 and "6613" not in r.text


@pytest.mark.parametrize("forma", [None, [], "x", {"resultado": "ok"}, {"registradas": "2"}])
def test_respuesta_inesperada_del_rpc_es_503(entorno, forma):
    _con_rpc(entorno, resultado=forma if forma is not None else [])
    assert _post(RUTA_LOTE, CUERPO).status_code == 503


def test_omitidas_pese_al_modo_estricto_se_informan_y_se_loguean(entorno, caplog):
    _con_rpc(entorno, resultado={"resultado": "ok", "registradas": 1, "omitidas": [6], "motivos_omision": {"6": "no_elegible"}})
    with caplog.at_level(logging.ERROR):
        r = _post(RUTA_LOTE, CUERPO)
    assert r.status_code == 201 and r.json()["omitidas"] == [6]
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_exige_edicion_y_sin_permiso_no_consulta_ni_escribe(entorno):
    _con_rpc(entorno)
    entorno.permitido = False
    assert _post(RUTA_LOTE, CUERPO).status_code == 403
    assert _llamadas_rpc(entorno, "fn_terminal_reconsentir") == []


def test_terminal_inexistente_y_fronteras_de_ids(entorno):
    entorno.configurar(terminal_usuario=tabla([]), terminal=tabla([]))
    assert _post("/api/terminales/9/usuarios/reconsentimientos", CUERPO).status_code == 404
    assert _post("/api/terminales/0/usuarios/reconsentimientos", CUERPO).status_code == 422
    assert _post("/api/terminales/1/usuarios/0/reconsentimiento", {"consentimiento_id": 4, "declaracion_documentos": True}).status_code == 422


def test_la_ruta_del_lote_no_se_confunde_con_la_de_una_alta(entorno):
    """`reconsentimientos` (lote) no debe capturarse como {tu_id}: ambas rutas conviven."""
    _con_rpc(entorno)
    assert _post(RUTA_LOTE, CUERPO).status_code == 201
    assert _post("/api/terminales/1/usuarios/reconsentimientos/reconsentimiento",
                 {"consentimiento_id": 4, "declaracion_documentos": True}).status_code == 422


# --- contrato RPC <-> DDL (88_) ----------------------------------------------------------------------------------------


def _ddl88():
    return next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob("88_*.sql")).read_text(encoding="utf-8")


def test_firma_de_fn_terminal_reconsentir_y_sus_hints_en_88():
    sql = _ddl88()
    assert "fn_terminal_reconsentir(p_altas bigint[], p_consentimiento_id bigint, p_estricto boolean DEFAULT false)" in sql
    assert "GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentir(bigint[], bigint, boolean) TO authenticated" in sql
    for hint in ("lote_invalido", "lote_no_elegible", "auto_reconsentimiento_prohibido"):
        assert f"HINT = '{hint}'" in sql
    assert re.search(r"'resultado', 'ok', 'registradas', v_n, 'omitidas'", sql)


def test_la_definicion_unica_de_pendientes_existe_con_grants():
    sql = _ddl88()
    assert "CREATE FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids()" in sql
    assert "GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids() TO authenticated, service_role" in sql


# --- ContextoCaller perezoso (testing P3) -----------------------------------------------------------------------------------------


def test_listado_sin_altas_propias_no_consulta_el_puesto_administrador(entorno, monkeypatch):
    espia = MagicMock(return_value=False)
    monkeypatch.setattr(permisos, "es_administrador_generico", espia)
    entorno.pendientes = [1]
    tu = _lista([_alta(1, "activo", OTRA), _alta(2, "activo", OTRA)], pend=[_fila(1)])
    entorno.configurar(terminal_usuario=tu)
    assert _get("/api/terminales/1/usuarios").status_code == 200
    espia.assert_not_called()


def test_reconsentimiento_sin_altas_propias_no_consulta_el_puesto_administrador(entorno, monkeypatch):
    espia = MagicMock(return_value=False)
    monkeypatch.setattr(permisos, "es_administrador_generico", espia)
    _con_rpc(entorno)
    assert _post(RUTA_LOTE, CUERPO).status_code == 201
    espia.assert_not_called()


def test_con_una_alta_propia_se_consulta_una_sola_vez_aunque_haya_varias(entorno, monkeypatch):
    espia = MagicMock(return_value=False)
    monkeypatch.setattr(permisos, "es_administrador_generico", espia)
    entorno.pendientes = [1, 2]
    tu = _lista([_alta(1, "activo", PROPIA), _alta(2, "activo", PROPIA)], pend=[_fila(1, PROPIA), _fila(2, PROPIA)])
    entorno.configurar(terminal_usuario=tu)
    _get("/api/terminales/1/usuarios")
    assert espia.call_count == 1  # cacheado dentro del ContextoCaller
