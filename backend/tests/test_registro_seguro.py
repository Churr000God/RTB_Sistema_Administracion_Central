"""L1/L2 de security: el registro NUNCA lleva el texto del mensaje de una excepción (solo tipo, marcos de traza o SQLSTATE); el mensaje completo solo para excepciones PROPIAS que lo declaran."""

import asyncio
import logging
from datetime import date
from types import SimpleNamespace
from unittest.mock import MagicMock, PropertyMock

import pytest
from fastapi import APIRouter
from fastapi.exceptions import ResponseValidationError
from postgrest.exceptions import APIError
from pydantic import BaseModel
from fastapi.testclient import TestClient

from app.main import app, manejador_excepciones_no_capturadas, registrar_excepcion_no_capturada
from app.registro_seguro import descripcion_segura, tiene_mensaje_registrable, traza_sin_mensaje

SECRETO = "valor-reconocible-del-input-5521"


def _peticion(ruta="/api/x"):
    return SimpleNamespace(method="POST", scope={"route": SimpleNamespace(path=ruta)}, url=SimpleNamespace(path=ruta + "?q=" + SECRETO), headers={})


# --- L1: el manejador global nunca registra el texto de ninguna excepción --------------------------------------------------------------------------------


@pytest.mark.parametrize("excepcion", [
    ValueError(f"mensaje con {SECRETO}"), KeyError(SECRETO), RuntimeError(SECRETO), ConnectionError(SECRETO), OSError(2, SECRETO), AssertionError(SECRETO),
    TypeError(f"unsupported {SECRETO}"), UnicodeDecodeError("utf-8", b"\xff", 0, 1, SECRETO),
])
def test_ninguna_excepcion_registra_su_mensaje_solo_tipo_y_marcos(excepcion, caplog):
    try:
        raise excepcion
    except Exception as error:  # noqa: BLE001
        with caplog.at_level(logging.DEBUG):
            registrar_excepcion_no_capturada(_peticion(), error)
    assert SECRETO not in caplog.text and type(excepcion).__name__ in caplog.text and "test_registro_seguro" in caplog.text
    assert not any(r.exc_info for r in caplog.records)


def test_una_response_validation_error_sintetica_no_deja_su_input_en_los_registros(caplog):
    """FastAPI la arma con el `input` completo de la respuesta: str(exc) lo incluye."""
    error = ResponseValidationError(errors=[{"type": "string_type", "loc": ("response", "nombre"), "msg": "Input should be a valid string", "input": SECRETO}], body={"nombre": SECRETO})
    assert SECRETO in str(error)                                                    # el riesgo es real
    try:
        raise error
    except ResponseValidationError as capturada:
        with caplog.at_level(logging.DEBUG):
            registrar_excepcion_no_capturada(_peticion(), capturada)
    assert SECRETO not in caplog.text and "ResponseValidationError" in caplog.text


def test_la_causa_encadenada_tampoco_se_registra(caplog):
    try:
        try:
            raise ConnectionError(f"causa {SECRETO}")
        except ConnectionError as causa:
            raise RuntimeError("principal") from causa
    except RuntimeError as error:
        with caplog.at_level(logging.DEBUG):
            registrar_excepcion_no_capturada(_peticion(), error)
    assert SECRETO not in caplog.text


def test_apierror_registra_solo_el_sqlstate_el_metodo_y_la_plantilla_de_la_ruta(caplog):
    with caplog.at_level(logging.DEBUG):
        registrar_excepcion_no_capturada(_peticion("/api/terminales/{terminal_id}"), APIError({"code": "23505", "message": SECRETO, "details": SECRETO, "hint": SECRETO}))
    assert SECRETO not in caplog.text and "23505" in caplog.text and "POST" in caplog.text and "/api/terminales/{terminal_id}" in caplog.text and "?q=" not in caplog.text


class ErrorPropioDeclarado(Exception):
    mensaje_registrable = True


class ErrorPropioSinDeclarar(Exception):
    pass


def test_solo_una_excepcion_propia_que_lo_declara_registra_su_mensaje(caplog):
    with caplog.at_level(logging.DEBUG):
        try:
            raise ErrorPropioDeclarado("texto escrito por este código")
        except ErrorPropioDeclarado as error:
            registrar_excepcion_no_capturada(_peticion(), error)
    assert "texto escrito por este código" in caplog.text
    caplog.clear()
    with caplog.at_level(logging.DEBUG):
        try:
            raise ErrorPropioSinDeclarar(f"texto {SECRETO}")
        except ErrorPropioSinDeclarar as error:
            registrar_excepcion_no_capturada(_peticion(), error)
    assert SECRETO not in caplog.text and "ErrorPropioSinDeclarar" in caplog.text


@pytest.mark.parametrize("valor", ["True", 1, "si", None, [True]])
def test_el_marcador_exige_true_exacto_en_la_clase(valor):
    class E(Exception):
        mensaje_registrable = valor

    assert tiene_mensaje_registrable(E("x")) is False
    assert tiene_mensaje_registrable(ErrorPropioDeclarado("x")) is True


def test_la_respuesta_de_extremo_a_extremo_sigue_siendo_el_500_generico_y_el_log_no_trae_el_input(caplog):
    """Una ruta cuyo response_model no coincide: ResponseValidationError real, pasa por el manejador global de la app."""

    class Salida(BaseModel):
        nombre: str

    enrutador = APIRouter()

    @enrutador.get("/__prueba_l1__", response_model=Salida)
    def _ruta() -> dict:
        return {"nombre": {"dato": SECRETO}}

    app.include_router(enrutador)
    try:
        with caplog.at_level(logging.DEBUG):
            r = TestClient(app, raise_server_exceptions=False).get("/__prueba_l1__")
    finally:
        app.router.routes[:] = [ruta for ruta in app.router.routes if getattr(ruta, "path", "") != "/__prueba_l1__"]
    assert r.status_code == 500 and r.json() == {"detail": "Error interno del servidor."} and SECRETO not in r.text
    assert SECRETO not in caplog.text and "ResponseValidationError" in caplog.text


def test_el_manejador_global_completo_no_filtra_el_mensaje():
    r = asyncio.run(manejador_excepciones_no_capturadas(_peticion(), ValueError(SECRETO)))
    assert r.status_code == 500 and SECRETO not in r.body.decode()


def test_descripcion_segura_es_solo_tipo_o_sqlstate():
    assert descripcion_segura(APIError({"code": "23505", "message": SECRETO})) == "APIError sqlstate=23505"
    assert descripcion_segura(ValueError(SECRETO)) == "ValueError" and SECRETO not in descripcion_segura(KeyError(SECRETO))
    assert SECRETO not in traza_sin_mensaje(ValueError(SECRETO))


# --- L2: jobs y batches ------------------------------------------------------------------------------------------------------------------------------------


def _db_que_revienta():
    db = MagicMock()
    type(db).postgrest = PropertyMock(side_effect=RuntimeError(f"fallo con {SECRETO}"))
    return db


def test_los_jobs_de_terminales_no_registran_el_mensaje_de_la_excepcion(caplog):
    from app.batches import terminales

    with caplog.at_level(logging.DEBUG):
        assert terminales.ejecutar_baja_por_caducidad(_db_que_revienta()) is None
        assert terminales.ejecutar_purga_rechazos(_db_que_revienta()) is None
    assert SECRETO not in caplog.text and "RuntimeError" in caplog.text
    assert not any(r.exc_info for r in caplog.records)


def test_el_batch_de_confianza_no_pone_el_texto_de_la_excepcion_en_el_log(monkeypatch, caplog):
    from app.batches import de_confianza

    monkeypatch.setattr(de_confianza, "upsert_corrida_en_progreso", lambda db, tipo, fecha: {"id": 1})
    monkeypatch.setattr(de_confianza, "_personas_de_confianza_vigentes", lambda db, fecha: ["persona-1"])
    monkeypatch.setattr(de_confianza, "finalizar_corrida", lambda db, corrida, estado, detalle: {"estado": estado, "detalle": detalle})

    def revienta(db, persona, fecha):
        raise APIError({"code": "23505", "message": f"duplicate {SECRETO}", "details": f"Key (x)=({SECRETO})"})

    monkeypatch.setattr(de_confianza, "_crear_dia_si_no_existe", revienta)
    with caplog.at_level(logging.DEBUG):
        r = de_confianza.ejecutar_batch_de_confianza(date(2026, 10, 9), db=MagicMock())
    assert r["estado"] == "fallida" and SECRETO not in caplog.text and SECRETO not in r["detalle"]
    assert "APIError sqlstate=23505" in caplog.text


@pytest.mark.parametrize("modulo", ["de_confianza", "cierre_dia", "corte_quincenal", "terminales", "_orquestacion"])
def test_ningun_batch_formatea_el_objeto_de_la_excepcion_en_cadenas_ni_logs(modulo):
    """Guarda estática: ni f"{error}" ni "%s", error, ni logger.exception en los batches/jobs (usar descripcion_segura / traza_sin_mensaje)."""
    import ast
    from pathlib import Path

    fuente = Path(__file__).resolve().parents[1] / "app" / "batches" / f"{modulo}.py"
    arbol = ast.parse(fuente.read_text(encoding="utf-8"))
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.ExceptHandler) and nodo.name:
            nombre = nodo.name
            for interior in ast.walk(nodo):
                if isinstance(interior, ast.FormattedValue) and isinstance(interior.value, ast.Name) and interior.value.id == nombre:
                    raise AssertionError(f"{modulo}: f-string con el objeto de la excepción `{nombre}` en la línea {interior.lineno}")
                if isinstance(interior, ast.Call) and isinstance(interior.func, ast.Attribute) and interior.func.attr == "exception":
                    raise AssertionError(f"{modulo}: logger.exception en la línea {interior.lineno}")
                if isinstance(interior, ast.Call) and isinstance(interior.func, ast.Attribute) and interior.func.attr in ("error", "warning", "info", "critical"):
                    if any(isinstance(a, ast.Name) and a.id == nombre for a in interior.args[1:]):
                        raise AssertionError(f"{modulo}: se registra el objeto `{nombre}` en la línea {interior.lineno}")


# --- L2 (b): las listas de errores por persona se acotan a 20 y «y N más» ------------------------------------------------------------------------------------------


def test_lista_acotada_deja_hasta_20_y_cuenta_el_resto():
    from app.registro_seguro import lista_acotada

    assert lista_acotada([str(i) for i in range(20)]) == [str(i) for i in range(20)]
    sal = lista_acotada([str(i) for i in range(57)])
    assert sal[:20] == [str(i) for i in range(20)] and sal[20] == "y 37 más" and len(sal) == 21
    assert lista_acotada([]) == [] and lista_acotada(["a"], 0) == ["y 1 más"]


def test_el_batch_de_confianza_registra_a_lo_mas_20_personas_y_el_resto_como_conteo(monkeypatch, caplog):
    from app.batches import de_confianza

    personas = [f"persona-{i:03d}" for i in range(45)]
    monkeypatch.setattr(de_confianza, "upsert_corrida_en_progreso", lambda db, tipo, fecha: {"id": 1})
    monkeypatch.setattr(de_confianza, "_personas_de_confianza_vigentes", lambda db, fecha: personas)
    monkeypatch.setattr(de_confianza, "finalizar_corrida", lambda db, corrida, estado, detalle: {"estado": estado, "detalle": detalle})

    def revienta(db, persona, fecha):
        raise APIError({"code": "23505", "message": SECRETO})

    monkeypatch.setattr(de_confianza, "_crear_dia_si_no_existe", revienta)
    with caplog.at_level(logging.DEBUG):
        r = de_confianza.ejecutar_batch_de_confianza(date(2026, 10, 9), db=MagicMock())
    assert caplog.text.count("persona-0") == 20 and "persona-020" not in caplog.text and "y 25 más" in caplog.text and SECRETO not in caplog.text
    assert "45 error(es)" in r["detalle"]                                  # el conteo real sigue en el detalle de la corrida
