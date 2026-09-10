from datetime import date, time

from pydantic import BaseModel, field_validator, model_validator

TIPOS_JORNADA_VALIDOS = {"normal", "flexible", "de_confianza"}
DIAS_SEMANA_VALIDOS = {
    "lunes",
    "martes",
    "miercoles",
    "jueves",
    "viernes",
    "sabado",
    "domingo",
}


class PatronSemanalCreate(BaseModel):
    dia_semana: str
    hora_entrada: time
    hora_salida: time
    minutos_comida: int = 0

    @field_validator("dia_semana")
    @classmethod
    def validar_dia_semana(cls, valor: str) -> str:
        """El CHECK de tiempo.patron_semanal ya garantiza esto en la DB -- se repite acá porque
        un 422 de Pydantic es más legible que un 500 por violación de constraint (mismo criterio
        que nivel en puestos.py)."""
        if valor not in DIAS_SEMANA_VALIDOS:
            raise ValueError(f"dia_semana debe ser uno de: {', '.join(sorted(DIAS_SEMANA_VALIDOS))}")
        return valor

    @model_validator(mode="after")
    def validar_horario(self) -> "PatronSemanalCreate":
        """Mismo criterio: ck_patron_semanal_horario ya lo exige en la DB."""
        if self.hora_salida <= self.hora_entrada:
            raise ValueError("hora_salida debe ser posterior a hora_entrada")
        return self


class JornadaAsignadaCreate(BaseModel):
    persona_id: str
    tipo_jornada: str
    vigente_desde: date
    descuento_comida_fija: bool = False
    minutos_descuento_comida_fija: int | None = None
    patron_semanal: list[PatronSemanalCreate]
    confirma_cierre_vigente: bool = False

    @field_validator("tipo_jornada")
    @classmethod
    def validar_tipo_jornada(cls, valor: str) -> str:
        """ck_jornada_asignada_tipo ya lo exige en la DB -- mismo criterio de 422 legible."""
        if valor not in TIPOS_JORNADA_VALIDOS:
            raise ValueError(f"tipo_jornada debe ser uno de: {', '.join(sorted(TIPOS_JORNADA_VALIDOS))}")
        return valor

    @field_validator("patron_semanal")
    @classmethod
    def validar_patron_no_vacio(cls, valor: list[PatronSemanalCreate]) -> list[PatronSemanalCreate]:
        if not valor:
            raise ValueError("patron_semanal debe tener al menos un día")
        return valor

    @model_validator(mode="after")
    def validar_descuento_fijo(self) -> "JornadaAsignadaCreate":
        """ck_jornada_asignada_descuento_fijo ya lo exige en la DB -- mismo criterio de 422
        legible (si descuento_comida_fija es true, minutos_descuento_comida_fija es obligatorio,
        y viceversa)."""
        if self.descuento_comida_fija != (self.minutos_descuento_comida_fija is not None):
            raise ValueError(
                "minutos_descuento_comida_fija es obligatorio si y sólo si "
                "descuento_comida_fija es true"
            )
        return self


class PatronSemanalOut(BaseModel):
    id: int
    jornada_asignada_id: int
    dia_semana: str
    hora_entrada: time
    hora_salida: time
    minutos_comida: int
    horas_efectivas: float | None = None


class JornadaAsignadaOut(BaseModel):
    id: int
    persona_id: str
    tipo_jornada: str
    vigente_desde: date
    vigente_hasta: date | None
    descuento_comida_fija: bool
    minutos_descuento_comida_fija: int | None
    horas_semanales_calculadas: float | None = None
    genera_alerta_horario: bool
    patron_semanal: list[PatronSemanalOut]
