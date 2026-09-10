from datetime import datetime

from pydantic import BaseModel, field_validator

NIVELES_VALIDOS = {"direccion", "gerencia", "mando_medio", "operativo"}


class PuestoCreate(BaseModel):
    departamento_id: str
    nombre_puesto: str
    nivel: str
    plazas_totales: int = 1
    reporta_a_id: str  # obligatorio: la API nunca crea un puesto tope, sólo la migración por SQL

    @field_validator("nombre_puesto")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())

    @field_validator("nivel")
    @classmethod
    def validar_nivel(cls, valor: str) -> str:
        """El CHECK de personas.puesto ya garantiza esto en la DB -- se repite acá porque un
        422 de Pydantic es más legible que un 500 por violación de constraint (mismo criterio
        que la normalización de CURP/RFC en personas.py)."""
        if valor not in NIVELES_VALIDOS:
            raise ValueError(f"nivel debe ser uno de: {', '.join(sorted(NIVELES_VALIDOS))}")
        return valor


class PuestoUpdate(BaseModel):
    nombre_puesto: str
    nivel: str
    plazas_totales: int

    @field_validator("nombre_puesto")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())

    @field_validator("nivel")
    @classmethod
    def validar_nivel(cls, valor: str) -> str:
        """El CHECK de personas.puesto ya garantiza esto en la DB -- se repite acá porque un
        422 de Pydantic es más legible que un 500 por violación de constraint (mismo criterio
        que la normalización de CURP/RFC en personas.py)."""
        if valor not in NIVELES_VALIDOS:
            raise ValueError(f"nivel debe ser uno de: {', '.join(sorted(NIVELES_VALIDOS))}")
        return valor


class PuestoEstado(BaseModel):
    activo: bool


class PuestoOut(BaseModel):
    id: str
    departamento_id: str
    nombre_puesto: str
    nivel: str
    plazas_totales: int
    reporta_a_id: str | None
    activo: bool
    creado_en: datetime
    actualizado_en: datetime
