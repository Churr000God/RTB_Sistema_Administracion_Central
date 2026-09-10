from datetime import date

from pydantic import BaseModel, field_validator


class PersonaCreate(BaseModel):
    primer_nombre: str
    segundo_nombre: str | None = None
    apellido_paterno: str
    apellido_materno: str | None = None
    curp: str
    rfc: str
    nss: str
    fecha_nacimiento: date
    fecha_ingreso: date
    tipo_contrato: str  # indefinido | prestacion_servicios | por_proyecto
    documento_ref: str  # formato RTB-__-__

    @field_validator("curp", "rfc")
    @classmethod
    def normalizar_mayusculas(cls, valor: str) -> str:
        """04_personas.sql documenta que curp/rfc no se validan por formato en la DB — se deja a
        la capa de aplicación. Normaliza aquí (no sólo en el frontend) porque alguien podría
        pegarle directo a la API sin pasar por el form."""
        return valor.strip().upper()


class PersonaActualizar(BaseModel):
    """Campos editables vía PATCH /api/personas/{id} -- espejo de fn_persona_actualizar_datos
    (db/ddl/69_personas_edicion.sql), sin p_ prefix. Todos opcionales: sólo lo enviado se cambia
    (exclude_unset en el router), NULL/omitido = no tocar ese campo (COALESCE en el RPC).
    A propósito, SIN estado/fecha_baja -- eso lo maneja únicamente POST
    /api/personas/{id}/movimientos, nunca este endpoint."""

    curp: str | None = None
    rfc: str | None = None
    nss: str | None = None
    primer_nombre: str | None = None
    segundo_nombre: str | None = None
    apellido_paterno: str | None = None
    apellido_materno: str | None = None
    fecha_nacimiento: date | None = None
    fecha_ingreso: date | None = None
    tipo_contrato: str | None = None
    documento_ref: str | None = None

    @field_validator("curp", "rfc")
    @classmethod
    def normalizar_mayusculas(cls, valor: str | None) -> str | None:
        return valor.strip().upper() if valor is not None else None


class PersonaOut(BaseModel):
    id: str
    primer_nombre: str
    segundo_nombre: str | None
    apellido_paterno: str
    apellido_materno: str | None
    curp: str
    rfc: str
    nss: str
    fecha_nacimiento: date
    fecha_ingreso: date
    fecha_baja: date | None = None
    estado: str
    tiene_jornada_vigente: bool = False


class PuestoVigente(BaseModel):
    asignacion_id: str
    puesto_id: str
    nombre_puesto: str
    nombre_departamento: str
    nombre_area: str


class PersonaConExpediente(PersonaOut):
    tipo_contrato: str | None = None
    documento_ref: str | None = None
    tiene_usuario: bool = False
    puestos_vigentes: list[PuestoVigente] = []
