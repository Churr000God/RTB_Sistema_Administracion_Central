"""Precondiciones del ESQUEMA con las que el backend puede arrancar (orden de despliegue obligado: DDL -> backend -> frontend).

Algunas lecturas del backend piden columnas que añade una migración (hoy: `tiempo.terminal_usuario.huella_evidencia`, de `94_`). Si el backend se despliega ANTES que la migración,
todo endpoint que lea altas falla con 500 en cada petición. En vez de un fallback silencioso (que haría ver altas sin evidencia como si no la tuvieran), el backend se
NEGA a arrancar con un mensaje claro, y `scripts/desplegar.sh` hace la misma comprobación antes de levantar nada.

Sólo un faltante DEFINITIVO (la base responde que la columna no existe) aborta; si la base no se puede consultar (red caída, credenciales), se registra una advertencia y se
sigue, igual que el resto del arranque tolera un Supabase transitoriamente caído."""

import logging
import os

from postgrest.exceptions import APIError
from supabase import Client

logger = logging.getLogger(__name__)

# (esquema, tabla, columna, migración que la crea)
ESQUEMA_REQUERIDO: tuple[tuple[str, str, str, str], ...] = (
    ("tiempo", "terminal_usuario", "huella_evidencia", "db/ddl/94_tiempo_terminal_huella_evidencia.sql"),
    ("tiempo", "terminal", "ingesta_detenida", "db/ddl/99_tiempo_terminal_ingesta_detenida.sql"),
)
# (esquema, función, parámetros de la llamada de comprobación, migración). Se llama con service_role y parámetros nulos: la de estado es de solo lectura y la de cambio NO tiene EXECUTE para
# service_role (la base responde 42501 sin ejecutar nada), de modo que la comprobación no puede escribir; una función inexistente responde PGRST202.
FUNCIONES_REQUERIDAS: tuple[tuple[str, str, dict, str], ...] = (
    ("tiempo", "fn_terminal_inferir_huella_estado", {}, "db/ddl/97_tiempo_terminal_inferir_huella_interruptor.sql"),
    # 99_: la firma de 7 argumentos. La comprobación pasa la terminal 0 (nunca existe: los ids son identity desde 1) y todo lo demás nulo: la función valida la terminal ANTES de cualquier
    # escritura y responde SCJ12 (la función existe con esa firma); sin el 7.º argumento PostgREST responde PGRST202.
    ("tiempo", "fn_terminal_latido", {"p_terminal_id": 0, "p_hora_terminal": None, "p_alcanzable": None, "p_reloj_sincronizado": None, "p_version_pi": None, "p_marcas_pendientes": None,
                                      "p_ingesta_detenida": None}, "db/ddl/99_tiempo_terminal_ingesta_detenida.sql"),
    ("tiempo", "fn_terminal_inferir_huella_cambiar", {"p_activa": None, "p_nota": None, "p_hasta": None}, "db/ddl/97_tiempo_terminal_inferir_huella_interruptor.sql"),
)
CODIGOS_FUNCION_EXISTE = {"42501", "22023", "SCJ12"}  # sin EXECUTE para service_role / parámetros nulos rechazados: la función existe
# PostgREST/Postgres: columna o tabla inexistente (42703 undefined_column, 42P01 undefined_table, PGRST204 columna no encontrada en la caché, PGRST205 tabla no encontrada).
CODIGOS_FALTANTE = {"42703", "42P01", "PGRST204", "PGRST205"}
VARIABLE_OMITIR = "SCJ_PRECONDICIONES"   # "off" la apaga (pruebas y emergencias); por omisión está encendida


class PrecondicionNoVerificable(Exception):
    """No se pudo consultar la base: no se sabe si falta algo (no es lo mismo que «falta»)."""


def faltantes(cliente: Client) -> list[tuple[str, str, str, str]]:
    """Las entradas de ESQUEMA_REQUERIDO que la base DICE que no existen. Lanza PrecondicionNoVerificable si no pudo preguntar."""
    perdidas = []
    for esquema, tabla, columna, migracion in ESQUEMA_REQUERIDO:
        try:
            cliente.postgrest.schema(esquema).table(tabla).select(columna).limit(0).execute()
        except APIError as error:
            if error.code in CODIGOS_FALTANTE:
                perdidas.append((esquema, tabla, columna, migracion))
            else:
                raise PrecondicionNoVerificable(f"código {error.code}") from None
        except Exception as error:  # red, DNS, credenciales…
            raise PrecondicionNoVerificable(type(error).__name__) from None
    for esquema, funcion, parametros, migracion in FUNCIONES_REQUERIDAS:
        try:
            cliente.postgrest.schema(esquema).rpc(funcion, parametros).execute()
        except APIError as error:
            if error.code in CODIGOS_FALTANTE | {"PGRST202"}:
                perdidas.append((esquema, funcion, "función", migracion))
            elif error.code not in CODIGOS_FUNCION_EXISTE:
                raise PrecondicionNoVerificable(f"código {error.code}") from None
        except Exception as error:  # red, DNS, credenciales…
            raise PrecondicionNoVerificable(type(error).__name__) from None
    return perdidas


def mensaje(perdidas: list[tuple[str, str, str, str]]) -> str:
    detalle = "; ".join(f"{e}.{t}.{c} (aplica {m})" for e, t, c, m in perdidas)
    return f"Falta aplicar migraciones antes de arrancar el backend: {detalle}. Orden obligado: DDL -> backend -> frontend."


def verificar_al_arrancar(cliente_servicio=None) -> None:
    """Lanza RuntimeError si la base DICE que falta una columna requerida; si no se puede consultar, sólo advierte."""
    if os.environ.get(VARIABLE_OMITIR, "").lower() == "off":
        return
    try:
        if cliente_servicio is None:
            from app.config import get_settings
            from app.deps import get_service_client

            cliente_servicio = get_service_client(get_settings())
        perdidas = faltantes(cliente_servicio)
    except PrecondicionNoVerificable as error:
        logger.warning("no se pudo verificar el esquema requerido al arrancar (%s); se sigue", error)
        return
    except Exception as error:  # configuración ausente, etc.
        logger.warning("no se pudo preparar la verificación del esquema al arrancar (%s); se sigue", type(error).__name__)
        return
    if perdidas:
        texto = mensaje(perdidas)
        logger.critical("%s", texto)
        raise RuntimeError(texto)
