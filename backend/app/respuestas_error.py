"""Errores HTTP con campos hermanos de `detail` (CONTRATO_API_TERMINALES_PAQUETE_2.md §6.1)."""

from fastapi import HTTPException
from fastapi.responses import JSONResponse


class ErrorConCampos(HTTPException):
    """HTTPException cuyo cuerpo es `{"detail": <texto fijo>, **campos}`: los 409/422 que necesitan devolver datos
    (`consentimiento_vigente`, `no_elegibles`, `valor_actual`). El `detail` sigue siendo siempre el texto fijo y `codigo` es un
    identificador estable (`consentimiento_desactualizado`, `version_base_desactualizada`, `valor_desactualizado`,
    `lote_no_elegible`, `lote_reintentar`)."""

    def __init__(self, status_code: int, detail: str, campos: dict, codigo: str | None = None) -> None:
        super().__init__(status_code=status_code, detail=detail)
        self.campos = campos
        self.codigo = codigo


async def manejar_error_con_campos(request, exc: ErrorConCampos) -> JSONResponse:
    contenido = {"detail": exc.detail}
    if exc.codigo:
        contenido["codigo"] = exc.codigo  # estable: el frontend decide por `codigo`, nunca por el texto de `detail`
    return JSONResponse(status_code=exc.status_code, content={**contenido, **exc.campos})
