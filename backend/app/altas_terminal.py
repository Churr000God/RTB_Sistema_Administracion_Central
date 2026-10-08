"""Piezas compartidas de las altas de terminal (tiempo.terminal_usuario) para la API web: separar el error
del puente, la acción disponible, la caducidad y los nombres de persona (CONTRATO_API_TERMINALES_PAQUETE_2.md §2)."""

import re
from datetime import datetime, timedelta

from supabase import Client

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


def usuario_creado_por_alta(db: Client, alta_ids: list[int]) -> dict[int, datetime]:
    """Momento del movimiento `usuario_creado` de cada alta, leído de la BITÁCORA (no de actualizado_en, que
    también mueve un `error`; SCJ-DEC-12 §12.7). Si hubiera más de uno, el más reciente."""
    if not alta_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("bitacora_movimiento_terminal_usuario")
        .select("terminal_usuario_id, creado_en")
        .eq("tipo_movimiento", "usuario_creado")
        .in_("terminal_usuario_id", alta_ids)
        .order("creado_en", desc=True)
        .execute()
        .data
    )
    resultado: dict[int, datetime] = {}
    for fila in filas:
        resultado.setdefault(fila["terminal_usuario_id"], a_datetime(fila["creado_en"]))
    return resultado


def armar_altas(db: Client, db_servicio: Client, filas: list[dict]) -> list[dict]:
    """Objeto «alta» del contrato §2.1 (sin los campos de consentimiento, que llegan con C5). Consultas por
    página, no por alta: nombres (1), usuario_creado (1) y, sólo si alguna espera huella, la variable de
    caducidad (1)."""
    nombres = resolver_nombres_persona(db, [f["persona_id"] for f in filas])
    creadas = usuario_creado_por_alta(db, [f["id"] for f in filas])
    horas = (
        valor_vigente(db_servicio, CLAVE_CADUCIDAD)
        if any(f["estado"] == "esperando_huella" for f in filas)
        else None
    )
    altas = []
    for fila in filas:
        creada = creadas.get(fila["id"])
        caduca = (
            creada + timedelta(hours=horas)
            if fila["estado"] == "esperando_huella" and creada is not None and horas is not None
            else None
        )
        codigo, detalle = separar_error(fila.get("error_detalle"))
        altas.append(
            {
                "id": fila["id"],
                "terminal_id": fila["terminal_id"],
                "employee_no": fila["employee_no"],
                "persona_id": fila["persona_id"],
                "persona_nombre": nombres.get(fila["persona_id"]),
                "estado": fila["estado"],
                "huellas_capturadas": fila["huellas_capturadas"],
                "creado_en": fila["creado_en"],
                "actualizado_en": fila["actualizado_en"],
                "usuario_creado_en": creada,
                "caduca_en": caduca,
                "error_codigo": codigo,
                "error_detalle": detalle,
                "accion_disponible": accion_disponible(fila["estado"]),
            }
        )
    return altas
