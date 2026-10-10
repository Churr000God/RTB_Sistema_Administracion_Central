"""C8 del contrato de Terminales: tablero de anomalías (10 categorías, aisladas) y job de reconciliación de bajas.
Mocks por NOMBRE de tabla/RPC; NUNCA contra la base real."""

import logging
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import rpc_con_firma_real, Resultado, TablaConCadenas, db_por_nombre, llamadas, tabla
from app import permisos
from app.anomalias_terminal import CATEGORIAS
from app.batches import terminales as jobs
from app.config import Settings, get_settings
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers.anomalias_terminales import CACHE

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
PROPIA = "pppppppp-0000-0000-0000-000000000009"
ANA = "aaaaaaaa-0000-0000-0000-000000000001"
LUIS = "bbbbbbbb-0000-0000-0000-000000000002"
CRUDO = "texto-crudo-id-interno-4407"
AHORA = datetime.now(timezone.utc)
TERMINAL = {"id": 1, "terminal_id": "SERIE-1", "reloj_desfase_seg": 3, "activa": True, "ultimo_contacto_en": (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat()}
NOMBRES = [
    {"id": ANA, "primer_nombre": "Ana", "apellido_paterno": "Torres"},
    {"id": LUIS, "primer_nombre": "Luis", "apellido_paterno": "Ramírez"},
]
RUTA = "/api/terminales/1/anomalias"


def _rpc_por_nombre(db, mapa):
    """Los RPC del cliente responden según su nombre; un valor Exception se lanza al ejecutar."""
    rpc = db.postgrest.schema.return_value.rpc

    def segun(nombre, params):
        r = MagicMock()
        valor = mapa.get(nombre)
        if isinstance(valor, Exception):
            r.execute.side_effect = valor
        else:
            r.execute.return_value = Resultado(valor)
        return r

    rpc.side_effect = segun
    return rpc


@pytest.fixture
def entorno(monkeypatch):
    entorno.codigos = []
    entorno.ajustes = {}
    entorno.otorgados = {"terminal_usuario_lectura", "marca_lectura"}
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: PROPIA)

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return any(c in entorno.otorgados for c in codigos)

    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)

    def configurar(caller=None, servicio=None, rpc_caller=None, rpc_servicio=None):
        CACHE.limpiar()                                   # la caché corta del tablero (45 s) no debe arrastrar resultados entre configuraciones de una misma prueba
        base_caller = {
            "terminal": tabla([TERMINAL]), "persona": tabla(NOMBRES), "terminal_usuario": tabla([]),
            "bitacora_movimiento_terminal_usuario": tabla([]), "usuario": tabla([]),
            "terminal_consentimiento": tabla([]),
        }
        base_caller.update(caller or {})
        base_servicio = {
            "parametro": tabla([]), "marca": tabla([]), "marca_rechazada": tabla([]), "terminal_credencial": tabla([]),
        }
        base_servicio.update(servicio or {})
        db = db_por_nombre(estricto=True, **base_caller)
        sv = db_por_nombre(estricto=True, **base_servicio)
        rc = _rpc_por_nombre(db, {"fn_terminal_reconsentimiento_pendiente_ids": [], **(rpc_caller or {})})
        rs = _rpc_por_nombre(
            sv,
            {"fn_terminal_anomalias": {"total": 0, "items": []}, "fn_terminal_config_valor": None, "fn_terminal_inferir_huella_estado": ESTADO_INTERRUPTOR_APAGADO, **(rpc_servicio or {})},
        )
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_service_client] = lambda: sv
        app.dependency_overrides[get_settings] = lambda: Settings(supabase_url="http://supabase.invalido", supabase_anon_key="a", supabase_service_role_key="s", **(entorno.ajustes or {}))
        entorno.db, entorno.sv, entorno.rpc_c, entorno.rpc_s = db, sv, rc, rs
        return db, sv

    entorno.configurar = configurar
    return entorno


ESTADO_INTERRUPTOR_APAGADO = {"activo": False, "vencido": False, "motivo": "apagado", "valor": "0", "hasta": "1970-01-01T00:00:00Z", "encendido_por": None, "encendido_en": None,
                              "ultimo_cambio_via_funcion": None, "sin_registro": False}


def _c():
    return TestClient(app, raise_server_exceptions=False)


def _get(ruta=RUTA):
    return _c().get(ruta, headers=AUTH)


def _tarjetas(r):
    assert r.status_code == 200, r.text
    return {t["clave"]: t for t in r.json()["categorias"]}


def _llamadas_anomalias(entorno):
    return [c.args for c in entorno.rpc_s.call_args_list if c.args[0] == "fn_terminal_anomalias"]


# --- estructura general ---------------------------------------------------------------------------------------------------


def test_el_tablero_trae_las_14_categorias_con_nivel_y_numero_del_contrato(entorno):
    entorno.configurar()
    r = _get()
    assert r.status_code == 200
    cuerpo = r.json()
    assert [c["numero"] for c in cuerpo["categorias"]] == list(range(1, 16))
    assert {c["clave"] for c in cuerpo["categorias"]} == {
        "marcas_posteriores_a_baja", "picos_de_tasa", "reloj_degradado", "huecos_de_secuencia", "rechazos_definitivos",
        "credenciales", "inconsistencias_de_baja", "altas_atascadas", "altas_recientes", "reconsentimientos_pendientes",
        "huellas_inferidas_exceso", "inferida_sin_marcas", "asignador_confirmador", "interruptor_huella",
        "terminal_sin_contacto",
    }
    assert all(c["estado"] == "sin_hallazgos" and c["nivel"] is None and c["total"] == 0 for c in cuerpo["categorias"])
    assert cuerpo["terminal_id"] == 1 and cuerpo["generado_en"] and cuerpo["desde"] and cuerpo["hasta"]


def test_niveles_los_manda_el_backend():
    por_numero = {c.numero: c.nivel for c in CATEGORIAS}
    assert por_numero == {1: "atender", 7: "atender", 2: "revisar", 3: "revisar", 4: "revisar", 5: "revisar",
                          6: "revisar", 8: "revisar", 10: "revisar", 9: "informativo", 11: "revisar", 12: "revisar", 13: "revisar", 14: "revisar", 15: "revisar"}


def test_sin_permiso_403_terminal_404_y_fronteras(entorno):
    entorno.configurar()
    assert _get("/api/terminales/0/anomalias").status_code == 422
    assert _get("/api/terminales/9223372036854775808/anomalias").status_code == 422
    entorno.otorgados = set()
    assert _get().status_code == 403
    entorno.otorgados = {"terminal_usuario_edicion"}
    entorno.configurar(caller={"terminal": tabla([])})
    assert _get().status_code == 404


def test_gate_lectura_o_edicion(entorno):
    entorno.configurar()
    _get()
    assert ("terminal_usuario_lectura", "terminal_usuario_edicion") in entorno.codigos


# --- ventana ---------------------------------------------------------------------------------------------------------------


def test_ventana_por_omision_usa_la_variable_de_ventana(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_config_valor": 10})
    cuerpo = _get().json()
    dias = (datetime.fromisoformat(cuerpo["hasta"].replace("Z", "+00:00")) - datetime.fromisoformat(cuerpo["desde"].replace("Z", "+00:00"))).days
    assert dias in (9, 10)


@pytest.mark.parametrize("query", ["?desde=2026-10-08&hasta=2026-10-01", "?desde=2026-01-01&hasta=2026-10-08", "?desde=ayer",
                                    "?hasta=mañana"])
def test_ventana_invalida_da_422_sin_calcular(entorno, query):
    entorno.configurar()
    r = _get(RUTA + query)
    assert r.status_code == 422
    assert _llamadas_anomalias(entorno) == []


def test_ventana_de_noventa_dias_pasa_y_las_fechas_son_dias_de_mexico(entorno):
    entorno.configurar()
    hoy = datetime.now(timezone.utc).date()
    r = _get(f"{RUTA}?desde={hoy - timedelta(days=89)}&hasta={hoy}")
    assert r.status_code == 200, r.text
    desde = datetime.fromisoformat(r.json()["desde"].replace("Z", "+00:00"))
    assert desde.hour == 6 and desde.minute == 0  # 00:00 de México (UTC-6) = 06:00 UTC


# --- aislamiento y permisos ---------------------------------------------------------------------------------------------------


def test_una_categoria_rota_no_tumba_el_tablero_y_no_filtra_el_texto(entorno, caplog):
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": APIError({"code": "XX999", "message": CRUDO})})
    with caplog.at_level(logging.ERROR):
        t = _tarjetas(_get())
    assert t["marcas_posteriores_a_baja"]["estado"] == "error" and t["marcas_posteriores_a_baja"]["total"] is None
    assert t["marcas_posteriores_a_baja"]["ejemplos"] == [] and t["marcas_posteriores_a_baja"]["nivel"] is None
    assert t["altas_recientes"]["estado"] == "sin_hallazgos"  # las demás siguen
    assert "4407" not in caplog.text and any(x.levelno >= logging.ERROR for x in caplog.records)


@pytest.mark.parametrize("codigo", ["PGRST202", "PGRST205", "42P01"])
def test_fuente_que_aun_no_existe_es_no_disponible(entorno, codigo):
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": APIError({"code": codigo, "message": CRUDO})})
    t = _tarjetas(_get())["huecos_de_secuencia"]
    assert t["estado"] == "no_disponible" and t["motivo"] == "falta_migracion" and t["total"] is None


@pytest.mark.parametrize("forma", [None, [], {"total": "2", "items": []}, {"total": True, "items": []}, {"total": 1}, {"items": []}])
def test_forma_inesperada_del_rpc_de_agregaciones_es_error(entorno, forma):
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": forma})
    assert _tarjetas(_get())["picos_de_tasa"]["estado"] == "error"


def test_sin_marca_lectura_las_categorias_de_marcas_de_personas_no_se_calculan(entorno):
    entorno.otorgados = {"terminal_usuario_lectura"}
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": [{"persona_id": ANA}]}})
    t = _tarjetas(_get())
    for clave in ("marcas_posteriores_a_baja", "picos_de_tasa", "inferida_sin_marcas"):     # (12 cruza marcas: security R1)
        assert t[clave]["estado"] == "no_disponible" and t[clave]["motivo"] == "sin_permiso" and t[clave]["ejemplos"] == []
    # el resto sí; huecos usa el mismo RPC (sin personas) y se calcula
    assert t["huecos_de_secuencia"]["estado"] == "con_hallazgos"
    # (94_) la 11 y la 13 no muestran marcas de personas: se calculan sin marca_lectura; la 12 SÍ cruza marcas y la exige
    assert {c[1]["p_categoria"] for c in _llamadas_anomalias(entorno)} == {"huecos_de_secuencia", "huellas_inferidas_exceso", "asignador_confirmador"}


def test_con_marca_lectura_se_calculan_las_de_personas(entorno):
    entorno.configurar()
    _get()
    assert {c[1]["p_categoria"] for c in _llamadas_anomalias(entorno)} == {
        "marcas_posteriores_a_baja", "picos_de_tasa", "huecos_de_secuencia", "huellas_inferidas_exceso", "inferida_sin_marcas", "asignador_confirmador"}


# --- agregaciones por RPC (1, 2, 4) ----------------------------------------------------------------------------------------------


def test_marcas_posteriores_a_baja_resuelve_nombres_con_el_cliente_del_caller_y_no_expone_ids(entorno):
    items = [{"persona_id": ANA, "marca_id": 9, "marca_en": "2026-10-08T10:00:00+00:00", "baja_confirmada_en": "2026-10-01T10:00:00+00:00"}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 4, "items": items}})
    t = _tarjetas(_get())["marcas_posteriores_a_baja"]
    assert t["estado"] == "con_hallazgos" and t["nivel"] == "atender" and t["total"] == 4 and t["hay_mas"] is True
    assert t["ejemplos"] == [{"persona_nombre": "Ana Torres", "marca_en": "2026-10-08T10:00:00+00:00",
                              "baja_confirmada_en": "2026-10-01T10:00:00+00:00"}]
    assert ANA not in str(t) and "marca_id" not in str(t)
    params = next(c[1] for c in _llamadas_anomalias(entorno) if c[1]["p_categoria"] == "marcas_posteriores_a_baja")
    assert params["p_terminal_id"] == 1 and params["p_limite"] == 3 and params["p_desplazamiento"] == 0


def test_picos_de_tasa_de_terminal_no_traen_persona(entorno):
    items = [{"persona_id": None, "hora": "2026-10-08T10:00:00+00:00", "marcas": 1200, "limite": 1000},
             {"persona_id": LUIS, "hora": "2026-10-08T11:00:00+00:00", "marcas": 14, "limite": 10}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 2, "items": items}})
    e = _tarjetas(_get())["picos_de_tasa"]["ejemplos"]
    assert e[0]["persona_nombre"] is None and e[0]["marcas"] == 1200
    assert e[1]["persona_nombre"] == "Luis Ramírez" and e[1]["limite"] == 10


def test_huecos_pasan_tal_cual(entorno):
    items = [{"desde": 10, "hasta": 12, "faltan": 3, "fecha": "2026-10-08T10:00:00+00:00"}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    assert _tarjetas(_get())["huecos_de_secuencia"]["ejemplos"] == items


def test_los_ejemplos_se_cortan_a_tres(entorno):
    items = [{"desde": i, "hasta": i, "faltan": 1, "fecha": None} for i in range(5)]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 5, "items": items}})
    t = _tarjetas(_get())["huecos_de_secuencia"]
    assert len(t["ejemplos"]) == 3 and t["hay_mas"] is True


# --- reloj, rechazos, credenciales -------------------------------------------------------------------------------------------


def test_reloj_degradado_cuenta_deriva_y_sin_sincronizar_de_esta_terminal(entorno):
    marca = TablaConCadenas(Resultado([], 4), Resultado([], 2))
    entorno.configurar(servicio={"marca": marca})
    t = _tarjetas(_get())["reloj_degradado"]
    assert t["total"] == 6 and t["ejemplos"] == [{"conteo": 6, "desfase_actual_seg": 3}] and t["nivel"] == "revisar"
    for cadena in marca.cadenas:
        assert ("terminal_id", "SERIE-1") in [a for a, _ in llamadas(cadena, "eq")]  # acotado por la SERIE de esta terminal
        assert cadena[0][2] == {"count": "exact", "head": True}
    assert [(("estado_reloj", e), {}) in llamadas(c, "eq") for c, e in zip(marca.cadenas, ("deriva", "sin_sincronizar"))] == [True, True]


def test_rechazos_por_codigo_con_total_y_orden(entorno):
    rech = TablaConCadenas(Resultado([], 2), Resultado([], 0), Resultado([], 7), Resultado([], 0), Resultado([], 1))
    entorno.configurar(servicio={"marca_rechazada": rech})
    t = _tarjetas(_get())["rechazos_definitivos"]
    assert t["total"] == 10
    assert t["ejemplos"] == [{"codigo": "secuencia_duplicada", "total": 7}, {"codigo": "forma_invalida", "total": 2},
                             {"codigo": "conflicto_evento", "total": 1}]
    assert all(("terminal_id", 1) in [a for a, _ in llamadas(c, "eq")] for c in rech.cadenas)


def _cred(**kw):
    base = {"creada_en": (AHORA - timedelta(days=10)).isoformat(), "expira_en": None, "revocada_en": None,
            "ultimo_uso_en": AHORA.isoformat(), "ip_cambiada_en": None}
    base.update(kw)
    return base


def test_credenciales_detecta_antigua_sin_uso_traslape_y_cambio_de_ip(entorno):
    filas = [
        _cred(creada_en=(AHORA - timedelta(days=400)).isoformat()),  # 13 meses > 12
        _cred(creada_en=(AHORA - timedelta(days=20)).isoformat(), ultimo_uso_en=None),  # sin uso
        _cred(creada_en=(AHORA - timedelta(days=60)).isoformat(), revocada_en=AHORA.isoformat()),  # revocada: no cuenta
        _cred(ip_cambiada_en=(AHORA - timedelta(days=2)).isoformat()),
    ]
    cred = TablaConCadenas(filas)
    entorno.configurar(servicio={"terminal_credencial": cred})
    r = _get(f"{RUTA}/credenciales")
    assert r.status_code == 200, r.text
    assert r.json()["total"] == 4
    assert sorted(e["tipo"] for e in r.json()["items"]) == ["cambio_de_ip", "llave_antigua", "llave_sin_uso", "traslape_abierto"]
    por_tipo = {e["tipo"]: e for e in r.json()["items"]}
    assert por_tipo["llave_antigua"]["antiguedad_meses"] == 13 and "dias_abierto" in por_tipo["traslape_abierto"]
    assert "hash" not in r.text and "ultima_ip" not in r.text
    seleccion = cred.cadenas[0][0][1][0]
    assert "hash" not in seleccion and "ultima_ip" not in seleccion  # ni se piden
    assert llamadas(cred.cadenas[0], "eq") == [(("terminal_id", 1), {})]


def test_credenciales_sanas_sin_hallazgos(entorno):
    entorno.configurar(servicio={"terminal_credencial": TablaConCadenas([_cred()])})
    assert _tarjetas(_get())["credenciales"]["estado"] == "sin_hallazgos"


def test_credencial_expirada_no_cuenta_como_vigente(entorno):
    filas = [_cred(creada_en=(AHORA - timedelta(days=900)).isoformat(), expira_en=(AHORA - timedelta(days=1)).isoformat())]
    entorno.configurar(servicio={"terminal_credencial": TablaConCadenas(filas)})
    assert _tarjetas(_get())["credenciales"]["estado"] == "sin_hallazgos"


# --- categorías con el cliente del caller (7, 8, 9, 10) -------------------------------------------------------------------------------


def test_inconsistencias_de_baja_persona_inactiva_con_alta_viva(entorno):
    altas = TablaConCadenas([{"persona_id": ANA, "estado": "activo"}, {"persona_id": LUIS, "estado": "esperando_huella"}])
    personas = TablaConCadenas([
        {"id": ANA, "estado": "suspension", "primer_nombre": "Ana", "apellido_paterno": "Torres"},
        {"id": LUIS, "estado": "activo", "primer_nombre": "Luis", "apellido_paterno": "Ramírez"},
    ])
    entorno.configurar(caller={"terminal_usuario": altas, "persona": personas})
    t = _get(f"{RUTA}/inconsistencias_de_baja").json()
    assert t["total"] == 1
    assert t["items"] == [{"persona_nombre": "Ana Torres", "estado_persona": "suspension", "estado_alta": "activo"}]
    assert llamadas(altas.cadenas[0], "eq") == [(("terminal_id", 1), {})]
    assert llamadas(altas.cadenas[0], "in_") == [(("estado", ["pendiente_alta", "esperando_huella", "activo"]), {})]
    assert llamadas(personas.cadenas[0], "in_")[0][0][0] == "id"


def test_altas_atascadas_usa_el_plazo_de_caducidad_y_la_base_correcta_por_estado(entorno):
    def f(persona, estado, hace, campo):
        return {"persona_id": persona, "estado": estado, "actualizado_en": None, "usuario_creado_en": None,
                campo: (AHORA - timedelta(hours=hace)).isoformat()}

    filas = [
        f(ANA, "pendiente_alta", 30, "actualizado_en"),      # > 24 h: atascada
        f(LUIS, "esperando_huella", 50, "usuario_creado_en"),  # vencida
        f(ANA, "pendiente_baja", 2, "actualizado_en"),       # reciente: no
    ]
    entorno.configurar(caller={"terminal_usuario": TablaConCadenas(filas)})
    t = _get(f"{RUTA}/altas_atascadas").json()
    assert t["total"] == 2 and [e["estado"] for e in t["items"]] == ["esperando_huella", "pendiente_alta"]
    assert t["items"][0] == {"persona_nombre": "Luis Ramírez", "estado": "esperando_huella", "horas": 50}


def test_altas_atascadas_respeta_la_variable_de_caducidad(entorno):
    fila = {"persona_id": ANA, "estado": "pendiente_alta", "usuario_creado_en": None,
            "actualizado_en": (AHORA - timedelta(hours=30)).isoformat()}
    entorno.configurar(caller={"terminal_usuario": TablaConCadenas([fila])}, rpc_servicio={"fn_terminal_config_valor": 48})
    assert _get(f"{RUTA}/altas_atascadas").json() == {"clave": "altas_atascadas", "total": 0, "items": []}


def test_altas_recientes_con_quien_asigno(entorno):
    bit = TablaConCadenas(Resultado([{"persona_id": ANA, "registrado_por": "auth-ti", "creado_en": "2026-10-08T09:00:00+00:00"}], 5))
    entorno.configurar(caller={"bitacora_movimiento_terminal_usuario": bit,
                               "usuario": tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "carlos.ruiz"}])})
    t = _tarjetas(_get())["altas_recientes"]
    assert t["nivel"] == "informativo" and t["total"] == 5 and t["hay_mas"] is True
    assert t["ejemplos"] == [{"persona_nombre": "Ana Torres", "asignada_por": "carlos.ruiz", "creado_en": "2026-10-08T09:00:00+00:00"}]
    c = bit.cadenas[0]
    assert (("tipo_movimiento", "asignado"), {}) in llamadas(c, "eq") and (("terminal_id", 1), {}) in llamadas(c, "eq")


def test_reconsentimientos_pendientes_con_versiones_y_dias(entorno):
    material = {"creado_en": (AHORA - timedelta(days=5, hours=3)).isoformat()}
    consent = TablaConCadenas(
        [{"id": 4, "version": 4, "texto": "t", "texto_sha256": "a" * 64, "provisional": False, "cambio_material": True,
          "nota": None, "creado_por": "p", "creado_en": AHORA.isoformat()}],   # leer_vigente
        [material],                                                            # última con cambio material
        [{"id": 2, "version": 2, "provisional": False, "cambio_material": True}],  # versión confirmada
    )
    tu = TablaConCadenas([{"id": 77, "persona_id": ANA, "consentimiento_id": 2}])
    entorno.configurar(caller={"terminal_usuario": tu, "terminal_consentimiento": consent}, rpc_caller={"fn_terminal_reconsentimiento_pendiente_ids": [77, 9000]})
    t = _get(f"{RUTA}/reconsentimientos_pendientes").json()
    assert t["total"] == 1
    assert t["items"] == [{"persona_nombre": "Ana Torres", "version_confirmada": 2, "version_vigente": 4, "dias_pendiente": 5}]


# --- «ver todos» -------------------------------------------------------------------------------------------------------------------


def test_detalle_pagina_y_pasa_limite_y_desplazamiento_al_rpc(entorno):
    items = [{"desde": 1, "hasta": 2, "faltan": 2, "fecha": None}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 120, "items": items}})
    r = _get(f"{RUTA}/huecos_de_secuencia?limite=50&desplazamiento=100")
    assert r.status_code == 200, r.text
    assert r.json() == {"clave": "huecos_de_secuencia", "total": 120, "items": items}
    params = _llamadas_anomalias(entorno)[0][1]
    assert params["p_limite"] == 50 and params["p_desplazamiento"] == 100 and params["p_terminal_id"] == 1


@pytest.mark.parametrize("query", ["?limite=0", "?limite=201", "?desplazamiento=-1", "?desde=ayer"])
def test_detalle_valida_parametros(entorno, query):
    entorno.configurar()
    assert _get(f"{RUTA}/huecos_de_secuencia{query}").status_code == 422


def test_detalle_de_categoria_desconocida_404(entorno):
    entorno.configurar()
    assert _get(f"{RUTA}/inventada").status_code == 404
    assert _get(f"{RUTA}/{'x' * 41}").status_code == 422


@pytest.mark.parametrize("clave", ["marcas_posteriores_a_baja", "picos_de_tasa"])
def test_detalle_de_marcas_de_personas_exige_marca_lectura(entorno, clave):
    entorno.otorgados = {"terminal_usuario_lectura"}
    entorno.configurar()
    r = _get(f"{RUTA}/{clave}")
    assert r.status_code == 403 and r.json()["detail"] == "No tienes permiso para esta acción."
    assert _llamadas_anomalias(entorno) == []


def test_detalle_con_falla_propaga_el_error_no_lo_aisla(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": APIError({"code": "XX999", "message": CRUDO})})
    r = _get(f"{RUTA}/huecos_de_secuencia")
    assert r.status_code == 500 and "4407" not in r.text


def test_detalle_de_otra_terminal_no_existe(entorno):
    entorno.configurar(caller={"terminal": tabla([])})
    assert _get("/api/terminales/7/anomalias/huecos_de_secuencia").status_code == 404


# --- contrato RPC <-> DDL (90_) ---------------------------------------------------------------------------------------------------------


def test_firma_de_fn_terminal_anomalias_y_sus_categorias_en_90():
    sql = next((Path(__file__).resolve().parents[2] / "db" / "ddl").glob("90_*.sql")).read_text(encoding="utf-8")
    assert "p_terminal_id      bigint" in sql and "p_categoria        text" in sql
    assert "TO service_role" in sql and "FROM PUBLIC, anon, authenticated" in sql
    for categoria in ("marcas_posteriores_a_baja", "picos_de_tasa", "huecos_de_secuencia"):
        assert f"'{categoria}'" in sql
    for hint in ("terminal_invalida", "categoria_invalida", "ventana_invalida", "paginacion_invalida"):
        assert f"HINT = '{hint}'" in sql
    for columna in ("persona_id", "marca_en", "baja_confirmada_en", "hora", "marcas", "limite", "desde", "hasta", "faltan", "fecha"):
        assert re.search(rf"\b{columna}\b", sql), columna


def test_las_columnas_que_lee_c8_existen_en_el_ddl():
    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    texto = "\n".join(p.read_text(encoding="utf-8") for p in sorted(ddl.glob("*.sql")))
    for col in ("creada_en", "expira_en", "revocada_en", "ultimo_uso_en", "ip_cambiada_en"):
        assert re.search(rf"^\s+{col}\s", texto, re.M), col
    assert re.search(r"ck_marca_rechazada_codigo CHECK \(\s*codigo IN \(", texto)
    from app.anomalias_terminal import CODIGOS_RECHAZO

    bloque = re.search(r"ck_marca_rechazada_codigo CHECK \(\s*codigo IN \((.*?)\)\s*\)", texto, re.S).group(1)
    assert set(re.findall(r"'([a-z_]+)'", bloque)) == set(CODIGOS_RECHAZO)


# --- job de reconciliación de bajas ------------------------------------------------------------------------------------------------


def _db_reconciliacion(altas, inactivas, rpc_valor=1, rpc_error=None):
    db = MagicMock()
    db.postgrest.schema.return_value.rpc = rpc_con_firma_real()
    # personas.persona devuelve {id, estado}; las «inactivas» del test se marcan suspendidas
    filas_persona = [[{"estado": "suspension", **f} for f in lote] for lote in inactivas]
    por_tabla = {"terminal_usuario": TablaConCadenas(*altas), "persona": TablaConCadenas(*filas_persona)}
    db.postgrest.schema.return_value.table.side_effect = lambda n: por_tabla[n]
    rpc = db.postgrest.schema.return_value.rpc

    def segun(nombre, params):
        r = MagicMock()
        valor = rpc_valor(params) if callable(rpc_valor) else rpc_valor
        if rpc_error is not None:
            r.execute.side_effect = rpc_error
        else:
            r.execute.return_value = Resultado(valor)
        return r

    rpc.side_effect = segun
    return db, rpc, por_tabla


def test_reconciliacion_pide_la_baja_de_cada_persona_inactiva_con_altas(caplog):
    db, rpc, _ = _db_reconciliacion(
        [[{"persona_id": ANA}, {"persona_id": LUIS}]], [[{"id": ANA}, {"id": LUIS, "estado": "activo"}]], rpc_valor=2
    )
    with caplog.at_level(logging.WARNING):
        resumen = jobs.ejecutar_reconciliacion_bajas(db)
    assert resumen == {"inactivas": 1, "emitidas": 2, "sin_autor": 0, "fallidas": 0}
    assert [c.args for c in rpc.call_args_list] == [("fn_terminal_baja_por_persona_inactiva", {"p_persona_id": ANA})]
    assert any("bajas_emitidas=2" in x.getMessage() and x.levelno == logging.WARNING for x in caplog.records)


def test_reconciliacion_sin_inactivas_no_llama_al_rpc():
    db, rpc, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA, "estado": "activo"}]])
    assert jobs.ejecutar_reconciliacion_bajas(db) == {"inactivas": 0, "emitidas": 0, "sin_autor": 0, "fallidas": 0}
    rpc.assert_not_called()


def test_resultado_menos_uno_es_alerta_permanente_en_cada_corrida_y_no_se_reintenta(caplog):
    db, rpc, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_valor=-1)
    for _ in range(2):  # dos corridas: la alerta se repite
        caplog.clear()
        with caplog.at_level(logging.ERROR):
            resumen = jobs.ejecutar_reconciliacion_bajas(db)
        assert resumen["sin_autor"] == 1 and resumen["emitidas"] == 0
        assert any("ALERTA PERMANENTE" in x.getMessage() and x.levelno >= logging.ERROR for x in caplog.records)
        db, rpc, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_valor=-1)


def test_menos_uno_se_llama_una_sola_vez_por_corrida():
    db, rpc, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_valor=-1)
    jobs.ejecutar_reconciliacion_bajas(db)
    assert rpc.call_count == 1


def test_la_alerta_no_lleva_el_uuid_completo(caplog):
    db, _, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_valor=-1)
    with caplog.at_level(logging.ERROR):
        jobs.ejecutar_reconciliacion_bajas(db)
    assert ANA not in caplog.text and ANA[:8] in caplog.text


@pytest.mark.parametrize("fallo", [APIError({"code": "XX999", "message": CRUDO}), ConnectionError(CRUDO), TimeoutError(CRUDO)])
def test_falla_del_rpc_por_persona_se_cuenta_y_no_propaga(fallo, caplog):
    db, _, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_error=fallo)
    with caplog.at_level(logging.ERROR):
        resumen = jobs.ejecutar_reconciliacion_bajas(db)
    assert resumen["fallidas"] == 1 and "4407" not in caplog.text


@pytest.mark.parametrize("valor", [None, True, "x", 2.0, -5])
def test_forma_inesperada_del_rpc_cuenta_como_fallida(valor):
    db, _, _ = _db_reconciliacion([[{"persona_id": ANA}]], [[{"id": ANA}]], rpc_valor=valor)
    assert jobs.ejecutar_reconciliacion_bajas(db)["fallidas"] == 1


@pytest.mark.parametrize("fallo", [APIError({"code": "XX999", "message": CRUDO}), ConnectionError(CRUDO)])
def test_si_no_puede_leer_devuelve_none_con_error(fallo, caplog):
    db = MagicMock()
    db.postgrest.schema.side_effect = fallo
    with caplog.at_level(logging.ERROR):
        assert jobs.ejecutar_reconciliacion_bajas(db) is None
    assert any(x.levelno >= logging.ERROR for x in caplog.records) and "4407" not in caplog.text


def test_job_que_no_puede_arrancar_no_propaga(monkeypatch):
    monkeypatch.setattr(jobs, "_cliente", lambda: (_ for _ in ()).throw(RuntimeError(CRUDO)))
    assert jobs.ejecutar_reconciliacion_bajas() is None


def test_reconciliacion_pagina_las_altas_y_trocea_las_personas():
    p1 = [{"persona_id": f"{i:08d}-0000-0000-0000-000000000000"} for i in range(1000)]
    p2 = [{"persona_id": "ffffffff-0000-0000-0000-000000000000"}]
    db, rpc, tablas = _db_reconciliacion([p1, p2], [[]] * 11)
    jobs.ejecutar_reconciliacion_bajas(db)
    assert len(tablas["terminal_usuario"].cadenas) == 2  # dos páginas
    assert [llamadas(c, "range")[0][0] for c in tablas["terminal_usuario"].cadenas] == [(0, 999), (1000, 1999)]
    assert len(tablas["persona"].cadenas) == 11  # 1001 personas en trozos de 100
    assert all(len(llamadas(c, "in_")[0][0][1]) <= 100 for c in tablas["persona"].cadenas)


def test_reconciliacion_tope_por_corrida(caplog):
    inactivas = [{"id": f"{i:08d}-0000-0000-0000-000000000000"} for i in range(250)]
    altas = [{"persona_id": f["id"]} for f in inactivas]
    db, rpc, _ = _db_reconciliacion([altas], [inactivas[:100], inactivas[100:200], inactivas[200:]], rpc_valor=0)
    with caplog.at_level(logging.WARNING):
        resumen = jobs.ejecutar_reconciliacion_bajas(db)
    assert rpc.call_count == 200 and resumen["inactivas"] == 250
    assert any("200 por corrida" in x.getMessage() for x in caplog.records)


def test_el_scheduler_registra_la_reconciliacion_cada_10_minutos_sin_solapes():
    import asyncio
    from unittest.mock import patch

    from app.scheduler import lifespan

    falso = MagicMock()

    async def escenario():
        with patch("app.scheduler.BackgroundScheduler", return_value=falso), patch(
            "app.scheduler._leer_hora_corrida_cierre_dia", return_value=(3, 0)
        ):
            async with lifespan(MagicMock()):
                c = {x.kwargs["id"]: x for x in falso.add_job.call_args_list}["terminales_reconciliacion_bajas"]
                assert c.args[0] is jobs.ejecutar_reconciliacion_bajas
                assert c.kwargs["trigger"] == "interval" and c.kwargs["minutes"] == 10
                assert c.kwargs["max_instances"] == 1 and c.kwargs["coalesce"] is True

    asyncio.run(escenario())


def test_firma_del_rpc_de_baja_por_persona_en_ddl():
    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    sql = next(ddl.glob("91_*.sql")).read_text(encoding="utf-8")
    assert "fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)" in sql
    assert "fn_terminal_baja_por_persona_inactiva(uuid) TO service_role" in sql
    assert "RETURN -1" in sql


# --- ajustes de security a C8 (B1-B4) ---------------------------------------------------------------------------------------------------


def test_las_personas_con_menos_uno_permanente_no_dejan_sin_atender_a_las_demas():
    """B1: 210 personas -1 + 40 normales (250 > cupo de 200). En la 2ª corrida las que NO fueron -1 van primero."""
    ids = [f"{i:08d}-0000-0000-0000-000000000000" for i in range(250)]
    menos_uno = set(ids[:210])  # las 210 primeras no tienen autor

    def rpc_valor(params):
        return -1 if params["p_persona_id"] in menos_uno else 1

    def correr():
        altas = [{"persona_id": i} for i in ids]
        lotes = [[{"id": i} for i in ids[k : k + 100]] for k in range(0, 250, 100)]
        db, rpc, _ = _db_reconciliacion([altas], lotes, rpc_valor=rpc_valor)
        jobs.ejecutar_reconciliacion_bajas(db)
        return [c.args[1]["p_persona_id"] for c in rpc.call_args_list]

    primera = correr()
    assert len(primera) == 200 and sum(1 for p in primera if p not in menos_uno) < 40  # por orden alfabético, las 40 buenas van al final
    segunda = correr()
    assert len(segunda) == 200
    assert {p for p in ids if p not in menos_uno} <= set(segunda)  # las 40 normales ya entran en la 2ª corrida
    # van PRIMERO: las 50 que no tenían marca de -1 (10 que aún son -1 sin marca previa + las 40 normales), en orden
    assert segunda[:50] == sorted(ids[200:250])


def test_un_menos_uno_sin_cupo_conserva_su_marca_para_la_siguiente_corrida():
    ids = [f"{i:08d}-0000-0000-0000-000000000000" for i in range(210)]
    jobs._SIN_AUTOR_PREVIO.update(ids)
    altas = [{"persona_id": i} for i in ids]
    lotes = [[{"id": i} for i in ids[k : k + 100]] for k in range(0, 210, 100)]
    db, _, _ = _db_reconciliacion([altas], lotes, rpc_valor=-1)
    jobs.ejecutar_reconciliacion_bajas(db)
    assert jobs._SIN_AUTOR_PREVIO == set(ids)  # las 200 procesadas siguen -1 y las 10 sin cupo no pierden su marca


def test_alta_huerfana_persona_inexistente_tambien_se_reconcilia():
    """B2: la frontera no tiene FK; si la persona ya no existe en personas.persona, su alta viva se trata como inactiva."""
    db, rpc, _ = _db_reconciliacion([[{"persona_id": ANA}, {"persona_id": LUIS}]], [[{"id": ANA, "estado": "activo"}]], rpc_valor=1)
    resumen = jobs.ejecutar_reconciliacion_bajas(db)
    assert resumen["inactivas"] == 1  # LUIS no está en personas.persona
    assert [c.args[1]["p_persona_id"] for c in rpc.call_args_list] == [LUIS]


def test_la_tarjeta_7_muestra_las_altas_huerfanas_sin_nombre(entorno):
    altas = TablaConCadenas([{"persona_id": ANA, "estado": "activo"}, {"persona_id": LUIS, "estado": "activo"}])
    personas = TablaConCadenas([{"id": ANA, "estado": "activo", "primer_nombre": "Ana", "apellido_paterno": "Torres"}])
    entorno.configurar(caller={"terminal_usuario": altas, "persona": personas})
    t = _get(f"{RUTA}/inconsistencias_de_baja").json()
    assert t["total"] == 1
    assert t["items"] == [{"persona_nombre": None, "estado_persona": "inexistente", "estado_alta": "activo"}]


# caché corta del tablero (B3)


def test_el_tablero_se_sirve_de_cache_dentro_del_ttl_y_no_vuelve_a_consultar(entorno):
    entorno.configurar()
    primero = _get().json()
    n = len(entorno.rpc_s.call_args_list)
    segundo = _get().json()
    assert segundo == primero and len(entorno.rpc_s.call_args_list) == n  # 0 consultas nuevas


def test_la_cache_expira(entorno, monkeypatch):
    from app.routers import anomalias_terminales as ar

    entorno.configurar()
    reloj = [1000.0]
    monkeypatch.setattr(ar, "monotonic", lambda: reloj[0])
    _get()
    n = len(entorno.rpc_s.call_args_list)
    reloj[0] += ar.CACHE.ttl + 1
    _get()
    assert len(entorno.rpc_s.call_args_list) > n


def test_la_cache_no_se_comparte_entre_usuarios_ni_entre_permisos_distintos(entorno):
    entorno.configurar()
    _get()
    n = len(entorno.rpc_s.call_args_list)
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(auth_user_id="otro-usuario", correo="o@example.com")
    _get()
    assert len(entorno.rpc_s.call_args_list) > n  # otro usuario: no reutiliza
    n = len(entorno.rpc_s.call_args_list)
    entorno.otorgados = {"terminal_usuario_lectura"}  # el mismo usuario sin marca_lectura: otra clave
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    t = _tarjetas(_get())
    assert t["picos_de_tasa"]["motivo"] == "sin_permiso"


def test_la_cache_distingue_ventanas_y_terminales(entorno):
    entorno.configurar()
    _get()
    n = len(entorno.rpc_s.call_args_list)
    _get(RUTA + "?desde=2026-10-01")
    assert len(entorno.rpc_s.call_args_list) > n


def test_la_cache_no_evita_el_gate_ni_la_terminal_inexistente(entorno):
    entorno.configurar()
    _get()
    entorno.otorgados = set()
    assert _get().status_code == 403  # el gate corre ANTES de la caché
    entorno.otorgados = {"terminal_usuario_lectura", "marca_lectura"}
    entorno.configurar(caller={"terminal": tabla([])})
    assert _get().status_code == 404


def test_la_cache_es_acotada():
    from app.routers.anomalias_terminales import CacheCorto

    c = CacheCorto(ttl_seg=60, maximo=3)
    for i in range(5):
        c.guardar((i,), {"i": i})
    assert len(c._datos) == 3 and c.obtener((0,)) is None and c.obtener((4,)) == {"i": 4}


# ninguna salida lleva identidad ni secretos (B4)

PROHIBIDAS = {"persona_id", "employee_no", "hash", "ip", "ultima_ip", "marca_id", "auth_user_id", "evento_id"}


def _claves(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            yield from _claves(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _claves(v)


def test_ninguna_categoria_devuelve_claves_de_identidad_ni_secretos(entorno):
    """Las fuentes traen persona_id, marca_id, hash, IP…; la salida (tablero y «ver todos») no debe llevar ninguna."""
    rpc_filas = {"total": 1, "items": [{
        "persona_id": ANA, "marca_id": 1, "marca_en": "2026-10-08T10:00:00+00:00", "baja_confirmada_en": "2026-10-01T00:00:00+00:00",
        "hora": "2026-10-08T10:00:00+00:00", "marcas": 12, "limite": 10, "desde": 1, "hasta": 2, "faltan": 1, "fecha": None,
    }]}
    cred = [_cred(creada_en=(AHORA - timedelta(days=400)).isoformat(), ultimo_uso_en=None) | {"hash": "f" * 64, "ultima_ip": "10.0.0.5"}]
    entorno.configurar(
        caller={
            "terminal_usuario": tabla([{"id": 77, "persona_id": ANA, "estado": "activo", "consentimiento_id": 2,
                                        "actualizado_en": (AHORA - timedelta(hours=90)).isoformat(),
                                        "usuario_creado_en": (AHORA - timedelta(hours=90)).isoformat(), "employee_no": 1077}]),
            "persona": tabla([{"id": ANA, "estado": "suspension", "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
            "bitacora_movimiento_terminal_usuario": tabla([{"persona_id": ANA, "registrado_por": "auth-ti", "creado_en": "2026-10-08T09:00:00+00:00", "employee_no": 5}]),
            "usuario": tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "carlos.ruiz"}]),
            "terminal_consentimiento": tabla([{"id": 4, "version": 4, "texto": "t", "texto_sha256": "a" * 64, "provisional": False,
                                               "cambio_material": True, "nota": None, "creado_por": "p", "creado_en": AHORA.isoformat()}]),
        },
        servicio={"marca": tabla([], count=3), "marca_rechazada": tabla([], count=2), "terminal_credencial": tabla(cred)},
        rpc_caller={"fn_terminal_reconsentimiento_pendiente_ids": [77]},
        rpc_servicio={"fn_terminal_anomalias": rpc_filas},
    )
    r = _get()
    assert r.status_code == 200
    assert not (set(_claves(r.json())) & PROHIBIDAS)
    assert all(t["estado"] == "con_hallazgos" for t in r.json()["categorias"] if t["clave"] not in ("interruptor_huella", "terminal_sin_contacto"))      # la 14 es global y tiene su propia fuente (apagado = sin hallazgos)
    for clave in (c.clave for c in CATEGORIAS):
        d = _get(f"{RUTA}/{clave}")
        assert d.status_code == 200, (clave, d.text)
        assert not (set(_claves(d.json())) & PROHIBIDAS), clave
    assert "f" * 64 not in r.text and "10.0.0.5" not in r.text and ANA not in r.text


# --- 94_: tres categorías de huella inferida / confirmada ------------------------------------------------------------------------------------------------


def test_huellas_inferidas_exceso_pasa_las_cifras_y_lleva_la_nota_de_que_es_esperado_el_primer_dia(entorno):
    items = [{"dia": "2026-10-09", "inferidas": 9, "manuales": 1, "activaciones": 10, "limite_inferidas": 5}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    t = _tarjetas(_get())["huellas_inferidas_exceso"]
    assert t["estado"] == "con_hallazgos" and t["nivel"] == "revisar" and t["total"] == 1
    assert t["ejemplos"] == [{"dia": "2026-10-09", "inferidas": 9, "manuales": 1, "activaciones": 10, "limite_inferidas": 5}]
    assert "ESPERADO el primer día" in t["nota"]
    otras = [x for x in _tarjetas(_get()).values() if x["clave"] not in ("huellas_inferidas_exceso", "interruptor_huella", "terminal_sin_contacto")]
    assert all(x["nota"] is None for x in otras)


def test_inferida_sin_marcas_resuelve_el_nombre_y_no_expone_ids(entorno):
    items = [{"terminal_usuario_id": 77, "persona_id": ANA, "evidencia": "inferida", "activada_en": "2026-09-30T10:00:00+00:00"}]
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    t = _tarjetas(_get())["inferida_sin_marcas"]
    assert t["ejemplos"] == [{"persona_nombre": "Ana Torres", "evidencia": "inferida", "activada_en": "2026-09-30T10:00:00+00:00"}]
    assert ANA not in str(t) and "terminal_usuario_id" not in str(t) and "77" not in str(t["ejemplos"])


def test_asignador_confirmador_resuelve_nombre_de_la_persona_y_del_autor_sin_ids(entorno):
    items = [{"terminal_usuario_id": 77, "persona_id": ANA, "confirmada_en": "2026-10-08T10:00:00+00:00", "usuario_id": "auth-ti"}]
    entorno.configurar(caller={"usuario": tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "ti.uno"}])},
                       rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    t = _tarjetas(_get())["asignador_confirmador"]
    assert t["nivel"] == "revisar" and t["ejemplos"] == [{"persona_nombre": "Ana Torres", "confirmada_por": "ti.uno", "confirmada_en": "2026-10-08T10:00:00+00:00"}]
    assert ANA not in str(t) and "auth-ti" not in str(t) and "usuario_id" not in str(t)


def test_las_categorias_de_huella_aisladas_si_la_migracion_94_falta_dan_no_disponible_sin_tumbar_el_tablero(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": APIError({"code": "22023", "hint": "categoria_invalida", "message": CRUDO})})
    t = _tarjetas(_get())
    for clave in ("huellas_inferidas_exceso", "inferida_sin_marcas", "asignador_confirmador"):
        assert t[clave]["estado"] == "error" and CRUDO not in str(t[clave])
    assert len(t) == 15


def test_sin_hallazgos_las_tres_categorias_de_huella_salen_vacias(entorno):
    entorno.configurar()
    t = _tarjetas(_get())
    assert all(t[c]["estado"] == "sin_hallazgos" and t[c]["total"] == 0 for c in ("huellas_inferidas_exceso", "inferida_sin_marcas", "asignador_confirmador"))


def test_security_r1_inferida_sin_marcas_exige_marca_lectura_y_no_llama_al_rpc_sin_ella(entorno):
    items = [{"terminal_usuario_id": 77, "persona_id": ANA, "evidencia": "inferida", "activada_en": "2026-09-30T10:00:00+00:00"}]
    entorno.otorgados = {"terminal_usuario_lectura"}
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    t = _tarjetas(_get())["inferida_sin_marcas"]
    assert t["estado"] == "no_disponible" and t["motivo"] == "sin_permiso" and t["ejemplos"] == [] and t["total"] is None and "Ana" not in str(t)
    assert "inferida_sin_marcas" not in {c[1]["p_categoria"] for c in _llamadas_anomalias(entorno)}
    d = _get(f"{RUTA}/inferida_sin_marcas")
    assert d.status_code in (403, 404) or "Ana" not in d.text                        # el detalle tampoco la muestra a quien no puede leer marcas
    entorno.otorgados = {"terminal_usuario_lectura", "marca_lectura"}
    entorno.configurar(rpc_servicio={"fn_terminal_anomalias": {"total": 1, "items": items}})
    assert _tarjetas(_get())["inferida_sin_marcas"]["estado"] == "con_hallazgos"


# --- categoría 14: interruptor de la activación por huella (GLOBAL; CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md §5) -----------------------------------------------

ENCENDIDO_SANO = {"activo": True, "vencido": False, "motivo": None, "valor": "1", "hasta": "2026-11-03T05:59:59Z", "encendido_por": "uuid-del-autor-9911", "encendido_en": "2026-10-12T16:03:11Z",
                  "ultimo_cambio_via_funcion": True, "sin_registro": False}


def _t14(entorno, estado):
    entorno.configurar(rpc_servicio={"fn_terminal_inferir_huella_estado": estado})
    return _tarjetas(_get())["interruptor_huella"]


def test_la_tarjeta_14_sin_alarma_es_sin_hallazgos(entorno):
    for estado in (ESTADO_INTERRUPTOR_APAGADO, ENCENDIDO_SANO, ESTADO_INTERRUPTOR_APAGADO | {"motivo": "vencido", "vencido": True}):
        t = _t14(entorno, estado)
        assert t["estado"] == "sin_hallazgos" and t["total"] == 0 and t["nivel"] is None and t["ejemplos"] == []


@pytest.mark.parametrize("estado,nivel,codigo", [
    (ESTADO_INTERRUPTOR_APAGADO | {"motivo": "sin_respaldo_de_la_funcion", "valor": "1"}, "atender", "sin_respaldo_de_la_funcion"),
    (ENCENDIDO_SANO | {"ultimo_cambio_via_funcion": False}, "atender", "cambio_fuera_de_la_funcion"),
    (ENCENDIDO_SANO | {"sin_registro": True, "ultimo_cambio_via_funcion": None}, "atender", "sin_registro"),
    (ESTADO_INTERRUPTOR_APAGADO | {"motivo": "vigencias_inconsistentes"}, "revisar", "vigencias_inconsistentes"),
    (ESTADO_INTERRUPTOR_APAGADO | {"motivo": "error"}, "revisar", "error"),
])
def test_la_tarjeta_14_con_alarma_lleva_nivel_codigo_y_mensaje_sin_nombres_ni_fechas(entorno, estado, nivel, codigo):
    t = _t14(entorno, estado)
    assert (t["estado"], t["nivel"], t["total"], t["hay_mas"]) == ("con_hallazgos", nivel, 1, False)
    assert len(t["ejemplos"]) == 1 and set(t["ejemplos"][0]) == {"codigo", "mensaje"} and t["ejemplos"][0]["codigo"] == codigo and "Sistemas" in t["ejemplos"][0]["mensaje"]
    assert t["nota"] == "Es un ajuste global del sistema, no de esta terminal."
    assert "uuid-del-autor-9911" not in str(t) and "2026-" not in str(t)


@pytest.mark.parametrize("ilegible", [None, [], "texto", {"activo": True}, {"activo": "si"}, ENCENDIDO_SANO | {"sin_registro": "no"}])
def test_un_estado_ilegible_deja_la_tarjeta_14_en_error_nunca_sin_hallazgos(entorno, ilegible):
    t = _t14(entorno, ilegible)
    assert t["estado"] == "error" and t["total"] is None and t["ejemplos"] == [] and t["nivel"] is None


def test_si_falla_la_lectura_del_interruptor_solo_esa_tarjeta_sale_en_error_y_las_demas_siguen(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_inferir_huella_estado": APIError({"code": "XX000", "message": CRUDO})})
    t = _tarjetas(_get())
    assert t["interruptor_huella"]["estado"] == "error" and CRUDO not in str(t["interruptor_huella"])
    assert all(t[c]["estado"] == "sin_hallazgos" for c in t if c != "interruptor_huella")


def test_una_migracion_97_sin_aplicar_deja_la_tarjeta_14_no_disponible(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_inferir_huella_estado": APIError({"code": "PGRST202", "message": CRUDO})})
    t = _tarjetas(_get())["interruptor_huella"]
    assert t["estado"] == "no_disponible" and t["motivo"] == "falta_migracion"


def test_la_tarjeta_14_no_exige_marca_lectura_pero_si_el_gate_del_tablero(entorno):
    entorno.otorgados = {"terminal_usuario_lectura"}                          # sin marca_lectura
    t = _t14(entorno, ESTADO_INTERRUPTOR_APAGADO | {"motivo": "error"})
    assert t["estado"] == "con_hallazgos"
    entorno.otorgados = set()
    entorno.configurar()
    assert _get().status_code == 403


def test_la_tarjeta_14_es_una_sola_por_tablero_y_global_en_todas_las_terminales(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_inferir_huella_estado": ESTADO_INTERRUPTOR_APAGADO | {"motivo": "sin_respaldo_de_la_funcion", "valor": "1"}})
    categorias = _get().json()["categorias"]
    assert [c["clave"] for c in categorias].count("interruptor_huella") == 1
    assert sum(c["total"] or 0 for c in categorias if c["clave"] == "interruptor_huella") == 1       # UNA alarma global, no N por terminal
    rpcs = [c for c in entorno.rpc_s.call_args_list if c.args[0] == "fn_terminal_inferir_huella_estado"]
    assert len(rpcs) == 1 and rpcs[0].args[1] == {}                                                    # sin terminal_id: no depende de la terminal


def test_el_detalle_ver_todos_de_la_categoria_14(entorno):
    entorno.configurar(rpc_servicio={"fn_terminal_inferir_huella_estado": ENCENDIDO_SANO | {"ultimo_cambio_via_funcion": False}})
    d = _get(f"{RUTA}/interruptor_huella").json()
    assert d["total"] == 1 and d["items"][0]["codigo"] == "cambio_fuera_de_la_funcion"


# --- categoría 15: terminal sin contacto (POR terminal; CONTRATO §9, condiciones de security) ----------------------------------------------------------------------


def _hace(**kw):
    return (datetime.now(timezone.utc) - timedelta(**kw)).isoformat()


def _t15(entorno, **fila):
    entorno.configurar(caller={"terminal": tabla([{**TERMINAL, **fila}])})
    return _tarjetas(_get())["terminal_sin_contacto"]


def test_en_linea_o_inactiva_no_hay_hallazgo(entorno):
    for fila in ({"ultimo_contacto_en": _hace(seconds=30)}, {"ultimo_contacto_en": _hace(seconds=299)}, {"activa": False, "ultimo_contacto_en": _hace(hours=5)},
                 {"activa": False, "ultimo_contacto_en": None}):
        t = _t15(entorno, **fila)
        assert t["estado"] == "sin_hallazgos" and t["total"] == 0 and t["nivel"] is None and t["ejemplos"] == []


@pytest.mark.parametrize("hace,nivel,codigo,minutos", [
    ({"seconds": 301}, "revisar", "sin_latido_revisar", 5), ({"minutes": 10}, "revisar", "sin_latido_revisar", 10), ({"minutes": 14, "seconds": 59}, "revisar", "sin_latido_revisar", 14),
    ({"minutes": 15}, "atender", "sin_latido_atender", 15), ({"minutes": 15, "seconds": 1}, "atender", "sin_latido_atender", 15), ({"hours": 5}, "atender", "sin_latido_atender", 300),
])
def test_los_niveles_dependen_de_cuanto_lleva_sin_latido(entorno, hace, nivel, codigo, minutos):
    t = _t15(entorno, ultimo_contacto_en=_hace(**hace))
    assert (t["estado"], t["nivel"], t["total"], t["hay_mas"]) == ("con_hallazgos", nivel, 1, False)
    assert len(t["ejemplos"]) == 1 and set(t["ejemplos"][0]) == {"codigo", "mensaje", "minutos_sin_latido"}
    assert t["ejemplos"][0]["codigo"] == codigo and t["ejemplos"][0]["minutos_sin_latido"] == minutos and t["ejemplos"][0]["mensaje"]


def test_nunca_hubo_contacto_es_revisar_y_no_atender(entorno):
    t = _t15(entorno, ultimo_contacto_en=None)
    assert (t["estado"], t["nivel"]) == ("con_hallazgos", "revisar")
    assert t["ejemplos"] == [{"codigo": "nunca_comunicada", "mensaje": "La terminal aún no se ha comunicado.", "minutos_sin_latido": None}]


def test_el_ejemplo_no_lleva_serie_ip_employee_no_ni_credencial(entorno):
    t = _t15(entorno, ultimo_contacto_en=_hace(hours=2), ultima_ip="10.9.8.7", hash="f" * 64, employee_no=1234)
    texto = str(t)
    assert "SERIE-1" not in texto and "10.9.8.7" not in texto and "f" * 64 not in texto and "1234" not in texto


def test_un_ultimo_contacto_ilegible_deja_la_tarjeta_en_error_y_no_en_nunca(entorno):
    t = _t15(entorno, ultimo_contacto_en="no-es-una-fecha")
    assert t["estado"] == "error" and t["nivel"] is None and t["total"] is None and t["ejemplos"] == []
    assert all(x["estado"] == "sin_hallazgos" for x in _tarjetas(_get()).values() if x["clave"] not in ("terminal_sin_contacto", "interruptor_huella"))     # aislada


def test_usa_la_misma_funcion_de_estado_de_contacto_que_la_insignia(entorno):
    from app import anomalias_terminal, contacto_terminal
    from app.routers import terminales

    assert anomalias_terminal.estado_contacto is contacto_terminal.estado_contacto is terminales.estado_contacto


def test_el_umbral_es_el_de_la_configuracion_el_mismo_de_la_insignia(entorno):
    entorno.ajustes = {"terminal_umbral_sin_contacto_seg": 900}
    assert _t15(entorno, ultimo_contacto_en=_hace(minutes=10))["estado"] == "sin_hallazgos"          # 10 min < umbral de 15: en línea para la insignia y para la tarjeta
    entorno.ajustes = {"terminal_umbral_sin_contacto_seg": 60}
    assert _t15(entorno, ultimo_contacto_en=_hace(minutes=2))["nivel"] == "revisar"


def test_no_exige_marca_lectura_pero_si_el_gate_del_tablero(entorno):
    entorno.otorgados = {"terminal_usuario_lectura"}
    assert _t15(entorno, ultimo_contacto_en=_hace(hours=1))["estado"] == "con_hallazgos"
    entorno.otorgados = set()
    entorno.configurar()
    assert _get().status_code == 403


def test_es_por_terminal_cada_tablero_ve_la_suya(entorno):
    assert _t15(entorno, id=1, ultimo_contacto_en=_hace(hours=1))["estado"] == "con_hallazgos"
    entorno.configurar(caller={"terminal": tabla([{**TERMINAL, "id": 2, "ultimo_contacto_en": _hace(seconds=5)}])})
    assert _tarjetas(_get(RUTA.replace("/1/", "/2/") if "/1/" in RUTA else RUTA))["terminal_sin_contacto"]["estado"] == "sin_hallazgos"


def test_es_un_aviso_pasivo_y_la_nota_lo_dice(entorno):
    t = _t15(entorno, ultimo_contacto_en=_hace(hours=1))
    assert "pasivo" in t["nota"] and "no envía correos" in t["nota"] and "a diario" in t["nota"] and "monitor externo" in t["nota"]


def test_el_detalle_ver_todos_de_la_categoria_15(entorno):
    entorno.configurar(caller={"terminal": tabla([{**TERMINAL, "ultimo_contacto_en": _hace(minutes=20)}])})
    d = _get(f"{RUTA}/terminal_sin_contacto").json()
    assert d["total"] == 1 and d["items"][0]["codigo"] == "sin_latido_atender"
