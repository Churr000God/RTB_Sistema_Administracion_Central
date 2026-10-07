"""Endpoints del PUENTE (Raspberry Pi) de la terminal biométrica -- credencial de terminal
(`Authorization: Bearer scjt_…`), NO el JWT de un usuario de Supabase (SCJ-DEC-12 §3).

Todo acceso a datos es un RPC SECURITY DEFINER con `p_terminal_id` tomado de la credencial (M2:
el aislamiento entre terminales vive en SQL; aquí nunca se filtra por un `.eq("terminal_id", …)`).
Se usa `service_role` sólo para invocar esos RPC. Corte 1: latido."""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from pydantic import ValidationError
from supabase import Client

from app.deps import get_service_client
from app.errores import manejar_error_terminal
from app.schemas.terminal import LatidoIn, LatidoOut
from app.terminal_auth import MENSAJE_NO_DISPONIBLE, TerminalIdentity, get_terminal_actual

logger = logging.getLogger("app.terminal")

router = APIRouter(prefix="/api/terminal", tags=["terminal"])

MENSAJE_TERMINAL_INCOHERENTE = "La credencial no corresponde a esa terminal."


@router.post("/latido", response_model=LatidoOut)
def latido(
    datos: LatidoIn,
    terminal: TerminalIdentity = Depends(get_terminal_actual),
    db: Client = Depends(get_service_client),
) -> dict:
    """El Pi reporta su estado (~cada 60 s). Guarda el estado del aparato y del reloj y responde la
    hora del servidor, el desfase y la última secuencia recibida (para que un Pi reinstalado
    renumere sin chocar con `uq_marca_terminal_secuencia`, SCJ-DEC-09)."""
    if datos.terminal_id is not None and datos.terminal_id != terminal.serie:
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_TERMINAL_INCOHERENTE)

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_terminal_latido",
                {
                    "p_terminal_id": terminal.id,
                    "p_hora_terminal": (
                        datos.hora_terminal.isoformat() if datos.hora_terminal else None
                    ),
                    "p_alcanzable": datos.terminal_alcanzable,
                    "p_reloj_sincronizado": datos.reloj_sincronizado,
                    "p_version_pi": datos.version_pi,
                    "p_marcas_pendientes": datos.marcas_pendientes,
                },
            )
            .execute()
            .data
        )
    except APIError as error:
        manejar_error_terminal(error)
    except Exception as error:  # red, timeout… hacia Supabase: mismo 503 que la autenticación
        logger.error("terminal: el latido no pudo consultar la base (%s)", type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None

    try:
        # None, {} o sin claves: la forma de la respuesta del RPC no es la esperada
        return LatidoOut.model_validate(resultado).model_dump()
    except ValidationError:
        logger.error("terminal: fn_terminal_latido devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None
