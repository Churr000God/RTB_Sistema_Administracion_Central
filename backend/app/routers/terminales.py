"""API WEB de Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md, SCJ-DEC-12 §4–§6). Es la cara que ve
Recursos Humanos / TI; NO es la del puente (`routers/terminal.py`, credencial de terminal).

Gate: get_caller_client (la RLS de cada tabla es la autorización real) + requiere_permiso(...) sólo para
un 403 legible. Nunca service_role para escribir. Corte C2: lista de terminales con el estado de su puente."""

import logging
import re
from collections import namedtuple
from datetime import date, datetime, timezone
from typing import Literal
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Path, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.altas_terminal import (
    _consentimientos_por_id,
    armar_altas,
    ids_pendientes,
    pendientes_de_terminal,
    ContextoCaller,
    razon_no_elegible,
    resolver_nombres_persona,
    sanear_motivo,
)
from app.consentimiento_terminal import (
    error_consentimiento_desactualizado,
    leer_vigente,
    manejar_error_con_consentimiento,
)
from app.config import Settings, get_settings
from app.deps import CallerIdentity, get_caller_client, get_caller_identity, get_service_client
from app.errores import MENSAJE_AUTO_ASIGNACION, MENSAJE_LOTE_INVALIDO, MENSAJE_LOTE_NO_ELEGIBLE, manejar_error_terminal_web
from app.respuestas_error import ErrorConCampos
from app.contacto_terminal import estado_contacto, segundos_sin_contacto as _segundos, ultimo_contacto  # noqa: F401  (estado_contacto se re-exporta: lo usan las pruebas y el tablero)
from app import permisos
from app.permisos import requiere_permiso
from app.schemas.terminales import (
    AltaDePersonaOut,
    AltaOut,
    AltasListaOut,
    AsignarCreate,
    BajaCreate,
    HuellaConfirmadaCreate,
    MovimientoAltaOut,
    PendientesOut,
    PersonaAsignableOut,
    ReconsentimientoOut,
    ReconsentirAltaCreate,
    ReconsentirLoteCreate,
    TerminalOut,
)

logger = logging.getLogger(__name__)

_Pagina = namedtuple("_Pagina", "data count")

router = APIRouter(prefix="/api/terminales", tags=["terminales"])

MENSAJE_TERMINAL_NO_ENCONTRADA = "La terminal no existe."

# bigint de Postgres: 0, negativos y > 2**63-1 dan 422 aquí en vez de llegar a la base y volver 500.
IdTerminal = Annotated[int, Path(ge=1, le=9223372036854775807)]
IdAlta = Annotated[int, Path(ge=1, le=9223372036854775807)]

# Columnas visibles de tiempo.terminal (ninguna es secreto; las credenciales viven en otra tabla).
COLUMNAS_TERMINAL = (
    "id, terminal_id, nombre, modelo, activa, ultimo_contacto_en, terminal_alcanzable, "
    "reloj_desfase_seg, version_pi, marcas_pendientes"
)


def _armar_terminal(fila: dict, ahora: datetime, umbral_seg: int) -> dict:
    ultimo, _ilegible = ultimo_contacto(fila)
    nivel, segundos = estado_contacto(fila["activa"], ultimo, ahora, umbral_seg)
    return {
        "id": fila["id"],
        "serie": fila["terminal_id"],
        "nombre": fila.get("nombre") or fila.get("terminal_id") or "Sin nombre",
        "modelo": fila.get("modelo"),
        "activa": fila["activa"],
        "estado_contacto": nivel,
        "ultimo_contacto_en": ultimo,
        "segundos_sin_contacto": segundos,
        "terminal_alcanzable": fila.get("terminal_alcanzable"),
        "reloj_desfase_seg": fila.get("reloj_desfase_seg"),
        "version_pi": fila.get("version_pi"),
        "marcas_pendientes": fila.get("marcas_pendientes"),
    }


@router.get("", response_model=list[TerminalOut])
def listar_terminales(
    db: Client = Depends(get_caller_client),
    settings: Settings = Depends(get_settings),
    _permiso: None = Depends(requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")),
) -> list[dict]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal")
        .select(COLUMNAS_TERMINAL)
        .order("nombre")
        .execute()
        .data
    )
    ahora = datetime.now(timezone.utc)
    return [_armar_terminal(fila, ahora, settings.terminal_umbral_sin_contacto_seg) for fila in filas]


@router.get("/{terminal_id}", response_model=TerminalOut)
def obtener_terminal(
    terminal_id: IdTerminal,
    db: Client = Depends(get_caller_client),
    settings: Settings = Depends(get_settings),
    _permiso: None = Depends(requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")),
) -> dict:
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal")
        .select(COLUMNAS_TERMINAL)
        .eq("id", terminal_id)
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_TERMINAL_NO_ENCONTRADA)
    return _armar_terminal(filas[0], datetime.now(timezone.utc), settings.terminal_umbral_sin_contacto_seg)


# ======================================================================================================
# Altas (usuarios) de una terminal — C4 (sin los campos de consentimiento, que llegan con C5)
# ======================================================================================================

MENSAJE_ALTA_NO_ENCONTRADA = "El alta no existe."
COLUMNAS_ALTA = (
    "id, terminal_id, employee_no, persona_id, estado, huellas_capturadas, huella_evidencia, error_detalle, "
    "creado_en, actualizado_en, usuario_creado_en, consentimiento_id"
)
ESTADOS_ALTA = ("pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja")
LIMITE_DEFECTO = 100
LIMITE_MAXIMO = 200
LIMITE_ASIGNABLES = 50
LIMITE_HISTORIAL = 500
LIMITE_ALTAS_PERSONA = 200
PAGINA_CANDIDATAS = 100
# Decisión del usuario (2026-10-08): la baja manual exige motivo de al menos MOTIVO_BAJA_MIN caracteres.
MOTIVO_BAJA_OBLIGATORIO = True
MOTIVO_BAJA_MIN = 10
MOTIVO_BAJA_MAX = 500
MENSAJE_MOTIVO_BAJA = f"El motivo de la baja debe tener entre {MOTIVO_BAJA_MIN} y {MOTIVO_BAJA_MAX} caracteres."
MAX_PAGINAS_CANDIDATAS = 5
MIN_BUSQUEDA = 2

_PERMISO_LECTURA = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")
_PERMISO_EDICION = requiere_permiso("terminal_usuario_edicion")


def _verificar_terminal(db: Client, terminal_id: int) -> None:
    """Un {id} inexistente o invisible para el caller (RLS) es 404; así una lista vacía significa «sin altas»."""
    filas = db.postgrest.schema("tiempo").table("terminal").select("id").eq("id", terminal_id).execute().data
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_TERMINAL_NO_ENCONTRADA)


def _leer_alta(db: Client, terminal_id: int, tu_id: int) -> dict:
    """El alta, SIEMPRE filtrada por la terminal de la URL: un tu_id de otra terminal es 404 (no se revela)."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select(COLUMNAS_ALTA)
        .eq("id", tu_id)
        .eq("terminal_id", terminal_id)
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_ALTA_NO_ENCONTRADA)
    return filas[0]


@router.get("/{terminal_id}/usuarios", response_model=AltasListaOut)
def listar_altas(
    terminal_id: IdTerminal,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_LECTURA),
    db_servicio: Client = Depends(get_service_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    estado: Literal["pendiente_alta", "esperando_huella", "activo", "pendiente_baja", "baja"] | None = Query(None),
    reconsentimiento: Literal["pendiente", "al_corriente"] | None = Query(
        None, description="Filtra por la definición única de «reconsentimiento pendiente» de la base."
    ),
    persona_id: UUID | None = Query(None, description="Una persona exacta (UUID)."),
    desde: date | None = Query(None, description="Asignadas desde (fecha, sobre creado_en)."),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """Cliente del caller (RLS de terminal_usuario); db_servicio sólo para leer la variable de caducidad
    (tiempo.parametro es deny-all). Más recientes primero. `resumen` cuenta TODAS las altas de la terminal."""
    _verificar_terminal(db, terminal_id)
    tabla = db.postgrest.schema("tiempo").table

    consulta = tabla("terminal_usuario").select(COLUMNAS_ALTA, count="exact").eq("terminal_id", terminal_id)
    if estado is not None:
        consulta = consulta.eq("estado", estado)
    if persona_id is not None:
        consulta = consulta.eq("persona_id", str(persona_id))
    if desde is not None:
        consulta = consulta.gte("creado_en", desde.isoformat())
    # Definición ÚNICA de pendiente = la función de la base (88_). Se filtra primero POR TERMINAL en la base e intersecta en
    # Python (la URL de PostgREST no crece con las altas de otras terminales).
    pendientes = ids_pendientes(db)
    pendientes_aqui_ids = [f["id"] for f in pendientes_de_terminal(db, terminal_id, pendientes)]
    vacia = False
    if reconsentimiento == "pendiente":
        if pendientes_aqui_ids:
            consulta = consulta.in_("id", pendientes_aqui_ids)
        else:
            vacia = True
    elif reconsentimiento == "al_corriente" and pendientes_aqui_ids:
        consulta = consulta.not_.in_("id", pendientes_aqui_ids)
    if vacia:
        resultado = _Pagina([], 0)
    else:
        resultado = (
            consulta.order("creado_en", desc=True)
            .order("id", desc=True)
            .range(desplazamiento, desplazamiento + limite - 1)
            .execute()
        )

    # Conteo por estado en la base (head: sin traer filas), no descargando todas las altas.
    por_estado = {}
    for e in ESTADOS_ALTA:
        conteo = (
            tabla("terminal_usuario")
            .select("id", count="exact", head=True)
            .eq("terminal_id", terminal_id)
            .eq("estado", e)
            .execute()
        )
        por_estado[e] = conteo.count or 0
    return {
        "total": resultado.count if resultado.count is not None else len(resultado.data),
        "resumen": {"por_estado": por_estado, "reconsentimiento_pendiente": len(pendientes_aqui_ids)},
        "altas": armar_altas(db, db_servicio, resultado.data, caller, pendientes),
    }


MENSAJE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
MENSAJE_CONSENTIMIENTO_NO_RECABADO = (
    "Confirma que se recabó el consentimiento y el aviso de privacidad antes de asignar."
)
MENSAJE_SIN_TEXTO_CONSENTIMIENTO = "Todavía no hay texto de consentimiento; avisa a Sistemas."


@router.post("/{terminal_id}/usuarios", status_code=201, response_model=AltaOut)
def asignar_persona(
    terminal_id: IdTerminal,
    datos: AsignarCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Asigna una persona a la terminal, con la versión del texto de consentimiento vigente. Escribe en la bitácora
    con el cliente del CALLER: la policy bitacora_terminal_usuario_insert_web y el trigger son la autorización real."""
    if not datos.consentimiento_recabado:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_CONSENTIMIENTO_NO_RECABADO)
    _verificar_terminal(db, terminal_id)

    # Primera barrera (la base la repite): nadie se asigna a sí mismo salvo el puesto administrador.
    propia = permisos.resolver_persona_id(db, caller)
    if str(datos.persona_id) == propia and not permisos.es_administrador_generico(db, propia):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_AUTO_ASIGNACION)

    vigente = leer_vigente(db)
    if vigente is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_SIN_TEXTO_CONSENTIMIENTO)
    if vigente["id"] != datos.consentimiento_id:
        raise error_consentimiento_desactualizado(db, vigente)

    try:
        creado = (
            db.postgrest.schema("tiempo")
            .table("bitacora_movimiento_terminal_usuario")
            .insert(
                {
                    "terminal_id": terminal_id,
                    "persona_id": str(datos.persona_id),
                    "tipo_movimiento": "asignado",
                    "origen": "web",
                    "registrado_por": caller.auth_user_id,
                    "consentimiento_id": datos.consentimiento_id,
                }
            )
            .execute()
            .data
        )
    except APIError as error:
        manejar_error_con_consentimiento(error, db, contexto="asignacion")
    tu_id = creado[0].get("terminal_usuario_id") if creado else None
    if tu_id is None:
        logger.error("asignar: la bitácora no devolvió terminal_usuario_id")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    return armar_altas(db, db_servicio, [_leer_alta(db, terminal_id, tu_id)], caller)[0]


@router.post("/{terminal_id}/usuarios/{tu_id}/baja", status_code=201, response_model=AltaOut)
def solicitar_baja(
    terminal_id: IdTerminal,
    tu_id: IdAlta,
    datos: BajaCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Baja de un alta; «Cancelar alta» y «Dar de baja» son el MISMO movimiento (baja_solicitada), que sólo
    cambia según el estado de origen. Se escribe con el cliente del CALLER: la policy
    bitacora_terminal_usuario_insert_web (persona activa, terminal_usuario_edicion, origen web, autor =
    auth.uid()) es la autorización real. El trigger valida la transición (SCJ11)."""
    motivo = sanear_motivo(datos.motivo, truncar=False)
    if motivo is not None and len(motivo) > MOTIVO_BAJA_MAX:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MOTIVO_BAJA)
    if MOTIVO_BAJA_OBLIGATORIO and (motivo is None or len(motivo) < MOTIVO_BAJA_MIN):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MOTIVO_BAJA)
    alta = _leer_alta(db, terminal_id, tu_id)
    try:
        db.postgrest.schema("tiempo").table("bitacora_movimiento_terminal_usuario").insert(
            {
                "terminal_usuario_id": alta["id"],
                "terminal_id": alta["terminal_id"],
                "persona_id": alta["persona_id"],
                "tipo_movimiento": "baja_solicitada",
                "detalle": motivo,
                "origen": "web",
                "registrado_por": caller.auth_user_id,
            }
        ).execute()
    except APIError as error:
        manejar_error_terminal_web(error)
    return armar_altas(db, db_servicio, [_leer_alta(db, terminal_id, tu_id)], caller)[0]


# 94_: qué movimiento deja qué evidencia de huella (la columna terminal_usuario.huella_evidencia la fija el trigger con la misma correspondencia).
EVIDENCIA_POR_MOVIMIENTO = {"huella_capturada": "conteo", "huella_inferida": "inferida", "huella_confirmada_manual": "manual"}

# Nota obligatoria de la confirmación manual (D5): el trigger exige 10 caracteres ya saneados; el backend lo valida antes y topa el largo.
NOTA_CONFIRMACION_MIN = 10
NOTA_CONFIRMACION_MAX = 500
MENSAJE_NOTA_CONFIRMACION = f"La nota de la confirmación debe tener entre {NOTA_CONFIRMACION_MIN} y {NOTA_CONFIRMACION_MAX} caracteres."


@router.post("/{terminal_id}/usuarios/{tu_id}/huella-confirmada", status_code=201, response_model=AltaOut)
def confirmar_huella(
    terminal_id: IdTerminal,
    tu_id: IdAlta,
    datos: HuellaConfirmadaCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
    db_servicio: Client = Depends(get_service_client),
) -> dict:
    """Una persona con permiso declara que la huella quedó enrolada en el menú de la terminal: el alta pasa de esperando_huella a activo con evidencia «manual». Se
    escribe en la bitácora con el cliente del CALLER: la policy bitacora_terminal_usuario_insert_web (persona activa, terminal_usuario_edicion, origen web, autor =
    auth.uid()) y el trigger son la autorización real (SCJ11 estado, SCJ12 auto-confirmación / nota). No hay conteo ni plantilla: sólo la declaración de una persona. Una
    confirmación equivocada no se deshace: se pide la baja y se asigna de nuevo."""
    nota = sanear_motivo(datos.nota, truncar=False)
    if nota is None or not NOTA_CONFIRMACION_MIN <= len(nota) <= NOTA_CONFIRMACION_MAX:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_NOTA_CONFIRMACION)
    alta = _leer_alta(db, terminal_id, tu_id)
    try:
        db.postgrest.schema("tiempo").table("bitacora_movimiento_terminal_usuario").insert(
            {
                "terminal_usuario_id": alta["id"],
                "terminal_id": alta["terminal_id"],
                "persona_id": alta["persona_id"],
                "tipo_movimiento": "huella_confirmada_manual",
                "detalle": nota,
                "origen": "web",
                "registrado_por": caller.auth_user_id,
            }
        ).execute()
    except APIError as error:
        manejar_error_terminal_web(error)
    return armar_altas(db, db_servicio, [_leer_alta(db, terminal_id, tu_id)], caller)[0]


MENSAJE_REINTENTAR = "No se registró nada porque el estado de las altas cambió; vuelve a intentarlo."
MENSAJE_DECLARACION_DOCUMENTOS = "Confirma que los documentos firmados existen antes de registrar el reconsentimiento."
TOPE_LOTE_RECONSENTIMIENTO = 200
TOPE_PENDIENTES = 200


@router.get("/{terminal_id}/reconsentimientos-pendientes", response_model=PendientesOut)
def reconsentimientos_pendientes(
    terminal_id: IdTerminal,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_LECTURA),
) -> dict:
    """Ids de TODAS las altas de esta terminal con reconsentimiento pendiente (tope 200), para «Seleccionar las N
    pendientes» sin depender de la página. La alta PROPIA de quien llama se excluye (no puede registrarla) salvo que
    sea el administrador genérico."""
    _verificar_terminal(db, terminal_id)
    filas = pendientes_de_terminal(db, terminal_id, ids_pendientes(db))
    if filas:
        ctx = ContextoCaller(db, caller)
        filas = [f for f in filas if not (ctx.es_propia(f["persona_id"]) and not ctx.es_admin)]
    ids = [f["id"] for f in filas]
    return {"total": len(ids), "ids": ids[:TOPE_PENDIENTES], "hay_mas": len(ids) > TOPE_PENDIENTES}


def _no_elegibles(
    db: Client, caller: CallerIdentity, terminal_id: int, ids: list[int], pendientes: set[int]
) -> list[dict]:
    """Por cada id del lote que NO se puede reconsentir ahora: {tu_id, persona_nombre, razon}. `no_encontrada` (no
    existe, es de otra terminal o el caller no la ve) va SIN nombre para no filtrar existencia."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select("id, persona_id, estado")
        .eq("terminal_id", terminal_id)
        .in_("id", ids)
        .execute()
        .data
    )
    por_id = {f["id"]: f for f in filas}
    ctx = ContextoCaller(db, caller)
    nombres = resolver_nombres_persona(db, [f["persona_id"] for f in filas])
    resultado = []
    for tu_id in ids:
        fila = por_id.get(tu_id)
        if fila is None:
            resultado.append({"tu_id": tu_id, "persona_nombre": None, "razon": "no_encontrada"})
            continue
        razon = razon_no_elegible(fila["estado"], fila["persona_id"], ctx, tu_id in pendientes)
        if razon is not None:
            resultado.append({"tu_id": tu_id, "persona_nombre": nombres.get(fila["persona_id"]), "razon": razon})
    return resultado


def _registrar_reconsentimiento(
    db: Client,
    caller: CallerIdentity,
    terminal_id: int,
    ids: list[int],
    consentimiento_id: int,
    declaracion: bool,
) -> dict:
    """Núcleo compartido del reconsentimiento por alta y en lote (todo o nada)."""
    if not declaracion:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DECLARACION_DOCUMENTOS)
    ids = sorted(set(ids))
    if not ids or len(ids) > TOPE_LOTE_RECONSENTIMIENTO:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_LOTE_INVALIDO)
    _verificar_terminal(db, terminal_id)

    vigente = leer_vigente(db)
    if vigente is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_SIN_TEXTO_CONSENTIMIENTO)
    if vigente["id"] != consentimiento_id:
        raise error_consentimiento_desactualizado(db, vigente)

    pendientes = ids_pendientes(db)
    malas = _no_elegibles(db, caller, terminal_id, ids, pendientes)
    if malas:
        raise ErrorConCampos(
            status.HTTP_409_CONFLICT, MENSAJE_LOTE_NO_ELEGIBLE, {"no_elegibles": malas}, codigo="lote_no_elegible"
        )

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_terminal_reconsentir",
                {"p_altas": ids, "p_consentimiento_id": consentimiento_id, "p_estricto": True},
            )
            .execute()
            .data
        )
    except APIError as error:
        if error.code == "22023" and (error.hint or "") == "lote_no_elegible":
            # Carrera entre mi verificación y el RPC: se reconstruye la lista (nunca el DETAIL de la base).
            otras = _no_elegibles(db, caller, terminal_id, ids, ids_pendientes(db))
            if not otras:  # la carrera se resolvió sola: no se devuelve un 409 vacío e incomprensible
                raise ErrorConCampos(status.HTTP_409_CONFLICT, MENSAJE_REINTENTAR, {}, codigo="lote_reintentar") from None
            raise ErrorConCampos(
                status.HTTP_409_CONFLICT, MENSAJE_LOTE_NO_ELEGIBLE, {"no_elegibles": otras}, codigo="lote_no_elegible"
            ) from None
        manejar_error_con_consentimiento(error, db)
    if not isinstance(resultado, dict) or not isinstance(resultado.get("registradas"), int):
        logger.error("fn_terminal_reconsentir devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    omitidas = [int(x) for x in resultado.get("omitidas") or []]
    if omitidas:  # no debería pasar con p_estricto=true; se informa en vez de ocultarlo
        logger.error("fn_terminal_reconsentir omitió %s altas pese a p_estricto", len(omitidas))
    return {
        "registradas": resultado["registradas"],
        "pendientes_restantes": len(ids_pendientes(db)),
        "omitidas": omitidas,
    }


@router.post("/{terminal_id}/usuarios/reconsentimientos", status_code=201, response_model=ReconsentimientoOut)
def reconsentir_lote(
    terminal_id: IdTerminal,
    datos: ReconsentirLoteCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
) -> dict:
    """Todo o nada: si alguna alta no es elegible, 409 con `no_elegibles` y NADA se escribe. Escribe el RPC
    (SECURITY INVOKER) con el cliente del caller: la policy de la bitácora es la autorización real."""
    return _registrar_reconsentimiento(
        db, caller, terminal_id, datos.tu_ids, datos.consentimiento_id, datos.declaracion_documentos
    )


@router.post("/{terminal_id}/usuarios/{tu_id}/reconsentimiento", status_code=201, response_model=ReconsentimientoOut)
def reconsentir_alta(
    terminal_id: IdTerminal,
    tu_id: IdAlta,
    datos: ReconsentirAltaCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
) -> dict:
    """Equivale a un lote de un elemento."""
    return _registrar_reconsentimiento(
        db, caller, terminal_id, [tu_id], datos.consentimiento_id, datos.declaracion_documentos
    )


@router.get("/{terminal_id}/usuarios/{tu_id}/movimientos", response_model=list[MovimientoAltaOut])
def historial_de_un_alta(
    terminal_id: IdTerminal,
    tu_id: IdAlta,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_LECTURA),
) -> list[dict]:
    """Bitácora inmutable del alta, más reciente primero. El nombre de quien la hizo sale de
    personas.usuario; los movimientos del puente (origen='terminal') no tienen autor."""
    _leer_alta(db, terminal_id, tu_id)
    filas = (
        db.postgrest.schema("tiempo")
        .table("bitacora_movimiento_terminal_usuario")
        .select(
            "id, tipo_movimiento, creado_en, origen, registrado_por, detalle, huellas_capturadas, consentimiento_id"
        )
        .eq("terminal_usuario_id", tu_id)
        .order("creado_en", desc=True)
        .order("id", desc=True)
        .limit(LIMITE_HISTORIAL)
        .execute()
        .data
    )
    autores = sorted({f["registrado_por"] for f in filas if f.get("registrado_por")})
    nombre_por_autor: dict[str, str] = {}
    if autores:
        nombre_por_autor = {
            u["auth_user_id"]: u["nombre_usuario"]
            for u in db.postgrest.schema("personas")
            .table("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", autores)
            .execute()
            .data
        }
    consentimientos = _consentimientos_por_id(db, [f["consentimiento_id"] for f in filas if f.get("consentimiento_id")])
    return [
        {
            "id": f["id"],
            "tipo_movimiento": f["tipo_movimiento"],
            "creado_en": f["creado_en"],
            "origen": f["origen"],
            "registrado_por_nombre": nombre_por_autor.get(f.get("registrado_por")),
            "detalle": f.get("detalle"),
            "huellas_capturadas": f.get("huellas_capturadas"),
            "huella_evidencia": EVIDENCIA_POR_MOVIMIENTO.get(f["tipo_movimiento"]),
            "consentimiento": (
                {
                    "id": consentimientos[f["consentimiento_id"]]["id"],
                    "version": consentimientos[f["consentimiento_id"]]["version"],
                    "cambio_material": consentimientos[f["consentimiento_id"]]["cambio_material"],
                }
                if f.get("consentimiento_id") in consentimientos
                else None
            ),
        }
        for f in filas
    ]


def _sanear_busqueda(texto: str) -> str:
    """Sólo letras, dígitos, espacios, guion y apóstrofo: el texto se interpola en un filtro `or=(…)` de
    PostgREST, donde comas, paréntesis, puntos y asteriscos tienen significado."""
    limpio = re.sub(r"[^\w\s'\-]", " ", texto, flags=re.UNICODE).replace("_", " ")
    return " ".join(limpio.split())


def _puesto_y_area(db: Client, persona_ids: list[str]) -> dict[str, tuple[str | None, str | None]]:
    """{persona_id: (puesto, area)} de la asignación VIGENTE; si hay varias, la de vigente_desde más
    reciente. Cuatro consultas por lote (asignaciones, puestos, departamentos, áreas), no una por persona."""
    if not persona_ids:
        return {}
    tabla = db.postgrest.schema("personas").table
    asignaciones = (
        tabla("asignacion")
        .select("persona_id, puesto_id, vigente_desde")
        .in_("persona_id", persona_ids)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    elegida: dict[str, dict] = {}
    for fila in asignaciones:
        actual = elegida.get(fila["persona_id"])
        if actual is None or str(fila["vigente_desde"]) > str(actual["vigente_desde"]):
            elegida[fila["persona_id"]] = fila
    if not elegida:
        return {}
    puestos = {
        p["id"]: p
        for p in tabla("puesto")
        .select("id, nombre_puesto, departamento_id")
        .in_("id", sorted({a["puesto_id"] for a in elegida.values()}))
        .execute()
        .data
    }
    departamentos = {
        d["id"]: d
        for d in tabla("departamento")
        .select("id, area_id")
        .in_("id", sorted({p["departamento_id"] for p in puestos.values()}))
        .execute()
        .data
    }
    areas = {
        a["id"]: a["nombre_area"]
        for a in tabla("area")
        .select("id, nombre_area")
        .in_("id", sorted({d["area_id"] for d in departamentos.values()}))
        .execute()
        .data
    }
    resultado = {}
    for persona, asignacion in elegida.items():
        puesto = puestos.get(asignacion["puesto_id"])
        departamento = departamentos.get(puesto["departamento_id"]) if puesto else None
        resultado[persona] = (
            puesto["nombre_puesto"] if puesto else None,
            areas.get(departamento["area_id"]) if departamento else None,
        )
    return resultado


@router.get("/{terminal_id}/personas-asignables", response_model=list[PersonaAsignableOut])
def personas_asignables(
    terminal_id: IdTerminal,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_EDICION),
    busqueda: str | None = Query(None, max_length=100),
    limite: int = Query(LIMITE_ASIGNABLES, ge=1, le=LIMITE_ASIGNABLES),
) -> list[dict]:
    """Personas `activo` SIN alta vigente (estado distinto de baja) en esa terminal, con su puesto y área
    vigentes para distinguir homónimos (null si no hay asignación vigente). Lo filtra el backend: el cliente
    no tiene la lista completa de personas ni todas las altas."""
    _verificar_terminal(db, terminal_id)
    texto = _sanear_busqueda(busqueda) if busqueda is not None else None
    if texto is not None and len(texto) < MIN_BUSQUEDA:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, f"La búsqueda necesita al menos {MIN_BUSQUEDA} caracteres."
        )

    # Quien llama no se ofrece a sí mismo (la base rechaza la auto-asignación salvo el puesto administrador).
    propia = permisos.resolver_persona_id(db, caller)
    excluir_propia = not permisos.es_administrador_generico(db, propia)

    consulta = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno, apellido_materno")
        .eq("estado", "activo")
    )
    if texto:
        consulta = consulta.or_(
            f"primer_nombre.ilike.%{texto}%,apellido_paterno.ilike.%{texto}%,apellido_materno.ilike.%{texto}%"
        )
    consulta = consulta.order("apellido_paterno").order("primer_nombre").order("id")

    # Se recorre por páginas hasta juntar `limite` libres: «ocupadas» se consulta sólo para los candidatos de
    # cada página (nunca una lista global que PostgREST truncaría a 1000).
    elegidas: list[dict] = []
    vistos: set[str] = set()
    for pagina in range(MAX_PAGINAS_CANDIDATAS):
        desde = pagina * PAGINA_CANDIDATAS
        lote = consulta.range(desde, desde + PAGINA_CANDIDATAS - 1).execute().data
        nuevos = [p for p in lote if p["id"] not in vistos]
        vistos.update(p["id"] for p in nuevos)
        if excluir_propia:
            nuevos = [p for p in nuevos if p["id"] != propia]
        ocupadas = set()
        if nuevos:
            ocupadas = {
                f["persona_id"]
                for f in db.postgrest.schema("tiempo")
                .table("terminal_usuario")
                .select("persona_id")
                .eq("terminal_id", terminal_id)
                .neq("estado", "baja")
                .in_("persona_id", [p["id"] for p in nuevos])
                .execute()
                .data
            }
        elegidas.extend(p for p in nuevos if p["id"] not in ocupadas)
        if len(elegidas) >= limite or len(lote) < PAGINA_CANDIDATAS:
            break
    elegidas = elegidas[:limite]
    puesto_area = _puesto_y_area(db, [p["id"] for p in elegidas])
    return [
        {
            "persona_id": p["id"],
            "nombre": f"{p['primer_nombre']} {p['apellido_paterno']}",
            "puesto": puesto_area.get(p["id"], (None, None))[0],
            "area": puesto_area.get(p["id"], (None, None))[1],
        }
        for p in elegidas
    ]


# --- GET /api/personas/{id}/terminales (sección «Terminal» de la ficha) --------------------------------------

router_personas = APIRouter(prefix="/api/personas/{persona_id}/terminales", tags=["terminales"])


@router_personas.get("", response_model=list[AltaDePersonaOut])
def terminales_de_una_persona(
    persona_id: UUID,
    db: Client = Depends(get_caller_client),
    settings: Settings = Depends(get_settings),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(_PERMISO_LECTURA),
    db_servicio: Client = Depends(get_service_client),
) -> list[dict]:
    """Altas de UNA persona en todas las terminales (incluidas las de baja; la UI decide cuáles pinta). Sin
    permiso de lectura: 403, y el frontend oculta la sección con la bandera de sesión."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select(COLUMNAS_ALTA)
        .eq("persona_id", str(persona_id))
        .order("creado_en", desc=True)
        .order("id", desc=True)
        .limit(LIMITE_ALTAS_PERSONA)
        .execute()
        .data
    )
    if not filas:
        return []
    altas = armar_altas(db, db_servicio, filas, caller)
    terminales = {
        t["id"]: t
        for t in db.postgrest.schema("tiempo")
        .table("terminal")
        .select(COLUMNAS_TERMINAL)
        .in_("id", sorted({f["terminal_id"] for f in filas}))
        .execute()
        .data
    }
    ahora = datetime.now(timezone.utc)
    umbral = settings.terminal_umbral_sin_contacto_seg
    return [
        {"alta": alta, "terminal": _armar_terminal(terminales[alta["terminal_id"]], ahora, umbral)}
        for alta in altas
        if alta["terminal_id"] in terminales
    ]
