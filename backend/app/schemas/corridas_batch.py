from datetime import date, datetime

from pydantic import BaseModel


class EjecutarBatchRequest(BaseModel):
    fecha: date | None = None


class CorridaBatchOut(BaseModel):
    id: int
    tipo_batch: str
    fecha: date
    estado: str
    intentos: int
    iniciado_en: datetime
    terminado_en: datetime | None
    detalle: str | None
