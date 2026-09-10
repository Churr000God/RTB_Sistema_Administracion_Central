"""API de tiempo.correccion (SCJ-PRO-10). Corrige el valor de una marca sin modificarla nunca --
inserta una fila nueva que apunta a la marca original (SCJ-DEC-03).

Sólo se corrige resolviendo una excepcion existente -- nunca libre. El trigger BEFORE INSERT
(fn_correccion_valida, db/ddl/02_tiempo.sql) es la integridad real e insaltable: exige excepcion
previa y bloquea cualquier valor_corregido que reordene las marcas de la persona. Este router
pre-chequea lo mismo para dar mensajes legibles (422 en vez del texto crudo de Postgres) y, sobre
todo, para decidir DINÁMICAMENTE qué permiso exigir -- no se puede declarar con un solo
Depends(requiere_permiso(...)) fijo porque el permiso depende del estado de la excepcion de la
marca (SCJ-PRO-10 §II.3). AND, no OR (confirmado por db: así quedó la RLS real de INSERT en
tiempo.correccion, 48/49_*.sql):
- correccion_edicion SIEMPRE (los 3 puestos).
- ADEMÁS excepcion_reapertura si TODAS las excepciones de la marca ya están 'resuelto'
  (reabrir/editar una ya cerrada) -- no heredable, exclusivo de Gerente o Encargado de TI.

Gate: get_caller_client (RLS) -- nunca service_role, la RLS que arma db es la autorización real.
tiempo.parametro/tiempo.dia_festivo se leen con service_role: son configuración global de
sistema, no datos del caller (mismo criterio que app/scheduler.py leyendo
hora_corrida_cierre_dia)."""

from datetime import date, datetime

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.dias_habiles import _dias_habiles_limite, _dias_habiles_transcurridos, _festivos_entre
from app.permisos import resolver_persona_id, tiene_permiso
from app.schemas.correcciones import CorreccionCreate, CorreccionOut

router = APIRouter(prefix="/api/correcciones", tags=["correcciones"])

MENSAJE_MARCA_NO_ENCONTRADA = "La marca no existe."
MENSAJE_MARCA_SIN_EXCEPCION = (
    "Esta marca no tiene ninguna excepción asociada -- no se puede corregir sin pasar antes "
    "por la cola de excepciones."
)
MENSAJE_VENTANA_VENCIDA = (
    "La ventana de corrección de {dias} día(s) hábil(es) ya venció para esta marca."
)
MENSAJE_ORDEN_CRONOLOGICO = (
    "La hora corregida debe quedar entre la marca anterior y la siguiente de la persona -- no "
    "se puede reordenar, sólo ajustar la hora."
)
MENSAJE_SIN_PERMISO_REAPERTURA = (
    "Esta excepción ya está resuelta -- reabrirla exige el permiso excepcion_reapertura "
    "(exclusivo de TI)."
)
MENSAJE_SIN_PERMISO_CORRECCION = (
    "No tenés el permiso necesario (correccion_edicion) para esta acción."
)


def _buscar_marca(db: Client, marca_id: int) -> dict | None:
    filas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, momento_dispositivo")
        .eq("id", marca_id)
        .execute()
        .data
    )
    return filas[0] if filas else None


def _estados_excepcion(db: Client, marca_id: int) -> list[str]:
    filas = (
        db.postgrest.schema("tiempo")
        .table("excepcion")
        .select("estado")
        .eq("marca_id", marca_id)
        .execute()
        .data
    )
    return [fila["estado"] for fila in filas]


def _validar_ventana(fecha_marca: date) -> None:
    """SCJ-PRO-10 D1-D2: sólo aplicación -- política de proceso, no integridad estructural."""
    limite = _dias_habiles_limite()
    hoy = date.today()
    festivos = _festivos_entre(fecha_marca, hoy)
    transcurridos = _dias_habiles_transcurridos(fecha_marca, hoy, festivos)
    if transcurridos > limite:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_VENTANA_VENCIDA.format(dias=limite)
        )


@router.post("", status_code=201, response_model=CorreccionOut)
def corregir_marca(
    datos: CorreccionCreate,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
) -> dict:
    """SCJ-PRO-10 A1-K2. El gate no es un Depends fijo -- ver docstring del módulo."""
    marca = _buscar_marca(db, datos.marca_id)
    if marca is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_MARCA_NO_ENCONTRADA)

    estados = _estados_excepcion(db, datos.marca_id)
    if not estados:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MARCA_SIN_EXCEPCION)

    hay_pendiente = "pendiente" in estados
    persona_id = resolver_persona_id(db, caller)

    # correccion_edicion es SIEMPRE necesario; excepcion_reapertura se exige ADEMÁS cuando se
    # reabre una excepción ya resuelta -- AND, no OR (confirmado por db: así quedó la RLS real de
    # INSERT en tiempo.correccion, 48/49_*.sql).
    if not tiene_permiso(db, persona_id, "correccion_edicion"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO_CORRECCION)
    if not hay_pendiente and not tiene_permiso(db, persona_id, "excepcion_reapertura"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO_REAPERTURA)

    fecha_marca = datetime.fromisoformat(marca["momento_dispositivo"]).date()
    _validar_ventana(fecha_marca)

    try:
        fila = (
            db.postgrest.schema("tiempo")
            .table("correccion")
            .insert(
                {
                    "marca_id": datos.marca_id,
                    "valor_corregido": datos.valor_corregido.isoformat(),
                    "motivo": datos.motivo,
                    "autor_id": persona_id,
                }
            )
            .execute()
            .data[0]
        )
    except APIError as error:
        mensaje_crudo = error.message or ""
        if "rompería el orden cronológico" in mensaje_crudo:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ORDEN_CRONOLOGICO
            ) from error
        if "no tiene ninguna excepcion asociada" in mensaje_crudo:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_MARCA_SIN_EXCEPCION
            ) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, mensaje_crudo) from error

    return fila
