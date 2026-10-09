"""Saneo del `detalle` de un movimiento `error` que reporta el Pi (CONTRATO_API_PUENTE_TERMINAL.md §4, SCJ-DEC-12 §12).

El contrato con el Pi es mandar códigos y mensajes FIJOS, nunca cuerpos ISAPI, cabeceras, datos de otros usuarios ni plantillas
biométricas; esto es la red de seguridad del lado del servidor: lo que huela a plantilla se RECHAZA (422, sin guardar nada), lo
demás se limpia (controles, invisibles, marcado `<…>`, espacios) y se acota a 500 caracteres."""

import re
import unicodedata

LIMITE_DETALLE = 500
# Invisibles / reordenamiento Unicode (mismos que el texto de consentimiento y 91_*.sql).
_INVISIBLES = re.compile("[­؜​-‏ -‮⁠-⁤⁦-⁩﻿\U000e0000-\U000e007f]")
_CONTROLES = re.compile("[\x00-\x1f\x7f-\x9f]")
_MARCADO = re.compile(r"<[^>]*>?")
_ESPACIOS = re.compile(r"\s+")
# Términos que delatan una plantilla / cuerpo ISAPI de huella; se buscan sobre el texto normalizado y también "aplastado"
# (sin separadores) para atrapar «finger Data», «finger-print», «f i n g e r d a t a».
_TERMINOS_PROHIBIDOS = (
    "fingerdata", "fingerprint", "fingerprintdata", "capturefingerprint", "template", "plantilla", "base64",
)
# Carga binaria: una racha larga de base64/hexadecimal.
_CARGA_BINARIA = re.compile(r"[A-Za-z0-9+/=_-]{64,}")


class DetalleProhibido(ValueError):
    """El detalle parece contener una plantilla, un cuerpo ISAPI o una carga binaria."""


def _normalizar(texto: str) -> str:
    return unicodedata.normalize("NFKC", texto).casefold()


def _contiene_prohibido(texto: str) -> bool:
    normal = _INVISIBLES.sub("", _normalizar(texto))
    aplastado = re.sub(r"[^a-z0-9]", "", normal)
    return any(t in normal or t in aplastado for t in _TERMINOS_PROHIBIDOS) or bool(_CARGA_BINARIA.search(normal))


def sanear_detalle(codigo: str, detalle: str | None) -> str:
    """`"<codigo>: <detalle>"` limpio y de ≤ 500 caracteres. Levanta DetalleProhibido (nada se guarda)."""
    crudo = detalle or ""
    # Se juzga el texto COMPLETO (hasta 2 000) antes de truncar: lo prohibido más allá del 500 también cuenta.
    if _contiene_prohibido(crudo) or _contiene_prohibido(codigo):
        raise DetalleProhibido
    limpio = _MARCADO.sub(" ", _CONTROLES.sub(" ", _INVISIBLES.sub("", unicodedata.normalize("NFKC", crudo))))
    limpio = _ESPACIOS.sub(" ", limpio).strip()
    compuesto = f"{codigo}: {limpio}" if limpio else codigo
    return compuesto[:LIMITE_DETALLE]
