"""Búsqueda de personas por nombre, compartida por TODOS los routers con buscador (terminales, tramos, días, banco de horas, ausencias).

El texto del usuario se interpola en un filtro `or=(…)` de PostgREST, donde la coma, el punto, los paréntesis y el asterisco son SINTAXIS: sin sanear, `x,curp.like.ABC*` agregaría condiciones
propias. Con `service_role` (sin RLS) eso era un oráculo para adivinar CURP/RFC/NSS letra por letra y se saltaba la separación de identidad de 110_/111_. Por eso NINGÚN router arma ese
filtro a mano: todos pasan por `filtro_de_nombre` / `resolver_ids_por_nombre`.

NOTA: `.in_` solo con UUID/enteros/constantes; texto del cliente, jamás (postgrest-py no escapa `"` ni `\\` dentro de `in.(…)`)."""

import re
import unicodedata

from supabase import Client

MAX_LARGO_BUSQUEDA = 100      # `max_length` de los Query de búsqueda


def sanear_busqueda(texto: str) -> str:
    """Sólo letras (con acentos y ñ), dígitos, espacios, guion y apóstrofo: el resto pasa a espacio y se colapsan los espacios. Primero se normaliza a NFC: pegado desde macOS un acento llega
    como letra + marca combinante (NFD), y esa marca NO es `\\w`: sin normalizar, «José» quedaría «Jose» y «Ramón» «Ramo n»."""
    texto = unicodedata.normalize("NFC", texto)
    limpio = re.sub(r"[^\w\s'\-]", " ", texto, flags=re.UNICODE).replace("_", " ")
    return " ".join(limpio.split())


def filtro_de_nombre(texto: str | None) -> str | None:
    """El valor de `.or_(...)` para buscar `texto` en primer_nombre/apellido_paterno/apellido_materno, o None si tras sanear no queda nada que buscar."""
    limpio = sanear_busqueda(texto) if texto is not None else ""
    if not limpio:
        return None
    return f"primer_nombre.ilike.%{limpio}%,apellido_paterno.ilike.%{limpio}%,apellido_materno.ilike.%{limpio}%"


def resolver_ids_por_nombre(db: Client, texto: str) -> list[str]:
    """ids de personas cuyo nombre coincide. Vacío tras sanear = SIN coincidencias ([], sin consultar), NUNCA «todas las personas»."""
    filtro = filtro_de_nombre(texto)
    if filtro is None:
        return []
    filas = db.postgrest.schema("personas").table("persona").select("id").or_(filtro).execute().data
    return [fila["id"] for fila in filas]
