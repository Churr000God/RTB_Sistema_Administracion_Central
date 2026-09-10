from datetime import date, datetime

from pydantic import BaseModel


class AsignacionCreate(BaseModel):
    persona_id: str
    puesto_id: str
    vigente_desde: date


class AsignacionTerminar(BaseModel):
    vigente_hasta: date


class AsignacionCambiarPuesto(BaseModel):
    puesto_nuevo_id: str
    fecha: date


class AsignacionOut(BaseModel):
    id: str
    persona_id: str
    puesto_id: str
    vigente_desde: date
    vigente_hasta: date | None
    creado_en: datetime
    actualizado_en: datetime


class AsignacionConDetalle(AsignacionOut):
    persona_nombre: str
    nombre_puesto: str
    nombre_departamento: str
    nombre_area: str
