import weakref

from fastapi import APIRouter, Depends
from supabase import Client

from app.deps import CallerIdentity, get_caller_identity, get_service_client
from app.errores import leer_con_reintento
from app.permisos import tiene_permisos_paralelo
from app.schemas.sesion import SesionOut

router = APIRouter(prefix="/api/sesion", tags=["sesion"])

CONTEXTO = "GET /api/sesion"
_ESQUEMAS: "weakref.WeakKeyDictionary" = weakref.WeakKeyDictionary()


def _esquema_personas(db: Client):
    """UN cliente del esquema `personas` por cliente de Supabase (por petición): cada `db.postgrest.schema(...)` fabrica un cliente httpx nuevo, con su propio TCP/TLS.

    GUARDA (security): esta memoización por OBJETO Client solo es válida con el cliente de SERVICIO de la petición (`get_service_client`, uno nuevo por petición). Un cliente de CALLER
    (`get_caller_client`) lleva el JWT de la persona en sus cabeceras: cachear su esquema más allá de esa petición, o compartirlo, mezclaría identidades. Por eso la clave es el objeto
    cliente (dos clientes distintos ⇒ dos esquemas distintos) y una prueba comprueba que ambos `get_*_client` fabrican un objeto NUEVO en cada llamada: si alguien los convirtiera en
    singleton, esa prueba falla. NO copiar este patrón a otros routers sin esa guarda y sin esa prueba."""
    esquema = _ESQUEMAS.get(db)
    if esquema is None:
        esquema = db.postgrest.schema("personas")
        _ESQUEMAS[db] = esquema
    return esquema


def _leer(consulta):
    return leer_con_reintento(consulta, contexto=CONTEXTO)


def tiene_permisos(db: Client, persona_id: str, codigos) -> dict[str, bool]:
    """Los permisos de la persona con las 4 lecturas independientes en paralelo, sobre el MISMO cliente de esquema, cada una con su reintento (ver `app.permisos`)."""
    return tiene_permisos_paralelo(_esquema_personas(db), persona_id, codigos, leer=_leer)


@router.get("", response_model=SesionOut)
def obtener_sesion(
    caller: CallerIdentity = Depends(get_caller_identity),
    db: Client = Depends(get_service_client),
) -> dict:
    """Usa service_role, no get_caller_client (excepción documentada en app/deps.py): la policy
    solo_caller_activo de personas.usuario también exige al caller activo para leer sus propias
    filas, así que una cuenta suspendida consultándose con su propio cliente recibiría cero
    filas — el mismo síntoma que este endpoint existe para diagnosticar. Por eso filtra
    exclusivamente por el auth_user_id ya verificado por get_caller_identity
    (supabase.auth.get_user contra GoTrue), nunca por un parámetro de la request."""
    # UN solo cliente de esquema para toda la petición: cada `db.postgrest.schema(...)` fabrica un cliente httpx nuevo (otro TCP/TLS), y con ~2 s por consulta desde el Pi eso era
    # la mayor parte del costo. Cada lectura tiene UN reintento ante un error transitorio de la base y, si vuelve a fallar, un 503 con Retry-After (no un 500 ni un «sin sesión»).
    tabla = _esquema_personas(db).table
    leer = _leer

    # usuario + estado de su persona en UNA consulta (embed por la FK usuario.persona_id → persona.id; el endpoint usa service_role, la RLS no interviene).
    filas_usuario = leer(
        lambda: tabla("usuario")
        .select("auth_user_id, nombre_usuario, persona_id, persona:persona_id(estado)")
        .eq("auth_user_id", caller.auth_user_id)
        .execute()
        .data
    )
    if not filas_usuario:
        return {
            "auth_user_id": caller.auth_user_id,
            "correo": caller.correo,
            "nombre_usuario": None,
            "persona_id": None,
            "persona_estado": None,
            "acceso_permitido": False,
            "motivo_bloqueo": "sin_usuario",
        }

    usuario = filas_usuario[0]
    if not usuario.get("persona_id"):
        return {
            "auth_user_id": caller.auth_user_id,
            "correo": caller.correo,
            "nombre_usuario": usuario["nombre_usuario"],
            "persona_id": None,
            "persona_estado": None,
            "acceso_permitido": False,
            "motivo_bloqueo": "sin_persona",
        }

    persona = usuario.get("persona")
    if isinstance(persona, list):          # tolerancia de versiones de PostgREST: un embed de muchos-a-uno llega como objeto; si llegara como lista de uno, se toma el primero
        persona = persona[0] if persona else None
    persona_estado = persona.get("estado") if isinstance(persona, dict) else None
    acceso_permitido = persona_estado == "activo"
    motivo_bloqueo = None if acceso_permitido else (persona_estado or "sin_persona")

    puede_ver_modulo_1 = False
    puede_ver_modulo_2 = False
    puede_ver_modulo_3 = False
    puede_descartar_excepciones = False
    puede_ver_terminales = False
    puede_editar_terminales = False
    puede_editar_config_terminales = False
    if acceso_permitido:
        # UNA resolución de puestos y poseedores para todos los códigos (antes ~5 consultas por código).
        permisos = tiene_permisos(
            db,
            usuario["persona_id"],
            (
                "ver_modulo_1",
                "ver_modulo_2",
                "ver_modulo_3",
                "excepcion_dia_cerrado_descarte",
                "terminal_usuario_lectura",
                "terminal_usuario_edicion",
                "terminal_config_edicion",
            ),
        )
        puede_ver_modulo_1 = permisos["ver_modulo_1"]
        puede_ver_modulo_2 = permisos["ver_modulo_2"]
        puede_ver_modulo_3 = permisos["ver_modulo_3"]
        puede_descartar_excepciones = permisos["excepcion_dia_cerrado_descarte"]
        puede_editar_terminales = permisos["terminal_usuario_edicion"]
        puede_editar_config_terminales = permisos["terminal_config_edicion"]
        # Q5 (decidido por el usuario): terminal_config_edicion SOLA no da acceso a Terminales.
        puede_ver_terminales = permisos["terminal_usuario_lectura"] or puede_editar_terminales

    return {
        "auth_user_id": caller.auth_user_id,
        "correo": caller.correo,
        "nombre_usuario": usuario["nombre_usuario"],
        "persona_id": usuario["persona_id"],
        "persona_estado": persona_estado,
        "acceso_permitido": acceso_permitido,
        "motivo_bloqueo": motivo_bloqueo,
        "puede_ver_modulo_1": puede_ver_modulo_1,
        "puede_ver_modulo_2": puede_ver_modulo_2,
        "puede_ver_modulo_3": puede_ver_modulo_3,
        "puede_descartar_excepciones": puede_descartar_excepciones,
        "puede_ver_terminales": puede_ver_terminales,
        "puede_editar_terminales": puede_editar_terminales,
        "puede_editar_config_terminales": puede_editar_config_terminales,
    }
