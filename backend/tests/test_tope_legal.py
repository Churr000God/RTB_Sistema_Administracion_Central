from datetime import date
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")

SEMANA_DE = date(2026, 9, 7)  # lunes
SEMANA_HASTA = date(2026, 9, 13)

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "aaaaaaaa-0000-0000-0000-000000000002"


# ---------------------------------------------------------------------------
# Helpers de gate (mismo estilo que test_corridas_batch.py/test_jornada_asignada.py)
# ---------------------------------------------------------------------------


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


def _entradas_gate():
    """requiere_permiso (OR) resuelve true en el primer código -- una sola vuelta de
    asignacion/puesto_permiso alcanza cuando el caller SÍ tiene el permiso."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_caller_client_secuencia(secuencia):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    iterador = iter(secuencia)

    def side_effect(nombre_tabla):
        nombre_esperado, mock_tabla = next(iterador)
        assert nombre_tabla == nombre_esperado, f"esperaba tabla {nombre_esperado!r}, llegó {nombre_tabla!r}"
        return mock_tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def _tabla_puesto_permiso_por_codigo(codigos_con_permiso):
    """Discrimina por el código pedido -- necesario para probar que 'sólo lectura' no alcanza
    para un endpoint que exige 'edicion' (a diferencia de _entradas_gate(), que no distingue)."""
    tabla = MagicMock()

    def eq_codigo(campo, valor):
        siguiente = MagicMock()
        tiene = valor in codigos_con_permiso
        siguiente.eq.return_value.execute.return_value.data = (
            [{"puesto_id": GATE_PUESTO_ID}] if tiene else []
        )
        return siguiente

    tabla.select.return_value.eq.side_effect = eq_codigo
    return tabla


def _fake_caller_client_con_permisos(codigos_con_permiso):
    """Dispatch por nombre de tabla (no por orden estricto) -- soporta que tiene_alguno() haga
    tantas vueltas de asignacion/puesto_permiso/permiso como códigos le falten al caller."""

    def side_effect(nombre_tabla):
        if nombre_tabla == "usuario":
            return _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])
        if nombre_tabla == "asignacion":
            return _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])
        if nombre_tabla == "puesto_permiso":
            return _tabla_puesto_permiso_por_codigo(codigos_con_permiso)
        if nombre_tabla == "permiso":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"heredable": False}
            ]
            return tabla
        return MagicMock()

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


def _limpiar():
    app.dependency_overrides.clear()


# ---------------------------------------------------------------------------
# GET /api/tope-legal
# ---------------------------------------------------------------------------


def test_listar_tope_legal_devuelve_historial_desc():
    tabla_tope = MagicMock()
    tabla_tope.select.return_value.order.return_value.execute.return_value.data = [
        {"id": 2, "vigente_desde": "2026-06-01", "vigente_hasta": None, "maximo_semanal": 48.0, "maximo_extra": 10.0},
        {"id": 1, "vigente_desde": "2026-01-01", "vigente_hasta": "2026-05-31", "maximo_semanal": 44.0, "maximo_extra": 8.0},
    ]
    fake_caller = _fake_caller_client_secuencia(_entradas_gate() + [("tope_legal", tabla_tope)])
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.table.return_value = tabla_tope
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/tope-legal", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert len(cuerpo) == 2
    assert cuerpo[0]["id"] == 2


def test_listar_tope_legal_sin_ninguno_de_los_2_permisos_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.get("/api/tope-legal", headers={"Authorization": "Bearer fake-token"})

    _limpiar()
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# POST /api/tope-legal
# ---------------------------------------------------------------------------


def _payload(**overrides):
    payload = {
        "vigente_desde": "2026-09-07",
        "maximo_semanal": 48.0,
        "maximo_extra": 10.0,
        "confirma_cierre_vigente": False,
    }
    payload.update(overrides)
    return payload


def _fila_tope_legal(**overrides):
    fila = {
        "id": 3,
        "vigente_desde": "2026-09-07",
        "vigente_hasta": None,
        "maximo_semanal": 48.0,
        "maximo_extra": 10.0,
    }
    fila.update(overrides)
    return fila


def test_crear_tope_legal_caso_feliz_201():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_tope_legal()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 201, response.text
    assert response.json()["maximo_semanal"] == 48.0
    fake_service.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_tope_legal_crear_vigencia",
        {
            "p_vigente_desde": "2026-09-07",
            "p_maximo_semanal": 48.0,
            "p_maximo_extra": 10.0,
            "p_confirma_cierre_vigente": False,
        },
    )


def test_crear_tope_legal_vigencia_activa_sin_confirmar_devuelve_409():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ01", "message": "ya existe un tope legal vigente"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 409


def test_crear_tope_legal_confirmando_cierre_201():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_tope_legal()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal",
        json=_payload(confirma_cierre_vigente=True),
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 201, response.text


def test_crear_tope_legal_otro_codigo_apierror_devuelve_422():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = MagicMock()
    fake_service.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "23514", "message": "violates check constraint"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 422


def test_crear_tope_legal_sin_tope_legal_edicion_devuelve_403():
    """tope_legal_lectura sola no alcanza -- el POST exige específicamente tope_legal_edicion."""
    fake_caller = _fake_caller_client_con_permisos({"tope_legal_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )

    _limpiar()
    assert response.status_code == 403


def test_crear_tope_legal_maximo_semanal_no_positivo_devuelve_422():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    client = TestClient(app)
    response = client.post(
        "/api/tope-legal",
        json=_payload(maximo_semanal=0),
        headers={"Authorization": "Bearer fake-token"},
    )

    _limpiar()
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# GET /api/tope-legal/exceso-semanal
# ---------------------------------------------------------------------------


def _dia(id_, persona_id, fecha, estado):
    return {"id": id_, "persona_id": persona_id, "fecha": fecha, "estado": estado}


def _tramo(id_, dia_id, minutos):
    return {"id": id_, "dia_id": dia_id, "minutos_trabajados": minutos}


def _clasificacion(tramo_id, tipo):
    return {"tramo_id": tramo_id, "tipo": tipo}


def _servicio_exceso_semanal(tope, dias, tramos, clasificaciones, personas_nombres=None):
    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "tope_legal":
            (
                tabla.select.return_value.lte.return_value.order.return_value.limit.return_value
                .execute.return_value.data
            ) = tope
        elif nombre_tabla == "dia":
            tabla.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = dias
        elif nombre_tabla == "tramo":
            tabla.select.return_value.in_.return_value.execute.return_value.data = tramos
        elif nombre_tabla == "clasificacion_de_tiempo":
            tabla.select.return_value.in_.return_value.execute.return_value.data = clasificaciones
        elif nombre_tabla == "persona":
            tabla.select.return_value.in_.return_value.execute.return_value.data = personas_nombres or []
        return tabla

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _pedir_exceso_semanal(**params):
    params.setdefault("semana_de", SEMANA_DE.isoformat())
    client = TestClient(app)
    return client.get(
        "/api/tope-legal/exceso-semanal",
        params=params,
        headers={"Authorization": "Bearer fake-token"},
    )


TOPE_ESTANDAR = [{"maximo_semanal": 48.0, "maximo_extra": 10.0, "vigente_hasta": None}]


def test_exceso_semanal_no_lunes_devuelve_422():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_exceso_semanal(semana_de="2026-09-08")  # martes

    _limpiar()
    assert response.status_code == 422


def test_exceso_semanal_sin_tope_vigente_devuelve_listado_vacio():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(tope=[], dias=[], tramos=[], clasificaciones=[])
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["maximo_semanal"] is None
    assert cuerpo["maximo_extra"] is None
    assert cuerpo["personas"] == []


def test_exceso_semanal_persona_con_dia_abierto_se_excluye_semana_completa():
    dias = [
        _dia(1, PERSONA_1, "2026-09-07", "cerrado"),
        _dia(2, PERSONA_1, "2026-09-08", "abierto"),  # basta uno para excluir toda la semana
    ]
    # Tramo gigante que, si se contara, dispararía cualquier tope -- no debe aparecer.
    tramos = [_tramo(10, 1, 60 * 100)]
    clasificaciones = [_clasificacion(10, "ordinario")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["personas"] == []


def test_exceso_semanal_persona_con_dia_bloqueado_se_excluye_semana_completa():
    dias = [
        _dia(1, PERSONA_1, "2026-09-07", "cerrado"),
        _dia(2, PERSONA_1, "2026-09-08", "bloqueado"),
    ]
    tramos = [_tramo(10, 1, 60 * 100)]
    clasificaciones = [_clasificacion(10, "ordinario")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.json()["personas"] == []


def test_exceso_semanal_persona_sin_ninguna_fila_dia_no_aparece_sin_error():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias=[], tramos=[], clasificaciones=[])
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["personas"] == []


def test_persona_supera_solo_semanal():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [_tramo(10, 1, 50 * 60)]  # 50h ordinarias
    clasificaciones = [_clasificacion(10, "ordinario")]
    personas_nombres = [{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones, personas_nombres)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    personas = response.json()["personas"]
    assert len(personas) == 1
    persona = personas[0]
    assert persona["persona_nombre"] == "Ana Pérez"
    assert persona["supera_semanal"] is True
    assert persona["supera_extra"] is False
    assert persona["supera_combinado"] is False
    assert persona["exceso_semanal"] == 2.0
    assert persona["exceso_extra"] is None
    assert persona["exceso_combinado"] is None


def test_persona_supera_solo_extra():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [_tramo(10, 1, 40 * 60), _tramo(11, 1, 15 * 60)]
    clasificaciones = [_clasificacion(10, "ordinario"), _clasificacion(11, "extra")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    persona = response.json()["personas"][0]
    assert persona["supera_semanal"] is False
    assert persona["supera_extra"] is True
    assert persona["supera_combinado"] is False
    assert persona["exceso_extra"] == 5.0


def test_supera_extra_y_combinado_simultaneo_sin_superar_semanal():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [_tramo(10, 1, 45 * 60), _tramo(11, 1, 20 * 60)]
    clasificaciones = [_clasificacion(10, "ordinario"), _clasificacion(11, "extra")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    persona = response.json()["personas"][0]
    assert persona["supera_semanal"] is False
    assert persona["supera_extra"] is True
    assert persona["supera_combinado"] is True
    assert persona["exceso_combinado"] == 7.0


def test_tramo_sin_clasificacion_se_ignora():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [
        _tramo(10, 1, 10 * 60),  # clasificado, cuenta
        _tramo(11, 1, 1000 * 60),  # sin clasificación -- debe ignorarse por completo
    ]
    clasificaciones = [_clasificacion(10, "ordinario")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    # 10h ordinarias, muy por debajo del tope -- si el tramo sin clasificar se hubiera contado,
    # esto dispararía la alerta.
    assert response.json()["personas"] == []


def test_reposicion_alta_no_dispara_nada():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [_tramo(10, 1, 5 * 60), _tramo(11, 1, 100 * 60)]
    clasificaciones = [_clasificacion(10, "ordinario"), _clasificacion(11, "reposicion")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.json()["personas"] == []


def test_persona_con_reposicion_y_exceso_expone_las_tres_horas():
    dias = [_dia(1, PERSONA_1, "2026-09-07", "cerrado")]
    tramos = [_tramo(10, 1, 50 * 60), _tramo(11, 1, 20 * 60)]
    clasificaciones = [_clasificacion(10, "ordinario"), _clasificacion(11, "reposicion")]

    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias, tramos, clasificaciones)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    persona = response.json()["personas"][0]
    assert persona["supera_semanal"] is True
    assert persona["horas_ordinarias"] == 50.0
    assert persona["horas_reposicion"] == 20.0
    assert persona["exceso_semanal"] == 2.0


def test_exceso_semanal_nunca_usa_caller_client_para_leer_datos():
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _servicio_exceso_semanal(TOPE_ESTANDAR, dias=[], tramos=[], clasificaciones=[])
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.status_code == 200, response.text
    tablas_pedidas_al_caller = {
        llamada.args[0]
        for llamada in fake_caller.postgrest.schema.return_value.table.call_args_list
    }
    assert tablas_pedidas_al_caller == {"usuario", "asignacion", "puesto_permiso"}
    assert "tope_legal" not in tablas_pedidas_al_caller
    assert "dia" not in tablas_pedidas_al_caller
    assert "tramo" not in tablas_pedidas_al_caller


def test_exceso_semanal_sin_ninguno_de_los_2_permisos_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_exceso_semanal()

    _limpiar()
    assert response.status_code == 403
