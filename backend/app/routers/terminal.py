"""Endpoints del PUENTE (Raspberry Pi) de la terminal biométrica -- credencial de terminal
(`Authorization: Bearer scjt_…`), NO el JWT de un usuario de Supabase (SCJ-DEC-12 §3).

Todo acceso a datos es un RPC SECURITY DEFINER con `p_terminal_id` tomado de la credencial (M2:
el aislamiento entre terminales vive en SQL; aquí nunca se filtra por un `.eq("terminal_id", …)`).
Se usa `service_role` sólo para invocar esos RPC. Corte 1: latido."""

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Response, status
from postgrest.exceptions import APIError
from pydantic import ValidationError
from supabase import Client

from app.deps import get_service_client
from app.detalle_terminal import DetalleProhibido, sanear_detalle
from app.errores import MENSAJE_TRANSICION_INVALIDA, manejar_error_terminal
from app.schemas.terminal import (
    CLAVES_ENTERAS,
    CLAVES_EVENTO,
    CODIGOS_DEFINITIVOS,
    CODIGOS_TRANSITORIOS,
    ACCION_POR_ESTADO,
    AltaTerminalOut,
    AltasTerminalOut,
    ENTERO_MAXIMO,
    LatidoIn,
    LatidoOut,
    MarcasIn,
    MarcasOut,
    MovimientoIn,
    MovimientoOut,
)
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


# --- POST /marcas ----------------------------------------------------------------------------------------------------------------


def _evento_limpio(evento, version_software: str) -> dict:
    """Reconstruye el evento con LISTA BLANCA: se descartan `origen`, `requiere_revision`, `persona_id`, `fingerData` y todo lo
    demás; sólo pasan cadenas y enteros acotados (otro tipo se omite y el RPC lo rechaza como forma_invalida de ESE evento). La
    versión del software la pone el backend en cada evento."""
    limpio: dict = {}
    if isinstance(evento, dict):
        for clave in CLAVES_EVENTO:
            valor = evento.get(clave)
            if clave in CLAVES_ENTERAS:
                # entero estricto: bool y float no valen (isinstance(True, int) es True), y acotado
                if type(valor) is int and abs(valor) <= ENTERO_MAXIMO:
                    limpio[clave] = valor
            elif type(valor) is str and _cadena_segura(valor):
                limpio[clave] = valor
    limpio["version_software"] = version_software
    return limpio


def _cadena_segura(valor: str) -> bool:
    """≤ 64 caracteres, sin NUL ni controles (un \u0000 hace fallar a Postgres con 22P05 y tumbaría el LOTE entero) y
    codificable en UTF-8 (un sustituto suelto reventaría al serializar hacia Supabase). Un valor que no cumple se OMITE y el
    RPC rechaza ESE evento como forma_invalida."""
    if len(valor) > 64 or any(ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F for c in valor):
        return False
    try:
        valor.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _validar_resultados(data, n_eventos: int) -> MarcasOut:
    """La respuesta del RPC se VALIDA antes de reenviarla al Pi: un resultado por evento, índices 0..n-1 sin repetir, vocabulario
    cerrado y código coherente con el estado. Cualquier otra cosa levanta ValueError/ValidationError (-> 503)."""
    salida = MarcasOut.model_validate(data)
    resultados = salida.resultados
    if len(resultados) != n_eventos or [r.indice for r in resultados] != list(range(n_eventos)):
        raise ValueError("resultados incompletos o desordenados")
    for r in resultados:
        if r.estado in ("confirmado", "duplicado"):
            ok = r.codigo is None
        elif r.estado == "rechazo_definitivo":
            ok = r.codigo in CODIGOS_DEFINITIVOS
        else:
            ok = r.codigo in CODIGOS_TRANSITORIOS
        if not ok:
            raise ValueError("código incoherente con el estado")
    return salida


@router.post("/marcas", response_model=MarcasOut)
def registrar_marcas(
    datos: MarcasIn,
    terminal: TerminalIdentity = Depends(get_terminal_actual),
    db: Client = Depends(get_service_client),
) -> dict:
    """Ruta de marcas (SCJ-DEC-12 §2): lote de 1 a 200 eventos, confirmación INDIVIDUAL, idempotente por `evento_id`. Llama
    `fn_marca_terminal_registrar(p_terminal_id, p_eventos)` con el id de la CREDENCIAL; el RPC resuelve employee_no -> persona
    (el persona_id nunca sale), fija origen='terminal' y guarda la evidencia de los rechazos definitivos."""
    if datos.terminal_id is not None and datos.terminal_id != terminal.serie:
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_TERMINAL_INCOHERENTE)

    eventos = [_evento_limpio(e, datos.version_software) for e in datos.eventos]
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc("fn_marca_terminal_registrar", {"p_terminal_id": terminal.id, "p_eventos": eventos})
            .execute()
            .data
        )
    except APIError as error:
        manejar_error_terminal(error)
    except Exception as error:  # red, timeout… hacia Supabase: 503, nunca un 200 con 200 transitorios
        logger.error("terminal: las marcas no pudieron llegar a la base (%s)", type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None

    try:
        return _validar_resultados(resultado, len(eventos)).model_dump(mode="json")
    except (ValidationError, ValueError):
        logger.error("terminal: fn_marca_terminal_registrar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None


# --- GET /cola y GET /mapa ---------------------------------------------------------------------------------------------------------


def _leer_mapa(db: Client, terminal: TerminalIdentity) -> list[AltaTerminalOut]:
    """`fn_terminal_mapa(p_terminal_id)`: el aislamiento entre terminales vive en SQL (M2), el backend no filtra por terminal. La
    respuesta se valida CAMPO POR CAMPO (extra=forbid): un persona_id, un nombre o un estado fuera del vocabulario que llegara del
    RPC NO se reenvía al Pi, es un 503."""
    try:
        data = db.postgrest.schema("tiempo").rpc("fn_terminal_mapa", {"p_terminal_id": terminal.id}).execute().data
    except APIError as error:
        manejar_error_terminal(error)
    except Exception as error:
        logger.error("terminal: el mapa no pudo consultar la base (%s)", type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None
    try:
        if not isinstance(data, list):
            raise ValueError("el mapa no es una lista")
        altas = [AltaTerminalOut.model_validate({**fila, "accion": ACCION_POR_ESTADO.get(fila.get("estado"))}) for fila in data]
    except (ValidationError, ValueError, TypeError, AttributeError):
        logger.error("terminal: fn_terminal_mapa devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None
    return sorted(altas, key=lambda a: a.employee_no)


def _respuesta_altas(altas: list[AltaTerminalOut]) -> dict:
    return AltasTerminalOut(hora_servidor=datetime.now(timezone.utc), altas=altas).model_dump(mode="json")


@router.get("/cola", response_model=AltasTerminalOut)
def cola(
    terminal: TerminalIdentity = Depends(get_terminal_actual),
    db: Client = Depends(get_service_client),
) -> dict:
    """Trabajo pendiente del Pi: el mapa filtrado a `pendiente_alta`, `esperando_huella` y `pendiente_baja`, cada una con su
    `accion` (crear_usuario | sondear_huellas | borrar_usuario). Sin persona_id ni nombres."""
    return _respuesta_altas([a for a in _leer_mapa(db, terminal) if a.accion is not None])


@router.get("/mapa", response_model=AltasTerminalOut)
def mapa(
    terminal: TerminalIdentity = Depends(get_terminal_actual),
    db: Client = Depends(get_service_client),
) -> dict:
    """Todas las altas no-`baja` de la terminal (incluye `activo`, con `accion: null`) para reconciliar el aparato contra el
    servidor."""
    return _respuesta_altas(_leer_mapa(db, terminal))


# --- POST /movimientos -----------------------------------------------------------------------------------------------------------

MENSAJE_ALTA_NO_EXISTE = "La alta no existe."
MENSAJE_DETALLE_PROHIBIDO = "El detalle contiene contenido no permitido."
MENSAJE_ERRORES_DEMASIADOS = "Demasiados errores reportados para esta alta; reintenta más tarde."
REINTENTO_LIMITADO_SEG = 300


@router.post("/movimientos", response_model=MovimientoOut)
def registrar_movimiento(
    datos: MovimientoIn,
    terminal: TerminalIdentity = Depends(get_terminal_actual),
    db: Client = Depends(get_service_client),
) -> dict:
    """El Pi reporta `usuario_creado`, `huella_capturada` (con el CONTEO, nunca una plantilla), `baja_confirmada` o `error` sobre
    una alta de SU terminal. `fn_terminal_movimiento_registrar` bloquea la alta, es idempotente y toma terminal/persona/employee_no
    de la fila: el Pi sólo manda el id de la alta. Una alta de otra terminal responde IGUAL que una inexistente (404)."""
    detalle = None
    if datos.tipo == "error":
        try:
            detalle = sanear_detalle(datos.codigo, datos.detalle)
        except DetalleProhibido:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DETALLE_PROHIBIDO) from None

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_terminal_movimiento_registrar",
                {
                    "p_terminal_id": terminal.id,
                    "p_terminal_usuario_id": datos.terminal_usuario_id,
                    "p_tipo": datos.tipo,
                    "p_huellas": datos.huellas,
                    "p_detalle": detalle,
                },
            )
            .execute()
            .data
        )
    except APIError as error:
        if error.code == "SCJ11":  # transición inválida: el Pi relee la cola
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_TRANSICION_INVALIDA) from None
        manejar_error_terminal(error)
    except Exception as error:
        logger.error("terminal: el movimiento no pudo consultar la base (%s)", type(error).__name__)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None

    clave = resultado.get("resultado") if isinstance(resultado, dict) else None
    if clave == "no_encontrado":
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_ALTA_NO_EXISTE)
    if clave == "limitado":
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS, MENSAJE_ERRORES_DEMASIADOS, headers={"Retry-After": str(REINTENTO_LIMITADO_SEG)}
        )
    try:
        if clave not in ("registrado", "ya_aplicado"):
            raise ValueError("resultado desconocido")
        return MovimientoOut.model_validate({"resultado": clave, "estado": resultado.get("estado")}).model_dump()
    except (ValidationError, ValueError):
        logger.error("terminal: fn_terminal_movimiento_registrar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_NO_DISPONIBLE) from None
