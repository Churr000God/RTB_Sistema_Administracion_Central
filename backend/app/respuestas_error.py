"""Errores HTTP con campos hermanos de `detail` (CONTRATO_API_TERMINALES_PAQUETE_2.md §6.1)."""

from fastapi import HTTPException
from fastapi.responses import JSONResponse


class ErrorConCampos(HTTPException):
    """HTTPException cuyo cuerpo es `{"detail": <texto fijo>, **campos}`: los 409/422 que necesitan devolver datos
    (`consentimiento_vigente`, `no_elegibles`, `valor_actual`). El `detail` sigue siendo siempre el texto fijo."""

    def __init__(self, status_code: int, detail: str, campos: dict) -> None:
        super().__init__(status_code=status_code, detail=detail)
        self.campos = campos


async def manejar_error_con_campos(request, exc: ErrorConCampos) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail, **exc.campos})
