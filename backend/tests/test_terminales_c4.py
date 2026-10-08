"""C4 del contrato de Terminales: altas de una terminal, baja/cancelar, historial, personas asignables y
altas de una persona. Mocks del cliente de Supabase por NOMBRE de tabla -- NUNCA contra la base real ni
escrituras reales. (Asignar y los campos de consentimiento llegan con C5/88_.)"""

import logging
import re
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from _mocks_supabase import Resultado, TablaConCadenas, db_por_nombre, llamadas, tabla
from app import permisos
from app.altas_terminal import accion_disponible, sanear_motivo, separar_error
from app.catalogo_terminal import CATALOGO_TERMINAL, valor_vigente
from app.config import Settings, get_settings
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

AUTH = {"Authorization": "Bearer fake-token"}
CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
PERSONA = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"
CRUDO = "texto-crudo-id-interno-7002"
AHORA = datetime.now(timezone.utc)
CONSENTIMIENTO = {"id": 4, "version": 4, "provisional": False, "cambio_material": True}


def _alta(id_=77, estado="activo", persona=PERSONA, terminal=1, **extra):
    fila = {
        "id": id_, "terminal_id": terminal, "employee_no": 1000 + id_, "persona_id": persona, "estado": estado,
        "huellas_capturadas": 0 if estado != "activo" else 2, "error_detalle": None,
        "creado_en": "2026-10-07T09:00:00+00:00", "actualizado_en": "2026-10-07T09:30:00+00:00",
        "usuario_creado_en": None, "consentimiento_id": 4,
    }
    fila.update(extra)
    return fila


def _terminal_fila(id_=1):
    return {
        "id": id_, "terminal_id": f"SERIE-{id_}", "nombre": f"Terminal {id_}", "modelo": "X", "activa": True,
        "ultimo_contacto_en": (AHORA - timedelta(seconds=30)).isoformat(), "terminal_alcanzable": True,
        "reloj_desfase_seg": 1, "version_pi": "1.0", "marcas_pendientes": 0,
    }


def _tabla_secuencia(*resultados):
    """execute() devuelve cada resultado en orden (misma tabla consultada varias veces con datos distintos)."""
    t = tabla([])
    t.execute.side_effect = [r if isinstance(r, Resultado) else Resultado(r) for r in resultados]
    return t


@pytest.fixture
def entorno(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    entorno.codigos = []

    def tiene_alguno(db, persona, *codigos):
        entorno.codigos.append(codigos)
        return entorno.permitido

    entorno.permitido = True
    entorno.pendientes = []
    entorno.admin_generico = False
    monkeypatch.setattr(permisos, "tiene_alguno", tiene_alguno)
    monkeypatch.setattr(permisos, "es_administrador_generico", lambda db, persona: entorno.admin_generico)

    def configurar(tablas, parametro=None, settings=None):
        tablas = dict(tablas)
        tablas.setdefault("terminal_consentimiento", tabla([CONSENTIMIENTO]))
        db = db_por_nombre(estricto=True, **tablas)
        db.postgrest.schema.return_value.rpc.return_value.execute.return_value = Resultado(entorno.pendientes)
        servicio = db_por_nombre(parametro=parametro if parametro is not None else tabla([]))
        app.dependency_overrides[get_caller_client] = lambda: db
        app.dependency_overrides[get_caller_identity] = lambda: CALLER
        app.dependency_overrides[get_service_client] = lambda: servicio
        app.dependency_overrides[get_settings] = lambda: settings or Settings(
            _env_file=None, supabase_url="http://x", supabase_anon_key="a", supabase_service_role_key="s"
        )
        return db, servicio

    entorno.configurar = configurar
    return entorno


def _cliente():
    return TestClient(app, raise_server_exceptions=False)


def _conteos(estados):
    """Los 5 conteos por estado (head) en el orden de ESTADOS_ALTA."""
    orden = ("pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja")
    return [Resultado([], sum(1 for e in estados if e == o)) for o in orden]


def _tablas_lista(altas, todas=None, nombres=None, creadas=(), total=None, terminal=None, pend=None):
    for c in creadas:  # 88_: usuario_creado_en es una columna de terminal_usuario, no una consulta a la bitácora
        for a in altas:
            if a["id"] == c["terminal_usuario_id"]:
                a["usuario_creado_en"] = c["creado_en"]
    return {
        "terminal": tabla([terminal if terminal is not None else _terminal_fila()]),
        "terminal_usuario": _tabla_secuencia(
            # con pendientes, primero se piden las altas de la terminal para intersectar (C6); luego la página y los conteos
            *([Resultado(pend)] if pend else []),
            Resultado(altas, total),
            *_conteos(todas if todas is not None else [a["estado"] for a in altas]),
        ),
        "persona": tabla(nombres if nombres is not None else [{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
        "bitacora_movimiento_terminal_usuario": tabla(list(creadas)),
    }


# --- piezas puras ------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "texto,esperado",
    [
        (None, (None, None)),
        ("", (None, None)),
        ("usuario_ya_existe: el usuario ya estaba", ("usuario_ya_existe", "el usuario ya estaba")),
        ("usuario_ya_existe: ", ("usuario_ya_existe", None)),
        ("Error en el puente: algo", (None, "Error en el puente: algo")),  # no es un código
        ("sin separador", (None, "sin separador")),
        ("x" * 41 + ": detalle", (None, "x" * 41 + ": detalle")),  # código demasiado largo
        ("a: b: c", ("a", "b: c")),  # separa en el primer «: »
    ],
)
def test_separar_error(texto, esperado):
    assert separar_error(texto) == esperado


@pytest.mark.parametrize(
    "estado,accion",
    [("pendiente_alta", "cancelar_alta"), ("esperando_huella", "cancelar_alta"), ("activo", "dar_de_baja"),
     ("pendiente_baja", None), ("baja", None), ("raro", None)],
)
def test_accion_disponible(estado, accion):
    assert accion_disponible(estado) == accion


def test_sanear_motivo():
    assert sanear_motivo(None) is None
    assert sanear_motivo("   \x00\x1f  ") is None
    assert sanear_motivo("  hola\x07   mundo\r\n  ") == "hola mundo"
    assert len(sanear_motivo("a" * 700)) == 500


# --- variable de caducidad -----------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "filas,esperado",
    [([{"valor": "48"}], 48), ([{"valor": " 12 "}], 12), ([], 24), ([{"valor": "abc"}], 24), ([{"valor": "3"}], 24),
     ([{"valor": "169"}], 24), ([{"valor": None}], 24)],
)
def test_valor_vigente_tolera_ausencia_corrupcion_y_rango(filas, esperado):
    servicio = db_por_nombre(parametro=tabla(filas))
    assert valor_vigente(servicio, "terminal_caducidad_alta_horas") == esperado


def test_valor_vigente_con_la_base_caida_devuelve_el_defecto():
    servicio = MagicMock()
    servicio.postgrest.schema.side_effect = ConnectionError(CRUDO)
    assert valor_vigente(servicio, "terminal_caducidad_alta_horas") == 24


def test_el_catalogo_coincide_con_fn_terminal_config_catalogo_del_89():
    import re
    from pathlib import Path

    archivos = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/89_*.sql"))
    if not archivos:
        pytest.skip("db/ddl/89_*.sql todavía no existe")
    sql = archivos[0].read_text(encoding="utf-8")
    bloque = re.search(r"fn_terminal_config_catalogo\(\).*?\$\$;", sql, re.S).group(0)
    filas = re.findall(r"\('(terminal_[a-z_]+)'(?:::text)?,\s*(\d+),\s*(\d+),\s*(\d+)\)", bloque)
    assert len(filas) == 5
    en_sql = {c: (int(d), int(mi), int(ma)) for c, d, mi, ma in filas}
    en_codigo = {c: (v.defecto, v.minimo, v.maximo) for c, v in CATALOGO_TERMINAL.items()}
    assert en_sql == en_codigo


# --- GET /{id}/usuarios ----------------------------------------------------------------------------------------------------


def _get(ruta):
    return _cliente().get(ruta, headers=AUTH)


def test_lista_altas_con_nombre_resumen_y_total(entorno):
    altas = [_alta(77, "activo"), _alta(78, "baja")]
    entorno.configurar(_tablas_lista(altas, todas=["activo", "activo", "baja"], total=2))
    r = _get("/api/terminales/1/usuarios")
    assert r.status_code == 200, r.text
    cuerpo = r.json()
    assert cuerpo["total"] == 2
    assert cuerpo["resumen"]["por_estado"] == {
        "pendiente_alta": 0, "esperando_huella": 0, "activo": 2, "pendiente_baja": 0, "baja": 1,
    }
    a = cuerpo["altas"][0]
    assert a["persona_nombre"] == "Ana Torres"
    assert a["employee_no"] == 1077 and a["huellas_capturadas"] == 2
    assert a["accion_disponible"] == "dar_de_baja"
    assert cuerpo["altas"][1]["accion_disponible"] is None


def test_la_alta_trae_el_resumen_de_consentimiento_pero_ni_texto_ni_biometria(entorno):
    entorno.configurar(_tablas_lista([_alta(77)]))
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert set(a) == {
        "id", "terminal_id", "employee_no", "persona_id", "persona_nombre", "estado", "huellas_capturadas",
        "creado_en", "actualizado_en", "usuario_creado_en", "caduca_en", "error_codigo", "error_detalle",
        "consentimiento", "consentimiento_vigente_id", "reconsentimiento_pendiente", "es_propia",
        "reconsentimiento_elegible", "reconsentimiento_razon", "accion_disponible",
    }
    assert a["consentimiento"] == {"id": 4, "version": 4, "provisional": False}  # sin texto
    assert a["consentimiento_vigente_id"] == 4 and a["reconsentimiento_pendiente"] is False


def test_caduca_en_es_usuario_creado_mas_la_variable_y_solo_en_esperando_huella(entorno):
    creada = "2026-10-08T10:00:00+00:00"
    tablas = _tablas_lista(
        [_alta(77, "esperando_huella"), _alta(78, "activo", persona=PERSONA_2), _alta(79, "pendiente_alta")],
        creadas=[
            {"terminal_usuario_id": 77, "creado_en": creada},
            {"terminal_usuario_id": 78, "creado_en": creada},
        ],
    )
    entorno.configurar(tablas, parametro=tabla([{"valor": "48"}]))
    altas = {a["id"]: a for a in _get("/api/terminales/1/usuarios").json()["altas"]}
    assert altas[77]["usuario_creado_en"] == "2026-10-08T10:00:00Z"
    assert altas[77]["caduca_en"] == "2026-10-10T10:00:00Z"  # +48 h, la variable vigente
    assert altas[78]["usuario_creado_en"] is not None and altas[78]["caduca_en"] is None  # activo no caduca
    assert altas[79]["usuario_creado_en"] is None and altas[79]["caduca_en"] is None


def test_caduca_en_usa_24h_si_la_variable_no_existe_todavia(entorno):
    tablas = _tablas_lista(
        [_alta(77, "esperando_huella")],
        creadas=[{"terminal_usuario_id": 77, "creado_en": "2026-10-08T10:00:00+00:00"}],
    )
    entorno.configurar(tablas, parametro=tabla([]))  # 89_ sin aplicar
    assert _get("/api/terminales/1/usuarios").json()["altas"][0]["caduca_en"] == "2026-10-09T10:00:00Z"


def test_sin_altas_esperando_huella_no_lee_la_variable(entorno):
    parametro = tabla([{"valor": "48"}])
    entorno.configurar(_tablas_lista([_alta(77, "activo")]), parametro=parametro)
    _get("/api/terminales/1/usuarios")
    parametro.execute.assert_not_called()


def test_usuario_creado_en_sale_de_la_columna_no_de_la_bitacora(entorno):
    from app.routers.terminales import COLUMNAS_ALTA

    tablas = _tablas_lista([_alta(77, "esperando_huella", usuario_creado_en="2026-10-08T10:00:00+00:00")])
    entorno.configurar(tablas)
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert "usuario_creado_en" in COLUMNAS_ALTA and "consentimiento_id" in COLUMNAS_ALTA
    assert a["usuario_creado_en"] == "2026-10-08T10:00:00Z"
    tablas["bitacora_movimiento_terminal_usuario"].execute.assert_not_called()


def test_reconsentimiento_pendiente_sale_de_la_funcion_unica_de_la_base(entorno):
    entorno.pendientes = [78]
    entorno.configurar(_tablas_lista([_alta(77), _alta(78)], pend=[{"id": 77, "persona_id": PERSONA}, {"id": 78, "persona_id": PERSONA}]))
    por_id = {a["id"]: a for a in _get("/api/terminales/1/usuarios").json()["altas"]}
    assert por_id[77]["reconsentimiento_pendiente"] is False and por_id[78]["reconsentimiento_pendiente"] is True


def test_el_error_del_puente_se_separa_en_codigo_y_detalle(entorno):
    entorno.configurar(
        _tablas_lista([_alta(77, "pendiente_alta", error_detalle="usuario_ya_existe: el usuario ya estaba en el aparato")])
    )
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert a["error_codigo"] == "usuario_ya_existe"
    assert a["error_detalle"] == "el usuario ya estaba en el aparato"


@pytest.mark.parametrize(
    "query",
    ["?estado=raro", "?persona_id=no-es-uuid", "?persona_id=1;drop table x", "?limite=0", "?limite=201", "?desplazamiento=-1", "?desde=ayer"],
)
def test_filtros_invalidos_dan_422_sin_consultar(entorno, query):
    tablas = _tablas_lista([_alta(77)])
    entorno.configurar(tablas)
    assert _get(f"/api/terminales/1/usuarios{query}").status_code == 422
    tablas["terminal_usuario"].execute.assert_not_called()


def test_terminal_inexistente_da_404_sin_consultar_las_altas(entorno):
    tablas = _tablas_lista([_alta(77)])
    tablas["terminal"] = tabla([])
    entorno.configurar(tablas)
    r = _get("/api/terminales/99/usuarios")
    assert r.status_code == 404
    assert r.json()["detail"] == "La terminal no existe."
    tablas["terminal_usuario"].execute.assert_not_called()


def test_sin_permiso_da_403_y_el_gate_es_lectura_o_edicion(entorno):
    entorno.configurar(_tablas_lista([_alta(77)]))
    _get("/api/terminales/1/usuarios")
    assert entorno.codigos == [("terminal_usuario_lectura", "terminal_usuario_edicion")]
    entorno.permitido = False
    assert _get("/api/terminales/1/usuarios").status_code == 403


# --- POST baja ----------------------------------------------------------------------------------------------------------


def _tablas_baja(alta_antes, alta_despues=None, error=None):
    bit = tabla([])
    if error is not None:
        bit.insert.return_value.execute.side_effect = error
    return {
        "terminal_usuario": _tabla_secuencia(alta_antes, alta_despues if alta_despues is not None else alta_antes),
        "bitacora_movimiento_terminal_usuario": bit,
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
    }


MOTIVO_OK = "Renuncia voluntaria"


def _post_baja(cuerpo, ruta="/api/terminales/1/usuarios/77/baja"):
    return _cliente().post(ruta, json=cuerpo, headers=AUTH)


def test_baja_inserta_baja_solicitada_con_el_cliente_del_caller_y_devuelve_el_alta(entorno):
    tablas = _tablas_baja([_alta(77, "activo")], [_alta(77, "pendiente_baja")])
    entorno.configurar(tablas)
    r = _post_baja({"motivo": "  Se fue\x07 de la empresa  "})
    assert r.status_code == 201, r.text
    assert r.json()["estado"] == "pendiente_baja"
    assert r.json()["accion_disponible"] is None
    carga = tablas["bitacora_movimiento_terminal_usuario"].insert.call_args.args[0]
    assert carga == {
        "terminal_usuario_id": 77, "terminal_id": 1, "persona_id": PERSONA, "tipo_movimiento": "baja_solicitada",
        "detalle": "Se fue de la empresa", "origen": "web", "registrado_por": CALLER.auth_user_id,
    }


@pytest.mark.parametrize("motivo", [None, "", "   ", "corto", "123456789", "\u200b" * 20, "  a b c d e  "])
def test_baja_sin_motivo_o_con_menos_de_10_caracteres_utiles_da_422_fijo(entorno, motivo):
    tablas = _tablas_baja([_alta(77, "esperando_huella")])
    entorno.configurar(tablas)
    r = _post_baja({} if motivo is None else {"motivo": motivo})
    assert r.status_code == 422
    assert r.json()["detail"] == "El motivo de la baja debe tener entre 10 y 500 caracteres."
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_baja_con_motivo_de_exactamente_10_caracteres_pasa(entorno):
    tablas = _tablas_baja([_alta(77, "esperando_huella")])
    entorno.configurar(tablas)
    assert _post_baja({"motivo": "1234567890"}).status_code == 201


def test_baja_de_un_alta_de_otra_terminal_es_404_y_no_inserta(entorno):
    tablas = _tablas_baja([])
    entorno.configurar(tablas)
    r = _post_baja({"motivo": MOTIVO_OK}, ruta="/api/terminales/2/usuarios/77/baja")
    assert r.status_code == 404
    assert r.json()["detail"] == "El alta no existe."
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()
    tablas["terminal_usuario"].eq.assert_any_call("terminal_id", 2)


@pytest.mark.parametrize("cuerpo", [{"motivo": "x" * 2001}, {"motivo": 5}, {"otro": "campo"}, {"estado": "baja"}])
def test_baja_con_cuerpo_invalido_da_422_sin_escribir(entorno, cuerpo):
    tablas = _tablas_baja([_alta(77)])
    entorno.configurar(tablas)
    assert _post_baja(cuerpo).status_code == 422
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_baja_con_transicion_invalida_da_409_fijo_sin_texto_crudo(entorno):
    entorno.configurar(
        _tablas_baja([_alta(77, "pendiente_baja")], error=APIError({"code": "SCJ11", "hint": "transicion_invalida", "message": CRUDO}))
    )
    r = _post_baja({"motivo": MOTIVO_OK})
    assert r.status_code == 409
    assert r.json()["detail"] == "El movimiento no es válido para el estado actual del alta."
    assert "7002" not in r.text


def test_baja_sin_permiso_de_la_base_da_403_y_error_desconocido_500_sin_texto(entorno):
    entorno.configurar(_tablas_baja([_alta(77)], error=APIError({"code": "42501", "hint": "sin_permiso", "message": CRUDO})))
    r = _post_baja({"motivo": MOTIVO_OK})
    assert r.status_code == 403 and "7002" not in r.text
    entorno.configurar(_tablas_baja([_alta(77)], error=APIError({"code": "XX999", "message": CRUDO})))
    r = _post_baja({"motivo": MOTIVO_OK})
    assert r.status_code == 500 and "7002" not in r.text


def test_baja_exige_terminal_usuario_edicion_y_sin_permiso_no_consulta(entorno):
    tablas = _tablas_baja([_alta(77)])
    entorno.configurar(tablas)
    entorno.permitido = False
    assert _post_baja({}).status_code == 403
    assert entorno.codigos == [("terminal_usuario_edicion",)]
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


# --- historial -------------------------------------------------------------------------------------------------------------


def test_historial_con_nombres_y_terminal_sin_autor(entorno):
    movs = [
        {"id": 3, "tipo_movimiento": "huella_capturada", "creado_en": "2026-10-08T10:05:00+00:00", "origen": "terminal",
         "registrado_por": None, "detalle": None, "huellas_capturadas": 1},
        {"id": 1, "tipo_movimiento": "asignado", "creado_en": "2026-10-08T09:00:00+00:00", "origen": "web",
         "registrado_por": "auth-ti", "detalle": "texto", "huellas_capturadas": None},
    ]
    tablas = {
        "terminal_usuario": tabla([_alta(77)]),
        "bitacora_movimiento_terminal_usuario": tabla(movs),
        "usuario": tabla([{"auth_user_id": "auth-ti", "nombre_usuario": "carlos.ruiz"}]),
    }
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/usuarios/77/movimientos")
    assert r.status_code == 200, r.text
    por_id = {m["id"]: m for m in r.json()}
    assert por_id[3]["registrado_por_nombre"] is None and por_id[3]["origen"] == "terminal"
    assert por_id[3]["huellas_capturadas"] == 1
    assert por_id[1]["registrado_por_nombre"] == "carlos.ruiz"
    assert set(por_id[1]) == {
        "id", "tipo_movimiento", "creado_en", "origen", "registrado_por_nombre", "detalle", "huellas_capturadas",
        "consentimiento",
    }
    assert por_id[1]["consentimiento"] is None  # el mock no trae consentimiento_id
    bit = tablas["bitacora_movimiento_terminal_usuario"]
    bit.order.assert_any_call("creado_en", desc=True)
    bit.order.assert_called_with("id", desc=True)  # orden estable
    bit.limit.assert_called_once_with(500)
    bit.eq.assert_called_with("terminal_usuario_id", 77)


def test_historial_sin_autores_no_consulta_usuarios(entorno):
    usuario = tabla([])
    tablas = {
        "terminal_usuario": tabla([_alta(77)]),
        "bitacora_movimiento_terminal_usuario": tabla([]),
        "usuario": usuario,
    }
    entorno.configurar(tablas)
    assert _get("/api/terminales/1/usuarios/77/movimientos").json() == []
    usuario.execute.assert_not_called()


def test_historial_de_un_alta_de_otra_terminal_da_404_sin_leer_la_bitacora(entorno):
    bit = tabla([])
    entorno.configurar({"terminal_usuario": tabla([]), "bitacora_movimiento_terminal_usuario": bit})
    assert _get("/api/terminales/2/usuarios/77/movimientos").status_code == 404
    bit.execute.assert_not_called()


# --- personas asignables ---------------------------------------------------------------------------------------------------


def _tablas_asignables(personas, ocupadas=(), asignaciones=(), puestos=(), departamentos=(), areas=()):
    return {
        "terminal": tabla([_terminal_fila()]),
        "terminal_usuario": tabla([{"persona_id": p} for p in ocupadas]),
        "persona": tabla(personas),
        "asignacion": tabla(list(asignaciones)),
        "puesto": tabla(list(puestos)),
        "departamento": tabla(list(departamentos)),
        "area": tabla(list(areas)),
    }


def _p(id_, nombre, ap):
    return {"id": id_, "primer_nombre": nombre, "apellido_paterno": ap, "apellido_materno": "X"}


def test_asignables_excluye_las_que_ya_tienen_alta_vigente_y_trae_puesto_y_area(entorno):
    tablas = _tablas_asignables(
        [_p(PERSONA, "Ana", "Torres"), _p(PERSONA_2, "Luis", "Ramírez")],
        ocupadas=[PERSONA],
        asignaciones=[{"persona_id": PERSONA_2, "puesto_id": "pu1", "vigente_desde": "2026-01-01"}],
        puestos=[{"id": "pu1", "nombre_puesto": "Encargado de bodega", "departamento_id": "d1"}],
        departamentos=[{"id": "d1", "area_id": "a1"}],
        areas=[{"id": "a1", "nombre_area": "Logística"}],
    )
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/personas-asignables")
    assert r.status_code == 200, r.text
    assert r.json() == [{"persona_id": PERSONA_2, "nombre": "Luis Ramírez", "puesto": "Encargado de bodega", "area": "Logística"}]
    tablas["terminal_usuario"].neq.assert_called_once_with("estado", "baja")
    tablas["terminal_usuario"].eq.assert_called_with("terminal_id", 1)
    tablas["persona"].eq.assert_any_call("estado", "activo")


def test_asignables_sin_asignacion_vigente_da_puesto_y_area_nulos(entorno):
    entorno.configurar(_tablas_asignables([_p(PERSONA, "Ana", "Torres")]))
    assert _get("/api/terminales/1/personas-asignables").json() == [
        {"persona_id": PERSONA, "nombre": "Ana Torres", "puesto": None, "area": None}
    ]


def test_asignables_con_varias_asignaciones_vigentes_gana_la_mas_reciente(entorno):
    tablas = _tablas_asignables(
        [_p(PERSONA, "Ana", "Torres")],
        asignaciones=[
            {"persona_id": PERSONA, "puesto_id": "viejo", "vigente_desde": "2024-01-01"},
            {"persona_id": PERSONA, "puesto_id": "nuevo", "vigente_desde": "2026-05-01"},
        ],
        puestos=[
            {"id": "viejo", "nombre_puesto": "Auxiliar", "departamento_id": "d1"},
            {"id": "nuevo", "nombre_puesto": "Jefa", "departamento_id": "d1"},
        ],
        departamentos=[{"id": "d1", "area_id": "a1"}],
        areas=[{"id": "a1", "nombre_area": "Ventas"}],
    )
    entorno.configurar(tablas)
    assert _get("/api/terminales/1/personas-asignables").json()[0]["puesto"] == "Jefa"
    tablas["asignacion"].is_.assert_called_with("vigente_hasta", "null")


def test_asignables_homonimos_se_distinguen_por_puesto(entorno):
    tablas = _tablas_asignables(
        [_p(PERSONA, "Ana", "Torres"), _p(PERSONA_2, "Ana", "Torres")],
        asignaciones=[
            {"persona_id": PERSONA, "puesto_id": "p1", "vigente_desde": "2026-01-01"},
            {"persona_id": PERSONA_2, "puesto_id": "p2", "vigente_desde": "2026-01-01"},
        ],
        puestos=[
            {"id": "p1", "nombre_puesto": "Cajera", "departamento_id": "d1"},
            {"id": "p2", "nombre_puesto": "Contadora", "departamento_id": "d1"},
        ],
        departamentos=[{"id": "d1", "area_id": "a1"}],
        areas=[{"id": "a1", "nombre_area": "Administración"}],
    )
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/personas-asignables").json()
    assert {x["puesto"] for x in r} == {"Cajera", "Contadora"}


def test_asignables_respeta_el_limite_aunque_haya_ocupadas(entorno):
    personas = [_p(f"id-{i}", "N", f"A{i}") for i in range(10)]
    tablas = _tablas_asignables(personas, ocupadas=["id-0", "id-1"])
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/personas-asignables?limite=3").json()
    assert [x["persona_id"] for x in r] == ["id-2", "id-3", "id-4"]
    tablas["persona"].range.assert_called_once_with(0, 99)  # una página de candidatas basta


def test_asignables_sanea_la_busqueda_antes_de_armar_el_filtro_or(entorno):
    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/personas-asignables?busqueda=An),id.eq.1,(x%25%2A")
    assert r.status_code == 200
    filtro = tablas["persona"].or_.call_args.args[0]
    for peligroso in ("),", ".eq.1", "(x", "*"):
        assert peligroso not in filtro
    assert filtro.count("ilike") == 3


@pytest.mark.parametrize("busqueda", ["a", "%", "(),", " "])
def test_asignables_busqueda_demasiado_corta_tras_sanear_da_422(entorno, busqueda):
    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    r = _get(f"/api/terminales/1/personas-asignables?busqueda={busqueda}")
    assert r.status_code == 422
    tablas["persona"].execute.assert_not_called()


def test_asignables_exige_edicion_y_terminal_existente(entorno):
    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    tablas["terminal"] = tabla([])
    entorno.configurar(tablas)
    assert _get("/api/terminales/9/personas-asignables").status_code == 404
    entorno.permitido = False
    assert _get("/api/terminales/1/personas-asignables").status_code == 403
    assert entorno.codigos[-1] == ("terminal_usuario_edicion",)


def test_asignables_limite_maximo_50(entorno):
    entorno.configurar(_tablas_asignables([]))
    assert _get("/api/terminales/1/personas-asignables?limite=51").status_code == 422


# --- GET /api/personas/{id}/terminales ---------------------------------------------------------------------------------


def test_altas_de_una_persona_con_su_terminal(entorno):
    tablas = {
        "terminal_usuario": tabla([_alta(77, "activo", terminal=1), _alta(80, "baja", terminal=2)]),
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
        "bitacora_movimiento_terminal_usuario": tabla([]),
        "terminal": tabla([_terminal_fila(1), _terminal_fila(2)]),
    }
    entorno.configurar(tablas)
    r = _get(f"/api/personas/{PERSONA}/terminales")
    assert r.status_code == 200, r.text
    cuerpo = r.json()
    assert [x["alta"]["id"] for x in cuerpo] == [77, 80]
    assert cuerpo[0]["terminal"]["id"] == 1 and cuerpo[0]["terminal"]["estado_contacto"] == "en_linea"
    assert cuerpo[1]["alta"]["estado"] == "baja"
    tablas["terminal_usuario"].eq.assert_called_with("persona_id", PERSONA)


def test_persona_sin_altas_da_lista_vacia_sin_mas_consultas(entorno):
    terminal = tabla([])
    entorno.configurar(
        {"terminal_usuario": tabla([]), "terminal": terminal, "persona": tabla([]),
         "bitacora_movimiento_terminal_usuario": tabla([])}
    )
    assert _get(f"/api/personas/{PERSONA}/terminales").json() == []
    terminal.execute.assert_not_called()


def test_altas_de_persona_exige_uuid_y_permiso_de_lectura(entorno):
    entorno.configurar(
        {"terminal_usuario": tabla([]), "terminal": tabla([]), "persona": tabla([]),
         "bitacora_movimiento_terminal_usuario": tabla([])}
    )
    assert _get("/api/personas/no-es-uuid/terminales").status_code == 422
    entorno.permitido = False
    assert _get(f"/api/personas/{PERSONA}/terminales").status_code == 403


# --- ajustes de revisión: gate antes del cliente service_role y fronteras de ids ---------------------------------


def _servicio_roto():
    raise RuntimeError("service_role no se pudo construir")


@pytest.mark.parametrize(
    "metodo,ruta,cuerpo",
    [
        ("get", "/api/terminales/1/usuarios", None),
        ("post", "/api/terminales/1/usuarios/77/baja", {}),
        ("get", f"/api/personas/{PERSONA}/terminales", None),
    ],
)
def test_sin_permiso_es_403_aunque_service_role_no_pueda_construirse(entorno, metodo, ruta, cuerpo):
    entorno.configurar(_tablas_baja([_alta(77)]) | _tablas_lista([_alta(77)]))
    app.dependency_overrides[get_service_client] = _servicio_roto
    entorno.permitido = False
    r = getattr(_cliente(), metodo)(ruta, headers=AUTH, **({"json": cuerpo} if cuerpo is not None else {}))
    assert r.status_code == 403


@pytest.mark.parametrize("ruta", [
    "/api/terminales/0/usuarios", "/api/terminales/-1/usuarios", "/api/terminales/9223372036854775808/usuarios",
    "/api/terminales/1/usuarios/0/movimientos", "/api/terminales/1/usuarios/9223372036854775808/movimientos",
    "/api/terminales/0/personas-asignables",
])
def test_fronteras_de_ids_dan_422(entorno, ruta):
    entorno.configurar(_tablas_lista([_alta(77)]))
    assert _get(ruta).status_code == 422


# --- ajustes de revisión de security (B1-B7) ----------------------------------------------------------------------


def test_listar_altas_cuenta_por_estado_con_head_sin_descargar_filas(entorno):
    tablas = _tablas_lista([_alta(77)], todas=["activo"] * 3 + ["baja"])
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/usuarios").json()
    assert r["resumen"]["por_estado"]["activo"] == 3 and r["resumen"]["por_estado"]["baja"] == 1
    tu = tablas["terminal_usuario"]
    cuentas = [c for c in tu.select.call_args_list if c.kwargs.get("head")]
    assert len(cuentas) == 5 and all(c.kwargs["count"] == "exact" for c in cuentas)
    assert {c.args[1] for c in tu.eq.call_args_list if c.args[0] == "estado"} >= {"activo", "baja"}


def test_historial_y_altas_de_persona_tienen_limite_y_orden_estable(entorno):
    tablas = {
        "terminal_usuario": tabla([_alta(77)]),
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "T"}]),
        "bitacora_movimiento_terminal_usuario": tabla([]),
        "terminal": tabla([_terminal_fila(1)]),
    }
    entorno.configurar(tablas)
    assert _get(f"/api/personas/{PERSONA}/terminales").status_code == 200
    tu = tablas["terminal_usuario"]
    tu.limit.assert_called_once_with(200)
    tu.order.assert_called_with("id", desc=True)


@pytest.mark.parametrize("caracter", [
    "\u00ad", "\u061c", "\u200b", "\u200f", "\u2028", "\u202e", "\u2060", "\u2064", "\u2066", "\u2069",
    "\ufeff", "\U000e0001", "\U000e007f",
])
def test_sanear_motivo_quita_invisibles_y_bidireccionales(caracter):
    assert sanear_motivo(f"pa{caracter}go{caracter}") == "pago"
    assert sanear_motivo(f"{caracter}{caracter}") is None


def test_asignables_no_ofrece_a_quien_llama_salvo_administrador_generico(entorno):
    propia = "persona-ficticia"  # la que devuelve resolver_persona_id en la fixture
    tablas = _tablas_asignables([_p(propia, "Yo", "Mismo"), _p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    assert [x["persona_id"] for x in _get("/api/terminales/1/personas-asignables").json()] == [PERSONA]
    entorno.admin_generico = True
    assert [x["persona_id"] for x in _get("/api/terminales/1/personas-asignables").json()] == [propia, PERSONA]


def test_asignables_ocupadas_se_consultan_solo_para_los_candidatos_de_la_pagina(entorno):
    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres"), _p(PERSONA_2, "Luis", "R")], ocupadas=[PERSONA])
    entorno.configurar(tablas)
    _get("/api/terminales/1/personas-asignables")
    tablas["terminal_usuario"].in_.assert_called_once_with("persona_id", [PERSONA, PERSONA_2])


def test_asignables_sigue_paginando_si_la_primera_pagina_es_toda_ocupada(entorno):
    """Más de una página de candidatas: si la primera se ocupa entera, pide la siguiente."""
    from app.routers import terminales as t

    pagina1 = [_p(f"o-{i}", "N", f"A{i}") for i in range(t.PAGINA_CANDIDATAS)]
    pagina2 = [_p("libre", "Lib", "Re")]
    persona = tabla([])
    persona.execute.side_effect = [Resultado(pagina1), Resultado(pagina2)]
    tu = tabla([])
    tu.execute.side_effect = [Resultado([{"persona_id": p["id"]} for p in pagina1]), Resultado([])]
    tablas = _tablas_asignables([])
    tablas["persona"], tablas["terminal_usuario"] = persona, tu
    entorno.configurar(tablas)
    r = _get("/api/terminales/1/personas-asignables").json()
    assert [x["persona_id"] for x in r] == ["libre"]
    assert [c.args for c in persona.range.call_args_list] == [(0, 99), (100, 199)]



def test_la_obligatoriedad_del_motivo_se_apaga_con_la_constante(entorno, monkeypatch):
    from app.routers import terminales as t

    assert t.MOTIVO_BAJA_OBLIGATORIO is True and t.MOTIVO_BAJA_MIN == 10
    tablas = _tablas_baja([_alta(77)])
    entorno.configurar(tablas)
    monkeypatch.setattr(t, "MOTIVO_BAJA_OBLIGATORIO", False)
    assert _post_baja({}).status_code == 201


# --- ronda de testing: pruebas que fallan si se quita un filtro --------------------------------------------------------


def _tablas_lista_con_cadenas(altas, conteos=None):
    tu = TablaConCadenas(Resultado(altas, len(altas)), *(conteos or _conteos([a["estado"] for a in altas])))
    return {
        "terminal": tabla([_terminal_fila()]),
        "terminal_usuario": tu,
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Torres"}]),
        "bitacora_movimiento_terminal_usuario": tabla([]),
    }, tu


def test_cada_consulta_de_listar_altas_lleva_su_propio_acotado(entorno):
    tablas, tu = _tablas_lista_con_cadenas([_alta(77)])
    entorno.configurar(tablas)
    r = _get(f"/api/terminales/1/usuarios?estado=activo&persona_id={PERSONA}&desde=2026-10-01&limite=10&desplazamiento=20")
    assert r.status_code == 200, r.text
    principal, *resumen = tu.cadenas
    assert principal[0][2].get("count") == "exact" and not principal[0][2].get("head")
    assert llamadas(principal, "eq") == [
        (("terminal_id", 1), {}), (("estado", "activo"), {}), (("persona_id", PERSONA), {}),
    ]
    assert llamadas(principal, "gte") == [(("creado_en", "2026-10-01"), {})]
    assert llamadas(principal, "order") == [(("creado_en",), {"desc": True}), (("id",), {"desc": True})]
    assert llamadas(principal, "range") == [((20, 29), {})]
    assert len(resumen) == 5
    for cadena, estado in zip(resumen, ("pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja")):
        assert cadena[0][2] == {"count": "exact", "head": True}
        assert llamadas(cadena, "eq") == [(("terminal_id", 1), {}), (("estado", estado), {})]


def test_sin_filtros_la_consulta_principal_solo_se_acota_por_terminal_y_pagina_100(entorno):
    tablas, tu = _tablas_lista_con_cadenas([_alta(77)])
    entorno.configurar(tablas)
    _get("/api/terminales/1/usuarios")
    principal = tu.cadenas[0]
    assert llamadas(principal, "eq") == [(("terminal_id", 1), {})]
    assert llamadas(principal, "gte") == []
    assert llamadas(principal, "range") == [((0, 99), {})]


def test_total_sin_count_cae_a_len_de_altas(entorno):
    tablas, tu = _tablas_lista_con_cadenas([])
    tu._resultados[0] = Resultado([_alta(77), _alta(78)], None)
    entorno.configurar(tablas)
    assert _get("/api/terminales/1/usuarios").json()["total"] == 2


def _valores_del_or(filtro):
    return re.findall(r"ilike\.%(.*?)%", filtro)


@pytest.mark.parametrize("entrada", ["a,b", "a%b", "a_b", 'a"b', "a\\b", "a(b)", "a.b", "a*b", "ab),id.eq.1,(cd"])
def test_busqueda_peligrosa_se_sanea_antes_del_or(entorno, entrada):
    from urllib.parse import quote

    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    r = _get(f"/api/terminales/1/personas-asignables?busqueda={quote(entrada, safe='')}")
    assert r.status_code == 200, r.text
    filtro = tablas["persona"].or_.call_args.args[0]
    valores = _valores_del_or(filtro)
    assert len(valores) == 3
    for v in valores:
        assert re.fullmatch(r"[\w\s'\-]+", v) and "_" not in v
    assert filtro.count(",") == 2 and filtro.count("(") == 0 and filtro.count(")") == 0


@pytest.mark.parametrize("entrada", ["José", "Ñandú"])
def test_busqueda_con_unicode_queda_intacta(entorno, entrada):
    from urllib.parse import quote

    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    _get(f"/api/terminales/1/personas-asignables?busqueda={quote(entrada)}")
    assert _valores_del_or(tablas["persona"].or_.call_args.args[0]) == [entrada] * 3


def test_busqueda_de_101_caracteres_da_422_y_100_pasa(entorno):
    tablas = _tablas_asignables([_p(PERSONA, "Ana", "Torres")])
    entorno.configurar(tablas)
    assert _get(f"/api/terminales/1/personas-asignables?busqueda={'a' * 101}").status_code == 422
    assert _get(f"/api/terminales/1/personas-asignables?busqueda={'a' * 100}").status_code == 200


def test_altas_de_persona_gate_y_terminal_que_no_devuelve_la_consulta(entorno):
    tablas = {
        "terminal_usuario": tabla([_alta(77, terminal=1), _alta(80, terminal=2)]),
        "persona": tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "T"}]),
        "bitacora_movimiento_terminal_usuario": tabla([]),
        "terminal": tabla([_terminal_fila(1)]),  # la terminal 2 no es visible para el caller
    }
    entorno.configurar(tablas)
    r = _get(f"/api/personas/{PERSONA}/terminales")
    assert r.status_code == 200
    assert [x["alta"]["id"] for x in r.json()] == [77]
    assert entorno.codigos == [("terminal_usuario_lectura", "terminal_usuario_edicion")]


def test_esperando_huella_sin_usuario_creado_en_la_bitacora_no_tiene_caduca_en(entorno):
    entorno.configurar(_tablas_lista([_alta(77, "esperando_huella")], creadas=[]), parametro=tabla([{"valor": "48"}]))
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert a["usuario_creado_en"] is None and a["caduca_en"] is None


def test_error_detalle_se_devuelve_literal_como_texto_plano(entorno):
    crudo = "x_y: <script>alert(1)</script> & más"
    entorno.configurar(_tablas_lista([_alta(77, "pendiente_alta", error_detalle=f"codigo_x: {crudo}")]))
    a = _get("/api/terminales/1/usuarios").json()["altas"][0]
    assert a["error_codigo"] == "codigo_x" and a["error_detalle"] == crudo


@pytest.mark.parametrize("valor,esperado", [("4", 4), ("168", 168), ("3", 24), ("169", 24)])
def test_valor_vigente_fronteras_del_rango(valor, esperado):
    assert valor_vigente(db_por_nombre(parametro=tabla([{"valor": valor}])), "terminal_caducidad_alta_horas") == esperado


def test_valor_vigente_filtra_la_vigencia_abierta_y_la_clave():
    t = TablaConCadenas([{"valor": "48"}])
    servicio = db_por_nombre(parametro=t)
    assert valor_vigente(servicio, "terminal_caducidad_alta_horas") == 48
    cadena = t.cadenas[0]
    assert llamadas(cadena, "eq") == [(("clave", "terminal_caducidad_alta_horas"), {})]
    assert llamadas(cadena, "is_") == [(("vigente_hasta", "null"), {})]


def _ddl_80_a_88():
    from pathlib import Path

    ddl = Path(__file__).resolve().parents[2] / "db" / "ddl"
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(ddl.glob("8[0-8]_*.sql")))


def _cuerpo_tabla(sql, nombre):
    m = re.search(rf"CREATE TABLE tiempo\.{nombre}\s*\((.*?)\n\);", sql, re.S)
    assert m, nombre
    return m.group(1)


def test_columnas_de_altas_y_bitacora_existen_en_el_ddl():
    from app.routers.terminales import COLUMNAS_ALTA

    sql = _ddl_80_a_88()
    tu = _cuerpo_tabla(sql, "terminal_usuario")
    agregadas = set(re.findall(r"ALTER TABLE tiempo\.terminal_usuario\s+ADD COLUMN\s+([a-z_]+)", sql))
    for col in (c.strip() for c in COLUMNAS_ALTA.split(",")):
        assert re.search(rf"^\s+{col}\s", tu, re.M) or col in agregadas, f"terminal_usuario.{col}"
    bit = _cuerpo_tabla(sql, "bitacora_movimiento_terminal_usuario")
    agregadas_bit = set(re.findall(r"ALTER TABLE tiempo\.bitacora_movimiento_terminal_usuario\s+ADD COLUMN\s+([a-z_]+)", sql))
    for col in ("id", "tipo_movimiento", "creado_en", "origen", "registrado_por", "detalle", "huellas_capturadas",
                "terminal_usuario_id", "consentimiento_id"):
        assert re.search(rf"^\s+{col}\s", bit, re.M) or col in agregadas_bit, f"bitacora.{col}"


def test_tipos_y_origenes_de_movimiento_que_usa_el_backend_existen_en_el_ddl():
    sql = _ddl_80_a_88()
    tipos = re.search(r"ck_bitacora_terminal_usuario_tipo CHECK \(\s*tipo_movimiento IN \((.*?)\)\s*\)", sql, re.S).group(1)
    assert {"baja_solicitada", "usuario_creado"} <= set(re.findall(r"'([a-z_]+)'", tipos))
    origenes = re.search(r"ck_bitacora_terminal_usuario_origen CHECK \(origen IN \((.*?)\)\)", sql).group(1)
    assert set(re.findall(r"'([a-z]+)'", origenes)) == {"web", "terminal"}
    assert "tipo_movimiento IN ('asignado', 'baja_solicitada')" in sql


def test_baja_con_motivo_de_501_caracteres_utiles_da_422_fijo(entorno):
    tablas = _tablas_baja([_alta(77, "activo")])
    entorno.configurar(tablas)
    r = _post_baja({"motivo": "x" * 501})
    assert r.status_code == 422 and r.json()["detail"] == "El motivo de la baja debe tener entre 10 y 500 caracteres."
    tablas["bitacora_movimiento_terminal_usuario"].insert.assert_not_called()


def test_baja_con_500_utiles_mas_relleno_pasa(entorno):
    """Los espacios sobrantes no cuentan: se mide tras sanear."""
    entorno.configurar(_tablas_baja([_alta(77, "activo")]))
    assert _post_baja({"motivo": "  " + "y" * 500 + "   "}).status_code == 201


def test_asignables_persona_repetida_entre_paginas_aparece_una_sola_vez(entorno):
    """Si el orden cambia entre páginas (altas/bajas concurrentes), una persona puede venir en dos páginas."""
    from app.routers import terminales as t

    pagina1 = [_p("dup", "Du", "Plicada")] + [_p(f"o-{i}", "N", f"A{i}") for i in range(t.PAGINA_CANDIDATAS - 1)]
    pagina2 = [_p("dup", "Du", "Plicada"), _p("otra", "Otra", "Persona")]
    persona = tabla([])
    persona.execute.side_effect = [Resultado(pagina1), Resultado(pagina2)]
    tu = tabla([])
    ocupadas = [{"persona_id": p["id"]} for p in pagina1 if p["id"] != "dup"]
    tu.execute.side_effect = [Resultado(ocupadas), Resultado([])]
    tablas = _tablas_asignables([])
    tablas["persona"], tablas["terminal_usuario"] = persona, tu
    entorno.configurar(tablas)
    ids = [x["persona_id"] for x in _get("/api/terminales/1/personas-asignables").json()]
    assert ids == ["dup", "otra"]
