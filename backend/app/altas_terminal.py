"""Piezas compartidas de las altas de terminal (tiempo.terminal_usuario) para la API web: separar el error
del puente, la acción disponible, la caducidad y los nombres de persona (CONTRATO_API_TERMINALES_PAQUETE_2.md §2)."""

import re
from datetime import datetime, timedelta

from supabase import Client

from app import permisos
from app.deps import CallerIdentity

from app.catalogo_terminal import CLAVE_CADUCIDAD, valor_vigente
from app.fecha_local import a_datetime

CODIGO_ERROR = re.compile(r"[a-z0-9_]{1,40}")
LIMITE_MOTIVO = 500

ACCION_POR_ESTADO = {
    "pendiente_alta": "cancelar_alta",
    "esperando_huella": "cancelar_alta",
    "activo": "dar_de_baja",
    "pendiente_baja": None,
    "baja": None,
}


def separar_error(error_detalle: str | None) -> tuple[str | None, str | None]:
    """El Pi guarda «<codigo>: <detalle>» (SCJ-DEC-12 §3). Se separa en el primer «: »; si lo de la izquierda no es
    un código corto [a-z0-9_]{1,40}, no hay código y todo es detalle. Ambos como TEXTO PLANO."""
    if not error_detalle:
        return None, None
    codigo, separador, resto = error_detalle.partition(": ")
    if separador and CODIGO_ERROR.fullmatch(codigo):
        return codigo, resto or None
    return None, error_detalle


def accion_disponible(estado: str) -> str | None:
    return ACCION_POR_ESTADO.get(estado)


# Invisibles y de dirección bidireccional que pasan un filtro de controles ASCII/C1 (Trojan Source, spoofing).
INVISIBLES = re.compile(
    "[\u00ad\u061c\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff\U000e0000-\U000e007f]"
)


def sanear_motivo(motivo: str | None, truncar: bool = True) -> str | None:
    """Colapsa espacios, quita caracteres de control y recorta a 500; vacío -> None."""
    if motivo is None:
        return None
    limpio = INVISIBLES.sub("", motivo)
    limpio = re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", limpio)
    limpio = " ".join(limpio.split())
    if truncar:
        limpio = limpio[:LIMITE_MOTIVO]
    return limpio or None


def resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", sorted(set(persona_ids)))
        .execute()
        .data
    )
    return {f["id"]: f"{f['primer_nombre']} {f['apellido_paterno']}" for f in filas}


def _consentimientos_por_id(db: Client, ids: list[int]) -> dict[int, dict]:
    if not ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_consentimiento")
        .select("id, version, provisional, cambio_material")
        .in_("id", sorted(set(ids)))
        .execute()
        .data
    )
    return {f["id"]: f for f in filas}


def _id_vigente(db: Client) -> int | None:
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_consentimiento")
        .select("id")
        .order("version", desc=True)
        .limit(1)
        .execute()
        .data
    )
    return filas[0]["id"] if filas else None


def ids_pendientes(db: Client) -> set[int]:
    """Definición ÚNICA de «reconsentimiento pendiente»: fn_terminal_reconsentimiento_pendiente_ids (88_, INVOKER)."""
    data = db.postgrest.schema("tiempo").rpc("fn_terminal_reconsentimiento_pendiente_ids", {}).execute().data
    return {int(x) for x in (data or [])}


RAZON_EN_BAJA = "en_baja"
RAZON_ES_PROPIA = "es_propia"
RAZON_YA_AL_CORRIENTE = "ya_al_corriente"
ESTADOS_EN_RETIRO = ("pendiente_baja", "baja")


ESTADOS_RECONSENTIBLES = ("pendiente_alta", "esperando_huella", "activo")
TOPE_FILAS_TERMINAL = 1000


def pendientes_de_terminal(db: Client, terminal_id: int, pendientes: set[int]) -> list[dict]:
    """Altas de ESTA terminal con reconsentimiento pendiente: se piden primero por terminal y estado (acotado, con índice)
    y se intersectan en Python con la lista global; nunca se arma una URL con todos los ids pendientes del sistema."""
    if not pendientes:
        return []
    filas = (
        db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select("id, persona_id, consentimiento_id")
        .eq("terminal_id", terminal_id)
        .in_("estado", list(ESTADOS_RECONSENTIBLES))
        .order("id")
        .limit(TOPE_FILAS_TERMINAL)
        .execute()
        .data
    )
    return [f for f in filas if f["id"] in pendientes]


class ContextoCaller:
    """Quién llama, para decidir elegibilidad: persona propia y, SÓLO si hace falta (una alta propia), si es el
    administrador genérico. La consulta del puesto administrador no depende de qué altas se estén armando."""

    def __init__(self, db: Client, caller: CallerIdentity) -> None:
        self._db = db
        self.propia: str = permisos.resolver_persona_id(db, caller)
        self._admin: bool | None = None

    @property
    def es_admin(self) -> bool:
        if self._admin is None:
            self._admin = bool(permisos.es_administrador_generico(self._db, self.propia))
        return self._admin

    def es_propia(self, persona_id: str) -> bool:
        return persona_id == self.propia


def razon_no_elegible(estado: str, persona_id: str, ctx, pendiente: bool) -> str | None:
    """Única regla de elegibilidad para reconsentir (lista cerrada de razones; None = elegible). Prioridad:
    en_baja > es_propia > ya_al_corriente. La propia sólo es inelegible si quien llama NO es administrador genérico
    (`ctx.es_admin` se consulta únicamente cuando la alta es propia)."""
    if estado in ESTADOS_EN_RETIRO:
        return RAZON_EN_BAJA
    if ctx is not None and ctx.es_propia(persona_id) and not ctx.es_admin:
        return RAZON_ES_PROPIA
    if not pendiente:
        return RAZON_YA_AL_CORRIENTE
    return None


def armar_altas(
    db: Client,
    db_servicio: Client,
    filas: list[dict],
    caller: CallerIdentity | None = None,
    pendientes: set[int] | None = None,
) -> list[dict]:
    """Objeto «alta» del contrato §2.1. Consultas por página, no por alta: nombres (1), consentimientos (1), vigente
    (1), pendientes (1) y, sólo si alguna espera huella, la variable de caducidad (1). `usuario_creado_en` es la
    columna de 88_ (la fija el trigger), no una consulta a la bitácora."""
    if not filas:
        return []
    nombres = resolver_nombres_persona(db, [f["persona_id"] for f in filas])
    consentimientos = _consentimientos_por_id(db, [f["consentimiento_id"] for f in filas if f.get("consentimiento_id")])
    vigente_id = _id_vigente(db)
    if pendientes is None:
        pendientes = ids_pendientes(db)
    ctx = ContextoCaller(db, caller) if caller is not None else None
    horas = (
        valor_vigente(db_servicio, CLAVE_CADUCIDAD)
        if any(f["estado"] == "esperando_huella" for f in filas)
        else None
    )
    altas = []
    for fila in filas:
        creada = a_datetime(fila["usuario_creado_en"]) if fila.get("usuario_creado_en") else None
        caduca = (
            creada + timedelta(hours=horas)
            if fila["estado"] == "esperando_huella" and creada is not None and horas is not None
            else None
        )
        codigo, detalle = separar_error(fila.get("error_detalle"))
        consent = consentimientos.get(fila.get("consentimiento_id"))
        razon = razon_no_elegible(fila["estado"], fila["persona_id"], ctx, fila["id"] in pendientes)
        altas.append(
            {
                "id": fila["id"],
                "terminal_id": fila["terminal_id"],
                "employee_no": fila["employee_no"],
                "persona_id": fila["persona_id"],
                "persona_nombre": nombres.get(fila["persona_id"]),
                "estado": fila["estado"],
                "huellas_capturadas": fila["huellas_capturadas"],
                "huella_evidencia": fila.get("huella_evidencia"),
                "creado_en": fila["creado_en"],
                "actualizado_en": fila["actualizado_en"],
                "usuario_creado_en": creada,
                "caduca_en": caduca,
                "error_codigo": codigo,
                "error_detalle": detalle,
                "consentimiento": (
                    {"id": consent["id"], "version": consent["version"], "provisional": consent["provisional"]}
                    if consent
                    else None
                ),
                "consentimiento_vigente_id": vigente_id,
                "reconsentimiento_pendiente": fila["id"] in pendientes,
                "es_propia": ctx is not None and ctx.es_propia(fila["persona_id"]),
                "reconsentimiento_elegible": razon is None,
                "reconsentimiento_razon": razon,
                "accion_disponible": accion_disponible(fila["estado"]),
            }
        )
    return altas
