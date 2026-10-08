"""Esquemas de la API WEB de Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md). Distintos de
schemas/terminal.py, que son los del puente (credencial de terminal)."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

EstadoContacto = Literal["en_linea", "sin_contacto", "nunca", "inactiva"]


class TerminalOut(BaseModel):
    id: int
    serie: str  # tiempo.terminal.terminal_id (varchar); NO el id interno
    nombre: str
    modelo: str | None = None
    activa: bool
    estado_contacto: EstadoContacto
    ultimo_contacto_en: datetime | None = None
    segundos_sin_contacto: int | None = None  # None si nunca hubo contacto
    terminal_alcanzable: bool | None = None  # None si el puente nunca lo reportó
    reloj_desfase_seg: int | None = None  # terminal - servidor; None si no se sabe
    version_pi: str | None = None
    marcas_pendientes: int | None = None


EstadoAlta = Literal["pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja"]
AccionDisponible = Literal["cancelar_alta", "dar_de_baja"]


class AltaOut(BaseModel):
    """tiempo.terminal_usuario para la UI (CONTRATO §2.1). Sin plantillas ni nada biométrico: sólo el conteo."""

    id: int
    terminal_id: int
    employee_no: int
    persona_id: str
    persona_nombre: str | None = None
    estado: EstadoAlta
    huellas_capturadas: int
    creado_en: datetime
    actualizado_en: datetime
    usuario_creado_en: datetime | None = None
    # Siempre presente en el esquema; no nulo sólo en esperando_huella (único estado que caduca).
    caduca_en: datetime | None = None
    error_codigo: str | None = None
    error_detalle: str | None = None
    accion_disponible: AccionDisponible | None = None


class ResumenAltas(BaseModel):
    por_estado: dict[str, int]


class AltasListaOut(BaseModel):
    total: int
    resumen: ResumenAltas
    altas: list[AltaOut]


class BajaCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    # Tope duro sólo contra abuso; el largo útil (10-500) se valida en el endpoint DESPUÉS de sanear.
    motivo: str | None = Field(default=None, max_length=2000)


class MovimientoAltaOut(BaseModel):
    id: int
    tipo_movimiento: str
    creado_en: datetime
    origen: Literal["web", "terminal"]
    registrado_por_nombre: str | None = None  # None si origen='terminal' (la UI muestra «Terminal»)
    detalle: str | None = None
    huellas_capturadas: int | None = None


class AltaDePersonaOut(BaseModel):
    alta: AltaOut
    terminal: TerminalOut


class PersonaAsignableOut(BaseModel):
    persona_id: str
    nombre: str
    puesto: str | None = None
    area: str | None = None
