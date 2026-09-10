from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

EXCEPCION_ID = 11
MARCA_ID = 7
PERSONA_ID = "aaaaaaaa-0000-0000-0000-000000000001"
PUESTO_ID = "puesto-caller"
CALLER_IDENTITY = CallerIdentity(auth_user_id="auth-caller", correo="caller@example.com")


def _tabla_select_simple(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_eq_is(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_doble_eq(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_excepcion_listar(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _tabla_in(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _entradas_gate():
    """requiere_permiso("excepcion_lectura", "excepcion_edicion") es OR -- basta con
    excepcion_edicion (lo que RH/Gerente General realmente tienen)."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": "persona-gate"}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    iterador = iter(secuencia)

    def side_effect(nombre_tabla):
        nombre_esperado, mock_tabla = next(iterador)
        assert nombre_tabla == nombre_esperado, f"esperaba tabla {nombre_esperado!r}, llegó {nombre_tabla!r}"
        return mock_tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: CALLER_IDENTITY


def _fila_excepcion(**overrides):
    fila = {
        "id": EXCEPCION_ID,
        "marca_id": MARCA_ID,
        "dia_id": None,
        "motivo_revision": "fuera_de_horario",
        "estado": "pendiente",
        "creado_en": "2026-01-01T09:10:00+00:00",
    }
    fila.update(overrides)
    return fila


def test_listar_excepciones_pendientes_resuelve_persona_y_momento():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("excepcion", _tabla_excepcion_listar([_fila_excepcion()])),
            (
                "marca",
                _tabla_in([{"id": MARCA_ID, "persona_id": PERSONA_ID, "momento_dispositivo": "2026-01-01T09:00:00+00:00"}]),
            ),
            ("persona", _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ficticia", "apellido_paterno": "Alfa"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/excepciones", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()[0]
    assert cuerpo["persona_nombre"] == "Ficticia Alfa"
    assert cuerpo["momento_dispositivo"] == "2026-01-01T09:00:00Z"
    assert cuerpo["persona_id"] == PERSONA_ID


def test_listar_excepciones_sin_ninguna_no_consulta_marca_ni_persona():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("excepcion", _tabla_excepcion_listar([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/excepciones", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json() == []


def test_obtener_excepcion_resuelta_tambien_devuelve_detalle():
    """Reabrir (SCJ-PRO-10 §II.3) también necesita precargar el formulario -- sin filtro de
    estado."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("excepcion", _tabla_select_simple([_fila_excepcion(estado="resuelto")])),
            (
                "marca",
                _tabla_in([{"id": MARCA_ID, "persona_id": PERSONA_ID, "momento_dispositivo": "2026-01-01T09:00:00+00:00"}]),
            ),
            ("persona", _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ficticia", "apellido_paterno": "Alfa"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/excepciones/{EXCEPCION_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json()["estado"] == "resuelto"
    assert response.json()["persona_nombre"] == "Ficticia Alfa"


def test_obtener_excepcion_no_encontrada_devuelve_404():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("excepcion", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/excepciones/{EXCEPCION_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 404
