from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class BancoDeHorasItem(BaseModel):
    persona_id: str
    persona_nombre: str | None = None
    monto: float
    vivo_desde: datetime | None
    actualizado_en: datetime | None
    horas_reciente: float
    horas_media: float
    horas_fuera_ventana: float
    meses_antiguedad_max: int
    conciliado: bool
    corte_pendiente: bool
    jornada_semanal_horas: float | None
    porcentaje_jornada_semanal: float | None
    nivel_alerta: Literal["sin_alerta", "aviso", "escalamiento"] | None


class TopEnDeudaItem(BaseModel):
    persona_id: str
    persona_nombre: str | None = None
    monto: float
    meses_antiguedad_max: int


class BancoDeHorasResumen(BaseModel):
    total_personas: int
    en_deuda: int
    sin_deuda: int
    horas_adeudadas: float
    horas_fuera_ventana: float
    personas_fuera_ventana: int
    personas_corte_pendiente: int
    personas_en_aviso: int
    personas_en_escalamiento: int
    ventana_meses: int
    aviso_pct: int
    escalamiento_pct: int
    top_en_deuda: list[TopEnDeudaItem]


class BancoDeHorasListaOut(BaseModel):
    total: int
    resumen: BancoDeHorasResumen
    saldos: list[BancoDeHorasItem]


class MovimientoSaldoItem(BaseModel):
    id: int
    creado_en: datetime
    tipo: str
    monto: float
    motivo: str | None
    autor_nombre: str | None = None
    saldo_corrido: float
    vivo: bool


class MovimientoSaldoListaOut(BaseModel):
    total: int
    movimientos: list[MovimientoSaldoItem]


class MovimientoSaldoCrear(BaseModel):
    tipo: Literal["arrastrar", "descontar", "condonar"]
    monto: float = Field(gt=0)
    motivo: str = Field(min_length=1)
