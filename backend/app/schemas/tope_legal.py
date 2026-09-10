from datetime import date

from pydantic import BaseModel, field_validator


class TopeLegalCreate(BaseModel):
    vigente_desde: date
    maximo_semanal: float
    maximo_extra: float
    confirma_cierre_vigente: bool = False

    @field_validator("maximo_semanal")
    @classmethod
    def validar_maximo_semanal(cls, valor: float) -> float:
        if valor <= 0:
            raise ValueError("maximo_semanal debe ser mayor a 0")
        return valor

    @field_validator("maximo_extra")
    @classmethod
    def validar_maximo_extra(cls, valor: float) -> float:
        if valor < 0:
            raise ValueError("maximo_extra no puede ser negativo")
        return valor


class TopeLegalOut(BaseModel):
    id: int
    vigente_desde: date
    vigente_hasta: date | None
    maximo_semanal: float
    maximo_extra: float


class PersonaSobreTopeItem(BaseModel):
    persona_id: str
    persona_nombre: str | None = None
    horas_ordinarias: float
    horas_extra: float
    horas_reposicion: float
    supera_semanal: bool
    supera_extra: bool
    supera_combinado: bool
    exceso_semanal: float | None = None
    exceso_extra: float | None = None
    exceso_combinado: float | None = None


class ExcesoSemanalOut(BaseModel):
    semana_desde: date
    semana_hasta: date
    maximo_semanal: float | None
    maximo_extra: float | None
    personas: list[PersonaSobreTopeItem]
