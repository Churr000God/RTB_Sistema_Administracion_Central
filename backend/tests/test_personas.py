from datetime import date
from unittest.mock import MagicMock

from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

# alta_persona ahora exige requiere_permiso("alta_personas_usuarios") -- el gate toca
# usuario/asignacion/puesto_permiso ANTES del insert propio del router (persona + expediente,
# ambos contra la MISMA tabla_pe compartida, calcando el diseño original del test). Ver
# test_areas.py para el razonamiento completo.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _tabla_gate(nombre_tabla):
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
        tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
            {"puesto_id": GATE_PUESTO_ID}
        ]
    return tabla


def _override_identidad():
    app.dependency_overrides[get_caller_identity] = lambda: GATE_IDENTITY


_PERSONA_FILA = {
    "id": "11111111-1111-1111-1111-111111111111",
    "primer_nombre": "Mariana",
    "segundo_nombre": None,
    "apellido_paterno": "Alcántara",
    "apellido_materno": None,
    "curp": "AARM910427MDFLVR03",
    "rfc": "AARM910427H8A",
    "nss": "62119145338",
    "fecha_nacimiento": "1991-04-27",
    "fecha_ingreso": "2026-01-01",
    "fecha_baja": None,
    "estado": "activo",
    "campo_interno_que_no_debe_salir": "x",
}


def _cliente_alta(resultado=None, error=None):
    """Gate (tablas) + RPC con la FIRMA REAL de postgrest-py (`rpc(func, params, ...)`)."""
    from _mocks_supabase import Resultado, rpc_con_firma_real

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = _tabla_gate
    rpc = rpc_con_firma_real()
    if error is not None:
        rpc.return_value.execute.side_effect = error
    else:
        rpc.return_value.execute.return_value = Resultado(resultado if resultado is not None else _PERSONA_FILA)
    fake_client.postgrest.schema.return_value.rpc = rpc
    return fake_client, rpc


def _post_alta(fake_client, **cambios):
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()
    try:
        return TestClient(app, raise_server_exceptions=False).post(
            "/api/personas", json={**_CUERPO_ALTA, **cambios}, headers={"Authorization": "Bearer fake-token"}
        )
    finally:
        app.dependency_overrides.clear()


def test_alta_persona_llama_una_sola_vez_al_rpc_transaccional_con_argumentos_por_nombre():
    fake_client, rpc = _cliente_alta()
    response = _post_alta(fake_client, segundo_nombre="Lucía")
    assert response.status_code == 201
    assert rpc.call_count == 1
    nombre, argumentos = rpc.call_args.args
    assert nombre == "fn_persona_crear"
    assert argumentos == {
        "p_primer_nombre": "Mariana", "p_apellido_paterno": "Alcántara", "p_curp": "AARM910427MDFLVR03", "p_rfc": "AARM910427H8A", "p_nss": "62119145338",
        "p_fecha_nacimiento": "1991-04-27", "p_fecha_ingreso": "2026-01-01", "p_tipo_contrato": "indefinido", "p_documento_ref": "RTB-RH-EIT-2026-06",
        "p_segundo_nombre": "Lucía", "p_apellido_materno": None,
    }
    fake_client.postgrest.schema.assert_any_call("personas")                       # esquema personas (Content-Profile)
    cuerpo = response.json()
    assert cuerpo["curp"] == "AARM910427MDFLVR03" and cuerpo["id"] == _PERSONA_FILA["id"]
    assert "campo_interno_que_no_debe_salir" not in cuerpo                          # se proyecta a PersonaOut, no se reenvía el objeto crudo


def test_alta_persona_ya_no_hace_inserts_sueltos():
    fake_client, _rpc = _cliente_alta()
    llamadas = []
    original = fake_client.postgrest.schema.return_value.table.side_effect

    def espia(nombre):
        llamadas.append(nombre)
        return original(nombre)

    fake_client.postgrest.schema.return_value.table.side_effect = espia
    assert _post_alta(fake_client).status_code == 201
    assert "persona" not in llamadas and "expediente" not in llamadas


def test_alta_persona_normaliza_curp_rfc_a_mayusculas():
    fake_client, rpc = _cliente_alta()
    response = _post_alta(fake_client, curp="aarm910427mdflvr03", rfc="aarm910427h8a")
    assert response.status_code == 201
    argumentos = rpc.call_args.args[1]
    assert argumentos["p_curp"] == "AARM910427MDFLVR03" and argumentos["p_rfc"] == "AARM910427H8A"


_DETALLE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."


def test_respuesta_del_rpc_como_objeto_es_201():
    fake_client, _ = _cliente_alta(resultado=_PERSONA_FILA)
    r = _post_alta(fake_client)
    assert r.status_code == 201 and r.json()["id"] == _PERSONA_FILA["id"]


def test_respuesta_del_rpc_como_lista_de_un_elemento_es_201():
    fake_client, _ = _cliente_alta(resultado=[_PERSONA_FILA])
    r = _post_alta(fake_client)
    assert r.status_code == 201 and r.json()["id"] == _PERSONA_FILA["id"]


def test_respuesta_del_rpc_como_lista_vacia_es_502_con_mensaje_fijo():
    fake_client, _ = _cliente_alta(resultado=[])
    r = _post_alta(fake_client)
    assert r.status_code == 502 and r.json()["detail"] == _DETALLE_RESPUESTA_INESPERADA


def test_respuesta_del_rpc_sin_id_nula_o_de_otro_tipo_es_502_con_mensaje_fijo():
    for malo in (None, {"sin_id": 1}, "texto", 7, [{"sin_id": 1}]):
        fake_client, _ = _cliente_alta(resultado=[])
        fake_client.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = malo
        r = _post_alta(fake_client)
        assert r.status_code == 502 and r.json()["detail"] == _DETALLE_RESPUESTA_INESPERADA, malo


def test_alta_persona_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin alta_personas_usuarios -- el gate debe rechazar antes de llamar al RPC."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [{"persona_id": GATE_PERSONA_ID}]
        elif nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [{"puesto_id": GATE_PUESTO_ID}]
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = []
        elif nombre_tabla == "permiso":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [{"heredable": False}]
        return tabla

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    response = _post_alta(fake_client)
    assert response.status_code == 403
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_listar_personas():
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.return_value.select.return_value.execute.return_value.data = [
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "fecha_baja": None,
            "estado": "activo",
        },
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "primer_nombre": "Jorge",
            "segundo_nombre": None,
            "apellido_paterno": "Del Bosque",
            "apellido_materno": None,
            "curp": "DBJJ850101HDFLRR07",
            "rfc": "DBJJ850101H8A",
            "nss": "12345678901",
            "fecha_nacimiento": "1985-01-01",
            "fecha_ingreso": "2020-01-01",
            "fecha_baja": "2026-06-15",
            "estado": "baja_definitiva",
        },
    ]
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/personas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert len(cuerpo) == 2
    assert cuerpo[0]["fecha_baja"] is None
    assert cuerpo[1]["fecha_baja"] == "2026-06-15"


def test_listar_personas_incluye_tiene_jornada_vigente():
    persona_con_jornada = "11111111-1111-1111-1111-111111111111"
    persona_sin_jornada = "44444444-4444-4444-4444-444444444444"

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "persona":
            tabla.select.return_value.execute.return_value.data = [
                {
                    "id": persona_con_jornada,
                    "primer_nombre": "Mariana",
                    "segundo_nombre": None,
                    "apellido_paterno": "Alcántara",
                    "apellido_materno": None,
                    "curp": "AARM910427MDFLVR03",
                    "rfc": "AARM910427H8A",
                    "nss": "62119145338",
                    "fecha_nacimiento": "1991-04-27",
                    "fecha_ingreso": "2026-01-01",
                    "fecha_baja": None,
                    "estado": "activo",
                },
                {
                    "id": persona_sin_jornada,
                    "primer_nombre": "Jorge",
                    "segundo_nombre": None,
                    "apellido_paterno": "Del Bosque",
                    "apellido_materno": None,
                    "curp": "DBJJ850101HDFLRR07",
                    "rfc": "DBJJ850101H8A",
                    "nss": "12345678901",
                    "fecha_nacimiento": "1985-01-01",
                    "fecha_ingreso": "2020-01-01",
                    "fecha_baja": None,
                    "estado": "activo",
                },
            ]
        elif nombre_tabla == "jornada_asignada":
            (
                tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
                .execute.return_value.data
            ) = [{"persona_id": persona_con_jornada}]
        return tabla

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/personas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    cuerpo = {p["id"]: p for p in response.json()}
    assert cuerpo[persona_con_jornada]["tiene_jornada_vigente"] is True
    assert cuerpo[persona_sin_jornada]["tiene_jornada_vigente"] is False


def test_listar_personas_jornada_vigente_filtra_por_vigente_hoy_no_por_fila_abierta():
    """Regresión del bug real (2026-09-11): antes filtraba sólo vigente_hasta IS NULL, lo que
    marcaba a alguien con sólo una jornada futura precargada como "con jornada vigente". Verifica
    que la query real use vigente_desde <= hoy, no sólo "sin fecha de término"."""
    persona_id = "11111111-1111-1111-1111-111111111111"
    tabla_jornada = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "persona":
            tabla = MagicMock()
            tabla.select.return_value.execute.return_value.data = [
                {
                    "id": persona_id,
                    "primer_nombre": "Mariana",
                    "segundo_nombre": None,
                    "apellido_paterno": "Alcántara",
                    "apellido_materno": None,
                    "curp": "AARM910427MDFLVR03",
                    "rfc": "AARM910427H8A",
                    "nss": "62119145338",
                    "fecha_nacimiento": "1991-04-27",
                    "fecha_ingreso": "2026-01-01",
                    "fecha_baja": None,
                    "estado": "activo",
                },
            ]
            return tabla
        if nombre_tabla == "jornada_asignada":
            (
                tabla_jornada.select.return_value.in_.return_value.lte.return_value.or_
                .return_value.execute.return_value.data
            ) = []
            return tabla_jornada
        return MagicMock()

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/personas", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    assert response.json()[0]["tiene_jornada_vigente"] is False
    hoy_iso = date.today().isoformat()
    tabla_jornada.select.return_value.in_.return_value.lte.assert_called_once_with(
        "vigente_desde", hoy_iso
    )
    tabla_jornada.select.return_value.in_.return_value.lte.return_value.or_.assert_called_once_with(
        f"vigente_hasta.is.null,vigente_hasta.gte.{hoy_iso}"
    )


PERSONA_ID = "11111111-1111-1111-1111-111111111111"
AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"


def _fake_db_ficha(
    fila_persona, filas_usuario=None, filas_asignacion=None, filas_jornada_asignada=None
):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "persona":
            tabla.select.return_value.eq.return_value.single.return_value.execute.return_value.data = (
                fila_persona
            )
        elif nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = (
                filas_usuario or []
            )
        elif nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = (
                filas_asignacion or []
            )
        elif nombre_tabla == "jornada_asignada":
            (
                tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
                .execute.return_value.data
            ) = (filas_jornada_asignada or [])
        return tabla

    tabla_mock.side_effect = side_effect
    return fake_client


def test_ficha_persona_incluye_expediente_y_tiene_usuario():
    fake_client = _fake_db_ficha(
        fila_persona={
            "id": PERSONA_ID,
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
            "expediente": {"tipo_contrato": "indefinido", "documento_ref": "RTB-2026-001"},
        },
        filas_usuario=[{"auth_user_id": AUTH_USER_ID}],
        filas_jornada_asignada=[{"persona_id": PERSONA_ID}],
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert cuerpo["documento_ref"] == "RTB-2026-001"
    assert cuerpo["tiene_usuario"] is True
    assert cuerpo["tiene_jornada_vigente"] is True


def test_ficha_persona_sin_expediente_ni_usuario_no_crashea():
    fake_client = _fake_db_ficha(
        fila_persona={
            "id": PERSONA_ID,
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
            "expediente": None,
        },
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert cuerpo["tipo_contrato"] is None
    assert cuerpo["tiene_usuario"] is False
    assert cuerpo["documento_ref"] is None


def test_ficha_persona_incluye_puestos_vigentes_aplanados():
    fake_client = _fake_db_ficha(
        fila_persona={
            "id": PERSONA_ID,
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
            "expediente": None,
        },
        filas_asignacion=[
            {
                "id": "asignacion-ficticia-1",
                "puesto": {
                    "id": "puesto-ficticio-1",
                    "nombre_puesto": "Puesto Ficticio Uno",
                    "departamento": {
                        "nombre_departamento": "Departamento Ficticio Uno",
                        "area": {"nombre_area": "Área Ficticia Uno"},
                    },
                },
            }
        ],
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    puestos_vigentes = response.json()["puestos_vigentes"]
    assert len(puestos_vigentes) == 1
    assert puestos_vigentes[0] == {
        "asignacion_id": "asignacion-ficticia-1",
        "puesto_id": "puesto-ficticio-1",
        "nombre_puesto": "Puesto Ficticio Uno",
        "nombre_departamento": "Departamento Ficticio Uno",
        "nombre_area": "Área Ficticia Uno",
    }


def _fake_client_patch_gate(rpc_side_effect=None, expediente_data=None):
    """Gate (usuario/asignacion/puesto_permiso) igual a _tabla_gate -- usado por los tests de
    PATCH que cortan antes de llegar a _construir_ficha_persona (422/404/409), donde no hace
    falta mockear persona/jornada_asignada."""
    fake_client = MagicMock()

    def side_effect(nombre_tabla):
        if nombre_tabla == "expediente":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = (
                expediente_data or []
            )
            return tabla
        return _tabla_gate(nombre_tabla)

    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    if rpc_side_effect is not None:
        fake_client.postgrest.schema.return_value.rpc.return_value.execute.side_effect = (
            rpc_side_effect
        )
    return fake_client


def test_actualizar_persona_cuerpo_vacio_devuelve_422():
    fake_client = _fake_client_patch_gate()
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_actualizar_persona_sin_permiso_devuelve_403():
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
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"primer_nombre": "Mariana Actualizada"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def test_actualizar_persona_expediente_incompleto_sin_expediente_previo_devuelve_422():
    """Persona sin fila en expediente + sólo documento_ref (sin tipo_contrato) -- el INSERT del
    RPC reventaría con NOT NULL real de Postgres si dejáramos pasar esto."""
    fake_client = _fake_client_patch_gate(expediente_data=[])
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"documento_ref": "RTB-2026-002"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    fake_client.postgrest.schema.return_value.rpc.assert_not_called()


def test_actualizar_persona_expediente_incompleto_con_expediente_previo_no_bloquea():
    """Misma forma de payload (sólo documento_ref), pero la persona YA tiene expediente --
    COALESCE cubre tipo_contrato en el RPC, no debe cortar con 422."""
    fila_persona = {
        "id": PERSONA_ID,
        "primer_nombre": "Mariana",
        "segundo_nombre": None,
        "apellido_paterno": "Alcántara",
        "apellido_materno": None,
        "curp": "AARM910427MDFLVR03",
        "rfc": "AARM910427H8A",
        "nss": "62119145338",
        "fecha_nacimiento": "1991-04-27",
        "fecha_ingreso": "2026-01-01",
        "estado": "activo",
        "expediente": {"tipo_contrato": "indefinido", "documento_ref": "RTB-2026-002"},
    }

    def side_effect(nombre_tabla):
        if nombre_tabla == "persona":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.single.return_value.execute.return_value.data = (
                fila_persona
            )
            return tabla
        if nombre_tabla == "expediente":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"persona_id": PERSONA_ID}
            ]
            return tabla
        if nombre_tabla == "jornada_asignada":
            tabla = MagicMock()
            (
                tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
                .execute.return_value.data
            ) = []
            return tabla
        if nombre_tabla == "asignacion":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {
                    "id": "asignacion-ficticia-1",
                    "puesto_id": GATE_PUESTO_ID,
                    "puesto": {
                        "id": GATE_PUESTO_ID,
                        "nombre_puesto": "Puesto Ficticio",
                        "departamento": {
                            "nombre_departamento": "Departamento Ficticio",
                            "area": {"nombre_area": "Área Ficticia"},
                        },
                    },
                }
            ]
            return tabla
        return _tabla_gate(nombre_tabla)

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"documento_ref": "RTB-2026-002"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    fake_client.postgrest.schema.return_value.rpc.assert_called_once()
    argumentos = fake_client.postgrest.schema.return_value.rpc.call_args.args[1]
    assert argumentos["p_documento_ref"] == "RTB-2026-002"
    assert "p_tipo_contrato" not in argumentos


def test_actualizar_persona_no_encontrada_devuelve_404():
    fake_client = _fake_client_patch_gate(
        rpc_side_effect=APIError({"code": "SCJ10", "message": "persona no existe"})
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"primer_nombre": "Nombre Nuevo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 404


def test_actualizar_persona_curp_duplicada_devuelve_409():
    fake_client = _fake_client_patch_gate(
        rpc_side_effect=APIError({"code": "23505", "message": "duplicate key"})
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"curp": "AARM910427MDFLVR03"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 409


def test_actualizar_persona_documento_ref_formato_invalido_devuelve_422():
    fake_client = _fake_client_patch_gate(
        rpc_side_effect=APIError(
            {
                "code": "23514",
                "message": (
                    'new row for relation "expediente" violates check constraint '
                    '"ck_expediente_documento_ref_formato"'
                ),
            }
        )
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"tipo_contrato": "indefinido", "documento_ref": "carpeta-suelta-1"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "RTB-RH-EIT" in response.json()["detail"]


def test_actualizar_persona_normaliza_curp_a_mayusculas_y_devuelve_ficha_actualizada():
    fila_persona = {
        "id": PERSONA_ID,
        "primer_nombre": "Mariana",
        "segundo_nombre": None,
        "apellido_paterno": "Alcántara",
        "apellido_materno": None,
        "curp": "AARM910427MDFLVR03",
        "rfc": "AARM910427H8A",
        "nss": "62119145338",
        "fecha_nacimiento": "1991-04-27",
        "fecha_ingreso": "2026-01-01",
        "estado": "activo",
        "expediente": None,
    }
    asignacion_con_nido = [
        {
            "id": "asignacion-ficticia-1",
            "puesto_id": GATE_PUESTO_ID,
            "puesto": {
                "id": GATE_PUESTO_ID,
                "nombre_puesto": "Puesto Ficticio",
                "departamento": {
                    "nombre_departamento": "Departamento Ficticio",
                    "area": {"nombre_area": "Área Ficticia"},
                },
            },
        }
    ]

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "persona":
            tabla.select.return_value.eq.return_value.single.return_value.execute.return_value.data = (
                fila_persona
            )
        elif nombre_tabla == "usuario":
            tabla.select.return_value.eq.return_value.execute.return_value.data = [
                {"persona_id": GATE_PERSONA_ID, "auth_user_id": AUTH_USER_ID}
            ]
        elif nombre_tabla == "asignacion":
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = (
                asignacion_con_nido
            )
        elif nombre_tabla == "puesto_permiso":
            tabla.select.return_value.eq.return_value.eq.return_value.execute.return_value.data = [
                {"puesto_id": GATE_PUESTO_ID}
            ]
        elif nombre_tabla == "jornada_asignada":
            (
                tabla.select.return_value.in_.return_value.lte.return_value.or_.return_value
                .execute.return_value.data
            ) = []
        return tabla

    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = side_effect
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    client = TestClient(app)
    response = client.patch(
        f"/api/personas/{PERSONA_ID}",
        json={"curp": "aarm910427mdflvr03"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    argumentos = fake_client.postgrest.schema.return_value.rpc.call_args.args[1]
    assert argumentos["p_curp"] == "AARM910427MDFLVR03"
    assert "p_rfc" not in argumentos
    assert response.json()["id"] == PERSONA_ID


def test_ficha_persona_sin_asignaciones_devuelve_puestos_vigentes_vacio():
    fake_client = _fake_db_ficha(
        fila_persona={
            "id": PERSONA_ID,
            "primer_nombre": "Mariana",
            "segundo_nombre": None,
            "apellido_paterno": "Alcántara",
            "apellido_materno": None,
            "curp": "AARM910427MDFLVR03",
            "rfc": "AARM910427H8A",
            "nss": "62119145338",
            "fecha_nacimiento": "1991-04-27",
            "fecha_ingreso": "2026-01-01",
            "estado": "activo",
            "expediente": None,
        },
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()["puestos_vigentes"] == []


# --- alta: errores de la base mapeados (nada de 500 ni de texto crudo) ---------------------------------------------------------------------------------

_CUERPO_ALTA = {
    "primer_nombre": "Mariana",
    "apellido_paterno": "Alcántara",
    "curp": "AARM910427MDFLVR03",
    "rfc": "AARM910427H8A",
    "nss": "62119145338",
    "fecha_nacimiento": "1991-04-27",
    "fecha_ingreso": "2026-01-01",
    "tipo_contrato": "indefinido",
    "documento_ref": "RTB-RH-EIT-2026-06",
}
_TEXTO_CRUDO = "already exists. DETAIL interno de la base"


def _alta_con_error(error: APIError):
    """El RPC transaccional lanza `error`."""
    fake_client, _ = _cliente_alta(error=error)
    return _post_alta(fake_client)


def _unicidad(restriccion: str, columna: str) -> APIError:
    return APIError({"code": "23505", "message": f'duplicate key value violates unique constraint "{restriccion}"', "details": f"Key ({columna})=(valor-real) {_TEXTO_CRUDO}"})


def _sin_texto_crudo(respuesta):
    texto = respuesta.text
    assert "duplicate key" not in texto and "valor-real" not in texto and "DETAIL interno" not in texto and "AARM910427MDFLVR03" not in texto and "Error interno" not in texto


def test_alta_curp_duplicada_devuelve_409_con_mensaje_de_curp():
    r = _alta_con_error(_unicidad("uq_persona_curp", "curp"))
    assert r.status_code == 409 and "CURP" in r.json()["detail"]
    _sin_texto_crudo(r)


def test_alta_rfc_duplicado_devuelve_409_con_mensaje_de_rfc():
    r = _alta_con_error(_unicidad("uq_persona_rfc", "rfc"))
    assert r.status_code == 409 and "RFC" in r.json()["detail"]
    _sin_texto_crudo(r)


def test_alta_nss_duplicado_devuelve_409_con_mensaje_de_nss():
    r = _alta_con_error(_unicidad("uq_persona_nss", "nss"))
    assert r.status_code == 409 and "NSS" in r.json()["detail"]
    _sin_texto_crudo(r)


def test_alta_documento_ref_duplicado_devuelve_409_con_mensaje_del_folio():
    r = _alta_con_error(_unicidad("uq_expediente_documento_ref", "documento_ref"))
    assert r.status_code == 409 and "folio" in r.json()["detail"].lower() and "sin expediente" not in r.json()["detail"]
    _sin_texto_crudo(r)


def test_alta_documento_ref_mal_formado_devuelve_422_con_el_formato_real():
    error = APIError({"code": "23514", "message": 'new row for relation "expediente" violates check constraint "ck_expediente_documento_ref_formato"',
                      "details": "Failing row contains (valor-real, carpeta-suelta)"})
    r = _alta_con_error(error)
    assert r.status_code == 422 and "RTB-RH-EIT-<año>-<número>" in r.json()["detail"] and "RTB-RH-EIT-2026-06" in r.json()["detail"]
    _sin_texto_crudo(r)
    assert "Failing row" not in r.text


def test_alta_otro_check_devuelve_422_generico_sin_texto_de_la_base():
    r = _alta_con_error(APIError({"code": "23514", "message": 'violates check constraint "ck_persona_algo_futuro"', "details": "Failing row contains (valor-real)"}))
    assert r.status_code == 422 and "ck_persona_algo_futuro" not in r.text
    _sin_texto_crudo(r)


def test_alta_unicidad_sin_restriccion_reconocible_devuelve_409_generico():
    r = _alta_con_error(APIError({"code": "23505", "message": "duplicate key value", "details": "otra cosa"}))
    assert r.status_code == 409 and r.json()["detail"] == "CURP, RFC, NSS o número de documento ya está en uso por otra persona."
    # y con solo la columna en el detalle (sin el nombre de la restricción) se reconoce el campo
    r = _alta_con_error(APIError({"code": "23505", "message": "duplicate key value", "details": "Key (rfc)=(X) already exists."}))
    assert r.status_code == 409 and "RFC" in r.json()["detail"]
    r = _alta_con_error(APIError({"code": "23505", "message": "duplicate key value", "details": "otra cosa"}))
    assert r.status_code == 409 and r.json()["detail"] == "CURP, RFC, NSS o número de documento ya está en uso por otra persona."


def test_ningun_error_de_alta_conocido_devuelve_500():
    casos = [_unicidad(r, c) for r, c in (("uq_persona_curp", "curp"), ("uq_persona_rfc", "rfc"), ("uq_persona_nss", "nss"))]
    casos += [_unicidad("uq_expediente_documento_ref", "documento_ref"),
              APIError({"code": "23514", "message": 'violates check constraint "ck_expediente_documento_ref_formato"'})]
    for error in casos:
        assert _alta_con_error(error).status_code in (409, 422)


def test_alta_un_error_inesperado_de_la_base_sigue_siendo_500_sin_texto():
    r = _alta_con_error(APIError({"code": "XX000", "message": "boom con texto interno"}))
    assert r.status_code == 500 and "boom" not in r.text


def test_alta_tipo_contrato_invalido_devuelve_422_generico():
    r = _alta_con_error(APIError({"code": "23514", "message": 'new row for relation "expediente" violates check constraint "ck_expediente_tipo_contrato"',
                                          "details": "Failing row contains (valor-real, bizarro)"}))
    assert r.status_code == 422 and "ck_expediente_tipo_contrato" not in r.text and "Failing row" not in r.text
    assert "RTB-RH-EIT" not in r.json()["detail"]                                   # no es el mensaje del folio


def test_alta_42501_de_la_rls_devuelve_403_sin_texto_de_la_base():
    r = _alta_con_error(APIError({"code": "42501", "message": 'new row violates row-level security policy for table "persona"', "details": None}))
    assert r.status_code == 403 and "row-level" not in r.text and "persona\"" not in r.text


def test_alta_el_mapeo_funciona_con_el_error_real_que_arma_postgrest_py_para_un_rpc():
    """No un APIError armado a mano: la librería real recibe la respuesta HTTP de PostgREST (409 + JSON code/message/details/hint) de `POST /rpc/fn_persona_crear` y es ELLA quien
    levanta el APIError; el router lo traduce. También verifica el camino, el esquema (Content-Profile) y los argumentos por nombre en la petición real."""
    import httpx
    from postgrest import SyncPostgrestClient

    peticiones = []

    def servidor(request: httpx.Request) -> httpx.Response:
        peticiones.append(request)
        return httpx.Response(409, json={"code": "23505", "details": "Key (curp)=(AARM910427MDFLVR03) already exists.", "hint": None,
                                         "message": 'duplicate key value violates unique constraint "uq_persona_curp"'})

    http = httpx.Client(transport=httpx.MockTransport(servidor), base_url="https://scj.ejemplo.test/rest/v1")
    real = SyncPostgrestClient("https://scj.ejemplo.test/rest/v1", schema="personas", http_client=http)
    esquema = MagicMock()
    esquema.table.side_effect = _tabla_gate
    esquema.rpc = real.rpc                                                         # el RPC real de la librería, con transporte simulado
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value = esquema
    r = _post_alta(fake_client)
    assert r.status_code == 409 and "CURP" in r.json()["detail"]
    _sin_texto_crudo(r)
    assert len(peticiones) == 1
    p = peticiones[0]
    assert p.method == "POST" and p.url.path.endswith("/rpc/fn_persona_crear") and p.headers.get("content-profile") == "personas"
    import json as _json

    assert _json.loads(p.content)["p_curp"] == "AARM910427MDFLVR03" and _json.loads(p.content)["p_documento_ref"] == "RTB-RH-EIT-2026-06"


def test_alta_el_error_real_de_check_del_folio_con_postgrest_py():
    import httpx
    from postgrest import SyncPostgrestClient

    def servidor(request):
        return httpx.Response(400, json={"code": "23514", "details": "Failing row contains (valor-real).", "hint": None,
                                         "message": 'new row for relation "expediente" violates check constraint "ck_expediente_documento_ref_formato"'})

    http = httpx.Client(transport=httpx.MockTransport(servidor), base_url="https://scj.ejemplo.test/rest/v1")
    esquema = MagicMock()
    esquema.table.side_effect = _tabla_gate
    esquema.rpc = SyncPostgrestClient("https://scj.ejemplo.test/rest/v1", schema="personas", http_client=http).rpc
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value = esquema
    r = _post_alta(fake_client, documento_ref="carpeta-suelta")
    assert r.status_code == 422 and "RTB-RH-EIT-<año>-<número>" in r.json()["detail"] and "Failing row" not in r.text


def test_alta_42501_deja_un_warning_con_sqlstate_y_ruta_pero_nunca_el_mensaje_de_la_base(caplog):
    import logging

    texto_base = 'permission denied for function fn_persona_crear (texto interno de la base)'
    with caplog.at_level(logging.WARNING, logger="app.personas"):
        r = _alta_con_error(APIError({"code": "42501", "message": texto_base, "details": "detalle interno"}))
    assert r.status_code == 403 and r.json()["detail"] == "No tienes permiso para dar de alta personas."      # al cliente le llega lo de siempre
    avisos = [x.getMessage() for x in caplog.records if x.name == "app.personas"]
    assert len(avisos) == 1 and "42501" in avisos[0] and "POST /api/personas" in avisos[0] and "fn_persona_crear" in avisos[0]
    assert "texto interno" not in avisos[0] and "detalle interno" not in avisos[0] and "permission denied" not in avisos[0]
    assert "permission denied" not in r.text and "texto interno" not in r.text
