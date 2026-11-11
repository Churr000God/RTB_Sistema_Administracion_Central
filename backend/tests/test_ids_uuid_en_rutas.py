"""P-214: un id que no es UUID en la ruta o en un filtro de query responde 422, no 500 (antes llegaba a Postgres y fallaba con 22P02)."""

from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app import permisos
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

BASURA = "no-es-uuid"
UUID_VALIDO = "33333333-3333-3333-3333-333333333333"

RUTAS_PATH = [
    ("GET", "/api/areas/{}", "area_id"),
    ("PATCH", "/api/areas/{}", "area_id"),
    ("PATCH", "/api/areas/{}/estado", "area_id"),
    ("GET", "/api/departamentos/{}", "departamento_id"),
    ("PATCH", "/api/departamentos/{}", "departamento_id"),
    ("PATCH", "/api/departamentos/{}/estado", "departamento_id"),
    ("GET", "/api/puestos/{}", "puesto_id"),
    ("PATCH", "/api/puestos/{}", "puesto_id"),
    ("PATCH", "/api/puestos/{}/estado", "puesto_id"),
    ("GET", "/api/asignaciones/{}", "asignacion_id"),
    ("PATCH", "/api/asignaciones/{}/terminar", "asignacion_id"),
    ("POST", "/api/asignaciones/{}/cambiar-puesto", "asignacion_id"),
    ("GET", "/api/personas/{}", "persona_id"),
    ("PATCH", "/api/personas/{}", "persona_id"),
    ("GET", "/api/personas/{}/movimientos", "persona_id"),
    ("POST", "/api/personas/{}/movimientos", "persona_id"),
    ("GET", "/api/personas/{}/jornada-vigente", "persona_id"),
    ("GET", "/api/personas/{}/jornadas", "persona_id"),
    ("GET", "/api/banco-de-horas/{}/movimientos", "persona_id"),
    ("POST", "/api/banco-de-horas/{}/movimientos", "persona_id"),
]

RUTAS_QUERY = [
    ("/api/marcas", "persona_id"),
    ("/api/alertas-de-retardo?desde=2026-10-01&hasta=2026-10-15", "persona_id"),
]


@pytest.fixture
def cliente(monkeypatch):
    monkeypatch.setattr(permisos, "resolver_persona_id", lambda db, caller: "persona-ficticia")
    monkeypatch.setattr(permisos, "tiene_alguno", lambda db, persona_id, *codigos: True)
    monkeypatch.setattr(permisos, "tiene_permiso", lambda db, persona_id, codigo: True)
    app.dependency_overrides[get_caller_client] = lambda: MagicMock()
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(auth_user_id="a", correo="a@example.com")
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def _loc_invalido(respuesta, donde, nombre):
    return any(error["loc"][:2] == [donde, nombre] for error in respuesta.json()["detail"])


@pytest.mark.parametrize("metodo,plantilla,nombre", RUTAS_PATH)
def test_id_de_path_que_no_es_uuid_da_422(cliente, metodo, plantilla, nombre):
    respuesta = cliente.request(metodo, plantilla.format(BASURA), json={})
    assert respuesta.status_code == 422
    assert _loc_invalido(respuesta, "path", nombre)


@pytest.mark.parametrize("ruta,nombre", RUTAS_QUERY)
def test_id_de_query_que_no_es_uuid_da_422(cliente, ruta, nombre):
    separador = "&" if "?" in ruta else "?"
    respuesta = cliente.get(f"{ruta}{separador}{nombre}={BASURA}")
    assert respuesta.status_code == 422
    assert _loc_invalido(respuesta, "query", nombre)


@pytest.mark.parametrize("metodo,plantilla,nombre", RUTAS_PATH)
def test_id_de_path_uuid_valido_no_da_422_por_el_id(cliente, metodo, plantilla, nombre):
    respuesta = cliente.request(metodo, plantilla.format(UUID_VALIDO), json={})
    if respuesta.status_code == 422 and isinstance(respuesta.json().get("detail"), list):
        assert not _loc_invalido(respuesta, "path", nombre)


CANONICO = "3f2a9c1e-5b7d-4e8a-9c0b-1d2e3f4a5b6c"


@pytest.mark.parametrize(
    "entrada",
    [CANONICO.upper(), "{" + CANONICO + "}", CANONICO.replace("-", "")],
)
def test_iduuid_normaliza_a_forma_canonica(entrada):
    from pydantic import TypeAdapter

    from app.tipos_id import IdUuid

    assert TypeAdapter(IdUuid).validate_python(entrada) == CANONICO


@pytest.mark.parametrize("basura", ["", "abc", "p1", "no-es-uuid", CANONICO + "0", CANONICO[:-1], "zzzzzzzz-5b7d-4e8a-9c0b-1d2e3f4a5b6c"])
def test_iduuid_rechaza_basura(basura):
    from pydantic import TypeAdapter, ValidationError

    from app.tipos_id import IdUuid

    with pytest.raises(ValidationError):
        TypeAdapter(IdUuid).validate_python(basura)


RUTAS_BODY = [
    ("POST", "/api/asignaciones", {"persona_id": BASURA, "puesto_id": UUID_VALIDO, "vigente_desde": "2026-11-01"}, "persona_id"),
    ("POST", "/api/asignaciones", {"persona_id": UUID_VALIDO, "puesto_id": BASURA, "vigente_desde": "2026-11-01"}, "puesto_id"),
    ("POST", f"/api/asignaciones/{UUID_VALIDO}/cambiar-puesto", {"puesto_nuevo_id": BASURA}, "puesto_nuevo_id"),
    ("POST", "/api/puestos", {"departamento_id": BASURA, "reporta_a_id": UUID_VALIDO, "nombre_puesto": "X"}, "departamento_id"),
    ("POST", "/api/puestos", {"departamento_id": UUID_VALIDO, "reporta_a_id": BASURA, "nombre_puesto": "X"}, "reporta_a_id"),
    ("POST", "/api/departamentos", {"area_id": BASURA, "nombre_departamento": "X"}, "area_id"),
    ("POST", "/api/permisos/otorgar", {"puesto_id": BASURA, "codigo": "x"}, "puesto_id"),
    ("POST", "/api/permisos/revocar", {"puesto_permiso_id": BASURA}, "puesto_permiso_id"),
    ("POST", "/api/usuarios", {"persona_id": BASURA, "correo": "a@example.com"}, "persona_id"),
    ("POST", "/api/marcas/captura-manual", {"evento_id": BASURA, "persona_id": UUID_VALIDO, "terminal_id": "rh-captura-01"}, "evento_id"),
    ("POST", "/api/marcas/captura-manual", {"evento_id": UUID_VALIDO, "persona_id": BASURA, "terminal_id": "rh-captura-01"}, "persona_id"),
]


@pytest.mark.parametrize("metodo,ruta,cuerpo,campo", RUTAS_BODY)
def test_id_de_body_que_no_es_uuid_da_422(cliente, metodo, ruta, cuerpo, campo):
    respuesta = cliente.request(metodo, ruta, json=cuerpo)
    assert respuesta.status_code == 422
    assert _loc_invalido(respuesta, "body", campo)
