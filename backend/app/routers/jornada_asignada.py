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

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso, requiere_todos_los_permisos
from app.schemas.jornada_asignada import (
    JornadaAsignadaCreate,
    JornadaAsignadaOut,
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


def _validar_tope_legal(db: Client, datos: JornadaAsignadaCreate) -> None:
    """Capa UX (D1-D4 de SCJ-PRO-09): sólo aplica a tipo_jornada='normal' -- flexible/de_confianza
    no tienen jornada fija que sumar contra un tope. El CONSTRAINT TRIGGER de
    tiempo.patron_semanal (DEFERRABLE INITIALLY DEFERRED, db/ddl/02_tiempo.sql) es la capa real e
    insaltable; esto sólo da feedback temprano, replicando la misma cuenta que hace el trigger."""
    if datos.tipo_jornada != "normal":
        return

    suma_horas = _horas_patron(datos.patron_semanal)
    vigente_desde_iso = datos.vigente_desde.isoformat()

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
    _validar_tope_legal(db, datos)

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
    persona"), no un listado que pueda venir vacío."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("*")
        .eq("persona_id", persona_id)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_SIN_JORNADA_VIGENTE)

    jornada = filas[0]
    patron = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("*")
        .eq("jornada_asignada_id", jornada["id"])
        .execute()
        .data
    )
    return {**jornada, "patron_semanal": patron}
