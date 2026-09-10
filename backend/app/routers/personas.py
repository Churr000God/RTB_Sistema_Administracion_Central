"""API de personas.persona (SCJ-PRO-01 alta persona+expediente).

Gate de permisos: GET (listado, ficha) sin cambio -- no existe código de lectura para este
módulo, sigue el gate débil de sólo get_caller_client (RLS) a propósito. POST (alta) exige
además requiere_permiso("alta_personas_usuarios") (app/permisos.py)."""

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.deps import get_caller_client
from app.errores import manejar_violacion_unicidad
from app.permisos import requiere_permiso
from app.schemas.personas import (
    PersonaActualizar,
    PersonaConExpediente,
    PersonaCreate,
    PersonaOut,
)

router = APIRouter(prefix="/api/personas", tags=["personas"])

CODIGO_PERSONA_NO_ENCONTRADA = "SCJ10"
MENSAJE_PERSONA_NO_ENCONTRADA = "Persona no encontrada."
MENSAJE_DUPLICADO = "CURP, RFC, NSS o número de documento ya está en uso por otra persona."
MENSAJE_EXPEDIENTE_INCOMPLETO = (
    "Esta persona no tiene expediente todavía -- mandá tipo_contrato y documento_ref juntos."
)


def _resolver_personas_con_jornada_vigente(db: Client, persona_ids: list[str]) -> set[str]:
    """Cruza a tiempo.jornada_asignada (la única dirección que puede ir sin romper la frontera --
    SCJ-FRO-01 sólo prohíbe que un atributo de identidad cruce de personas a tiempo, no una
    lectura de conveniencia en sentido contrario). Un solo IN por lote en vez de una consulta por
    persona -- mismo criterio que el resto de los resolvers de nombre cruzado del proyecto."""
    if not persona_ids:
        return set()
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("persona_id")
        .in_("persona_id", persona_ids)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    return {fila["persona_id"] for fila in filas}


@router.post("", status_code=201, response_model=PersonaOut)
def alta_persona(
    datos: PersonaCreate,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("alta_personas_usuarios")),
) -> dict:
    """SCJ-PRO-01 paso A1: persona + expediente en una misma operación, en ese orden por la FK."""
    persona = (
        db.postgrest.schema("personas")
        .table("persona")
        .insert(
            {
                "primer_nombre": datos.primer_nombre,
                "segundo_nombre": datos.segundo_nombre,
                "apellido_paterno": datos.apellido_paterno,
                "apellido_materno": datos.apellido_materno,
                "curp": datos.curp,
                "rfc": datos.rfc,
                "nss": datos.nss,
                "fecha_nacimiento": datos.fecha_nacimiento.isoformat(),
                "fecha_ingreso": datos.fecha_ingreso.isoformat(),
            }
        )
        .execute()
        .data[0]
    )

    db.postgrest.schema("personas").table("expediente").insert(
        {
            "persona_id": persona["id"],
            "tipo_contrato": datos.tipo_contrato,
            "documento_ref": datos.documento_ref,
        }
    ).execute()

    return persona


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
        manejar_violacion_unicidad(error, MENSAJE_DUPLICADO)

    return _construir_ficha_persona(db, persona_id)
