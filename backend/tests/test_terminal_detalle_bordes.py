"""Bordes del saneo del `detalle` (detalle_terminal.py) y aserciones que los tests de B1-B3 dejaban flojas.

Salieron de mutación manual sobre detalle_terminal.py: cada rango de `_INVISIBLES` y de `_CONTROLES` se movía un carácter
y la suite seguía en verde; estas pruebas fijan los extremos de cada rango."""

import pytest

from app.detalle_terminal import DetalleProhibido, sanear_detalle
from test_terminal_movimientos import Entorno, _m


@pytest.mark.parametrize(
    "invisible",
    [
        "­", "؜", "​", "‌", "‏", " ", " ", "‮", "⁠", "⁤",
        "⁦", "⁩", "﻿", "\U000e0000", "\U000e0001", "\U000e007f",
    ],
    ids=lambda c: f"U+{ord(c):04X}",
)
def test_cada_extremo_de_los_rangos_invisibles_se_elimina_sin_dejar_espacio(invisible):
    assert sanear_detalle("e", f"a{invisible}b") == "e: ab"


@pytest.mark.parametrize("control", ["\x01", "\x08", "\x7f", "\x80", "\x84", "\x9e", "\x9f"], ids=lambda c: f"U+{ord(c):04X}")
def test_los_controles_de_los_extremos_se_vuelven_espacio(control):
    assert sanear_detalle("e", f"a{control}b") == "e: a b"


@pytest.mark.parametrize("detalle", ["base-64", "BASE 64", "ba.se_64", "base/64", "Base:64"])
def test_base64_con_separadores_tambien_se_rechaza(detalle):
    with pytest.raises(DetalleProhibido):
        sanear_detalle("err", detalle)


def test_el_tope_de_500_incluye_el_codigo_y_es_exacto():
    palabras = lambda n: ("a " * n).strip()  # noqa: E731  (separadas: una racha larga sin espacios sería «carga binaria»)
    assert len(sanear_detalle("e", palabras(300))) == 500
    justo = palabras(249)  # 497 caracteres: «e: » + 497 = 500
    assert len(justo) == 497 and sanear_detalle("e", justo) == f"e: {justo}"
    una_menos = palabras(248)
    assert sanear_detalle("e", una_menos) == f"e: {una_menos}" and len(sanear_detalle("e", una_menos)) == 498


def test_detalle_solo_con_espacios_o_invisibles_queda_como_el_codigo_solo():
    assert sanear_detalle("err", "   \t\n") == "err"
    assert sanear_detalle("err", "​⁠ <b></b>") == "err"
    assert sanear_detalle("err", None) == "err"


def test_alta_ajena_responde_identico_a_inexistente_en_cuerpo_y_en_cabeceras_con_valores():
    """Antes sólo se comparaban los NOMBRES de cabecera: un `content-length` o un `x-…` distinto pasaba."""
    ajena = Entorno({"resultado": "no_encontrado"}).post(_m())
    inexistente = Entorno({"resultado": "no_encontrado"}).post({**_m(), "terminal_usuario_id": 999_999})
    sin_fecha = lambda r: {k: v for k, v in r.headers.items() if k != "date"}  # noqa: E731
    assert ajena.content == inexistente.content
    assert sin_fecha(ajena) == sin_fecha(inexistente)


@pytest.mark.parametrize(
    "respuesta",
    [None, [], "ok", {}, {"resultado": "rara"}, {"resultado": "registrado"}, {"resultado": "registrado", "estado": "inventado"},
     {"resultado": "ya_aplicado", "estado": None}],
)
def test_respuesta_rara_del_rpc_es_exactamente_503_fijo(respuesta):
    """Versión sin la salida `or … 200` de la prueba original."""
    e = Entorno()
    e.respuesta = respuesta  # Entorno(None) usaría el valor por defecto
    r = e.post(_m())
    assert r.status_code == 503 and "inventado" not in r.text and "rara" not in r.text


def test_una_clave_extra_del_rpc_en_movimientos_no_se_reenvia():
    r = Entorno({"resultado": "registrado", "estado": "activo", "persona_id": "uuid-secreto"}).post(_m())
    assert r.status_code == 200 and r.json() == {"resultado": "registrado", "estado": "activo"}


def test_borde_de_la_carga_binaria_63_pasa_y_64_se_rechaza():
    """El contrato dice «racha de >= 64»: el umbral es exacto (5aedf53 lo dejó en 65 por una mutación sin restaurar)."""
    assert sanear_detalle("err", "a" * 63).endswith("a" * 63)
    with pytest.raises(DetalleProhibido):
        sanear_detalle("err", "a" * 64)
