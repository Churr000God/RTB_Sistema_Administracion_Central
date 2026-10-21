"""Zona horaria de los batches programados (bug real, confirmado en el Pi): el contenedor corre en UTC; `BackgroundScheduler()` sin zona disparaba el cron «03:00» a las 03:00 UTC = 21:00 DE MÉXICO
del día anterior, y `date.today()` daba la fecha UTC. El cierre del 20-oct corrió el 20-oct a las 21:00 y una marca de las 22:20 cayó como «marca tardía · día cerrado».

El reloj se congela parcheando `datetime` DENTRO de `app.zona` (la única fuente de «hoy» en México): una implementación que use `date.today()` o `datetime.now()` sin zona NO queda congelada y falla."""

import asyncio
from datetime import date, datetime, time, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from app import zona
from app.zona import ZONA_MEXICO

UTC = timezone.utc


def _congelar(instante_utc: datetime):
    """Parchea `datetime` en app.zona: `datetime.now(tz)` devuelve ese instante convertido a `tz` (o naive UTC sin tz)."""

    class FalsoDatetime(datetime):
        @classmethod
        def now(cls, tz=None):
            return instante_utc.astimezone(tz) if tz is not None else instante_utc.replace(tzinfo=None)

    return patch("app.zona.datetime", FalsoDatetime)


# --- el helper ---------------------------------------------------------------------------------------------------------------------------------------


def test_hoy_mexico_a_las_03_00z_es_el_dia_anterior_a_las_21_00_de_mexico():
    with _congelar(datetime(2026, 10, 21, 3, 0, tzinfo=UTC)):          # 21:00 del 20-oct en México
        assert zona.hoy_mexico() == date(2026, 10, 20)
        assert zona.ahora_mexico().time() == time(21, 0)
        assert zona.ahora_mexico().tzinfo is ZONA_MEXICO


def test_hoy_mexico_a_las_09_00z_es_el_mismo_dia_a_las_03_00_de_mexico():
    with _congelar(datetime(2026, 10, 21, 9, 0, tzinfo=UTC)):
        assert zona.hoy_mexico() == date(2026, 10, 21)
        assert zona.ahora_mexico().time() == time(3, 0)


def test_la_zona_es_explicita_no_la_del_contenedor():
    assert str(ZONA_MEXICO) == "America/Mexico_City"
    ahora = zona.ahora_mexico()
    assert ahora.utcoffset() == datetime.now(UTC).astimezone(ZONA_MEXICO).utcoffset()


# --- el scheduler -------------------------------------------------------------------------------------------------------------------------------------


def _correr_lifespan(extra=None):
    """Arranca el lifespan con un BackgroundScheduler REAL (sin arrancar sus hilos) y devuelve sus trabajos y los argumentos con que se creó."""
    from app.scheduler import lifespan

    creado = {}

    def fabrica(*args, **kwargs):
        planificador = BackgroundScheduler(*args, **kwargs)
        planificador.start = lambda *a, **k: None
        planificador.shutdown = lambda *a, **k: None
        creado["kwargs"] = kwargs
        creado["planificador"] = planificador
        return planificador

    async def escenario():
        with patch("app.scheduler.BackgroundScheduler", side_effect=fabrica), patch("app.scheduler._leer_hora_corrida_cierre_dia", return_value=(3, 0)):
            async with lifespan(MagicMock()):
                creado["trabajos"] = {t.id: t for t in creado["planificador"].get_jobs()}

    asyncio.run(escenario())
    return creado


def test_el_scheduler_se_crea_con_la_zona_de_mexico():
    creado = _correr_lifespan()
    assert creado["kwargs"].get("timezone") is ZONA_MEXICO


def test_el_cron_de_las_03_00_dispara_a_las_03_00_de_mexico_no_a_las_03_00_utc():
    """21:00 del 20-oct en México (03:00Z del 21): el siguiente disparo NO es «ya» sino las 03:00 de México del 21 = 09:00Z."""
    from app.scheduler import ID_JOB_BATCH_DE_CONFIANZA, ID_JOB_CIERRE_DIA

    creado = _correr_lifespan()
    ahora = datetime(2026, 10, 21, 3, 0, 1, tzinfo=UTC)
    for id_job in (ID_JOB_CIERRE_DIA, ID_JOB_BATCH_DE_CONFIANZA):
        trigger = creado["trabajos"][id_job].trigger
        assert trigger.timezone is ZONA_MEXICO
        siguiente = trigger.get_next_fire_time(None, ahora)
        assert siguiente.astimezone(UTC) == datetime(2026, 10, 21, 9, 0, tzinfo=UTC)


def test_el_corte_quincenal_dispara_los_dias_1_y_16_a_las_03_00_de_mexico():
    from app.scheduler import ID_JOB_CORTE_QUINCENAL

    trigger = _correr_lifespan()["trabajos"][ID_JOB_CORTE_QUINCENAL].trigger
    assert trigger.timezone is ZONA_MEXICO
    # 21:00 de México del 15-oct (03:00Z del 16): el siguiente es el 16 a las 03:00 de México (09:00Z), no «ya»
    assert trigger.get_next_fire_time(None, datetime(2026, 10, 16, 3, 0, 1, tzinfo=UTC)).astimezone(UTC) == datetime(2026, 10, 16, 9, 0, tzinfo=UTC)


def _ejecutar_jobs_con_reloj(instante_utc):
    from app.scheduler import ID_JOB_BATCH_DE_CONFIANZA, ID_JOB_CIERRE_DIA, ID_JOB_CORTE_QUINCENAL

    creado = _correr_lifespan()
    with (
        _congelar(instante_utc),
        patch("app.scheduler.ejecutar_batch_de_confianza") as confianza,
        patch("app.scheduler.ejecutar_cierre_dia") as cierre,
        patch("app.scheduler.ejecutar_corte_quincenal") as corte,
    ):
        for id_job in (ID_JOB_BATCH_DE_CONFIANZA, ID_JOB_CIERRE_DIA, ID_JOB_CORTE_QUINCENAL):
            creado["trabajos"][id_job].func()
    return confianza, cierre, corte


def test_a_las_03_00z_hoy_es_el_dia_d_de_mexico_y_cierre_dia_procesa_d_menos_1():
    """03:00Z del 21 = 21:00 del 20 en México: hoy = 20, cierre_dia procesa el 19 (nunca el 20, que aún no termina)."""
    confianza, cierre, corte = _ejecutar_jobs_con_reloj(datetime(2026, 10, 21, 3, 0, tzinfo=UTC))
    confianza.assert_called_once_with(date(2026, 10, 20))
    cierre.assert_called_once_with(date(2026, 10, 19))
    corte.assert_called_once_with(date(2026, 10, 20))


def test_a_las_09_00z_del_dia_d_mas_1_cierre_dia_procesa_d():
    """09:00Z del 21 = 03:00 del 21 en México: hoy = 21, cierre_dia procesa el 20 (el día completo que acaba de terminar)."""
    confianza, cierre, corte = _ejecutar_jobs_con_reloj(datetime(2026, 10, 21, 9, 0, tzinfo=UTC))
    confianza.assert_called_once_with(date(2026, 10, 21))
    cierre.assert_called_once_with(date(2026, 10, 20))
    corte.assert_called_once_with(date(2026, 10, 21))


def test_leer_hora_corrida_pide_el_parametro_con_la_fecha_de_mexico():
    from app.scheduler import _leer_hora_corrida_cierre_dia

    visto = []
    with _congelar(datetime(2026, 10, 21, 3, 0, tzinfo=UTC)), patch("app.scheduler.crear_cliente_servicio"), patch(
        "app.scheduler.resolver_umbral_cierre_dia_cron", side_effect=lambda db, fecha: visto.append(fecha) or (3, 0)
    ):
        assert _leer_hora_corrida_cierre_dia() == (3, 0)
    assert visto == ["2026-10-20"]                                    # la fecha de México, no la UTC (21)


def test_03_00_significa_03_00_de_mexico_lo_que_dicen_la_ui_y_el_parametro():
    trigger = CronTrigger(hour=3, minute=0, timezone=ZONA_MEXICO)
    siguiente = trigger.get_next_fire_time(None, datetime(2026, 10, 21, 8, 59, tzinfo=UTC))
    assert siguiente.astimezone(ZONA_MEXICO).strftime("%H:%M") == "03:00" and siguiente.astimezone(UTC).hour == 9


# --- el disparo manual y otras reglas por día -------------------------------------------------------------------------------------------------------


def _cliente_corridas():
    from fastapi.testclient import TestClient

    from app.deps import get_caller_client, get_service_client
    from app.main import app
    from tests.test_corridas_batch import _entradas_gate, _fake_caller_client_secuencia, _override_identidad

    app.dependency_overrides[get_caller_client] = lambda: _fake_caller_client_secuencia(_entradas_gate())
    app.dependency_overrides[get_service_client] = lambda: MagicMock()
    _override_identidad()
    return TestClient(app), app


def test_el_disparo_manual_de_cierre_dia_usa_la_hora_y_el_dia_de_mexico_para_el_umbral():
    """01:00Z del 21 = 19:00 del 20 en México. Umbral 03:00: en México ya pasó (19:00 >= 03:00) y se permite; con la hora UTC (01:00) se habría rechazado."""
    cliente, app = _cliente_corridas()
    with (
        _congelar(datetime(2026, 10, 21, 1, 0, tzinfo=UTC)),
        patch("app.routers.corridas_batch.resolver_umbral_cierre_dia", return_value=time(3, 0)),
        patch("app.routers.corridas_batch.ejecutar_cierre_dia", return_value={"id": 1, "tipo_batch": "cierre_dia", "fecha": "2026-10-20", "estado": "exitosa", "intentos": 1,
                                                                             "iniciado_en": "2026-10-21T01:00:00+00:00", "terminado_en": "2026-10-21T01:00:05+00:00", "detalle": "x"}) as ejecutar,
    ):
        r = cliente.post("/api/corridas-batch/cierre-dia", headers={"Authorization": "Bearer t"})
    app.dependency_overrides.clear()
    assert r.status_code == 200, r.text
    assert ejecutar.call_args.args[0] == date(2026, 10, 20)


def test_el_disparo_manual_rechaza_como_futuro_el_dia_utc_que_en_mexico_todavia_no_llega():
    cliente, app = _cliente_corridas()
    with _congelar(datetime(2026, 10, 21, 1, 0, tzinfo=UTC)), patch("app.routers.corridas_batch.ejecutar_cierre_dia") as ejecutar:
        r = cliente.post("/api/corridas-batch/cierre-dia", json={"fecha": "2026-10-21"}, headers={"Authorization": "Bearer t"})
    app.dependency_overrides.clear()
    assert r.status_code == 422 and not ejecutar.called               # el 21 aún es futuro en México (hoy = 20)


def test_dias_habiles_pide_el_parametro_con_la_fecha_de_mexico(monkeypatch):
    from app import dias_habiles

    capturado = []
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.lte.side_effect = lambda campo, valor: capturado.append(valor) or tabla.select.return_value.eq.return_value.lte.return_value
    tabla.select.return_value.eq.return_value.lte.return_value.order.return_value.limit.return_value.execute.return_value.data = []
    db = MagicMock()
    db.postgrest.schema.return_value.table.return_value = tabla
    monkeypatch.setattr(dias_habiles, "crear_cliente_servicio", lambda settings: db)
    monkeypatch.setattr(dias_habiles, "get_settings", lambda: None)
    with _congelar(datetime(2026, 10, 21, 3, 0, tzinfo=UTC)):
        dias_habiles._dias_habiles_limite()
    assert capturado == ["2026-10-20"]


def test_ningun_modulo_de_app_usa_date_today_ni_datetime_now_sin_zona():
    """Guarda de CI: `date.today()` y `datetime.now()` sin zona dependen del contenedor (UTC). Solo `app/zona.py` (y comentarios) pueden mencionarlos."""
    import re
    from pathlib import Path

    raiz = Path(__file__).resolve().parents[1] / "app"
    patron = re.compile(r"(?<![\w`'\"#])(date\.today\(\)|datetime\.now\(\)|datetime\.today\(\)|datetime\.utcnow\(\))")
    infractores = {}
    for ruta in sorted(raiz.rglob("*.py")):
        if ruta.name == "zona.py":
            continue
        for numero, linea in enumerate(ruta.read_text(encoding="utf-8").splitlines(), 1):
            codigo = linea.split("#", 1)[0]
            if patron.search(codigo) and not codigo.strip().startswith(("`", '"', "'")) and "`" not in codigo:
                infractores.setdefault(str(ruta.relative_to(raiz)), []).append(numero)
    assert infractores == {}, f"usa app.zona.hoy_mexico()/ahora_mexico(): {infractores}"
