from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class ExcepcionOut(BaseModel):
    id: int
    marca_id: int | None
    dia_id: int | None
    motivo_revision: str
    estado: str
    creado_en: datetime
    persona_id: str | None
    persona_nombre: str | None
    momento_dispositivo: datetime | None
    # --- Sólo para excepciones de marca con motivo dia_cerrado (86_*.sql); None/False en las demás ---
    es_dia_cerrado: bool = False
    # Día al que pertenece la marca (fecha local EFECTIVA: corrección más reciente + desfase) y su estado.
    dia_de_la_marca_id: int | None = None
    dia_de_la_marca_estado: Literal["abierto", "bloqueado", "cerrado", "revisado"] | None = None
    # Qué camino resuelve una dia_cerrado PENDIENTE: 'revisar_dia' (día bloqueado/cerrado) o
    # 'descartar' (día ya revisado). None si no aplica o el día no está en un estado que lo admita.
    camino_resolucion: Literal["revisar_dia", "descartar"] | None = None


class DescartarExcepcionIn(BaseModel):
    motivo: str = Field(min_length=1, max_length=500)


class DescartarExcepcionOut(BaseModel):
    resultado: Literal["descartada", "ya_descartada"]
    excepcion_id: int
    dia_id: int | None = None
