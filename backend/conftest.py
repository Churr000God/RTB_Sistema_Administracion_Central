"""Aislamiento global de pruebas: el limitador de fallos de la terminal (app/terminal_auth.py) es
estado en memoria a nivel de módulo y los overrides de dependencias de FastAPI son globales a `app`.
Sin reiniciarlos entre pruebas, una prueba hereda el bloqueo por IP o el override de otra."""

import pytest

from app import terminal_auth
from app.batches import terminales as jobs_terminales
from app.routers import anomalias_terminales
from app.main import app


@pytest.fixture(autouse=True)
def _aislar_estado_global():
    terminal_auth.limitador.reiniciar()
    terminal_auth._redes_confiables.cache_clear()
    jobs_terminales._SIN_AUTOR_PREVIO.clear()
    anomalias_terminales.CACHE.limpiar()
    yield
    terminal_auth.limitador.reiniciar()
    app.dependency_overrides.clear()
