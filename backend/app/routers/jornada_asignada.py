"""API de tiempo.jornada_asignada / tiempo.patron_semanal (SCJ-PRO-09).

Primer router del subsistema Tiempo -- establece el patrón que el resto de las fases copia.
Gate de permisos: get_caller_client (RLS) + requiere_todos_los_permisos("jornada_asignada_edicion",
"patron_semanal_edicion") (app/permisos.py) -- AND, no OR: el endpoint escribe en las dos tablas,
no se asume que el mapeo de puesto_permiso las otorgue siempre juntas. La RLS de
tiempo.jornada_asignada/tiempo.patron_semanal (fn_caller_activo() + fn_caller_tiene_permiso(...),
armada en paralelo por el equipo de db) es la autorización real -- este chequeo es sólo la capa
de negocio (mensaje 403 legible); nunca service_role para esto, mismo motivo que el hallazgo de
seguridad del 2026-09-04 documentado en CLAUDE.md.
"""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso, requiere_todos_los_permisos
from app.schemas.jornada_asignada import (
    JornadaAsignadaActualizar,
    JornadaAsignadaCreate,
    JornadaAsignadaOut,
    JornadaEnCadena,
    JornadaLimiteActualizar,
    PatronSemanalCreate,
)

router = APIRouter(prefix="/api/jornadas-asignadas", tags=["jornadas-asignadas"])

# Segundo router del mismo módulo, con prefijo anidado bajo /api/personas/{persona_id} -- mismo
# patrón que movimientos.py (recurso de Tiempo consultado desde el expediente de una persona, sin
# mezclarlo con el prefijo propio de "jornadas-asignadas"). Vive en este archivo porque la lógica
# es 100% de jornada_asignada, no de personas.py.
router_persona = APIRouter(prefix="/api/personas/{persona_id}", tags=["jornadas-asignadas"])

CODIGO_VIGENCIA_ACTIVA_SIN_CONFIRMAR = "SCJ01"
CODIGO_VIGENCIA_DESDE_INVALIDA = "SCJ02"

MENSAJE_PERSONA_INVALIDA = "La persona no existe."
MENSAJE_SIN_JORNADA_VIGENTE = "La persona no tiene jornada vigente."
MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR = (
    "Esta persona ya tiene una jornada vigente. Confirmá para cerrarla y asignar la nueva."
)
MENSAJE_VIGENCIA_DESDE_INVALIDA = (
    "La nueva vigencia debe comenzar después de que empezó la jornada actual."
)
MENSAJE_TOPE_LEGAL_EXCEDIDO = (
    "La suma de horas semanales del patrón ({suma} h) se pasa del tope legal vigente ({maximo} h)."
)


def _validar_persona_existe(db: Client, persona_id: str) -> None:
    """tiempo.persona es el stub de la frontera (SCJ-FRO-01) -- sólo tiene id, sin estado. La
    FK de jornada_asignada.persona_id ya lo garantiza en la DB; esto sólo evita un 500 crudo de
    violación de FK a cambio de un 422 legible (mismo criterio que el resto de los routers)."""
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


def _horas_patron(patron: list[PatronSemanalCreate]) -> float:
    total = 0.0
    for fila in patron:
        minutos_jornada = (
            fila.hora_salida.hour * 60 + fila.hora_salida.minute
        ) - (fila.hora_entrada.hour * 60 + fila.hora_entrada.minute)
        total += minutos_jornada / 60.0 - fila.minutos_comida / 60.0
    return total


def _validar_tope_legal(
    db: Client, tipo_jornada: str, vigente_desde: date, patron_semanal: list[PatronSemanalCreate]
) -> None:
    """Capa UX (D1-D4 de SCJ-PRO-09): sólo aplica a tipo_jornada='normal' -- flexible/de_confianza
    no tienen jornada fija que sumar contra un tope. El CONSTRAINT TRIGGER de
    tiempo.patron_semanal (DEFERRABLE INITIALLY DEFERRED, db/ddl/02_tiempo.sql) es la capa real e
    insaltable; esto sólo da feedback temprano, replicando la misma cuenta que hace el trigger.
    Recibe los campos sueltos (no un schema completo) para servir tanto al alta como a la edición
    de jornada futura -- comparten la misma regla, distinto payload."""
    if tipo_jornada != "normal":
        return

    suma_horas = _horas_patron(patron_semanal)
    vigente_desde_iso = vigente_desde.isoformat()

    topes = (
        db.postgrest.schema("tiempo")
        .table("tope_legal")
        .select("maximo_semanal, vigente_hasta")
        .lte("vigente_desde", vigente_desde_iso)
        .order("vigente_desde", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not topes:
        return

    tope = topes[0]
    if tope["vigente_hasta"] is not None and tope["vigente_hasta"] < vigente_desde_iso:
        return

    if suma_horas > float(tope["maximo_semanal"]):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            MENSAJE_TOPE_LEGAL_EXCEDIDO.format(suma=suma_horas, maximo=tope["maximo_semanal"]),
        )


@router.post("", status_code=201, response_model=JornadaAsignadaOut)
def asignar_jornada(
    datos: JornadaAsignadaCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_todos_los_permisos("jornada_asignada_edicion", "patron_semanal_edicion")
    ),
) -> dict:
    """SCJ-PRO-09 A1-G1. Cierre+apertura vive en el RPC transaccional
    tiempo.fn_jornada_asignar_renovar (db/ddl/40_*.sql, SECURITY INVOKER -- sigue exigiendo RLS
    con el permiso específico, éste chequeo sólo da el 403 legible antes de llegar a la BD).
    Si ya hay una vigencia activa y el cliente no confirmó, el RPC revienta con ERRCODE 'SCJ01'
    (B1-B2 del diagrama) -- nunca cierra en silencio. genera_alerta_horario se calcula dentro
    del RPC, no acá."""
    _validar_persona_existe(db, datos.persona_id)
    _validar_tope_legal(db, datos.tipo_jornada, datos.vigente_desde, datos.patron_semanal)

    patron_jsonb = [
        {
            "dia_semana": fila.dia_semana,
            "hora_entrada": fila.hora_entrada.isoformat(),
            "hora_salida": fila.hora_salida.isoformat(),
            "minutos_comida": fila.minutos_comida,
        }
        for fila in datos.patron_semanal
    ]

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_jornada_asignar_renovar",
                {
                    "p_persona_id": datos.persona_id,
                    "p_tipo_jornada": datos.tipo_jornada,
                    "p_vigente_desde": datos.vigente_desde.isoformat(),
                    "p_patron_semanal": patron_jsonb,
                    "p_descuento_comida_fija": datos.descuento_comida_fija,
                    "p_minutos_descuento_comida_fija": datos.minutos_descuento_comida_fija,
                    "p_confirma_cierre_vigente": datos.confirma_cierre_vigente,
                },
            )
            .execute()
        )
    except APIError as error:
        if error.code == CODIGO_VIGENCIA_ACTIVA_SIN_CONFIRMAR:
            raise HTTPException(
                status.HTTP_409_CONFLICT, MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR
            ) from error
        if error.code == CODIGO_VIGENCIA_DESDE_INVALIDA:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_VIGENCIA_DESDE_INVALIDA
            ) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    jornada_nueva = resultado.data

    patron_insertado = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .eq("jornada_asignada_id", jornada_nueva["id"])
        .execute()
        .data
    )

    return {**jornada_nueva, "patron_semanal": patron_insertado}


@router_persona.get("/jornada-vigente", response_model=JornadaAsignadaOut)
def jornada_vigente_de_persona(
    persona_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_permiso("jornada_asignada_lectura", "jornada_asignada_edicion")
    ),
) -> dict:
    """Para el expediente de la persona (calendario semanal) -- 404 si no tiene jornada vigente,
    en vez de devolver null: es una URL de un solo recurso ("la jornada vigente de esta
    persona"), no un listado que pueda venir vacío.

    Bug real encontrado 2026-09-11: filtrar por `vigente_hasta IS NULL` devuelve "la fila
    abierta", que con el plan de jornadas futuras precargadas hoy puede NO ser la vigente hoy --
    puede ser una que todavía no empieza. Mismo criterio de resolución "vigente en una fecha"
    que ya usan corte_quincenal.py/alertas_horario.py: vigente_desde <= hoy AND (vigente_hasta
    IS NULL OR vigente_hasta >= hoy), la de vigente_desde más reciente si hubiera más de una
    candidata (no debería, SCJ-DEC-04)."""
    hoy_iso = date.today().isoformat()
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("*")
        .eq("persona_id", persona_id)
        .lte("vigente_desde", hoy_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{hoy_iso}")
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_SIN_JORNADA_VIGENTE)

    jornada = max(filas, key=lambda fila: fila["vigente_desde"])
    patron = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .eq("jornada_asignada_id", jornada["id"])
        .execute()
        .data
    )
    return {**jornada, "patron_semanal": patron}


def _estado_vigencia(jornada: dict, hoy_iso: str) -> str:
    if jornada["vigente_desde"] > hoy_iso:
        return "futura"
    if jornada["vigente_hasta"] is None or jornada["vigente_hasta"] >= hoy_iso:
        return "en_curso"
    return "pasada"


def _es_ultima_de_cadena(jornada: dict, jornadas: list[dict]) -> bool:
    if jornada["vigente_hasta"] is not None:
        return False
    return not any(
        otra["id"] != jornada["id"] and otra["vigente_desde"] >= jornada["vigente_desde"]
        for otra in jornadas
    )


def _sucesora_inmediata(jornada: dict, jornadas: list[dict]) -> dict | None:
    candidatas = [
        otra
        for otra in jornadas
        if otra["id"] != jornada["id"] and otra["vigente_desde"] > jornada["vigente_desde"]
    ]
    if not candidatas:
        return None
    return min(candidatas, key=lambda otra: otra["vigente_desde"])


def _puede_mover_limite(jornada: dict, jornadas: list[dict], estado_vigencia: str) -> bool:
    if estado_vigencia != "en_curso" or jornada["vigente_hasta"] is None:
        return False
    sucesora = _sucesora_inmediata(jornada, jornadas)
    return sucesora is not None and sucesora["vigente_hasta"] is None


def _armar_jornada_en_cadena(
    jornada: dict, jornadas: list[dict], patrones_por_jornada: dict[int, list[dict]], hoy_iso: str
) -> dict:
    estado_vigencia = _estado_vigencia(jornada, hoy_iso)
    es_ultima = _es_ultima_de_cadena(jornada, jornadas)
    puede_editar_o_eliminar = estado_vigencia == "futura" and es_ultima
    return {
        **jornada,
        "patron_semanal": patrones_por_jornada.get(jornada["id"], []),
        "estado_vigencia": estado_vigencia,
        "es_ultima_de_cadena": es_ultima,
        "puede_editarse": puede_editar_o_eliminar,
        "puede_eliminarse": puede_editar_o_eliminar,
        "puede_mover_limite": _puede_mover_limite(jornada, jornadas, estado_vigencia),
    }


@router_persona.get("/jornadas", response_model=list[JornadaEnCadena])
def listar_jornadas_de_persona(
    persona_id: str,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_permiso("jornada_asignada_lectura", "jornada_asignada_edicion")
    ),
) -> list[dict]:
    """Cadena completa de jornadas de la persona (a diferencia de /jornada-vigente, que sólo
    resuelve una), para la fila expandible de AsignarJornadaPage -- editar/eliminar/mover límite
    necesita ver el resto de la cadena, no sólo la vigente hoy. Lista vacía -> 200 [] (es un
    listado, no un recurso único, al revés que /jornada-vigente)."""
    jornadas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("*")
        .eq("persona_id", persona_id)
        .order("vigente_desde", desc=True)
        .execute()
        .data
    )
    if not jornadas:
        return []

    patrones = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .in_("jornada_asignada_id", [jornada["id"] for jornada in jornadas])
        .execute()
        .data
    )
    patrones_por_jornada: dict[int, list[dict]] = {}
    for fila in patrones:
        patrones_por_jornada.setdefault(fila["jornada_asignada_id"], []).append(fila)

    hoy_iso = date.today().isoformat()
    return [
        _armar_jornada_en_cadena(jornada, jornadas, patrones_por_jornada, hoy_iso)
        for jornada in jornadas
    ]


ERRORES_ELIMINAR = {
    "SCJ01": (status.HTTP_404_NOT_FOUND, "La jornada asignada no existe."),
    "SCJ02": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Sólo se puede eliminar una jornada que todavía no empezó.",
    ),
    "SCJ03": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Sólo se puede eliminar la última jornada de la cadena.",
    ),
}

ERRORES_ACTUALIZAR = {
    "SCJ01": (status.HTTP_404_NOT_FOUND, "La jornada asignada no existe."),
    "SCJ02": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Sólo se puede editar una jornada que todavía no empezó.",
    ),
    "SCJ03": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Sólo se puede editar la última jornada de la cadena.",
    ),
    "SCJ04": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "La jornada debe seguir empezando en una fecha futura.",
    ),
    "SCJ05": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "La nueva fecha no puede empezar antes ni el mismo día que la jornada anterior.",
    ),
    "SCJ06": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "El patrón semanal debe tener al menos un día.",
    ),
}

ERRORES_MOVER_LIMITE = {
    "SCJ01": (status.HTTP_404_NOT_FOUND, "La jornada asignada no existe."),
    "SCJ02": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Sólo se puede mover la fecha de término de la jornada vigente hoy.",
    ),
    "SCJ03": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Esta jornada no tiene fecha de término ni un tramo planeado después.",
    ),
    "SCJ04": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "La fecha de término debe ser posterior a hoy.",
    ),
    "SCJ05": (
        status.HTTP_422_UNPROCESSABLE_ENTITY,
        "Hay más de un tramo planeado después -- eliminá los tramos futuros desde el final "
        "primero.",
    ),
    "SCJ06": (status.HTTP_422_UNPROCESSABLE_ENTITY, "La cadena de jornadas quedó inconsistente."),
}


def _lanzar_error_rpc(error: APIError, mapa: dict[str, tuple[int, str]]) -> None:
    """Un diccionario por RPC, no uno global -- los ERRCODE son locales a cada función
    (db/ddl/76_*.sql), mismo criterio ya documentado en 67_*.sql. El fallback 422 con
    error.message crudo atrapa cualquier 23514 (CHECK) de los triggers de protección de
    vigencias (75_*.sql) que bypassee la validación del RPC."""
    par = mapa.get(error.code)
    if par:
        raise HTTPException(par[0], par[1]) from error
    raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error


@router.patch("/{jornada_id}", response_model=JornadaAsignadaOut)
def actualizar_jornada_futura(
    jornada_id: int,
    datos: JornadaAsignadaActualizar,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_todos_los_permisos("jornada_asignada_edicion", "patron_semanal_edicion")
    ),
) -> dict:
    """Reemplazo total (tipo/fecha/patrón) de la jornada futura terminal de la cadena --
    fn_jornada_futura_actualizar (db/ddl/76_*.sql, SECURITY INVOKER, la RLS de
    39_tiempo_rls_jornada_patron.sql sigue siendo la autorización real) valida que la fila
    todavía no haya empezado y sea la última de la cadena antes de tocar nada."""
    _validar_tope_legal(db, datos.tipo_jornada, datos.vigente_desde, datos.patron_semanal)

    patron_jsonb = [
        {
            "dia_semana": fila.dia_semana,
            "hora_entrada": fila.hora_entrada.isoformat(),
            "hora_salida": fila.hora_salida.isoformat(),
            "minutos_comida": fila.minutos_comida,
        }
        for fila in datos.patron_semanal
    ]

    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_jornada_futura_actualizar",
                {
                    "p_jornada_id": jornada_id,
                    "p_tipo_jornada": datos.tipo_jornada,
                    "p_vigente_desde": datos.vigente_desde.isoformat(),
                    "p_patron_semanal": patron_jsonb,
                    "p_descuento_comida_fija": datos.descuento_comida_fija,
                    "p_minutos_descuento_comida_fija": datos.minutos_descuento_comida_fija,
                },
            )
            .execute()
        )
    except APIError as error:
        _lanzar_error_rpc(error, ERRORES_ACTUALIZAR)

    jornada_actualizada = resultado.data
    patron_actualizado = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .eq("jornada_asignada_id", jornada_actualizada["id"])
        .execute()
        .data
    )
    return {**jornada_actualizada, "patron_semanal": patron_actualizado}


@router.patch("/{jornada_id}/limite", response_model=JornadaAsignadaOut)
def mover_limite_jornada_en_curso(
    jornada_id: int,
    datos: JornadaLimiteActualizar,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_todos_los_permisos("jornada_asignada_edicion", "patron_semanal_edicion")
    ),
) -> dict:
    """Mueve sólo `vigente_hasta` de la jornada vigente HOY -- nunca su fecha de inicio ni su
    patrón. fn_jornada_en_curso_mover_limite (db/ddl/76_*.sql) exige fecha estrictamente futura
    (sin el carve-out de "puede caer hoy" que sí tiene fn_jornada_futura_actualizar al recerrar
    la predecesora) y mueve en cascada el vigente_desde de la sucesora para no dejar hueco ni
    traslape."""
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_jornada_en_curso_mover_limite",
                {"p_jornada_id": jornada_id, "p_vigente_hasta": datos.vigente_hasta.isoformat()},
            )
            .execute()
        )
    except APIError as error:
        _lanzar_error_rpc(error, ERRORES_MOVER_LIMITE)

    jornada_actualizada = resultado.data
    patron = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .eq("jornada_asignada_id", jornada_actualizada["id"])
        .execute()
        .data
    )
    return {**jornada_actualizada, "patron_semanal": patron}


@router.delete("/{jornada_id}", status_code=204)
def eliminar_jornada_futura(
    jornada_id: int,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(
        requiere_todos_los_permisos("jornada_asignada_edicion", "patron_semanal_edicion")
    ),
) -> None:
    """Borra por completo la jornada futura terminal de la cadena (y su patron_semanal) --
    fn_jornada_futura_eliminar (db/ddl/76_*.sql) reabre la predecesora (vigente_hasta = NULL) si
    existía una."""
    try:
        db.postgrest.schema("tiempo").rpc(
            "fn_jornada_futura_eliminar", {"p_jornada_id": jornada_id}
        ).execute()
    except APIError as error:
        _lanzar_error_rpc(error, ERRORES_ELIMINAR)
