"""API de personas.persona (SCJ-PRO-01 alta persona+expediente).

Gate de permisos: GET (listado, ficha) sin cambio -- no existe código de lectura para este
módulo, sigue el gate débil de sólo get_caller_client (RLS) a propósito. POST (alta) exige
además requiere_permiso("alta_personas_usuarios") (app/permisos.py)."""

import logging
from datetime import date
from typing import NoReturn

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.errores import UNIQUE_VIOLATION, manejar_violacion_unicidad, rechazo_generico
from app.permisos import requiere_permiso
from app.schemas.personas import (
    PersonaActualizar,
    PersonaConExpediente,
    PersonaCreate,
    PersonaOut,
)

router = APIRouter(prefix="/api/personas", tags=["personas"])
logger = logging.getLogger("app.personas")

CODIGO_PERSONA_NO_ENCONTRADA = "SCJ10"
MENSAJE_PERSONA_NO_ENCONTRADA = "Persona no encontrada."
MENSAJE_DUPLICADO = "CURP, RFC, NSS o número de documento ya está en uso por otra persona."
MENSAJE_EXPEDIENTE_INCOMPLETO = (
    "Esta persona no tiene expediente todavía -- mandá tipo_contrato y documento_ref juntos."
)
CODIGO_VIOLACION_CHECK = "23514"
# Mensajes del ALTA por campo (SIN revelar nada de la persona que ya tiene ese dato). El texto de la base nunca va al cliente: solo se lee el NOMBRE de la restricción
# (o la columna) para elegir uno de estos mensajes fijos.
MENSAJE_CURP_DUPLICADA = "Ya existe una persona registrada con esa CURP."
MENSAJE_RFC_DUPLICADO = "Ya existe una persona registrada con ese RFC."
MENSAJE_NSS_DUPLICADO = "Ya existe una persona registrada con ese NSS."
MENSAJE_DOCUMENTO_REF_DUPLICADO = "Ese folio de expediente ya está en uso por otra persona."
MENSAJE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
MENSAJE_SIN_PERMISO = "No tienes permiso para dar de alta personas."
CODIGO_PERMISO_DENEGADO = "42501"
_UNICIDAD_POR_RESTRICCION = (
    ("uq_persona_curp", "(curp)", MENSAJE_CURP_DUPLICADA),
    ("uq_persona_rfc", "(rfc)", MENSAJE_RFC_DUPLICADO),
    ("uq_persona_nss", "(nss)", MENSAJE_NSS_DUPLICADO),
    ("uq_expediente_documento_ref", "(documento_ref)", MENSAJE_DOCUMENTO_REF_DUPLICADO),
)
MENSAJE_DOCUMENTO_REF_FORMATO = (
    "El folio del expediente debe tener el formato RTB-RH-EIT-<año>-<número> "
    "(ej. RTB-RH-EIT-2026-06)."
)


def _resolver_personas_con_jornada_vigente(db: Client, persona_ids: list[str]) -> set[str]:
    """Cruza a tiempo.jornada_asignada (la única dirección que puede ir sin romper la frontera --
    SCJ-FRO-01 sólo prohíbe que un atributo de identidad cruce de personas a tiempo, no una
    lectura de conveniencia en sentido contrario). Un solo IN por lote en vez de una consulta por
    persona -- mismo criterio que el resto de los resolvers de nombre cruzado del proyecto.

    Bug real encontrado 2026-09-11 (misma forma que jornada_asignada.py::jornada_vigente_de_
    persona): filtrar por `vigente_hasta IS NULL` cuenta como "con jornada vigente" a alguien
    cuya única jornada es una futura precargada que todavía no empieza. Mismo criterio de
    resolución "vigente hoy" que ya usan corte_quincenal.py/alertas_horario.py."""
    if not persona_ids:
        return set()
    hoy_iso = date.today().isoformat()
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("persona_id")
        .in_("persona_id", persona_ids)
        .lte("vigente_desde", hoy_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{hoy_iso}")
        .execute()
        .data
    )
    return {fila["persona_id"] for fila in filas}


def _mensaje_de_unicidad(error: APIError) -> str:
    """El mensaje fijo por campo de una violación 23505, leyendo SOLO el nombre de la restricción o la columna (nunca se reenvía el texto de la base)."""
    mensaje_base, detalle = (error.message or "").lower(), (error.details or "").lower()
    for restriccion, _columna, mensaje in _UNICIDAD_POR_RESTRICCION:        # primero el NOMBRE de la restricción (siempre viene en el mensaje de Postgres)
        if restriccion in mensaje_base:
            return mensaje
    for _restriccion, columna, mensaje in _UNICIDAD_POR_RESTRICCION:        # y, si no, la columna del «Key (col)=(…)»
        if f"key {columna}=" in detalle:
            return mensaje
    return MENSAJE_DUPLICADO


def _traducir_error_alta(error: APIError) -> NoReturn:
    """Espeja el mapeo del PATCH para el alta: 23505 → 409 con el mensaje del campo; el CHECK del folio → 422 con el formato real (71_*.sql: `RTB-RH-EIT-AAAA-N`); cualquier otro
    CHECK → 422 genérico fijo (el texto real al log); 42501 (la RLS del RPC INVOKER) → 403. Nada de la base llega al cliente. Lo que no es de estas familias se relanza al manejador
    global (500 sin texto)."""
    if error.code == UNIQUE_VIOLATION:
        raise HTTPException(status.HTTP_409_CONFLICT, _mensaje_de_unicidad(error)) from None
    if error.code == CODIGO_VIOLACION_CHECK:
        if "documento_ref_formato" in (error.message or ""):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DOCUMENTO_REF_FORMATO) from None
        raise rechazo_generico(error, "alta de persona") from None
    if error.code == CODIGO_PERMISO_DENEGADO:
        # requiere_permiso ya filtró al usuario sin permiso: un 42501 que llega aquí es, probablemente, una regresión de privilegios (EXECUTE revocado, policy rota). Se registra el
        # SQLSTATE y la ruta -NUNCA el mensaje de la base-; al cliente le llega lo mismo de siempre.
        logger.warning("POST /api/personas: la base respondió %s al RPC fn_persona_crear (revisar EXECUTE/policies si el usuario sí tiene alta_personas_usuarios)", error.code)
        raise HTTPException(status.HTTP_403_FORBIDDEN, MENSAJE_SIN_PERMISO) from None
    raise error


def _crear_persona_con_expediente(db: Client, datos: PersonaCreate) -> dict:
    """Persona + expediente en UNA transacción: `personas.fn_persona_crear` (db/ddl/107_*.sql, SECURITY INVOKER: corre con los privilegios y la RLS del caller). Si algo falla no queda
    nada (ni persona ni expediente). Devuelve la fila COMPLETA de personas.persona como un solo objeto; el router la proyecta a PersonaOut. Argumentos por NOMBRE."""
    try:
        resultado = (
            db.postgrest.schema("personas")
            .rpc(
                "fn_persona_crear",
                {
                    "p_primer_nombre": datos.primer_nombre,
                    "p_apellido_paterno": datos.apellido_paterno,
                    "p_curp": datos.curp,
                    "p_rfc": datos.rfc,
                    "p_nss": datos.nss,
                    "p_fecha_nacimiento": datos.fecha_nacimiento.isoformat(),
                    "p_fecha_ingreso": datos.fecha_ingreso.isoformat(),
                    "p_tipo_contrato": datos.tipo_contrato,
                    "p_documento_ref": datos.documento_ref,
                    "p_segundo_nombre": datos.segundo_nombre,
                    "p_apellido_materno": datos.apellido_materno,
                },
            )
            .execute()
        )
    except APIError as error:
        _traducir_error_alta(error)
    persona = resultado.data
    if isinstance(persona, list):          # tolerancia de versiones de PostgREST: un RPC que devuelve una fila puede llegar envuelto en una lista de un elemento
        persona = persona[0] if persona else None
    if not isinstance(persona, dict) or "id" not in persona:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, MENSAJE_RESPUESTA_INESPERADA)
    return persona


@router.post("", status_code=201, response_model=PersonaOut)
def alta_persona(
    datos: PersonaCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("alta_personas_usuarios")),
) -> dict:
    """SCJ-PRO-01 paso A1: persona + expediente en una misma operación, en ese orden por la FK."""
    return _crear_persona_con_expediente(db, datos)


@router.get("", response_model=list[PersonaOut])
def listar_personas(db: Client = Depends(get_caller_client)) -> list[dict]:
    """tiene_jornada_vigente alimenta la pestaña de asignación de jornadas (SCJ-PRO-09) -- mismo
    criterio que tiene_usuario en ficha_persona: un booleano derivado, no la jornada completa."""
    personas = db.postgrest.schema("personas").table("persona").select("*").execute().data
    con_jornada_vigente = _resolver_personas_con_jornada_vigente(
        db, [persona["id"] for persona in personas]
    )
    return [
        {**persona, "tiene_jornada_vigente": persona["id"] in con_jornada_vigente}
        for persona in personas
    ]


def _construir_ficha_persona(db: Client, persona_id: str) -> dict:
    fila = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("*, expediente(tipo_contrato, documento_ref)")
        .eq("id", persona_id)
        .single()
        .execute()
        .data
    )
    # Persona insertada sin pasar por POST /api/personas (ej. datos de prueba por SQL directo)
    # puede no tener fila en expediente — el embed de PostgREST devuelve null, no {}.
    expediente = fila.pop("expediente") or {}

    tiene_usuario = bool(
        db.postgrest.schema("personas")
        .table("usuario")
        .select("auth_user_id")
        .eq("persona_id", persona_id)
        .execute()
        .data
    )

    asignaciones_vigentes = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select(
            "id, puesto:puesto_id(id, nombre_puesto, "
            "departamento:departamento_id(nombre_departamento, area:area_id(nombre_area)))"
        )
        .eq("persona_id", persona_id)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    puestos_vigentes = [
        {
            "asignacion_id": asignacion["id"],
            "puesto_id": asignacion["puesto"]["id"],
            "nombre_puesto": asignacion["puesto"]["nombre_puesto"],
            "nombre_departamento": asignacion["puesto"]["departamento"]["nombre_departamento"],
            "nombre_area": asignacion["puesto"]["departamento"]["area"]["nombre_area"],
        }
        for asignacion in asignaciones_vigentes
    ]

    tiene_jornada_vigente = persona_id in _resolver_personas_con_jornada_vigente(db, [persona_id])

    return {
        **fila,
        **expediente,
        "tiene_usuario": tiene_usuario,
        "tiene_jornada_vigente": tiene_jornada_vigente,
        "puestos_vigentes": puestos_vigentes,
    }


@router.get("/{persona_id}", response_model=PersonaConExpediente)
def ficha_persona(persona_id: str, db: Client = Depends(get_caller_client)) -> dict:
    return _construir_ficha_persona(db, persona_id)


@router.patch("/{persona_id}", response_model=PersonaConExpediente)
def actualizar_persona(
    persona_id: str,
    datos: PersonaActualizar,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("persona_edicion")),
) -> dict:
    """SCJ-PRO-01 corrección de expediente post-alta. Nunca toca estado/fecha_baja -- eso sigue
    siendo exclusivo de POST /api/personas/{id}/movimientos. get_caller_client (RLS exige
    cambio_estado_persona OR persona_edicion en personas.persona, persona_edicion a secas en
    personas.expediente, db/ddl/69_*.sql) es la autorización real; requiere_permiso sólo da un
    403 legible antes de llegar ahí."""
    campos = datos.model_dump(exclude_unset=True)
    if not campos:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, "No se envió ningún campo a actualizar."
        )

    # personas.expediente tiene tipo_contrato/documento_ref NOT NULL -- el RPC sólo intenta el
    # INSERT...ON CONFLICT si viene alguno de los dos. Con persona sin expediente todavía y sólo
    # uno de los dos en el payload, ese INSERT revienta con NOT NULL real de Postgres -- lo
    # cortamos acá con un 422 legible en vez de dejarlo caer como 500.
    trae_tipo_contrato = "tipo_contrato" in campos
    trae_documento_ref = "documento_ref" in campos
    if trae_tipo_contrato != trae_documento_ref:
        tiene_expediente = bool(
            db.postgrest.schema("personas")
            .table("expediente")
            .select("persona_id")
            .eq("persona_id", persona_id)
            .execute()
            .data
        )
        if not tiene_expediente:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_EXPEDIENTE_INCOMPLETO)

    argumentos_rpc = {f"p_{campo}": valor for campo, valor in campos.items()}
    for campo in ("fecha_nacimiento", "fecha_ingreso"):
        if campo in campos and campos[campo] is not None:
            argumentos_rpc[f"p_{campo}"] = campos[campo].isoformat()

    try:
        db.postgrest.schema("personas").rpc(
            "fn_persona_actualizar_datos",
            {"p_persona_id": persona_id, **argumentos_rpc},
        ).execute()
    except APIError as error:
        if error.code == CODIGO_PERSONA_NO_ENCONTRADA:
            raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PERSONA_NO_ENCONTRADA) from error
        if error.code == CODIGO_VIOLACION_CHECK and "documento_ref_formato" in (error.message or ""):
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_DOCUMENTO_REF_FORMATO
            ) from error
        manejar_violacion_unicidad(error, MENSAJE_DUPLICADO)

    return _construir_ficha_persona(db, persona_id)
