"""Precondición de esquema (R2 de despliegue de security): orden DDL -> backend -> frontend. Sin red: clientes falsos."""

import importlib.util
import logging
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from postgrest.exceptions import APIError

from app import precondiciones
from app.precondiciones import ESQUEMA_REQUERIDO, PrecondicionNoVerificable, faltantes, mensaje, verificar_al_arrancar


def _cliente(error=None):
    db = MagicMock()
    consulta = db.postgrest.schema.return_value.table.return_value.select.return_value.limit.return_value
    if error is not None:
        consulta.execute.side_effect = error
    return db


def test_la_columna_huella_evidencia_es_una_precondicion_con_su_migracion():
    assert ("tiempo", "terminal_usuario", "huella_evidencia", "db/ddl/94_tiempo_terminal_huella_evidencia.sql") in ESQUEMA_REQUERIDO


def test_si_la_base_tiene_la_columna_no_falta_nada():
    db = _cliente()
    assert faltantes(db) == []
    db.postgrest.schema.assert_called_with("tiempo")
    db.postgrest.schema.return_value.table.assert_any_call("terminal_usuario")
    db.postgrest.schema.return_value.table.return_value.select.assert_any_call("huella_evidencia")
    db.postgrest.schema.return_value.table.assert_any_call("terminal")                        # 99_: tiempo.terminal.ingesta_detenida
    db.postgrest.schema.return_value.table.return_value.select.assert_any_call("ingesta_detenida")


@pytest.mark.parametrize("codigo", ["42703", "42P01", "PGRST204", "PGRST205"])
def test_la_columna_o_tabla_inexistente_es_un_faltante_definitivo(codigo):
    assert faltantes(_cliente(APIError({"code": codigo, "message": "texto crudo"}))) == list(ESQUEMA_REQUERIDO)


@pytest.mark.parametrize("error", [APIError({"code": "42501", "message": "x"}), APIError({"code": "XX999", "message": "x"}), ConnectionError("red"), TimeoutError()])
def test_cualquier_otro_fallo_no_es_un_faltante_es_no_verificable(error):
    with pytest.raises(PrecondicionNoVerificable) as e:
        faltantes(_cliente(error))
    assert "texto" not in str(e.value) and "x" != str(e.value)


def test_el_mensaje_nombra_la_columna_la_migracion_y_el_orden():
    texto = mensaje(list(ESQUEMA_REQUERIDO))
    assert "huella_evidencia" in texto and "94_tiempo_terminal_huella_evidencia.sql" in texto and "DDL -> backend -> frontend" in texto


def test_al_arrancar_con_un_faltante_definitivo_el_backend_se_niega(monkeypatch, caplog):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "on")
    with caplog.at_level(logging.CRITICAL), pytest.raises(RuntimeError, match="Falta aplicar migraciones"):
        verificar_al_arrancar(_cliente(APIError({"code": "42703", "message": "x"})))
    assert "huella_evidencia" in caplog.text


def test_al_arrancar_sin_poder_consultar_solo_advierte_y_sigue(monkeypatch, caplog):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "on")
    with caplog.at_level(logging.WARNING):
        verificar_al_arrancar(_cliente(ConnectionError("red caída")))
    assert "no se pudo verificar" in caplog.text


def test_al_arrancar_con_todo_en_orden_no_hace_ruido(monkeypatch, caplog):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "on")
    verificar_al_arrancar(_cliente())
    assert caplog.records == []


def test_la_variable_off_apaga_la_verificacion(monkeypatch):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "off")
    verificar_al_arrancar(_cliente(APIError({"code": "42703", "message": "x"})))             # no lanza


def test_sin_configuracion_de_supabase_el_arranque_solo_advierte(monkeypatch, caplog):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "on")
    for v in ("SUPABASE_URL", "SUPABASE_ANON_KEY", "SUPABASE_SERVICE_ROLE_KEY"):
        monkeypatch.delenv(v, raising=False)
    monkeypatch.setattr("app.config.get_settings", MagicMock(side_effect=ValueError("sin env")))
    with caplog.at_level(logging.WARNING):
        verificar_al_arrancar()
    assert "no se pudo preparar la verificación" in caplog.text


def test_el_lifespan_aborta_el_arranque_si_falta_una_migracion(monkeypatch):
    import asyncio

    from app import scheduler

    def falta():
        raise RuntimeError("Falta aplicar migraciones")

    monkeypatch.setattr(scheduler, "verificar_esquema_al_arrancar", falta)

    async def arrancar():
        async with scheduler.lifespan(MagicMock()):
            pass

    with pytest.raises(RuntimeError, match="Falta aplicar"):
        asyncio.run(arrancar())


# --- scripts/verificar_esquema.py y scripts/desplegar.sh -------------------------------------------------------------------------------------------------

RAIZ = Path(__file__).resolve().parents[2]


def _script():
    spec = importlib.util.spec_from_file_location("verificar_esquema", RAIZ / "scripts" / "verificar_esquema.py")
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


def test_el_script_devuelve_0_1_o_2_segun_el_caso(capsys):
    script = _script()
    assert script.principal(_cliente()) == 0
    assert script.principal(_cliente(APIError({"code": "42703", "message": "x"}))) == 1
    assert "huella_evidencia" in capsys.readouterr().err
    assert script.principal(_cliente(ConnectionError("red"))) == 2
    assert "no se pudo verificar" in capsys.readouterr().err


def test_desplegar_sh_verifica_el_esquema_antes_de_levantar_los_contenedores_y_aborta_con_1():
    sh = (RAIZ / "scripts" / "desplegar.sh").read_text(encoding="utf-8")
    levantar = sh[sh.index("  levantar)"):sh.index("  bajar)")]
    assert levantar.index("verificar_esquema_requerido") < levantar.index("compose up -d --build")
    funcion = sh[sh.index("verificar_esquema_requerido() {"):sh.index("# Bootstrap del usuario base")]
    assert "verificar_esquema.py" in funcion and '"$codigo" -eq 1' in funcion and "exit 1" in funcion


def test_scj_precondiciones_off_nunca_queda_en_env_example_compose_ni_dockerfiles():
    """Sólo existe para pruebas y emergencias: no debe viajar en la configuración de despliegue (ni el conftest que la apaga afecta fuera de pytest)."""
    candidatos = [*RAIZ.glob(".env*"), *RAIZ.glob("docker-compose*.y*ml"), *RAIZ.glob("**/Dockerfile*"), *RAIZ.glob("frontend/.env*"), RAIZ / "scripts" / "desplegar.sh"]
    candidatos = [c for c in candidatos if c.is_file() and ".venv" not in c.parts and "node_modules" not in c.parts]
    assert candidatos and not [c.name for c in candidatos if "SCJ_PRECONDICIONES" in c.read_text(encoding="utf-8", errors="replace")]


# --- funciones del interruptor de la activación por huella (97_) ------------------------------------------------------------------------------


def _cliente_con_rpc(errores):
    """errores: {nombre_de_funcion: APIError|None}; las tablas responden bien."""
    db = MagicMock()
    db.postgrest.schema.return_value.table.return_value.select.return_value.limit.return_value.execute.return_value = None

    def rpc(nombre, params):
        r = MagicMock()
        error = errores.get(nombre)
        if error is not None:
            r.execute.side_effect = error
        return r

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    return db


def test_las_funciones_del_interruptor_y_del_latido_son_precondiciones_de_sus_migraciones():
    from app.precondiciones import FUNCIONES_REQUERIDAS

    assert {f[1] for f in FUNCIONES_REQUERIDAS} == {"fn_terminal_inferir_huella_estado", "fn_terminal_inferir_huella_cambiar", "fn_terminal_latido"}
    assert all(f[3] == "db/ddl/97_tiempo_terminal_inferir_huella_interruptor.sql" for f in FUNCIONES_REQUERIDAS if f[1] != "fn_terminal_latido")
    assert [f[3] for f in FUNCIONES_REQUERIDAS if f[1] == "fn_terminal_latido"] == ["db/ddl/99_tiempo_terminal_ingesta_detenida.sql"]


def test_con_las_funciones_presentes_no_falta_nada():
    assert faltantes(_cliente_con_rpc({"fn_terminal_inferir_huella_cambiar": APIError({"code": "42501", "message": "x"})})) == []   # sin EXECUTE para service_role: existe


def test_una_funcion_inexistente_es_un_faltante_con_su_migracion():
    perdidas = faltantes(_cliente_con_rpc({"fn_terminal_inferir_huella_estado": APIError({"code": "PGRST202", "message": "no function"})}))
    assert perdidas == [("tiempo", "fn_terminal_inferir_huella_estado", "función", "db/ddl/97_tiempo_terminal_inferir_huella_interruptor.sql")]
    assert "97_tiempo_terminal_inferir_huella_interruptor.sql" in mensaje(perdidas) and "fn_terminal_inferir_huella_estado" in mensaje(perdidas)


def test_la_comprobacion_de_la_funcion_de_cambio_no_puede_escribir():
    """Se llama con parámetros NULOS y service_role (sin EXECUTE): la base responde 42501 antes de ejecutar; la comprobación nunca lleva una nota ni un p_activa verdadero."""
    db = _cliente_con_rpc({"fn_terminal_inferir_huella_cambiar": APIError({"code": "42501", "message": "x"})})
    faltantes(db)
    llamadas_cambiar = [c for c in db.postgrest.schema.return_value.rpc.call_args_list if c.args[0] == "fn_terminal_inferir_huella_cambiar"]
    assert [c.args[1] for c in llamadas_cambiar] == [{"p_activa": None, "p_nota": None, "p_hasta": None}]


def test_n2_la_comprobacion_nunca_pasa_un_parametro_distinto_de_nulo_a_la_funcion_de_escritura():
    """Si alguien cambiara FUNCIONES_REQUERIDAS para llamar la función de cambio con un valor real (p_activa=True, una nota…), la comprobación del arranque ESCRIBIRÍA en la base."""
    from app.precondiciones import FUNCIONES_REQUERIDAS

    escrituras = [f for f in FUNCIONES_REQUERIDAS if f[1] == "fn_terminal_inferir_huella_cambiar"]
    assert len(escrituras) == 1
    assert set(escrituras[0][2]) == {"p_activa", "p_nota", "p_hasta"} and all(valor is None for valor in escrituras[0][2].values())
    lecturas = [f for f in FUNCIONES_REQUERIDAS if f[1] == "fn_terminal_inferir_huella_estado"]
    assert lecturas and all(f[2] == {} for f in lecturas)           # la de estado es de solo lectura y sin parámetros


def test_99_la_comprobacion_del_latido_usa_una_terminal_que_nunca_existe_y_todo_lo_demas_nulo():
    """fn_terminal_latido SÍ escribe, pero valida la terminal ANTES (SCJ12 si no existe o no está activa). La comprobación pasa la terminal 0 (los ids son identity desde 1) y nulos."""
    from app.precondiciones import FUNCIONES_REQUERIDAS

    latido = [f for f in FUNCIONES_REQUERIDAS if f[1] == "fn_terminal_latido"]
    assert len(latido) == 1
    parametros = latido[0][2]
    assert list(parametros) == ["p_terminal_id", "p_hora_terminal", "p_alcanzable", "p_reloj_sincronizado", "p_version_pi", "p_marcas_pendientes", "p_ingesta_detenida"]
    assert parametros["p_terminal_id"] == 0 and all(v is None for k, v in parametros.items() if k != "p_terminal_id")


def test_99_la_firma_de_7_argumentos_ausente_es_un_faltante_y_scj12_significa_que_existe():
    perdidas = faltantes(_cliente_con_rpc({"fn_terminal_latido": APIError({"code": "PGRST202", "message": "no function with parameters"})}))
    assert perdidas == [("tiempo", "fn_terminal_latido", "función", "db/ddl/99_tiempo_terminal_ingesta_detenida.sql")]
    assert faltantes(_cliente_con_rpc({"fn_terminal_latido": APIError({"code": "SCJ12", "message": "x", "hint": "terminal_no_valida"}),
                                       "fn_terminal_inferir_huella_cambiar": APIError({"code": "42501", "message": "x"})})) == []


def test_99_la_columna_ingesta_detenida_es_una_precondicion_con_su_migracion():
    assert ("tiempo", "terminal", "ingesta_detenida", "db/ddl/99_tiempo_terminal_ingesta_detenida.sql") in ESQUEMA_REQUERIDO


def test_un_fallo_raro_al_comprobar_la_funcion_es_no_verificable():
    with pytest.raises(PrecondicionNoVerificable):
        faltantes(_cliente_con_rpc({"fn_terminal_inferir_huella_estado": APIError({"code": "XX999", "message": "x"})}))
