from datetime import datetime
from typing import Literal

from pydantic import BaseModel, field_validator


class MarcaCapturaManualCreate(BaseModel):
    evento_id: str  # UUID v4, generado por el frontend al montar el formulario (SCJ-ESP-01 §VII.4)
    persona_id: str
    terminal_id: str  # punto de captura (ej. "rh-captura-01"), no un aparato físico
    momento_dispositivo: datetime | None = None  # None = comportamiento actual, ahora

    @field_validator("terminal_id")
    @classmethod
    def validar_terminal_id(cls, valor: str) -> str:
        valor = valor.strip()
        if not valor or len(valor) > 32:
            raise ValueError("terminal_id debe tener entre 1 y 32 caracteres")
        return valor


class MarcaCapturaManualOut(BaseModel):
    evento_id: str
    duplicado: bool
    momento_dispositivo: datetime
    momento_recepcion: datetime
    requiere_revision: bool
    motivos_revision: list[str]


class MarcaListaItem(BaseModel):
    id: int
    evento_id: str
    persona_id: str
    persona_nombre: str | None = None
    terminal_id: str
    secuencia_local: int | None = None
    momento_dispositivo: datetime
    momento_efectivo: datetime
    momento_recepcion: datetime
    desfase_local: str
    estado_reloj: str
    version_software: str
    origen: str
    requiere_revision: bool
    motivos_revision: list[str]
    excepcion_pendiente_id: int | None = None
    estado_revision: Literal["sin_revision", "pendiente", "resuelta"]


class MarcaListaOut(BaseModel):
    total: int
    marcas: list[MarcaListaItem]
