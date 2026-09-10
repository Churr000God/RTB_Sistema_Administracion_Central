"""API de "alerta de retardo" (SCJ-DEC-10) -- pedido del usuario en vivo, no un proceso SCJ-PRO
original. Para una persona con jornada `normal` vigente, si su primera marca del día no coincide
con la hora de entrada programada Y su última marca tampoco coincide con la hora de salida
programada (con la misma tolerancia que usa `fuera_de_horario`, `tiempo.parametro.
tolerancia_retardo_min`), el día se marca como alerta. Ver SCJ-DEC-10 para el detalle completo de
cada regla (tolerancia, marca faltante, exclusiones, franjas partidas).

Sólo lectura, cálculo enteramente en Python sobre lotes de PostgREST (sin RPC ni vista nueva --
Opción A del punto C de SCJ-DEC-10): a la escala real del proyecto (rango acotado, decenas de
personas) no se justifica una migración nueva para una regla que recién se terminó de definir con
el usuario. get_caller_client (RLS) de siempre, nunca service_role.

`tiempo.marca` no distingue entrada de salida (es un evento crudo, SCJ-DEC-08) -- "primera" y
"última" marca del día son, literalmente, el mínimo y el máximo de la hora local reconstruida. Con
una sola marca ese día, mínimo y máximo son la misma marca y se compara contra ambos extremos sin
caso especial (ver SCJ-DEC-10, sección "Simplificación de alcance")."""

from datetime import date, datetime, time, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import Client

from app.deps import get_caller_client
from app.permisos import requiere_permiso
from app.schemas.alertas_de_retardo import AlertaDeRetardoItem, AlertasDeRetardoOut

router = APIRouter(prefix="/api/alertas-de-retardo", tags=["alertas-de-retardo"])

DIAS_SEMANA = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
LIMITE_RANGO_DIAS = 62  # ~2 quincenas -- tope defensivo, no pedido explícito por el usuario.
TOLERANCIA_POR_DEFECTO_MIN = 0

MENSAJE_RANGO_INVALIDO = "desde no puede ser posterior a hasta."
MENSAJE_RANGO_DEMASIADO_AMPLIO = f"El rango no puede superar {LIMITE_RANGO_DIAS} días."


def _dia_semana(fecha: date) -> str:
    return DIAS_SEMANA[fecha.isoweekday() - 1]


def _rango_fechas(desde: date, hasta: date):
    fecha = desde
    while fecha <= hasta:
        yield fecha
        fecha += timedelta(days=1)


def _hora_local(momento_dispositivo: str, desfase_local: str) -> datetime:
    """Misma reconstrucción que trg_marca_valida_revision (02_tiempo.sql): la hora local nunca se
    guarda, se recalcula desde momento_dispositivo (UTC) + desfase_local cada vez."""
    momento_utc = datetime.fromisoformat(momento_dispositivo)
    signo = 1 if desfase_local[0] == "+" else -1
    horas, minutos = (int(parte) for parte in desfase_local[1:].split(":"))
    return momento_utc.replace(tzinfo=None) + signo * timedelta(hours=horas, minutes=minutos)


def _resolver_jornadas_normales(
    db: Client, persona_id: str | None, desde: date, hasta: date
) -> list[dict]:
    consulta = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("id, persona_id, vigente_desde, vigente_hasta")
        .eq("tipo_jornada", "normal")
        .lte("vigente_desde", hasta.isoformat())
    )
    if persona_id is not None:
        consulta = consulta.eq("persona_id", persona_id)
    filas = consulta.execute().data
    return [
        fila
        for fila in filas
        if fila["vigente_hasta"] is None or fila["vigente_hasta"] >= desde.isoformat()
    ]


def _resolver_patrones(db: Client, jornada_ids: list[int]) -> dict[int, dict[str, list[dict]]]:
    if not jornada_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("patron_semanal")
        .select("jornada_asignada_id, dia_semana, hora_entrada, hora_salida")
        .in_("jornada_asignada_id", jornada_ids)
        .execute()
        .data
    )
    patrones: dict[int, dict[str, list[dict]]] = {}
    for fila in filas:
        por_dia = patrones.setdefault(fila["jornada_asignada_id"], {})
        por_dia.setdefault(fila["dia_semana"], []).append(fila)
    return patrones


def _resolver_tolerancias(db: Client, hasta: date) -> list[tuple[date, int]]:
    """Ordenadas desc por vigente_desde -- misma resolución "última vigente antes de la fecha"
    que usa el trigger de fuera_de_horario, sólo que acá se trae todo el historial de una vez
    (rango acotado) en vez de una consulta por día."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("parametro")
        .select("valor, vigente_desde")
        .eq("clave", "tolerancia_retardo_min")
        .lte("vigente_desde", hasta.isoformat())
        .order("vigente_desde", desc=True)
        .execute()
        .data
    )
    return [(date.fromisoformat(fila["vigente_desde"]), int(fila["valor"])) for fila in filas]


def _tolerancia_vigente(tolerancias: list[tuple[date, int]], fecha: date) -> int:
    for vigente_desde, valor in tolerancias:
        if vigente_desde <= fecha:
            return valor
    return TOLERANCIA_POR_DEFECTO_MIN


def _resolver_dias(db: Client, persona_ids: list[str], desde: date, hasta: date) -> dict:
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .select("persona_id, fecha, estado, origen")
        .in_("persona_id", persona_ids)
        .gte("fecha", desde.isoformat())
        .lte("fecha", hasta.isoformat())
        .execute()
        .data
    )
    return {(fila["persona_id"], fila["fecha"]): fila for fila in filas}


def _resolver_marcas_locales(
    db: Client, persona_ids: list[str], desde: date, hasta: date
) -> dict[tuple[str, date], list[datetime]]:
    if not persona_ids:
        return {}
    # Ventana ampliada un día a cada lado en UTC -- un desfase distinto de +00:00 puede correr la
    # fecha local fuera del rango UTC pedido (mismo motivo que la reconstrucción de hora local).
    ventana_desde = (desde - timedelta(days=1)).isoformat() + "T00:00:00+00:00"
    ventana_hasta = (hasta + timedelta(days=1)).isoformat() + "T23:59:59+00:00"
    filas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("persona_id, momento_dispositivo, desfase_local")
        .in_("persona_id", persona_ids)
        .gte("momento_dispositivo", ventana_desde)
        .lte("momento_dispositivo", ventana_hasta)
        .execute()
        .data
    )
    marcas_por_dia: dict[tuple[str, date], list[datetime]] = {}
    for fila in filas:
        local = _hora_local(fila["momento_dispositivo"], fila["desfase_local"])
        clave = (fila["persona_id"], local.date())
        marcas_por_dia.setdefault(clave, []).append(local)
    return marcas_por_dia


def _resolver_nombres_persona(db: Client, persona_ids: list[str]) -> dict[str, str]:
    if not persona_ids:
        return {}
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id, primer_nombre, apellido_paterno")
        .in_("id", persona_ids)
        .execute()
        .data
    )
    return {fila["id"]: f"{fila['primer_nombre']} {fila['apellido_paterno']}" for fila in filas}


def _diferencia_minutos(hora_a: time, hora_b: time) -> float:
    referencia = date(2000, 1, 1)
    return abs(
        (datetime.combine(referencia, hora_a) - datetime.combine(referencia, hora_b)).total_seconds()
    ) / 60.0


@router.get("", response_model=AlertasDeRetardoOut)
def listar_alertas_de_retardo(
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("clasificacion_de_tiempo_lectura")),
    persona_id: str | None = Query(None, description="Filtra por una persona exacta."),
    desde: date = Query(..., description="Primer día del rango a evaluar (inclusive)."),
    hasta: date = Query(..., description="Último día del rango a evaluar (inclusive)."),
) -> dict:
    if desde > hasta:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_RANGO_INVALIDO)
    if (hasta - desde).days > LIMITE_RANGO_DIAS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_RANGO_DEMASIADO_AMPLIO)

    jornadas = _resolver_jornadas_normales(db, persona_id, desde, hasta)
    if not jornadas:
        return {"alertas": []}

    jornada_ids = [jornada["id"] for jornada in jornadas]
    persona_ids = sorted({jornada["persona_id"] for jornada in jornadas})

    patrones = _resolver_patrones(db, jornada_ids)
    tolerancias = _resolver_tolerancias(db, hasta)
    dias = _resolver_dias(db, persona_ids, desde, hasta)
    marcas_por_dia = _resolver_marcas_locales(db, persona_ids, desde, hasta)
    nombres = _resolver_nombres_persona(db, persona_ids)

    alertas = []
    for jornada in jornadas:
        vigente_desde = date.fromisoformat(jornada["vigente_desde"])
        vigente_hasta = (
            date.fromisoformat(jornada["vigente_hasta"]) if jornada["vigente_hasta"] else hasta
        )
        inicio = max(desde, vigente_desde)
        fin = min(hasta, vigente_hasta)
        if inicio > fin:
            continue

        patron_de_jornada = patrones.get(jornada["id"], {})
        for fecha in _rango_fechas(inicio, fin):
            patron_del_dia = patron_de_jornada.get(_dia_semana(fecha))
            if not patron_del_dia:
                continue  # Día sin franja programada -- nada contra qué comparar (SCJ-DEC-10).

            dia_info = dias.get((jornada["persona_id"], fecha.isoformat()))
            if dia_info and (
                dia_info["origen"] == "ausencia_autorizada" or dia_info["estado"] == "revisado"
            ):
                continue

            entrada_programada = min(fila["hora_entrada"] for fila in patron_del_dia)
            salida_programada = max(fila["hora_salida"] for fila in patron_del_dia)
            entrada_programada = time.fromisoformat(entrada_programada)
            salida_programada = time.fromisoformat(salida_programada)

            marcas_del_dia = marcas_por_dia.get((jornada["persona_id"], fecha), [])
            if not marcas_del_dia:
                alertas.append(
                    AlertaDeRetardoItem(
                        persona_id=jornada["persona_id"],
                        persona_nombre=nombres.get(jornada["persona_id"]),
                        fecha=fecha,
                        hora_entrada_programada=entrada_programada,
                        hora_salida_programada=salida_programada,
                        primera_marca=None,
                        ultima_marca=None,
                        motivo="sin_marcas",
                    )
                )
                continue

            primera_marca = min(marcas_del_dia)
            ultima_marca = max(marcas_del_dia)
            tolerancia = _tolerancia_vigente(tolerancias, fecha)
            coincide_entrada = (
                _diferencia_minutos(primera_marca.time(), entrada_programada) <= tolerancia
            )
            coincide_salida = (
                _diferencia_minutos(ultima_marca.time(), salida_programada) <= tolerancia
            )
            if not coincide_entrada and not coincide_salida:
                alertas.append(
                    AlertaDeRetardoItem(
                        persona_id=jornada["persona_id"],
                        persona_nombre=nombres.get(jornada["persona_id"]),
                        fecha=fecha,
                        hora_entrada_programada=entrada_programada,
                        hora_salida_programada=salida_programada,
                        primera_marca=primera_marca,
                        ultima_marca=ultima_marca,
                        motivo="fuera_de_tolerancia",
                    )
                )

    alertas.sort(key=lambda alerta: (alerta.fecha, alerta.persona_id), reverse=True)
    return {"alertas": alertas}
