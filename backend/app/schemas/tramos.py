from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel


class TramoListaItem(BaseModel):
    id: int
    fecha: date  # de tiempo.dia (embed)
    persona_id: str
    persona_nombre: str | None = None
    dia_estado: Literal["abierto", "cerrado", "bloqueado", "revisado"]  # de tiempo.dia (embed)
    inicio: datetime
    fin: datetime | None
    minutos_trabajados: float | None
    tipo: Literal["ordinario", "reposicion", "extra"] | None = None


class TramoListaOut(BaseModel):
    total: int
    tramos: list[TramoListaItem]
