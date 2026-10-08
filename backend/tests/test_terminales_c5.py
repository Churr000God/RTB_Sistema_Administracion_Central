"""C5 del contrato de Terminales: consentimiento versionado (GET, impacto, publicar) y asignar con
consentimiento_id. Mocks del cliente de Supabase por NOMBRE de tabla; NUNCA contra la base real."""

import logging
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, TablaConCadenas, db_por_nombre, llamadas, tabla
from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import traducir_error_terminal_web
from app.main import app

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
PROPIA = "persona-ficticia"
PERSONA = "aaaaaaaa-0000-0000-0000-000000000001"
CRUDO = "texto-crudo-id-interno-8814"


def _version(id_, version, **extra):
    fila = {
        "id": id_, "version": version, "texto": f"Texto v{version}", "texto_sha256": "a" * 64,
        "provisional": False, "cambio_material": False, "nota": None, "creado_por": "p-autor",
        "creado_en": f"2026-10-0{version}T10:00:00+00:00",
    }
    fila.update(extra)
    return fila


SEMILLA = _version(1, 1, provisional=True, creado_por=None, texto="Provisional")
V2 = _version(2, 2, cambio_material=True, nota="Cambio del aviso")
V3 = _version(3, 3)


@pytest.fixture
def entorno(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: PROPIA)
    entorno.codigos = []

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return entorno.permitido

    entorno.permitido = True
    entorno.admin_generico = False
    entorno.pendientes = []
    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)
    monkeypatch.setattr(permisos, "es_administrador_generico", lambda db, persona: entorno.admin_generico)

    def configurar(**tablas):
        db = db_por_nombre(estricto=True, **tablas)
        rpc = db.postgrest.schema.return_value.rpc
        rpc.return_value.execute.return_value = Resultado(entorno.pendientes)
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER

        def sin_service():
            raise AssertionError("el consentimiento NUNCA usa service_role")

        app.dependency_overrides[get_service_client] = sin_service
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


RUTA = "/api/terminales/configuracion/consentimiento"


# --- GET ---------------------------------------------------------------------------------------------------


def test_lee_vigente_e_historial_con_vigencia_derivada_y_autor(entorno):
    tablas = {
        "terminal_consentimiento": tabla([V3, V2, SEMILLA]),
        "persona": tabla([{"id": "p-autor", "primer_nombre": "Carlos", "apellido_paterno": "Ruiz"}]),
    }
    entorno.configurar(**tablas)
    r = _get(RUTA)
    assert r.status_code == 200, r.text
    cuerpo = r.json()
    assert cuerpo["vigente"]["version"] == 3 and cuerpo["vigente"]["vigente_hasta"] is None
    assert cuerpo["vigente"]["publicado_por_nombre"] == "Carlos Ruiz" and cuerpo["vigente"]["es_semilla"] is False
    hist = cuerpo["historial"]
    assert [h["version"] for h in hist] == [3, 2, 1]
    assert hist[1]["vigente_hasta"] == V3["creado_en"].replace("+00:00", "Z")  # hasta = creado_en de la siguiente
    assert hist[2]["vigente_hasta"] == V2["creado_en"].replace("+00:00", "Z")
    assert hist[1]["motivo_cambio"] == "Cambio del aviso" and hist[1]["cambio_material"] is True
    assert hist[2]["es_semilla"] is True and hist[2]["publicado_por_nombre"] is None and hist[2]["provisional"] is True
    assert hist[0]["vigente_desde"] == V3["creado_en"].replace("+00:00", "Z")


def test_el_historial_se_pide_ordenado_por_version_desc_y_acotado(entorno):
    t = TablaConCadenas([V2, SEMILLA], [])
    entorno.configurar(terminal_consentimiento=t, persona=tabla([]))
    _get(RUTA)
    cadena = t.cadenas[0]
    assert llamadas(cadena, "order") == [(("version",), {"desc": True})]
    assert llamadas(cadena, "limit") == [((200,), {})]


def test_el_texto_se_devuelve_literal_como_texto_plano(entorno):
    html = "<script>alert(1)</script> & línea\nsiguiente"
    entorno.configurar(terminal_consentimiento=tabla([_version(2, 2, texto=html)]), persona=tabla([]))
    assert _get(RUTA).json()["vigente"]["texto"] == html


def test_sin_filas_da_404_fijo_sin_inventar_texto(entorno):
    entorno.configurar(terminal_consentimiento=tabla([]), persona=tabla([]))
    r = _get(RUTA)
    assert r.status_code == 404 and r.json()["detail"] == "Todavía no hay texto de consentimiento."


def test_get_gate_incluye_a_quien_solo_configura(entorno):
    entorno.configurar(terminal_consentimiento=tabla([SEMILLA]), persona=tabla([]))
    assert _get(RUTA).status_code == 200
    assert entorno.codigos[-1] == ("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
    entorno.permitido = False
    assert _get(RUTA).status_code == 403


# --- impacto -----------------------------------------------------------------------------------------------


def _tablas_impacto(vigente, en_proceso=(2, 1), activas=11):
    tu = TablaConCadenas(
        Resultado([], en_proceso[0]), Resultado([], en_proceso[1]), Resultado([], activas)
    )
    return {"terminal_consentimiento": tabla([vigente]), "terminal_usuario": tu}, tu


def test_impacto_con_provisional_fuerza_el_cambio_material(entorno):
    tablas, tu = _tablas_impacto(SEMILLA)
    entorno.pendientes = [5, 6]
    entorno.configurar(**tablas)
    r = _get(f"{RUTA}/impacto?cambio_material=false")
    assert r.status_code == 200, r.text
    assert r.json() == {
        "cambio_material_efectivo": True, "forzado": True, "altas_que_quedarian_pendientes": 14,
        "en_proceso": 3, "activas": 11, "pendientes_actuales": 2,
    }
    estados = [llamadas(c, "eq")[0][0][1] for c in tu.cadenas]
    assert estados == ["pendiente_alta", "esperando_huella", "activo"]
    assert all(c[0][2] == {"count": "exact", "head": True} for c in tu.cadenas)


@pytest.mark.parametrize("pedido,esperado", [("true", 14), ("false", 0)])
def test_impacto_sobre_definitiva_solo_cuenta_si_se_pide_cambio_material(entorno, pedido, esperado):
    tablas, _ = _tablas_impacto(V3)
    entorno.configurar(**tablas)
    r = _get(f"{RUTA}/impacto?cambio_material={pedido}").json()
    assert r["forzado"] is False and r["cambio_material_efectivo"] is (pedido == "true")
    assert r["altas_que_quedarian_pendientes"] == esperado


def test_impacto_cambio_material_invalido_da_422_y_gate(entorno):
    tablas, _ = _tablas_impacto(V3)
    entorno.configurar(**tablas)
    assert _get(f"{RUTA}/impacto?cambio_material=quizas").status_code == 422
    entorno.permitido = False
    assert _get(f"{RUTA}/impacto").status_code == 403


# --- publicar ----------------------------------------------------------------------------------------------


def _con_rpc(entorno, resultado=None, error=None, vigente=V3):
    db = entorno.configurar(terminal_consentimiento=tabla([vigente] if vigente else []), persona=tabla([]))
    ejecucion = entorno.rpc.return_value.execute
    if error is not None:
        ejecucion.side_effect = error
    else:
        ejecucion.return_value = Resultado(resultado)
    return db


CUERPO = {"texto": "Nuevo texto", "cambio_material": False, "motivo_cambio": "Corrección", "base_version": 3}


def test_publica_y_llama_al_rpc_con_los_parametros_exactos(entorno):
    _con_rpc(entorno, {"resultado": "publicada", "id": 9, "version": 4, "cambio_material": False, "pendientes": 0})
    r = _post(RUTA, CUERPO)
    assert r.status_code == 201, r.text
    assert r.json() == {
        "resultado": "publicada", "id": 9, "version": 4, "cambio_material": False,
        "cambio_material_forzado": False, "pendientes": 0,
    }
    nombre, params = entorno.rpc.call_args.args
    assert nombre == "fn_terminal_consentimiento_publicar"
    assert params == {"p_texto": "Nuevo texto", "p_cambio_material": False, "p_nota": "Corrección", "p_base_version": 3}
    assert entorno.codigos == [("terminal_config_edicion",)]


def test_cambio_material_forzado_se_refleja_cuando_la_base_lo_prende_sola(entorno):
    _con_rpc(entorno, {"resultado": "publicada", "id": 9, "version": 2, "cambio_material": True, "pendientes": 14})
    r = _post(RUTA, {**CUERPO, "base_version": 1}).json()
    assert r["cambio_material"] is True and r["cambio_material_forzado"] is True and r["pendientes"] == 14


def test_cambio_material_pedido_no_cuenta_como_forzado(entorno):
    _con_rpc(entorno, {"resultado": "publicada", "id": 9, "version": 4, "cambio_material": True, "pendientes": 3})
    assert _post(RUTA, {**CUERPO, "cambio_material": True}).json()["cambio_material_forzado"] is False


def test_sin_cambio_da_200(entorno):
    _con_rpc(entorno, {"resultado": "sin_cambio", "version": 3, "id": 3})
    r = _post(RUTA, CUERPO)
    assert r.status_code == 200 and r.json()["resultado"] == "sin_cambio" and r.json()["version"] == 3


@pytest.mark.parametrize(
    "cuerpo",
    [
        {**CUERPO, "provisional": True},  # el RPC nunca publica provisional
        {**CUERPO, "otro": 1},
        {"cambio_material": False, "base_version": 3},  # sin texto
        {**CUERPO, "texto": ""},
        {**CUERPO, "texto": "x" * 4001},
        {**CUERPO, "motivo_cambio": "n" * 201},
        {k: v for k, v in CUERPO.items() if k != "base_version"},
        {**CUERPO, "base_version": 0},
        {**CUERPO, "cambio_material": "talvez"},
    ],
)
def test_cuerpo_invalido_da_422_sin_llamar_al_rpc(entorno, cuerpo):
    _con_rpc(entorno, {"resultado": "publicada"})
    assert _post(RUTA, cuerpo).status_code == 422
    entorno.rpc.assert_not_called()


def test_publicacion_concurrente_da_409_con_el_vigente_releido(entorno):
    error = APIError({"code": "SCJ16", "hint": "version_base_desactualizada", "message": CRUDO})
    _con_rpc(entorno, error=error, vigente=V3)
    r = _post(RUTA, CUERPO)
    assert r.status_code == 409
    assert r.json()["detail"] == "Otra persona publicó una versión nueva del texto; vuelve a leerlo antes de publicar."
    assert r.json()["consentimiento_vigente"] == {
        "id": 3, "version": 3, "texto": "Texto v3", "texto_sha256": "a" * 64, "provisional": False,
        "cambio_material": False, "vigente_desde": V3["creado_en"],
    }
    assert "8814" not in r.text


def test_si_la_relectura_falla_el_409_sale_solo_con_detail(entorno):
    error = APIError({"code": "SCJ16", "hint": "version_base_desactualizada", "message": CRUDO})
    _con_rpc(entorno, error=error, vigente=None)
    r = _post(RUTA, CUERPO)
    assert r.status_code == 409 and set(r.json()) == {"detail"}


@pytest.mark.parametrize(
    "codigo,hint,estado,mensaje",
    [
        ("22023", "texto_invalido", 422, "El texto debe tener entre 1 y 4 000 caracteres."),
        ("22023", "nota_invalida", 422, "El motivo del cambio no puede pasar de 200 caracteres."),
        ("42501", "sin_permiso", 403, "No tienes permiso para esta acción."),
    ],
)
def test_errores_del_rpc_con_mensaje_fijo(entorno, codigo, hint, estado, mensaje):
    _con_rpc(entorno, error=APIError({"code": codigo, "hint": hint, "message": CRUDO}))
    r = _post(RUTA, CUERPO)
    assert r.status_code == estado and r.json()["detail"] == mensaje and "8814" not in r.text


def test_error_desconocido_del_rpc_es_500_sin_texto(entorno):
    _con_rpc(entorno, error=APIError({"code": "XX999", "message": CRUDO}))
    r = _post(RUTA, CUERPO)
    assert r.status_code == 500 and "8814" not in r.text


@pytest.mark.parametrize("forma", [None, [], "ok", {"resultado": "rara"}])
def test_respuesta_inesperada_del_rpc_es_503(entorno, forma, caplog):
    _con_rpc(entorno, forma)
    with caplog.at_level(logging.ERROR):
        assert _post(RUTA, CUERPO).status_code == 503


def test_publicar_exige_config_edicion_y_sin_permiso_no_llama_al_rpc(entorno):
    _con_rpc(entorno, {"resultado": "sin_cambio", "version": 3})
    entorno.permitido = False
    assert _post(RUTA, CUERPO).status_code == 403
    entorno.rpc.assert_not_called()


# --- errores nuevos de SCJ12 / SCJ16 -------------------------------------------------------------------


@pytest.mark.parametrize(
    "codigo,hint,estado,fragmento",
    [
        ("SCJ12", "auto_asignacion_prohibida", 422, "No puedes asignarte a ti mismo"),
        ("SCJ12", "auto_reconsentimiento_prohibido", 422, "No puedes registrar tu propio reconsentimiento"),
        ("SCJ16", "version_base_desactualizada", 409, "Otra persona publicó"),
        ("SCJ16", "consentimiento_desactualizado", 409, "El texto de consentimiento cambió"),
    ],
)
def test_mapeo_de_los_hints_nuevos(codigo, hint, estado, fragmento):
    e = traducir_error_terminal_web(APIError({"code": codigo, "hint": hint, "message": CRUDO}))
    assert e.status_code == estado and fragmento in e.detail and "8814" not in e.detail


# --- asignar ---------------------------------------------------------------------------------------------------


RUTA_ASIGNAR = "/api/terminales/1/usuarios"
CUERPO_ASIGNAR = {"persona_id": PERSONA, "consentimiento_id": 3, "consentimiento_recabado": True}
ALTA = {
    "id": 77, "terminal_id": 1, "employee_no": 1077, "persona_id": PERSONA, "estado": "pendiente_alta",
    "huellas_capturadas": 0, "error_detalle": None, "creado_en": "2026-10-08T09:00:00+00:00",
    "actualizado_en": "2026-10-08T09:00:00+00:00", "usuario_creado_en": None, "consentimiento_id": 3,
}


def _asignar_tablas(error=None, vigente=V3, devuelve=({"terminal_usuario_id": 77},)):
    bit = tabla([])
    bit.insert.return_value.execute.return_value = Resultado(list(devuelve))
    if error is not None:
        bit.insert.return_value.execute.side_effect = error
    return {
        "terminal": tabla([{"id": 1}]),
        "terminal_consentimiento": tabla([vigente] if vigente else []),
        "bitacora_movimiento_terminal_usuario": bit,
        "terminal_usuario": tabla([ALTA]),
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
    }


def _cfg(entorno, tablas):
    """Asignar sí usa service_role (sólo para leer la variable de caducidad al armar el alta): override benigno."""
    db = entorno.configurar(**tablas)
    app.dependency_overrides[get_service_client] = lambda: db_por_nombre(parametro=tabla([]))
    return db


def test_asigna_con_el_cliente_del_caller_y_devuelve_el_alta_con_consentimiento(entorno):
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    r = _post(RUTA_ASIGNAR, CUERPO_ASIGNAR)
    assert r.status_code == 201, r.text
    a = r.json()
    assert a["id"] == 77 and a["estado"] == "pendiente_alta" and a["persona_nombre"] == "Ana Torres"
    assert a["consentimiento"] == {"id": 3, "version": 3, "provisional": False}
    assert a["accion_disponible"] == "cancelar_alta"
    carga = tablas["bitacora_movimiento_terminal_usuario"].insert.call_args.args[0]
    # el servidor asigna terminal_usuario_id/employee_no/detalle: el backend NO los manda
    assert carga == {
        "terminal_id": 1, "persona_id": PERSONA, "tipo_movimiento": "asignado", "origen": "web",
        "registrado_por": CALLER.auth_user_id, "consentimiento_id": 3,
    }
    assert entorno.codigos == [("terminal_usuario_edicion",)]
    # el alta devuelta se relee por el terminal_usuario_id que asignó el trigger, acotada a la terminal
    llamadas_eq = [c.args for c in tablas["terminal_usuario"].eq.call_args_list]
    assert ("id", 77) in llamadas_eq and ("terminal_id", 1) in llamadas_eq


@pytest.mark.parametrize("recabado", [False, None])
def test_sin_consentimiento_recabado_da_422_y_no_escribe(entorno, recabado):
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    cuerpo = {**CUERPO_ASIGNAR, "consentimiento_recabado": recabado}
    r = _post(RUTA_ASIGNAR, cuerpo)
    assert r.status_code == 422
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


@pytest.mark.parametrize(
    "cuerpo",
    [
        {"consentimiento_id": 3, "consentimiento_recabado": True},
        {**CUERPO_ASIGNAR, "persona_id": "no-uuid"},
        {**CUERPO_ASIGNAR, "consentimiento_id": 0},
        {**CUERPO_ASIGNAR, "consentimiento_id": "x"},
        {**CUERPO_ASIGNAR, "employee_no": 5},
        {**CUERPO_ASIGNAR, "terminal_usuario_id": 5},
    ],
)
def test_cuerpo_invalido_o_con_campos_que_asigna_el_servidor_da_422(entorno, cuerpo):
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    assert _post(RUTA_ASIGNAR, cuerpo).status_code == 422
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_auto_asignacion_da_422_fijo_antes_de_tocar_la_base(entorno):
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    r = _post(RUTA_ASIGNAR, {**CUERPO_ASIGNAR, "persona_id": PROPIA})
    # PROPIA no es un UUID: pasa por la comparación con resolver_persona_id sólo si es uuid; se usa uno real abajo
    assert r.status_code == 422


def test_auto_asignacion_con_uuid_real(entorno, monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: PERSONA)
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    r = _post(RUTA_ASIGNAR, CUERPO_ASIGNAR)
    assert r.status_code == 422
    assert r.json()["detail"] == (
        "No puedes asignarte a ti mismo a una terminal. Sólo el puesto administrador puede hacerlo."
    )
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_el_administrador_generico_si_puede_asignarse(entorno, monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: PERSONA)
    entorno.admin_generico = True
    _cfg(entorno, _asignar_tablas())
    assert _post(RUTA_ASIGNAR, CUERPO_ASIGNAR).status_code == 201


def test_consentimiento_que_no_es_el_vigente_da_409_con_el_texto_y_no_escribe(entorno):
    tablas = _asignar_tablas(vigente=V3)
    _cfg(entorno, tablas)
    r = _post(RUTA_ASIGNAR, {**CUERPO_ASIGNAR, "consentimiento_id": 2})
    assert r.status_code == 409
    assert r.json()["detail"] == "El texto de consentimiento cambió; vuelve a leerlo."
    assert r.json()["consentimiento_vigente"]["id"] == 3 and r.json()["consentimiento_vigente"]["texto"] == "Texto v3"
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_sin_texto_de_consentimiento_en_la_base_da_422(entorno):
    tablas = _asignar_tablas(vigente=None)
    _cfg(entorno, tablas)
    r = _post(RUTA_ASIGNAR, CUERPO_ASIGNAR)
    assert r.status_code == 422 and "consentimiento" in r.json()["detail"]
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


@pytest.mark.parametrize(
    "codigo,hint,estado,fragmento",
    [
        ("SCJ12", "alta_duplicada", 409, "ya tiene un alta vigente"),
        ("SCJ12", "persona_no_activa", 422, "no existe o no está activa"),
        ("SCJ12", "terminal_no_valida", 422, "La terminal no existe o no está activa"),
        ("SCJ12", "auto_asignacion_prohibida", 422, "No puedes asignarte a ti mismo"),
        ("SCJ16", "consentimiento_desactualizado", 409, "El texto de consentimiento cambió"),
        ("SCJ16", "consentimiento_requerido", 422, "Falta la versión"),
        ("23505", "", 409, "Otra asignación de esta persona"),
        ("23503", "", 422, "no está sincronizada"),
        ("42501", "sin_permiso", 403, "No tienes permiso"),
    ],
)
def test_errores_de_la_base_al_asignar_con_mensaje_fijo(entorno, codigo, hint, estado, fragmento):
    _cfg(entorno, _asignar_tablas(error=APIError({"code": codigo, "hint": hint, "message": CRUDO})))
    r = _post(RUTA_ASIGNAR, CUERPO_ASIGNAR)
    assert r.status_code == estado and fragmento in r.json()["detail"] and "8814" not in r.text


def test_carrera_de_consentimiento_en_la_base_tambien_devuelve_el_vigente(entorno):
    err = APIError({"code": "SCJ16", "hint": "consentimiento_desactualizado", "message": CRUDO})
    _cfg(entorno, _asignar_tablas(error=err))
    assert _post(RUTA_ASIGNAR, CUERPO_ASIGNAR).json()["consentimiento_vigente"]["id"] == 3


def test_asignar_a_terminal_inexistente_da_404_sin_escribir(entorno):
    tablas = _asignar_tablas()
    tablas["terminal"] = tabla([])
    _cfg(entorno, tablas)
    assert _post("/api/terminales/9/usuarios", CUERPO_ASIGNAR).status_code == 404
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_si_la_bitacora_no_devuelve_terminal_usuario_id_es_503(entorno, caplog):
    _cfg(entorno, _asignar_tablas(devuelve=({},)))
    with caplog.at_level(logging.ERROR):
        assert _post(RUTA_ASIGNAR, CUERPO_ASIGNAR).status_code == 503


def test_asignar_exige_edicion_y_sin_permiso_no_consulta(entorno):
    tablas = _asignar_tablas()
    _cfg(entorno, tablas)
    entorno.permitido = False
    assert _post(RUTA_ASIGNAR, CUERPO_ASIGNAR).status_code == 403
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_fronteras_de_terminal_id_al_asignar(entorno):
    _cfg(entorno, _asignar_tablas())
    assert _post("/api/terminales/0/usuarios", CUERPO_ASIGNAR).status_code == 422
    assert _post("/api/terminales/9223372036854775808/usuarios", CUERPO_ASIGNAR).status_code == 422


# --- historial con consentimiento ---------------------------------------------------------------------------------


def test_historial_trae_el_consentimiento_de_asignado_y_reconsentido(entorno):
    movs = [
        {"id": 3, "tipo_movimiento": "reconsentido", "creado_en": "2026-10-08T12:00:00+00:00", "origen": "web",
         "registrado_por": None, "detalle": "reconsentimiento recabado: versión 2", "huellas_capturadas": None,
         "consentimiento_id": 2},
        {"id": 2, "tipo_movimiento": "usuario_creado", "creado_en": "2026-10-08T11:00:00+00:00", "origen": "terminal",
         "registrado_por": None, "detalle": None, "huellas_capturadas": None, "consentimiento_id": None},
    ]
    entorno.configurar(
        terminal_usuario=tabla([ALTA]),
        bitacora_movimiento_terminal_usuario=tabla(movs),
        terminal_consentimiento=tabla([{"id": 2, "version": 2, "provisional": False, "cambio_material": True}]),
    )
    por_id = {m["id"]: m for m in _get("/api/terminales/1/usuarios/77/movimientos").json()}
    assert por_id[3]["consentimiento"] == {"id": 2, "version": 2, "cambio_material": True}
    assert por_id[2]["consentimiento"] is None


# --- contrato RPC <-> DDL (88_) ----------------------------------------------------------------------------------


def _ddl88():
    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    return next(ddl.glob("88_*.sql")).read_text(encoding="utf-8")


def test_la_firma_del_rpc_de_publicar_coincide_con_88():
    sql = _ddl88()
    firma = re.search(r"CREATE FUNCTION tiempo\.fn_terminal_consentimiento_publicar\((.*?)\)\s*RETURNS jsonb", sql, re.S).group(1)
    assert [p.split()[0] for p in firma.strip().split(",")] == ["p_texto", "p_cambio_material", "p_nota", "p_base_version"]
    assert "GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_consentimiento_publicar(text, boolean, text, integer) TO authenticated" in sql


def test_los_hints_que_mapea_el_backend_existen_en_88():
    sql = _ddl88()
    for hint in ("version_base_desactualizada", "consentimiento_desactualizado", "consentimiento_requerido",
                 "auto_asignacion_prohibida", "auto_reconsentimiento_prohibido"):
        assert f"HINT = '{hint}'" in sql, hint


def test_las_columnas_de_consentimiento_que_lee_el_backend_existen_en_88():
    sql = _ddl88()
    cuerpo = re.search(r"CREATE TABLE tiempo\.terminal_consentimiento \((.*?)\n\);", sql, re.S).group(1)
    from app.routers.consentimiento_terminales import COLUMNAS

    for col in (c.strip() for c in COLUMNAS.split(",")):
        assert re.search(rf"^\s+{col}\s", cuerpo, re.M), col
    assert "fn_terminal_reconsentimiento_pendiente_ids()" in sql


# --- ajustes de security a C5 (M1, B1-B3) ---------------------------------------------------------------------------


def test_impacto_exige_ver_las_altas_config_sola_no_basta(entorno):
    """M1: con la RLS del caller, quien sólo tiene terminal_config_edicion contaría 0 altas y publicaría a ciegas."""
    tablas, _ = _tablas_impacto(V3)
    entorno.configurar(**tablas)
    assert _get(f"{RUTA}/impacto").status_code == 200
    assert entorno.codigos[-1] == ("terminal_usuario_lectura", "terminal_usuario_edicion")


def test_la_respuesta_inesperada_lleva_mensaje_fijo_y_log(entorno, caplog):
    _con_rpc(entorno, "rara")
    with caplog.at_level(logging.ERROR):
        r = _post(RUTA, CUERPO)
    assert r.status_code == 503
    assert r.json()["detail"] == "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


@pytest.mark.parametrize("codigo", ["PGRST202", "PGRST204", "PGRST205", "42P01"])
@pytest.mark.parametrize("ruta", ["GET:" + RUTA, "GET:" + RUTA + "/impacto", "POST:" + RUTA_ASIGNAR, "GET:/api/terminales/1/usuarios"])
def test_falta_de_migracion_88_da_503_con_error_en_el_log(entorno, codigo, ruta, caplog):
    """B2: orden de despliegue 88_ -> backend -> 89_. Un objeto inexistente es 503 «Servicio no disponible», no 500."""
    from unittest.mock import MagicMock

    metodo, url = ruta.split(":", 1)
    roto = MagicMock()
    roto.execute.side_effect = APIError({"code": codigo, "message": CRUDO})
    for nombre in ("select", "eq", "order", "limit", "range", "in_", "gte", "insert", "neq", "is_", "or_"):
        getattr(roto, nombre).return_value = roto
    tablas = {
        "terminal_consentimiento": roto,
        "terminal_usuario": roto,
        "terminal": tabla([{"id": 1}]),
        "persona": tabla([]),
        "bitacora_movimiento_terminal_usuario": roto,
    }
    entorno.configurar(**tablas)
    app.dependency_overrides[get_service_client] = lambda: db_por_nombre(parametro=tabla([]))
    with caplog.at_level(logging.ERROR):
        r = _cliente().request(metodo, url, headers=AUTH, json=CUERPO_ASIGNAR if metodo == "POST" else None)
    assert r.status_code == 503, r.text
    assert r.json() == {"detail": "Servicio no disponible. Avisa a Sistemas."}
    assert "8814" not in r.text
    assert any(x.levelno >= logging.ERROR and codigo in x.getMessage() for x in caplog.records)


def test_otro_error_de_postgrest_sigue_siendo_500(entorno):
    from unittest.mock import MagicMock

    roto = MagicMock()
    roto.execute.side_effect = APIError({"code": "XX999", "message": CRUDO})
    for nombre in ("select", "order", "limit"):
        getattr(roto, nombre).return_value = roto
    entorno.configurar(terminal_consentimiento=roto, persona=tabla([]))
    r = _get(RUTA)
    assert r.status_code == 500 and "8814" not in r.text


def test_el_historial_no_trae_el_texto_salvo_la_vigente(entorno):
    t = TablaConCadenas([V3, V2, SEMILLA], [V3])
    entorno.configurar(terminal_consentimiento=t, persona=tabla([]))
    cuerpo = _get(RUTA).json()
    assert cuerpo["vigente"]["texto"] == "Texto v3"
    assert [h["texto"] for h in cuerpo["historial"]] == ["Texto v3", None, None]
    primera = t.cadenas[0][0]
    assert "texto," not in primera[1][0] and "texto " not in primera[1][0] + " "  # la lista no pide la columna texto


def test_leer_una_version_trae_el_texto_completo_y_su_vigencia(entorno):
    t = TablaConCadenas([V2], [V3])
    entorno.configurar(terminal_consentimiento=t, persona=tabla([{"id": "p-autor", "primer_nombre": "Carlos", "apellido_paterno": "Ruiz"}]))
    r = _get(f"{RUTA}/2")
    assert r.status_code == 200, r.text
    assert r.json()["texto"] == "Texto v2" and r.json()["vigente_hasta"] == V3["creado_en"].replace("+00:00", "Z")
    assert llamadas(t.cadenas[0], "eq") == [(("version", 2), {})]
    assert llamadas(t.cadenas[1], "gt") == [(("version", 2), {})]


def test_version_inexistente_404_y_fronteras(entorno):
    entorno.configurar(terminal_consentimiento=tabla([]), persona=tabla([]))
    assert _get(f"{RUTA}/9").status_code == 404
    assert _get(f"{RUTA}/0").status_code == 422
    assert _get(f"{RUTA}/2147483648").status_code == 422
    assert _get(f"{RUTA}/abc").status_code == 422


def test_impacto_no_se_confunde_con_una_version(entorno):
    tablas, _ = _tablas_impacto(V3)
    entorno.configurar(**tablas)
    assert _get(f"{RUTA}/impacto").status_code == 200


def test_la_version_puntual_exige_el_gate_de_ver(entorno):
    entorno.configurar(terminal_consentimiento=tabla([V2]), persona=tabla([]))
    entorno.permitido = False
    assert _get(f"{RUTA}/2").status_code == 403


def test_el_log_del_handler_global_usa_la_plantilla_de_la_ruta_no_la_url(entorno, caplog):
    """Un log no debe llevar ids de personas ni caracteres inyectados en el path: se registra la plantilla."""
    from unittest.mock import MagicMock

    roto = MagicMock()
    roto.execute.side_effect = APIError({"code": "PGRST205", "message": CRUDO})
    for nombre in ("select", "eq", "order", "limit", "range", "in_", "gte", "is_"):
        getattr(roto, nombre).return_value = roto
    entorno.configurar(terminal=tabla([{"id": 1}]), terminal_usuario=roto, persona=tabla([]), terminal_consentimiento=roto)
    app.dependency_overrides[get_service_client] = lambda: db_por_nombre(parametro=tabla([]))
    with caplog.at_level(logging.ERROR):
        r = _get("/api/terminales/1/usuarios?persona_id=" + PERSONA)
    assert r.status_code == 503
    mensajes = " ".join(x.getMessage() for x in caplog.records)
    assert "/api/terminales/{terminal_id}/usuarios" in mensajes
    assert "/api/terminales/1/usuarios" not in mensajes and PERSONA not in mensajes
