"""Batch de jornada de_confianza (SCJ-PRO-14) -- el más simple de los tres batches del
subsistema Tiempo, estrena la orquestación job+botón+corrida_batch que cierre_dia/corte_quincenal
(Fase 4) van a reusar sin volver a diseñarla.

ejecutar_batch_de_confianza es el punto de entrada tanto del job programado (app/scheduler.py,
BackgroundScheduler de APScheduler en el lifespan de FastAPI, id fijo + replace_existing=True)
como del botón manual (routers/corridas_batch.py) -- misma invocación, mismo mecanismo de
corrida_batch e idempotencia por persona (SCJ-PRO-14 §III/§V). Corre como service_role: es un
proceso de sistema, no un caller humano sujeto a RLS."""

import logging
from datetime import date

from postgrest.exceptions import APIError
from supabase import Client

from app.batches._orquestacion import finalizar_corrida, upsert_corrida_en_progreso
from app.config import get_settings
from app.deps import get_service_client

UNIQUE_VIOLATION = "23505"
TIPO_BATCH = "de_confianza"

logger = logging.getLogger(__name__)


def _personas_de_confianza_vigentes(db: Client, fecha_iso: str) -> list[str]:
    """jornada_asignada vigente en fecha: vigente_desde <= fecha y (vigente_hasta NULL o >=
    fecha) -- misma condición de vigencia que el resto del proyecto (SCJ-DEC-04)."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("persona_id")
        .eq("tipo_jornada", "de_confianza")
        .lte("vigente_desde", fecha_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{fecha_iso}")
        .execute()
        .data
    )
    return [fila["persona_id"] for fila in filas]


def _crear_dia_si_no_existe(db: Client, persona_id: str, fecha_iso: str) -> bool:
    """True si creó el día, False si ya existía (idempotente -- SCJ-PRO-14 §III D1/D2).
    tiempo.dia tiene a lo sumo una fila por (persona_id, fecha) sin importar el origen
    (uq_dia_persona_fecha) -- probar el INSERT y atrapar 23505 evita una consulta extra."""
    try:
        db.postgrest.schema("tiempo").table("dia").insert(
            {
                "persona_id": persona_id,
                "fecha": fecha_iso,
                "estado": "cerrado",
                "horas_totales": None,
                "origen": "automatico_confianza",
            }
        ).execute()
        return True
    except APIError as error:
        if error.code == UNIQUE_VIOLATION:
            return False
        raise


def ejecutar_batch_de_confianza(fecha: date, db: Client | None = None) -> dict:
    """SCJ-PRO-14 A1-G3. Si no se pasa un cliente ya armado (tests, o el endpoint del botón
    manual que ya tiene el suyo), arma uno de service_role propio -- así el scheduler de devops
    puede invocar esta función directo (fecha) sin pasar por FastAPI Depends. Una persona que
    revienta no detiene a las demás (SCJ-PRO-14 §V): se captura por persona y sigue con las
    siguientes."""
    if db is None:
        db = get_service_client(get_settings())

    fecha_iso = fecha.isoformat()
    corrida = upsert_corrida_en_progreso(db, TIPO_BATCH, fecha_iso)

    creados = 0
    ya_existian = 0
    errores: list[str] = []

    for persona_id in _personas_de_confianza_vigentes(db, fecha_iso):
        try:
            if _crear_dia_si_no_existe(db, persona_id, fecha_iso):
                creados += 1
            else:
                ya_existian += 1
        except Exception as error:  # noqa: BLE001 -- por diseño: aislar la falla de una persona
            errores.append(f"{persona_id}: {error}")

    if errores:
        # RLS de corrida_batch sólo exige fn_caller_activo(), sin permiso específico (a
        # propósito) -- detalle no debe llevar persona_id crudo. El detalle completo (con
        # persona_id) va al log del servidor, no a la fila.
        logger.error("batch de_confianza fecha=%s errores=%s", fecha_iso, errores)
        detalle = (
            f"{creados} día(s) creado(s), {ya_existian} ya existían, "
            f"{len(errores)} error(es) -- ver logs del servidor."
        )
        estado_final = "fallida"
    else:
        detalle = f"{creados} día(s) creado(s), {ya_existian} ya existían."
        estado_final = "exitosa"

    return finalizar_corrida(db, corrida["id"], estado_final, detalle)
