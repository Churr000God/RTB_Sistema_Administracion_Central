"""API de tiempo.marca (SCJ-PRO-07: captura manual). Primer router humano que escribe en
tiempo.marca -- origen='captura_manual', la vía ordinaria para quien no otorgó consentimiento
biométrico o no logra enrolar, no una excepción rara.

Gate: get_caller_client (RLS) + requiere_permiso("captura_manual_edicion") -- NO heredable
(confirmado con el usuario 2026-09-05), NUNCA service_role: la RLS de tiempo.marca/tiempo.excepcion
que arma db es la autorización real, mismo motivo que el resto de los routers de Tiempo.

evento_id nace en el frontend (UUID v4, al montar el formulario, no al enviar) -- es la llave de
idempotencia de reintentos (doble clic, reintento de red). NUNCA se genera acá. Sin
capturista_id ni ningún campo de quién capturó: ese dato vive en el esquema Operación, fuera de
alcance (SCJ-ESP-01 §I.4 regla 4, mismo criterio que genera_alerta_horario en SCJ-PRO-09)."""

from datetime import date, datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.dias_habiles import _dias_habiles_limite, _dias_habiles_transcurridos, _festivos_entre
from app.permisos import requiere_permiso
from app.schemas.marcas import (
    MarcaCapturaManualCreate,
    MarcaCapturaManualOut,
    MarcaListaOut,
)

router = APIRouter(prefix="/api/marcas", tags=["marcas"])

UNIQUE_VIOLATION = "23505"
LIMITE_DEFECTO = 50
LIMITE_MAXIMO = 200
VERSION_SOFTWARE = "0.1.0"  # SCJ-PRO-07 D1: "versión de la app web" -- la fija el backend, no el
# cliente (mismo criterio que el firmware de un terminal fija la suya). Mantener en sync con
# backend/pyproject.toml -> [project].version.

MENSAJE_PERSONA_INVALIDA = "La persona no existe."
MENSAJE_MOMENTO_FUTURO = "La hora del dispositivo no puede ser futura."
MENSAJE_VENTANA_VENCIDA = (
    "La captura retroactiva sólo admite hasta {dias} día(s) hábil(es) hacia atrás -- esa hora "
    "ya venció esa ventana."
)


def _validar_persona_existe(db: Client, persona_id: str) -> None:
    """tiempo.persona es el stub de la frontera (SCJ-FRO-01). No es un chequeo de
    activo/inactivo -- eso lo decide trg_marca_valida_revision como señal, nunca como rechazo
    (SCJ-CDT-01 §II.5: la evidencia nunca se pierde). Esto sólo evita un 500 crudo de violación
    de FK si el persona_id no corresponde a nadie sincronizado."""
    fila = (
        db.postgrest.schema("tiempo")
        .table("persona")
        .select("id")
        .eq("id", persona_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PERSONA_INVALIDA)


def _buscar_marca_por_evento_id(db: Client, evento_id: str) -> dict | None:
    filas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, evento_id, requiere_revision, momento_dispositivo, momento_recepcion")
        .eq("evento_id", evento_id)
        .execute()
        .data
    )
    return filas[0] if filas else None


def _motivos_revision(db: Client, marca_id: int) -> list[str]:
    """Pueden acumularse varios (persona_inactiva Y dia_cerrado Y fuera_de_horario a la vez) --
    trg_marca_valida_revision los evalúa todos, no se detiene en el primero."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("motivo_revision")
        .eq("marca_id", marca_id)
        .order("id")
        .execute()
        .data
    )
    return [fila["motivo_revision"] for fila in filas]


def _armar_respuesta(db: Client, marca_fila: dict, duplicado: bool) -> dict:
    motivos = _motivos_revision(db, marca_fila["id"]) if marca_fila["requiere_revision"] else []
    return {
        "evento_id": marca_fila["evento_id"],
        "duplicado": duplicado,
        "momento_dispositivo": marca_fila["momento_dispositivo"],
        "momento_recepcion": marca_fila["momento_recepcion"],
        "requiere_revision": marca_fila["requiere_revision"],
        "motivos_revision": motivos,
    }


def _desfase_local_en(momento: datetime) -> str:
    """Desfase UTC vigente EN momento (no el de 'ahora'), formato '+HH:MM'/'-HH:MM'
    (ck_marca_desfase_local) -- SCJ-CDT-01 §VII.1. astimezone() sin argumento resuelve el offset
    real de la zona horaria del proceso para ESE instante puntual (no uno fijo cacheado al
    arrancar), relevante si algún día vuelve el horario de verano -- hoy en México da lo mismo,
    pero la firma correcta evita tener que migrar datos entonces."""
    offset = momento.astimezone().utcoffset()
    total_minutos = int(offset.total_seconds() // 60)
    signo = "+" if total_minutos >= 0 else "-"
    horas, minutos = divmod(abs(total_minutos), 60)
    return f"{signo}{horas:02d}:{minutos:02d}"


def _validar_momento_dispositivo(momento: datetime) -> None:
    """Sólo corre cuando el caller manda una hora explícita (None = ahora, siempre válido). RLS
    (db/ddl/61_*.sql) ya pone un techo duro de 90 días calendario -- esto da el mensaje legible
    y la ventana fina en días hábiles, que RLS no puede calcular sin duplicar lógica de
    tiempo.dia_festivo/tiempo.parametro en SQL (mismo reparto que correcciones.py)."""
    ahora = datetime.now(timezone.utc)
    if momento > ahora:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MOMENTO_FUTURO)

    limite = _dias_habiles_limite()
    hoy = date.today()
    fecha_momento = momento.date()
    festivos = _festivos_entre(fecha_momento, hoy)
    transcurridos = _dias_habiles_transcurridos(fecha_momento, hoy, festivos)
    if transcurridos > limite:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_VENTANA_VENCIDA.format(dias=limite)
        )


def _resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
    """Mismo cruce que excepciones.py::_resolver_detalle_marca -- tiempo.marca sólo tiene
    persona_id (SCJ-FRO-01), el nombre vive en personas.persona."""
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", persona_ids)
        .execute()
        .data
    )
    return {fila["id"]: f"{fila['primer_nombre']} {fila['apellido_paterno']}" for fila in filas}


def _resolver_motivos_y_pendiente_por_marca(
    db: Client, marca_ids: list[int]
) -> tuple[dict[int, list[str]], dict[int, int]]:
    """Mismo patrón y mismo criterio de "no consultar si no hace falta" que
    _resolver_nombres_persona -- una sola consulta batch, nada si ninguna marca de la página
    requiere revisión.

    tiempo.marca.requiere_revision es de una sola vía (el trigger la pone true, nunca la vuelve
    a false) -- no sirve para saber si hay algo pendiente AHORA. La señal real es
    tiempo.excepcion.estado = 'pendiente' (mismo criterio que GET /api/excepciones), por eso esta
    función también devuelve, por marca, el id de su excepción pendiente más antigua (si la
    tiene) -- 'Corregir' en el frontend sólo tiene sentido con ese id."""
    if not marca_ids:
        return {}, {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("id, marca_id, motivo_revision, estado")
        .in_("marca_id", marca_ids)
        .order("id")
        .execute()
        .data
    )
    motivos: dict[int, list[str]] = {}
    pendientes: dict[int, int] = {}
    for fila in filas:
        motivos.setdefault(fila["marca_id"], []).append(fila["motivo_revision"])
        if fila["estado"] == "pendiente" and fila["marca_id"] not in pendientes:
            pendientes[fila["marca_id"]] = fila["id"]
    return motivos, pendientes


def _resolver_momento_efectivo_por_marca(db: Client, marca_ids: list[int]) -> dict[int, datetime]:
    """Mismo cálculo que el trigger SQL fn_correccion_valida (db/ddl/02_tiempo.sql:414-419):
    COALESCE(último tiempo.correccion.valor_corregido por marca_id ordenado por creado_en DESC,
    momento_dispositivo si no hay corrección). tiempo.marca es INSERT-only (SCJ-DEC-03) -- la
    corrección vive en otra tabla, así que este helper corre sobre TODAS las marcas de la
    página, no sólo las que requieren_revision (una marca puede tener corrección aunque ya no
    requiera revisión)."""
    if not marca_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("correccion")
        .select("marca_id, valor_corregido, creado_en")
        .in_("marca_id", marca_ids)
        .order("creado_en", desc=True)
        .execute()
        .data
    )
    efectivo: dict[int, datetime] = {}
    for fila in filas:
        efectivo.setdefault(fila["marca_id"], fila["valor_corregido"])
    return efectivo


def _estado_revision(requiere_revision: bool, excepcion_pendiente_id: int | None) -> str:
    """Derivado de campos ya calculados, sin query nueva. requiere_revision es de una sola vía
    (nunca baja a false) -- por eso no alcanza sola para saber si ya se resolvió."""
    if not requiere_revision:
        return "sin_revision"
    if excepcion_pendiente_id is not None:
        return "pendiente"
    return "resuelta"


@router.get("", response_model=MarcaListaOut)
def listar_marcas(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("marca_lectura", "captura_manual_edicion")),
    persona_id: str | None = Query(None, description="Filtra por una persona exacta."),
    desde: datetime | None = Query(
        None, description="momento_recepcion >= desde (ISO 8601, incluye hora)."
    ),
    hasta: datetime | None = Query(
        None, description="momento_recepcion <= hasta (ISO 8601, incluye hora)."
    ),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """Listado paginado para la pestaña de marcas en vivo (polling desde el frontend, sin
    websocket -- SCJ-PRO-11/07 no piden push real). Más reciente primero, siempre:
    momento_recepcion es el momento en que el servidor la recibió, no el que declara el
    dispositivo (SCJ-DEC-08), así que es el único campo confiable para "recién pasó esto".

    fecha+hora es un solo filtro de rango (desde/hasta) en vez de campos separados: el cliente
    arma el ISO 8601 combinando su selector de fecha y de hora (fecha sola -> desde=00:00:00,
    hasta=23:59:59 del mismo día); evita duplicar en el backend la lógica de "día completo" vs.
    "franja horaria" que la UI ya resuelve mejor."""
    consulta = db.postgrest.schema("tiempo").table("marca").select("*", count="exact")
    if persona_id is not None:
        consulta = consulta.eq("persona_id", persona_id)
    if desde is not None:
        consulta = consulta.gte("momento_recepcion", desde.isoformat())
    if hasta is not None:
        consulta = consulta.lte("momento_recepcion", hasta.isoformat())

    resultado = (
        consulta.order("momento_recepcion", desc=True)
        .range(desplazamiento, desplazamiento + limite - 1)
        .execute()
    )

    nombres = _resolver_nombres_persona(db, sorted({fila["persona_id"] for fila in resultado.data}))
    ids_con_revision = sorted(
        {fila["id"] for fila in resultado.data if fila["requiere_revision"]}
    )
    motivos, pendientes = _resolver_motivos_y_pendiente_por_marca(db, ids_con_revision)
    ids_pagina = sorted({fila["id"] for fila in resultado.data})
    efectivos = _resolver_momento_efectivo_por_marca(db, ids_pagina)
    marcas = [
        {
            **fila,
            "persona_nombre": nombres.get(fila["persona_id"]),
            "motivos_revision": motivos.get(fila["id"], []),
            "excepcion_pendiente_id": pendientes.get(fila["id"]),
            "momento_efectivo": efectivos.get(fila["id"], fila["momento_dispositivo"]),
            "estado_revision": _estado_revision(
                fila["requiere_revision"], pendientes.get(fila["id"])
            ),
        }
        for fila in resultado.data
    ]
    return {"total": resultado.count, "marcas": marcas}


@router.post("/captura-manual", status_code=201, response_model=MarcaCapturaManualOut)
def captura_manual(
    datos: MarcaCapturaManualCreate,
    response: Response,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("captura_manual_edicion")),
) -> dict:
    """SCJ-PRO-07 A4-G1. evento_id ya visto -> 200 idempotente, NO 409 (es un reintento
    legítimo de red/doble clic, no un conflicto). Si no, INSERT y deja que
    trg_marca_valida_revision (SCJ-PRO-11) decida requiere_revision/motivo_revision -- no se
    calculan acá."""
    existente = _buscar_marca_por_evento_id(db, datos.evento_id)
    if existente is not None:
        response.status_code = status.HTTP_200_OK
        return _armar_respuesta(db, existente, duplicado=True)

    _validar_persona_existe(db, datos.persona_id)

    ahora = datetime.now(timezone.utc)
    if datos.momento_dispositivo is None:
        momento_dispositivo = ahora
    else:
        momento_dispositivo = datos.momento_dispositivo
        if momento_dispositivo.tzinfo is None:
            momento_dispositivo = momento_dispositivo.replace(tzinfo=timezone.utc)
        _validar_momento_dispositivo(momento_dispositivo)

    try:
        db.postgrest.schema("tiempo").table("marca").insert(
            {
                "evento_id": datos.evento_id,
                "persona_id": datos.persona_id,
                "terminal_id": datos.terminal_id,
                "secuencia_local": None,
                "momento_dispositivo": momento_dispositivo.isoformat(),
                "momento_recepcion": ahora.isoformat(),
                "desfase_local": _desfase_local_en(momento_dispositivo),
                "estado_reloj": "sincronizado",
                "version_software": VERSION_SOFTWARE,
                "origen": "captura_manual",
                "requiere_revision": False,
            }
        ).execute()
    except APIError as error:
        if error.code == UNIQUE_VIOLATION:
            # Carrera: dos envíos del mismo evento_id casi simultáneos (doble clic real) --
            # idempotente también acá, no un error.
            existente = _buscar_marca_por_evento_id(db, datos.evento_id)
            response.status_code = status.HTTP_200_OK
            return _armar_respuesta(db, existente, duplicado=True)
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    # RETURNING del INSERT queda desactualizado frente al UPDATE que hace el AFTER trigger sobre
    # la misma fila (requiere_revision) -- se relee después de que el INSERT (con su trigger) ya
    # terminó, no se confía en la respuesta del INSERT para ese campo.
    fila_fresca = _buscar_marca_por_evento_id(db, datos.evento_id)
    return _armar_respuesta(db, fila_fresca, duplicado=False)
