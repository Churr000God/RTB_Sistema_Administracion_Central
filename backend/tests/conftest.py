"""Las pruebas no consultan la base real al arrancar: la precondición de esquema (app/precondiciones.py) se apaga salvo en sus propias pruebas."""

import pytest


@pytest.fixture(autouse=True)
def _sin_precondiciones_de_esquema(monkeypatch):
    monkeypatch.setenv("SCJ_PRECONDICIONES", "off")
