from datetime import datetime

from pydantic import BaseModel


class PermisoOut(BaseModel):
    codigo: str
    heredable: bool
    activo: bool
    creado_en: datetime
    actualizado_en: datetime


class PuestoPermisoOtorgar(BaseModel):
    puesto_id: str
    codigo: str


class PuestoPermisoRevocar(BaseModel):
    puesto_permiso_id: str


class PuestoPermisoOut(BaseModel):
    id: str
    puesto_id: str
    codigo: str
    activo: bool
    creado_en: datetime
    actualizado_en: datetime


class PuestoPermisoConDetalle(PuestoPermisoOut):
    nombre_puesto: str


class BitacoraPuestoPermisoOut(BaseModel):
    id: str
    puesto_id: str
    nombre_puesto: str
    codigo: str
    tipo_movimiento: str  # otorgado | revocado
    fecha_efectiva: datetime
    motivo: str | None
    registrado_por_nombre: str | None = None
    creado_en: datetime
