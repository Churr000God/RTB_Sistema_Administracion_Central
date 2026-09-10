from datetime import date
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
DIA_ID = 42


# ---------------------------------------------------------------------------
# Helpers de gate
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


def _entradas_gate_or():
    """requiere_permiso (OR) -- basta una vuelta de asignacion/puesto_permiso."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _entradas_gate_and():
    """requiere_todos_los_permisos (AND, dia_lectura Y marca_lectura) -- tiene_permiso se llama
    una vez por código, cada una resuelve puestos vigentes + poseedores desde cero."""
    return _entradas_gate_or() + [
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
# Helpers de dato (service client para GET /api/dias)
# ---------------------------------------------------------------------------


def _tabla_encadenada(datos, total=None):
    """select/in_/gte/lte/eq/order/range/or_/limit encadenan sobre el mismo builder (self) --
    sólo execute() corta la cadena, así que da igual qué combinación de filtros se haya
    aplicado."""
    tabla = MagicMock()
    for metodo in ("select", "in_", "gte", "lte", "eq", "order", "range", "or_", "limit"):
        getattr(tabla, metodo).return_value = tabla
    resultado = MagicMock()
    resultado.data = datos
    resultado.count = total if total is not None else len(datos)
    tabla.execute.return_value = resultado
    return tabla


def _tabla_persona(busqueda_ids=None, nombres=None):
    tabla = MagicMock()
    tabla.select.return_value.or_.return_value.execute.return_value.data = (
        [{"id": pid} for pid in busqueda_ids] if busqueda_ids is not None else []
    )
    tabla.select.return_value.in_.return_value.execute.return_value.data = nombres or []
    return tabla


def _tabla_persona_in(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_excepcion(pendientes_por_marca=None, pendientes_por_dia=None):
    """_resolver_excepciones_pendientes hace dos consultas contra la misma tabla, distintas sólo
    por la columna pedida en select() -- 'marca_id' o 'dia_id'. Se distinguen por eso."""
    tabla = MagicMock()

    def select_side_effect(columna):
        siguiente = MagicMock()
        if columna == "marca_id":
            datos = [{"marca_id": marca_id} for marca_id in (pendientes_por_marca or [])]
        else:
            datos = [{"dia_id": dia_id} for dia_id in (pendientes_por_dia or [])]
        siguiente.in_.return_value.eq.return_value.execute.return_value.data = datos
        return siguiente

    tabla.select.side_effect = select_side_effect
    return tabla


def _fake_service_client(**tablas):
    defaults = {
        "dia": _tabla_encadenada([], total=0),
        "persona": _tabla_persona(nombres=[]),
        "marca": _tabla_encadenada([]),
        "correccion": _tabla_encadenada([]),
        "jornada_asignada": _tabla_encadenada([]),
        "patron_semanal": _tabla_encadenada([]),
        "parametro": _tabla_encadenada([]),
        "excepcion": _tabla_excepcion(),
    }
    defaults.update({nombre: tabla for nombre, tabla in tablas.items() if tabla is not None})

    def side_effect(nombre_tabla):
        return defaults.get(nombre_tabla, MagicMock())

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _fila_dia(**overrides):
    fila = {
        "id": DIA_ID,
        "persona_id": PERSONA_1,
        "fecha": "2026-09-08",  # martes
        "estado": "cerrado",
        "horas_totales": 8.0,
        "origen": None,
    }
    fila.update(overrides)
    return fila


def _fila_jornada(**overrides):
    fila = {
        "id": 10,
        "persona_id": PERSONA_1,
        "tipo_jornada": "normal",
        "genera_alerta_horario": True,
        "vigente_desde": "2026-01-01",
        "vigente_hasta": None,
    }
    fila.update(overrides)
    return fila


def _fila_patron(dia_semana="martes", hora_entrada="08:00:00", hora_salida="17:00:00"):
    return {
        "jornada_asignada_id": 10,
        "dia_semana": dia_semana,
        "hora_entrada": hora_entrada,
        "hora_salida": hora_salida,
    }


def _fila_marca(marca_id=1, momento="2026-09-08T14:15:00+00:00", desfase="-06:00"):
    return {
        "id": marca_id,
        "persona_id": PERSONA_1,
        "momento_dispositivo": momento,
        "desfase_local": desfase,
    }


def _preparar(tabla_dia=None, **otras_tablas):
    fake_caller = _fake_caller_client_secuencia(_entradas_gate_and())
    fake_service = _fake_service_client(dia=tabla_dia, **otras_tablas)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()
    return fake_caller, fake_service


def _pedir_dias(**params):
    client = TestClient(app)
    return client.get("/api/dias", params=params, headers={"Authorization": "Bearer fake-token"})


# ---------------------------------------------------------------------------
# GET /api/dias -- listado
# ---------------------------------------------------------------------------


def test_listar_dias_devuelve_pagina_con_nombre_resuelto_sin_marcas():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_persona = _tabla_persona(nombres=[{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}])
    _preparar(tabla_dia=tabla_dia, persona=tabla_persona)

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    dia = cuerpo["dias"][0]
    assert dia["persona_nombre"] == "Ana Pérez"
    assert dia["primera_marca"] is None
    assert dia["ultima_marca"] is None
    assert dia["alerta_entrada"] is None
    assert dia["alerta_salida"] is None


def test_listar_dias_acepta_filtros_orden_y_paginacion():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    _preparar(tabla_dia=tabla_dia)

    response = _pedir_dias(
        desde="2026-01-01",
        hasta="2026-12-31",
        orden="horas_asc",
        limite=10,
        desplazamiento=20,
    )

    _limpiar()
    assert response.status_code == 200, response.text
    tabla_dia.gte.assert_called_once_with("fecha", "2026-01-01")
    tabla_dia.lte.assert_called_once_with("fecha", "2026-12-31")
    tabla_dia.order.assert_called_once_with("horas_totales", desc=False)
    tabla_dia.range.assert_called_once_with(20, 29)


def test_listar_dias_filtro_estado():
    tabla_dia = _tabla_encadenada([_fila_dia(estado="bloqueado")], total=1)
    _preparar(tabla_dia=tabla_dia)

    response = _pedir_dias(estado="bloqueado")

    _limpiar()
    assert response.status_code == 200, response.text
    tabla_dia.eq.assert_called_once_with("estado", "bloqueado")


def test_listar_dias_busqueda_sin_coincidencias_no_consulta_dia():
    tabla_persona = _tabla_persona(busqueda_ids=[])
    fake_caller, fake_service = _preparar(persona=tabla_persona)

    response = _pedir_dias(busqueda_persona="nadie-existe")

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "dias": []}
    tablas_pedidas = {
        llamada.args[0]
        for llamada in fake_service.postgrest.schema.return_value.table.call_args_list
    }
    assert "dia" not in tablas_pedidas


def test_listar_dias_limite_fuera_de_rango_devuelve_422():
    _preparar()

    response = _pedir_dias(limite=500)

    _limpiar()
    assert response.status_code == 422


def test_listar_dias_sin_dia_lectura_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos({"marca_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 403


def test_listar_dias_con_dia_lectura_pero_sin_marca_lectura_devuelve_403():
    """El AND: un solo código no alcanza."""
    fake_caller = _fake_caller_client_con_permisos({"dia_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# GET /api/dias -- enriquecido (alertas_horario)
# ---------------------------------------------------------------------------


def test_listar_dias_con_retardo_y_salida_a_tiempo():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_marca = _tabla_encadenada(
        [
            _fila_marca(1, "2026-09-08T14:15:00+00:00"),  # local 08:15 -> retardo
            _fila_marca(2, "2026-09-08T23:00:00+00:00"),  # local 17:00 -> a tiempo
        ]
    )
    tabla_jornada = _tabla_encadenada([_fila_jornada()])
    tabla_patron = _tabla_encadenada([_fila_patron()])
    _preparar(
        tabla_dia=tabla_dia, marca=tabla_marca, jornada_asignada=tabla_jornada, patron_semanal=tabla_patron
    )

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 200, response.text
    dia = response.json()["dias"][0]
    assert dia["alerta_entrada"] == "retardo"
    assert dia["alerta_salida"] is None
    assert dia["primera_marca"] == "2026-09-08T14:15:00Z"
    assert dia["ultima_marca"] == "2026-09-08T23:00:00Z"


def test_listar_dias_correccion_mueve_primera_marca_y_desaparece_la_alerta():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:30:00+00:00")])  # local 08:30
    tabla_correccion = _tabla_encadenada(
        [{"marca_id": 1, "valor_corregido": "2026-09-08T14:00:00+00:00", "creado_en": "2026-09-08T15:00:00+00:00"}]
    )
    tabla_jornada = _tabla_encadenada([_fila_jornada()])
    tabla_patron = _tabla_encadenada([_fila_patron()])
    _preparar(
        tabla_dia=tabla_dia,
        marca=tabla_marca,
        correccion=tabla_correccion,
        jornada_asignada=tabla_jornada,
        patron_semanal=tabla_patron,
    )

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 200, response.text
    dia = response.json()["dias"][0]
    assert dia["primera_marca"] == "2026-09-08T14:00:00Z"
    assert dia["alerta_entrada"] is None


def test_listar_dias_correccion_cruza_medianoche_cambia_de_dia():
    """Una corrección puede mover una marca de un día calendario a otro (gap real que
    alertas_de_retardo.py no cubre) -- fn_correccion_valida no lo impide, sólo exige quedar entre
    las marcas vecinas de la persona."""
    dia_08 = _fila_dia(id=1, fecha="2026-09-08")
    dia_09 = _fila_dia(id=2, fecha="2026-09-09")
    tabla_dia = _tabla_encadenada([dia_08, dia_09], total=2)
    # Cruda: 2026-09-09T05:50 UTC - 6h = 2026-09-08 23:50 local.
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-09T05:50:00+00:00")])
    # Corregida: 2026-09-09T06:10 UTC - 6h = 2026-09-09 00:10 local -- cruzó a otro día.
    tabla_correccion = _tabla_encadenada(
        [{"marca_id": 1, "valor_corregido": "2026-09-09T06:10:00+00:00", "creado_en": "2026-09-08T23:59:59+00:00"}]
    )
    _preparar(tabla_dia=tabla_dia, marca=tabla_marca, correccion=tabla_correccion)

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 200, response.text
    dias_por_fecha = {dia["fecha"]: dia for dia in response.json()["dias"]}
    assert dias_por_fecha["2026-09-08"]["primera_marca"] is None
    assert dias_por_fecha["2026-09-09"]["primera_marca"] == "2026-09-09T06:10:00Z"


def test_listar_dias_genera_alerta_horario_false_suprime_alertas():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:15:00+00:00")])  # retardo si se evaluara
    tabla_jornada = _tabla_encadenada([_fila_jornada(genera_alerta_horario=False)])
    tabla_patron = _tabla_encadenada([_fila_patron()])
    _preparar(
        tabla_dia=tabla_dia, marca=tabla_marca, jornada_asignada=tabla_jornada, patron_semanal=tabla_patron
    )

    response = _pedir_dias()

    _limpiar()
    dia = response.json()["dias"][0]
    assert dia["alerta_entrada"] is None
    assert dia["primera_marca"] == "2026-09-08T14:15:00Z"  # la marca se sigue mostrando


def test_listar_dias_sin_patron_ese_dia_suprime_alertas():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)  # 2026-09-08 = martes
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:15:00+00:00")])
    tabla_jornada = _tabla_encadenada([_fila_jornada()])
    tabla_patron = _tabla_encadenada([_fila_patron(dia_semana="lunes")])  # ningún patrón el martes
    _preparar(
        tabla_dia=tabla_dia, marca=tabla_marca, jornada_asignada=tabla_jornada, patron_semanal=tabla_patron
    )

    response = _pedir_dias()

    _limpiar()
    dia = response.json()["dias"][0]
    assert dia["alerta_entrada"] is None
    assert dia["alerta_salida"] is None


def test_listar_dias_origen_ausencia_autorizada_suprime_alertas():
    tabla_dia = _tabla_encadenada([_fila_dia(origen="ausencia_autorizada")], total=1)
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:15:00+00:00")])
    tabla_jornada = _tabla_encadenada([_fila_jornada()])
    tabla_patron = _tabla_encadenada([_fila_patron()])
    _preparar(
        tabla_dia=tabla_dia, marca=tabla_marca, jornada_asignada=tabla_jornada, patron_semanal=tabla_patron
    )

    response = _pedir_dias()

    _limpiar()
    dia = response.json()["dias"][0]
    assert dia["alerta_entrada"] is None
    assert dia["alerta_salida"] is None


def test_listar_dias_estado_revisado_no_suprime_alertas():
    """Divergencia intencional con alertas_de_retardo.py, que sí oculta el día revisado."""
    tabla_dia = _tabla_encadenada([_fila_dia(estado="revisado")], total=1)
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:15:00+00:00")])
    tabla_jornada = _tabla_encadenada([_fila_jornada()])
    tabla_patron = _tabla_encadenada([_fila_patron()])
    _preparar(
        tabla_dia=tabla_dia, marca=tabla_marca, jornada_asignada=tabla_jornada, patron_semanal=tabla_patron
    )

    response = _pedir_dias()

    _limpiar()
    dia = response.json()["dias"][0]
    assert dia["alerta_entrada"] == "retardo"


def test_listar_dias_excepciones_pendientes_suma_marca_y_dia():
    """2 pendientes vía marca (marcas 1 y 2, ambas del mismo día) + 1 pendiente vía dia_id directo
    (ej. paridad_impar, SCJ-PRO-08) -> 3 en total."""
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_marca = _tabla_encadenada(
        [
            _fila_marca(1, "2026-09-08T14:00:00+00:00"),
            _fila_marca(2, "2026-09-08T23:00:00+00:00"),
        ]
    )
    tabla_excepcion = _tabla_excepcion(pendientes_por_marca=[1, 2], pendientes_por_dia=[DIA_ID])
    _preparar(tabla_dia=tabla_dia, marca=tabla_marca, excepcion=tabla_excepcion)

    response = _pedir_dias()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["dias"][0]["excepciones_pendientes"] == 3


def test_listar_dias_sin_excepciones_pendientes_es_cero():
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    _preparar(tabla_dia=tabla_dia)

    response = _pedir_dias()

    _limpiar()
    assert response.json()["dias"][0]["excepciones_pendientes"] == 0


def test_listar_dias_excepciones_resueltas_no_cuentan():
    """La consulta real filtra .eq('estado', 'pendiente') -- una excepción resuelto nunca llega
    acá, mismo criterio que el resto de las consultas de este router."""
    tabla_dia = _tabla_encadenada([_fila_dia()], total=1)
    tabla_marca = _tabla_encadenada([_fila_marca(1, "2026-09-08T14:00:00+00:00")])
    # marca 1 tiene una excepción, pero resuelto -- no aparece en la respuesta filtrada.
    tabla_excepcion = _tabla_excepcion(pendientes_por_marca=[], pendientes_por_dia=[])
    _preparar(tabla_dia=tabla_dia, marca=tabla_marca, excepcion=tabla_excepcion)

    response = _pedir_dias()

    _limpiar()
    assert response.json()["dias"][0]["excepciones_pendientes"] == 0


# ---------------------------------------------------------------------------
# GET /api/dias/pendientes-corte-quincenal
# ---------------------------------------------------------------------------


def _pedir_pendientes_corte_quincenal():
    client = TestClient(app)
    return client.get(
        "/api/dias/pendientes-corte-quincenal", headers={"Authorization": "Bearer fake-token"}
    )


def test_dias_pendientes_corte_quincenal_agrupa_por_persona():
    tabla_persona = _tabla_persona(
        nombres=[{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]
    )
    _preparar(tabla_dia=_tabla_encadenada([]), persona=tabla_persona)

    with (
        patch(
            "app.routers.dias.resolver_periodo_en_curso",
            return_value=(date(2026, 9, 1), date(2026, 9, 15)),
        ),
        patch(
            "app.routers.dias.resolver_dias_faltantes",
            return_value=[
                {"persona_id": PERSONA_1, "fecha": "2026-09-03"},
                {"persona_id": PERSONA_1, "fecha": "2026-09-05"},
            ],
        ),
    ):
        response = _pedir_pendientes_corte_quincenal()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["periodo_desde"] == "2026-09-01"
    assert cuerpo["periodo_hasta"] == "2026-09-15"
    assert len(cuerpo["personas"]) == 1
    persona = cuerpo["personas"][0]
    assert persona["persona_id"] == PERSONA_1
    assert persona["persona_nombre"] == "Ana Pérez"
    assert persona["fechas_faltantes"] == ["2026-09-03", "2026-09-05"]


def test_dias_pendientes_corte_quincenal_sin_faltantes_devuelve_lista_vacia():
    _preparar(tabla_dia=_tabla_encadenada([]))

    with (
        patch(
            "app.routers.dias.resolver_periodo_en_curso",
            return_value=(date(2026, 9, 1), date(2026, 9, 15)),
        ),
        patch("app.routers.dias.resolver_dias_faltantes", return_value=[]),
    ):
        response = _pedir_pendientes_corte_quincenal()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["personas"] == []


def test_dias_pendientes_corte_quincenal_sin_dia_lectura_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos({"marca_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_pendientes_corte_quincenal()

    _limpiar()
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# GET /api/dias/{dia_id}/previsualizar-tramos
# ---------------------------------------------------------------------------


def _fila_armado(accion, minutos=None, **overrides):
    fila = {
        "accion": accion,
        "tramo_id": None,
        "marca_apertura_id": 1,
        "marca_cierre_id": 2,
        "inicio": "2026-09-08T14:00:00+00:00",
        "fin": "2026-09-08T23:00:00+00:00",
        "minutos_trabajados": minutos,
    }
    fila.update(overrides)
    return fila


def _pedir_previsualizar(dia_id=DIA_ID):
    client = TestClient(app)
    return client.get(
        f"/api/dias/{dia_id}/previsualizar-tramos", headers={"Authorization": "Bearer fake-token"}
    )


def test_previsualizar_tramos_cerrarian_calcula_horas_sin_huerfana():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = [
        _fila_armado("cerrar_existente", minutos=480.0),
        _fila_armado("nuevo", minutos=60.0),
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_previsualizar()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["horas_calculadas"] == 9.0
    assert cuerpo["tiene_huerfana_sin_pareja"] is False
    fake_client.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_dia_calcular_armado_tramos", {"p_dia_id": DIA_ID}
    )


def test_previsualizar_tramos_con_huerfana_sobrante():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = [
        _fila_armado("cerrar_existente", minutos=480.0),
        _fila_armado("huerfana_sin_pareja", minutos=None, fin=None),
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_previsualizar()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["horas_calculadas"] == 8.0
    assert cuerpo["tiene_huerfana_sin_pareja"] is True


def test_previsualizar_tramos_sin_permiso_devuelve_403():
    fake_client = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_previsualizar()

    _limpiar()
    assert response.status_code == 403


# ---------------------------------------------------------------------------
# POST /api/dias/{dia_id}/revisar
# ---------------------------------------------------------------------------


def _fila_dia_revisada(**overrides):
    fila = {
        "id": DIA_ID,
        "persona_id": PERSONA_1,
        "fecha": "2026-09-08",
        "estado": "revisado",
        "horas_totales": None,
        "origen": None,
        "revisado_por": PERSONA_1,
        "revisado_en": "2026-09-08T20:00:00+00:00",
    }
    fila.update(overrides)
    return fila


def _pedir_revisar(dia_id=DIA_ID, horas_totales=8.0):
    client = TestClient(app)
    return client.post(
        f"/api/dias/{dia_id}/revisar",
        json={"horas_totales": horas_totales},
        headers={"Authorization": "Bearer fake-token"},
    )


def test_revisar_dia_exito_llama_rpc_una_vez_con_horas():
    fake_client = _fake_caller_client_secuencia(
        _entradas_gate_or() + [("persona", _tabla_persona_in([{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]))]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_dia_revisada(horas_totales=7.5)
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar(horas_totales=7.5)

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["estado"] == "revisado"
    assert cuerpo["horas_totales"] == 7.5
    assert cuerpo["persona_nombre"] == "Ana Pérez"
    fake_client.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_dia_revisar", {"p_dia_id": DIA_ID, "p_horas_totales": 7.5}
    )


def test_revisar_dia_horas_fuera_de_rango_devuelve_422_sin_llegar_al_rpc():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar(horas_totales=25)

    _limpiar()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_revisar_dia_horas_invalidas_rechazadas_por_el_rpc_devuelve_422():
    """SCJ08 -- por si el RPC lo rechaza por otra razón que Pydantic no cubre."""
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ08", "message": "horas invalidas"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 422


def test_revisar_dia_no_encontrado_devuelve_404():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ06", "message": "el dia no existe"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 404


def test_revisar_dia_no_bloqueado_devuelve_409():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ07", "message": "el dia no esta bloqueado"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 409


def test_revisar_dia_huerfana_sin_pareja_devuelve_409_con_mensaje():
    fake_client = _fake_caller_client_secuencia(_entradas_gate_or())
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": "SCJ09", "message": "marca huerfana sin pareja"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 409
    assert "sin pareja" in response.json()["detail"]


def test_revisar_dia_sin_permiso_devuelve_403():
    fake_client = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 403


def test_revisar_dia_nunca_usa_get_service_client():
    """dia_update_revision (RLS) es la autorización real -- este endpoint debe operar 100% con
    el JWT del caller, nunca con service_role."""

    def _service_client_boom():
        raise AssertionError("revisar_dia no debería depender de get_service_client")

    fake_client = _fake_caller_client_secuencia(
        _entradas_gate_or() + [("persona", _tabla_persona_in([{"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]))]
    )
    fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = (
        _fila_dia_revisada()
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    app.dependency_overrides[get_service_client] = _service_client_boom
    _override_identidad()

    response = _pedir_revisar()

    _limpiar()
    assert response.status_code == 200, response.text
