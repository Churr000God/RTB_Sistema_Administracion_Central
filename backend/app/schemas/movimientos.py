from datetime import datetime

from pydantic import BaseModel


class MovimientoCreate(BaseModel):
    tipo_movimiento: str  # suspension | reactivacion | baja_definitiva (alta la crea el trigger)
    motivo: str


class MovimientoOut(BaseModel):
    id: str
    persona_id: str
    tipo_movimiento: str
    fecha_efectiva: datetime
    motivo: str | None
    documento_ref: str | None = None
    registrado_por: str | None
    registrado_por_nombre: str | None = None  # sólo se resuelve en el GET
