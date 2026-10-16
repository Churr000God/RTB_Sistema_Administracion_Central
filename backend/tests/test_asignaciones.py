import pytest
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

PERSONA_ID = "aaaaaaaa-0000-0000-0000-000000000001"
PUESTO_ID = "bbbbbbbb-0000-0000-0000-000000000002"
PUESTO_NUEVO_ID = "bbbbbbbb-0000-0000-0000-000000000003"
ASIGNACION_ID = "cccccccc-0000-0000-0000-000000000004"

# Ver test_areas.py: el gate real (requiere_permiso) toca usuario/asignacion/puesto_permiso
# ANTES del cuerpo del endpoint -- se prepende siempre a la secuencia de tablas esperada. Ojo:
# este router usa "asignacion" tanto para el gate como para su propia lógica de negocio (plazas
# ocupadas) -- la secuencia POSICIONAL es la que distingue una llamada de la otra, no el nombre.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _fila_asignacion_plana(**overrides):
    fila = {
        "id": ASIGNACION_ID,
        "persona_id": PERSONA_ID,
        "puesto_id": PUESTO_ID,
        "vigente_desde": "2026-01-01",
        "vigente_hasta": None,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _fila_asignacion_con_embed(**overrides):
    fila = {
        "id": ASIGNACION_ID,
        "persona_id": PERSONA_ID,
        "puesto_id": PUESTO_ID,
        "vigente_desde": "2026-01-01",
        "vigente_hasta": None,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
        "persona": {"primer_nombre": "Ficticia", "apellido_paterno": "Alfa"},
        "puesto": {
            "nombre_puesto": "Puesto Ficticio Alfa",
            "departamento": {
                "nombre_departamento": "Departamento Ficticio Alfa",
                "area": {"nombre_area": "Área Ficticia Alfa"},
            },
        },
    }
    fila.update(overrides)
    return fila


def _tabla_select_simple(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_eq_is(datos):
    """.select(...).eq(...).is_(...).execute().data -- plazas ocupadas / puestos vigentes."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_doble_eq(datos):
    """.select(...).eq(...).eq(...).execute().data -- poseedores del gate."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_insert(datos):
    tabla = MagicMock()
    tabla.insert.return_value.execute.return_value.data = datos
    return tabla


def _tabla_insert_error(error):
    tabla = MagicMock()
    tabla.insert.return_value.execute.side_effect = error
    return tabla


def _tabla_update(datos):
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _entradas_gate():
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
    """secuencia: lista de (nombre_tabla_esperado, mock_a_devolver), en el orden exacto en que
    el router llama a .table(...). alta/cambiar-puesto encadenan varias tablas distintas
    (persona, puesto, asignacion) con formas de consulta distintas -- hace falta control por
    posición, no sólo por nombre."""
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


def test_listar_asignaciones_con_detalle_aplanado():
    tabla_asignacion = MagicMock()
    tabla_asignacion.select.return_value.order.return_value.execute.return_value.data = [
        _fila_asignacion_con_embed(),
    ]
    fake_client = _fake_client_secuencia(_entradas_gate() + [("asignacion", tabla_asignacion)])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/asignaciones", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()[0]
    assert cuerpo["persona_nombre"] == "Ficticia Alfa"
    assert cuerpo["nombre_puesto"] == "Puesto Ficticio Alfa"
    assert cuerpo["nombre_departamento"] == "Departamento Ficticio Alfa"
    assert cuerpo["nombre_area"] == "Área Ficticia Alfa"
    assert "persona" not in cuerpo
    assert "puesto" not in cuerpo


def test_obtener_asignacion_no_encontrada():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("asignacion", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.get(
        f"/api/asignaciones/{ASIGNACION_ID}", headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def _cuerpo_alta():
    return {
        "persona_id": PERSONA_ID,
        "puesto_id": PUESTO_ID,
        "vigente_desde": "2026-01-01",
    }


def test_alta_asignacion_exitosa():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([{"id": "otra-asignacion"}])),
            ("asignacion", _tabla_insert([_fila_asignacion_plana()])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["persona_id"] == PERSONA_ID


def test_alta_asignacion_persona_inactiva_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "baja_definitiva"}]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_asignacion_puesto_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": False, "plazas_totales": 2}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_asignacion_plazas_llenas_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 1}])),
            ("asignacion", _tabla_select_eq_is([{"id": "otra-asignacion"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_alta_asignacion_vigente_duplicada_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            (
                "asignacion",
                _tabla_insert_error(
                    APIError(
                        {
                            "code": "23505",
                            "message": 'duplicate key value violates unique constraint "ux_asignacion_vigente_persona_puesto"',
                        }
                    )
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_terminar_asignacion_ya_cerrada_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("asignacion", _tabla_select_simple([{"vigente_hasta": "2026-06-01"}]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/asignaciones/{ASIGNACION_ID}/terminar",
        json={"vigente_hasta": "2026-07-01"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_terminar_asignacion_no_encontrada():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("asignacion", _tabla_select_simple([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/asignaciones/{ASIGNACION_ID}/terminar",
        json={"vigente_hasta": "2026-07-01"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_terminar_asignacion_exitosa():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("asignacion", _tabla_select_simple([{"puesto_id": PUESTO_ID, "vigente_hasta": None}])),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
            ("asignacion", _tabla_update([_fila_asignacion_plana(vigente_hasta="2026-07-01")])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/asignaciones/{ASIGNACION_ID}/terminar",
        json={"vigente_hasta": "2026-07-01"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["vigente_hasta"] == "2026-07-01"


def test_terminar_asignacion_puesto_administrador_generico_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("asignacion", _tabla_select_simple([{"puesto_id": PUESTO_ID, "vigente_hasta": None}])),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": True}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/asignaciones/{ASIGNACION_ID}/terminar",
        json={"vigente_hasta": "2026-07-01"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def _cuerpo_cambiar_puesto():
    return {"puesto_nuevo_id": PUESTO_NUEVO_ID, "fecha": "2026-07-01"}


def test_cambiar_puesto_destino_invalido_devuelve_422():
    fake_client = _fake_client_secuencia(_entradas_gate() + [("puesto", _tabla_select_simple([]))])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_cambiar_puesto_destino_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": False, "plazas_totales": 2}]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_cambiar_puesto_plazas_llenas_en_destino_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 1}])),
            ("asignacion", _tabla_select_eq_is([{"id": "otra-asignacion"}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_cambiar_puesto_rpc_con_asignacion_cerrada_o_inexistente_devuelve_422():
    """El RPC rechaza con RAISE EXCEPTION (SQLSTATE por omisión P0001) cuando la asignación
    origen no existe o ya está cerrada -- postgrest-py lo propaga como APIError."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_select_simple([])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "P0001", "message": "La asignación no existe o ya está cerrada."}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == "La asignación no existe o ya está cerrada."


def test_cambiar_puesto_rpc_con_error_desconocido_devuelve_mensaje_generico_y_no_el_de_la_base():
    """Cualquier código distinto del único caso deliberado (P0001) cae al mensaje genérico fijo; el texto real va al log."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_select_simple([])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "XX999", "message": "TEXTO-DE-LA-BASE-id-9931"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert response.json()["detail"] == "La operación no se pudo completar; revisa los datos o avisa a Sistemas."
    assert "9931" not in response.text and "cerrada" not in response.text  # ni el texto de la base ni el caso P0001


def test_cambiar_puesto_exitoso_rpc_devuelve_dict_plano():
    """fn_asignacion_cambiar_puesto RETURNS personas.asignacion (fila única, no SETOF) --
    PostgREST/postgrest-py devuelve resultado.data como dict plano, no lista de un elemento."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_select_simple([{"puesto_id": PUESTO_ID}])),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = _fila_asignacion_plana(
        puesto_id=PUESTO_NUEVO_ID
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["puesto_id"] == PUESTO_NUEVO_ID
    fake_client.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_asignacion_cambiar_puesto",
        {
            "p_asignacion_id": ASIGNACION_ID,
            "p_puesto_nuevo_id": PUESTO_NUEVO_ID,
            "p_fecha": "2026-07-01",
        },
    )


def test_cambiar_puesto_origen_administrador_generico_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_select_simple([{"puesto_id": PUESTO_ID}])),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": True}])),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto",
        json=_cuerpo_cambiar_puesto(),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_alta_asignacion_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin asignacion_edicion -- el gate debe rechazar
    antes de validar persona/puesto."""
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
        "/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_asignaciones_sin_token():
    client = TestClient(app)
    response = client.get("/api/asignaciones")

    assert response.status_code in (401, 422)


def test_alta_asignacion_sin_token():
    client = TestClient(app)
    response = client.post("/api/asignaciones", json=_cuerpo_alta())

    assert response.status_code in (401, 422)


# --- terminar con fecha anterior al inicio, errores nuevos de 113_ y mensaje del 403 -----------------------------------------------------------------

from app.routers import asignaciones as router_asignaciones  # noqa: E402


def _terminar(secuencia, fecha="2026-05-01"):
    fake_client = _fake_client_secuencia(_entradas_gate() + secuencia)
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).patch(
            f"/api/asignaciones/{ASIGNACION_ID}/terminar", json={"vigente_hasta": fecha}, headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    return r, fake_client


def _previo_terminar(vigente_desde="2026-06-01"):
    return [
        ("asignacion", _tabla_select_simple([{"puesto_id": PUESTO_ID, "vigente_hasta": None, "vigente_desde": vigente_desde}])),
        ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
    ]


def test_terminar_con_fecha_anterior_al_inicio_es_422_claro_y_no_escribe():
    escritura = MagicMock()
    r, _ = _terminar(_previo_terminar() + [("asignacion", escritura)])
    assert r.status_code == 422 and r.json()["detail"] == "La fecha de término no puede ser anterior al inicio de la asignación."
    escritura.update.assert_not_called()                                           # se valida en Python ANTES de escribir


def test_terminar_el_mismo_dia_del_inicio_si_se_permite():
    r, _ = _terminar(_previo_terminar("2026-05-01") + [("asignacion", _tabla_update([_fila_asignacion_plana(vigente_hasta="2026-05-01")]))])
    assert r.status_code == 200


def test_terminar_si_el_check_de_la_base_salta_igual_es_el_mismo_422_fijo():
    error = APIError({"code": "23514", "message": 'new row for relation "asignacion" violates check constraint "ck_asignacion_vigencia"', "details": "Failing row contains (valor-real)"})
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.side_effect = error
    r, _ = _terminar(_previo_terminar("2026-04-01") + [("asignacion", tabla)])
    assert r.status_code == 422 and r.json()["detail"] == router_asignaciones.MENSAJE_TERMINO_ANTERIOR_AL_INICIO
    assert "ck_asignacion_vigencia" not in r.text and "Failing row" not in r.text


def test_terminar_otro_check_es_422_generico_y_otro_error_se_propaga():
    tabla = MagicMock()
    tabla.update.return_value.eq.return_value.execute.side_effect = APIError({"code": "23514", "message": 'violates check constraint "ck_otro"', "details": "x"})
    r, _ = _terminar(_previo_terminar("2026-04-01") + [("asignacion", tabla)])
    assert r.status_code == 422 and "ck_otro" not in r.text
    tabla2 = MagicMock()
    tabla2.update.return_value.eq.return_value.execute.side_effect = APIError({"code": "XX000", "message": "boom"})
    r2, _ = _terminar(_previo_terminar("2026-04-01") + [("asignacion", tabla2)])
    assert r2.status_code == 500 and "boom" not in r2.text


def _error_113(tipo):
    c = router_asignaciones
    codigo, hint = (c.CODIGO_AUTOASIGNACION, c.HINT_AUTOASIGNACION) if tipo == "auto" else (c.CODIGO_INICIO_FUTURO, c.HINT_INICIO_FUTURO)
    return APIError({"code": codigo, "message": "TEXTO INTERNO de la base con ids", "hint": hint, "details": "detalle interno"})


ESPERADO_113 = {"auto": router_asignaciones.MENSAJE_AUTOASIGNACION, "futuro": router_asignaciones.MENSAJE_INICIO_FUTURO}


@pytest.mark.parametrize("tipo", ["auto", "futuro"])
def test_alta_mapea_los_rechazos_de_113_a_422_fijo_sin_texto_de_la_base(tipo):
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_insert_error(_error_113(tipo))),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post("/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 422 and r.json()["detail"] == ESPERADO_113[tipo]
    assert "TEXTO INTERNO" not in r.text and "detalle interno" not in r.text


@pytest.mark.parametrize("tipo", ["auto", "futuro"])
def test_cambiar_puesto_mapea_los_rechazos_de_113_a_422_fijo_sin_texto_de_la_base(tipo):
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
            ("asignacion", _tabla_select_eq_is([])),
            ("asignacion", _tabla_select_simple([])),
        ]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = _error_113(tipo)
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post(
            f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto", json=_cuerpo_cambiar_puesto(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 422 and r.json()["detail"] == ESPERADO_113[tipo]
    assert "TEXTO INTERNO" not in r.text


def test_un_codigo_parecido_pero_con_otro_hint_no_se_confunde_con_los_de_113():
    parecido = APIError({"code": router_asignaciones.CODIGO_AUTOASIGNACION, "message": "x", "hint": "otro_hint"})
    assert router_asignaciones._traducir_error_de_113(parecido) is None
    assert router_asignaciones._traducir_error_de_113(APIError({"code": "P0001", "message": "x"})) is None


def test_el_403_de_las_asignaciones_es_tuteo_y_sin_el_codigo_de_permiso():
    fake_client = MagicMock()

    def tabla(nombre):
        t = MagicMock()
        if nombre == "usuario":
            t.select.return_value.eq.return_value.execute.return_value.data = [{"persona_id": GATE_PERSONA_ID}]
        elif nombre == "asignacion":
            t.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [{"puesto_id": GATE_PUESTO_ID}]
        elif nombre == "puesto_permiso":
            t.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
        elif nombre == "permiso":
            t.select.return_value.eq.return_value.execute.return_value.data = [{"heredable": False}]
        return t

    fake_client.postgrest.schema.return_value.table.side_effect = tabla
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        cliente = TestClient(app)
        respuestas = [
            cliente.get("/api/asignaciones", headers={"Authorization": "Bearer t"}),
            cliente.get(f"/api/asignaciones/{ASIGNACION_ID}", headers={"Authorization": "Bearer t"}),
            cliente.post("/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer t"}),
            cliente.patch(f"/api/asignaciones/{ASIGNACION_ID}/terminar", json={"vigente_hasta": "2026-07-01"}, headers={"Authorization": "Bearer t"}),
            cliente.post(f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto", json=_cuerpo_cambiar_puesto(), headers={"Authorization": "Bearer t"}),
        ]
    finally:
        app.dependency_overrides.clear()
    for r in respuestas:
        assert r.status_code == 403 and r.json()["detail"] == "No tienes permiso para esta acción."
        assert "asignacion_edicion" not in r.text and "asignacion_lectura" not in r.text and "tenés" not in r.text


def test_requiere_permiso_sin_mensaje_conserva_el_texto_historico_de_los_demas_routers():
    from app.permisos import requiere_permiso

    assert requiere_permiso("area_edicion") is not None and requiere_permiso("area_edicion", mensaje="x") is not None


def test_los_codigos_de_113_son_los_reales():
    c = router_asignaciones
    assert (c.CODIGO_PLAZAS_LLENAS, c.HINT_PLAZAS_LLENAS) == ("SCJ21", "plazas_llenas")
    assert (c.CODIGO_AUTOASIGNACION, c.HINT_AUTOASIGNACION) == ("SCJ19", "autoasignacion_no_permitida")
    assert (c.CODIGO_INICIO_FUTURO, c.HINT_INICIO_FUTURO) == ("SCJ20", "vigencia_futura_no_permitida")


def _cliente_con_postgrest_real(secuencia_previa, respuesta_http, final: str):
    """Gate/validaciones con mocks y la ÚLTIMA operación (insert en `asignacion` o el RPC) con la librería postgrest-py REAL sobre un transporte httpx simulado: el APIError que ve el
    router es el que arma la librería a partir de la respuesta de PostgREST, no uno armado a mano."""
    import httpx
    from postgrest import SyncPostgrestClient

    peticiones = []

    def servidor(request: httpx.Request) -> httpx.Response:
        peticiones.append(request)
        return respuesta_http

    http = httpx.Client(transport=httpx.MockTransport(servidor), base_url="https://scj.ejemplo.test/rest/v1")
    real = SyncPostgrestClient("https://scj.ejemplo.test/rest/v1", schema="personas", http_client=http)
    iterador = iter(secuencia_previa)
    esquema = MagicMock()

    def tabla(nombre):
        try:
            esperado, mock_tabla = next(iterador)
        except StopIteration:
            assert final == "insert" and nombre == "asignacion"
            return real.table("asignacion")
        assert nombre == esperado
        return mock_tabla

    esquema.table.side_effect = tabla
    esquema.rpc = real.rpc
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value = esquema
    return fake_client, peticiones


def _respuesta_113(codigo, hint):
    import httpx

    return httpx.Response(400, json={"code": codigo, "details": "detalle interno con ids", "hint": hint, "message": "TEXTO INTERNO de la base con ids"})


@pytest.mark.parametrize("codigo,hint,esperado", [
    ("SCJ19", "autoasignacion_no_permitida", "No puedes asignarte, cambiarte ni reabrirte una asignación a ti mismo; lo hace otra persona con permiso."),
    ("SCJ20", "vigencia_futura_no_permitida", "La fecha de inicio no puede ser futura."),
    ("SCJ21", "plazas_llenas", "El puesto no tiene plazas libres."),
])
def test_alta_con_el_apierror_real_de_postgrest_py_para_scj19_y_scj20(codigo, hint, esperado):
    previo = _entradas_gate() + [
        ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
        ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 2}])),
        ("asignacion", _tabla_select_eq_is([])),
    ]
    fake_client, peticiones = _cliente_con_postgrest_real(previo, _respuesta_113(codigo, hint), "insert")
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post("/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 422 and r.json()["detail"] == esperado
    assert "TEXTO INTERNO" not in r.text and "detalle interno" not in r.text
    assert len(peticiones) == 1 and peticiones[0].method == "POST" and peticiones[0].url.path.endswith("/asignacion")
    assert peticiones[0].headers.get("content-profile") == "personas"


@pytest.mark.parametrize("codigo,hint,esperado", [
    ("SCJ19", "autoasignacion_no_permitida", "No puedes asignarte, cambiarte ni reabrirte una asignación a ti mismo; lo hace otra persona con permiso."),
    ("SCJ20", "vigencia_futura_no_permitida", "La fecha de inicio no puede ser futura."),
    ("SCJ21", "plazas_llenas", "El puesto no tiene plazas libres."),
])
def test_cambiar_puesto_con_el_apierror_real_de_postgrest_py_para_scj19_y_scj20(codigo, hint, esperado):
    previo = _entradas_gate() + [
        ("puesto", _tabla_select_simple([{"id": PUESTO_NUEVO_ID, "activo": True, "plazas_totales": 2}])),
        ("asignacion", _tabla_select_eq_is([])),
        ("asignacion", _tabla_select_simple([])),
    ]
    fake_client, peticiones = _cliente_con_postgrest_real(previo, _respuesta_113(codigo, hint), "rpc")
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post(
            f"/api/asignaciones/{ASIGNACION_ID}/cambiar-puesto", json=_cuerpo_cambiar_puesto(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 422 and r.json()["detail"] == esperado
    assert "TEXTO INTERNO" not in r.text and "detalle interno" not in r.text
    assert len(peticiones) == 1 and peticiones[0].url.path.endswith("/rpc/fn_asignacion_cambiar_puesto")


def test_el_mensaje_de_scj19_cubre_asignar_cambiar_y_reabrir():
    m = router_asignaciones.MENSAJE_AUTOASIGNACION
    assert m == "No puedes asignarte, cambiarte ni reabrirte una asignación a ti mismo; lo hace otra persona con permiso."
    assert "asignarte" in m and "cambiarte" in m and "reabrirte" in m


@pytest.mark.parametrize("codigo,hint", [
    ("SCJ21", "otro_hint"), ("SCJ21", None), ("SCJ19", "plazas_llenas"), ("SCJ20", "plazas_llenas"), ("P0001", "plazas_llenas"), ("23505", "plazas_llenas"),
])
def test_un_error_de_otro_codigo_o_hint_no_se_confunde_con_plazas_llenas(codigo, hint):
    error = APIError({"code": codigo, "message": "x", "hint": hint})
    traduccion = router_asignaciones._traducir_error_de_113(error)
    assert traduccion is None or traduccion.detail != router_asignaciones.MENSAJE_PLAZAS_LLENAS


def test_scj21_con_otro_hint_en_el_alta_no_se_traduce_a_plazas_llenas_y_se_propaga_sin_texto():
    previo = _entradas_gate() + [
        ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
        ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 2}])),
        ("asignacion", _tabla_select_eq_is([])),
    ]
    fake_client, _ = _cliente_con_postgrest_real(previo, _respuesta_113("SCJ21", "hint_de_otra_cosa"), "insert")
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post("/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 500 and "plazas" not in r.text and "TEXTO INTERNO" not in r.text


def test_la_comprobacion_previa_de_plazas_en_python_se_conserva():
    """El trigger de 115_ es la red de seguridad de la carrera; el caso normal (puesto lleno) sigue dando el mismo 422 ANTES de insertar."""
    insercion = MagicMock()
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("persona", _tabla_select_simple([{"id": PERSONA_ID, "estado": "activo"}])),
            ("puesto", _tabla_select_simple([{"id": PUESTO_ID, "activo": True, "plazas_totales": 1}])),
            ("asignacion", _tabla_select_eq_is([{"id": "ocupada"}])),
            ("asignacion", insercion),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        r = TestClient(app, raise_server_exceptions=False).post("/api/asignaciones", json=_cuerpo_alta(), headers={"Authorization": "Bearer fake-token"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 422 and r.json()["detail"] == "El puesto no tiene plazas libres."
    insercion.insert.assert_not_called()
