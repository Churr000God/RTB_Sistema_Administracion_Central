"""Esquemas de /api/terminal/* (SCJ-DEC-12 §3). Todo campo de texto con max_length y el cuerpo
cerrado (extra=forbid): el Pi sólo manda lo que el contrato define, nada de persona_id ni de
campos de más."""

from datetime import datetime

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field


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


class LatidoOut(BaseModel):
    hora_servidor: datetime
    desfase_reloj_seg: int | None
    ultima_secuencia_recibida: int
