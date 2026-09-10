from datetime import date

from pydantic import BaseModel, field_validator

LARGO_MAXIMO_NOMBRE = 100  # varchar(100) en tiempo.dia_festivo


class DiaFestivoCreate(BaseModel):
    fecha: date
    nombre: str

    @field_validator("nombre")
    @classmethod
    def normalizar(cls, valor: str) -> str:
        """Colapsa espacios repetidos/inicio-fin (mismo criterio que AreaCreate.normalizar). Se
        normaliza aquí (no sólo en el frontend) porque alguien podría pegarle directo a la API
        sin pasar por el form."""
        valor = " ".join(valor.split())
        if not valor:
            raise ValueError("nombre no puede estar vacío")
        if len(valor) > LARGO_MAXIMO_NOMBRE:
            raise ValueError(f"nombre no puede tener más de {LARGO_MAXIMO_NOMBRE} caracteres")
        return valor


class DiaFestivoOut(BaseModel):
    id: int  # bigint PK -- a diferencia de AreaOut.id (uuid/str)
    fecha: date
    nombre: str
