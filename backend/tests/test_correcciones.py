"""POST /api/correcciones (SCJ-PRO-10). Mocks del cliente de Supabase por NOMBRE de tabla (como
test_dia_cerrado_datos_ui.py), no por orden de llamada: un cambio en el orden de las consultas del
router no rompe estas pruebas, sólo un cambio de comportamiento. El gate de permisos (`tiene_permiso`)
se prueba aparte (test_gate_permisos.py); aquí se parchea su función pública. Nunca contra la base real."""

from datetime import date, timedelta
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.main import app
from app.routers import correcciones


def _fake_service_client_config(limite_valor: str | None = None, festivos: list | None = None):
    """tiempo.parametro/tiempo.dia_festivo -- config global que _validar_ventana lee con
    service_role vía app/dias_habiles.py (helper compartido con routers/marcas.py). Sin este
    fake, get_service_client(get_settings()) construiría un cliente real contra el Supabase de
    .env y pegaría de verdad -- CLAUDE.md exige que ningún test lo haga."""
    fake = MagicMock()
    tabla_parametro = MagicMock()
    (
        tabla_parametro.select.return_value.eq.return_value.lte.return_value.order.return_value
        .limit.return_value.execute.return_value.data
    ) = [{"valor": limite_valor}] if limite_valor is not None else []
    tabla_festivo = MagicMock()
    tabla_festivo.select.return_value.gte.return_value.lte.return_value.execute.return_value.data = (
        festivos or []
    )

    def table_side_effect(nombre):
        return {"parametro": tabla_parametro, "dia_festivo": tabla_festivo}[nombre]

    fake.postgrest.schema.return_value.table.side_effect = table_side_effect
    return fake


def _tabla(datos):
    """Constructor fluido: cualquier método encadenable devuelve el mismo objeto; sólo execute() corta."""
    t = MagicMock()
    for metodo in ("select", "eq", "in_", "or_", "order", "is_"):
        getattr(t, metodo).return_value = t
    t.execute.return_value.data = datos
    return t


def _db(**tablas):
    """Cliente del caller: cada tabla se resuelve por nombre. Una tabla no declarada falla la prueba."""
    db = MagicMock()
    db.postgrest.schema.return_value.table.side_effect = lambda nombre: tablas[nombre]
    return db


def _fake_servicio_tramos(datos):
    """Cliente service_role de la consulta previa a tiempo.tramo (marca_en_tramo.py): por defecto la
    marca no está en ningún tramo y la corrección sigue como siempre."""
    return _db(tramo=_tabla(datos))


@pytest.fixture(autouse=True)
def _sin_red_real():
    """Todo test de este módulo pasa por _validar_ventana (get_service_client de dias_habiles para leer
    dias_habiles_correccion_marca) y por la consulta de tramos (Depends(get_service_client)): sin estos
    fakes golpearían Supabase real. Un test que necesite otro valor usa su propio override/patch."""
    app.dependency_overrides[get_service_client] = lambda: _fake_servicio_tramos([])
    with patch("app.dias_habiles.get_service_client", return_value=_fake_service_client_config()):
        yield


@pytest.fixture
def gate(monkeypatch):
    """El caller tiene correccion_edicion; `gate.conceder(...)` cambia el conjunto de permisos."""
    estado = type("Gate", (), {})()
    estado.permisos = {"correccion_edicion"}
    estado.conceder = lambda *codigos: setattr(estado, "permisos", set(codigos))
    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda db, caller: PERSONA_ID)
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda db, persona, codigo: codigo in estado.permisos)
    return estado


MARCA_ID = 7
PERSONA_ID = "persona-caller"
CORRECCION_ID = 3
CALLER_IDENTITY = CallerIdentity(auth_user_id="auth-caller", correo="caller@example.com")

HOY_ISO = f"{date.today().isoformat()}T09:00:00+00:00"
HACE_100_DIAS_ISO = f"{(date.today() - timedelta(days=100)).isoformat()}T09:00:00+00:00"


def _payload(**overrides):
    payload = {
        "marca_id": MARCA_ID,
        "valor_corregido": "2026-01-01T09:05:00+00:00",
        "motivo": "reloj no sincronizado",
    }
    payload.update(overrides)
    return payload


def _fila_correccion(**overrides):
    fila = {
        "id": CORRECCION_ID,
        "marca_id": MARCA_ID,
        "valor_corregido": "2026-01-01T09:05:00+00:00",
        "motivo": "reloj no sincronizado",
        "autor_id": PERSONA_ID,
        "creado_en": "2026-01-01T09:10:00+00:00",
    }
    fila.update(overrides)
    return fila


def _tabla_correccion(fila=None, error=None):
    tabla = _tabla([])
    if error is not None:
        tabla.insert.return_value.execute.side_effect = error
    else:
        tabla.insert.return_value.execute.return_value.data = [fila or _fila_correccion()]
    return tabla


def _escenario(momento=HOY_ISO, estados_excepcion=("pendiente",), correccion=None):
    return _db(
        marca=_tabla([{"id": MARCA_ID, "momento_dispositivo": momento}]),
        excepcion=_tabla([{"estado": e, "motivo_revision": "reloj_no_sincronizado"} for e in estados_excepcion]),
        correccion=correccion or _tabla_correccion(),
    )


def _post(db):
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CALLER_IDENTITY
    return TestClient(app).post(
        "/api/correcciones", json=_payload(), headers={"Authorization": "Bearer fake-token"}
    )


def test_corregir_marca_con_excepcion_pendiente_exitosa(gate):
    response = _post(_escenario())
    assert response.status_code == 201, response.text
    assert response.json()["autor_id"] == PERSONA_ID


def test_corregir_marca_no_encontrada_devuelve_404(gate):
    db = _db(marca=_tabla([]))
    assert _post(db).status_code == 404


def test_corregir_marca_sin_excepcion_devuelve_422(gate):
    db = _db(marca=_tabla([{"id": MARCA_ID, "momento_dispositivo": HOY_ISO}]), excepcion=_tabla([]))
    assert _post(db).status_code == 422


def test_corregir_marca_excepcion_resuelta_sin_permiso_reapertura_devuelve_403(gate):
    response = _post(_escenario(estados_excepcion=("resuelto",)))
    assert response.status_code == 403
    assert "excepcion_reapertura" in response.json()["detail"]


def test_corregir_marca_excepcion_resuelta_con_permiso_reapertura_exitosa(gate):
    gate.conceder("correccion_edicion", "excepcion_reapertura")
    response = _post(_escenario(estados_excepcion=("resuelto",)))
    assert response.status_code == 201, response.text


def test_corregir_sin_correccion_edicion_devuelve_403(gate):
    gate.conceder()
    db = _escenario()
    response = _post(db)
    assert response.status_code == 403
    db.postgrest.schema.return_value.table.side_effect("correccion").insert.assert_not_called()


def test_corregir_marca_ventana_vencida_devuelve_422(gate):
    """El fixture autouse cubre get_service_client (sin fila de parametro -> cae al valor de ejemplo,
    30): 100 días de por medio lo superan de sobra sin un mock puntual."""
    response = _post(_escenario(momento=HACE_100_DIAS_ISO))
    assert response.status_code == 422
    assert "30" in response.json()["detail"]


def test_corregir_marca_trigger_rechaza_orden_cronologico_devuelve_422_legible(gate):
    error = APIError(
        {
            "code": "P0001",
            "message": (
                "La corrección de la marca 7 rompería el orden cronológico: "
                "2026-01-01 09:05:00+00 no es posterior a la marca anterior"
            ),
        }
    )
    response = _post(_escenario(correccion=_tabla_correccion(error=error)))
    assert response.status_code == 422
    assert "rompería el orden cronológico" not in response.json()["detail"]
    assert "no se puede reordenar" in response.json()["detail"]
