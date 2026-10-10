"""Esquemas de la API del interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md)."""

from typing import Literal

from pydantic import BaseModel

EstadoInterruptor = Literal["encendido", "apagado", "vencido", "inconsistente"]


class RequisitosOut(BaseModel):
    consentimiento_publicado: bool | None = None
    terminal_activa: bool | None = None


class AlarmaOut(BaseModel):
    activa: bool
    nivel: Literal["atender", "revisar"] | None = None
    codigo: str | None = None
    mensaje: str | None = None


class EstadoInterruptorOut(BaseModel):
    activo: bool
    estado: EstadoInterruptor
    motivo: str | None = None
    mensaje: str | None = None
    hasta: str | None = None
    hasta_fecha: str | None = None
    vencido: bool
    encendido_por_nombre: str | None = None
    encendido_en: str | None = None
    altas_activadas_desde_encendido: int | None = None
    maximo_dias: int
    fecha_minima: str
    fecha_maxima: str
    nota_minimo: int
    nota_maximo: int
    requisitos: RequisitosOut
    alarma: AlarmaOut
