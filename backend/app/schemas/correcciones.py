from datetime import datetime

from pydantic import BaseModel


class CorreccionCreate(BaseModel):
    marca_id: int
    valor_corregido: datetime
    motivo: str


class CorreccionOut(BaseModel):
    id: int
    marca_id: int
    valor_corregido: datetime
    motivo: str
    autor_id: str
    creado_en: datetime
