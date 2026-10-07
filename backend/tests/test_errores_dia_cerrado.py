"""86_*.sql: traducción de SCJ15 (por HINT), 42501/sin_permiso y 22023/motivo_invalido a HTTP con
mensajes FIJOS. El texto de la base nunca llega a la respuesta."""

import logging

import pytest
from fastapi import HTTPException
from postgrest.exceptions import APIError

from app import errores
from app.errores import manejar_error_dia_cerrado, traducir_error_dia_cerrado

CRUDO = "texto-crudo-con-id-interno-9981 (excepción 42)"


def _error(code, hint=None):
    return APIError({"code": code, "hint": hint, "message": CRUDO, "details": CRUDO})


CASOS = [
    (
        "SCJ15",
        "dia_cerrado_requiere_revision",
        409,
        "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día "
        "(o, si el día ya está revisado, descarta la marca tardía).",
    ),
    ("SCJ15", "excepcion_columna_inmutable", 409, "La excepción no se puede alterar."),
    ("SCJ15", "excepcion_motivo_inmutable", 409, "La excepción no se puede alterar."),
    ("SCJ15", "tramo_incoherente", 422, "La marca no corresponde a la persona o al día del tramo."),
    (
        "SCJ15",
        "dia_no_revisado",
        409,
        "El día todavía no está revisado: revísalo en vez de descartar la marca.",
    ),
    (
        "SCJ15",
        "excepcion_no_descartable",
        409,
        "Esta excepción no se puede descartar: no es una marca tardía de día cerrado, o ya está "
        "resuelta por otra vía.",
    ),
    ("42501", "sin_permiso", 403, "No tienes permiso para esta acción."),
    ("22023", "motivo_invalido", 422, "El motivo es obligatorio."),
]


@pytest.mark.parametrize("code,hint,estado,mensaje", CASOS)
def test_cada_hint_se_traduce_a_su_estado_y_mensaje_fijo(code, hint, estado, mensaje):
    traduccion = traducir_error_dia_cerrado(_error(code, hint))
    assert isinstance(traduccion, HTTPException)
    assert traduccion.status_code == estado
    assert traduccion.detail == mensaje
    assert "9981" not in traduccion.detail and "excepción 42" not in traduccion.detail


def test_mensaje_de_dia_cerrado_es_el_acordado():
    assert errores.MENSAJE_DIA_CERRADO_REQUIERE_REVISION == (
        "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el día "
        "(o, si el día ya está revisado, descarta la marca tardía)."
    )
    assert errores.MENSAJE_DIA_NO_REVISADO == (
        "El día todavía no está revisado: revísalo en vez de descartar la marca."
    )


def test_un_hint_scj15_desconocido_da_409_generico_sin_texto():
    traduccion = traducir_error_dia_cerrado(_error("SCJ15", "hint_nuevo_que_no_conozco"))
    assert traduccion.status_code == 409
    assert "9981" not in traduccion.detail


def test_scj15_sin_hint_da_409_generico():
    assert traducir_error_dia_cerrado(_error("SCJ15", None)).status_code == 409


def test_42501_sin_el_hint_del_rpc_es_403_y_deja_un_error_en_el_log(caplog):
    with caplog.at_level(logging.ERROR):
        traduccion = traducir_error_dia_cerrado(_error("42501", None))
    assert traduccion.status_code == 403
    assert any(x.levelno >= logging.ERROR for x in caplog.records)
    assert "9981" not in caplog.text


def test_42501_con_sin_permiso_no_ensucia_el_log_de_errores(caplog):
    with caplog.at_level(logging.ERROR):
        traducir_error_dia_cerrado(_error("42501", "sin_permiso"))
    assert not [x for x in caplog.records if x.levelno >= logging.ERROR]


@pytest.mark.parametrize(
    "code,hint", [("23505", None), ("SCJ11", "transicion_invalida"), ("SCJ12", "x"), ("XX000", None), (None, None)]
)
def test_lo_que_no_es_de_esta_familia_devuelve_none(code, hint):
    assert traducir_error_dia_cerrado(_error(code, hint)) is None


def test_manejar_error_levanta_la_traduccion():
    with pytest.raises(HTTPException) as excinfo:
        manejar_error_dia_cerrado(_error("SCJ15", "dia_no_revisado"))
    assert excinfo.value.status_code == 409


def test_manejar_error_relanza_lo_desconocido():
    with pytest.raises(APIError):
        manejar_error_dia_cerrado(_error("XX000"))


def test_los_mensajes_se_mantienen_con_su_texto_literal():
    """Las constantes del módulo no se usan como oráculo (serían una tautología): el texto es parte del
    contrato con el frontend y sólo cambia a propósito."""
    assert errores.MENSAJE_EXCEPCION_INMUTABLE == "La excepción no se puede alterar."
    assert errores.MENSAJE_TRAMO_INCOHERENTE == "La marca no corresponde a la persona o al día del tramo."
    assert errores.MENSAJE_SIN_PERMISO == "No tienes permiso para esta acción."
    assert errores.MENSAJE_MOTIVO_INVALIDO == "El motivo es obligatorio."
    assert errores.MENSAJE_SCJ15_GENERICO == (
        "La operación no es válida para el estado actual de la excepción o del día."
    )


def test_marca_en_tramo_del_87_se_traduce_al_mismo_409_fijo_del_guard():
    traduccion = traducir_error_dia_cerrado(_error("SCJ15", "marca_en_tramo"))
    assert traduccion.status_code == 409
    assert traduccion.detail == (
        "Esta marca ya forma parte de un tramo: no se puede corregir su hora desde aquí. Revisa el día."
    )
    assert "9981" not in traduccion.detail


def test_el_post_de_correcciones_traduce_marca_en_tramo_del_commit_o_del_insert(monkeypatch):
    """Si el guard previo no la hubiera detectado (carrera) y la base rechazara con 87_, el usuario ve el
    mismo mensaje claro en vez del 'No se pudo registrar la corrección.' genérico."""
    from unittest.mock import MagicMock

    from fastapi.testclient import TestClient

    from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
    from app.main import app
    from app.routers import correcciones

    monkeypatch.setattr(correcciones, "resolver_persona_id", lambda d, c: "p")
    monkeypatch.setattr(correcciones, "tiene_permiso", lambda d, p, c: True)
    monkeypatch.setattr(correcciones, "_validar_ventana", lambda f: None)

    def tabla(datos):
        t = MagicMock()
        for m in ("select", "eq", "or_", "in_"):
            getattr(t, m).return_value = t
        t.execute.return_value.data = datos
        return t

    corr = tabla([])
    corr.insert.return_value.execute.side_effect = _error("SCJ15", "marca_en_tramo")
    tablas = {
        "marca": tabla([{"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"}]),
        "excepcion": tabla([{"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"}]),
        "correccion": corr,
    }
    db = MagicMock()
    db.postgrest.schema.return_value.table.side_effect = lambda n: tablas[n]
    servicio = MagicMock()
    servicio.postgrest.schema.return_value.table.side_effect = lambda n: tabla([])  # el guard no la ve
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(auth_user_id="a", correo=None)
    app.dependency_overrides[get_service_client] = lambda: servicio
    r = TestClient(app).post(
        "/api/correcciones",
        json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"},
        headers={"Authorization": "Bearer t"},
    )
    assert r.status_code == 409
    assert r.json()["detail"].startswith("Esta marca ya forma parte de un tramo")
