import re
from datetime import date

from pydantic import BaseModel, field_validator

from app.catalogo_parametros import CATALOGO

PATRON_HORA = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


class ParametroActualizar(BaseModel):
    valor: str


def validar_formato_valor(clave: str, valor: str) -> str:
    """Formato contra el tipo del catálogo -- entero positivo o HH:MM 24h. Que la clave EXISTA
    (y tenga vigencia activa) lo valida el RPC (ERRCODE 'SCJ02'), no acá: éste sólo conoce el
    catálogo de código, no el estado real de la tabla."""
    entrada = CATALOGO.get(clave)
    if entrada is None:
        raise ValueError(f"clave desconocida: {clave}")

    if entrada.tipo == "entero":
        if not valor.isdigit() or int(valor) <= 0:
            raise ValueError("valor debe ser un entero positivo")
    elif entrada.tipo == "hora":
        if not PATRON_HORA.match(valor):
            raise ValueError("valor debe tener formato HH:MM (24 horas)")
    return valor


class ParametroVigenteOut(BaseModel):
    clave: str
    valor: str
    vigente_desde: date
    etiqueta: str
    descripcion: str
    tipo: str
    unidad: str | None
    impacta_logica: bool
    nota: str | None = None


class ParametroHistorialItem(BaseModel):
    id: int
    clave: str
    etiqueta: str
    valor: str
    vigente_desde: date
    vigente_hasta: date | None
    registrado_por: str | None
    nombre_registrado_por: str | None
