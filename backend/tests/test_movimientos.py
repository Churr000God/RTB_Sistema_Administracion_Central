from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app

import pytest

AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"
PERSONA_ID = "11111111-1111-1111-1111-111111111111"

# El POST de movimientos ahora exige requiere_permiso("cambio_estado_persona") -- el gate toca
# usuario/asignacion/puesto_permiso ANTES del insert propio del router. Ver test_areas.py para
# el razonamiento completo.
GATE_PERSONA_ID = "persona-ficticia-gate"
GATE_PUESTO_ID = "puesto-ficticio-gate"


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


def test_crear_movimiento_de_suspension_guarda_registrado_por():
    tabla_bitacora = MagicMock()
    tabla_bitacora.insert.return_value.execute.return_value.data = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "suspension",
            "fecha_efectiva": "2026-09-03T10:00:00+00:00",
            "motivo": "Licencia sin goce de sueldo",
            "documento_ref": None,
            "registrado_por": AUTH_USER_ID,
        }
    ]
    fake_client = MagicMock()
    fake_client.postgrest.schema.return_value.table.side_effect = (
        lambda nombre: tabla_bitacora if nombre == "bitacora_movimiento_persona" else _tabla_gate(nombre)
    )
    insert_mock = tabla_bitacora.insert
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo="mariana.alcantara@example.com"
    )

    client = TestClient(app)
    response = client.post(
        f"/api/personas/{PERSONA_ID}/movimientos",
        json={"tipo_movimiento": "suspension", "motivo": "Licencia sin goce de sueldo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 201
    assert response.json()["tipo_movimiento"] == "suspension"
    assert insert_mock.call_args[0][0]["registrado_por"] == AUTH_USER_ID


def test_crear_movimiento_sin_permiso_devuelve_403():
    """Caller autenticado y activo, pero sin cambio_estado_persona -- el gate debe rechazar
    antes de insertar el movimiento."""
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
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo="mariana.alcantara@example.com"
    )

    client = TestClient(app)
    response = client.post(
        f"/api/personas/{PERSONA_ID}/movimientos",
        json={"tipo_movimiento": "suspension", "motivo": "Licencia sin goce de sueldo"},
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 403


def _fake_db_get(movimientos, filas_usuario=None):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table

    def side_effect(nombre_tabla):
        tabla = MagicMock()
        if nombre_tabla == "bitacora_movimiento_persona":
            tabla.select.return_value.eq.return_value.order.return_value.execute.return_value.data = (
                movimientos
            )
        elif nombre_tabla == "usuario":
            tabla.select.return_value.in_.return_value.execute.return_value.data = (
                filas_usuario or []
            )
        return tabla

    tabla_mock.side_effect = side_effect
    return fake_client, tabla_mock


def test_listar_movimientos_resuelve_autor_con_mezcla_de_registros():
    movimientos = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "alta",
            "fecha_efectiva": "2026-01-01T09:00:00+00:00",
            "motivo": None,
            "documento_ref": None,
            "registrado_por": AUTH_USER_ID,
        },
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "suspension",
            "fecha_efectiva": "2026-02-01T09:00:00+00:00",
            "motivo": "Motivo X",
            "documento_ref": None,
            "registrado_por": None,
        },
    ]
    fake_client, _ = _fake_db_get(
        movimientos,
        filas_usuario=[{"auth_user_id": AUTH_USER_ID, "nombre_usuario": "mariana.alcantara"}],
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    cuerpo = response.json()
    assert cuerpo[0]["registrado_por_nombre"] == "mariana.alcantara"
    assert cuerpo[1]["registrado_por_nombre"] is None


def test_listar_movimientos_sin_autores_no_dispara_segunda_consulta():
    movimientos = [
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "persona_id": PERSONA_ID,
            "tipo_movimiento": "alta",
            "fecha_efectiva": "2026-01-01T09:00:00+00:00",
            "motivo": None,
            "documento_ref": None,
            "registrado_por": None,
        },
    ]
    fake_client, tabla_mock = _fake_db_get(movimientos)
    app.dependency_overrides[get_caller_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get(
        f"/api/personas/{PERSONA_ID}/movimientos",
        headers={"Authorization": "Bearer fake-token"},
    )

    app.dependency_overrides.clear()
    assert response.status_code == 200
    assert response.json()[0]["registrado_por_nombre"] is None
    assert tabla_mock.call_count == 1
    assert tabla_mock.call_args[0][0] == "bitacora_movimiento_persona"


@pytest.fixture(autouse=True)
def _sin_service_role_real():
    """POST de movimientos ahora depende de get_service_client (hook de baja de terminal): sin override
    llegaría a Supabase real. Por defecto el RPC devuelve 0 bajas."""
    servicio = MagicMock()
    servicio.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 0
    app.dependency_overrides[get_service_client] = lambda: servicio
    yield


# --- 129_*.sql: baja_definitiva exige además asignacion_edicion -----------------------------------

from postgrest.exceptions import APIError  # noqa: E402

from app.routers.movimientos import (  # noqa: E402
    MENSAJE_BAJA_PUESTO_ADMINISTRADOR,
    MENSAJE_BAJA_SIN_PERMISO_ASIGNACIONES,
    MENSAJE_MOVIMIENTO_SIN_PERMISO,
)


def _cliente_con_permisos(codigos_otorgados, error_insert=None):
    """Gate sensible al código: puesto_permiso devuelve el puesto del caller sólo para los códigos
    otorgados; permiso responde no heredable (así no entra la rama de herencia)."""
    tabla_bitacora = MagicMock()
    if error_insert is not None:
        tabla_bitacora.insert.return_value.execute.side_effect = error_insert
    else:
        tabla_bitacora.insert.return_value.execute.side_effect = lambda: MagicMock(
            data=[
                {
                    "id": "33333333-3333-3333-3333-333333333333",
                    "persona_id": PERSONA_ID,
                    "tipo_movimiento": tabla_bitacora.insert.call_args[0][0]["tipo_movimiento"],
                    "fecha_efectiva": "2026-10-28T10:00:00+00:00",
                    "motivo": "motivo",
                    "documento_ref": None,
                    "registrado_por": AUTH_USER_ID,
                }
            ]
        )

    def tabla(nombre):
        if nombre == "bitacora_movimiento_persona":
            return tabla_bitacora
        t = MagicMock()
        if nombre == "usuario":
            t.select.return_value.eq.return_value.execute.return_value.data = [{"persona_id": GATE_PERSONA_ID}]
        elif nombre == "asignacion":
            t.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": GATE_PUESTO_ID}
            ]
        elif nombre == "puesto_permiso":
            def por_codigo(_columna, codigo):
                siguiente = MagicMock()
                siguiente.eq.return_value.execute.return_value.data = (
                    [{"puesto_id": GATE_PUESTO_ID}] if codigo in codigos_otorgados else []
                )
                return siguiente

            t.select.return_value.eq.side_effect = por_codigo
        elif nombre == "permiso":
            t.select.return_value.eq.return_value.execute.return_value.data = [{"heredable": False}]
        return t

    cliente = MagicMock()
    cliente.postgrest.schema.return_value.table.side_effect = tabla
    return cliente, tabla_bitacora


PUESTO_AFECTADO_ID = "puesto-de-la-persona-afectada"


def _servicio(es_admin=False):
    """service_role: lee la asignación vigente de la persona afectada y el flag de su puesto, y responde
    el RPC de baja de terminales."""
    servicio = MagicMock()
    servicio.postgrest.schema.return_value.rpc.return_value.execute.return_value.data = 0

    def tabla(nombre):
        t = MagicMock()
        if nombre == "asignacion":
            t.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": PUESTO_AFECTADO_ID}
            ]
        elif nombre == "puesto":
            t.select.return_value.in_.return_value.execute.return_value.data = [
                {"es_administrador_generico": es_admin}
            ]
        return t

    servicio.postgrest.schema.return_value.table.side_effect = tabla
    return servicio


def _post_movimiento(cliente, tipo, servicio=None):
    servicio = servicio or _servicio()
    app.dependency_overrides[get_caller_client] = lambda: cliente
    app.dependency_overrides[get_service_client] = lambda: servicio
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo="mariana.alcantara@example.com"
    )
    try:
        return TestClient(app).post(
            f"/api/personas/{PERSONA_ID}/movimientos",
            json={"tipo_movimiento": tipo, "motivo": "motivo"},
            headers={"Authorization": "Bearer fake-token"},
        )
    finally:
        app.dependency_overrides.clear()


def test_baja_definitiva_sin_asignacion_edicion_da_403_sin_insertar():
    cliente, bitacora = _cliente_con_permisos({"cambio_estado_persona"})
    r = _post_movimiento(cliente, "baja_definitiva")
    assert r.status_code == 403
    assert r.json()["detail"] == MENSAJE_BAJA_SIN_PERMISO_ASIGNACIONES
    bitacora.insert.assert_not_called()


def test_baja_definitiva_con_asignacion_edicion_pasa():
    cliente, bitacora = _cliente_con_permisos({"cambio_estado_persona", "asignacion_edicion"})
    r = _post_movimiento(cliente, "baja_definitiva")
    assert r.status_code == 201
    assert r.json()["tipo_movimiento"] == "baja_definitiva"
    bitacora.insert.assert_called_once()


@pytest.mark.parametrize("tipo", ["suspension", "reactivacion"])
def test_suspension_y_reactivacion_no_exigen_asignacion_edicion(tipo):
    cliente, bitacora = _cliente_con_permisos({"cambio_estado_persona"})
    r = _post_movimiento(cliente, tipo)
    assert r.status_code == 201
    assert r.json()["tipo_movimiento"] == tipo


def test_baja_definitiva_sin_cambio_estado_persona_da_403_aunque_tenga_asignacion_edicion():
    cliente, bitacora = _cliente_con_permisos({"asignacion_edicion"})
    r = _post_movimiento(cliente, "baja_definitiva")
    assert r.status_code == 403
    bitacora.insert.assert_not_called()


@pytest.mark.parametrize(
    "tipo, mensaje",
    [
        ("baja_definitiva", MENSAJE_MOVIMIENTO_SIN_PERMISO),
        ("suspension", MENSAJE_MOVIMIENTO_SIN_PERMISO),
    ],
)
def test_42501_de_la_base_da_403_con_mensaje_fijo_y_sin_texto_en_log(tipo, mensaje, caplog):
    texto_secreto = 'new row violates row-level security policy for table "bitacora_movimiento_persona"'
    error = APIError({"code": "42501", "message": texto_secreto, "hint": None, "details": None})
    cliente, _ = _cliente_con_permisos(
        {"cambio_estado_persona", "asignacion_edicion"}, error_insert=error
    )
    with caplog.at_level("DEBUG"):
        r = _post_movimiento(cliente, tipo)
    assert r.status_code == 403
    assert r.json()["detail"] == mensaje
    assert texto_secreto not in r.text
    assert texto_secreto not in caplog.text


def test_otro_error_de_la_base_no_se_traduce_a_403():
    error = APIError({"code": "23503", "message": "fk", "hint": None, "details": None})
    cliente, _ = _cliente_con_permisos({"cambio_estado_persona"}, error_insert=error)
    r = _post_movimiento(cliente, "suspension")
    assert r.status_code != 403



def _error_42501():
    return APIError({"code": "42501", "message": "texto de la base no contractual", "hint": None, "details": None})


def test_baja_de_quien_ocupa_el_puesto_administrador_da_422_sin_insertar():
    cliente, bitacora = _cliente_con_permisos({"cambio_estado_persona", "asignacion_edicion"})
    r = _post_movimiento(cliente, "baja_definitiva", servicio=_servicio(es_admin=True))
    assert r.status_code == 422
    assert r.json()["detail"] == MENSAJE_BAJA_PUESTO_ADMINISTRADOR
    bitacora.insert.assert_not_called()


@pytest.mark.parametrize("tipo", ["suspension", "reactivacion"])
def test_suspension_y_reactivacion_no_consultan_el_puesto_administrador(tipo):
    cliente, _ = _cliente_con_permisos({"cambio_estado_persona"})
    r = _post_movimiento(cliente, tipo, servicio=_servicio(es_admin=True))
    assert r.status_code == 201


def test_verificacion_previa_no_detecta_al_administrador_y_el_insert_da_42501_es_403():
    """La asignación del administrador no se vio en la verificación previa (simulado: es_admin=False) y la
    policy de asignacion rechaza vía el trigger. Respaldo: 403 fijo, nunca 500 ni texto de la base."""
    cliente, bitacora = _cliente_con_permisos(
        {"cambio_estado_persona", "asignacion_edicion"}, error_insert=_error_42501()
    )
    r = _post_movimiento(cliente, "baja_definitiva", servicio=_servicio(es_admin=False))
    assert r.status_code == 403
    # El respaldo nunca afirma una causa: ni «falta asignacion_edicion» ni «puesto administrador».
    assert r.json()["detail"] == MENSAJE_MOVIMIENTO_SIN_PERMISO
    assert "texto de la base" not in r.text
    bitacora.insert.assert_called_once()


def test_carrera_permiso_revocado_entre_validacion_e_insert_da_403_fijo(caplog):
    cliente, _ = _cliente_con_permisos(
        {"cambio_estado_persona", "asignacion_edicion"}, error_insert=_error_42501()
    )
    with caplog.at_level("DEBUG"):
        r = _post_movimiento(cliente, "baja_definitiva")
    assert r.status_code == 403
    assert r.json()["detail"] == MENSAJE_MOVIMIENTO_SIN_PERMISO
    assert "texto de la base" not in caplog.text


@pytest.mark.parametrize("tipo", ["alta", "despido", "", "BAJA_DEFINITIVA"])
def test_tipo_de_movimiento_invalido_da_422_sin_insertar(tipo):
    cliente, bitacora = _cliente_con_permisos({"cambio_estado_persona", "asignacion_edicion"})
    r = _post_movimiento(cliente, tipo)
    assert r.status_code == 422
    bitacora.insert.assert_not_called()
