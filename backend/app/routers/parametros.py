"""API de tiempo.parametro (módulo Parámetros de Tiempo, tercera pantalla). Vigencias
versionadas, mismo patrón de historial que tope_legal.py, pero sin flag de confirmación --
acá siempre hay una vigencia activa por clave y siempre se quiere cerrar, así que un 409 en
cada guardado sería puro ruido (a diferencia de tope_legal, donde "no cerrar todavía" es una
opción válida).

get_service_client para TODA lectura/escritura -- tiempo.parametro tiene RLS deny-all
(41_tiempo_rls_deny_default.sql) y desde la migración 60 además REVOKE UPDATE/DELETE a
anon/authenticated (la tabla es histórica). get_caller_client sólo aparece indirectamente, vía
requiere_permiso (que lo usa internamente) y vía get_caller_identity explícito en el PUT para
tener el auth_user_id que se guarda en registrado_por.

El catálogo de claves (backend/app/catalogo_parametros.py) es cerrado y vive en código -- este
router no crea ni borra claves, sólo cambia el valor de una que ya existe. Que la clave EXISTA y
tenga vigencia activa lo valida el RPC tiempo.fn_parametro_actualizar_valor, que revienta con
ERRCODE 'SCJ02' si no -- se mapea a 404, calcado de tope_legal.py."""

from fastapi import APIRouter, Depends, HTTPException, status
from postgrest.exceptions import APIError
from supabase import Client

from app.catalogo_parametros import CATALOGO
from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.permisos import requiere_permiso
from app.schemas.parametros import (
    ParametroActualizar,
    ParametroHistorialItem,
    ParametroVigenteOut,
    validar_formato_valor,
)

router = APIRouter(prefix="/api/parametros", tags=["parametros"])

CODIGO_CLAVE_SIN_VIGENCIA_ACTIVA = "SCJ02"

MENSAJE_CLAVE_SIN_VIGENCIA_ACTIVA = "No existe un parámetro activo con esa clave."


def _mezclar_con_catalogo(fila: dict) -> dict:
    entrada = CATALOGO[fila["clave"]]
    return {
        **fila,
        "etiqueta": entrada.etiqueta,
        "descripcion": entrada.descripcion,
        "tipo": entrada.tipo,
        "unidad": entrada.unidad,
        "impacta_logica": entrada.impacta_logica,
        "nota": entrada.nota,
    }


@router.get("", response_model=list[ParametroVigenteOut])
def listar_parametros_vigentes(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("parametro_lectura", "parametro_edicion")),
) -> list[dict]:
    filas = (
        db_servicio.postgrest.schema("tiempo")
        .table("parametro")
        .select("*")
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    return [_mezclar_con_catalogo(fila) for fila in filas]


@router.get("/historial", response_model=list[ParametroHistorialItem])
def listar_historial_parametros(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("parametro_lectura", "parametro_edicion")),
) -> list[dict]:
    """Sin query params -- 8 claves × pocas vigencias, el filtrado (búsqueda/rango/orden) lo hace
    el frontend client-side, mismo criterio de dias_festivos.py."""
    tabla = db_servicio.postgrest.schema("tiempo").table
    historial = (
        tabla("parametro").select("*").order("vigente_desde", desc=True).execute().data
    )

    for fila in historial:
        fila["etiqueta"] = CATALOGO[fila["clave"]].etiqueta

    autores_ids = {fila["registrado_por"] for fila in historial if fila.get("registrado_por")}
    if autores_ids:
        filas_usuario = (
            db_servicio.postgrest.schema("personas")
            .table("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", list(autores_ids))
            .execute()
            .data
        )
        nombre_por_id = {fila["auth_user_id"]: fila["nombre_usuario"] for fila in filas_usuario}
        for fila in historial:
            fila["nombre_registrado_por"] = nombre_por_id.get(fila.get("registrado_por"))
    else:
        for fila in historial:
            fila["nombre_registrado_por"] = None

    return historial


@router.put("/{clave}", response_model=ParametroVigenteOut)
def actualizar_valor_parametro(
    clave: str,
    datos: ParametroActualizar,
    db_servicio: Client = Depends(get_service_client),
    caller: CallerIdentity = Depends(get_caller_identity),
    _permiso: None = Depends(requiere_permiso("parametro_edicion")),
) -> dict:
    """vigente_desde siempre hoy, puesto por el RPC -- sin campo de fecha en el formulario. Dos
    cambios de la misma clave el mismo día son la misma vigencia corregida (UPDATE), no una fila
    nueva -- lo resuelve el RPC, no este endpoint."""
    try:
        valor = validar_formato_valor(clave, datos.valor)
    except ValueError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(error)) from error

    try:
        resultado = (
            db_servicio.postgrest.schema("tiempo")
            .rpc(
                "fn_parametro_actualizar_valor",
                {
                    "p_clave": clave,
                    "p_valor": valor,
                    "p_registrado_por": caller.auth_user_id,
                },
            )
            .execute()
        )
    except APIError as error:
        if error.code == CODIGO_CLAVE_SIN_VIGENCIA_ACTIVA:
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, MENSAJE_CLAVE_SIN_VIGENCIA_ACTIVA
            ) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    return _mezclar_con_catalogo(resultado.data)
