from datetime import date, datetime

from pydantic import BaseModel

from app.tipos_id import IdUuid


class AsignacionCreate(BaseModel):
    persona_id: IdUuid
    puesto_id: IdUuid
    vigente_desde: date


class AsignacionTerminar(BaseModel):
    vigente_hasta: date


class AsignacionCambiarPuesto(BaseModel):
    puesto_nuevo_id: IdUuid
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
