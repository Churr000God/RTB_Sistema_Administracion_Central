import asyncio
from datetime import date, timedelta
from unittest.mock import MagicMock, patch

from app.scheduler import (
    HORA_POR_DEFECTO,
    ID_JOB_BATCH_DE_CONFIANZA,
    ID_JOB_CIERRE_DIA,
    ID_JOB_CORTE_QUINCENAL,
    _leer_hora_corrida_cierre_dia,
    lifespan,
)


def _fake_db_parametros(valores):
    """valores: {clave: valor_str}. Un solo mock de tabla distingue cada llamada por el valor
    pasado a .eq('clave', ...) -- el umbral real lee hora_corte_dia Y hora_corrida_cierre_dia por
    separado (app/hora_cierre_dia.py), no una sola clave como antes de este corte."""
    fake_client = MagicMock()
    tabla = MagicMock()

    def eq_side_effect(campo, valor_clave):
        assert campo == "clave"
        resultado = MagicMock()
        datos = [{"valor": valores[valor_clave]}] if valor_clave in valores else []
        (
            resultado.lte.return_value.order.return_value.limit.return_value.execute
            .return_value.data
        ) = datos
        return resultado

    tabla.select.return_value.eq.side_effect = eq_side_effect
    fake_client.postgrest.schema.return_value.table.return_value = tabla
    return fake_client


def test_lee_hora_suma_las_2_claves():
    """El umbral real es hora_corte_dia + hora_corrida_cierre_dia (SCJ-PRO-12 §V), no sólo el
    colchón -- con 01:15 + 02:30 el resultado (03:45) no coincide con ninguna de las 2 claves por
    separado, distingue la suma real de usar sólo una."""
    fake_db = _fake_db_parametros({"hora_corte_dia": "01:15", "hora_corrida_cierre_dia": "02:30"})
    with patch("app.scheduler.get_service_client", return_value=fake_db):
        assert _leer_hora_corrida_cierre_dia() == (3, 45)


def test_sin_filas_de_parametro_usa_default():
    fake_db = _fake_db_parametros({})
    with patch("app.scheduler.get_service_client", return_value=fake_db):
        assert _leer_hora_corrida_cierre_dia() == HORA_POR_DEFECTO


def test_error_leyendo_parametro_usa_default_no_tumba_arranque():
    with patch("app.scheduler.get_service_client", side_effect=RuntimeError("sin red")):
        assert _leer_hora_corrida_cierre_dia() == HORA_POR_DEFECTO


def test_lifespan_arranca_los_3_jobs_a_la_misma_hora_y_apaga_el_scheduler():
    """Sin pytest-asyncio en el proyecto -- se maneja el context manager async a mano con
    asyncio.run en vez de declarar el test como async def (quedaría sin correr, sin plugin).
    Los 3 batches comparten la misma hora leída una sola vez (SCJ-PRO-14: "mismo colchón/hora
    que SCJ-PRO-12"; corte_quincenal reusa la misma por no existir un parámetro propio), cada
    uno con su propio id fijo + replace_existing=True. corte_quincenal además sólo dispara los
    días 1 y 16."""
    fake_scheduler = MagicMock()

    async def escenario():
        with (
            patch("app.scheduler.BackgroundScheduler", return_value=fake_scheduler),
            patch("app.scheduler._leer_hora_corrida_cierre_dia", return_value=(3, 0)),
        ):
            app_falso = MagicMock()
            async with lifespan(app_falso):
                assert fake_scheduler.add_job.call_count == 3
                llamadas_por_id = {
                    llamada.kwargs["id"]: llamada for llamada in fake_scheduler.add_job.call_args_list
                }
                assert set(llamadas_por_id) == {
                    ID_JOB_BATCH_DE_CONFIANZA,
                    ID_JOB_CIERRE_DIA,
                    ID_JOB_CORTE_QUINCENAL,
                }
                for llamada in llamadas_por_id.values():
                    assert llamada.kwargs["replace_existing"] is True
                    assert llamada.kwargs["hour"] == 3
                    assert llamada.kwargs["minute"] == 0
                assert llamadas_por_id[ID_JOB_CORTE_QUINCENAL].kwargs["day"] == "1,16"
                assert "day" not in llamadas_por_id[ID_JOB_BATCH_DE_CONFIANZA].kwargs
                assert "day" not in llamadas_por_id[ID_JOB_CIERRE_DIA].kwargs
                fake_scheduler.start.assert_called_once()
                fake_scheduler.shutdown.assert_not_called()

    asyncio.run(escenario())
    fake_scheduler.shutdown.assert_called_once()


def test_lifespan_cierre_dia_recibe_ayer_los_otros_2_hoy():
    """Bug real corregido este corte: a la hora en que el job dispara, HOY recién empieza (sin
    marcas) -- cierre_dia debe procesar el día ANTERIOR. de_confianza y corte_quincenal SÍ siguen
    sobre date.today(), no se tocan."""
    fake_scheduler = MagicMock()

    async def escenario():
        with (
            patch("app.scheduler.BackgroundScheduler", return_value=fake_scheduler),
            patch("app.scheduler._leer_hora_corrida_cierre_dia", return_value=(3, 0)),
        ):
            app_falso = MagicMock()
            async with lifespan(app_falso):
                llamadas_por_id = {
                    llamada.kwargs["id"]: llamada for llamada in fake_scheduler.add_job.call_args_list
                }
                with (
                    patch("app.scheduler.ejecutar_batch_de_confianza") as mock_confianza,
                    patch("app.scheduler.ejecutar_cierre_dia") as mock_cierre,
                    patch("app.scheduler.ejecutar_corte_quincenal") as mock_corte,
                ):
                    llamadas_por_id[ID_JOB_BATCH_DE_CONFIANZA].args[0]()
                    llamadas_por_id[ID_JOB_CIERRE_DIA].args[0]()
                    llamadas_por_id[ID_JOB_CORTE_QUINCENAL].args[0]()

                    mock_confianza.assert_called_once_with(date.today())
                    mock_cierre.assert_called_once_with(date.today() - timedelta(days=1))
                    mock_corte.assert_called_once_with(date.today())

    asyncio.run(escenario())
