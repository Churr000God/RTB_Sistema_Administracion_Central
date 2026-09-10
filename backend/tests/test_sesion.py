from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.main import app

AUTH_USER_ID = "22222222-2222-2222-2222-222222222222"
PERSONA_ID = "11111111-1111-1111-1111-111111111111"


PUESTO_CALLER_ID = "puesto-ficticio-caller"


def _tabla_puesto_permiso_por_codigo(codigos_activos):
    """MagicMock argumento-consciente: .select("puesto_id").eq("codigo", codigo).eq("activo",
    True).execute().data -- distingue el código pedido (a diferencia del resto de los fakes de
    este módulo, acá SÍ importa: puede_ver_modulo_1 y puede_ver_modulo_2 se resuelven con dos
    llamadas a tiene_permiso con códigos distintos, y necesitamos respuestas distintas)."""
    tabla = MagicMock()

    def eq_codigo(_campo, codigo):
        resultado_eq2 = MagicMock()

        def eq_activo(_campo2, _valor2):
            ejecutable = MagicMock()
            datos = [{"puesto_id": PUESTO_CALLER_ID}] if codigo in codigos_activos else []
            ejecutable.execute.return_value.data = datos
            return ejecutable

        resultado_eq2.eq.side_effect = eq_activo
        return resultado_eq2

    tabla.select.return_value.eq.side_effect = eq_codigo
    return tabla


def _fake_db(filas_usuario, filas_persona=None, codigos_activos=()):
    fake_client = MagicMock()
    tabla_mock = fake_client.postgrest.schema.return_value.table

    def side_effect(nombre_tabla):
        if nombre_tabla == "usuario":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = filas_usuario
            return tabla
        if nombre_tabla == "persona":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.execute.return_value.data = (
                filas_persona or []
            )
            return tabla
        if nombre_tabla == "asignacion":
            tabla = MagicMock()
            tabla.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
                {"puesto_id": PUESTO_CALLER_ID}
            ]
            return tabla
        if nombre_tabla == "puesto_permiso":
            return _tabla_puesto_permiso_por_codigo(codigos_activos)
        return MagicMock()

    tabla_mock.side_effect = side_effect
    return fake_client


def _overrides(fake_client, correo="mariana.alcantara@example.com"):
    app.dependency_overrides[get_service_client] = lambda: fake_client
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(
        auth_user_id=AUTH_USER_ID, correo=correo
    )


def test_sesion_persona_activa_permite_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is True
    assert body["motivo_bloqueo"] is None
    assert body["persona_estado"] == "activo"


def test_sesion_calcula_puede_ver_modulo_1_y_2_por_separado():
    """El puesto vigente del caller tiene ver_modulo_1 activo pero NO ver_modulo_2 -- confirma
    que ambos flags se resuelven de forma independiente (dos llamadas a tiene_permiso, una por
    código), no como un OR compartido."""
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
        codigos_activos=("ver_modulo_1",),
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["puede_ver_modulo_1"] is True
    assert body["puede_ver_modulo_2"] is False


def test_sesion_sin_ver_modulo_1_ni_2_devuelve_ambos_false():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "activo"}],
        codigos_activos=(),
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["puede_ver_modulo_1"] is False
    assert body["puede_ver_modulo_2"] is False


def test_sesion_persona_suspendida_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "suspension"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "suspension"
    # Cuenta bloqueada: ni siquiera se calculan los permisos (backend confirmó que sólo se
    # evalúan cuando acceso_permitido es true) -- quedan en su default False.
    assert body["puede_ver_modulo_1"] is False
    assert body["puede_ver_modulo_2"] is False


def test_sesion_persona_baja_definitiva_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": PERSONA_ID,
            }
        ],
        filas_persona=[{"estado": "baja_definitiva"}],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "baja_definitiva"


def test_sesion_usuario_sin_persona_bloquea_acceso():
    fake_client = _fake_db(
        filas_usuario=[
            {
                "auth_user_id": AUTH_USER_ID,
                "nombre_usuario": "mariana.alcantara",
                "persona_id": None,
            }
        ],
    )
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "sin_persona"


def test_sesion_sin_fila_usuario_bloquea_acceso():
    fake_client = _fake_db(filas_usuario=[])
    _overrides(fake_client)

    client = TestClient(app)
    response = client.get("/api/sesion", headers={"Authorization": "Bearer fake-token"})

    app.dependency_overrides.clear()
    assert response.status_code == 200
    body = response.json()
    assert body["acceso_permitido"] is False
    assert body["motivo_bloqueo"] == "sin_usuario"


def test_sesion_rechaza_sin_token():
    fake_client = _fake_db(filas_usuario=[])
    app.dependency_overrides[get_service_client] = lambda: fake_client

    client = TestClient(app)
    response = client.get("/api/sesion")

    app.dependency_overrides.clear()
    assert response.status_code in (401, 422)
