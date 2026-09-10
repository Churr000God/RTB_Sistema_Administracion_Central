from datetime import date, datetime, time

from pydantic import BaseModel


class AlertaDeRetardoItem(BaseModel):
    persona_id: str
    persona_nombre: str | None = None
    fecha: date
    hora_entrada_programada: time
    hora_salida_programada: time
    primera_marca: datetime | None = None
    ultima_marca: datetime | None = None
    motivo: str  # "sin_marcas" | "fuera_de_tolerancia" -- SCJ-DEC-10


class AlertasDeRetardoOut(BaseModel):
    alertas: list[AlertaDeRetardoItem]
