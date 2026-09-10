from datetime import datetime

from pydantic import BaseModel, field_validator


class DepartamentoCreate(BaseModel):
    area_id: str
    nombre_departamento: str

    @field_validator("nombre_departamento")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())


class DepartamentoRename(BaseModel):
    nombre_departamento: str

    @field_validator("nombre_departamento")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin. Se normaliza aquí (no sólo en el frontend)
        porque alguien podría pegarle directo a la API sin pasar por el form."""
        return " ".join(valor.split())


class DepartamentoEstado(BaseModel):
    activo: bool


class DepartamentoOut(BaseModel):
    id: str
    area_id: str
    nombre_departamento: str
    activo: bool
    creado_en: datetime
    actualizado_en: datetime
