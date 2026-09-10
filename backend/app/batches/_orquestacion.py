"""Orquestación compartida por los batches del subsistema Tiempo (de_confianza, cierre_dia,
corte_quincenal) -- el job programado y el botón manual son la misma invocación para los tres
(SCJ-PRO-12 §V, reusado sin rediseñar en 13/14): UPSERT de tiempo.corrida_batch por
(tipo_batch, fecha), incrementando 'intentos' sobre el valor existente en vez de reemplazarlo."""

from datetime import datetime, timezone

from postgrest.exceptions import APIError
from supabase import Client

UNIQUE_VIOLATION = "23505"


def _releer_y_marcar_en_progreso(db: Client, tipo_batch: str, fecha_iso: str, ahora: str) -> dict:
    fila = (
        db.postgrest.schema("tiempo")
        .table("corrida_batch")
        .select("id, intentos")
        .eq("tipo_batch", tipo_batch)
        .eq("fecha", fecha_iso)
        .execute()
        .data[0]
    )
    return (
        db.postgrest.schema("tiempo")
        .table("corrida_batch")
        .update(
            {
                "estado": "en_progreso",
                "intentos": fila["intentos"] + 1,
                "iniciado_en": ahora,
                "terminado_en": None,
                "detalle": None,
            }
        )
        .eq("id", fila["id"])
        .execute()
        .data[0]
    )


def upsert_corrida_en_progreso(db: Client, tipo_batch: str, fecha_iso: str) -> dict:
    """UPSERT manual, no .upsert() de postgrest -- 'intentos' se incrementa sobre el valor
    existente, algo que un upsert declarativo no puede expresar sin leer antes. Ventana de
    carrera entre el SELECT y el INSERT (el job programado y el botón manual cayendo a la vez
    para el mismo (tipo_batch, fecha)): si el INSERT revienta con 23505 sobre
    uq_corrida_batch_tipo_fecha, releer y actualizar en vez de propagar un 500 crudo."""
    existente = (
        db.postgrest.schema("tiempo")
        .table("corrida_batch")
        .select("id, intentos")
        .eq("tipo_batch", tipo_batch)
        .eq("fecha", fecha_iso)
        .execute()
        .data
    )
    ahora = datetime.now(timezone.utc).isoformat()
    if existente:
        fila = existente[0]
        return (
            db.postgrest.schema("tiempo")
            .table("corrida_batch")
            .update(
                {
                    "estado": "en_progreso",
                    "intentos": fila["intentos"] + 1,
                    "iniciado_en": ahora,
                    "terminado_en": None,
                    "detalle": None,
                }
            )
            .eq("id", fila["id"])
            .execute()
            .data[0]
        )
    try:
        return (
            db.postgrest.schema("tiempo")
            .table("corrida_batch")
            .insert(
                {
                    "tipo_batch": tipo_batch,
                    "fecha": fecha_iso,
                    "estado": "en_progreso",
                    "intentos": 1,
                    "iniciado_en": ahora,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        if error.code == UNIQUE_VIOLATION:
            return _releer_y_marcar_en_progreso(db, tipo_batch, fecha_iso, ahora)
        raise


def finalizar_corrida(db: Client, corrida_id: int, estado_final: str, detalle: str) -> dict:
    return (
        db.postgrest.schema("tiempo")
        .table("corrida_batch")
        .update(
            {
                "estado": estado_final,
                "terminado_en": datetime.now(timezone.utc).isoformat(),
                "detalle": detalle,
            }
        )
        .eq("id", corrida_id)
        .execute()
        .data[0]
    )
