from datetime import date, timedelta
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app


def _fake_service_client_config(limite_valor: str | None = None, festivos: list | None = None):
    """tiempo.parametro/tiempo.dia_festivo -- config global que _validar_ventana lee con
    service_role vía app/dias_habiles.py (helper compartido con routers/marcas.py). Sin este
    fake, get_service_client(get_settings()) construiría un cliente real contra el Supabase de
    .env y pegaría de verdad -- CLAUDE.md exige que ningún test lo haga."""
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
    """Autouse: todo test de este módulo pasa por _validar_ventana (llama a
    get_service_client incondicionalmente para leer dias_habiles_correccion_marca) -- se
    parchea con un fake por defecto (sin fila -> cae al valor de ejemplo, 30) para que ningún
    test golpee Supabase real. Los tests que necesiten un valor/festivos específicos usan su
    propio `with patch(...)` puntual, que sobreescribe este durante su alcance."""
    with patch(
        "app.dias_habiles.get_service_client",
        return_value=_fake_service_client_config(),
    ):
        yield


MARCA_ID = 7
PERSONA_ID = "persona-caller"
PUESTO_ID = "puesto-caller"
CORRECCION_ID = 3
CALLER_IDENTITY = CallerIdentity(auth_user_id="auth-caller", correo="caller@example.com")

HOY_ISO = f"{date.today().isoformat()}T09:00:00+00:00"
HACE_100_DIAS_ISO = f"{(date.today() - timedelta(days=100)).isoformat()}T09:00:00+00:00"


def _payload(**overrides):
    payload = {
        "marca_id": MARCA_ID,
        "valor_corregido": "2026-01-01T09:05:00+00:00",
        "motivo": "reloj no sincronizado",
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


def _tabla_insert(fila):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = [fila]
    return tabla


def _tabla_insert_error(error):
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = error
    return tabla


def _entradas_gate_correccion_edicion():
    """usuario -> resolver_persona_id; asignacion -> puestos vigentes; puesto_permiso -> posee
    el código directo (tiene_permiso corta ahí, sin consultar 'permiso'/'puesto')."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),
    ]


def _entradas_gate_reapertura_denegada():
    """AND real: correccion_edicion SIEMPRE se chequea primero (lo tiene), y ADEMÁS
    excepcion_reapertura al reabrir una excepción resuelta (no lo tiene, y no es heredable --
    tiene_permiso corta después de leer 'permiso', sin llegar a 'puesto'). resolver_puestos_
    vigentes ('asignacion') se vuelve a consultar en cada llamada a tiene_permiso, no se cachea."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),  # correccion_edicion: sí
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([])),  # excepcion_reapertura: no
        ("permiso", _tabla_select_simple([{"heredable": False}])),
    ]


def _entradas_gate_reapertura_concedida():
    """AND real, ambos permisos concedidos por poseedor directo -- ninguna de las dos llamadas
    necesita caer al chequeo de heredable/hijos."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),  # correccion_edicion: sí
        ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": PUESTO_ID}])),  # excepcion_reapertura: sí
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


def _fila_correccion(**overrides):
    fila = {
        "id": CORRECCION_ID,
        "marca_id": MARCA_ID,
        "valor_corregido": "2026-01-01T09:05:00+00:00",
        "motivo": "reloj no sincronizado",
        "autor_id": PERSONA_ID,
        "creado_en": "2026-01-01T09:10:00+00:00",
    }
    fila.update(overrides)
    return fila


def test_corregir_marca_con_excepcion_pendiente_exitosa():
    fake_client = _fake_client_secuencia(
        [
            ("marca", _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}])),
            ("excepcion", _tabla_select_simple([{"estado": "pendiente"}])),
        ]
        + _entradas_gate_correccion_edicion()
        + [("correccion", _tabla_insert(_fila_correccion()))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    assert response.json()["autor_id"] == PERSONA_ID


def test_corregir_marca_no_encontrada_devuelve_404():
    fake_client = _fake_client_secuencia([("marca", _tabla_select_simple([]))])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_corregir_marca_sin_excepcion_devuelve_422():
    fake_client = _fake_client_secuencia(
        [
            ("marca", _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}])),
            ("excepcion", _tabla_select_simple([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_corregir_marca_excepcion_resuelta_sin_permiso_reapertura_devuelve_403():
    fake_client = _fake_client_secuencia(
        [
            ("marca", _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}])),
            ("excepcion", _tabla_select_simple([{"estado": "resuelto"}])),
        ]
        + _entradas_gate_reapertura_denegada()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403
    assert "excepcion_reapertura" in response.json()["detail"]


def test_corregir_marca_excepcion_resuelta_con_permiso_reapertura_exitosa():
    fake_client = _fake_client_secuencia(
        [
            ("marca", _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}])),
            ("excepcion", _tabla_select_simple([{"estado": "resuelto"}])),
        ]
        + _entradas_gate_reapertura_concedida()
        + [("correccion", _tabla_insert(_fila_correccion()))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text


def test_corregir_marca_ventana_vencida_devuelve_422():
    """El fixture autouse ya cubre get_service_client (sin fila de parametro -> cae al valor de
    ejemplo, 30) -- 100 días de por medio los supera de sobra sin necesidad de un mock puntual."""
    fake_client = _fake_client_secuencia(
        [
            (
                "marca",
                _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HACE_100_DIAS_ISO}]),
            ),
            ("excepcion", _tabla_select_simple([{"estado": "pendiente"}])),
        ]
        + _entradas_gate_correccion_edicion()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "30" in response.json()["detail"]


def test_corregir_marca_trigger_rechaza_orden_cronologico_devuelve_422_legible():
    fake_client = _fake_client_secuencia(
        [
            ("marca", _tabla_select_simple([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}])),
            ("excepcion", _tabla_select_simple([{"estado": "pendiente"}])),
        ]
        + _entradas_gate_correccion_edicion()
        + [
            (
                "correccion",
                _tabla_insert_error(
                    APIError(
                        {
                            "code": "P0001",
                            "message": (
                                "La corrección de la marca 7 rompería el orden cronológico: "
                                "2026-01-01 09:05:00+00 no es posterior a la marca anterior"
                            ),
                        }
                    )
                ),
            )
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "rompería el orden cronológico" not in response.json()["detail"]
    assert "no se puede reordenar" in response.json()["detail"]
