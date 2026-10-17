from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.main import app

AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"
PERSONA_ID = "11111111-1111-1111-1111-111111111111"


PUESTO_CALLER_ID = "puesto-ficticio-caller"


def _tabla_puesto_permiso_por_codigo(codigos_activos):
    """MagicMock argumento-consciente: .select("puesto_id").eq("codigo", codigo).eq("activo",
    True).execute().data -- distingue el código pedido (a diferencia del resto de los fakes de
    este módulo, acá SÍ importa: puede_ver_modulo_1 y puede_ver_modulo_2 se resuelven con dos
    llamadas a tiene_permiso con códigos distintos, y necesitamos respuestas distintas)."""
    tabla = MagicMock()

    def eq_codigo(_campo, codigo):
        resultado_eq2 = MagicMock()

        def eq_activo(_campo2, _valor2):
            ejecutable = MagicMock()
            datos = [{"puesto_id": PUESTO_CALLER_ID}] if codigo in codigos_activos else []
            ejecutable.execute.return_value.data = datos
            return ejecutable

        resultado_eq2.eq.side_effect = eq_activo
        return resultado_eq2

    tabla.select.return_value.eq.side_effect = eq_codigo

    def in_codigos(_campo, codigos):
        resultado_in = MagicMock()
        filas = [
            {"puesto_id": PUESTO_CALLER_ID, "codigo": codigo}
            for codigo in codigos
            if codigo in codigos_activos
        ]
        resultado_in.eq.return_value.execute.return_value.data = filas
        return resultado_in

    tabla.select.return_value.in_.side_effect = in_codigos
    return tabla


def _fake_db(filas_usuario, filas_persona=None, codigos_activos=()):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    # El estado de la persona viaja EMBEBIDO en la fila de usuario (`persona:persona_id(estado)`), como lo devuelve PostgREST.
    filas_usuario = [
        {**fila, "persona": (filas_persona[0] if filas_persona else None)} if fila.get("persona_id") else fila for fila in filas_usuario
    ]

    def side_effect(nombre_tabla):
        if nombre_tabla == "usuario":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = filas_usuario
            return tabla
        if nombre_tabla == "persona":
            raise AssertionError("/api/sesion ya no consulta personas.persona aparte: el estado viene embebido en usuario")
        if nombre_tabla in ("permiso", "puesto"):
            tabla = MagicMock()
            tabla.select.return_value.in_.return_value.execute.return_value.data = []
            tabla.select.return_value.execute.return_value.data = []
            return tabla
        if nombre_tabla == "asignacion":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": PUESTO_CALLER_ID}
            ]
            return tabla
        if nombre_tabla == "puesto_permiso":
            return _tabla_puesto_permiso_por_codigo(codigos_activos)
        return MagicMock()

    tabla_mock.side_effect = side_effect
    return fake_client


def _overrides(fake_client, correo="mariana.alcantara@example.com"):
    app.dependency_overrides[get_service_client] = lambda: fake_client
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo=correo
    )


def test_sesion_persona_activa_permite_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is True
    assert body["motivo_bloqueo"] is None
    assert body["persona_estado"] == "activo"


def test_sesion_calcula_puede_ver_modulo_1_y_2_por_separado():
    """El puesto vigente del caller tiene ver_modulo_1 activo pero NO ver_modulo_2 -- confirma
    que ambos flags se resuelven de forma independiente (dos llamadas a tiene_permiso, una por
    código), no como un OR compartido."""
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
        codigos_activos=("ver_modulo_1",),
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["puede_ver_modulo_1"] is True
    assert body["puede_ver_modulo_2"] is False


def test_sesion_sin_ver_modulo_1_ni_2_devuelve_ambos_false():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
        codigos_activos=(),
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["puede_ver_modulo_1"] is False
    assert body["puede_ver_modulo_2"] is False


def test_sesion_persona_suspendida_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "suspension"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "suspension"
    # Cuenta bloqueada: ni siquiera se calculan los permisos (backend confirmó que sólo se
    # evalúan cuando acceso_permitido es true) -- quedan en su default False.
    assert body["puede_ver_modulo_1"] is False
    assert body["puede_ver_modulo_2"] is False


def test_sesion_persona_baja_definitiva_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "baja_definitiva"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "baja_definitiva"


def test_sesion_usuario_sin_persona_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": None,
            }
        ],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "sin_persona"


def test_sesion_sin_fila_usuario_bloquea_acceso():
    fake_client = _fake_db(filas_usuario=[])
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "sin_usuario"


def test_sesion_rechaza_sin_token():
    fake_client = _fake_db(filas_usuario=[])
    app.dependency_overrides[get_service_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/sesion")

    app.dependency_overrides.clear()
    assert response.status_code in (401, 422)


# --- costo y transitorios de /api/sesion --------------------------------------------------------------------------------------------------------------

import threading  # noqa: E402
import time  # noqa: E402

import httpx  # noqa: E402
from postgrest.exceptions import APIError  # noqa: E402


def _pedir_sesion(fake_client):
    _overrides(fake_client)
    try:
        return TestClient(app, raise_server_exceptions=False).get("/api/sesion", headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()


def test_sesion_obtiene_el_esquema_una_sola_vez_y_no_hace_la_consulta_de_persona():
    """Cada `.schema()` fabrica un cliente httpx nuevo (otro TCP/TLS): /api/sesion lo pide UNA vez y hace 1 consulta de usuario+persona (embed) + 4 lecturas de permisos."""
    fake_client = _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=[{"estado": "activo"}],
                           codigos_activos=("ver_modulo_1",))
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 200 and respuesta.json()["acceso_permitido"] is True and respuesta.json()["puede_ver_modulo_1"] is True
    assert fake_client.postgrest.schema.call_count == 1
    tablas = [c.args[0] for c in fake_client.postgrest.schema.return_value.table.call_args_list]
    assert sorted(tablas) == ["asignacion", "permiso", "puesto", "puesto_permiso", "usuario"]
    assert "persona" not in tablas


def test_sesion_persona_suspendida_no_consulta_permisos():
    fake_client = _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=[{"estado": "suspension"}])
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 200 and respuesta.json()["motivo_bloqueo"] == "suspension"
    tablas = [c.args[0] for c in fake_client.postgrest.schema.return_value.table.call_args_list]
    assert tablas == ["usuario"]


def test_sesion_las_lecturas_de_permisos_salen_a_la_vez():
    """Las 4 lecturas independientes corren concurrentemente: con una barrera de 4 hilos, si fueran en serie nunca se llenaría y la prueba fallaría por timeout."""
    barrera = threading.Barrier(4, timeout=3)
    fake_client = _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=[{"estado": "activo"}])
    original = fake_client.postgrest.schema.return_value.table.side_effect

    def con_barrera(nombre):
        if nombre in ("asignacion", "puesto_permiso", "permiso", "puesto"):
            barrera.wait()
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = con_barrera
    assert _pedir_sesion(fake_client).status_code == 200


def _fallar_una_vez_en(fake_client, tabla_objetivo, error):
    """La PRIMERA lectura de `tabla_objetivo` lanza `error`; las siguientes responden normal."""
    original = fake_client.postgrest.schema.return_value.table.side_effect
    estado = {"fallos": 0}

    def tabla(nombre):
        t = original(nombre)
        if nombre == tabla_objetivo and estado["fallos"] < estado.get("max", 1):
            estado["fallos"] += 1
            roto = MagicMock()
            roto.select.return_value.eq.return_value.execute.side_effect = error
            roto.select.return_value.eq.return_value.is_.return_value.execute.side_effect = error
            roto.select.return_value.in_.return_value.eq.return_value.execute.side_effect = error
            roto.select.return_value.in_.return_value.execute.side_effect = error
            roto.select.return_value.execute.side_effect = error
            return roto
        return t

    fake_client.postgrest.schema.return_value.table.side_effect = tabla
    return estado


def _db_activa():
    return _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=[{"estado": "activo"}],
                    codigos_activos=("ver_modulo_1",))


def test_sesion_un_statement_timeout_transitorio_se_reintenta_una_vez_y_responde_200(caplog):
    import logging

    fake_client = _db_activa()
    estado = _fallar_una_vez_en(fake_client, "usuario", APIError({"code": "57014", "message": "canceling statement due to statement timeout TEXTO INTERNO"}))
    with caplog.at_level(logging.WARNING, logger="app.errores"):
        respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 200 and respuesta.json()["puede_ver_modulo_1"] is True and estado["fallos"] == 1
    avisos = [r.getMessage() for r in caplog.records if r.name == "app.errores"]
    assert len(avisos) == 1 and "APIError" in avisos[0] and "57014" in avisos[0] and "TEXTO INTERNO" not in avisos[0]


def test_sesion_si_el_reintento_tambien_falla_responde_503_con_retry_after_y_mensaje_fijo():
    fake_client = _db_activa()
    _fallar_una_vez_en(fake_client, "usuario", APIError({"code": "57014", "message": "TEXTO INTERNO de la base"}))
    original = fake_client.postgrest.schema.return_value.table.side_effect
    # que el reintento TAMBIÉN falle: la tabla `usuario` falla siempre
    def siempre_rota(nombre):
        if nombre == "usuario":
            roto = MagicMock()
            roto.select.return_value.eq.return_value.execute.side_effect = APIError({"code": "57014", "message": "TEXTO INTERNO de la base"})
            return roto
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = siempre_rota
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 503 and respuesta.headers["Retry-After"] == "2"
    assert respuesta.json()["detail"] == "El servicio no está disponible un momento; reintenta."
    assert "TEXTO INTERNO" not in respuesta.text


def test_sesion_una_lectura_de_permisos_que_falla_dos_veces_es_503_no_sesion_vacia():
    """Antes un timeout dejaba a la persona sin sesión (y el frontend lo leía como «abre todo»): ahora es un 503 explícito."""
    fake_client = _db_activa()
    original = fake_client.postgrest.schema.return_value.table.side_effect

    def rota(nombre):
        if nombre == "puesto_permiso":
            t = MagicMock()
            t.select.return_value.in_.return_value.eq.return_value.execute.side_effect = APIError({"code": "57014", "message": "x"})
            return t
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = rota
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 503 and respuesta.headers["Retry-After"] == "2"


def test_sesion_un_error_de_transporte_httpx_tambien_se_reintenta():
    fake_client = _db_activa()
    estado = _fallar_una_vez_en(fake_client, "asignacion", httpx.ReadTimeout("texto con url https://secreto"))
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 200 and estado["fallos"] == 1


def test_sesion_un_error_no_transitorio_no_se_reintenta_ni_se_convierte_en_503():
    fake_client = _db_activa()
    estado = _fallar_una_vez_en(fake_client, "usuario", APIError({"code": "42501", "message": "permission denied"}))
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 500 and estado["fallos"] == 1          # no hubo segundo intento: el manejador global lo trata como siempre
    assert "Retry-After" not in respuesta.headers


def test_sesion_sigue_respondiendo_lo_mismo_para_las_ramas_sin_usuario_y_sin_persona():
    r1 = _pedir_sesion(_fake_db(filas_usuario=[]))
    assert r1.status_code == 200 and r1.json()["motivo_bloqueo"] == "sin_usuario"
    r2 = _pedir_sesion(_fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": None}]))
    assert r2.status_code == 200 and r2.json()["motivo_bloqueo"] == "sin_persona"


# --- guarda de la memoización del esquema (security) ---------------------------------------------------------------------------------------------------


def test_el_esquema_se_memoiza_por_objeto_cliente_dos_clientes_dos_esquemas():
    from app.routers.sesion import _esquema_personas

    a, b = MagicMock(), MagicMock()
    a.postgrest.schema.return_value, b.postgrest.schema.return_value = MagicMock(name="esquema_a"), MagicMock(name="esquema_b")
    assert _esquema_personas(a) is _esquema_personas(a) and a.postgrest.schema.call_count == 1
    assert _esquema_personas(b) is not _esquema_personas(a)                      # clientes distintos: NUNCA comparten esquema (ni cabeceras, ni JWT)
    assert b.postgrest.schema.call_count == 1


def test_los_get_client_fabrican_un_objeto_nuevo_en_cada_llamada_nunca_un_singleton(monkeypatch):
    """Si alguien cacheara `get_service_client` o `get_caller_client` (lru_cache, global), `_esquema_personas` compartiría el esquema entre peticiones/identidades: esta prueba lo detecta."""
    import app.deps as deps
    from app.config import Settings

    monkeypatch.setattr(deps, "create_client", lambda *a, **k: MagicMock())
    ajustes = Settings(supabase_url="http://supabase.invalido", supabase_anon_key="anon-ficticia", supabase_service_role_key="service-ficticia")
    from starlette.requests import Request

    def peticion():
        return Request({"type": "http", "method": "GET", "path": "/", "headers": [], "query_string": b""})

    assert deps.get_service_client(peticion(), ajustes) is not deps.get_service_client(peticion(), ajustes)
    assert deps.get_caller_client(peticion(), "Bearer aaa.bbb.ccc", ajustes) is not deps.get_caller_client(peticion(), "Bearer aaa.bbb.ccc", ajustes)
    assert deps.get_caller_client(peticion(), "Bearer aaa.bbb.ccc", ajustes) is not deps.get_caller_client(peticion(), "Bearer ddd.eee.fff", ajustes)


# --- lecturas de permisos: fallos permanentes y no transitorios -----------------------------------------------------------------------------------------

import pytest  # noqa: E402


def _tabla_rota(error):
    roto = MagicMock()
    for cadena in (roto.select.return_value.eq.return_value.execute, roto.select.return_value.eq.return_value.is_.return_value.execute,
                   roto.select.return_value.in_.return_value.eq.return_value.execute, roto.select.return_value.in_.return_value.execute, roto.select.return_value.execute):
        cadena.side_effect = error
    return roto


@pytest.mark.parametrize("tabla_rota", ["asignacion", "puesto_permiso", "permiso", "puesto"])
def test_si_una_de_las_cuatro_lecturas_falla_de_forma_permanente_es_503_y_ningun_codigo_resuelto(tabla_rota):
    fake_client = _db_activa()
    original = fake_client.postgrest.schema.return_value.table.side_effect
    llamadas = {"n": 0}

    def tabla(nombre):
        if nombre == tabla_rota:
            llamadas["n"] += 1
            return _tabla_rota(APIError({"code": "57014", "message": "TEXTO INTERNO"}))
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = tabla
    respuesta = _pedir_sesion(fake_client)
    assert respuesta.status_code == 503 and respuesta.headers["Retry-After"] == "2" and llamadas["n"] == 2           # un intento y UN reintento
    cuerpo = respuesta.json()
    assert list(cuerpo) == ["detail"]                                                                             # ningún `puede_*`: no hay «sin permisos» fabricado
    assert "TEXTO INTERNO" not in respuesta.text


@pytest.mark.parametrize("codigo", ["42501", "23505", "23514", "23503"])
@pytest.mark.parametrize("tabla_rota", ["asignacion", "puesto_permiso"])
def test_un_42501_o_23xxx_en_una_lectura_no_se_reintenta_y_se_propaga(tabla_rota, codigo):
    fake_client = _db_activa()
    original = fake_client.postgrest.schema.return_value.table.side_effect
    llamadas = {"n": 0}

    def tabla(nombre):
        if nombre == tabla_rota:
            llamadas["n"] += 1
            return _tabla_rota(APIError({"code": codigo, "message": "TEXTO INTERNO"}))
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = tabla
    respuesta = _pedir_sesion(fake_client)
    assert llamadas["n"] == 1 and respuesta.status_code == 500 and "Retry-After" not in respuesta.headers
    assert "TEXTO INTERNO" not in respuesta.text and "puede_" not in respuesta.text


# --- embed `persona` ausente o nulo ---------------------------------------------------------------------------------------------------------------------


def test_embed_de_persona_nulo_es_sin_persona_y_sin_acceso():
    fake_client = _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=None)       # persona: None
    cuerpo = _pedir_sesion(fake_client).json()
    assert cuerpo["acceso_permitido"] is False and cuerpo["motivo_bloqueo"] == "sin_persona" and cuerpo["persona_estado"] is None
    assert cuerpo["puede_ver_modulo_1"] is False and cuerpo["puede_editar_terminales"] is False


def test_embed_de_persona_ausente_es_sin_persona_y_sin_acceso_y_no_consulta_permisos():
    fake_client = _fake_db(filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}], filas_persona=None)
    original = fake_client.postgrest.schema.return_value.table.side_effect

    def tabla(nombre):
        if nombre == "usuario":
            t = MagicMock()
            t.select.return_value.eq.return_value.execute.return_value.data = [{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "m", "persona_id": PERSONA_ID}]   # SIN clave persona
            return t
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = tabla
    cuerpo = _pedir_sesion(fake_client).json()
    assert cuerpo["acceso_permitido"] is False and cuerpo["motivo_bloqueo"] == "sin_persona"
    tablas = [c.args[0] for c in fake_client.postgrest.schema.return_value.table.call_args_list]
    assert tablas == ["usuario"]
