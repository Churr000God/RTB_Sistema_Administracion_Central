from datetime import date, datetime

from pydantic import BaseModel, field_validator, model_validator

DECISIONES_VALIDAS = {"autorizada", "rechazada"}
TIPOS_AUSENCIA_APROBADA_VALIDOS = {
    "vacaciones",
    "permiso_con_goce",
    "permiso_sin_goce",
    "incapacidad",
}


class AusenciaOut(BaseModel):
    id: int
    persona_id: str
    persona_nombre: str | None
    tipo_de_ausencia: str
    fecha_inicio: date
    fecha_fin: date
    estado_autorizacion: str
    documento_ref: str | None


class AusenciaListaItem(BaseModel):
    id: int
    persona_id: str
    persona_nombre: str | None = None
    tipo_de_ausencia: str
    fecha_inicio: date
    fecha_fin: date
    estado_autorizacion: str
    documento_ref: str | None
    aprobador_id: str | None = None
    aprobador_nombre: str | None = None
    motivo: str | None = None
    decidido_en: datetime | None = None


class AusenciaListaOut(BaseModel):
    total: int
    ausencias: list[AusenciaListaItem]


class ResolverAusenciaCreate(BaseModel):
    decision: str
    tipo_de_ausencia: str | None = None
    motivo: str | None = None

    @field_validator("decision")
    @classmethod
    def validar_decision(cls, valor: str) -> str:
        if valor not in DECISIONES_VALIDAS:
            raise ValueError(f"decision debe ser una de: {', '.join(sorted(DECISIONES_VALIDAS))}")
        return valor

    @model_validator(mode="after")
    def validar_tipo_si_autorizada(self) -> "ResolverAusenciaCreate":
        """Al autorizar, siempre se reclasifica (SCJ-PRO-08 D1/E1) -- 'falta' no es una
        reclasificación válida, es lo que queda si se rechaza."""
        if self.decision == "autorizada" and self.tipo_de_ausencia not in TIPOS_AUSENCIA_APROBADA_VALIDOS:
            raise ValueError(
                "tipo_de_ausencia es obligatorio al autorizar y debe ser uno de: "
                + ", ".join(sorted(TIPOS_AUSENCIA_APROBADA_VALIDOS))
            )
        return self
