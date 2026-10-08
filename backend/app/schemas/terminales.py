"""Esquemas de la API WEB de Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md). Distintos de
schemas/terminal.py, que son los del puente (credencial de terminal)."""

from datetime import datetime
from typing import Annotated, Literal

from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt

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
    # 88_: versión del texto que CONFIRMÓ esta alta, la vigente y si falta reconsentir (definición única de la base).
    consentimiento: "ConsentimientoDeAltaOut | None" = None
    consentimiento_vigente_id: int | None = None
    reconsentimiento_pendiente: bool = False
    # C6: la UI deshabilita la casilla con la razón (lista cerrada: en_baja | es_propia | ya_al_corriente).
    es_propia: bool = False
    reconsentimiento_elegible: bool = False
    reconsentimiento_razon: Literal["en_baja", "es_propia", "ya_al_corriente"] | None = None
    accion_disponible: AccionDisponible | None = None


class ResumenAltas(BaseModel):
    por_estado: dict[str, int]
    reconsentimiento_pendiente: int = 0


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
    consentimiento: "ConsentimientoMovimientoOut | None" = None  # sólo asignado y reconsentido


class ConsentimientoMovimientoOut(BaseModel):
    id: int
    version: int
    cambio_material: bool


class AltaDePersonaOut(BaseModel):
    alta: AltaOut
    terminal: TerminalOut


class PersonaAsignableOut(BaseModel):
    persona_id: str
    nombre: str
    puesto: str | None = None
    area: str | None = None


# --- Consentimiento (C5) ---------------------------------------------------------------------------------------


class ConsentimientoVersionOut(BaseModel):
    """Una versión del texto (CONTRATO §3.1). El texto es texto plano: el cliente nunca lo muestra como HTML."""

    id: int
    version: int
    texto: str | None = None  # completo sólo en la vigente y en GET …/{version}; null en el resto del historial
    texto_sha256: str
    provisional: bool
    cambio_material: bool
    motivo_cambio: str | None = None
    vigente_desde: datetime
    vigente_hasta: datetime | None = None
    publicado_por_nombre: str | None = None
    es_semilla: bool


class ConsentimientoOut(BaseModel):
    vigente: ConsentimientoVersionOut
    historial: list[ConsentimientoVersionOut]


class ImpactoOut(BaseModel):
    cambio_material_efectivo: bool
    forzado: bool
    altas_que_quedarian_pendientes: int
    en_proceso: int
    activas: int
    pendientes_actuales: int


class PublicarConsentimiento(BaseModel):
    """Sin `provisional` a propósito (extra=forbid): el RPC nunca publica provisional."""

    model_config = ConfigDict(extra="forbid")
    texto: str = Field(min_length=1, max_length=4000)
    cambio_material: bool = False
    motivo_cambio: str | None = Field(default=None, max_length=200)
    base_version: int = Field(ge=1)


class PublicacionOut(BaseModel):
    resultado: Literal["publicada", "sin_cambio"]
    version: int
    id: int | None = None
    cambio_material: bool | None = None
    cambio_material_forzado: bool | None = None
    pendientes: int | None = None


class AsignarCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    persona_id: UUID
    consentimiento_id: int = Field(ge=1)
    consentimiento_recabado: bool


class ConsentimientoDeAltaOut(BaseModel):
    id: int
    version: int
    provisional: bool


AltaOut.model_rebuild()
MovimientoAltaOut.model_rebuild()


# --- Reconsentimiento (C6) --------------------------------------------------------------------------------------


class ReconsentirAltaCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    consentimiento_id: int = Field(ge=1)
    declaracion_documentos: bool


class ReconsentirLoteCreate(BaseModel):
    """El tope de 200 se valida en el endpoint (mensaje fijo `lote_invalido`); aquí sólo un tope duro de entrada."""

    model_config = ConfigDict(extra="forbid")
    tu_ids: list[Annotated[int, Field(ge=1, le=9223372036854775807)]] = Field(max_length=1000)
    consentimiento_id: int = Field(ge=1)
    declaracion_documentos: bool


class ReconsentimientoOut(BaseModel):
    registradas: int
    pendientes_restantes: int | None = None
    omitidas: list[int] = []


class PendientesOut(BaseModel):
    total: int
    ids: list[int]
    hay_mas: bool


# --- Variables de configuración (C7) -------------------------------------------------------------------------------


class VariableOut(BaseModel):
    clave: str
    etiqueta: str
    descripcion: str
    unidad: str
    minimo: int
    maximo: int
    valor_defecto: int
    valor: int
    vigente_desde: str | None = None  # null si la clave falta o está corrupta (se devuelve el defecto)
    modificado_por_nombre: str | None = None
    valor_ilegible: bool = False  # true si la base tiene un valor corrupto/fuera de rango: la UI debe avisarlo


class VariableEditar(BaseModel):
    model_config = ConfigDict(extra="forbid")
    valor: StrictInt  # "48" o 48.0 no valen: sólo enteros JSON
    valor_base: StrictInt  # lo que la pantalla tenía; si ya no es el vigente, 409 con `valor_actual`


class VariableActualizadaOut(BaseModel):
    resultado: Literal["actualizada", "sin_cambio"]
    clave: str
    valor: int
    vigente_desde: str | None = None


class VigenciaVariableOut(BaseModel):
    clave: str
    valor: str
    vigente_desde: str
    vigente_hasta: str | None = None
    modificado_por_nombre: str | None = None
    estado: Literal["vigente", "reemplazada"]
    valor_ilegible: bool = False


class SimularCaducidad(BaseModel):
    model_config = ConfigDict(extra="forbid")
    valor: StrictInt


class AltaQueCaducariaOut(BaseModel):
    tu_id: int
    persona_nombre: str | None = None
    esperando_desde: datetime


class SimulacionCaducidadOut(BaseModel):
    valor_actual: int
    valor_propuesto: int
    acorta: bool
    altas_en_espera: int
    altas_que_ganan_plazo: int
    altas_que_caducarian_ya: list[AltaQueCaducariaOut]
    altas_que_caducarian_ya_total: int
    altas_por_caducar_nuevas: int
    tope_por_corrida: int


# --- Tablero de anomalías (C8) ---------------------------------------------------------------------------------


class TarjetaAnomaliaOut(BaseModel):
    clave: str
    numero: int
    titulo: str
    estado: Literal["sin_hallazgos", "con_hallazgos", "no_disponible", "error"]
    nivel: Literal["atender", "revisar", "informativo"] | None = None
    total: int | None = None
    ejemplos: list[dict] = []
    hay_mas: bool = False
    motivo: Literal["sin_permiso", "falta_migracion"] | None = None  # sólo con estado no_disponible


class AnomaliasOut(BaseModel):
    terminal_id: int
    desde: datetime
    hasta: datetime
    generado_en: datetime
    categorias: list[TarjetaAnomaliaOut]


class AnomaliaDetalleOut(BaseModel):
    clave: str
    total: int
    items: list[dict]
