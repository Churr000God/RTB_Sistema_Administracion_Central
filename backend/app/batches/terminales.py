"""Jobs programados del módulo Terminales (CONTRATO_API_TERMINALES_PAQUETE_2.md §10, SCJ-DEC-12 §5/§6): caducidad de
altas sin huella y purga de marcas rechazadas. Corren como service_role (proceso de sistema, no un caller humano),
leen la variable vigente EN CADA CORRIDA (un cambio de configuración aplica a las altas en curso), son idempotentes
y NUNCA propagan una excepción: un job que falla se registra y espera a la siguiente corrida."""

import logging

from supabase import Client

from datetime import datetime, timezone

from app.catalogo_terminal import CLAVE_CADUCIDAD, CLAVE_RETENCION_RECHAZOS, valor_vigente_estricto
from app.deps import get_service_client
from app.config import get_settings

logger = logging.getLogger(__name__)

TOPE_BAJAS_POR_CORRIDA = 50  # fijo dentro de fn_terminal_baja_por_caducidad


def _cliente() -> Client:
    return get_service_client(get_settings())


def _llamar(db: Client, funcion: str, parametros: dict) -> int | None:
    try:
        resultado = db.postgrest.schema("tiempo").rpc(funcion, parametros).execute().data
    except Exception as error:  # APIError, red, 89_/85_ sin aplicar…
        logger.error("job de terminales: %s falló (%s, código %s)", funcion, type(error).__name__, getattr(error, "code", None))
        return None
    if isinstance(resultado, bool) or not isinstance(resultado, int) or resultado < 0:
        logger.error("job de terminales: %s devolvió una forma inesperada", funcion)
        return None
    return resultado


def ejecutar_baja_por_caducidad(db: Client | None = None) -> int | None:
    """Da de baja las altas en `esperando_huella` que llevan más de `terminal_caducidad_alta_horas` desde
    `usuario_creado` (piso de 4 h y tope de 50 por corrida viven DENTRO de la función SQL; el resto queda para la
    siguiente corrida). Devuelve cuántas bajas emitió, o None si falló."""
    try:
        db = db or _cliente()
        horas = valor_vigente_estricto(db, CLAVE_CADUCIDAD)
        if horas is None:
            logger.error("baja por caducidad: no se pudo leer la variable; se omite la corrida")
            return None
        n = _llamar(db, "fn_terminal_baja_por_caducidad", {"p_horas": horas})
    except Exception:
        logger.exception("job de terminales: la baja por caducidad no pudo arrancar")
        return None
    if n:
        logger.warning(
            "baja por caducidad: altas=%s plazo_horas=%s fecha=%s", n, horas, datetime.now(timezone.utc).isoformat()
        )
        if n >= TOPE_BAJAS_POR_CORRIDA:
            logger.warning(
                "baja por caducidad: se alcanzó el tope de %s por corrida; el resto queda para la siguiente",
                TOPE_BAJAS_POR_CORRIDA,
            )
    return n


def ejecutar_purga_rechazos(db: Client | None = None) -> int | None:
    """Purga `tiempo.marca_rechazada` más antigua que `terminal_retencion_rechazos_dias` (piso de 7 días dentro de
    la función). Bajar la retención borra evidencia de forma irreversible en esta corrida."""
    try:
        db = db or _cliente()
        dias = valor_vigente_estricto(db, CLAVE_RETENCION_RECHAZOS)
        if dias is None:
            logger.error("purga de rechazos: no se pudo leer la variable; se omite la corrida")
            return None
        n = _llamar(db, "fn_marca_rechazada_purgar", {"p_dias": dias})
    except Exception:
        logger.exception("job de terminales: la purga de rechazos no pudo arrancar")
        return None
    if n:
        logger.warning(
            "purga de rechazos: filas=%s retencion_dias=%s fecha=%s", n, dias, datetime.now(timezone.utc).isoformat()
        )
    return n


# --- Reconciliación de bajas por persona inactiva (respaldo del hook de movimientos) -----------------------------------------
# CONDICIÓN DE SALIDA A PRODUCCIÓN (security): el hook de POST /movimientos puede fallar (red, RPC caído, `-1` sin autor); sin
# este respaldo una persona suspendida seguiría marcando. Idempotente: la función SQL ignora las altas que ya se retiran.

ESTADOS_ALTA_VIVA = ("pendiente_alta", "esperando_huella", "activo")
PAGINA_ALTAS = 1000
MAX_PAGINAS_ALTAS = 20
TOPE_PERSONAS_POR_CORRIDA = 200


def _personas_con_altas_vivas(db: Client) -> list[str]:
    ids: set[str] = set()
    for pagina in range(MAX_PAGINAS_ALTAS):
        filas = (
            db.postgrest.schema("tiempo")
            .table("terminal_usuario")
            .select("persona_id")
            .in_("estado", list(ESTADOS_ALTA_VIVA))
            .order("id")
            .range(pagina * PAGINA_ALTAS, (pagina + 1) * PAGINA_ALTAS - 1)
            .execute()
            .data
        )
        ids.update(f["persona_id"] for f in filas)
        if len(filas) < PAGINA_ALTAS:
            break
    return sorted(ids)


def _inactivas(db: Client, persona_ids: list[str]) -> list[str]:
    """Personas con altas vivas que ya no están activas O que ya no existen en personas.persona (alta huérfana: la
    función SQL las trata como «inexistente» y también pide su baja)."""
    inactivas: list[str] = []
    for i in range(0, len(persona_ids), 100):
        trozo = persona_ids[i : i + 100]
        filas = db.postgrest.schema("personas").table("persona").select("id, estado").in_("id", trozo).execute().data
        estados = {f["id"]: f["estado"] for f in filas}
        inactivas.extend(p for p in trozo if p not in estados or estados[p] != "activo")
    return inactivas


# Personas cuyo último resultado fue -1 (sin autor derivable): no avanzan solas, así que NO deben ocupar el cupo de cada
# corrida y dejar sin atender a las demás (inanición). Estado en memoria del único worker.
_SIN_AUTOR_PREVIO: set[str] = set()


def ejecutar_reconciliacion_bajas(db: Client | None = None) -> dict | None:
    """Para cada persona `estado <> 'activo'` con altas de terminal que no se están retirando, pide su baja con
    `fn_terminal_baja_por_persona_inactiva`. Un resultado `-1` (sin autor derivable) NO se reintenta en bucle: se registra
    como ALERTA PERMANENTE en cada corrida (ERROR) mientras la inconsistencia exista, y además queda visible en la tarjeta
    «Inconsistencias de baja» del tablero. Nunca propaga una excepción. Devuelve el resumen, o None si no pudo leer."""
    try:
        db = db or _cliente()
        personas = _personas_con_altas_vivas(db)
        inactivas = _inactivas(db, personas)
    except Exception as error:
        logger.error("reconciliación de bajas: no se pudo leer (%s)", getattr(error, "code", None) or type(error).__name__)
        return None
    if len(inactivas) > TOPE_PERSONAS_POR_CORRIDA:
        logger.warning(
            "reconciliación de bajas: %s personas inactivas con altas; se procesan %s por corrida",
            len(inactivas), TOPE_PERSONAS_POR_CORRIDA,
        )
    # Primero las que NO fueron -1 en la corrida anterior; las -1 permanentes van al final y no consumen el cupo de las demás.
    inactivas.sort(key=lambda p: (p in _SIN_AUTOR_PREVIO, p))
    procesadas = inactivas[:TOPE_PERSONAS_POR_CORRIDA]
    emitidas, sin_autor, fallidas = 0, [], 0
    for persona_id in procesadas:
        try:
            r = db.postgrest.schema("tiempo").rpc("fn_terminal_baja_por_persona_inactiva", {"p_persona_id": persona_id}).execute().data
        except Exception as error:
            fallidas += 1
            logger.error("reconciliación de bajas: falló una persona (%s)", getattr(error, "code", None) or type(error).__name__)
            continue
        if isinstance(r, bool) or not isinstance(r, int):
            fallidas += 1
            logger.error("reconciliación de bajas: forma inesperada del RPC")
        elif r == -1:
            sin_autor.append(persona_id)
        elif r >= 0:
            emitidas += r
        else:
            fallidas += 1
            logger.error("reconciliación de bajas: resultado inesperado del RPC")
    sin_procesar_previas = {p for p in inactivas[TOPE_PERSONAS_POR_CORRIDA:] if p in _SIN_AUTOR_PREVIO}
    _SIN_AUTOR_PREVIO.clear()
    _SIN_AUTOR_PREVIO.update(sin_autor)
    _SIN_AUTOR_PREVIO.update(sin_procesar_previas)  # las que no alcanzaron cupo conservan su marca
    if sin_autor:
        # Sin autor derivable la baja NUNCA se emitirá sola: hace falta intervención humana. Se repite en cada corrida.
        logger.error(
            "ALERTA PERMANENTE reconciliación de bajas: %s persona(s) inactiva(s) con altas de terminal sin autor derivable "
            "(la baja no se puede emitir sola); revisar el tablero «Inconsistencias de baja». Personas: %s",
            len(sin_autor), ", ".join(p[:8] for p in sin_autor),
        )
    if emitidas:
        logger.warning(
            "reconciliación de bajas: bajas_emitidas=%s personas_inactivas=%s fecha=%s",
            emitidas, len(inactivas), datetime.now(timezone.utc).isoformat(),
        )
    return {"inactivas": len(inactivas), "emitidas": emitidas, "sin_autor": len(sin_autor), "fallidas": fallidas}
