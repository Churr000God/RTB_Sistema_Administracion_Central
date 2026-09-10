"""API de personas.permiso (catálogo) y personas.puesto_permiso (SCJ-PRO-05: otorgar/revocar).

Gate de permisos: get_caller_client (RLS) + requiere_permiso(...) (app/permisos.py) -- este
último exige que el caller tenga, en alguno de sus puestos vigentes (directo o heredado), al
menos uno de los códigos de permiso indicados. GET "" / /vigentes / /otorgados aceptan
lectura O edición; POST /otorgar y /revocar exigen puesto_permiso_edicion (SCJ-PRO-05 §II.1,
literal). El resto de la lógica de negocio del proceso (auto-otorgamiento directo o por
herencia via el organigrama, protección de "última fila" de puesto_permiso_edicion) es
independiente del gate y ya estaba implementada."""

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity
from app.permisos import (
    descendientes_incluido_si_mismo,
    mapa_hijos_por_puesto,
    requiere_permiso,
    resolver_persona_id,
    resolver_puestos_vigentes,
)
from app.schemas.permisos import (
    BitacoraPuestoPermisoOut,
    PermisoOut,
    PuestoPermisoConDetalle,
    PuestoPermisoOtorgar,
    PuestoPermisoOut,
    PuestoPermisoRevocar,
)

router = APIRouter(prefix="/api/permisos", tags=["permisos"])

CODIGO_PUESTO_PERMISO_EDICION = "puesto_permiso_edicion"

MENSAJE_PUESTO_INVALIDO = "El puesto no existe o está inactivo."
MENSAJE_PERMISO_INVALIDO = "El permiso no existe o está inactivo."
MENSAJE_AUTOOTORGAMIENTO_DIRECTO = "No podés otorgarte este permiso a vos mismo."
MENSAJE_AUTOOTORGAMIENTO_POR_HERENCIA = (
    "No podés otorgar este permiso: terminarías heredándolo por el rodeo del organigrama."
)
MENSAJE_PUESTO_PERMISO_NO_ENCONTRADO = "puesto_permiso no encontrado."
MENSAJE_ULTIMA_FILA_EDICION = (
    "No se puede revocar: dejaría al sistema sin nadie que pueda repartir permisos."
)
MENSAJE_ADMINISTRADOR_SIN_ACCESO = (
    "No se puede revocar: dejaría al puesto administrador sin acceso."
)


PERMISOS_LECTURA_O_EDICION = (
    "permiso_lectura",
    "permiso_edicion",
    "puesto_permiso_lectura",
    "puesto_permiso_edicion",
)


@router.get("", response_model=list[PermisoOut])
def listar_permisos(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso(*PERMISOS_LECTURA_O_EDICION)),
) -> list[dict]:
    return db.postgrest.schema("personas").table("permiso").select("*").order("codigo").execute().data


@router.get("/vigentes", response_model=list[PuestoPermisoConDetalle])
def listar_puesto_permiso_vigentes(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso(*PERMISOS_LECTURA_O_EDICION)),
) -> list[dict]:
    """Estado ACTUAL de puesto_permiso (con el flag activo) -- a diferencia de /otorgados, que
    es el histórico de eventos. Devuelve todas las filas, activas e inactivas; el filtro de
    "sólo activas" lo hace el cliente."""
    filas = (
        db.postgrest.schema("personas")
        .table("puesto_permiso")
        .select("*, puesto:puesto_id(nombre_puesto)")
        .order("codigo")
        .execute()
        .data
    )
    for fila in filas:
        fila["nombre_puesto"] = fila.pop("puesto")["nombre_puesto"]
    return filas


@router.get("/otorgados", response_model=list[BitacoraPuestoPermisoOut])
def listar_otorgados(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso(*PERMISOS_LECTURA_O_EDICION)),
) -> list[dict]:
    """Histórico completo de otorgamientos/revocaciones -- a diferencia de asignacion (donde
    cada fila YA es un evento con vigente_desde/vigente_hasta), acá el registro de eventos vive
    aparte en bitacora_movimiento_puesto_permiso; puesto_permiso sólo tiene el estado derivado
    (activo/inactivo), sin historial. Devuelve todas las filas, otorgado y revocado."""
    tabla = db.postgrest.schema("personas").table
    filas = (
        tabla("bitacora_movimiento_puesto_permiso")
        .select("*, puesto:puesto_id(nombre_puesto)")
        .order("fecha_efectiva", desc=True)
        .execute()
        .data
    )
    for fila in filas:
        fila["nombre_puesto"] = fila.pop("puesto")["nombre_puesto"]

    autores_ids = {fila["registrado_por"] for fila in filas if fila.get("registrado_por")}
    if autores_ids:
        filas_usuario = (
            tabla("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", list(autores_ids))
            .execute()
            .data
        )
        nombre_por_id = {fu["auth_user_id"]: fu["nombre_usuario"] for fu in filas_usuario}
        for fila in filas:
            fila["registrado_por_nombre"] = nombre_por_id.get(fila.get("registrado_por"))

    return filas


@router.post("/otorgar", status_code=201, response_model=PuestoPermisoOut)
def otorgar_permiso(
    datos: PuestoPermisoOtorgar,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(requiere_permiso(CODIGO_PUESTO_PERMISO_EDICION)),
) -> dict:
    """SCJ-PRO-05 G0-G8."""
    puesto_destino = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("id, activo")
        .eq("id", datos.puesto_id)
        .execute()
        .data
    )
    if not puesto_destino or not puesto_destino[0]["activo"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PUESTO_INVALIDO)

    permiso = (
        db.postgrest.schema("personas")
        .table("permiso")
        .select("codigo, heredable, activo")
        .eq("codigo", datos.codigo)
        .execute()
        .data
    )
    if not permiso or not permiso[0]["activo"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_PERMISO_INVALIDO)

    persona_id_caller = resolver_persona_id(db, caller)
    puestos_vigentes_caller = resolver_puestos_vigentes(db, persona_id_caller)

    if permiso[0]["heredable"]:
        hijos = mapa_hijos_por_puesto(db)
        for puesto_caller in puestos_vigentes_caller:
            if datos.puesto_id in descendientes_incluido_si_mismo(hijos, puesto_caller):
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_AUTOOTORGAMIENTO_POR_HERENCIA
                )
    else:
        if datos.puesto_id in puestos_vigentes_caller:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_AUTOOTORGAMIENTO_DIRECTO
            )

    db.postgrest.schema("personas").table("bitacora_movimiento_puesto_permiso").insert(
        {
            "puesto_id": datos.puesto_id,
            "codigo": datos.codigo,
            "tipo_movimiento": "otorgado",
            "registrado_por": caller.auth_user_id,
        }
    ).execute()

    return (
        db.postgrest.schema("personas")
        .table("puesto_permiso")
        .select("*")
        .eq("puesto_id", datos.puesto_id)
        .eq("codigo", datos.codigo)
        .execute()
        .data[0]
    )


@router.post("/revocar", response_model=PuestoPermisoOut)
def revocar_permiso(
    datos: PuestoPermisoRevocar,
    db: Client = Depends(get_caller_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(requiere_permiso(CODIGO_PUESTO_PERMISO_EDICION)),
) -> dict:
    """SCJ-PRO-05 R0-R5."""
    fila = (
        db.postgrest.schema("personas")
        .table("puesto_permiso")
        .select("id, puesto_id, codigo")
        .eq("id", datos.puesto_permiso_id)
        .execute()
        .data
    )
    if not fila:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PUESTO_PERMISO_NO_ENCONTRADO)
    puesto_id, codigo = fila[0]["puesto_id"], fila[0]["codigo"]

    puesto = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("es_administrador_generico")
        .eq("id", puesto_id)
        .execute()
        .data
    )
    if puesto and puesto[0]["es_administrador_generico"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ADMINISTRADOR_SIN_ACCESO)

    if codigo == CODIGO_PUESTO_PERMISO_EDICION:
        activas = (
            db.postgrest.schema("personas")
            .table("puesto_permiso")
            .select("id")
            .eq("codigo", CODIGO_PUESTO_PERMISO_EDICION)
            .eq("activo", True)
            .execute()
            .data
        )
        if len(activas) <= 1:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_ULTIMA_FILA_EDICION)

    db.postgrest.schema("personas").table("bitacora_movimiento_puesto_permiso").insert(
        {
            "puesto_id": puesto_id,
            "codigo": codigo,
            "tipo_movimiento": "revocado",
            "registrado_por": caller.auth_user_id,
        }
    ).execute()

    return (
        db.postgrest.schema("personas")
        .table("puesto_permiso")
        .select("*")
        .eq("id", datos.puesto_permiso_id)
        .execute()
        .data[0]
    )
