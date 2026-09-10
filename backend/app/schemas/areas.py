from datetime import datetime

from pydantic import BaseModel, field_validator


class AreaCreate(BaseModel):
    nombre_area: str

    @field_validator("nombre_area")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())


class AreaRename(BaseModel):
    nombre_area: str

    @field_validator("nombre_area")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())


class AreaEstado(BaseModel):
    activo: bool


class AreaOut(BaseModel):
    id: str
    nombre_area: str
    activo: bool
    creado_en: datetime
    actualizado_en: datetime
