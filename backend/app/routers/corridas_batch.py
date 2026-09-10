"""API de tiempo.corrida_batch -- botón manual de los batches del subsistema Tiempo. SCJ-PRO-14
(de_confianza) estrenó el patrón; SCJ-PRO-12 (cierre_dia) y SCJ-PRO-13 (corte_quincenal) lo
reusan sin volver a diseñarlo.

Cada batch en sí corre con service_role (app/batches/*.py -- es un proceso de sistema, no un
caller humano). Este router sólo gatea el botón manual con permiso antes de invocarlo.

Gateado con corrida_batch_edicion (heredable, mapeado a Responsable de Recursos Humanos/Gerente
General/Gerente o Encargado de TI -- confirmado y aplicado por db). No existía en el catálogo
original de 33_*.sql (pensado originalmente sólo para lectura/edición de tablas concretas, no
para "disparar un proceso"); tiempo_persona_edicion no servía como stopgap porque 34_*.sql lo
deja deliberadamente fuera de RH/Gerente General."""

from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.batches.cierre_dia import ejecutar_cierre_dia
from app.batches.corte_quincenal import ejecutar_corte_quincenal
from app.batches.de_confianza import ejecutar_batch_de_confianza
from app.deps import get_caller_client, get_service_client
from app.hora_cierre_dia import resolver_umbral_cierre_dia
from app.permisos import requiere_permiso
from app.schemas.corridas_batch import CorridaBatchOut, EjecutarBatchRequest

router = APIRouter(prefix="/api/corridas-batch", tags=["corridas-batch"])

CODIGO_PERMISO_BATCH = "corrida_batch_edicion"

MENSAJE_CIERRE_DIA_FUTURO = "No se puede cerrar un día que todavía no ocurre."
MENSAJE_CIERRE_DIA_ANTES_DEL_UMBRAL = (
    "El cierre de día de hoy no se puede correr antes de las {umbral} -- la jornada todavía "
    "está en curso."
)


@router.get("", response_model=list[CorridaBatchOut])
def listar_corridas_batch(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso(CODIGO_PERMISO_BATCH)),
) -> list[dict]:
    """Panel de estado de corridas (frontend). get_caller_client, no service_role -- es lectura
    humana; la RLS de tiempo.corrida_batch (armada por db) sólo exige fn_caller_activo(), sin
    permiso específico, pero se gatea igual acá por consistencia con el resto de los routers."""
    return (
        db.postgrest.schema("tiempo")
        .table("corrida_batch")
        .select("*")
        .order("fecha", desc=True)
        .execute()
        .data
    )


@router.post("/de-confianza", response_model=CorridaBatchOut)
def disparar_batch_de_confianza(
    datos: EjecutarBatchRequest = EjecutarBatchRequest(),
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso(CODIGO_PERMISO_BATCH)),
) -> dict:
    """SCJ-PRO-14 Z1: botón manual, misma invocación que el job programado (devops,
    APScheduler) -- ejecutar_batch_de_confianza es idempotente por persona, repetir la corrida
    del mismo día es seguro."""
    fecha_efectiva = datos.fecha or date.today()
    return ejecutar_batch_de_confianza(fecha_efectiva, db_servicio)


@router.post("/cierre-dia", response_model=CorridaBatchOut)
def disparar_cierre_dia(
    datos: EjecutarBatchRequest = EjecutarBatchRequest(),
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso(CODIGO_PERMISO_BATCH)),
) -> dict:
    """SCJ-PRO-12 Z1: botón manual, misma invocación que el job programado -- ejecutar_cierre_dia
    es idempotente por persona (tiempo.dia ya resuelto se salta), repetir la corrida del mismo
    día es seguro.

    Bloqueo horario (hallazgo real, este corte): sin él, dispararlo sobre HOY a media mañana
    procesa marcas parciales y le crea falta/día bloqueado a gente que aún no terminó su turno.
    Una fecha PASADA siempre se permite (la jornada de ese día ya terminó, sin importar la hora
    actual); una fecha FUTURA nunca ("todavía no ocurre"); HOY sólo después del umbral real
    (`app/hora_cierre_dia.py`, hora_corte_dia + hora_corrida_cierre_dia -- nunca un "03:00"
    hardcodeado en el mensaje, misma lección que ventana_banco_meses)."""
    hoy = date.today()
    fecha_efectiva = datos.fecha or hoy
    if fecha_efectiva > hoy:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_CIERRE_DIA_FUTURO)
    if fecha_efectiva == hoy:
        umbral = resolver_umbral_cierre_dia(db_servicio, hoy.isoformat())
        if datetime.now().time() < umbral:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                MENSAJE_CIERRE_DIA_ANTES_DEL_UMBRAL.format(umbral=umbral.strftime("%H:%M")),
            )
    return ejecutar_cierre_dia(fecha_efectiva, db_servicio)


@router.post("/corte-quincenal", response_model=CorridaBatchOut)
def disparar_corte_quincenal(
    datos: EjecutarBatchRequest = EjecutarBatchRequest(),
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso(CODIGO_PERMISO_BATCH)),
) -> dict:
    """SCJ-PRO-13 Z1: botón manual, misma invocación que el job programado -- ejecutar_corte_
    quincenal es idempotente por persona (cualquier tramo del periodo ya clasificado se salta),
    repetir la corrida es seguro. `fecha` (día 1 o 16, o cualquier otra si es un reproceso
    manual) determina el periodo -- ver _rango_periodo en app/batches/corte_quincenal.py."""
    fecha_efectiva = datos.fecha or date.today()
    return ejecutar_corte_quincenal(fecha_efectiva, db_servicio)
