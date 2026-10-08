"""86_*.sql, datos para la UI y mapeo de SCJ15 en los routers que lo pueden recibir. Mocks del
cliente de Supabase -- NUNCA contra la base real."""

from datetime import datetime
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers import correcciones

CALLER = CallerIdentity(auth_user_id="auth-ficticio", correo="x@example.com")
AUTH = {"Authorization": "Bearer fake-token"}
PERSONA = "aaaaaaaa-0000-0000-0000-000000000001"
CRUDO = "texto-crudo-id-interno-3377"


class _Resultado:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


def _tabla(datos, count=None):
    """Constructor fluido: cualquier método encadenable devuelve el mismo objeto; sólo execute() corta."""
    t = MagicMock()
    for metodo in ("select", "eq", "like", "in_", "gte", "lte", "order", "range", "is_", "ilike", "or_"):
        getattr(t, metodo).return_value = t
    t.execute.return_value = _Resultado(datos, count)
    return t


def _db(**tablas):
    db = MagicMock()
    db.postgrest.schema.return_value.table.side_effect = lambda nombre: tablas.get(nombre, _tabla([]))
    return db


@pytest.fixture(autouse=True)
def _servicio_sin_tramos_por_defecto():
    """GET /api/marcas y POST /api/correcciones consultan tiempo.tramo con el cliente service_role
    (Depends(get_service_client)): sin override llegarían a Supabase real. Por defecto, sin tramos."""
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=_tabla([]))
    yield


@pytest.fixture
def permitir(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-gate")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona_id, *codigos: True)
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona_id, codigo: True)


def _cliente(db):
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    return TestClient(app, raise_server_exceptions=False)


# --- GET /api/marcas: correccion_bloqueada_por_dia_cerrado ----------------------------------------------------


def _marca(id_, **extra):
    base = {
        "id": id_,
        "evento_id": f"00000000-0000-0000-0000-{id_:012d}",
        "persona_id": PERSONA,
        "terminal_id": "T-1",
        "secuencia_local": id_,
        "momento_dispositivo": "2026-10-06T15:00:00+00:00",
        "momento_recepcion": "2026-10-07T15:00:00+00:00",
        "desfase_local": "-06:00",
        "estado_reloj": "sincronizado",
        "version_software": "1.0.0",
        "origen": "terminal",
        "requiere_revision": True,
    }
    base.update(extra)
    return base


def _exc(id_, marca_id, motivo, estado="pendiente"):
    return {"id": id_, "marca_id": marca_id, "motivo_revision": motivo, "estado": estado}


def _listar_marcas(permitir, marcas, excepciones):
    db = _db(
        marca=_tabla(marcas, count=len(marcas)),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=_tabla(excepciones),
        correccion=_tabla([]),
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.status_code == 200, r.text
    return {m["id"]: m for m in r.json()["marcas"]}


def test_marca_con_dia_cerrado_pendiente_queda_bloqueada_para_corregir(permitir):
    marcas = _listar_marcas(permitir, [_marca(1)], [_exc(10, 1, "dia_cerrado")])
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is True
    assert marcas[1]["excepcion_dia_cerrado_pendiente_id"] == 10


def test_marca_con_dos_pendientes_una_dia_cerrado_sigue_bloqueada_y_apunta_a_la_dia_cerrado(permitir):
    """La corrección resolvería ambas en un UPDATE y la de dia_cerrado lo impide."""
    marcas = _listar_marcas(
        permitir,
        [_marca(1)],
        [_exc(10, 1, "reloj_no_sincronizado"), _exc(11, 1, "dia_cerrado")],
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is True
    assert marcas[1]["excepcion_dia_cerrado_pendiente_id"] == 11
    assert marcas[1]["excepcion_pendiente_id"] == 10  # lo que ya exponía no cambia


def test_marca_con_otros_motivos_pendientes_no_se_bloquea(permitir):
    marcas = _listar_marcas(
        permitir,
        [_marca(1)],
        [_exc(10, 1, "reloj_no_sincronizado"), _exc(11, 1, "fuera_de_horario")],
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is False
    assert marcas[1]["excepcion_dia_cerrado_pendiente_id"] is None


def test_dia_cerrado_ya_resuelta_no_bloquea(permitir):
    marcas = _listar_marcas(
        permitir,
        [_marca(1)],
        [_exc(10, 1, "dia_cerrado — descartada por abc: duplicada", estado="resuelto")],
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is False


def test_dia_cerrado_reabierta_con_sufijo_pendiente_bloquea_por_prefijo(permitir):
    marcas = _listar_marcas(
        permitir, [_marca(1)], [_exc(10, 1, "dia_cerrado — resuelto por ausencia 3")]
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is True


def test_marca_sin_revision_no_se_bloquea_y_no_consulta_excepciones(permitir):
    excepcion = _tabla([_exc(10, 1, "dia_cerrado")])
    db = _db(
        marca=_tabla([_marca(1, requiere_revision=False)], count=1),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=excepcion,
        correccion=_tabla([]),
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    marca = r.json()["marcas"][0]
    assert marca["correccion_bloqueada_por_dia_cerrado"] is False
    assert marca["excepcion_dia_cerrado_pendiente_id"] is None
    excepcion.execute.assert_not_called()


def test_el_bloqueo_se_calcula_por_marca(permitir):
    marcas = _listar_marcas(
        permitir,
        [_marca(1), _marca(2)],
        [_exc(10, 1, "dia_cerrado"), _exc(12, 2, "fuera_de_horario")],
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is True
    assert marcas[2]["correccion_bloqueada_por_dia_cerrado"] is False


# --- GET /api/excepciones: estado del día y camino de resolución ---------------------------------------------


def _fila_exc(id_, marca_id, motivo, estado="pendiente"):
    return {
        "id": id_,
        "marca_id": marca_id,
        "dia_id": None,
        "motivo_revision": motivo,
        "estado": estado,
        "creado_en": "2026-10-07T10:00:00+00:00",
    }


def _listar_excepciones(permitir, filas, dias, correcciones=(), marcas=None, query=""):
    resultado, tabla_exc, _ = _listar_excepciones_completo(permitir, filas, dias, correcciones, marcas, query)
    return resultado, tabla_exc


def _listar_excepciones_completo(permitir, filas, dias, correcciones=(), marcas=None, query=""):
    """Igual que _listar_excepciones pero también devuelve las tablas, para fijar los argumentos."""
    marcas = marcas or [
        {
            "id": f["marca_id"],
            "persona_id": PERSONA,
            "momento_dispositivo": "2026-10-06T15:00:00+00:00",
            "desfase_local": "-06:00",
        }
        for f in filas
        if f["marca_id"]
    ]
    tabla_exc = _tabla(filas)
    db_tablas = {
        "marca": _tabla(marcas),
        "persona": _tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        "correccion": _tabla(list(correcciones)),
        "dia": _tabla(dias),
    }
    db = _db(excepcion=tabla_exc, **db_tablas)
    r = _cliente(db).get(f"/api/excepciones{query}", headers=AUTH)
    assert r.status_code == 200, r.text
    tablas = {"excepcion": tabla_exc, "marca": db_tablas["marca"], "persona": db_tablas["persona"], "correccion": db_tablas["correccion"], "dia": db_tablas["dia"]}
    return {x["id"]: x for x in r.json()}, tabla_exc, tablas


def test_dia_cerrado_con_dia_bloqueado_o_cerrado_se_resuelve_revisando_el_dia(permitir):
    for estado in ("bloqueado", "cerrado"):
        filas, _ = _listar_excepciones(
            permitir,
            [_fila_exc(10, 1, "dia_cerrado")],
            [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": estado}],
        )
        assert filas[10]["es_dia_cerrado"] is True
        assert filas[10]["dia_de_la_marca_id"] == 5
        assert filas[10]["dia_de_la_marca_estado"] == estado
        assert filas[10]["camino_resolucion"] == "revisar_dia"


def test_dia_cerrado_con_dia_revisado_se_resuelve_descartando_la_marca(permitir):
    filas, _ = _listar_excepciones(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "revisado"}],
    )
    assert filas[10]["dia_de_la_marca_estado"] == "revisado"
    assert filas[10]["camino_resolucion"] == "descartar"


def test_el_dia_se_busca_por_fecha_local_efectiva_con_la_correccion_mas_reciente(permitir):
    """La marca (15:00Z, -06:00) caería el 2026-10-06 sin corrección. Hay DOS correcciones, ordenadas por
    creado_en descendente: la primera (la MÁS RECIENTE) la lleva a 03:00Z del 06, que con -06:00 es las
    21:00 del 05 -> el día es el 05 (bloqueado). Si se usara la otra (20:00Z del 06 = 14:00 local del 06)
    o ninguna, el día sería el 06 (revisado)."""
    dias = [
        {"id": 6, "persona_id": PERSONA, "fecha": "2026-10-05", "estado": "bloqueado"},
        {"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "revisado"},
    ]
    corrs = [  # order desc por creado_en: la primera es la más reciente
        {"marca_id": 1, "valor_corregido": "2026-10-06T03:00:00+00:00", "creado_en": "2026-10-07T09:00:00Z"},
        {"marca_id": 1, "valor_corregido": "2026-10-06T20:00:00+00:00", "creado_en": "2026-10-07T08:00:00Z"},
    ]
    filas, _, tablas = _listar_excepciones_completo(
        permitir, [_fila_exc(10, 1, "dia_cerrado")], dias, corrs
    )
    # el orden pedido a PostgREST es creado_en DESCENDENTE: sin él "la primera" no sería la más reciente
    tablas["correccion"].order.assert_called_with("creado_en", desc=True)
    tablas["correccion"].in_.assert_called_with("marca_id", [1])
    # 03:00Z del 06 -06:00 = 21:00 del 05 -> día 05 (bloqueado), no el 06
    assert filas[10]["dia_de_la_marca_id"] == 6
    assert filas[10]["camino_resolucion"] == "revisar_dia"


def test_dia_cerrado_sin_dia_o_con_dia_abierto_no_ofrece_camino(permitir):
    filas, _ = _listar_excepciones(permitir, [_fila_exc(10, 1, "dia_cerrado")], [])
    assert filas[10]["camino_resolucion"] is None
    assert filas[10]["dia_de_la_marca_estado"] is None
    filas, _ = _listar_excepciones(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "abierto"}],
    )
    assert filas[10]["camino_resolucion"] is None


def test_otras_excepciones_no_son_dia_cerrado_ni_consultan_dias(permitir):
    tabla_dia = _tabla([])
    tabla_corr = _tabla([])
    db = _db(
        excepcion=_tabla([_fila_exc(10, 1, "reloj_no_sincronizado")]),
        marca=_tabla([{"id": 1, "persona_id": PERSONA, "momento_dispositivo": "2026-10-06T15:00:00+00:00", "desfase_local": "-06:00"}]),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        correccion=tabla_corr,
        dia=tabla_dia,
    )
    r = _cliente(db).get("/api/excepciones", headers=AUTH)
    fila = r.json()[0]
    assert fila["es_dia_cerrado"] is False
    assert fila["camino_resolucion"] is None
    tabla_dia.execute.assert_not_called()
    tabla_corr.execute.assert_not_called()


def test_una_dia_cerrado_ya_resuelta_no_ofrece_camino(permitir):
    filas, _ = _listar_excepciones(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado — descartada por x: y", estado="resuelto")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "revisado"}],
    )
    assert filas[10]["es_dia_cerrado"] is True
    assert filas[10]["camino_resolucion"] is None


def test_el_filtro_tipo_dia_cerrado_filtra_en_la_consulta_por_prefijo_sin_escape(permitir):
    filas, tabla_exc = _listar_excepciones(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "bloqueado"}],
        query="?tipo=dia_cerrado",
    )
    tabla_exc.like.assert_called_once_with("motivo_revision", "dia_cerrado%")
    tabla_exc.eq.assert_called_with("estado", "pendiente")
    assert filas[10]["camino_resolucion"] == "revisar_dia"


def test_sin_filtro_no_se_aplica_like(permitir):
    _, tabla_exc = _listar_excepciones(permitir, [_fila_exc(10, 1, "reloj_no_sincronizado")], [])
    tabla_exc.like.assert_not_called()


def test_tipo_desconocido_da_422(permitir):
    db = _db(excepcion=_tabla([]))
    r = _cliente(db).get("/api/excepciones?tipo=otra_cosa", headers=AUTH)
    assert r.status_code == 422


# --- /api/sesion: puede_descartar_excepciones ---------------------------------------------------------------


@pytest.mark.parametrize("tiene,esperado", [(True, True), (False, False)])
def test_sesion_expone_si_puede_descartar_excepciones(monkeypatch, tiene, esperado):
    from app.routers import sesion

    consultados = []

    def tiene_permiso(db, persona_id, codigo):
        consultados.append(codigo)
        return tiene if codigo == "excepcion_dia_cerrado_descarte" else False

    monkeypatch.setattr(sesion, "tiene_permiso", tiene_permiso)
    db = _db(
        usuario=_tabla([{"auth_user_id": "a", "nombre_usuario": "ana", "persona_id": PERSONA}]),
        persona=_tabla([{"estado": "activo"}]),
    )
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app).get("/api/sesion", headers=AUTH)
    assert r.status_code == 200
    assert r.json()["puede_descartar_excepciones"] is esperado
    assert "excepcion_dia_cerrado_descarte" in consultados


def test_sesion_de_cuenta_bloqueada_no_puede_descartar(monkeypatch):
    from app.routers import sesion

    monkeypatch.setattr(sesion, "tiene_permiso", lambda *a: True)
    db = _db(
        usuario=_tabla([{"auth_user_id": "a", "nombre_usuario": "ana", "persona_id": PERSONA}]),
        persona=_tabla([{"estado": "suspension"}]),
    )
    app.dependency_overrides[get_service_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app).get("/api/sesion", headers=AUTH)
    assert r.json()["acceso_permitido"] is False
    assert r.json()["puede_descartar_excepciones"] is False


# --- SCJ15 en los routers que lo pueden recibir ---------------------------------------------------------------


def _scj15(hint):
    return APIError({"code": "SCJ15", "hint": hint, "message": CRUDO})


def test_correccion_sobre_marca_de_dia_cerrado_falla_al_commit_con_409_y_mensaje_fijo(monkeypatch):
    """El constraint trigger diferido dispara al COMMIT; PostgREST lo devuelve como la respuesta de la
    petición completa y supabase-py lo levanta como APIError(code=SCJ15) en .execute() del INSERT."""
    monkeypatch.setattr(correcciones, "_buscar_marca", lambda db, marca_id: {"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"})
    monkeypatch.setattr(
        correcciones,
        "_excepciones_de_marca",
        lambda db, marca_id: [{"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"}],
    )
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda db, persona_id, codigo: True)
    monkeypatch.setattr(correcciones, "_validar_ventana", lambda fecha: None)
    tabla = _tabla([])
    tabla.insert.return_value.execute.side_effect = _scj15("dia_cerrado_requiere_revision")
    db = _db(correccion=tabla)
    r = _cliente(db).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )
    assert r.status_code == 409
    assert r.json()["detail"].startswith("Esta marca es de un día ya cerrado")
    assert "3377" not in r.text


def test_correccion_con_otro_error_de_base_conserva_su_comportamiento(monkeypatch):
    monkeypatch.setattr(correcciones, "_buscar_marca", lambda db, marca_id: {"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"})
    monkeypatch.setattr(
        correcciones,
        "_excepciones_de_marca",
        lambda db, marca_id: [{"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"}],
    )
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda db, persona_id, codigo: True)
    monkeypatch.setattr(correcciones, "_validar_ventana", lambda fecha: None)
    tabla = _tabla([])
    tabla.insert.return_value.execute.side_effect = APIError(
        {"code": "P0001", "message": "La corrección rompería el orden cronológico de las marcas"}
    )
    db = _db(correccion=tabla)
    r = _cliente(db).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )
    assert r.status_code == 422
    assert r.json()["detail"] == correcciones.MENSAJE_ORDEN_CRONOLOGICO


@pytest.mark.parametrize(
    "hint,estado",
    [("tramo_incoherente", 422), ("dia_cerrado_requiere_revision", 409), ("excepcion_motivo_inmutable", 409)],
)
def test_revisar_dia_traduce_scj15_sin_texto_crudo(permitir, hint, estado):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = _scj15(hint)
    r = _cliente(db).post("/api/dias/5/revisar", json={"horas_totales": 8}, headers=AUTH)
    assert r.status_code == estado
    assert "3377" not in r.text


def test_resolver_ausencia_traduce_scj15_sin_texto_crudo(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = _scj15(
        "excepcion_motivo_inmutable"
    )
    r = _cliente(db).post(
        "/api/ausencias/9/resolver", json={"decision": "autorizada", "tipo_de_ausencia": "vacaciones"}, headers=AUTH
    )
    assert r.status_code == 409
    assert "3377" not in r.text


# ======================================================================================================
# Opción A: corrección sobre una marca que YA está en un tramo cerrado / día cerrado o revisado
# ======================================================================================================

MENSAJE_DIA_YA_CERRADO = "Este día ya está cerrado: la corrección no se refleja en las horas. Revisa el día."


def _tramo(apertura, cierre, dia_estado):
    return {
        "marca_apertura_id": apertura,
        "marca_cierre_id": cierre,
        "dia": {"estado": dia_estado},
    }


def _preparar_correccion(monkeypatch, tramos, insert_error=None):
    monkeypatch.setattr(correcciones, "_buscar_marca", lambda db, marca_id: {"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"})
    monkeypatch.setattr(
        correcciones,
        "_excepciones_de_marca",
        lambda db, marca_id: [{"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"}],
    )
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda db, persona_id, codigo: True)
    monkeypatch.setattr(correcciones, "_validar_ventana", lambda fecha: None)
    tabla_tramo = _tabla(tramos)
    tabla_corr = _tabla([])
    if insert_error is not None:
        tabla_corr.insert.return_value.execute.side_effect = insert_error
    else:
        tabla_corr.insert.return_value.execute.return_value = _Resultado(
            [
                {
                    "id": 1,
                    "marca_id": 1,
                    "valor_corregido": "2026-10-06T16:00:00+00:00",
                    "motivo": "x",
                    "autor_id": PERSONA,
                    "creado_en": "2026-10-07T10:00:00+00:00",
                }
            ]
        )
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=tabla_tramo)
    db = _db(correccion=tabla_corr)
    db.tabla_tramo = tabla_tramo
    return db, tabla_corr


def _corregir(db):
    return _cliente(db).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )


@pytest.mark.parametrize(
    "tramo",
    [
        _tramo(1, 2, "cerrado"),  # apertura de un tramo de un día cerrado
        _tramo(0, 1, "cerrado"),  # cierre
        _tramo(1, 2, "revisado"),
        _tramo(1, 2, "bloqueado"),  # el tramo ya está cerrado (tiene marca_cierre): el UPDATE afecta 0 filas
        _tramo(1, None, "cerrado"),  # tramo abierto, pero el día está cerrado
        _tramo(1, None, "revisado"),
    ],
)
def test_corregir_una_marca_en_tramo_cerrado_o_dia_cerrado_da_409_sin_insertar(monkeypatch, tramo):
    db, tabla_corr = _preparar_correccion(monkeypatch, [tramo])
    r = _corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_DIA_YA_CERRADO
    tabla_corr.insert.assert_not_called()


@pytest.mark.parametrize(
    "tramos",
    [
        [],  # no está en ningún tramo (día abierto/bloqueado sin tramos armados)
        [_tramo(7, 8, "cerrado")],  # un tramo cerrado, pero de OTRAS marcas
        [_tramo(7, None, "bloqueado")],  # un tramo abierto, pero de otra marca
    ],
)
def test_corregir_una_marca_que_no_esta_en_ningun_tramo_sigue_como_siempre(monkeypatch, tramos):
    db, tabla_corr = _preparar_correccion(monkeypatch, tramos)
    r = _corregir(db)
    assert r.status_code == 201, r.text
    tabla_corr.insert.assert_called_once()


def test_la_consulta_previa_es_de_lectura_sobre_tramo_con_el_estado_del_dia_embebido(monkeypatch):
    db, _ = _preparar_correccion(monkeypatch, [])
    _corregir(db)
    tramo = db.tabla_tramo
    tramo.select.assert_called_with("marca_apertura_id, marca_cierre_id, dia:dia_id!inner(estado)")
    tramo.or_.assert_called_with("marca_apertura_id.in.(1),marca_cierre_id.in.(1)")


def test_el_dia_embebido_como_lista_tambien_se_entiende():
    from app.marca_en_tramo import bloqueo_por_tramo

    db = _db(tramo=_tabla([{"marca_apertura_id": 1, "marca_cierre_id": None, "dia": [{"estado": "revisado"}]}]))
    assert bloqueo_por_tramo(db, [1]) == {1: "en_tramo_cerrado"}


def test_sin_marcas_no_se_consulta_nada():
    from app.marca_en_tramo import bloqueo_por_tramo

    db = _db()
    assert bloqueo_por_tramo(db, []) == {}
    db.postgrest.schema.assert_not_called()


def test_una_sola_consulta_para_muchas_marcas_y_devuelve_las_dos_puntas_del_tramo():
    from app.marca_en_tramo import bloqueo_por_tramo

    tramo = _tabla([_tramo(1, 2, "cerrado"), _tramo(3, None, "bloqueado")])
    db = _db(tramo=tramo)
    assert bloqueo_por_tramo(db, [3, 1, 2, 9]) == {1: "en_tramo_cerrado", 2: "en_tramo_cerrado", 3: "en_tramo"}
    assert tramo.execute.call_count == 1


# --- fallthrough previo: mensaje fijo y log, nunca el texto de la base --------------------------------------


@pytest.mark.parametrize("code", ["P0001", "XX999", "", None, "500"])
def test_un_error_desconocido_de_la_base_en_correcciones_da_422_fijo_y_log(monkeypatch, caplog, code):
    import logging

    error = APIError({"code": code, "message": f"{CRUDO} con id interno 3377"})
    db, _ = _preparar_correccion(monkeypatch, [], insert_error=error)
    with caplog.at_level(logging.ERROR):
        r = _corregir(db)
    assert r.status_code == 422
    assert r.json()["detail"] == "No se pudo registrar la corrección."
    assert "3377" not in r.text and "texto-crudo" not in r.text
    assert any("corrección rechazada por la base" in x.getMessage() for x in caplog.records)


def test_un_error_diferido_con_otro_codigo_sigue_siendo_seguro(monkeypatch):
    """Si el SCJ15 del COMMIT llegara con un código distinto, el resultado es el mensaje fijo."""
    error = APIError({"code": "PGRST999", "message": f"commit falló: {CRUDO}"})
    db, _ = _preparar_correccion(monkeypatch, [], insert_error=error)
    r = _corregir(db)
    assert r.status_code == 422
    assert "texto-crudo" not in r.text


# --- GET /api/marcas: correccion_bloqueada_en_tramo_cerrado y motivo_bloqueo_correccion ---------------------


def _listar_marcas_con_tramos(permitir, marcas, excepciones, tramos):
    tramo = _tabla(tramos)
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=tramo)  # service_role
    db = _db(
        marca=_tabla(marcas, count=len(marcas)),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=_tabla(excepciones),
        correccion=_tabla([]),
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.status_code == 200, r.text
    return {m["id"]: m for m in r.json()["marcas"]}, tramo


def test_marca_en_tramo_cerrado_se_bloquea_con_motivo_en_tramo_cerrado(permitir):
    marcas, _ = _listar_marcas_con_tramos(
        permitir, [_marca(1, requiere_revision=False)], [], [_tramo(1, 2, "cerrado")]
    )
    assert marcas[1]["correccion_bloqueada_en_tramo_cerrado"] is True
    assert marcas[1]["motivo_bloqueo_correccion"] == "en_tramo_cerrado"
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is False


def test_dia_cerrado_pendiente_manda_sobre_tramo_cerrado_en_el_motivo(permitir):
    marcas, _ = _listar_marcas_con_tramos(
        permitir, [_marca(1)], [_exc(10, 1, "dia_cerrado")], [_tramo(1, 2, "revisado")]
    )
    assert marcas[1]["correccion_bloqueada_por_dia_cerrado"] is True
    assert marcas[1]["correccion_bloqueada_en_tramo_cerrado"] is True
    assert marcas[1]["motivo_bloqueo_correccion"] == "dia_cerrado_pendiente"


def test_marca_en_tramo_abierto_se_bloquea_con_motivo_en_tramo(permitir):
    marcas, _ = _listar_marcas_con_tramos(
        permitir, [_marca(1, requiere_revision=False)], [], [_tramo(1, None, "bloqueado")]
    )
    assert marcas[1]["motivo_bloqueo_correccion"] == "en_tramo"
    assert marcas[1]["correccion_bloqueada_en_tramo_cerrado"] is False


def test_marca_sin_tramo_no_tiene_motivo_de_bloqueo(permitir):
    marcas, _ = _listar_marcas_con_tramos(
        permitir, [_marca(1, requiere_revision=False)], [], [_tramo(7, 8, "cerrado")]
    )
    assert marcas[1]["motivo_bloqueo_correccion"] is None
    assert marcas[1]["correccion_bloqueada_en_tramo_cerrado"] is False


def test_una_sola_consulta_a_tramo_por_pagina_de_marcas(permitir):
    marcas, tramo = _listar_marcas_con_tramos(
        permitir,
        [_marca(1, requiere_revision=False), _marca(2, requiere_revision=False), _marca(3, requiere_revision=False)],
        [],
        [_tramo(1, 2, "cerrado")],
    )
    assert tramo.execute.call_count == 1
    assert marcas[1]["motivo_bloqueo_correccion"] == "en_tramo_cerrado"
    assert marcas[2]["motivo_bloqueo_correccion"] == "en_tramo_cerrado"
    assert marcas[3]["motivo_bloqueo_correccion"] is None


def test_pagina_vacia_no_consulta_tramos(permitir):
    tramo = _tabla([])
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=tramo)
    db = _db(marca=_tabla([], count=0))
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.status_code == 200
    tramo.execute.assert_not_called()


# --- ensayo de db: tramo ABIERTO (la base lo rechaza con 42501) y 42501 real de permisos ---------------------

MENSAJE_MARCA_EN_TRAMO = (
    "Esta marca ya forma parte de un tramo: no se puede corregir su hora desde aquí. Revisa el día."
)


@pytest.mark.parametrize(
    "tramo",
    [
        _tramo(1, None, "bloqueado"),  # día bloqueado con una sola marca (el caso del ensayo)
        _tramo(1, None, "abierto"),
        _tramo(0, 1, "bloqueado") | {"marca_cierre_id": None, "marca_apertura_id": 1},
    ],
)
def test_corregir_una_marca_de_un_tramo_abierto_da_409_claro_sin_insertar(monkeypatch, tramo):
    db, tabla_corr = _preparar_correccion(monkeypatch, [tramo])
    r = _corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_MARCA_EN_TRAMO
    tabla_corr.insert.assert_not_called()


def test_el_tramo_cerrado_o_dia_cerrado_conserva_su_mensaje(monkeypatch):
    db, tabla_corr = _preparar_correccion(monkeypatch, [_tramo(1, 2, "bloqueado")])
    r = _corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_DIA_YA_CERRADO
    tabla_corr.insert.assert_not_called()


def test_una_marca_sin_tramo_se_corrige_como_siempre(monkeypatch):
    db, tabla_corr = _preparar_correccion(monkeypatch, [])
    assert _corregir(db).status_code == 201
    tabla_corr.insert.assert_called_once()


def test_un_42501_real_de_permisos_sigue_siendo_403_con_error_en_el_log(monkeypatch, caplog):
    """El guard ya intercepta el tramo abierto; un 42501 sin hint que llegue igual (RLS real de
    correccion) sigue siendo 'sin permiso' y deja un ERROR: es una policy, no un usuario sin permiso."""
    import logging

    error = APIError({"code": "42501", "message": f"new row violates row-level security policy {CRUDO}"})
    db, _ = _preparar_correccion(monkeypatch, [], insert_error=error)
    with caplog.at_level(logging.ERROR):
        r = _corregir(db)
    assert r.status_code == 403
    assert "texto-crudo" not in r.text
    assert any(x.levelno >= logging.ERROR for x in caplog.records)


def test_el_motivo_prioriza_dia_cerrado_pendiente_luego_tramo_cerrado_luego_tramo(permitir):
    marcas, _ = _listar_marcas_con_tramos(
        permitir,
        [_marca(1), _marca(2, requiere_revision=False), _marca(3, requiere_revision=False)],
        [_exc(10, 1, "dia_cerrado")],
        [_tramo(1, None, "bloqueado"), _tramo(2, 5, "cerrado"), _tramo(3, None, "bloqueado")],
    )
    assert marcas[1]["motivo_bloqueo_correccion"] == "dia_cerrado_pendiente"  # aun en tramo abierto
    assert marcas[2]["motivo_bloqueo_correccion"] == "en_tramo_cerrado"
    assert marcas[3]["motivo_bloqueo_correccion"] == "en_tramo"


# ======================================================================================================
# Revisión de security del backend del 86_
# ======================================================================================================


def test_m1_la_consulta_de_tramos_usa_service_role_aunque_el_caller_no_pueda_leer_tramo(monkeypatch):
    """Con el cliente del caller, un permiso de lectura faltante devolvería 0 filas y el guard no
    bloquearía (fail-open). La lectura de insumo va con service_role; el caller NUNCA consulta tramo."""
    db, tabla_corr = _preparar_correccion(monkeypatch, [_tramo(1, 2, "cerrado")])
    tramo_del_caller = _tabla([])  # lo que vería el caller sin tramo_lectura/dia_lectura: nada
    db.postgrest.schema.return_value.table.side_effect = lambda nombre: (
        tramo_del_caller if nombre == "tramo" else tabla_corr
    )
    r = _corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_DIA_YA_CERRADO
    tramo_del_caller.select.assert_not_called()
    tabla_corr.insert.assert_not_called()


def test_m1_en_marcas_la_consulta_de_tramos_tampoco_usa_el_cliente_del_caller(permitir):
    tramo_del_caller = _tabla([])
    servicio_tramo = _tabla([_tramo(1, 2, "cerrado")])
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=servicio_tramo)
    db = _db(
        marca=_tabla([_marca(1, requiere_revision=False)], count=1),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        correccion=_tabla([]),
        tramo=tramo_del_caller,
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.json()["marcas"][0]["motivo_bloqueo_correccion"] == "en_tramo_cerrado"
    tramo_del_caller.select.assert_not_called()
    servicio_tramo.select.assert_called_once()


def test_m1_el_servicio_recibe_solo_ids_enteros_validados():
    from app.marca_en_tramo import bloqueo_por_tramo

    servicio = _tabla([])
    bloqueo_por_tramo(_db(tramo=servicio), [3, "1", 3])
    servicio.or_.assert_called_once_with("marca_apertura_id.in.(1,3),marca_cierre_id.in.(1,3)")
    with pytest.raises(ValueError):
        bloqueo_por_tramo(_db(tramo=_tabla([])), ["1),marca_cierre_id.is.null,(x"])


# --- M2: precheck de dia_cerrado antes del INSERT -----------------------------------------------------------


MENSAJE_DIA_CERRADO = (
    "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día "
    "(o, si el día ya está revisado, descarta la marca tardía)."
)


@pytest.mark.parametrize(
    "motivo", ["dia_cerrado", "dia_cerrado — resuelto por ausencia 3", "dia_cerrado — descartada por x: y"]
)
def test_m2_una_dia_cerrado_pendiente_se_rechaza_antes_del_insert(monkeypatch, motivo):
    db, tabla_corr = _preparar_correccion(monkeypatch, [])
    monkeypatch.setattr(
        correcciones,
        "_excepciones_de_marca",
        lambda d, marca_id: [
            {"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"},
            {"estado": "pendiente", "motivo_revision": motivo},
        ],
    )
    r = _corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_DIA_CERRADO
    tabla_corr.insert.assert_not_called()


def test_m2_una_dia_cerrado_ya_resuelta_o_otros_motivos_no_disparan_el_precheck(monkeypatch):
    db, tabla_corr = _preparar_correccion(monkeypatch, [])
    monkeypatch.setattr(
        correcciones,
        "_excepciones_de_marca",
        lambda d, marca_id: [
            {"estado": "resuelto", "motivo_revision": "dia_cerrado"},
            {"estado": "pendiente", "motivo_revision": "fuera_de_horario"},
        ],
    )
    assert _corregir(db).status_code == 201
    tabla_corr.insert.assert_called_once()


def test_m2_el_precheck_lee_motivo_revision_de_la_tabla_excepcion(monkeypatch):
    db, tabla_corr = _preparar_correccion(monkeypatch, [])
    monkeypatch.undo()  # sin monkeypatch de _excepciones_de_marca: se ejercita la consulta real
    monkeypatch.setattr(correcciones, "_buscar_marca", lambda d, m: {"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"})
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda d, c: "p")
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda d, p, c: True)
    monkeypatch.setattr(correcciones, "_validar_ventana", lambda f: None)
    excepcion = _tabla([{"estado": "pendiente", "motivo_revision": "dia_cerrado"}])
    db2 = _db(excepcion=excepcion, correccion=tabla_corr)
    assert _corregir(db2).status_code == 409
    excepcion.select.assert_called_with("estado, motivo_revision")
    tabla_corr.insert.assert_not_called()


# --- M3: fallthrough de dias y ausencias ----------------------------------------------------------------------


def test_m3_revisar_dia_con_error_desconocido_da_422_fijo_y_log(permitir, caplog):
    import logging

    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "XX999", "message": f"{CRUDO} linea1\nlinea2"}
    )
    with caplog.at_level(logging.ERROR):
        r = _cliente(db).post("/api/dias/5/revisar", json={"horas_totales": 8}, headers=AUTH)
    assert r.status_code == 422
    assert r.json()["detail"] == "No se pudo revisar el día."
    assert "3377" not in r.text and "texto-crudo" not in r.text
    registros = [x for x in caplog.records if "revisar día rechazado" in x.getMessage()]
    assert registros and "\n" not in registros[0].getMessage()


def test_m3_resolver_ausencia_con_error_desconocido_da_422_fijo_y_log(permitir, caplog):
    import logging

    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "XX999", "message": f"{CRUDO}\r\nsegunda linea"}
    )
    with caplog.at_level(logging.ERROR):
        r = _cliente(db).post(
            "/api/ausencias/9/resolver", json={"decision": "autorizada", "tipo_de_ausencia": "vacaciones"}, headers=AUTH
        )
    assert r.status_code == 422
    assert r.json()["detail"] == "No se pudo resolver la ausencia."
    assert "3377" not in r.text and "texto-crudo" not in r.text
    registros = [x for x in caplog.records if "resolver ausencia rechazado" in x.getMessage()]
    assert registros and "\n" not in registros[0].getMessage() and "\r" not in registros[0].getMessage()


# --- descartar: 23505; errores: 22023 sólo con su hint; log de correcciones en una línea --------------------


def test_descartar_con_violacion_de_unicidad_da_409_sin_texto(permitir):
    db = _db()
    db.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": f"duplicate key {CRUDO}"}
    )
    r = _cliente(db).post("/api/excepciones/7/descartar", json={"motivo": "x"}, headers=AUTH)
    assert r.status_code == 409
    assert r.json()["detail"] == "La excepción ya fue descartada antes."
    assert "3377" not in r.text


def test_22023_sin_el_hint_del_motivo_no_se_traduce_a_motivo_obligatorio():
    from app.errores import traducir_error_dia_cerrado

    assert traducir_error_dia_cerrado(APIError({"code": "22023", "hint": None, "message": "x"})) is None
    assert traducir_error_dia_cerrado(APIError({"code": "22023", "hint": "otro", "message": "x"})) is None
    traduccion = traducir_error_dia_cerrado(
        APIError({"code": "22023", "hint": "motivo_invalido", "message": "x"})
    )
    assert traduccion.status_code == 422


def test_el_log_de_correcciones_queda_en_una_sola_linea(monkeypatch, caplog):
    import logging

    error = APIError({"code": "XX999", "hint": "h\ninyectado", "message": "a\r\nFALSO ERROR linea\nb"})
    db, _ = _preparar_correccion(monkeypatch, [], insert_error=error)
    with caplog.at_level(logging.ERROR):
        _corregir(db)
    mensaje = [x.getMessage() for x in caplog.records if "corrección rechazada" in x.getMessage()][0]
    assert "\n" not in mensaje and "\r" not in mensaje


def test_fecha_local_exige_el_desfase_completo_sin_salto_de_linea_final():
    from app.fecha_local import desfase_a_timedelta

    with pytest.raises(ValueError):
        desfase_a_timedelta("-06:00\n")
    assert desfase_a_timedelta("-06:00").total_seconds() == -21600


def test_el_dia_de_las_excepciones_se_busca_por_fechas_exactas_no_por_rango(permitir):
    tabla_dia = _tabla([{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "revisado"}])
    db = _db(
        excepcion=_tabla([_fila_exc(10, 1, "dia_cerrado"), _fila_exc(11, 2, "dia_cerrado")]),
        marca=_tabla(
            [
                {"id": 1, "persona_id": PERSONA, "momento_dispositivo": "2026-10-06T15:00:00+00:00", "desfase_local": "-06:00"},
                {"id": 2, "persona_id": PERSONA, "momento_dispositivo": "2026-09-01T15:00:00+00:00", "desfase_local": "-06:00"},
            ]
        ),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        correccion=_tabla([]),
        dia=tabla_dia,
    )
    r = _cliente(db).get("/api/excepciones", headers=AUTH)
    assert r.status_code == 200
    tabla_dia.in_.assert_any_call("fecha", ["2026-09-01", "2026-10-06"])
    tabla_dia.gte.assert_not_called()
    tabla_dia.lte.assert_not_called()


# ======================================================================================================
# Cierre de huecos de la revisión de testing
# ======================================================================================================

PERSONA_2 = "bbbbbbbb-0000-0000-0000-000000000002"


# --- P2 (mutantes) ------------------------------------------------------------------------------------------


def test_p2b_las_consultas_de_dia_llevan_las_listas_exactas_de_personas_y_fechas(permitir):
    marcas = [
        {"id": 1, "persona_id": PERSONA, "momento_dispositivo": "2026-10-06T15:00:00+00:00", "desfase_local": "-06:00"},
        {"id": 2, "persona_id": PERSONA_2, "momento_dispositivo": "2026-09-01T15:00:00+00:00", "desfase_local": "-06:00"},
    ]
    dias = [
        {"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "revisado"},
        {"id": 6, "persona_id": PERSONA_2, "fecha": "2026-09-01", "estado": "bloqueado"},
    ]
    filas, _, tablas = _listar_excepciones_completo(
        permitir, [_fila_exc(10, 1, "dia_cerrado"), _fila_exc(11, 2, "dia_cerrado")], dias, marcas=marcas
    )
    tablas["dia"].in_.assert_any_call("persona_id", [PERSONA, PERSONA_2])
    tablas["dia"].in_.assert_any_call("fecha", ["2026-09-01", "2026-10-06"])
    assert filas[10]["camino_resolucion"] == "descartar"
    assert filas[11]["camino_resolucion"] == "revisar_dia"


def test_p2c_las_excepciones_de_dia_no_son_dia_cerrado_ni_consultan_marca_ni_dia(permitir):
    filas_exc = [
        {**_fila_exc(20, None, "paridad_impar"), "dia_id": 5},
        {**_fila_exc(21, None, "otra_cosa"), "dia_id": 5},
    ]
    filas, _, tablas = _listar_excepciones_completo(permitir, filas_exc, [])
    for id_ in (20, 21):
        assert filas[id_]["es_dia_cerrado"] is False
        assert filas[id_]["camino_resolucion"] is None
        assert filas[id_]["dia_de_la_marca_id"] is None
    for nombre in ("marca", "dia", "correccion"):
        tablas[nombre].execute.assert_not_called()


def test_p2c_es_dia_cerrado_tolera_motivo_nulo_o_ausente():
    from app.routers.excepciones import _es_dia_cerrado

    assert _es_dia_cerrado({"marca_id": 1, "motivo_revision": None}) is False
    assert _es_dia_cerrado({"marca_id": 1}) is False
    assert _es_dia_cerrado({"marca_id": None, "motivo_revision": "dia_cerrado"}) is False
    assert _es_dia_cerrado({"marca_id": 1, "motivo_revision": "dia_cerrado — x"}) is True


def test_p2d_un_tramo_cerrado_consultando_solo_una_punta_no_contamina_con_la_otra():
    from app.marca_en_tramo import bloqueo_por_tramo

    db = _db(tramo=_tabla([_tramo(1, 2, "cerrado")]))
    assert bloqueo_por_tramo(db, [1]) == {1: "en_tramo_cerrado"}
    assert bloqueo_por_tramo(db, [2]) == {2: "en_tramo_cerrado"}


def test_p2e_una_marca_sin_desfase_local_no_revienta_y_no_ofrece_camino(permitir):
    marcas = [{"id": 1, "persona_id": PERSONA, "momento_dispositivo": "2026-10-06T15:00:00+00:00"}]
    filas, _, tablas = _listar_excepciones_completo(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "bloqueado"}],
        marcas=marcas,
    )
    assert filas[10]["es_dia_cerrado"] is True
    assert filas[10]["camino_resolucion"] is None
    assert filas[10]["dia_de_la_marca_estado"] is None
    tablas["dia"].execute.assert_not_called()


def test_p2e_un_dia_embebido_como_lista_vacia_no_da_indexerror():
    from app.marca_en_tramo import bloqueo_por_tramo

    db = _db(tramo=_tabla([{"marca_apertura_id": 1, "marca_cierre_id": None, "dia": []}]))
    assert bloqueo_por_tramo(db, [1]) == {1: "en_tramo"}  # sin estado de día legible: tramo abierto


# --- filtro ?tipo=dia_cerrado: el LIKE sin escape es sólo un prefiltro; el filtro real es startswith ---------


def test_p4_el_prefiltro_like_va_sin_escape_y_el_filtro_exacto_es_startswith(permitir):
    filas_exc = [
        _fila_exc(10, 1, "dia_cerrado"),
        _fila_exc(11, 1, "dia_cerrado — resuelto por ausencia 3"),
        _fila_exc(12, 1, "diaXcerrado_raro"),  # el `_` sin escape es comodín: PostgREST lo devolvería
        _fila_exc(13, 1, "fuera_de_horario"),  # (por si el filtro de la base no se aplicara)
    ]
    filas, tabla_exc, _ = _listar_excepciones_completo(
        permitir,
        filas_exc,
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "bloqueado"}],
        query="?tipo=dia_cerrado",
    )
    tabla_exc.like.assert_called_once_with("motivo_revision", "dia_cerrado%")
    assert "\\" not in tabla_exc.like.call_args.args[1]
    assert sorted(filas) == [10, 11]  # el startswith exacto descarta 12 y 13


def test_p4_sin_el_filtro_tipo_no_se_filtra_en_python(permitir):
    filas, tabla_exc, _ = _listar_excepciones_completo(
        permitir, [_fila_exc(13, 1, "fuera_de_horario"), _fila_exc(10, 1, "dia_cerrado")], []
    )
    assert sorted(filas) == [10, 13]
    tabla_exc.like.assert_not_called()


# --- P2 (contratos con el DDL de 86_) -------------------------------------------------------------------------

import re
from pathlib import Path

_DDL_86 = sorted(Path(__file__).resolve().parents[2].glob("db/ddl/86_*.sql"))


def _sql_86() -> str:
    assert _DDL_86, "no se encontró db/ddl/86_*.sql"
    return _DDL_86[0].read_text(encoding="utf-8")


def test_p2a_el_prefijo_del_backend_coincide_con_el_like_del_constraint_trigger():
    from app.routers.excepciones import PREFIJO_DIA_CERRADO

    sql = _sql_86()
    patrones = set(re.findall(r"LIKE\s+'(dia\\_cerrado%)'", sql))
    assert patrones, "el constraint trigger de 86_ ya no usa LIKE 'dia\\_cerrado%'"
    escapado = PREFIJO_DIA_CERRADO.replace("_", "\\_") + "%"
    assert patrones == {escapado}
    # y el SQL que decide el motivo de las excepciones de marca sigue emitiendo exactamente este prefijo
    assert f"'{PREFIJO_DIA_CERRADO}'" in (Path(__file__).resolve().parents[2] / "db/ddl/02_tiempo.sql").read_text(encoding="utf-8")


def test_p2b_fecha_local_efectiva_replica_fn_marca_fecha_local_del_ddl():
    sql = _sql_86()
    cuerpo = re.search(r"CREATE FUNCTION tiempo\.fn_marca_fecha_local.*?\$\$;", sql, re.S).group(0)
    # corrección MÁS RECIENTE si existe, si no momento_dispositivo; y luego el desfase local
    assert re.search(
        r"SELECT c\.valor_corregido FROM tiempo\.correccion c\s+WHERE c\.marca_id = m\.id ORDER BY c\.creado_en DESC LIMIT 1",
        cuerpo,
    )
    assert "COALESCE(" in cuerpo and "m.momento_dispositivo" in cuerpo
    assert "AT TIME ZONE 'UTC'" in cuerpo
    assert "m.desfase_local::interval" in cuerpo
    assert ")::date" in cuerpo
    # y la contraparte Python hace lo mismo con los mismos insumos
    from datetime import date

    from app.fecha_local import fecha_local_efectiva

    assert fecha_local_efectiva("2026-10-07T03:00:00+00:00", "-06:00") == date(2026, 10, 6)


# --- P3: coherencia GET <-> POST, orden de chequeos, permiso primero -------------------------------------------


def _escenario(permitir_gate, monkeypatch, tramos, motivo="reloj_no_sincronizado", puede_corregir=True):
    """Mismo fixture para GET /api/marcas y POST /api/correcciones."""
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda d, c: "persona-ficticia")
    monkeypatch.setattr(
        correcciones,
        "tiene_permiso",
        lambda d, p, codigo: puede_corregir if codigo == "correccion_edicion" else True,
    )
    tabla_corr = _tabla([])
    tabla_corr.insert.return_value.execute.return_value = _Resultado(
        [{"id": 1, "marca_id": 1, "valor_corregido": "2026-10-06T16:00:00+00:00", "motivo": "x",
          "autor_id": PERSONA, "creado_en": "2026-10-07T10:00:00+00:00"}]
    )
    marca = _marca(1, momento_dispositivo=f"{__import__('datetime').date.today().isoformat()}T09:00:00+00:00")
    db = _db(
        marca=_tabla([marca], count=1),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=_tabla([_exc(10, 1, motivo)]),
        correccion=tabla_corr,
    )
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=_tabla(tramos))
    return db, tabla_corr


CASOS_COHERENCIA = [
    ("sin_tramo", [], "reloj_no_sincronizado"),
    ("tramo_abierto", [_tramo(1, None, "bloqueado")], "reloj_no_sincronizado"),
    ("tramo_cerrado", [_tramo(1, 2, "bloqueado")], "reloj_no_sincronizado"),
    ("dia_cerrado_sin_cierre", [_tramo(1, None, "cerrado")], "reloj_no_sincronizado"),
    ("dia_revisado", [_tramo(1, None, "revisado")], "reloj_no_sincronizado"),
    ("dia_cerrado_pendiente", [], "dia_cerrado"),
]


@pytest.mark.parametrize("nombre,tramos,motivo", CASOS_COHERENCIA, ids=[c[0] for c in CASOS_COHERENCIA])
def test_p3a_una_marca_bloqueada_en_get_es_un_409_en_post_y_al_reves(permitir, monkeypatch, nombre, tramos, motivo):
    db, tabla_corr = _escenario(permitir, monkeypatch, tramos, motivo)
    cliente = _cliente(db)
    get = cliente.get("/api/marcas", headers=AUTH)
    assert get.status_code == 200, get.text
    bloqueada_en_get = get.json()["marcas"][0]["motivo_bloqueo_correccion"] is not None
    post = cliente.post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )
    assert bloqueada_en_get == (post.status_code == 409), (nombre, get.json(), post.text)
    if bloqueada_en_get:
        tabla_corr.insert.assert_not_called()
    else:
        assert post.status_code == 201


def test_p3a_el_fixture_sin_bloqueo_realmente_deja_pasar(permitir, monkeypatch):
    db, _ = _escenario(permitir, monkeypatch, [])
    post = _cliente(db).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )
    assert post.status_code == 201


def _post_corregir(db):
    return _cliente(db).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers=AUTH,
    )


def test_p3b_orden_tramo_antes_que_ventana(permitir, monkeypatch):
    """Marca en tramo cerrado Y con la ventana de días hábiles vencida: gana el 409 del tramo."""
    db, tabla_corr = _escenario(permitir, monkeypatch, [_tramo(1, 2, "cerrado")])
    llamadas = []

    def ventana_vencida(fecha):
        llamadas.append(fecha)
        from fastapi import HTTPException

        raise HTTPException(422, "ventana vencida")

    monkeypatch.setattr(correcciones, "_validar_ventana", ventana_vencida)
    r = _post_corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"] == MENSAJE_DIA_YA_CERRADO
    assert llamadas == []  # ni siquiera se llegó a la ventana
    tabla_corr.insert.assert_not_called()


def test_p3b_orden_dia_cerrado_antes_que_tramo(permitir, monkeypatch):
    db, _ = _escenario(permitir, monkeypatch, [_tramo(1, 2, "cerrado")], motivo="dia_cerrado")
    r = _post_corregir(db)
    assert r.status_code == 409
    assert r.json()["detail"].startswith("Esta marca es de un día ya cerrado")  # no el del tramo


def test_p3b_la_ventana_vencida_sigue_dando_422_cuando_nada_mas_bloquea(permitir, monkeypatch):
    db, _ = _escenario(permitir, monkeypatch, [])

    def ventana_vencida(fecha):
        from fastapi import HTTPException

        raise HTTPException(422, "ventana vencida")

    monkeypatch.setattr(correcciones, "_validar_ventana", ventana_vencida)
    assert _post_corregir(db).status_code == 422


def test_p3c_sin_correccion_edicion_el_403_gana_al_409_del_tramo(permitir, monkeypatch):
    db, tabla_corr = _escenario(permitir, monkeypatch, [_tramo(1, 2, "cerrado")], puede_corregir=False)
    r = _post_corregir(db)
    assert r.status_code == 403
    tabla_corr.insert.assert_not_called()


def test_p3c_sin_correccion_edicion_el_403_gana_tambien_a_dia_cerrado_pendiente(permitir, monkeypatch):
    db, _ = _escenario(permitir, monkeypatch, [], motivo="dia_cerrado", puede_corregir=False)
    assert _post_corregir(db).status_code == 403


# ======================================================================================================
# Paquete 1 de frontend: fecha/día de la marca, filtros de GET /api/dias
# ======================================================================================================


def test_excepciones_trae_dia_de_la_marca_fecha_aunque_el_dia_no_exista(permitir):
    filas, _ = _listar_excepciones(permitir, [_fila_exc(10, 1, "dia_cerrado")], [])
    assert filas[10]["dia_de_la_marca_fecha"] == "2026-10-06"
    assert filas[10]["dia_de_la_marca_id"] is None
    assert filas[10]["camino_resolucion"] is None


def test_excepciones_trae_dia_de_la_marca_fecha_junto_al_id_y_el_estado(permitir):
    filas, _ = _listar_excepciones(
        permitir,
        [_fila_exc(10, 1, "dia_cerrado")],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06", "estado": "bloqueado"}],
    )
    assert filas[10]["dia_de_la_marca_fecha"] == "2026-10-06"
    assert filas[10]["dia_de_la_marca_id"] == 5


def test_excepciones_la_fecha_usa_la_correccion_mas_reciente(permitir):
    corrs = [{"marca_id": 1, "valor_corregido": "2026-10-08T03:00:00+00:00", "creado_en": "2026-10-09T09:00:00Z"}]
    filas, _ = _listar_excepciones(permitir, [_fila_exc(10, 1, "dia_cerrado")], [], corrs)
    assert filas[10]["dia_de_la_marca_fecha"] == "2026-10-07"  # 03:00Z con -06:00 = 21:00 del 07


def test_excepciones_no_dia_cerrado_dejan_la_fecha_en_none_y_no_consultan(permitir):
    filas, _ = _listar_excepciones(permitir, [_fila_exc(10, 1, "reloj_no_sincronizado")], [])
    assert filas[10]["dia_de_la_marca_fecha"] is None


# --- GET /api/dias: filtros persona_id y dia_id ---------------------------------------------------------------


def _listar_dias(permitir, query=""):
    tabla_dia = _tabla([])
    tabla_dia.execute.return_value = _Resultado([], count=0)
    servicio = _db(dia=tabla_dia)
    app.dependency_overrides[get_service_client] = lambda: servicio
    app.dependency_overrides[get_caller_client] = lambda: MagicMock()
    app.dependency_overrides[get_caller_identity] = lambda: CALLER
    r = TestClient(app, raise_server_exceptions=False).get(f"/api/dias{query}", headers=AUTH)
    return r, tabla_dia


def test_dias_filtra_por_persona_y_por_dia_exactos(permitir):
    r, tabla = _listar_dias(permitir, f"?persona_id={PERSONA}&dia_id=5")
    assert r.status_code == 200, r.text
    tabla.eq.assert_any_call("persona_id", PERSONA)
    tabla.eq.assert_any_call("id", 5)


def test_dias_sin_filtros_nuevos_no_los_aplica(permitir):
    r, tabla = _listar_dias(permitir)
    assert r.status_code == 200
    assert [c.args[0] for c in tabla.eq.call_args_list] == []


@pytest.mark.parametrize(
    "query",
    [
        "?persona_id=no-es-uuid",
        "?persona_id=1;drop table dia",
        "?persona_id=aaaaaaaa-0000-0000-0000-00000000000g",
        "?dia_id=0",
        "?dia_id=-3",
        "?dia_id=abc",
        "?dia_id=1.5",
    ],
)
def test_dias_rechaza_filtros_invalidos_con_422_sin_consultar(permitir, query):
    r, tabla = _listar_dias(permitir, query)
    assert r.status_code == 422
    tabla.execute.assert_not_called()


def test_dias_los_filtros_no_saltan_el_gate_de_permisos(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "p")
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona, codigo: False)
    r, tabla = _listar_dias(None, f"?persona_id={PERSONA}&dia_id=5")
    assert r.status_code == 403
    tabla.execute.assert_not_called()


def test_dias_el_uuid_normaliza_antes_de_llegar_al_filtro(permitir):
    r, tabla = _listar_dias(permitir, f"?persona_id={PERSONA.upper()}")
    assert r.status_code == 200
    tabla.eq.assert_any_call("persona_id", PERSONA)


# --- GET /api/marcas: fecha_local y dia_id -----------------------------------------------------------------------


def _marcas_con_dias(permitir, marcas, dias, correcciones=()):
    tabla_dia = _tabla(dias)
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=_tabla([]), dia=tabla_dia)
    db = _db(
        marca=_tabla(marcas, count=len(marcas)),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        excepcion=_tabla([]),
        correccion=_tabla(list(correcciones)),
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.status_code == 200, r.text
    return {m["id"]: m for m in r.json()["marcas"]}, tabla_dia


def test_marcas_trae_fecha_local_y_dia_id(permitir):
    marcas, tabla = _marcas_con_dias(
        permitir,
        [_marca(1, requiere_revision=False)],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06"}],
    )
    assert marcas[1]["fecha_local"] == "2026-10-06"
    assert marcas[1]["dia_id"] == 5
    tabla.in_.assert_any_call("persona_id", [PERSONA])
    tabla.in_.assert_any_call("fecha", ["2026-10-06"])


def test_marcas_dia_id_es_none_si_el_dia_no_existe_pero_la_fecha_local_si_viene(permitir):
    marcas, _ = _marcas_con_dias(permitir, [_marca(1, requiere_revision=False)], [])
    assert marcas[1]["fecha_local"] == "2026-10-06"
    assert marcas[1]["dia_id"] is None


def test_marcas_la_fecha_local_usa_la_correccion_mas_reciente(permitir):
    corrs = [{"marca_id": 1, "valor_corregido": "2026-10-08T03:00:00+00:00", "creado_en": "2026-10-09T09:00:00Z"}]
    marcas, tabla = _marcas_con_dias(
        permitir,
        [_marca(1, requiere_revision=False)],
        [{"id": 9, "persona_id": PERSONA, "fecha": "2026-10-07"}],
        corrs,
    )
    assert marcas[1]["fecha_local"] == "2026-10-07"
    assert marcas[1]["dia_id"] == 9


def test_marcas_no_cruza_dias_de_otra_persona_ni_de_otra_fecha(permitir):
    marcas, _ = _marcas_con_dias(
        permitir,
        [_marca(1, requiere_revision=False)],
        [
            {"id": 5, "persona_id": "otra-persona", "fecha": "2026-10-06"},
            {"id": 6, "persona_id": PERSONA, "fecha": "2026-10-05"},
        ],
    )
    assert marcas[1]["dia_id"] is None


def test_marcas_una_sola_consulta_de_dias_por_pagina_y_ninguna_si_esta_vacia(permitir):
    _, tabla = _marcas_con_dias(
        permitir,
        [_marca(1, requiere_revision=False), _marca(2, requiere_revision=False)],
        [{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06"}],
    )
    assert tabla.execute.call_count == 1
    _, vacia = _marcas_con_dias(permitir, [], [])
    vacia.execute.assert_not_called()


def test_marcas_la_consulta_de_dias_usa_service_role_no_el_cliente_del_caller(permitir):
    dia_del_caller = _tabla([])
    tabla_servicio = _tabla([{"id": 5, "persona_id": PERSONA, "fecha": "2026-10-06"}])
    app.dependency_overrides[get_service_client] = lambda: _db(tramo=_tabla([]), dia=tabla_servicio)
    db = _db(
        marca=_tabla([_marca(1, requiere_revision=False)], count=1),
        persona=_tabla([{"id": PERSONA, "primer_nombre": "Ana", "apellido_paterno": "Ruiz"}]),
        correccion=_tabla([]),
        dia=dia_del_caller,
    )
    r = _cliente(db).get("/api/marcas", headers=AUTH)
    assert r.json()["marcas"][0]["dia_id"] == 5
    dia_del_caller.select.assert_not_called()
