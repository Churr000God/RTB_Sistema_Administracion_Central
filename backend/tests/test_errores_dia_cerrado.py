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
    (
        "SCJ15",
        "tramo_tiempos_incoherentes",
        409,
        "Los tiempos del tramo no coinciden con sus marcas. Revisa las marcas del día antes de continuar.",
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


# --- 123_: tramo_tiempos_incoherentes (trg_tramo_valida_tiempos) -----------------------------------------------------------------------------------


def test_tramo_tiempos_incoherentes_se_distingue_por_hint_no_por_sqlstate():
    """SCJ15 con ESTE hint -> su mensaje; SCJ15 con otro hint o sin hint NO se traduce a este mensaje; el hint con otro SQLSTATE tampoco."""
    mensaje = errores.MENSAJE_TRAMO_TIEMPOS_INCOHERENTES
    assert traducir_error_dia_cerrado(_error("SCJ15", "tramo_tiempos_incoherentes")).detail == mensaje
    for otro_hint in ("tramo_incoherente", "marca_en_tramo", "dia_cerrado_requiere_revision", "hint_nuevo", None):
        assert traducir_error_dia_cerrado(_error("SCJ15", otro_hint)).detail != mensaje
    assert traducir_error_dia_cerrado(_error("23514", "tramo_tiempos_incoherentes")) is None
    assert traducir_error_dia_cerrado(_error("42501", "tramo_tiempos_incoherentes")).detail != mensaje


def test_los_demas_hints_de_scj15_siguen_como_hoy():
    esperado = {
        "dia_cerrado_requiere_revision": 409, "excepcion_columna_inmutable": 409, "excepcion_motivo_inmutable": 409,
        "tramo_incoherente": 422, "dia_no_revisado": 409, "excepcion_no_descartable": 409, "marca_en_tramo": 409,
    }
    for hint, estado in esperado.items():
        assert traducir_error_dia_cerrado(_error("SCJ15", hint)).status_code == estado, hint
    assert set(errores._SCJ15_POR_HINT) == set(esperado) | {"tramo_tiempos_incoherentes"}


def test_el_mensaje_es_en_tuteo_y_sin_datos_personales():
    mensaje = errores.MENSAJE_TRAMO_TIEMPOS_INCOHERENTES
    assert mensaje == "Los tiempos del tramo no coinciden con sus marcas. Revisa las marcas del día antes de continuar."
    assert "Revisa" in mensaje and not any(c.isdigit() for c in mensaje)


def test_manejar_error_dia_cerrado_traduce_el_hint_nuevo_para_excepciones():
    with pytest.raises(HTTPException) as e:
        manejar_error_dia_cerrado(_error("SCJ15", "tramo_tiempos_incoherentes"))
    assert e.value.status_code == 409 and e.value.detail == errores.MENSAJE_TRAMO_TIEMPOS_INCOHERENTES


def test_descripcion_segura_de_un_scj_lleva_su_hint_de_la_lista_cerrada_y_nunca_el_texto():
    from app.registro_seguro import HINTS_CONOCIDOS, descripcion_segura

    assert descripcion_segura(_error("SCJ15", "tramo_tiempos_incoherentes")) == "APIError sqlstate=SCJ15 hint=tramo_tiempos_incoherentes"
    assert descripcion_segura(_error("SCJ27", "dia_ya_existe")) == "APIError sqlstate=SCJ27 hint=dia_ya_existe"
    assert descripcion_segura(_error("SCJ27", "horas_fuera_de_rango")) == "APIError sqlstate=SCJ27 hint=horas_fuera_de_rango"
    assert {"dia_ya_existe", "estado_invalido", "tramos_inconsistentes", "horas_fuera_de_rango", "tramo_tiempos_incoherentes"} <= HINTS_CONOCIDOS
    assert descripcion_segura(_error("SCJ15", None)) == "APIError sqlstate=SCJ15"
    assert descripcion_segura(_error("23505", "tramo_tiempos_incoherentes")) == "APIError sqlstate=23505"        # el hint solo se registra en los SQLSTATE propios
    # fuera de la lista (identificador desconocido, o texto con datos): NO se registra, sale como «otro»
    assert descripcion_segura(_error("SCJ15", "hint_nuevo_que_no_conozco")) == "APIError sqlstate=SCJ15 hint=otro"
    assert descripcion_segura(_error("SCJ15", "Hint con espacios y datos 9981")) == "APIError sqlstate=SCJ15 hint=otro"
    assert "9981" not in descripcion_segura(_error("SCJ15", "Hint con espacios y datos 9981"))


def test_la_lista_de_hints_conocidos_coincide_con_los_hint_literales_de_db_ddl_en_las_dos_direcciones():
    """Contrato con el DDL: cada hint de la lista existe literal en algún db/ddl/*.sql, y todo `HINT = '...'` literal de db/ddl está en la lista (un hint nuevo sin registrar saldría como «otro» en los logs)."""
    import re
    from pathlib import Path

    from app.registro_seguro import HINTS_CONOCIDOS

    carpeta = Path(__file__).resolve().parents[2] / "db" / "ddl"
    en_ddl = set()
    for archivo in carpeta.glob("*.sql"):
        en_ddl |= set(re.findall(r"HINT\s*=\s*'([A-Za-z0-9_]+)'", archivo.read_text(encoding="utf-8")))
    assert en_ddl, "no se leyó ningún HINT de db/ddl"
    assert HINTS_CONOCIDOS - en_ddl == set(), f"en la lista pero ya no en el DDL: {sorted(HINTS_CONOCIDOS - en_ddl)}"
    assert en_ddl - HINTS_CONOCIDOS == set(), f"en el DDL pero falta en HINTS_CONOCIDOS: {sorted(en_ddl - HINTS_CONOCIDOS)}"



def test_el_post_de_correcciones_traduce_tiempos_incoherentes_del_recalculo_del_tramo(monkeypatch):
    """Si fn_correccion_recalcula_tramo (AFTER INSERT en tiempo.correccion) llegara a reescribir un tramo y chocara con trg_tramo_valida_tiempos, el error vuelve como SCJ15 con ese hint."""
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
    corr.insert.return_value.execute.side_effect = _error("SCJ15", "tramo_tiempos_incoherentes")
    tablas = {
        "marca": tabla([{"id": 1, "momento_dispositivo": "2026-10-06T15:00:00+00:00"}]),
        "excepcion": tabla([{"estado": "pendiente", "motivo_revision": "reloj_no_sincronizado"}]),
        "correccion": corr,
    }
    db = MagicMock()
    db.postgrest.schema.return_value.table.side_effect = lambda n: tablas[n]
    servicio = MagicMock()
    servicio.postgrest.schema.return_value.table.side_effect = lambda n: tabla([])
    app.dependency_overrides[get_caller_client] = lambda: db
    app.dependency_overrides[get_caller_identity] = lambda: CallerIdentity(auth_user_id="a", correo=None)
    app.dependency_overrides[get_service_client] = lambda: servicio
    try:
        r = TestClient(app).post("/api/correcciones", json={"marca_id": 1, "valor_corregido": "2026-10-06T16:00:00Z", "motivo": "x"}, headers={"Authorization": "Bearer t"})
    finally:
        app.dependency_overrides.clear()
    assert r.status_code == 409
    assert r.json()["detail"] == errores.MENSAJE_TRAMO_TIEMPOS_INCOHERENTES and "9981" not in r.text
