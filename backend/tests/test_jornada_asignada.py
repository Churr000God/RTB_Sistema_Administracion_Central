from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

PERSONA_ID = "aaaaaaaa-0000-0000-0000-000000000001"
JORNADA_ID = 10

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _payload(**overrides):
    payload = {
        "persona_id": PERSONA_ID,
        "tipo_jornada": "normal",
        "vigente_desde": "2026-01-01",
        "descuento_comida_fija": False,
        "minutos_descuento_comida_fija": None,
        "confirma_cierre_vigente": False,
        "patron_semanal": [
            {
                "dia_semana": "lunes",
                "hora_entrada": "09:00:00",
                "hora_salida": "18:00:00",
                "minutos_comida": 60,
            },
        ],
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


def _tabla_tope_legal(datos):
    tabla = MagicMock()
    (
        tabla.select.return_value.lte.return_value.order.return_value.limit.return_value
        .execute.return_value.data
    ) = datos
    return tabla


def _entradas_gate():
    """requiere_todos_los_permisos exige AND (jornada_asignada_edicion Y patron_semanal_edicion)
    -- tiene_permiso se llama una vez por código, y cada llamada resuelve sus propios puestos
    vigentes (asignacion) + poseedores (puesto_permiso) desde cero, no comparte resultado entre
    llamadas."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
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


def _fila_jornada(**overrides):
    fila = {
        "id": JORNADA_ID,
        "persona_id": PERSONA_ID,
        "tipo_jornada": "normal",
        "vigente_desde": "2026-01-01",
        "vigente_hasta": None,
        "descuento_comida_fija": False,
        "minutos_descuento_comida_fija": None,
        "horas_semanales_calculadas": None,
        "genera_alerta_horario": True,
    }
    fila.update(overrides)
    return fila


def _fila_patron():
    return [
        {
            "id": 1,
            "jornada_asignada_id": JORNADA_ID,
            "dia_semana": "lunes",
            "hora_entrada": "09:00:00",
            "hora_salida": "18:00:00",
            "minutos_comida": 60,
            "horas_efectivas": 8.0,
        }
    ]


def test_asignar_jornada_primera_vez_exitosa():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
            ("patron_semanal", _tabla_select_simple(_fila_patron())),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_jornada()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    cuerpo = response.json()
    assert cuerpo["persona_id"] == PERSONA_ID
    assert cuerpo["patron_semanal"][0]["dia_semana"] == "lunes"
    fake_client.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_jornada_asignar_renovar",
        {
            "p_persona_id": PERSONA_ID,
            "p_tipo_jornada": "normal",
            "p_vigente_desde": "2026-01-01",
            "p_patron_semanal": [
                {
                    "dia_semana": "lunes",
                    "hora_entrada": "09:00:00",
                    "hora_salida": "18:00:00",
                    "minutos_comida": 60,
                }
            ],
            "p_descuento_comida_fija": False,
            "p_minutos_descuento_comida_fija": None,
            "p_confirma_cierre_vigente": False,
        },
    )


def test_asignar_jornada_persona_invalida_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("persona", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_asignar_jornada_vigencia_activa_sin_confirmar_devuelve_409():
    """El RPC revienta con ERRCODE 'SCJ01' (código propio) cuando ya hay vigencia activa y no
    vino confirma_cierre_vigente -- el router lo traduce a 409 con mensaje legible."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ01", "message": "ya existe una jornada vigente para esta persona"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_asignar_jornada_vigencia_desde_invalida_devuelve_422():
    """El RPC revienta con ERRCODE 'SCJ02' cuando la nueva vigencia empieza el mismo día o antes
    que la jornada vigente actual (renovar 2 veces el mismo día calcularía vigente_hasta =
    vigente_desde - 1, quedando ANTES del propio vigente_desde de esa fila) -- el router lo
    traduce a 422 con mensaje legible."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ02", "message": "la nueva vigencia no puede empezar antes de la actual"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas",
        json=_payload(confirma_cierre_vigente=True),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422, response.text
    assert response.json()["detail"] == (
        "La nueva vigencia debe comenzar después de que empezó la jornada actual."
    )


def test_asignar_jornada_vigencia_activa_confirmada_cierra_anterior():
    """Con confirma_cierre_vigente=True, el RPC cierra la vigencia anterior y abre la nueva en
    una sola transacción -- el router sólo reenvía el flag, no arma el cierre él mismo."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
            ("patron_semanal", _tabla_select_simple(_fila_patron())),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_jornada()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas",
        json=_payload(confirma_cierre_vigente=True),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text
    parametros_rpc = fake_client.postgrest.schema.return_value.rpc.call_args[0][1]
    assert parametros_rpc["p_confirma_cierre_vigente"] is True


def test_asignar_jornada_tope_legal_excedido_devuelve_422():
    payload = _payload(
        patron_semanal=[
            {
                "dia_semana": dia,
                "hora_entrada": "08:00:00",
                "hora_salida": "20:00:00",
                "minutos_comida": 0,
            }
            for dia in ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
        ]
    )
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=payload, headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_asignar_jornada_flexible_no_valida_tope_legal():
    """tipo_jornada='flexible' no consulta tope_legal en absoluto (_validar_tope_legal corta
    antes de la query)."""
    payload = _payload(
        tipo_jornada="flexible",
        patron_semanal=[
            {
                "dia_semana": dia,
                "hora_entrada": "08:00:00",
                "hora_salida": "20:00:00",
                "minutos_comida": 0,
            }
            for dia in ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
        ],
    )
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            (
                "patron_semanal",
                _tabla_select_simple(_fila_patron()),
            ),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_jornada(tipo_jornada="flexible", genera_alerta_horario=False)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=payload, headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201, response.text


def test_asignar_jornada_rpc_rechaza_con_otro_codigo_devuelve_422():
    """Cualquier código de error del RPC que no sea SCJ01 (p.ej. el CONSTRAINT TRIGGER de tope
    legal revienta con P0001 si algo bypasseó la validación de la app) sigue el patrón de
    siempre: 422 con error.message crudo."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID}])),
            ("tope_legal", _tabla_tope_legal([{"maximo_semanal": "48.00", "vigente_hasta": None}])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "P0001", "message": "se pasa del tope legal vigente"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_asignar_jornada_horario_invalido_devuelve_422_sin_llegar_a_bd():
    payload = _payload(
        patron_semanal=[
            {
                "dia_semana": "lunes",
                "hora_entrada": "18:00:00",
                "hora_salida": "09:00:00",
                "minutos_comida": 60,
            }
        ]
    )
    fake_client = _fake_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/jornadas-asignadas", json=payload, headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def _fila_jornada_vigente(**overrides):
    fila = {
        "id": JORNADA_ID,
        "persona_id": PERSONA_ID,
        "tipo_jornada": "normal",
        "vigente_desde": "2026-06-01",
        "vigente_hasta": None,
        "descuento_comida_fija": False,
        "minutos_descuento_comida_fija": None,
        "horas_semanales_calculadas": None,
        "genera_alerta_horario": True,
    }
    fila.update(overrides)
    return fila


def _fila_patron_semanal(**overrides):
    fila = {
        "id": 1,
        "jornada_asignada_id": JORNADA_ID,
        "dia_semana": "lunes",
        "hora_entrada": "09:00:00",
        "hora_salida": "18:00:00",
        "minutos_comida": 60,
        "horas_efectivas": None,
    }
    fila.update(overrides)
    return fila


def _entradas_gate_or():
    """requiere_permiso (OR) -- a diferencia de _entradas_gate() (AND, 2 códigos), basta un solo
    tiene_permiso() que resuelve true en el primer código -- una sola vuelta de
    asignacion/puesto_permiso, no dos."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def test_jornada_vigente_de_persona_devuelve_jornada_y_patron():
    fake_client = _fake_client_secuencia(
        _entradas_gate_or()
        + [
            ("jornada_asignada", _tabla_select_eq_is([_fila_jornada_vigente()])),
            ("patron_semanal", _tabla_select_simple([_fila_patron_semanal()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/jornada-vigente",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["tipo_jornada"] == "normal"
    assert len(cuerpo["patron_semanal"]) == 1
    assert cuerpo["patron_semanal"][0]["dia_semana"] == "lunes"


def test_jornada_vigente_de_persona_sin_jornada_devuelve_404():
    fake_client = _fake_client_secuencia(
        _entradas_gate_or() + [("jornada_asignada", _tabla_select_eq_is([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/jornada-vigente",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404
