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
    # Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md §8). Sólo el POST los llena; compatibles hacia atrás.
    # `advertencias` = ["baja_terminal_pendiente"] si el movimiento (suspensión / baja definitiva) quedó
    # confirmado pero NO se pudo pedir la baja en las terminales; un job de respaldo lo reintenta.
    advertencias: list[str] = []
    # Cuántas bajas de terminal se emitieron (>= 0): permite el aviso informativo «se solicitó la baja».
    bajas_terminal_emitidas: int = 0
