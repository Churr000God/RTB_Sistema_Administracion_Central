from datetime import datetime
from typing import Literal

from pydantic import BaseModel


class MovimientoCreate(BaseModel):
    # Lo que deja insertar la policy de la bitácora (92_/129_). «alta» también está en el CHECK de la tabla,
    # pero la crea el trigger de persona, nunca este endpoint.
    tipo_movimiento: Literal["suspension", "reactivacion", "baja_definitiva"]
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
    # Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md §8). Sólo el POST los llena; compatibles hacia atrás.
    # `advertencias` = ["baja_terminal_pendiente"] si el movimiento (suspensión / baja definitiva) quedó
    # confirmado pero NO se pudo pedir la baja en las terminales; un job de respaldo lo reintenta.
    advertencias: list[str] = []
    # Cuántas bajas de terminal se emitieron (>= 0): permite el aviso informativo «se solicitó la baja».
    bajas_terminal_emitidas: int = 0
