"""APIError.code puede ser un int (p. ej. un 520 de Cloudflare en GET /api/terminal/cola): ningún helper de errores asume que es str."""

import pytest
from fastapi import HTTPException
from postgrest.exceptions import APIError

from app.errores import es_error_transitorio_de_base, manejar_error_terminal


@pytest.mark.parametrize("codigo", [520, 502, 500, 0, None])
def test_manejar_error_terminal_con_codigo_no_str_no_truena_con_attributeerror(codigo):
    error = APIError({"code": codigo, "message": "x"})
    with pytest.raises(APIError):        # no reconocido: se relanza tal cual al manejador global (500 sin texto), nunca AttributeError
        manejar_error_terminal(error)


def test_manejar_error_terminal_clase_22_sigue_dando_422_con_codigo_str():
    with pytest.raises(HTTPException) as e:
        manejar_error_terminal(APIError({"code": "22003", "message": "x"}))
    assert e.value.status_code == 422


@pytest.mark.parametrize("codigo,esperado", [(520, True), (503, True), (404, False), (400, False), ("57014", True), (None, False)])
def test_es_error_transitorio_con_codigo_int_o_str(codigo, esperado):
    assert es_error_transitorio_de_base(APIError({"code": codigo, "message": "x"})) is esperado
