from datetime import datetime

from pydantic import BaseModel


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
