"""Esquemas de /api/terminal/* (SCJ-DEC-12 §3). Todo campo de texto con max_length y el cuerpo
cerrado (extra=forbid): el Pi sólo manda lo que el contrato define, nada de persona_id ni de
campos de más."""

from datetime import datetime

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, StrictBool, StrictInt


class LatidoIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # La serie de la terminal; si viene, debe coincidir con la de la credencial (el id real sale
    # de la credencial, nunca de aquí).
    terminal_id: str | None = Field(default=None, max_length=32)
    hora_terminal: AwareDatetime | None = None
    terminal_alcanzable: bool | None = None
    reloj_sincronizado: bool | None = None
    version_pi: str | None = Field(default=None, max_length=16)
    marcas_pendientes: int | None = Field(default=None, ge=0, le=10_000_000)
    # 99_: la ingesta del puente está DETENIDA esperando a una persona (booleano sin motivo). StrictBool: "yes", 1 o "true" NO pasan (422).
    ingesta_detenida: StrictBool | None = None


class LatidoOut(BaseModel):
    hora_servidor: datetime
    desfase_reloj_seg: int | None
    ultima_secuencia_recibida: int


# --- POST /api/terminal/marcas (CONTRATO_API_PUENTE_TERMINAL.md §1) -----------------------------------------------------------

from typing import Any, Literal

LIMITE_LOTE_MARCAS = 200
CLAVES_EVENTO = ("evento_id", "employee_no", "secuencia_local", "momento_dispositivo", "desfase_local", "estado_reloj")
ENTERO_MAXIMO = 2**62
CLAVES_ENTERAS = ("employee_no", "secuencia_local")
# 95_: campo OPCIONAL del evento. Su ÚNICO valor significativo es la cadena exacta «huella» (el puente la manda sólo para una marca minor 38 por huella); cualquier otro
# valor, tipo o largo se descarta (queda NULL) antes del RPC: nunca se pasa texto libre.
CLAVE_MODO_VERIFICACION = "modo_verificacion"
MODO_VERIFICACION_HUELLA = "huella"

EstadoResultado = Literal["confirmado", "duplicado", "rechazo_definitivo", "rechazo_transitorio"]
CODIGOS_DEFINITIVOS = ("forma_invalida", "no_enrolado", "secuencia_duplicada", "secuencia_fuera_de_rango", "conflicto_evento")
CODIGOS_TRANSITORIOS = ("tope_terminal", "error_interno")


class MarcasIn(BaseModel):
    """Sólo la ESTRUCTURA del lote se valida aquí (422 de todo el lote); la forma de cada evento la juzga el RPC y un
    evento malo es un rechazo individual, no un lote caído (SCJ-DEC-12 §2)."""

    model_config = ConfigDict(extra="forbid")

    terminal_id: str | None = Field(default=None, max_length=32)
    version_software: str = Field(min_length=1, max_length=16)
    eventos: list[Any] = Field(min_length=1, max_length=LIMITE_LOTE_MARCAS)


class ResultadoMarca(BaseModel):
    model_config = ConfigDict(extra="forbid")

    indice: int = Field(ge=0)
    evento_id: str | None = Field(default=None, max_length=36)
    estado: EstadoResultado
    codigo: Literal[
        "forma_invalida", "no_enrolado", "secuencia_duplicada", "secuencia_fuera_de_rango", "conflicto_evento",
        "tope_terminal", "error_interno",
    ] | None = None


class MarcasOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    momento_recepcion: datetime
    resultados: list[ResultadoMarca]


# --- GET /api/terminal/cola y /mapa (CONTRATO_API_PUENTE_TERMINAL.md §2-§3) ------------------------------------------------------

EstadoAltaTerminal = Literal["pendiente_alta", "esperando_huella", "activo", "pendiente_baja"]
AccionPuente = Literal["crear_usuario", "sondear_huellas", "borrar_usuario"]
# Una sola regla: qué trabajo tiene el Pi según el estado de la alta (activo no tiene).
ACCION_POR_ESTADO: dict[str, str] = {
    "pendiente_alta": "crear_usuario",
    "esperando_huella": "sondear_huellas",
    "pendiente_baja": "borrar_usuario",
}


class AltaTerminalOut(BaseModel):
    """Lo ÚNICO que el Pi sabe de un alta: sin persona_id, sin nombres, sin estado de la persona (extra=forbid)."""

    model_config = ConfigDict(extra="forbid")

    # StrictInt: una fila del RPC con True / "1000" / 2.0 no se re-serializa en silencio, es un 503 (forma inesperada).
    terminal_usuario_id: StrictInt = Field(ge=1)
    employee_no: StrictInt = Field(ge=1, le=99_999_999)
    estado: EstadoAltaTerminal
    huellas_capturadas: StrictInt = Field(ge=0, le=10)
    accion: AccionPuente | None = None


class AltasTerminalOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    hora_servidor: datetime
    altas: list[AltaTerminalOut]


# --- POST /api/terminal/movimientos (CONTRATO_API_PUENTE_TERMINAL.md §4) ----------------------------------------------------------

import re as _re

from pydantic import model_validator

TipoMovimiento = Literal["usuario_creado", "huella_capturada", "baja_confirmada", "error"]
FORMATO_CODIGO_ERROR = _re.compile(r"[a-z0-9_]{1,40}")
ID_ALTA_MAXIMO = 2**63 - 1


class MovimientoIn(BaseModel):
    """Cuerpo cerrado. NO acepta employee_no, persona_id ni terminal_id: la alta se resuelve por (terminal_usuario_id, terminal de
    la credencial). Los campos que no corresponden al tipo están PROHIBIDOS (no se ignoran en silencio)."""

    model_config = ConfigDict(extra="forbid")

    terminal_usuario_id: StrictInt = Field(ge=1, le=ID_ALTA_MAXIMO)
    tipo: TipoMovimiento
    huellas: StrictInt | None = None
    codigo: str | None = Field(default=None, max_length=40)
    detalle: str | None = Field(default=None, max_length=2000)

    @model_validator(mode="after")
    def _campos_segun_el_tipo(self):
        if self.tipo == "huella_capturada":
            if self.huellas is None or not 1 <= self.huellas <= 10:
                raise ValueError("huellas debe estar entre 1 y 10")
        elif self.huellas is not None:
            raise ValueError("huellas sólo va con huella_capturada")
        if self.tipo == "error":
            if self.codigo is None or not FORMATO_CODIGO_ERROR.fullmatch(self.codigo):
                raise ValueError("el código del error es obligatorio y de formato [a-z0-9_]{1,40}")
        elif self.codigo is not None or self.detalle is not None:
            raise ValueError("codigo y detalle sólo van con error")
        return self


class MovimientoOut(BaseModel):
    model_config = ConfigDict(extra="forbid")

    resultado: Literal["registrado", "ya_aplicado"]
    estado: Literal["pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja"]
