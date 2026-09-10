# backend/tests/test_health.py
from fastapi.testclient import TestClient

from app.main import app


def test_salud_responde_ok():
    client = TestClient(app)
    response = client.get("/salud")
    assert response.status_code == 200
    assert response.json() == {"estado": "ok"}
