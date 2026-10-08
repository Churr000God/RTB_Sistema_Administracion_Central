"""Texto de consentimiento biométrico versionado (CONTRATO_API_TERMINALES_PAQUETE_2.md §3, SCJ-DEC-12 / 88_).

Lectura con el cliente del caller (policy terminal_consentimiento_select_lectura); publicar con el RPC
`fn_terminal_consentimiento_publicar`, que valida persona activa + terminal_config_edicion DENTRO. Nunca service_role."""

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Response, status
from postgrest.exceptions import APIError
from supabase import Client

from app.altas_terminal import resolver_nombres_persona
from app.consentimiento_terminal import (
    leer_vigente,
    manejar_error_con_consentimiento,
)
from app.deps import get_caller_client
from app.permisos import requiere_permiso
from app.schemas.terminales import (
    ConsentimientoOut,
    ConsentimientoVersionOut,
    ImpactoOut,
    PublicacionOut,
    PublicarConsentimiento,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/terminales/configuracion/consentimiento", tags=["terminales"])

_PERMISO_VER = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion", "terminal_config_edicion")
_PERMISO_PUBLICAR = requiere_permiso("terminal_config_edicion")
# /impacto cuenta altas con la RLS del caller: con SÓLO terminal_config_edicion vería 0 y publicaría un cambio material
# a ciegas. Decisión del usuario: el módulo no se ve con config sola, así que /impacto exige ver las altas.
_PERMISO_IMPACTO = requiere_permiso("terminal_usuario_lectura", "terminal_usuario_edicion")

MENSAJE_RESPUESTA_INESPERADA = "El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas."
MENSAJE_VERSION_NO_EXISTE = "La versión del texto no existe."
MENSAJE_RECARGA = "Otro cambio ocurrió al mismo tiempo; recarga."
COLUMNAS_SIN_TEXTO = "id, version, texto_sha256, provisional, cambio_material, nota, creado_por, creado_en"

COLUMNAS = "id, version, texto, texto_sha256, provisional, cambio_material, nota, creado_por, creado_en"
LIMITE_HISTORIAL = 200
ESTADOS_EN_PROCESO = ("pendiente_alta", "esperando_huella")


def _forma(fila: dict, vigente_hasta, nombres: dict[str, str], con_texto: bool = False) -> dict:
    autor = fila.get("creado_por")
    return {
        "id": fila["id"],
        "version": fila["version"],
        "texto": fila.get("texto") if con_texto else None,
        "texto_sha256": fila["texto_sha256"],
        "provisional": fila["provisional"],
        "cambio_material": fila["cambio_material"],
        "motivo_cambio": fila.get("nota"),
        "vigente_desde": fila["creado_en"],
        "vigente_hasta": vigente_hasta,
        "publicado_por_nombre": nombres.get(autor) if autor else None,
        "es_semilla": autor is None and bool(fila["provisional"]),
    }


@router.get("", response_model=ConsentimientoOut)
def leer_consentimiento(db: Client = Depends(get_caller_client), _permiso: None = Depends(_PERMISO_VER)) -> dict:
    """Vigente (mayor `version`) + historial completo (versión desc, incluye la vigente). `vigente_hasta` de
    cada versión = `creado_en` de la siguiente, porque la tabla no guarda rango. El TEXTO completo viaja sólo en la
    vigente; el de cada versión anterior se pide bajo demanda en GET …/{version} (el historial completo pesaría
    cientos de KB)."""
    tabla = db.postgrest.schema("tiempo").table("terminal_consentimiento")
    filas = tabla.select(COLUMNAS_SIN_TEXTO).order("version", desc=True).limit(LIMITE_HISTORIAL).execute().data
    if not filas:
        # 88_ siembra la v1; sin filas la migración no corrió (o la RLS no deja ver): no se inventa nada.
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Todavía no hay texto de consentimiento.")
    nombres = resolver_nombres_persona(db, [f["creado_por"] for f in filas if f.get("creado_por")])
    historial = [
        _forma(fila, filas[i - 1]["creado_en"] if i > 0 else None, nombres) for i, fila in enumerate(filas)
    ]
    vigente = leer_vigente(db)
    if vigente is None or vigente["id"] != filas[0]["id"]:
        raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_RECARGA)  # publicaron entre las dos lecturas
    historial[0]["texto"] = vigente["texto"]  # sólo la vigente lleva el texto
    return {"vigente": historial[0], "historial": historial}


def _contar(db: Client, estado: str) -> int:
    resultado = (
        db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select("id", count="exact", head=True)
        .eq("estado", estado)
        .execute()
    )
    return resultado.count or 0


def pendientes_actuales(db: Client) -> list[int]:
    """Ids con reconsentimiento pendiente: definición ÚNICA de la base (fn_terminal_reconsentimiento_pendiente_ids)."""
    data = db.postgrest.schema("tiempo").rpc("fn_terminal_reconsentimiento_pendiente_ids", {}).execute().data
    return [int(x) for x in (data or [])]


@router.get("/impacto", response_model=ImpactoOut)
def impacto_de_publicar(
    cambio_material: bool = Query(False),
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_IMPACTO),
) -> dict:
    """Cifra del panel «Publicar» ANTES de publicar. Si la vigente es provisional, publicar una definitiva
    FUERZA el cambio material (el cliente no puede desmarcarlo)."""
    vigente = leer_vigente(db)
    forzado = bool(vigente and vigente["provisional"])
    efectivo = bool(cambio_material) or forzado
    en_proceso = sum(_contar(db, e) for e in ESTADOS_EN_PROCESO)
    activas = _contar(db, "activo")
    return {
        "cambio_material_efectivo": efectivo,
        "forzado": forzado,
        "altas_que_quedarian_pendientes": (en_proceso + activas) if efectivo else 0,
        "en_proceso": en_proceso,
        "activas": activas,
        "pendientes_actuales": len(pendientes_actuales(db)),
    }


@router.post("", response_model=PublicacionOut, status_code=status.HTTP_201_CREATED)
def publicar_consentimiento(
    datos: PublicarConsentimiento,
    respuesta: Response,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_PUBLICAR),
) -> dict:
    """RPC con el cliente del caller (el gate de persona activa + terminal_config_edicion está DENTRO). La
    protección contra publicación concurrente la da `p_base_version` (SCJ16 / version_base_desactualizada)."""
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_terminal_consentimiento_publicar",
                {
                    "p_texto": datos.texto,
                    "p_cambio_material": datos.cambio_material,
                    "p_nota": datos.motivo_cambio,
                    "p_base_version": datos.base_version,
                },
            )
            .execute()
            .data
        )
    except APIError as error:
        manejar_error_con_consentimiento(error, db)
    if not isinstance(resultado, dict) or resultado.get("resultado") not in ("publicada", "sin_cambio"):
        logger.error("fn_terminal_consentimiento_publicar devolvió una forma inesperada")
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MENSAJE_RESPUESTA_INESPERADA)
    if resultado["resultado"] == "sin_cambio":
        respuesta.status_code = status.HTTP_200_OK
        return {"resultado": "sin_cambio", "version": resultado["version"], "id": resultado.get("id")}
    return {
        "resultado": "publicada",
        "id": resultado["id"],
        "version": resultado["version"],
        "cambio_material": resultado["cambio_material"],
        # Forzado = el servidor lo prendió aunque el cliente no lo pidió (la anterior era provisional).
        "cambio_material_forzado": bool(resultado["cambio_material"]) and not datos.cambio_material,
        "pendientes": resultado.get("pendientes"),
    }


@router.get("/{version}", response_model=ConsentimientoVersionOut)
def leer_version(
    version: Annotated[int, Path(ge=1, le=2147483647)],
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(_PERMISO_VER),
) -> dict:
    """Una versión del texto, COMPLETA (el historial sólo trae el texto de la vigente)."""
    tabla = db.postgrest.schema("tiempo").table("terminal_consentimiento")
    filas = tabla.select(COLUMNAS).eq("version", version).limit(1).execute().data
    if not filas:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_VERSION_NO_EXISTE)
    siguiente = (
        db.postgrest.schema("tiempo")
        .table("terminal_consentimiento")
        .select("creado_en")
        .gt("version", version)
        .order("version")
        .limit(1)
        .execute()
        .data
    )
    nombres = resolver_nombres_persona(db, [filas[0]["creado_por"]] if filas[0].get("creado_por") else [])
    return _forma(filas[0], siguiente[0]["creado_en"] if siguiente else None, nombres, con_texto=True)
