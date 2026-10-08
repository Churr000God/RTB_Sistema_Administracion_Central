"""Tablero de anomalías de una terminal (CONTRATO_API_TERMINALES_PAQUETE_2.md §9). La lógica de cada categoría vive en
`app/anomalias_terminal.py`; aquí sólo el gate, la ventana de fechas y la composición."""

import logging
from time import monotonic
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Path, Query, status
from supabase import Client
from typing import Annotated

from app import permisos
from app.altas_terminal import ContextoCaller
from app.anomalias_terminal import CATEGORIAS, POR_CLAVE, Contexto, tarjeta
from app.catalogo_terminal import valor_vigente
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import MENSAJE_VARIABLE_NO_EXISTE
from app.permisos import requiere_permiso
from app.schemas.terminales import AnomaliaDetalleOut, AnomaliasOut

logger = logging.getLogger(__name__)


class CacheCorto:
    """Caché en memoria de vida corta para el tablero (cada carga hace ~15-20 consultas). La clave incluye al usuario y su
    permiso de marcas: nunca se comparte una respuesta entre quienes ven cosas distintas."""

    def __init__(self, ttl_seg: float = 45.0, maximo: int = 200) -> None:
        self.ttl, self.maximo = ttl_seg, maximo
        self._datos: dict[tuple, tuple[float, dict]] = {}

    def obtener(self, clave: tuple) -> dict | None:
        hallado = self._datos.get(clave)
        if hallado is None:
            return None
        if monotonic() - hallado[0] > self.ttl:
            self._datos.pop(clave, None)
            return None
        return hallado[1]

    def guardar(self, clave: tuple, valor: dict) -> None:
        if len(self._datos) >= self.maximo:
            self._datos.pop(min(self._datos, key=lambda k: self._datos[k][0]))
        self._datos[clave] = (monotonic(), valor)

    def limpiar(self) -> None:
        self._datos.clear()


CACHE = CacheCorto()

router = APIRouter(prefix="/api/terminales/{terminal_id}/anomalias", tags=["terminales"])

ZONA = ZoneInfo("America/Mexico_City")
VENTANA_MAXIMA_DIAS = 90
MENSAJE_VENTANA = "La ventana debe ir de una fecha de inicio a una de fin, con fin posterior al inicio y a lo más 90 días."
MENSAJE_SIN_PERMISO = "No tienes permiso para esta acción."
MENSAJE_TERMINAL = "La terminal no existe."

_PERMISO_VER = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")
IdTerminal = Annotated[int, Path(ge=1, le=9223372036854775807)]


def _ventana(db_servicio: Client, desde: date | None, hasta: date | None) -> tuple[datetime, datetime, datetime]:
    """(desde, hasta, ahora). Por omisión: desde = hoy − `terminal_anomalias_ventana_dias`, hasta = ahora. Las fechas del
    cliente son días de México: desde 00:00 local; hasta, el final de ese día (sin pasar de «ahora»)."""
    ahora = datetime.now(timezone.utc)
    ini = (
        datetime.combine(desde, time.min, tzinfo=ZONA).astimezone(timezone.utc)
        if desde
        else ahora - timedelta(days=valor_vigente(db_servicio, "terminal_anomalias_ventana_dias"))
    )
    fin = (
        min(datetime.combine(hasta + timedelta(days=1), time.min, tzinfo=ZONA).astimezone(timezone.utc), ahora)
        if hasta
        else ahora
    )
    if fin < ini or fin - ini > timedelta(days=VENTANA_MAXIMA_DIAS):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_VENTANA)
    return ini, fin, ahora


def _terminal(db: Client, terminal_id: int) -> dict:
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal")
        .select("id, terminal_id, reloj_desfase_seg")
        .eq("id", terminal_id)
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_TERMINAL)
    return filas[0]


def _contexto(db, db_servicio, terminal, desde, hasta, ahora) -> Contexto:
    return Contexto(
        db=db, db_servicio=db_servicio, terminal_id=terminal["id"], serie=terminal["terminal_id"],
        reloj_desfase_seg=terminal.get("reloj_desfase_seg"), desde=desde, hasta=hasta, ahora=ahora,
    )


def _tiene_marca_lectura(db: Client, caller: CallerIdentity) -> bool:
    return permisos.tiene_alguno(db, ContextoCaller(db, caller).propia, "marca_lectura")


@router.get("", response_model=AnomaliasOut)
def tablero(
    terminal_id: IdTerminal,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_VER),
    db_servicio: Client = Depends(get_service_client),
    desde: date | None = Query(None, description="Día de México (YYYY-MM-DD); por omisión hoy − la ventana configurada."),
    hasta: date | None = Query(None, description="Día de México (YYYY-MM-DD); por omisión ahora."),
) -> dict:
    """Las 10 tarjetas, cada una calculada aislada. Las de marcas de personas (1 y 2) exigen además `marca_lectura`;
    sin él salen `no_disponible` con motivo `sin_permiso`."""
    terminal = _terminal(db, terminal_id)  # también valida que el caller VE la terminal (RLS) antes de tocar la caché
    con_marcas = _tiene_marca_lectura(db, caller)
    clave_cache = (caller.auth_user_id, terminal_id, desde, hasta, con_marcas)
    en_cache = CACHE.obtener(clave_cache)
    if en_cache is not None:
        return en_cache
    ini, fin, ahora = _ventana(db_servicio, desde, hasta)
    ctx = _contexto(db, db_servicio, terminal, ini, fin, ahora)
    respuesta = {
        "terminal_id": terminal_id,
        "desde": ini,
        "hasta": fin,
        "generado_en": ahora,
        "categorias": [tarjeta(c, ctx, con_marcas) for c in CATEGORIAS],
    }
    CACHE.guardar(clave_cache, respuesta)
    return respuesta


@router.get("/{clave}", response_model=AnomaliaDetalleOut)
def detalle(
    terminal_id: IdTerminal,
    clave: Annotated[str, Path(max_length=40)],
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_VER),
    db_servicio: Client = Depends(get_service_client),
    desde: date | None = Query(None),
    hasta: date | None = Query(None),
    limite: int = Query(50, ge=1, le=200),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """«Ver todos» de una categoría, paginado. Una falla aquí SÍ es un error (a diferencia del tablero, que aísla)."""
    categoria = POR_CLAVE.get(clave)
    if categoria is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_VARIABLE_NO_EXISTE)
    if categoria.requiere_marca_lectura and not _tiene_marca_lectura(db, caller):
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO)
    terminal = _terminal(db, terminal_id)
    ini, fin, ahora = _ventana(db_servicio, desde, hasta)
    total, items = categoria.calcular(_contexto(db, db_servicio, terminal, ini, fin, ahora), limite, desplazamiento)
    return {"clave": clave, "total": total, "items": items}
