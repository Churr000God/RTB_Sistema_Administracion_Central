from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

CALLER_AUTH_USER_ID = "auth-ficticio-caller"
CALLER_PERSONA_ID = "persona-ficticia-caller"
GATE_PUESTO_ID = "puesto-ficticio-gate"

PUESTO_DESTINO_ID = "puesto-ficticio-destino"
PUESTO_PERMISO_ID = "puesto-permiso-ficticio-1"

RAIZ_ID = "puesto-ficticio-raiz"
HIJO_ID = "puesto-ficticio-hijo"
NIETO_ID = "puesto-ficticio-nieto"
OTRO_TOPE_ID = "puesto-ficticio-otro-tope"
OTRO_HIJO_ID = "puesto-ficticio-otro-hijo"

CALLER_IDENTITY = CallerIdentity(auth_user_id=CALLER_AUTH_USER_ID, correo="caller-ficticio@example.com")


def _tabla_select_plana(datos):
    """.select(...).execute().data -- sin ningún .eq/.order (el select-todo de mapa_hijos_por_puesto)."""
    tabla = MagicMock()
    tabla.select.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_simple(datos):
    """.select(...).eq(...).execute().data -- una sola cadena .eq."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_eq_is(datos):
    """.select(...).eq(...).is_(...).execute().data -- puestos vigentes de una persona."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_select_doble_eq(datos):
    """.select(...).eq(...).eq(...).execute().data -- dos cadenas .eq (poseedores del gate,
    o la consulta de "activas" en revocar)."""
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_insert_sin_dato():
    tabla = MagicMock()
    return tabla


def _entradas_gate():
    """Las 3 llamadas que hace requiere_permiso ANTES de que el endpoint corra: resolver
    persona_id (usuario), puestos vigentes (asignacion), y el permiso directo (puesto_permiso)
    -- siempre satisfechas, sin importar qué código pida el router."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": CALLER_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
    """secuencia: lista de (nombre_tabla_esperado, mock_a_devolver), en el orden exacto en que
    el router llama a .table(...). otorgar/revocar encadenan varias tablas distintas (puesto,
    permiso, usuario, asignacion, bitacora, puesto_permiso) con formas de consulta distintas --
    hace falta control por posición, no sólo por nombre."""
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table
    iterador = iter(secuencia)

    def side_effect(nombre_tabla):
        nombre_esperado, mock_tabla = next(iterador)
        assert nombre_tabla == nombre_esperado, f"esperaba tabla {nombre_esperado!r}, llegó {nombre_tabla!r}"
        return mock_tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def _fake_client_get(configuraciones_extra=None):
    """Para los GET (listar_permisos/vigentes/otorgados): el gate y la lógica propia del
    endpoint a veces tocan la MISMA tabla ("puesto_permiso" en /vigentes, "usuario" en
    /otorgados) pero con formas de consulta DISTINTAS (eq+eq del gate vs order/in_ del propio
    endpoint) -- como son atributos distintos sobre el mismo MagicMock, no hace falta
    dispatch posicional: un mock por nombre de tabla, cacheado, con todas las formas que
    necesite configuradas encima."""
    configuraciones_extra = configuraciones_extra or {}
    fake_client = MagicMock()
    tablas: dict[str, MagicMock] = {}

    def obtener_tabla(nombre_tabla):
        if nombre_tabla not in tablas:
            tabla = MagicMock()
            if nombre_tabla == "usuario":
                tabla.select.return_value.eq.return_value.execute.return_value.data = [
                    {"persona_id": CALLER_PERSONA_ID}
                ]
            elif nombre_tabla == "asignacion":
                tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                    {"puesto_id": GATE_PUESTO_ID}
                ]
            elif nombre_tabla == "puesto_permiso":
                tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
                    {"puesto_id": GATE_PUESTO_ID}
                ]
            if nombre_tabla in configuraciones_extra:
                configuraciones_extra[nombre_tabla](tabla)
            tablas[nombre_tabla] = tabla
        return tablas[nombre_tabla]

    fake_client.postgrest.schema.return_value.table.side_effect = obtener_tabla
    return fake_client


def _override_identidad(fake_client):
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    app.dependency_overrides[get_caller_identity] = lambda: CALLER_IDENTITY


def _fila_permiso(**overrides):
    fila = {
        "codigo": "puesto_permiso_edicion",
        "heredable": False,
        "activo": True,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _fila_puesto_permiso(**overrides):
    fila = {
        "id": PUESTO_PERMISO_ID,
        "puesto_id": PUESTO_DESTINO_ID,
        "codigo": "puesto_permiso_edicion",
        "activo": True,
        "creado_en": "2026-08-31T00:00:00+00:00",
        "actualizado_en": "2026-08-31T00:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _cuerpo_otorgar(codigo="permiso_ficticio_uno", puesto_id=PUESTO_DESTINO_ID):
    return {"puesto_id": puesto_id, "codigo": codigo}


def test_listar_permisos():
    def configurar_permiso(tabla):
        tabla.select.return_value.order.return_value.execute.return_value.data = [
            _fila_permiso(codigo="permiso_ficticio_uno"),
            _fila_permiso(codigo="permiso_ficticio_dos", heredable=True),
        ]

    fake_client = _fake_client_get({"permiso": configurar_permiso})
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.get("/api/permisos", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert len(cuerpo) == 2
    assert cuerpo[0]["codigo"] == "permiso_ficticio_uno"


def test_listar_puesto_permiso_vigentes():
    def configurar_puesto_permiso(tabla):
        tabla.select.return_value.order.return_value.execute.return_value.data = [
            {**_fila_puesto_permiso(), "puesto": {"nombre_puesto": "Puesto Ficticio Destino"}}
        ]

    fake_client = _fake_client_get({"puesto_permiso": configurar_puesto_permiso})
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.get("/api/permisos/vigentes", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()[0]
    assert cuerpo["nombre_puesto"] == "Puesto Ficticio Destino"
    assert "puesto" not in cuerpo


def test_listar_otorgados_resuelve_registrado_por_nombre():
    def configurar_bitacora(tabla):
        tabla.select.return_value.order.return_value.execute.return_value.data = [
            {
                "id": "bitacora-ficticia-1",
                "puesto_id": PUESTO_DESTINO_ID,
                "puesto": {"nombre_puesto": "Puesto Ficticio Destino"},
                "codigo": "permiso_ficticio_uno",
                "tipo_movimiento": "otorgado",
                "fecha_efectiva": "2026-08-31T00:00:00+00:00",
                "motivo": None,
                "registrado_por": CALLER_AUTH_USER_ID,
                "creado_en": "2026-08-31T00:00:00+00:00",
            }
        ]

    def configurar_usuario_extra(tabla):
        tabla.select.return_value.in_.return_value.execute.return_value.data = [
            {"auth_user_id": CALLER_AUTH_USER_ID, "nombre_usuario": "caller.ficticio"}
        ]

    fake_client = _fake_client_get(
        {
            "bitacora_movimiento_puesto_permiso": configurar_bitacora,
            "usuario": configurar_usuario_extra,
        }
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.get("/api/permisos/otorgados", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()[0]
    assert cuerpo["nombre_puesto"] == "Puesto Ficticio Destino"
    assert cuerpo["registrado_por_nombre"] == "caller.ficticio"
    assert cuerpo["tipo_movimiento"] == "otorgado"


def test_listar_otorgados_sin_autor_no_crashea():
    def configurar_bitacora(tabla):
        tabla.select.return_value.order.return_value.execute.return_value.data = [
            {
                "id": "bitacora-ficticia-2",
                "puesto_id": PUESTO_DESTINO_ID,
                "puesto": {"nombre_puesto": "Puesto Ficticio Destino"},
                "codigo": "permiso_ficticio_uno",
                "tipo_movimiento": "revocado",
                "fecha_efectiva": "2026-08-31T00:00:00+00:00",
                "motivo": None,
                "registrado_por": None,
                "creado_en": "2026-08-31T00:00:00+00:00",
            }
        ]

    fake_client = _fake_client_get({"bitacora_movimiento_puesto_permiso": configurar_bitacora})
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.get("/api/permisos/otorgados", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()[0]["registrado_por_nombre"] is None


def test_otorgar_puesto_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("puesto", _tabla_select_simple([{"id": PUESTO_DESTINO_ID, "activo": False}]))]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar", json=_cuerpo_otorgar(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_otorgar_permiso_inactivo_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_DESTINO_ID, "activo": True}])),
            ("permiso", _tabla_select_simple([{"codigo": "permiso_ficticio_uno", "heredable": False, "activo": False}])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar", json=_cuerpo_otorgar(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422


def test_otorgar_autootorgamiento_directo_devuelve_422():
    """Permiso NO heredable y el puesto destino es uno de los vigentes del caller."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_DESTINO_ID, "activo": True}])),
            ("permiso", _tabla_select_simple([{"codigo": "permiso_ficticio_uno", "heredable": False, "activo": True}])),
            ("usuario", _tabla_select_simple([{"persona_id": CALLER_PERSONA_ID}])),
            ("asignacion", _tabla_select_eq_is([{"puesto_id": PUESTO_DESTINO_ID}])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar", json=_cuerpo_otorgar(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "vos mismo" in response.json()["detail"]


def test_otorgar_autootorgamiento_por_herencia_en_subarbol_devuelve_422():
    """Permiso heredable y el puesto destino (NIETO) cuelga, dos niveles abajo, de un puesto
    vigente del caller (RAIZ) -- terminaría heredándolo por el organigrama."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": NIETO_ID, "activo": True}])),
            ("permiso", _tabla_select_simple([{"codigo": "permiso_ficticio_heredable", "heredable": True, "activo": True}])),
            ("usuario", _tabla_select_simple([{"persona_id": CALLER_PERSONA_ID}])),
            ("asignacion", _tabla_select_eq_is([{"puesto_id": RAIZ_ID}])),
            (
                "puesto",
                _tabla_select_plana(
                    [
                        {"id": RAIZ_ID, "reporta_a_id": None},
                        {"id": HIJO_ID, "reporta_a_id": RAIZ_ID},
                        {"id": NIETO_ID, "reporta_a_id": HIJO_ID},
                        {"id": OTRO_TOPE_ID, "reporta_a_id": None},
                        {"id": OTRO_HIJO_ID, "reporta_a_id": OTRO_TOPE_ID},
                    ]
                ),
            ),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar",
        json=_cuerpo_otorgar(codigo="permiso_ficticio_heredable", puesto_id=NIETO_ID),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "rodeo del organigrama" in response.json()["detail"]


def test_otorgar_exitoso_no_heredable():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": PUESTO_DESTINO_ID, "activo": True}])),
            ("permiso", _tabla_select_simple([{"codigo": "permiso_ficticio_uno", "heredable": False, "activo": True}])),
            ("usuario", _tabla_select_simple([{"persona_id": CALLER_PERSONA_ID}])),
            ("asignacion", _tabla_select_eq_is([{"puesto_id": "puesto-ficticio-otro-del-caller"}])),
            ("bitacora_movimiento_puesto_permiso", _tabla_insert_sin_dato()),
            ("puesto_permiso", _tabla_select_doble_eq([_fila_puesto_permiso()])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar", json=_cuerpo_otorgar(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["puesto_id"] == PUESTO_DESTINO_ID


def test_otorgar_exitoso_heredable_a_puesto_fuera_del_subarbol():
    """Permiso heredable, destino (OTRO_HIJO) en una rama del organigrama que no cuelga de
    ningún puesto vigente del caller (RAIZ) -- no hay autootorgamiento por herencia."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("puesto", _tabla_select_simple([{"id": OTRO_HIJO_ID, "activo": True}])),
            ("permiso", _tabla_select_simple([{"codigo": "permiso_ficticio_heredable", "heredable": True, "activo": True}])),
            ("usuario", _tabla_select_simple([{"persona_id": CALLER_PERSONA_ID}])),
            ("asignacion", _tabla_select_eq_is([{"puesto_id": RAIZ_ID}])),
            (
                "puesto",
                _tabla_select_plana(
                    [
                        {"id": RAIZ_ID, "reporta_a_id": None},
                        {"id": HIJO_ID, "reporta_a_id": RAIZ_ID},
                        {"id": NIETO_ID, "reporta_a_id": HIJO_ID},
                        {"id": OTRO_TOPE_ID, "reporta_a_id": None},
                        {"id": OTRO_HIJO_ID, "reporta_a_id": OTRO_TOPE_ID},
                    ]
                ),
            ),
            ("bitacora_movimiento_puesto_permiso", _tabla_insert_sin_dato()),
            ("puesto_permiso", _tabla_select_doble_eq([_fila_puesto_permiso(puesto_id=OTRO_HIJO_ID)])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar",
        json=_cuerpo_otorgar(codigo="permiso_ficticio_heredable", puesto_id=OTRO_HIJO_ID),
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["puesto_id"] == OTRO_HIJO_ID


def test_revocar_no_encontrado():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("puesto_permiso", _tabla_select_simple([]))]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/revocar",
        json={"puesto_permiso_id": PUESTO_PERMISO_ID},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_revocar_ultima_fila_activa_de_puesto_permiso_edicion_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto_permiso",
                _tabla_select_simple(
                    [{"id": PUESTO_PERMISO_ID, "puesto_id": PUESTO_DESTINO_ID, "codigo": "puesto_permiso_edicion"}]
                ),
            ),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
            ("puesto_permiso", _tabla_select_doble_eq([{"id": PUESTO_PERMISO_ID}])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/revocar",
        json={"puesto_permiso_id": PUESTO_PERMISO_ID},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "sin nadie que pueda repartir permisos" in response.json()["detail"]


def test_revocar_puesto_administrador_generico_devuelve_422():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto_permiso",
                _tabla_select_simple(
                    [{"id": PUESTO_PERMISO_ID, "puesto_id": PUESTO_DESTINO_ID, "codigo": "permiso_ficticio_uno"}]
                ),
            ),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": True}])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/revocar",
        json={"puesto_permiso_id": PUESTO_PERMISO_ID},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "puesto administrador" in response.json()["detail"]


def test_revocar_exitoso_cuando_quedan_otras_filas_activas():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto_permiso",
                _tabla_select_simple(
                    [{"id": PUESTO_PERMISO_ID, "puesto_id": PUESTO_DESTINO_ID, "codigo": "puesto_permiso_edicion"}]
                ),
            ),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
            (
                "puesto_permiso",
                _tabla_select_doble_eq([{"id": PUESTO_PERMISO_ID}, {"id": "puesto-permiso-ficticio-2"}]),
            ),
            ("bitacora_movimiento_puesto_permiso", _tabla_insert_sin_dato()),
            ("puesto_permiso", _tabla_select_simple([_fila_puesto_permiso(activo=False)])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/revocar",
        json={"puesto_permiso_id": PUESTO_PERMISO_ID},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["activo"] is False


def test_revocar_permiso_no_edicion_no_valida_ultima_fila():
    """Un permiso distinto de puesto_permiso_edicion se puede revocar aunque sea la última
    fila activa -- la protección de "última fila" es específica de ese código."""
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            (
                "puesto_permiso",
                _tabla_select_simple(
                    [{"id": PUESTO_PERMISO_ID, "puesto_id": PUESTO_DESTINO_ID, "codigo": "permiso_ficticio_uno"}]
                ),
            ),
            ("puesto", _tabla_select_simple([{"es_administrador_generico": False}])),
            ("bitacora_movimiento_puesto_permiso", _tabla_insert_sin_dato()),
            ("puesto_permiso", _tabla_select_simple([_fila_puesto_permiso(codigo="permiso_ficticio_uno", activo=False)])),
        ]
    )
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/revocar",
        json={"puesto_permiso_id": PUESTO_PERMISO_ID},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200


def test_otorgar_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin puesto_permiso_edicion -- el gate debe rechazar
    antes de validar puesto/permiso destino."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"persona_id": CALLER_PERSONA_ID}
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
    _override_identidad(fake_client)

    client = TestClient(app)
    response = client.post(
        "/api/permisos/otorgar", json=_cuerpo_otorgar(), headers={"Authorization": "Bearer fake-token"}
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_listar_permisos_sin_token():
    client = TestClient(app)
    response = client.get("/api/permisos")

    assert response.status_code in (401, 422)


def test_otorgar_permiso_sin_token():
    client = TestClient(app)
    response = client.post("/api/permisos/otorgar", json=_cuerpo_otorgar())

    assert response.status_code in (401, 422)
