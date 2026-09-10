from datetime import date
from unittest.mock import MagicMock

from fastapi.testclient import TestClient

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.main import app

PERSONA_ID = "aaaaaaaa-0000-0000-0000-000000000001"
JORNADA_ID = 6

FECHA = date(2026, 9, 7)
DIAS_SEMANA = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
DIA_SEMANA = DIAS_SEMANA[FECHA.isoweekday() - 1]

GATE_PUESTO_ID = "puesto-ficticio-gate"
GATE_IDENTITY = CallerIdentity(auth_user_id="auth-ficticio-gate", correo="gate-ficticio@example.com")


def _tabla_encadenable(datos):
    """El builder real encadena select/eq/lte/gte/in_/order antes de execute() -- cada filtro
    devuelve el mismo builder (self); sirve para las 5 formas distintas de consulta de este
    router sin necesitar un mock por cada una."""
    tabla = MagicMock()
    for metodo in ("select", "eq", "lte", "gte", "in_", "order", "is_"):
        getattr(tabla, metodo).return_value = tabla
    tabla.execute.return_value = MagicMock(data=datos)
    return tabla


def _entradas_gate():
    return [
        ("usuario", _tabla_encadenable([{"persona_id": "persona-ficticia-gate"}])),
        ("asignacion", _tabla_encadenable([{"puesto_id": GATE_PUESTO_ID}])),
        ("puesto_permiso", _tabla_encadenable([{"puesto_id": GATE_PUESTO_ID}])),
    ]


def _fake_client_secuencia(secuencia):
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


def _jornada(**overrides):
    fila = {
        "id": JORNADA_ID,
        "persona_id": PERSONA_ID,
        "vigente_desde": "2026-06-01",
        "vigente_hasta": None,
    }
    fila.update(overrides)
    return fila


def _patron():
    return [
        {
            "jornada_asignada_id": JORNADA_ID,
            "dia_semana": DIA_SEMANA,
            "hora_entrada": "08:00:00",
            "hora_salida": "17:00:00",
        }
    ]


def _marca(hora_utc):
    return {
        "persona_id": PERSONA_ID,
        "momento_dispositivo": f"{FECHA.isoformat()}T{hora_utc}+00:00",
        "desfase_local": "+00:00",
    }


def _tolerancia(minutos=10):
    return [{"valor": str(minutos), "vigente_desde": "2026-01-01"}]


def _persona_nombre():
    return [{"id": PERSONA_ID, "primer_nombre": "Ana", "apellido_paterno": "Pérez"}]


def _pedir(**params):
    params.setdefault("desde", FECHA.isoformat())
    params.setdefault("hasta", FECHA.isoformat())
    client = TestClient(app)
    response = client.get(
        "/api/alertas-de-retardo", params=params, headers={"Authorization": "Bearer fake-token"}
    )
    app.dependency_overrides.clear()
    return response


def test_alerta_por_ambos_extremos_fuera_de_tolerancia():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            ("dia", _tabla_encadenable([])),
            ("marca", _tabla_encadenable([_marca("08:45:00"), _marca("18:00:00")])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    cuerpo = _pedir().json()
    assert len(cuerpo["alertas"]) == 1
    alerta = cuerpo["alertas"][0]
    assert alerta["motivo"] == "fuera_de_tolerancia"
    assert alerta["persona_nombre"] == "Ana Pérez"


def test_sin_alerta_si_un_extremo_coincide_dentro_de_tolerancia():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            ("dia", _tabla_encadenable([])),
            # Entrada 5 min tarde (dentro de la tolerancia de 10) -- basta un extremo para no alertar.
            ("marca", _tabla_encadenable([_marca("08:05:00"), _marca("18:00:00")])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    assert _pedir().json() == {"alertas": []}


def test_alerta_sin_marcas_motivo_sin_marcas():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            ("dia", _tabla_encadenable([])),
            ("marca", _tabla_encadenable([])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    cuerpo = _pedir().json()
    assert len(cuerpo["alertas"]) == 1
    assert cuerpo["alertas"][0]["motivo"] == "sin_marcas"
    assert cuerpo["alertas"][0]["primera_marca"] is None


def test_dia_con_ausencia_autorizada_se_excluye():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            (
                "dia",
                _tabla_encadenable(
                    [
                        {
                            "persona_id": PERSONA_ID,
                            "fecha": FECHA.isoformat(),
                            "estado": "cerrado",
                            "origen": "ausencia_autorizada",
                        }
                    ]
                ),
            ),
            ("marca", _tabla_encadenable([])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    assert _pedir().json() == {"alertas": []}


def test_dia_revisado_se_excluye():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            (
                "dia",
                _tabla_encadenable(
                    [
                        {
                            "persona_id": PERSONA_ID,
                            "fecha": FECHA.isoformat(),
                            "estado": "revisado",
                            "origen": None,
                        }
                    ]
                ),
            ),
            ("marca", _tabla_encadenable([_marca("08:45:00"), _marca("18:00:00")])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    assert _pedir().json() == {"alertas": []}


def test_dia_bloqueado_si_genera_alerta():
    fake_client = _fake_client_secuencia(
        _entradas_gate()
        + [
            ("jornada_asignada", _tabla_encadenable([_jornada()])),
            ("patron_semanal", _tabla_encadenable(_patron())),
            ("parametro", _tabla_encadenable(_tolerancia())),
            (
                "dia",
                _tabla_encadenable(
                    [
                        {
                            "persona_id": PERSONA_ID,
                            "fecha": FECHA.isoformat(),
                            "estado": "bloqueado",
                            "origen": None,
                        }
                    ]
                ),
            ),
            ("marca", _tabla_encadenable([_marca("08:45:00"), _marca("18:00:00")])),
            ("persona", _tabla_encadenable(_persona_nombre())),
        ]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    cuerpo = _pedir().json()
    assert len(cuerpo["alertas"]) == 1


def test_sin_jornada_normal_en_el_rango_no_consulta_nada_mas():
    fake_client = _fake_client_secuencia(
        _entradas_gate() + [("jornada_asignada", _tabla_encadenable([]))]
    )
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    assert _pedir().json() == {"alertas": []}


def test_rango_invertido_devuelve_422():
    fake_client = _fake_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    respuesta = _pedir(desde="2026-09-10", hasta="2026-09-01")
    assert respuesta.status_code == 422


def test_rango_demasiado_amplio_devuelve_422():
    fake_client = _fake_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_caller_client] = lambda: fake_client
    _override_identidad()

    respuesta = _pedir(desde="2026-01-01", hasta="2026-12-31")
    assert respuesta.status_code == 422
