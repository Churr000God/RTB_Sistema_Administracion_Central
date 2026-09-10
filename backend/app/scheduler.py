"""Orquestación de los jobs programados de los batches del subsistema Tiempo (SCJ-PRO-12/13/14) --
arranca/apaga un BackgroundScheduler de APScheduler en el lifespan de FastAPI (app/main.py).

Llama cada función de batch directo en Python, NO vía HTTP interno -- un job de sistema no debe
pasar por el gate de permisos pensado para callers humanos (confirmado con security).

de_confianza y cierre_dia corren TODOS los días a la MISMA hora -- el umbral real de
`app/hora_cierre_dia.py` (`hora_corte_dia + hora_corrida_cierre_dia`, SCJ-PRO-12 §V, no sólo el
colchón: divergencia real corregida en este corte). SCJ-PRO-14 documenta esa hora compartida
explícitamente como "mismo colchón/hora que SCJ-PRO-12", no es casualidad ni un parámetro nuevo
por batch. corte_quincenal reusa la MISMA hora (no existe un parámetro propio en el catálogo --
revisado, sólo están hora_corte_dia y hora_corrida_cierre_dia; corte_quincenal necesita correr
después de que cierre_dia ya haya procesado el último día del periodo, así que reusar el mismo
colchón es razonable), pero sólo dispara los días 1 y 16 de cada mes (SCJ-PRO-13 §III).

cierre_dia corre sobre el día ANTERIOR (`date.today() - timedelta(days=1)`) -- a la hora en que
el job dispara, el día de HOY recién empieza, sin marcas que cerrar (bug real: hasta este corte
el job pasaba `date.today()`, contradiciendo tanto la UI del panel de corridas como
`app/prevision_corte_quincenal.py`, que ya asumía que cierre_dia procesa el día anterior).
de_confianza y corte_quincenal SÍ corren sobre `date.today()` -- no se tocan."""

from contextlib import asynccontextmanager
from datetime import date, timedelta

from apscheduler.schedulers.background import BackgroundScheduler
from fastapi import FastAPI

from app.batches.cierre_dia import ejecutar_cierre_dia
from app.batches.corte_quincenal import ejecutar_corte_quincenal
from app.batches.de_confianza import ejecutar_batch_de_confianza
from app.config import get_settings
from app.deps import get_service_client
from app.hora_cierre_dia import resolver_umbral_cierre_dia_cron

ID_JOB_BATCH_DE_CONFIANZA = "batch_de_confianza_diario"
ID_JOB_CIERRE_DIA = "cierre_dia_diario"
ID_JOB_CORTE_QUINCENAL = "corte_quincenal_dia_1_y_16"
HORA_POR_DEFECTO = (3, 0)  # hora_corte_dia (00:00) + hora_corrida_cierre_dia (03:00), valores de
# ejemplo de db/ddl/03_parametros_ejemplo.sql


def _leer_hora_corrida_cierre_dia() -> tuple[int, int]:
    """Umbral real de los 3 jobs -- `app/hora_cierre_dia.py::resolver_umbral_cierre_dia_cron`
    (`hora_corte_dia + hora_corrida_cierre_dia`). Se lee una sola vez al arrancar el proceso, no
    hay reconfiguración en caliente todavía. Si Supabase no responde en ese momento, cae al
    valor de ejemplo sembrado en vez de tumbar el arranque del backend entero por un problema
    transitorio de red."""
    try:
        db = get_service_client(get_settings())
        return resolver_umbral_cierre_dia_cron(db, date.today().isoformat())
    except Exception:
        return HORA_POR_DEFECTO


@asynccontextmanager
async def lifespan(app: FastAPI):
    scheduler = BackgroundScheduler()
    hora, minuto = _leer_hora_corrida_cierre_dia()
    scheduler.add_job(
        lambda: ejecutar_batch_de_confianza(date.today()),
        trigger="cron",
        hour=hora,
        minute=minuto,
        id=ID_JOB_BATCH_DE_CONFIANZA,
        replace_existing=True,
    )
    scheduler.add_job(
        lambda: ejecutar_cierre_dia(date.today() - timedelta(days=1)),
        trigger="cron",
        hour=hora,
        minute=minuto,
        id=ID_JOB_CIERRE_DIA,
        replace_existing=True,
    )
    scheduler.add_job(
        lambda: ejecutar_corte_quincenal(date.today()),
        trigger="cron",
        day="1,16",
        hour=hora,
        minute=minuto,
        id=ID_JOB_CORTE_QUINCENAL,
        replace_existing=True,
    )
    scheduler.start()
    app.state.scheduler = scheduler
    try:
        yield
    finally:
        scheduler.shutdown()
