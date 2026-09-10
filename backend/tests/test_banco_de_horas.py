from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

PERSONA_1 = "aaaaaaaa-0000-0000-0000-000000000001"
PERSONA_2 = "aaaaaaaa-0000-0000-0000-000000000002"
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")

AHORA = datetime.now(timezone.utc)


def _iso(hace_dias: int) -> str:
    return (AHORA - timedelta(days=hace_dias)).isoformat()


# ---------------------------------------------------------------------------
# Helpers de gate -- AND entre 2 Depends(requiere_permiso(...)) separados
# (banco_de_horas_lectura) y (movimiento_de_saldo_lectura OR movimiento_de_saldo_edicion),
# cada uno resuelve su propio persona_id desde cero (no son la misma dependencia FastAPI).
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
    """Camino feliz: los 2 permisos se resuelven en el primer código de cada grupo."""
    grupo = [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]
    return grupo + grupo  # banco_de_horas_lectura, después movimiento_de_saldo_lectura


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
# Helpers de dato (service client)
# ---------------------------------------------------------------------------


def _tabla_parametro(valor=None):
    tabla = MagicMock()
    datos = [{"valor": str(valor)}] if valor is not None else []
    (
        tabla.select.return_value.eq.return_value.lte.return_value.order.return_value.limit
        .return_value.execute.return_value.data
    ) = datos
    return tabla


def _tabla_parametro_por_clave(valores: dict) -> MagicMock:
    """A diferencia de _tabla_parametro (mismo valor para cualquier clave), distingue cada
    lectura por el valor pasado a .eq('clave', ...) -- necesario para mover UN umbral (ej.
    umbral_aviso_pct) sin arrastrar ventana_banco_meses/umbral_escalamiento_pct con él."""
    tabla = MagicMock()

    def eq_side_effect(campo, valor_clave):
        assert campo == "clave"
        resultado = MagicMock()
        datos = [{"valor": valores[valor_clave]}] if valor_clave in valores else []
        resultado.lte.return_value.order.return_value.limit.return_value.execute.return_value.data = datos
        return resultado

    tabla.select.return_value.eq.side_effect = eq_side_effect
    return tabla


def _fila_patron_semanal(jornada_id, dia_semana, hora_entrada, hora_salida, minutos_comida=0):
    return {
        "jornada_asignada_id": jornada_id,
        "dia_semana": dia_semana,
        "hora_entrada": hora_entrada,
        "hora_salida": hora_salida,
        "minutos_comida": minutos_comida,
    }


def _patron_5x8(jornada_id):
    """Jornada normal, 8h/día de lunes a viernes -- 40h semanales."""
    return [
        _fila_patron_semanal(jornada_id, dia, "08:00", "17:00", 60)
        for dia in ("lunes", "martes", "miercoles", "jueves", "viernes")
    ]


def _tabla_plana(datos):
    tabla = MagicMock()
    tabla.select.return_value.execute.return_value.data = datos
    return tabla


def _tabla_eq(datos):
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = datos
    return tabla


def _tabla_in(datos):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos
    return tabla


def _tabla_persona(busqueda_ids=None, nombres=None):
    tabla = MagicMock()
    tabla.select.return_value.or_.return_value.execute.return_value.data = (
        [{"id": pid} for pid in busqueda_ids] if busqueda_ids is not None else []
    )
    tabla.select.return_value.in_.return_value.execute.return_value.data = nombres or []
    return tabla


def _tabla_festivos(datos=None):
    """_festivos_del_periodo: select().gte().lte().execute()."""
    tabla = MagicMock()
    tabla.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = datos or []
    return tabla


def _tabla_jornada_asignada(candidatas=None, jornadas_por_persona=None, jornadas_alerta_magnitud=None):
    """Una sola tabla soporta las 3 formas de consulta sobre jornada_asignada --
    _personas_normal_flexible_del_periodo (select().in_().lte().or_()),
    _jornadas_del_periodo (select().eq().lte().or_()) -- ambas de corte_quincenal.py, reusadas
    por la previsión de corte pendiente -- y _jornadas_normal_flexible_vigentes
    (select().in_().in_().lte().or_(), banco_alertas_magnitud.py, doble .in_) -- son atributos
    distintos del mismo mock, no chocan."""
    tabla = MagicMock()
    (
        tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = candidatas or []
    (
        tabla.select.return_value.eq.return_value.lte.return_value.or_.return_value
        .execute.return_value.data
    ) = jornadas_por_persona or []
    (
        tabla.select.return_value.in_.return_value.in_.return_value.lte.return_value.or_
        .return_value.execute.return_value.data
    ) = jornadas_alerta_magnitud or []
    return tabla


def _tabla_dia_periodo(datos=None):
    """_dias_del_periodo: select().eq(persona_id).gte().lte().execute()."""
    tabla = MagicMock()
    (
        tabla.select.return_value.eq.return_value.gte.return_value.lte.return_value
        .execute.return_value.data
    ) = datos or []
    return tabla


def _tabla_tramo_periodo(datos=None):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.order.return_value.execute.return_value.data = datos or []
    return tabla


def _tabla_clasificacion_existente(datos=None):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.limit.return_value.execute.return_value.data = datos or []
    return tabla


def _tabla_patron_semanal(datos=None):
    tabla = MagicMock()
    tabla.select.return_value.in_.return_value.execute.return_value.data = datos or []
    return tabla


def _fake_service_client(
    parametro=None,
    banco=None,
    movimiento=None,
    persona=None,
    dia_festivo=None,
    jornada_asignada=None,
    dia=None,
    tramo=None,
    clasificacion_de_tiempo=None,
    patron_semanal=None,
):
    defaults = {
        "parametro": parametro if parametro is not None else _tabla_parametro(),
        "banco_de_horas": banco if banco is not None else _tabla_plana([]),
        "movimiento_de_saldo": movimiento if movimiento is not None else _tabla_in([]),
        "persona": persona if persona is not None else _tabla_persona(nombres=[]),
        # Previsión de corte quincenal (corte_pendiente) -- por defecto nadie es candidato, así
        # los tests que no le importa esto no necesitan mockear nada más.
        "dia_festivo": dia_festivo if dia_festivo is not None else _tabla_festivos(),
        "jornada_asignada": jornada_asignada if jornada_asignada is not None else _tabla_jornada_asignada(),
        "dia": dia if dia is not None else _tabla_dia_periodo(),
        "tramo": tramo if tramo is not None else _tabla_tramo_periodo(),
        "clasificacion_de_tiempo": (
            clasificacion_de_tiempo if clasificacion_de_tiempo is not None else _tabla_clasificacion_existente()
        ),
        "patron_semanal": patron_semanal if patron_semanal is not None else _tabla_patron_semanal(),
    }

    def side_effect(nombre_tabla):
        return defaults.get(nombre_tabla, MagicMock())

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    return fake_client


def _preparar(**tablas):
    fake_caller = _fake_caller_client_secuencia(_entradas_gate())
    fake_service = _fake_service_client(**tablas)
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()
    return fake_caller, fake_service


def _fila_banco(persona_id=PERSONA_1, banco_id=1, monto=0.0, vivo_desde=None):
    return {
        "id": banco_id,
        "persona_id": persona_id,
        "monto": str(monto),
        "vivo_desde": vivo_desde,
        "actualizado_en": AHORA.isoformat(),
    }


def _mov(mov_id, banco_id, creado_en, monto):
    return {"id": mov_id, "banco_de_horas_id": banco_id, "creado_en": creado_en, "monto": str(monto)}


def _pedir(**params):
    client = TestClient(app)
    return client.get(
        "/api/banco-de-horas", params=params, headers={"Authorization": "Bearer fake-token"}
    )


# ---------------------------------------------------------------------------
# GET /api/banco-de-horas
# ---------------------------------------------------------------------------


def test_listar_banco_de_horas_resuelve_nombre_y_resumen():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=10.0, vivo_desde=_iso(10)),
            _fila_banco(PERSONA_2, 2, monto=0.0, vivo_desde=None),
        ]
    )
    movimiento = _tabla_in([_mov(1, 1, _iso(10), 10.0)])
    persona = _tabla_persona(
        nombres=[
            {"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"},
            {"id": PERSONA_2, "primer_nombre": "Beto", "apellido_paterno": "Ruiz"},
        ]
    )
    _preparar(banco=banco, movimiento=movimiento, persona=persona)

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["resumen"]["total_personas"] == 2
    assert cuerpo["resumen"]["en_deuda"] == 1
    assert cuerpo["resumen"]["sin_deuda"] == 1
    assert cuerpo["resumen"]["ventana_meses"] == 6
    saldos_por_persona = {item["persona_id"]: item for item in cuerpo["saldos"]}
    assert saldos_por_persona[PERSONA_1]["persona_nombre"] == "Ana Pérez"
    assert saldos_por_persona[PERSONA_1]["monto"] == 10.0
    assert saldos_por_persona[PERSONA_1]["horas_reciente"] == 10.0
    assert saldos_por_persona[PERSONA_1]["conciliado"] is True
    assert saldos_por_persona[PERSONA_2]["monto"] == 0.0


def test_listar_banco_de_horas_filtra_por_tramo_antiguedad():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=5.0, vivo_desde=_iso(10)),  # reciente
            _fila_banco(PERSONA_2, 2, monto=5.0, vivo_desde=_iso(250)),  # fuera_ventana
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 5.0),
            _mov(2, 2, _iso(250), 5.0),
        ]
    )
    _preparar(banco=banco, movimiento=movimiento)

    response = _pedir(tramo_antiguedad="fuera_ventana")

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    assert cuerpo["saldos"][0]["persona_id"] == PERSONA_2
    # el resumen sigue reflejando a las 2 personas, el filtro no lo toca.
    assert cuerpo["resumen"]["total_personas"] == 2


def test_listar_banco_de_horas_orden_monto_asc():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=20.0, vivo_desde=_iso(10)),
            _fila_banco(PERSONA_2, 2, monto=5.0, vivo_desde=_iso(10)),
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 20.0),
            _mov(2, 2, _iso(10), 5.0),
        ]
    )
    _preparar(banco=banco, movimiento=movimiento)

    response = _pedir(orden="monto_asc")

    _limpiar()
    assert response.status_code == 200, response.text
    montos = [item["monto"] for item in response.json()["saldos"]]
    assert montos == [5.0, 20.0]


def test_listar_banco_de_horas_paginacion():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=30.0, vivo_desde=_iso(10)),
            _fila_banco(PERSONA_2, 2, monto=20.0, vivo_desde=_iso(10)),
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 30.0),
            _mov(2, 2, _iso(10), 20.0),
        ]
    )
    _preparar(banco=banco, movimiento=movimiento)

    response = _pedir(limite=1, desplazamiento=1)

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 2
    assert len(cuerpo["saldos"]) == 1
    assert cuerpo["saldos"][0]["monto"] == 20.0  # monto_desc por defecto -- el segundo es el menor


def test_listar_banco_de_horas_busqueda_filtra_sin_tocar_el_resumen():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=10.0, vivo_desde=_iso(10)),
            _fila_banco(PERSONA_2, 2, monto=10.0, vivo_desde=_iso(10)),
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 10.0),
            _mov(2, 2, _iso(10), 10.0),
        ]
    )
    persona = _tabla_persona(
        busqueda_ids=[PERSONA_1],
        nombres=[
            {"id": PERSONA_1, "primer_nombre": "Ana", "apellido_paterno": "Pérez"},
            {"id": PERSONA_2, "primer_nombre": "Beto", "apellido_paterno": "Ruiz"},
        ],
    )
    _preparar(banco=banco, movimiento=movimiento, persona=persona)

    response = _pedir(busqueda_persona="Ana")

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    assert cuerpo["saldos"][0]["persona_id"] == PERSONA_1
    assert cuerpo["resumen"]["total_personas"] == 2


def test_listar_banco_de_horas_sin_banco_de_horas_lectura_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(
        {"movimiento_de_saldo_lectura", "movimiento_de_saldo_edicion"}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir()

    _limpiar()
    assert response.status_code == 403


def test_listar_banco_de_horas_sin_permiso_de_ledger_devuelve_403():
    """El AND entre grupos: banco_de_horas_lectura solo no alcanza."""
    fake_caller = _fake_caller_client_con_permisos({"banco_de_horas_lectura"})
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir()

    _limpiar()
    assert response.status_code == 403


def test_listar_banco_de_horas_desconciliado_marca_bandera():
    """movimientos que no cuadran contra monto -- conciliado=False + fallback a vivo_desde."""
    banco = _tabla_plana([_fila_banco(PERSONA_1, 1, monto=8.0, vivo_desde=_iso(150))])  # media
    movimiento = _tabla_in([_mov(1, 1, _iso(10), 2.0)])  # sólo reconstruye 2, banco dice 8
    _preparar(banco=banco, movimiento=movimiento)

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    saldo = response.json()["saldos"][0]
    assert saldo["conciliado"] is False
    assert saldo["horas_media"] == 8.0


def _jornada_vigente_siempre(id_=1):
    return {"id": id_, "tipo_jornada": "normal", "vigente_desde": "2020-01-01", "vigente_hasta": None}


def test_listar_banco_de_horas_marca_corte_pendiente_en_fila_real():
    """dia=[] (sin mockear, default) -- _procesar_persona(solo_simular=True) encuentra el primer
    día esperado sin tiempo.dia y devuelve PENDIENTE_DIA_ABIERTO -> corte_pendiente=True."""
    banco = _tabla_plana([_fila_banco(PERSONA_1, 1, monto=5.0, vivo_desde=_iso(10))])
    movimiento = _tabla_in([_mov(1, 1, _iso(10), 5.0)])
    jornada_asignada = _tabla_jornada_asignada(
        candidatas=[{"persona_id": PERSONA_1}],
        jornadas_por_persona=[_jornada_vigente_siempre()],
    )
    _preparar(banco=banco, movimiento=movimiento, jornada_asignada=jornada_asignada)

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["saldos"][0]["corte_pendiente"] is True
    assert cuerpo["resumen"]["personas_corte_pendiente"] == 1


def test_listar_banco_de_horas_fila_sintetica_para_persona_sin_banco_real():
    """PERSONA_2 no tiene fila en tiempo.banco_de_horas pero sí corte pendiente -- aparece como
    fila sintética en 0, para que RH la vea igual."""
    banco = _tabla_plana([])  # nadie con fila real
    jornada_asignada = _tabla_jornada_asignada(
        candidatas=[{"persona_id": PERSONA_2}],
        jornadas_por_persona=[_jornada_vigente_siempre()],
    )
    persona = _tabla_persona(nombres=[{"id": PERSONA_2, "primer_nombre": "Beto", "apellido_paterno": "Ruiz"}])
    _preparar(banco=banco, jornada_asignada=jornada_asignada, persona=persona)

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    saldo = cuerpo["saldos"][0]
    assert saldo["persona_id"] == PERSONA_2
    assert saldo["persona_nombre"] == "Beto Ruiz"
    assert saldo["monto"] == 0.0
    assert saldo["actualizado_en"] is None
    assert saldo["corte_pendiente"] is True
    assert cuerpo["resumen"]["personas_corte_pendiente"] == 1
    assert cuerpo["resumen"]["total_personas"] == 1


# ---------------------------------------------------------------------------
# Alerta por magnitud (umbral_aviso_pct/umbral_escalamiento_pct) -- segundo eje, independiente
# del de antigüedad de arriba.
# ---------------------------------------------------------------------------


def test_listar_banco_de_horas_calcula_porcentaje_y_nivel_de_alerta():
    """PERSONA_1: 50h de deuda / 40h de jornada semanal = 125% -> "aviso" (umbrales por defecto
    100/200). PERSONA_2: sin jornada normal/flexible vigente -> None en los 3 campos."""
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=50.0, vivo_desde=_iso(10)),
            _fila_banco(PERSONA_2, 2, monto=50.0, vivo_desde=_iso(10)),
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 50.0),
            _mov(2, 2, _iso(10), 50.0),
        ]
    )
    jornada_asignada = _tabla_jornada_asignada(
        jornadas_alerta_magnitud=[{"id": 10, "persona_id": PERSONA_1, "vigente_desde": "2020-01-01"}],
    )
    patron_semanal = _tabla_patron_semanal(_patron_5x8(10))
    _preparar(
        banco=banco, movimiento=movimiento, jornada_asignada=jornada_asignada, patron_semanal=patron_semanal
    )

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    saldos_por_persona = {item["persona_id"]: item for item in response.json()["saldos"]}
    saldo_1 = saldos_por_persona[PERSONA_1]
    assert saldo_1["jornada_semanal_horas"] == 40.0
    assert saldo_1["porcentaje_jornada_semanal"] == 125.0
    assert saldo_1["nivel_alerta"] == "aviso"
    saldo_2 = saldos_por_persona[PERSONA_2]
    assert saldo_2["jornada_semanal_horas"] is None
    assert saldo_2["porcentaje_jornada_semanal"] is None
    assert saldo_2["nivel_alerta"] is None


def test_listar_banco_de_horas_resumen_expone_umbrales_y_conteos():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=50.0, vivo_desde=_iso(10)),  # 125% -> aviso
            _fila_banco(PERSONA_2, 2, monto=90.0, vivo_desde=_iso(10)),  # 225% -> escalamiento
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 50.0),
            _mov(2, 2, _iso(10), 90.0),
        ]
    )
    jornada_asignada = _tabla_jornada_asignada(
        jornadas_alerta_magnitud=[
            {"id": 10, "persona_id": PERSONA_1, "vigente_desde": "2020-01-01"},
            {"id": 11, "persona_id": PERSONA_2, "vigente_desde": "2020-01-01"},
        ],
    )
    patron_semanal = _tabla_patron_semanal(_patron_5x8(10) + _patron_5x8(11))
    _preparar(
        banco=banco, movimiento=movimiento, jornada_asignada=jornada_asignada, patron_semanal=patron_semanal
    )

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    resumen = response.json()["resumen"]
    assert resumen["aviso_pct"] == 100
    assert resumen["escalamiento_pct"] == 200
    assert resumen["personas_en_aviso"] == 1
    assert resumen["personas_en_escalamiento"] == 1


def test_listar_banco_de_horas_filtra_por_nivel_alerta():
    banco = _tabla_plana(
        [
            _fila_banco(PERSONA_1, 1, monto=50.0, vivo_desde=_iso(10)),  # 125% -> aviso
            _fila_banco(PERSONA_2, 2, monto=90.0, vivo_desde=_iso(10)),  # 225% -> escalamiento
        ]
    )
    movimiento = _tabla_in(
        [
            _mov(1, 1, _iso(10), 50.0),
            _mov(2, 2, _iso(10), 90.0),
        ]
    )
    jornada_asignada = _tabla_jornada_asignada(
        jornadas_alerta_magnitud=[
            {"id": 10, "persona_id": PERSONA_1, "vigente_desde": "2020-01-01"},
            {"id": 11, "persona_id": PERSONA_2, "vigente_desde": "2020-01-01"},
        ],
    )
    patron_semanal = _tabla_patron_semanal(_patron_5x8(10) + _patron_5x8(11))
    _preparar(
        banco=banco, movimiento=movimiento, jornada_asignada=jornada_asignada, patron_semanal=patron_semanal
    )

    response = _pedir(nivel_alerta="escalamiento")

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 1
    assert cuerpo["saldos"][0]["persona_id"] == PERSONA_2
    # el resumen sigue reflejando a las 2 personas, el filtro no lo toca.
    assert cuerpo["resumen"]["total_personas"] == 2


def test_listar_banco_de_horas_umbral_aviso_distinto_del_default_cambia_el_nivel():
    """umbral_aviso_pct=50 (en vez del sembrado 100) -- 50h/40h=125% ya no cae en "sin_alerta"
    contra un umbral de 100, cae directo en "aviso" incluso con un umbral más bajo. El punto es
    que el nivel lo decide el PARÁMETRO real, no un 100/200 hardcodeado en el cálculo."""
    banco = _tabla_plana([_fila_banco(PERSONA_1, 1, monto=44.0, vivo_desde=_iso(10))])  # 110%
    movimiento = _tabla_in([_mov(1, 1, _iso(10), 44.0)])
    jornada_asignada = _tabla_jornada_asignada(
        jornadas_alerta_magnitud=[{"id": 10, "persona_id": PERSONA_1, "vigente_desde": "2020-01-01"}],
    )
    patron_semanal = _tabla_patron_semanal(_patron_5x8(10))
    parametro = _tabla_parametro_por_clave({"umbral_aviso_pct": "50"})
    _preparar(
        banco=banco,
        movimiento=movimiento,
        jornada_asignada=jornada_asignada,
        patron_semanal=patron_semanal,
        parametro=parametro,
    )

    response = _pedir()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["resumen"]["aviso_pct"] == 50
    assert cuerpo["resumen"]["escalamiento_pct"] == 200  # sin override -- sigue en el default
    saldo = cuerpo["saldos"][0]
    assert saldo["porcentaje_jornada_semanal"] == 110.0
    assert saldo["nivel_alerta"] == "aviso"  # 110% >= 50% (umbral bajado) -> aviso


# ---------------------------------------------------------------------------
# GET /api/banco-de-horas/{persona_id}/movimientos
# ---------------------------------------------------------------------------


def _pedir_movimientos(persona_id=PERSONA_1):
    client = TestClient(app)
    return client.get(
        f"/api/banco-de-horas/{persona_id}/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )


def test_listar_movimientos_calcula_saldo_corrido_y_vivo():
    banco = _tabla_eq([{"id": 1}])
    movimiento = _tabla_eq(
        [
            {
                "id": 1,
                "tipo": "generado_quincena",
                "monto": "5.00",
                "motivo": None,
                "autor_id": None,
                "creado_en": _iso(20),
            },
            {
                "id": 2,
                "tipo": "cubrir",
                "monto": "-2.00",
                "motivo": "cubrió falta",
                "autor_id": None,
                "creado_en": _iso(10),
            },
        ]
    )
    _preparar(banco=banco, movimiento=movimiento)

    response = _pedir_movimientos()

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 2
    por_id = {item["id"]: item for item in cuerpo["movimientos"]}
    assert por_id[1]["saldo_corrido"] == 5.0
    assert por_id[1]["vivo"] is True
    assert por_id[2]["saldo_corrido"] == 3.0
    assert por_id[2]["vivo"] is False
    # más reciente primero
    assert cuerpo["movimientos"][0]["id"] == 2


def test_listar_movimientos_persona_sin_banco_de_horas_devuelve_vacio():
    banco = _tabla_eq([])
    _preparar(banco=banco)

    response = _pedir_movimientos()

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json() == {"total": 0, "movimientos": []}


# ---------------------------------------------------------------------------
# POST /api/banco-de-horas/{persona_id}/movimientos
# ---------------------------------------------------------------------------
#
# 2 clientes distintos, mockeados por separado -- mismo motivo que el router: la lectura previa
# (banco_de_horas + movimiento_de_saldo + parametro, dos veces cada una: antes del RPC para la
# validación fina, después para reconstruir el ledger de la respuesta) va por get_service_client;
# el gate y el RPC van por get_caller_client. No hay que asumir que quien tiene
# movimiento_de_saldo_edicion también tiene banco_de_horas_lectura.


def _entradas_gate_edicion():
    """requiere_permiso("movimiento_de_saldo_edicion") -- OR de un solo código."""
    return [
        ("usuario", _tabla_select_simple([{"persona_id": GATE_PERSONA_ID}])),
        ("asignacion", _tabla_select_eq_is([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_select_doble_eq([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_caller_gate_edicion():
    return _fake_caller_client_secuencia(_entradas_gate_edicion())


def _pedir_registrar(persona_id=PERSONA_1, tipo="arrastrar", monto=3.0, motivo="ajuste"):
    client = TestClient(app)
    return client.post(
        f"/api/banco-de-horas/{persona_id}/movimientos",
        json={"tipo": tipo, "monto": monto, "motivo": motivo},
        headers={"Authorization": "Bearer fake-token"},
    )


def test_registrar_movimiento_arrastrar_llama_rpc_y_devuelve_ledger_de_2_filas():
    """arrastrar inserta 2 filas del lado del RPC (cancela + reabre) -- la respuesta re-arma el
    ledger completo después, no confía en lo que devuelva el RPC."""
    fake_caller = _fake_caller_gate_edicion()
    fake_service = _fake_caller_client_secuencia(
        [
            ("banco_de_horas", _tabla_eq([{"id": 1, "monto": "8.00", "vivo_desde": _iso(200)}])),
            ("movimiento_de_saldo", _tabla_eq([{"id": 1, "creado_en": _iso(200), "monto": "8.00"}])),
            ("parametro", _tabla_parametro()),
            ("banco_de_horas", _tabla_eq([{"id": 1}])),
            (
                "movimiento_de_saldo",
                _tabla_eq(
                    [
                        {
                            "id": 10,
                            "tipo": "arrastrar",
                            "monto": "-8.00",
                            "motivo": "renovar antigüedad",
                            "autor_id": None,
                            "creado_en": _iso(200),
                        },
                        {
                            "id": 11,
                            "tipo": "arrastrar",
                            "monto": "8.00",
                            "motivo": "renovar antigüedad",
                            "autor_id": None,
                            "creado_en": _iso(200),
                        },
                    ]
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_registrar(tipo="arrastrar", monto=3.0, motivo="renovar antigüedad")

    _limpiar()
    assert response.status_code == 200, response.text
    cuerpo = response.json()
    assert cuerpo["total"] == 2
    fake_caller.postgrest.schema.return_value.rpc.assert_called_once_with(
        "fn_movimiento_de_saldo_manual_registrar",
        {"p_persona_id": PERSONA_1, "p_tipo": "arrastrar", "p_monto": 3.0, "p_motivo": "renovar antigüedad"},
    )
    # las lecturas de validación/ledger fueron con service_role, nunca con el caller.
    assert "banco_de_horas" not in {
        llamada.args[0] for llamada in fake_caller.postgrest.schema.return_value.table.call_args_list
    }


def test_registrar_movimiento_descontar_devuelve_ledger_de_1_fila():
    fake_caller = _fake_caller_gate_edicion()
    fake_service = _fake_caller_client_secuencia(
        [
            ("banco_de_horas", _tabla_eq([{"id": 1, "monto": "8.00", "vivo_desde": _iso(200)}])),
            ("movimiento_de_saldo", _tabla_eq([{"id": 1, "creado_en": _iso(200), "monto": "8.00"}])),
            ("parametro", _tabla_parametro()),
            ("banco_de_horas", _tabla_eq([{"id": 1}])),
            (
                "movimiento_de_saldo",
                _tabla_eq(
                    [
                        {
                            "id": 12,
                            "tipo": "descontar",
                            "monto": "-3.00",
                            "motivo": "descuento admin",
                            "autor_id": None,
                            "creado_en": _iso(0),
                        }
                    ]
                ),
            ),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_registrar(tipo="descontar", monto=3.0, motivo="descuento admin")

    _limpiar()
    assert response.status_code == 200, response.text
    assert response.json()["total"] == 1


def test_registrar_movimiento_monto_excede_fuera_ventana_devuelve_422_sin_llamar_rpc():
    """Tope FINO en Python -- el monto pedido supera lo que efectivamente tiene 6+ meses de
    antigüedad (todo el saldo real, en este caso), aunque no supere el saldo total."""
    fake_caller = _fake_caller_gate_edicion()
    fake_service = _fake_caller_client_secuencia(
        [
            ("banco_de_horas", _tabla_eq([{"id": 1, "monto": "8.00", "vivo_desde": _iso(200)}])),
            ("movimiento_de_saldo", _tabla_eq([{"id": 1, "creado_en": _iso(200), "monto": "8.00"}])),
            ("parametro", _tabla_parametro()),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_registrar(tipo="descontar", monto=10.0)

    _limpiar()
    assert response.status_code == 422, response.text
    assert "6+ meses" in response.json()["detail"]
    fake_caller.postgrest.schema.return_value.rpc.assert_not_called()


def test_registrar_movimiento_monto_excede_fuera_ventana_usa_ventana_del_parametro():
    """El mensaje refleja ventana_banco_meses real, no un "6" hardcodeado -- con el parámetro en
    4, el detail dice "4+ meses"."""
    fake_caller = _fake_caller_gate_edicion()
    fake_service = _fake_caller_client_secuencia(
        [
            ("banco_de_horas", _tabla_eq([{"id": 1, "monto": "8.00", "vivo_desde": _iso(200)}])),
            ("movimiento_de_saldo", _tabla_eq([{"id": 1, "creado_en": _iso(200), "monto": "8.00"}])),
            ("parametro", _tabla_parametro(valor="4")),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()

    response = _pedir_registrar(tipo="descontar", monto=10.0)

    _limpiar()
    assert response.status_code == 422, response.text
    assert "4+ meses" in response.json()["detail"]
    fake_caller.postgrest.schema.return_value.rpc.assert_not_called()


def _preparar_para_error_rpc(codigo, mensaje):
    fake_caller = _fake_caller_gate_edicion()
    fake_service = _fake_caller_client_secuencia(
        [
            ("banco_de_horas", _tabla_eq([{"id": 1, "monto": "8.00", "vivo_desde": _iso(200)}])),
            ("movimiento_de_saldo", _tabla_eq([{"id": 1, "creado_en": _iso(200), "monto": "8.00"}])),
            ("parametro", _tabla_parametro()),
        ]
    )
    fake_caller.postgrest.schema.return_value.rpc.return_value.execute.side_effect = APIError(
        {"code": codigo, "message": mensaje}
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: fake_service
    _override_identidad()
    return fake_caller


def test_registrar_movimiento_tipo_no_permitido_scj01_devuelve_422():
    _preparar_para_error_rpc("SCJ01", "tipo no permitido")

    response = _pedir_registrar(monto=3.0)

    _limpiar()
    assert response.status_code == 422


def test_registrar_movimiento_monto_invalido_scj02_devuelve_422():
    _preparar_para_error_rpc("SCJ02", "monto invalido")

    response = _pedir_registrar(monto=3.0)

    _limpiar()
    assert response.status_code == 422


def test_registrar_movimiento_persona_sin_banco_scj03_devuelve_404():
    _preparar_para_error_rpc("SCJ03", "persona sin banco de horas")

    response = _pedir_registrar(monto=3.0)

    _limpiar()
    assert response.status_code == 404


def test_registrar_movimiento_excede_saldo_total_scj04_devuelve_409():
    _preparar_para_error_rpc("SCJ04", "excede el saldo total")

    response = _pedir_registrar(monto=3.0)

    _limpiar()
    assert response.status_code == 409


def test_registrar_movimiento_sin_permiso_devuelve_403():
    fake_caller = _fake_caller_client_con_permisos(set())
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_registrar()

    _limpiar()
    assert response.status_code == 403


def test_registrar_movimiento_motivo_vacio_devuelve_422_sin_llegar_al_rpc():
    """Pydantic (min_length=1) rechaza motivo="" antes de que el router toque la BD."""
    fake_caller = _fake_caller_gate_edicion()
    app.dependency_overrides[get_caller_client] = lambda: fake_caller
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()

    response = _pedir_registrar(motivo="")

    _limpiar()
    assert response.status_code == 422
