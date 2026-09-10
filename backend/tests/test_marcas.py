from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app
from app.routers.marcas import (
    MENSAJE_MOMENTO_FUTURO,
    MENSAJE_VENTANA_VENCIDA,
    _desfase_local_en,
)

EVENTO_ID = "11111111-1111-1111-1111-111111111111"
PERSONA_ID = "aaaaaaaa-0000-0000-0000-000000000001"
MARCA_ID = 42

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _payload(**overrides):
    payload = {
        "evento_id": EVENTO_ID,
        "persona_id": PERSONA_ID,
        "terminal_id": "rh-captura-01",
    }
    payload.update(overrides)
    return payload


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


def _tabla_marca_select(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_excepcion_select(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _tabla_marca_lista(datos, total):
    """El builder real encadena select/eq/gte/lte/order/range antes de execute() -- cada método
    devuelve el mismo builder (self), sólo execute() corta la cadena."""
    tabla = MagicMock()
    tabla.select.return_value = tabla
    tabla.eq.return_value = tabla
    tabla.gte.return_value = tabla
    tabla.lte.return_value = tabla
    tabla.order.return_value = tabla
    tabla.range.return_value = tabla
    resultado = MagicMock()
    resultado.data = datos
    resultado.count = total
    tabla.execute.return_value = resultado
    return tabla


def _tabla_in(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_in_order(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.order.return_value.execute.return_value.data = datos
    return tabla


def _fake_service_client_config(limite_valor: str | None = None, festivos: list | None = None):
    """tiempo.parametro/tiempo.dia_festivo -- config global que _validar_momento_dispositivo lee
    con service_role vía app/dias_habiles.py (helper compartido con routers/correcciones.py).
    Mismo fake que tests/test_correcciones.py, sin él get_service_client(get_settings())
    pegaría contra el Supabase real de .env."""
    fake = MagicMock()
    tabla_parametro = MagicMock()
    (
        tabla_parametro.select.return_value.eq.return_value.lte.return_value.order.return_value
        .limit.return_value.execute.return_value.data
    ) = [{"valor": limite_valor}] if limite_valor is not None else []
    tabla_festivo = MagicMock()
    tabla_festivo.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = (
        festivos or []
    )

    def table_side_effect(nombre):
        return {"parametro": tabla_parametro, "dia_festivo": tabla_festivo}[nombre]

    fake.postgrest.schema.return_value.table.side_effect = table_side_effect
    return fake


@pytest.fixture(autouse=True)
def _sin_red_real_para_ventana():
    """Autouse: sólo entra en juego cuando el test manda momento_dispositivo explícito (None se
    resuelve a ahora() sin pasar por _validar_momento_dispositivo). Por defecto cae al valor de
    ejemplo (30 días hábiles) sin festivos -- los tests que necesiten otro valor usan su propio
    `with patch(...)` puntual."""
    with patch(
        "app.dias_habiles.get_service_client",
        return_value=_fake_service_client_config(),
    ):
        yield


def _tabla_marca_insert():
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [{}]
    return tabla


def _tabla_marca_insert_conflicto():
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = APIError(
        {"code": "23505", "message": "duplicate key value violates uq_marca_evento_id"}
    )
    return tabla


def _entradas_gate():
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
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
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _fila_marca(**overrides):
    fila = {
        "id": MARCA_ID,
        "evento_id": EVENTO_ID,
        "requiere_revision": False,
        "momento_dispositivo": "2026-09-06T12:00:00+00:00",
        "momento_recepcion": "2026-09-06T12:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _fila_marca_lista(**overrides):
    fila = {
        "id": MARCA_ID,
        "evento_id": EVENTO_ID,
        "persona_id": PERSONA_ID,
        "terminal_id": "rh-captura-01",
        "secuencia_local": None,
        "momento_dispositivo": "2026-09-06T12:00:00+00:00",
        "momento_recepcion": "2026-09-06T12:00:00+00:00",
        "desfase_local": "-06:00",
        "estado_reloj": "sincronizado",
        "version_software": "0.1.0",
        "origen": "captura_manual",
        "requiere_revision": False,
    }
    fila.update(overrides)
    return fila


def test_listar_marcas_devuelve_pagina_con_nombre_persona_resuelto():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_lista([_fila_marca_lista()], total=1)),
            (
                "persona",
                _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]),
            ),
            ("correccion", _tabla_in_order([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/marcas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    assert cuerpo["marcas"][0]["persona_nombre"] == "Ana Pérez"
    assert cuerpo["marcas"][0]["momento_efectivo"] == cuerpo["marcas"][0]["momento_dispositivo"]
    assert cuerpo["marcas"][0]["estado_revision"] == "sin_revision"


def test_listar_marcas_acepta_filtros_de_persona_fecha_hora_y_paginado():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_lista([_fila_marca_lista()], total=1)),
            (
                "persona",
                _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]),
            ),
            ("correccion", _tabla_in_order([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        "/api/marcas",
        params={
            "persona_id": PERSONA_ID,
            "desde": "2026-09-01T00:00:00",
            "hasta": "2026-09-06T23:59:59",
            "limite": 10,
            "desplazamiento": 20,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text


def test_listar_marcas_sin_resultados_no_consulta_nombres_de_persona():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_lista([], total=0)),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/marcas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "marcas": []}


def test_listar_marcas_limite_fuera_de_rango_devuelve_422():
    fake_client = _fake_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        "/api/marcas", params={"limite": 500}, headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_captura_manual_exitosa_sin_revision():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),  # busca evento_id -- no existe
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("marca", _tabla_marca_insert()),
            ("marca", _tabla_marca_select([_fila_marca()])),  # relectura post-trigger
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    cuerpo = response.json()
    assert cuerpo["evento_id"] == EVENTO_ID
    assert cuerpo["duplicado"] is False
    assert cuerpo["requiere_revision"] is False
    assert cuerpo["motivos_revision"] == []


def test_captura_manual_con_revision_devuelve_motivos():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("marca", _tabla_marca_insert()),
            ("marca", _tabla_marca_select([_fila_marca(requiere_revision=True)])),
            (
                "excepcion",
                _tabla_excepcion_select(
                    [{"motivo_revision": "persona_inactiva"}, {"motivo_revision": "dia_cerrado"}]
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    cuerpo = response.json()
    assert cuerpo["requiere_revision"] is True
    assert cuerpo["motivos_revision"] == ["persona_inactiva", "dia_cerrado"]


def test_captura_manual_evento_id_ya_existente_es_idempotente_200():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([_fila_marca()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json()["duplicado"] is True


def test_captura_manual_carrera_en_insert_es_idempotente_200():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("marca", _tabla_marca_insert_conflicto()),
            ("marca", _tabla_marca_select([_fila_marca()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json()["duplicado"] is True


def test_captura_manual_persona_invalida_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_captura_manual_terminal_id_vacio_devuelve_422_sin_llegar_a_bd():
    fake_client = _fake_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual",
        json=_payload(terminal_id=""),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_captura_manual_con_hora_pasada_valida_se_persiste_tal_cual():
    """El instante que declara el dispositivo no se pisa con now() -- SCJ-CDT-01 §VII.3."""
    momento = datetime.now(timezone.utc) - timedelta(hours=2)
    momento_iso = momento.isoformat()
    tabla_insert = _tabla_marca_insert()
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("marca", tabla_insert),
            (
                "marca",
                _tabla_marca_select([_fila_marca(momento_dispositivo=momento_iso)]),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual",
        json=_payload(momento_dispositivo=momento_iso),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    cuerpo = response.json()
    assert datetime.fromisoformat(cuerpo["momento_dispositivo"].replace("Z", "+00:00")) == momento

    insertado = tabla_insert.insert.call_args.args[0]
    assert insertado["momento_dispositivo"] == momento_iso
    assert insertado["desfase_local"] == _desfase_local_en(momento)
    assert insertado["momento_recepcion"] != momento_iso


def test_captura_manual_momento_dispositivo_futuro_devuelve_422():
    momento_futuro = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual",
        json=_payload(momento_dispositivo=momento_futuro),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_MOMENTO_FUTURO


def test_captura_manual_momento_dispositivo_fuera_de_ventana_dias_habiles_devuelve_422():
    """Fixture autouse cae al valor de ejemplo (30 días hábiles) -- 100 días de por medio lo
    supera de sobra, mismo criterio que test_correcciones.py::test_corregir_marca_ventana_vencida
    _devuelve_422."""
    hace_100_dias = (datetime.now(timezone.utc) - timedelta(days=100)).isoformat()
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_select([])),
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/marcas/captura-manual",
        json=_payload(momento_dispositivo=hace_100_dias),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_VENTANA_VENCIDA.format(dias=30)


def test_listar_marcas_con_revision_trae_motivos_desde_excepcion():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "marca",
                _tabla_marca_lista(
                    [_fila_marca_lista(requiere_revision=True)], total=1
                ),
            ),
            (
                "persona",
                _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]),
            ),
            (
                "excepcion",
                _tabla_in_order(
                    [
                        {
                            "id": 900,
                            "marca_id": MARCA_ID,
                            "motivo_revision": "persona_inactiva",
                            "estado": "pendiente",
                        }
                    ]
                ),
            ),
            (
                "correccion",
                _tabla_in_order(
                    [
                        {
                            "marca_id": MARCA_ID,
                            "valor_corregido": "2026-09-06T12:15:00+00:00",
                            "creado_en": "2026-09-06T13:00:00+00:00",
                        }
                    ]
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/marcas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["marcas"][0]["motivos_revision"] == ["persona_inactiva"]
    assert cuerpo["marcas"][0]["excepcion_pendiente_id"] == 900
    assert cuerpo["marcas"][0]["estado_revision"] == "pendiente"
    assert cuerpo["marcas"][0]["momento_efectivo"] == "2026-09-06T12:15:00Z"
    assert cuerpo["marcas"][0]["momento_efectivo"] != cuerpo["marcas"][0]["momento_dispositivo"]


def test_listar_marcas_con_excepcion_ya_resuelta_no_expone_pendiente():
    """requiere_revision es de una sola vía -- el motivo histórico se sigue mostrando, pero
    excepcion_pendiente_id debe ser None porque ya no hay nada que corregir."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "marca",
                _tabla_marca_lista(
                    [_fila_marca_lista(requiere_revision=True)], total=1
                ),
            ),
            (
                "persona",
                _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]),
            ),
            (
                "excepcion",
                _tabla_in_order(
                    [
                        {
                            "id": 901,
                            "marca_id": MARCA_ID,
                            "motivo_revision": "persona_inactiva",
                            "estado": "resuelto",
                        }
                    ]
                ),
            ),
            ("correccion", _tabla_in_order([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/marcas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["marcas"][0]["motivos_revision"] == ["persona_inactiva"]
    assert cuerpo["marcas"][0]["excepcion_pendiente_id"] is None
    assert cuerpo["marcas"][0]["estado_revision"] == "resuelta"


def test_listar_marcas_sin_excepciones_excepcion_pendiente_id_es_none():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("marca", _tabla_marca_lista([_fila_marca_lista()], total=1)),
            (
                "persona",
                _tabla_in([{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]),
            ),
            ("correccion", _tabla_in_order([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/marcas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json()["marcas"][0]["estado_revision"] == "sin_revision"
    cuerpo = response.json()
    assert cuerpo["marcas"][0]["excepcion_pendiente_id"] is None
