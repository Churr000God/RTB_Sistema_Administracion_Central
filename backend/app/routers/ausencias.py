"""API de tiempo.ausencia/tiempo.aprobacion_ausencia (SCJ-PRO-08). Único flujo de ausencia hoy:
el sistema la crea (batch de cierre de día, Fase 4, todavía no existe) con
tipo_de_ausencia='falta' (placeholder) y estado_autorizacion='pendiente'; este router cubre la
resolución humana -- un solo paso, sin jerarquía, cualquiera de los 3 puestos con el permiso.

Gate: get_caller_client (RLS) -- nunca service_role. Resolver invoca
tiempo.fn_ausencia_resolver (RPC transaccional, SECURITY INVOKER) -- reclasificar tipo_de_ausencia
+ aprobar quedan en una sola transacción real (a diferencia del primer corte de este router, que
hacía UPDATE + INSERT en dos llamadas REST separadas). requiere_todos_los_permisos(...) sigue
haciendo falta para el 403 legible antes de llegar a la BD -- la RLS real (ausencia_edicion +
aprobacion_ausencia_edicion) es la autorización insaltable.

persona_nombre se resuelve del lado del servidor cruzando tiempo.ausencia.persona_id ->
personas.persona (mismo criterio que routers/excepciones.py::_resolver_detalle_marca) -- sin
esto, la bandeja de RH no tiene forma de saber de quién es la ausencia que está resolviendo."""

from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso, requiere_todos_los_permisos
from app.schemas.ausencias import AusenciaListaOut, AusenciaOut, ResolverAusenciaCreate

router = APIRouter(prefix="/api/ausencias", tags=["ausencias"])

UNIQUE_VIOLATION = "23505"
CODIGO_AUSENCIA_NO_ENCONTRADA = "SCJ02"
CODIGO_AUSENCIA_YA_RESUELTA = "SCJ03"
CODIGO_TIPO_INVALIDO = "SCJ04"

MENSAJE_AUSENCIA_NO_ENCONTRADA = "La ausencia no existe."
MENSAJE_AUSENCIA_YA_RESUELTA = "Esta ausencia ya fue resuelta -- alguien más se te adelantó."

LIMITE_DEFECTO = 50
LIMITE_MAXIMO = 200

ORDEN_A_COLUMNA: dict[str, tuple[str, bool]] = {
    "fecha_desc": ("fecha_inicio", True),
    "fecha_asc": ("fecha_inicio", False),
}


def _resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
    ids = sorted(set(persona_ids))
    if not ids:
        return {}
    personas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", ids)
        .execute()
        .data
    )
    return {
        persona["id"]: f"{persona['primer_nombre']} {persona['apellido_paterno']}"
        for persona in personas
    }


def _con_nombre(db: Client, fila: dict) -> dict:
    nombres = _resolver_nombres_persona(db, [fila["persona_id"]])
    return {**fila, "persona_nombre": nombres.get(fila["persona_id"])}


def _con_nombres(db: Client, filas: list[dict]) -> list[dict]:
    nombres = _resolver_nombres_persona(db, [fila["persona_id"] for fila in filas])
    return [{**fila, "persona_nombre": nombres.get(fila["persona_id"])} for fila in filas]


def _resolver_ids_por_busqueda(db: Client, busqueda: str) -> list[str]:
    """Texto libre sobre primer_nombre/apellido_paterno/apellido_materno -- mismo molde que
    tramos.py/dias.py::_resolver_ids_por_busqueda."""
    filtro = f"primer_nombre.ilike.%{busqueda}%,apellido_paterno.ilike.%{busqueda}%,apellido_materno.ilike.%{busqueda}%"
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id")
        .or_(filtro)
        .execute()
        .data
    )
    return [fila["id"] for fila in filas]


def _resolver_aprobaciones(db: Client, ausencia_ids: list[int]) -> dict[int, dict]:
    """Quién aprobó -- se queda con el numero_paso MÁS ALTO por ausencia_id (hoy siempre es 1,
    flujo de un solo paso, pero no hay que asumirlo -- SCJ-DEC-05 Opción C admite varios)."""
    if not ausencia_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("aprobacion_ausencia")
        .select("ausencia_id, numero_paso, aprobador_id, motivo, decidido_en")
        .in_("ausencia_id", ausencia_ids)
        .execute()
        .data
    )
    ultima_por_ausencia: dict[int, dict] = {}
    for fila in filas:
        actual = ultima_por_ausencia.get(fila["ausencia_id"])
        if actual is None or fila["numero_paso"] > actual["numero_paso"]:
            ultima_por_ausencia[fila["ausencia_id"]] = fila
    return ultima_por_ausencia


@router.get("", response_model=AusenciaListaOut)
def listar_ausencias(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("ausencia_lectura", "ausencia_edicion")),
    busqueda_persona: str | None = Query(None, description="Texto libre sobre el nombre."),
    desde: date | None = Query(None, description="fecha_inicio >= desde."),
    hasta: date | None = Query(None, description="fecha_inicio <= hasta."),
    tipo: Literal["vacaciones", "permiso_con_goce", "permiso_sin_goce", "incapacidad", "falta"]
    | None = Query(None),
    estado: Literal["pendiente", "autorizada", "rechazada"] | None = Query(None),
    orden: Literal["fecha_desc", "fecha_asc"] = Query("fecha_desc"),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """Listado completo (a diferencia de /pendientes) -- mismo gate que ya usa este módulo:
    get_caller_client + requiere_permiso, la RLS de ausencia/aprobacion_ausencia es la
    autorización real, nunca service_role."""
    persona_ids: list[str] | None = None
    if busqueda_persona is not None:
        persona_ids = _resolver_ids_por_busqueda(db, busqueda_persona)
        if not persona_ids:
            return {"total": 0, "ausencias": []}

    consulta = db.postgrest.schema("tiempo").table("ausencia").select("*", count="exact")
    if persona_ids is not None:
        consulta = consulta.in_("persona_id", persona_ids)
    if desde is not None:
        consulta = consulta.gte("fecha_inicio", desde.isoformat())
    if hasta is not None:
        consulta = consulta.lte("fecha_inicio", hasta.isoformat())
    if tipo is not None:
        consulta = consulta.eq("tipo_de_ausencia", tipo)
    if estado is not None:
        consulta = consulta.eq("estado_autorizacion", estado)

    columna, descendente = ORDEN_A_COLUMNA[orden]
    resultado = (
        consulta.order(columna, desc=descendente)
        .range(desplazamiento, desplazamiento + limite - 1)
        .execute()
    )

    filas = resultado.data
    nombres = _resolver_nombres_persona(db, [fila["persona_id"] for fila in filas])
    ids_resueltas = [fila["id"] for fila in filas if fila["estado_autorizacion"] != "pendiente"]
    aprobaciones = _resolver_aprobaciones(db, ids_resueltas)
    aprobador_nombres = _resolver_nombres_persona(
        db, [aprobacion["aprobador_id"] for aprobacion in aprobaciones.values()]
    )

    ausencias = []
    for fila in filas:
        aprobacion = aprobaciones.get(fila["id"])
        ausencias.append(
            {
                **fila,
                "persona_nombre": nombres.get(fila["persona_id"]),
                "aprobador_id": aprobacion["aprobador_id"] if aprobacion else None,
                "aprobador_nombre": (
                    aprobador_nombres.get(aprobacion["aprobador_id"]) if aprobacion else None
                ),
                "motivo": aprobacion["motivo"] if aprobacion else None,
                "decidido_en": aprobacion["decidido_en"] if aprobacion else None,
            }
        )
    return {"total": resultado.count, "ausencias": ausencias}


@router.get("/pendientes", response_model=list[AusenciaOut])
def listar_ausencias_pendientes(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("ausencia_lectura", "ausencia_edicion")),
) -> list[dict]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("ausencia")
        .select("*")
        .eq("estado_autorizacion", "pendiente")
        .order("fecha_inicio")
        .execute()
        .data
    )
    return _con_nombres(db, filas)


@router.post("/{ausencia_id}/resolver", response_model=AusenciaOut)
def resolver_ausencia(
    ausencia_id: int,
    datos: ResolverAusenciaCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_todos_los_permisos("ausencia_edicion", "aprobacion_ausencia_edicion")
    ),
) -> dict:
    """SCJ-PRO-08 B1-H2. numero_paso=1 fijo dentro del RPC -- flujo de un solo paso, sin
    jerarquía. aprobador_id se resuelve solo vía auth.uid() dentro de la función, no hace falta
    resolverlo acá. trg_aprobacion_ausencia_actualiza_ausencia recalcula estado_autorizacion
    dentro de la misma transacción del RPC; no se fija a mano."""
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_ausencia_resolver",
                {
                    "p_ausencia_id": ausencia_id,
                    "p_decision": datos.decision,
                    "p_tipo_de_ausencia": datos.tipo_de_ausencia,
                    "p_motivo": datos.motivo,
                },
            )
            .execute()
        )
    except APIError as error:
        if error.code == CODIGO_AUSENCIA_NO_ENCONTRADA:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, MENSAJE_AUSENCIA_NO_ENCONTRADA
            ) from error
        if error.code in (CODIGO_AUSENCIA_YA_RESUELTA, UNIQUE_VIOLATION):
            # SCJ03 (pre-chequeo dentro de la función) o 23505 real de uq_aprobacion_ausencia_
            # paso (H1-H2: dos personas resolviendo a la vez, la función no siempre alcanza a
            # adelantarse a la carrera) -- mismo mensaje en los dos casos.
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_AUSENCIA_YA_RESUELTA) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    return _con_nombre(db, resultado.data)
