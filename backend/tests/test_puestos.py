from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app
from app.routers.puestos import (
    MENSAJE_ADMINISTRADOR_SIN_ACCESO,
    MENSAJE_REACTIVACION_INVALIDA,
    MENSAJE_TIENE_ASIGNACION_VIGENTE,
    MENSAJE_TIENE_PERMISOS_ACTIVOS,
    MENSAJE_TIENE_SUBORDINADOS,
)

DEPARTAMENTO_ID = "55555555-5555-5555-5555-555555555555"
PUESTO_ID = "77777777-7777-7777-7777-777777777777"
SUPERIOR_ID = "88888888-8888-8888-8888-888888888888"

# Ver test_areas.py: el gate real (requiere_permiso) toca usuario/asignacion/puesto_permiso
# ANTES del cuerpo del endpoint -- se prepende siempre a la secuencia de tablas esperada.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _fila_puesto(**overrides):
    fila = {
        "id": PUESTO_ID,
        "departamento_id": DEPARTAMENTO_ID,
        "nombre_puesto": "Ejecutivo de Ventas",
        "nivel": "operativo",
        "plazas_totales": 3,
        "reporta_a_id": SUPERIOR_ID,
        "activo": True,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _tabla_select_simple(datos):
    """MagicMock para una tabla donde el router hace .select(...).eq(...).execute().data
    (una sola cadena .eq)."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_doble_eq(datos):
    """MagicMock para .select(...).eq(...).eq(...).execute().data (dos cadenas .eq, el caso
    de la consulta de subordinados activos, y también el shape de poseedores del gate)."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_eq_is(datos):
    """MagicMock para .select(...).eq(...).is_(...).execute().data (puestos vigentes del gate)."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_insert(datos):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = datos
    return tabla


def _tabla_update(datos):
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _entradas_gate():
    """Las 3 llamadas que hace requiere_permiso ANTES de que el endpoint corra: resolver
    persona_id (usuario), puestos vigentes (asignacion), y el permiso directo (puesto_permiso)
    -- siempre satisfechas, sin importar qué código pida el router, para no interferir con lo
    que cada test prueba de la lógica de negocio propia."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
    """secuencia: lista de (nombre_tabla_esperado, mock_a_devolver), en el orden exacto en que
    el router llama a .table(...). cambiar_estado_puesto hace varias llamadas a .table("puesto")
    con formas distintas (select simple, select doble-eq, update) -- no alcanza con un side_effect
    por nombre de tabla, hace falta uno por posición."""
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


def test_listar_puestos():
    # listar_puestos hace .select(...).order(...).execute().data, no .eq().
    tabla_puesto = MagicMock()
    tabla_puesto.select.return_value.order.return_value.execute.return_value.data = [_fila_puesto()]
    fake_client = _fake_client_secuencia(_entradas_gate() + [("puesto", tabla_puesto)])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/puestos", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()[0]["nombre_puesto"] == "Ejecutivo de Ventas"


def test_alta_puesto_inserta_puesto():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("departamento", _tabla_select_simple([{"id": DEPARTAMENTO_ID, "activo": True}])),
            ("puesto", _tabla_select_simple([{"id": SUPERIOR_ID}])),
            ("puesto", _tabla_insert([_fila_puesto()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["nombre_puesto"] == "Ejecutivo de Ventas"


def test_alta_puesto_departamento_inexistente_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("departamento", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_puesto_departamento_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [("departamento", _tabla_select_simple([{"id": DEPARTAMENTO_ID, "activo": False}]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_puesto_reporta_a_inexistente_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("departamento", _tabla_select_simple([{"id": DEPARTAMENTO_ID, "activo": True}])),
            ("puesto", _tabla_select_simple([])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_obtener_puesto():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("puesto", _tabla_select_simple([_fila_puesto()]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/puestos/{PUESTO_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["id"] == PUESTO_ID


def test_obtener_puesto_no_encontrado():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("puesto", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(f"/api/puestos/{PUESTO_ID}", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_actualizar_puesto_rename_nivel_plazas():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto",
                _tabla_update(
                    [_fila_puesto(nombre_puesto="Gerente de Ventas", nivel="gerencia", plazas_totales=1)]
                ),
            )
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}",
        json={"nombre_puesto": "Gerente de Ventas", "nivel": "gerencia", "plazas_totales": 1},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert cuerpo["nombre_puesto"] == "Gerente de Ventas"
    assert cuerpo["nivel"] == "gerencia"
    assert cuerpo["plazas_totales"] == 1


def test_actualizar_puesto_no_encontrado():
    fake_client = _fake_client_secuencia(_entradas_gate() + [("puesto", _tabla_update([]))])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}",
        json={"nombre_puesto": "Gerente de Ventas", "nivel": "gerencia", "plazas_totales": 1},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_desactivar_puesto_administrador_generico_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": True}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_ADMINISTRADOR_SIN_ACCESO


def test_desactivar_puesto_con_asignacion_vigente_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("asignacion", _tabla_select_eq_is([{"id": "asignacion-vigente-1"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_TIENE_ASIGNACION_VIGENTE


def test_desactivar_puesto_con_permiso_activo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("puesto_permiso", _tabla_select_doble_eq([{"id": "puesto-permiso-1"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_TIENE_PERMISOS_ACTIVOS


def test_desactivar_puesto_con_subordinados_activos_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("puesto_permiso", _tabla_select_doble_eq([])),
            ("puesto", _tabla_select_doble_eq([{"id": "subordinado-1"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_TIENE_SUBORDINADOS


def test_desactivar_puesto_sin_subordinados_devuelve_200():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("puesto_permiso", _tabla_select_doble_eq([])),
            ("puesto", _tabla_select_doble_eq([])),
            ("puesto", _tabla_update([_fila_puesto(activo=False, reporta_a_id=None)])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is False


def test_reactivar_puesto_departamento_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("departamento", _tabla_select_simple([{"activo": False}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_REACTIVACION_INVALIDA


def test_reactivar_puesto_superior_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto",
                _tabla_select_simple(
                    [{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": SUPERIOR_ID, "es_administrador_generico": False}]
                ),
            ),
            ("departamento", _tabla_select_simple([{"activo": True}])),
            ("puesto", _tabla_select_simple([{"activo": False}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == MENSAJE_REACTIVACION_INVALIDA


def test_reactivar_puesto_valido_devuelve_200():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto",
                _tabla_select_simple(
                    [{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": SUPERIOR_ID, "es_administrador_generico": False}]
                ),
            ),
            ("departamento", _tabla_select_simple([{"activo": True}])),
            ("puesto", _tabla_select_simple([{"activo": True}])),
            ("puesto", _tabla_update([_fila_puesto(activo=True)])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is True


def test_reactivar_puesto_tope_sin_superior_devuelve_200():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"departamento_id": DEPARTAMENTO_ID, "reporta_a_id": None, "es_administrador_generico": False}])),
            ("departamento", _tabla_select_simple([{"activo": True}])),
            ("puesto", _tabla_update([_fila_puesto(activo=True, reporta_a_id=None)])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": True},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is True


def test_cambiar_estado_puesto_no_encontrado():
    fake_client = _fake_client_secuencia(_entradas_gate() + [("puesto", _tabla_select_simple([]))])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/puestos/{PUESTO_ID}/estado",
        json={"activo": False},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_alta_puesto_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin puesto_edicion -- el gate debe rechazar antes de
    validar departamento_id/reporta_a_id."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"persona_id": GATE_PERSONA_ID}
            ]
        elif nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": GATE_PUESTO_ID}
            ]
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
        elif nombre_tabla == "permiso":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": False}
            ]
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_puestos_sin_token():
    client = TestClient(app)
    response = client.get("/api/puestos")

    assert response.status_code in (401, 422)


def test_alta_puesto_sin_token():
    client = TestClient(app)
    response = client.post(
        "/api/puestos",
        json={
            "departamento_id": DEPARTAMENTO_ID,
            "reporta_a_id": SUPERIOR_ID,
            "nombre_puesto": "Ejecutivo de Ventas",
            "nivel": "operativo",
            "plazas_totales": 3,
        },
    )

    assert response.status_code in (401, 422)
