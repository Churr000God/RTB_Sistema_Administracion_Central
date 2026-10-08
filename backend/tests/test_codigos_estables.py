"""Pedido de contrato (security al frontend, B1): los 409 con campos hermanos llevan un `codigo` ESTABLE para que el cliente no
deduzca por el texto de `detail`; el `detail` sigue siendo fijo. Cambio aditivo. Mocks; nunca la base real."""

import ast
import logging
import re
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from postgrest.exceptions import APIError

from app import errores
from app.consentimiento_terminal import error_consentimiento_desactualizado, error_de_terminal_con_consentimiento
from app.respuestas_error import ErrorConCampos

VIGENTE = {
    "id": 4, "version": 4, "texto": "t", "texto_sha256": "a" * 64, "provisional": False, "cambio_material": True,
    "nota": None, "creado_por": "p", "creado_en": "2026-10-08T10:00:00+00:00",
}


def _db_con_vigente(fila):
    db = MagicMock()
    t = MagicMock()
    for m in ("select", "order", "limit"):
        getattr(t, m).return_value = t
    t.execute.return_value.data = [fila] if fila else []
    db.postgrest.schema.return_value.table.return_value = t
    return db


@pytest.mark.parametrize("hint", ["consentimiento_desactualizado", "version_base_desactualizada"])
def test_los_409_de_consentimiento_de_la_base_llevan_su_codigo_con_y_sin_vigente(hint):
    error = APIError({"code": "SCJ16", "hint": hint, "message": "crudo-123"})
    con = error_de_terminal_con_consentimiento(error, _db_con_vigente(VIGENTE))
    sin = error_de_terminal_con_consentimiento(error, _db_con_vigente(None))
    assert isinstance(con, ErrorConCampos) and con.codigo == hint and "consentimiento_vigente" in con.campos
    assert isinstance(sin, ErrorConCampos) and sin.codigo == hint and sin.campos == {}
    assert con.detail == sin.detail and "crudo" not in con.detail


def test_el_409_armado_por_el_endpoint_lleva_el_mismo_codigo():
    e = error_consentimiento_desactualizado(MagicMock(), VIGENTE)
    assert e.codigo == "consentimiento_desactualizado" and e.status_code == 409


def test_otros_errores_scj16_y_no_scj16_no_llevan_codigo_de_estos():
    requerido = error_de_terminal_con_consentimiento(
        APIError({"code": "SCJ16", "hint": "consentimiento_requerido", "message": "x"}), _db_con_vigente(VIGENTE)
    )
    assert not isinstance(requerido, ErrorConCampos)  # 422 plano, sin campos hermanos


def test_el_cuerpo_serializado_trae_detail_fijo_codigo_y_campos():
    from app.respuestas_error import manejar_error_con_campos
    import asyncio

    exc = ErrorConCampos(409, "texto fijo", {"extra": 1}, codigo="lote_no_elegible")
    r = asyncio.run(manejar_error_con_campos(None, exc))
    assert r.status_code == 409 and r.body == b'{"detail":"texto fijo","codigo":"lote_no_elegible","extra":1}'
    sin = asyncio.run(manejar_error_con_campos(None, ErrorConCampos(409, "t", {})))
    assert sin.body == b'{"detail":"t"}'  # sin código no se inventa uno


def test_el_contrato_lista_los_codigos_estables():
    texto = (Path(__file__).resolve().parents[2] / "docs" / "07-procesos" / "CONTRATO_API_TERMINALES_PAQUETE_2.md").read_text(
        encoding="utf-8"
    )
    for codigo in ("consentimiento_desactualizado", "version_base_desactualizada", "valor_desactualizado", "lote_no_elegible", "lote_reintentar"):
        assert f"`{codigo}`" in texto, codigo


# --- M3 de C0: ningún 422/409 relaya el texto de la base --------------------------------------------------------------------------------


def test_rechazo_generico_es_fijo_y_el_log_va_saneado_y_truncado(caplog):
    error = APIError({"code": "XX999", "hint": "h\nforzado", "message": "id-secreto-77\r\nINYECTADO " + "z" * 500})
    with caplog.at_level(logging.ERROR):
        e = errores.rechazo_generico(error, "prueba")
    assert e.status_code == 422 and e.detail == errores.MENSAJE_RECHAZO_GENERICO and "secreto" not in e.detail
    registro = next(x.getMessage() for x in caplog.records)
    assert "\n" not in registro and "\r" not in registro and len(registro) < 600  # sin inyección de línea ni mensaje entero


ATRIBUTOS_DE_LA_BASE = {"message", "details", "hint", "code"}
# Única excepción documentada: parametros.py devuelve str(ValueError) de validar_formato_valor, texto PROPIO del backend (no de la base).
LISTA_BLANCA = {("parametros.py", "error")}


def _nombres_ligados_en_except(arbol) -> dict[ast.AST, set[str]]:
    """Para cada `except ... as X`, el cuerpo del handler y el nombre X (el error capturado)."""
    ligados: dict[ast.AST, set[str]] = {}
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.ExceptHandler) and nodo.name:
            ligados[nodo] = {nodo.name}
    return ligados


def _depende_del_error(expresion, nombres: set[str]) -> bool:
    """¿El `detail` usa .message/.details/.hint/.code de un nombre capturado, o el nombre mismo (str(X), f"{X}", X)?"""
    for n in ast.walk(expresion):
        if isinstance(n, ast.Attribute) and n.attr in ATRIBUTOS_DE_LA_BASE and isinstance(n.value, ast.Name) and n.value.id in nombres:
            return True
        if isinstance(n, ast.Name) and n.id in nombres:
            return True
    return False


def _fugas_en(arbol, archivo: str) -> list[str]:
    fugas = []
    for handler, nombres in _nombres_ligados_en_except(arbol).items():
        for nodo in ast.walk(handler):
            if not (isinstance(nodo, ast.Call) and getattr(nodo.func, "id", getattr(nodo.func, "attr", "")) == "HTTPException"):
                continue
            argumentos = list(nodo.args[1:2]) + [k.value for k in nodo.keywords if k.arg == "detail"]
            if any(_depende_del_error(a, nombres) for a in argumentos):
                if (archivo, next(iter(nombres))) in LISTA_BLANCA:
                    continue
                fugas.append(f"{archivo}:{nodo.lineno}")
    return fugas


def test_ningun_router_relaya_el_texto_de_la_base_en_un_http_exception():
    """Guardia de regresión por AST: ningún HTTPException dentro de un `except ... as X` puede tener un `detail` que dependa de X
    (X.message/.details/.hint/.code, str(X), f"{X}" o X). Cubre cualquier forma de la fuga, no sólo `error.message` literal."""
    carpeta = Path(__file__).resolve().parents[1] / "app" / "routers"
    fugas = []
    for p in sorted(carpeta.glob("*.py")):
        fugas += _fugas_en(ast.parse(p.read_text(encoding="utf-8")), p.name)
    assert fugas == [], fugas


@pytest.mark.parametrize(
    "fuente",
    [
        "try:\n    x()\nexcept APIError as error:\n    raise HTTPException(422, error.message)\n",
        "try:\n    x()\nexcept APIError as e:\n    raise HTTPException(422, str(e))\n",
        "try:\n    x()\nexcept APIError as e:\n    raise HTTPException(422, f'fallo {e}')\n",
        "try:\n    x()\nexcept APIError as e:\n    raise HTTPException(status_code=422, detail=e.details)\n",
        "try:\n    x()\nexcept APIError as e:\n    raise HTTPException(422, (e.hint or '') + 'x')\n",
        "try:\n    x()\nexcept APIError as e:\n    raise HTTPException(422, detail=f'{e.code}')\n",
    ],
)
def test_la_guardia_ast_detecta_cada_forma_de_fuga(fuente):
    assert _fugas_en(ast.parse(fuente), "prueba.py") != []


def test_la_guardia_ast_no_acusa_mensajes_fijos():
    fuente = "try:\n    x()\nexcept APIError as e:\n    if e.code == 'X':\n        raise HTTPException(409, MENSAJE)\n    raise HTTPException(422, 'fijo')\n"
    assert _fugas_en(ast.parse(fuente), "prueba.py") == []


def test_rechazo_generico_relanza_la_falta_de_migracion_para_el_503_global():
    for codigo in ("PGRST202", "PGRST204", "PGRST205", "42P01"):
        error = APIError({"code": codigo, "message": "x"})
        with pytest.raises(APIError):
            errores.rechazo_generico(error, "prueba")


@pytest.mark.parametrize("texto", ["a\nb", "a\rb", "a\u2028b", "a\u2029b", "a\x85b", "a\x00b", "a\x1bb", "a\x7fb", "a\x9fb"])
def test_limpiar_para_log_quita_todo_separador_de_linea_y_control(texto):
    limpio = errores.limpiar_para_log(texto)
    assert limpio == "a b" and "\n" not in limpio


def test_limpiar_para_log_acota_y_tolera_none():
    assert len(errores.limpiar_para_log("x" * 1000)) == 300
    assert len(errores.limpiar_para_log("x" * 1000, 20)) == 20
    assert errores.limpiar_para_log(None) == ""


def test_ningun_bloque_de_log_usa_el_replace_manual():
    """B1: una sola función de limpieza para los logs."""
    carpeta = Path(__file__).resolve().parents[1] / "app"
    sueltos = [p.name for p in carpeta.rglob("*.py") if '.replace("\\r", " ")' in p.read_text(encoding="utf-8")]
    assert sueltos == [], sueltos


# --- B6: un día que falla no tumba el listado de /api/dias ---------------------------------------------------------------------


def _servicio_con_rpc(por_dia):
    db = MagicMock()

    def rpc(nombre, params=None):
        r = MagicMock()
        valor = por_dia[params["p_dia_id"]]
        if isinstance(valor, Exception):
            r.execute.side_effect = valor
        else:
            r.execute.return_value.data = valor
        return r

    db.postgrest.schema.return_value.rpc.side_effect = rpc
    return db


def test_un_dia_que_falla_queda_desconocido_y_los_demas_se_calculan(caplog):
    from app.routers.dias import _resolver_tiene_marcas_por_armar

    db = _servicio_con_rpc({1: [{"x": 1}], 2: APIError({"code": "XX999", "message": "secreto-55\nINYECTADO"}), 3: []})
    with caplog.at_level(logging.ERROR):
        resultado = _resolver_tiene_marcas_por_armar(db, [1, 2, 3])
    assert resultado == {1: True, 3: False}  # el día 2 no aparece => None en el listado
    assert any("día 2" in x.getMessage() for x in caplog.records)
    assert "\n" not in caplog.records[0].getMessage()


def test_si_falta_la_migracion_el_listado_si_falla_con_503_global():
    from app.routers.dias import _resolver_tiene_marcas_por_armar

    db = _servicio_con_rpc({1: APIError({"code": "PGRST202", "message": "x"})})
    with pytest.raises(APIError):
        _resolver_tiene_marcas_por_armar(db, [1])
