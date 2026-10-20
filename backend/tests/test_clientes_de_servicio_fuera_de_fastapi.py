"""Regresión (5bdce98): `get_service_client(request, settings)` es una dependencia de FastAPI. Llamarla a mano como `get_service_client(get_settings())` mete Settings como `request` y revienta con
AttributeError: 'Settings' object has no attribute 'state'. Los batches, el scheduler y varios helpers la llamaban así: dejaron de correr en silencio (varios capturan toda excepción). Fuera de una
petición se usa `crear_cliente_servicio(settings)`.

1) Cada camino sin cliente inyectado construye su cliente de servicio (create_client mockeado, sin red). Como varios tragan excepciones y caen a valores por omisión, la prueba NO mira si el
   camino falla: mira que `create_client` SÍ se llamó con la llave de servicio (con el bug nunca llegaba).
2) Lint AST: ninguna llamada a `get_service_client(...)` en `backend/app` ni `backend/scripts` fuera de `Depends(...)`, y ninguna referencia a `crear_cliente_servicio` en `app/routers/`."""

import ast
from datetime import date
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from app import config

RAIZ = Path(__file__).resolve().parents[1] / "app"
RAICES = (RAIZ, Path(__file__).resolve().parents[1] / "scripts")      # el lint también cubre los scripts de TI (alta_credencial_terminal.py)
URL, ANON, SERVICIO = "http://supabase.invalido", "anon-ficticia", "service-ficticia"


class _Parar(Exception):
    pass


@pytest.fixture
def servicio_mockeado(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", URL)
    monkeypatch.setenv("SUPABASE_ANON_KEY", ANON)
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", SERVICIO)
    monkeypatch.setenv("SCJ_PRECONDICIONES", "on")
    config.get_settings.cache_clear()
    cliente = MagicMock()
    cliente.postgrest.schema.side_effect = _Parar        # cualquier uso real del cliente corta aquí: lo que se prueba es que se CONSTRUYÓ
    with patch("app.deps.create_client", return_value=cliente) as crear:
        yield crear
    config.get_settings.cache_clear()


def _caminos():
    from app import dias_habiles, precondiciones, scheduler
    from app.batches import cierre_dia, corte_quincenal, de_confianza, terminales

    hoy = date(2026, 10, 19)
    return {
        "cierre_dia": lambda: cierre_dia.ejecutar_cierre_dia(hoy),
        "batch_de_confianza": lambda: de_confianza.ejecutar_batch_de_confianza(hoy),
        "corte_quincenal": lambda: corte_quincenal.ejecutar_corte_quincenal(hoy),
        "terminales_cliente": terminales._cliente,
        "terminales_baja_por_caducidad": terminales.ejecutar_baja_por_caducidad,
        "terminales_purga_rechazos": terminales.ejecutar_purga_rechazos,
        "terminales_reconciliacion_bajas": terminales.ejecutar_reconciliacion_bajas,
        "scheduler_hora_corrida": scheduler._leer_hora_corrida_cierre_dia,
        "dias_habiles_limite": dias_habiles._dias_habiles_limite,
        "dias_habiles_festivos": lambda: dias_habiles._festivos_entre(date(2026, 10, 1), hoy),
        "precondiciones_al_arrancar": precondiciones.verificar_al_arrancar,
    }


@pytest.mark.parametrize("nombre", sorted([
    "cierre_dia", "batch_de_confianza", "corte_quincenal", "terminales_cliente", "terminales_baja_por_caducidad", "terminales_purga_rechazos",
    "terminales_reconciliacion_bajas", "scheduler_hora_corrida", "dias_habiles_limite", "dias_habiles_festivos", "precondiciones_al_arrancar",
]))
def test_cada_camino_sin_cliente_inyectado_construye_su_cliente_de_servicio_sin_attributeerror(nombre, servicio_mockeado):
    camino = _caminos()[nombre]
    try:
        camino()
    except AttributeError as error:
        pytest.fail(f"{nombre}: AttributeError {error!s} (¿se llamó a get_service_client(get_settings()) a mano?)")
    except Exception:  # noqa: BLE001 -- _Parar u otra: el cliente falso no sirve para más; importa que se construyó
        pass
    servicio_mockeado.assert_called()
    assert servicio_mockeado.call_args.args[:2] == (URL, SERVICIO), nombre


def test_crear_cliente_servicio_no_necesita_request_y_get_service_client_si_marca_la_peticion():
    from starlette.requests import Request

    import app.deps as deps
    from app.config import Settings

    ajustes = Settings(supabase_url=URL, supabase_anon_key=ANON, supabase_service_role_key=SERVICIO)
    with patch("app.deps.create_client", return_value=MagicMock()) as crear:
        deps.crear_cliente_servicio(ajustes)
        assert crear.call_args.args == (URL, SERVICIO)
        peticion = Request({"type": "http", "method": "GET", "path": "/", "headers": [], "query_string": b""})
        deps.get_service_client(peticion, ajustes)
        assert peticion.state.usa_cliente_servicio is True
        with pytest.raises(AttributeError):          # el bug: Settings en el lugar de `request`
            deps.get_service_client(ajustes)  # type: ignore[call-arg]


def _llamadas_a_get_service_client_fuera_de_depends(ruta: Path) -> list[int]:
    arbol = ast.parse(ruta.read_text(encoding="utf-8"))
    dentro_de_depends: set[int] = set()
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Name) and nodo.func.id == "Depends":
            for interno in ast.walk(nodo):
                dentro_de_depends.add(id(interno))
    lineas = []
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.Call) and id(nodo) not in dentro_de_depends:
            f = nodo.func
            if (isinstance(f, ast.Name) and f.id == "get_service_client") or (isinstance(f, ast.Attribute) and f.attr == "get_service_client"):
                lineas.append(nodo.lineno)
    return lineas


def test_ningun_modulo_de_la_app_ni_de_los_scripts_llama_a_get_service_client_a_mano():
    """`get_service_client` solo aparece como `Depends(get_service_client)` (referencia, no llamada) o en su definición. Una llamada directa fuera de FastAPI se rompe con Settings como `request`."""
    infractores = {str(ruta.relative_to(RAIZ.parent)): lineas for raiz in RAICES for ruta in sorted(raiz.rglob("*.py")) if (lineas := _llamadas_a_get_service_client_fuera_de_depends(ruta))}
    assert infractores == {}, f"usa crear_cliente_servicio(get_settings()) fuera de FastAPI: {infractores}"


def _usos_de_crear_cliente_servicio(ruta: Path) -> list[int]:
    arbol = ast.parse(ruta.read_text(encoding="utf-8"))
    return sorted({n.lineno for n in ast.walk(arbol) if (isinstance(n, ast.Name) and n.id == "crear_cliente_servicio") or (isinstance(n, ast.Attribute) and n.attr == "crear_cliente_servicio")
                   or (isinstance(n, ast.alias) and n.name == "crear_cliente_servicio")})


def test_ningun_router_usa_crear_cliente_servicio():
    """Un router que necesite el cliente de servicio lo pide con `Depends(get_service_client)`: así el manejador de APIError ve la marca `usa_cliente_servicio` y no culpa al token del usuario."""
    infractores = {str(r.relative_to(RAIZ.parent)): u for r in sorted((RAIZ / "routers").rglob("*.py")) if (u := _usos_de_crear_cliente_servicio(r))}
    assert infractores == {}, f"los routers usan Depends(get_service_client), no crear_cliente_servicio: {infractores}"


def test_el_lint_de_routers_detecta_el_uso(tmp_path):
    malo = tmp_path / "router.py"
    malo.write_text("from app.deps import crear_cliente_servicio\ndb = crear_cliente_servicio(x)\n", encoding="utf-8")
    assert _usos_de_crear_cliente_servicio(malo) == [1, 2]
    bueno = tmp_path / "ok.py"
    bueno.write_text("from app.deps import get_service_client\ndef f(db=Depends(get_service_client)):\n    pass\n", encoding="utf-8")
    assert _usos_de_crear_cliente_servicio(bueno) == []


def test_el_script_de_alta_de_credencial_construye_el_cliente_de_servicio_con_db_none(servicio_mockeado, capsys):
    """Sin red ni escritura real: `create_client` devuelve un cliente falso (terminal activa; el INSERT de la credencial cae en el mock)."""
    import importlib.util

    ruta = Path(__file__).resolve().parents[1] / "scripts" / "alta_credencial_terminal.py"
    spec = importlib.util.spec_from_file_location("alta_credencial_terminal_regresion", ruta)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    cliente = MagicMock()
    cliente.postgrest.schema.return_value.table.return_value.select.return_value.eq.return_value.execute.return_value.data = [{"id": 5, "terminal_id": "TERM-X", "activa": True}]
    servicio_mockeado.return_value = cliente
    assert modulo.main(["--serie", "TERM-X"], db=None) == 0
    servicio_mockeado.assert_called_once()
    assert servicio_mockeado.call_args.args[:2] == (URL, SERVICIO)
    salida = capsys.readouterr()
    assert "no se pudo guardar la credencial" not in salida.err and "AttributeError" not in salida.err


def test_el_lint_detecta_la_llamada_a_mano(tmp_path):
    malo = tmp_path / "malo.py"
    malo.write_text("from app.deps import get_service_client\ndb = get_service_client(get_settings())\ndef f(x=Depends(get_service_client)):\n    pass\n", encoding="utf-8")
    assert _llamadas_a_get_service_client_fuera_de_depends(malo) == [2]
    bueno = tmp_path / "bueno.py"
    bueno.write_text("from app.deps import crear_cliente_servicio, get_service_client\ndb = crear_cliente_servicio(get_settings())\ndef f(x=Depends(get_service_client)):\n    pass\n", encoding="utf-8")
    assert _llamadas_a_get_service_client_fuera_de_depends(bueno) == []
