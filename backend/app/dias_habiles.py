"""Helper de días hábiles compartido por routers/correcciones.py (SCJ-PRO-10) y
routers/marcas.py (SCJ-PRO-07, hora editable en captura manual) -- día hábil = ni domingo ni
tiempo.dia_festivo. service_role: tiempo.parametro/tiempo.dia_festivo son configuración global,
no dato del caller (mismo criterio que app/scheduler.py leyendo hora_corrida_cierre_dia). Fail-
open si Supabase no responde -- no tumbar el endpoint por un problema transitorio de red."""

from datetime import date, timedelta

from app.config import get_settings
from app.deps import get_service_client

DIAS_HABILES_POR_DEFECTO = 30  # mismo valor de ejemplo que db/ddl/03_parametros_ejemplo.sql


def _dias_habiles_limite() -> int:
    """Lee tiempo.parametro.dias_habiles_correccion_marca con service_role. Si Supabase no
    responde, cae al valor de ejemplo en vez de tumbar el endpoint por un problema transitorio
    de red."""
    try:
        db = get_service_client(get_settings())
        hoy = date.today().isoformat()
        filas = (
            db.postgrest.schema("tiempo")
            .table("parametro")
            .select("valor")
            .eq("clave", "dias_habiles_correccion_marca")
            .lte("vigente_desde", hoy)
            .order("vigente_desde", desc=True)
            .limit(1)
            .execute()
            .data
        )
        if not filas:
            return DIAS_HABILES_POR_DEFECTO
        return int(filas[0]["valor"])
    except Exception:
        return DIAS_HABILES_POR_DEFECTO


def _festivos_entre(fecha_inicio: date, fecha_fin: date) -> set[str]:
    """service_role -- config global, no dato del caller. Igual que _dias_habiles_limite, si
    Supabase no responde no tumba el endpoint: sigue como si no hubiera festivos (fail-open)."""
    if fecha_fin <= fecha_inicio:
        return set()
    try:
        db = get_service_client(get_settings())
        filas = (
            db.postgrest.schema("tiempo")
            .table("dia_festivo")
            .select("fecha")
            .gte("fecha", fecha_inicio.isoformat())
            .lte("fecha", fecha_fin.isoformat())
            .execute()
            .data
        )
        return {fila["fecha"] for fila in filas}
    except Exception:
        return set()


def _dias_habiles_transcurridos(fecha_inicio: date, fecha_fin: date, festivos: set[str]) -> int:
    """Día hábil = ni domingo ni tiempo.dia_festivo. Pura -- recibe los festivos ya resueltos,
    no toca la BD."""
    if fecha_fin <= fecha_inicio:
        return 0
    dias = 0
    cursor = fecha_inicio + timedelta(days=1)
    while cursor <= fecha_fin:
        if cursor.weekday() != 6 and cursor.isoformat() not in festivos:  # 6 = domingo
            dias += 1
        cursor += timedelta(days=1)
    return dias
