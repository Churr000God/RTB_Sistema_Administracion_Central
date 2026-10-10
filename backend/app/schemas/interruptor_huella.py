"""Esquemas de la API del interruptor de la activación por huella (CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md)."""

from datetime import date
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, StringConstraints

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


# La nota es texto libre: la validación fija el rango tras `strip()`; un fallo NO se devuelve con eco (manejador propio de RequestValidationError, C3).
Nota = Annotated[str, StringConstraints(strip_whitespace=True, min_length=10, max_length=500)]
NotaOpcional = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]


class EncenderIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nota: Nota
    hasta_fecha: date


class RenovarIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nota: Nota
    hasta_fecha: date
    hasta_base: str  # el `hasta` (instante) que la pantalla tenía; se interpreta a mano para que un valor ilegible sea 422 hasta_invalido


class ApagarIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nota: NotaOpcional | None = None


class CambioOut(BaseModel):
    resultado: Literal["actualizada", "sin_cambio"]
    estado: EstadoInterruptorOut
