"""Batch de cierre de día (SCJ-PRO-12) -- la pieza de mayor riesgo y tamaño del subsistema
Tiempo, afecta el cálculo de horas de personas con jornada normal/flexible (de_confianza lo
cubre el otro batch, app/batches/de_confianza.py).

ejecutar_cierre_dia es el punto de entrada tanto del job programado (app/scheduler.py) como del
botón manual (routers/corridas_batch.py) -- misma invocación, misma orquestación de
tiempo.corrida_batch (app/batches/_orquestacion.py) que ya estrenó SCJ-PRO-14. Corre como
service_role: es un proceso de sistema, no un caller humano sujeto a RLS.

Algoritmo por persona, SCJ-PRO-12 §III/§IV:
1. Si tiempo.dia ya existe con estado != 'abierto' -> saltar (idempotente por persona).
2. Si la fecha es domingo o festivo -> saltar, nunca genera nada por sí sola.
3. Cuenta las marcas del día -- AGRUPADAS por el día calendario del valor EFECTIVO (corregido si
   existe, si no el original), no por el original crudo (hallazgo de security: una corrección
   puede cruzar medianoche -- ej. última marca 23:50 corregida a 00:10 del día siguiente, válida
   para fn_correccion_valida porque sólo exige quedar entre las marcas vecinas de la persona, sin
   exigir que el día calendario no cambie. fn_marca_valida_revision sí usa el original porque
   corre al insertar la marca, antes de que exista ninguna corrección -- este batch corre
   después, así que el bucket debe reflejar dónde cae la marca DE VERDAD):
   - 0 marcas: si no hay tiempo.ausencia cubriendo la fecha, la crea (tipo='falta', pendiente);
     tiempo.dia NO se crea acá -- se materializa cuando la ausencia se resuelve
     (fn_ausencia_resuelve_excepcion ya lo hace, SCJ-PRO-08, responsabilidad de ese trigger).
   - Par: arma tramo por parejas consecutivas, tiempo.dia.estado='cerrado',
     horas_totales=suma de tramo.minutos_trabajados.
   - Impar: arma los tramos completos, el último queda abierto (marca_cierre_id=NULL),
     tiempo.dia.estado='bloqueado' (horas_totales se deja NULL a propósito -- SCJ-PRA-01 #14,
     el valor exacto de relleno de un día bloqueado queda pendiente de decidir, no se inventa
     un número acá), crea tiempo.excepcion(dia_id, sin marca_id).

OJO -- motivo_revision de la excepción de paridad impar: ningún documento (SCJ-DEC-01, SCJ-PRO-12,
el comentario de tiempo.excepcion en 02_tiempo.sql) especifica el string exacto a usar; los 5
valores canónicos de motivo_revision son todos de marca, no de día. Se usa 'paridad_impar'
(mismo estilo snake_case que los demás) -- reportado a orchestrator como criterio propio, no como
algo tomado de un documento."""

import logging
from datetime import date, datetime, timedelta, timezone

from postgrest.exceptions import APIError
from supabase import Client

from app.batches._orquestacion import finalizar_corrida, upsert_corrida_en_progreso
from app.catalogo_motivos_revision import MOTIVO_PARIDAD_IMPAR
from app.config import get_settings
from app.deps import get_service_client

TIPO_BATCH = "cierre_dia"
DOMINGO = 6  # date.weekday(): lunes=0 ... domingo=6
UNIQUE_VIOLATION = "23505"
DESCUENTO_PAUSA_POR_DEFECTO_MIN = 60  # mismo valor de ejemplo que db/ddl/03_parametros_ejemplo.sql

logger = logging.getLogger(__name__)


def _parse_desfase(desfase_local: str) -> timedelta:
    signo = 1 if desfase_local[0] == "+" else -1
    horas, minutos = desfase_local[1:].split(":")
    return signo * timedelta(hours=int(horas), minutes=int(minutos))


def _fecha_local(momento_iso: str, desfase_local: str) -> date:
    """Misma reconstrucción que fn_marca_valida_revision (SCJ-PRO-11): momento (UTC) +
    desfase_local. Se le pasa el valor EFECTIVO (corregido si existe), no necesariamente
    momento_dispositivo -- ver docstring del módulo, fn_correccion_valida no impide que una
    corrección cruce medianoche."""
    momento = datetime.fromisoformat(momento_iso)
    return (momento.astimezone(timezone.utc) + _parse_desfase(desfase_local)).date()


def _es_festivo(db: Client, fecha_iso: str) -> bool:
    filas = (
        db.postgrest.schema("tiempo")
        .table("dia_festivo")
        .select("fecha")
        .eq("fecha", fecha_iso)
        .execute()
        .data
    )
    return bool(filas)


def _personas_normal_flexible_vigentes(db: Client, fecha_iso: str) -> list[str]:
    """Mismo criterio de vigencia que el resto del proyecto (SCJ-DEC-04). de_confianza queda
    fuera -- lo procesa el otro batch."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("jornada_asignada")
        .select("persona_id")
        .in_("tipo_jornada", ["normal", "flexible"])
        .lte("vigente_desde", fecha_iso)
        .or_(f"vigente_hasta.is.null,vigente_hasta.gte.{fecha_iso}")
        .execute()
        .data
    )
    return [fila["persona_id"] for fila in filas]


def _dia_ya_resuelto(db: Client, persona_id: str, fecha_iso: str) -> bool:
    filas = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .select("id, estado")
        .eq("persona_id", persona_id)
        .eq("fecha", fecha_iso)
        .execute()
        .data
    )
    return bool(filas) and filas[0]["estado"] != "abierto"


def _marcas_efectivas_del_dia(db: Client, persona_id: str, fecha: date) -> list[dict]:
    """Ventana de +-1 día en UTC (cualquier desfase posible) sobre el campo crudo -- suficiente
    para no perder ninguna marca candidata, el bucketing real pasa después sobre el valor
    EFECTIVO. fn_correccion_valida NO impide que una corrección cruce medianoche (sólo exige
    quedar entre las marcas vecinas de la persona) -- agrupar por momento_dispositivo original
    dejaría un tramo colgado del día equivocado si esto pasa (hallazgo de security)."""
    ventana_desde = (fecha - timedelta(days=1)).isoformat()
    ventana_hasta = (fecha + timedelta(days=2)).isoformat()
    marcas = (
        db.postgrest.schema("tiempo")
        .table("marca")
        .select("id, momento_dispositivo, desfase_local")
        .eq("persona_id", persona_id)
        .gte("momento_dispositivo", ventana_desde)
        .lt("momento_dispositivo", ventana_hasta)
        .execute()
        .data
    )
    if not marcas:
        return []

    marca_ids = [m["id"] for m in marcas]
    correcciones = (
        db.postgrest.schema("tiempo")
        .table("correccion")
        .select("marca_id, valor_corregido, creado_en")
        .in_("marca_id", marca_ids)
        .execute()
        .data
    )
    ultima_por_marca: dict[int, dict] = {}
    for correccion in correcciones:
        actual = ultima_por_marca.get(correccion["marca_id"])
        if actual is None or correccion["creado_en"] > actual["creado_en"]:
            ultima_por_marca[correccion["marca_id"]] = correccion

    candidatas = []
    for marca in marcas:
        correccion = ultima_por_marca.get(marca["id"])
        efectivo_iso = correccion["valor_corregido"] if correccion else marca["momento_dispositivo"]
        candidatas.append(
            {
                "id": marca["id"],
                "efectivo": datetime.fromisoformat(efectivo_iso),
                "fecha_local_efectiva": _fecha_local(efectivo_iso, marca["desfase_local"]),
            }
        )

    del_dia = [c for c in candidatas if c["fecha_local_efectiva"] == fecha]
    del_dia.sort(key=lambda fila: fila["efectivo"])
    return [{"id": fila["id"], "efectivo": fila["efectivo"]} for fila in del_dia]


def _ausencia_existente(db: Client, persona_id: str, fecha_iso: str) -> dict | None:
    filas = (
        db.postgrest.schema("tiempo")
        .table("ausencia")
        .select("id, estado_autorizacion")
        .eq("persona_id", persona_id)
        .lte("fecha_inicio", fecha_iso)
        .gte("fecha_fin", fecha_iso)
        .execute()
        .data
    )
    return filas[0] if filas else None


def _resolver_sin_marcas(db: Client, persona_id: str, fecha_iso: str) -> str:
    """SCJ-PRO-08: sin marcas y sin ausencia previa que cubra la fecha, crea la solicitud --
    tiempo.dia NO se crea acá, se materializa cuando la ausencia se resuelve
    (fn_ausencia_resuelve_excepcion, responsabilidad de ese trigger, no de este batch).

    Carrera (hallazgo de security): dos corridas casi simultáneas (job + botón, o dos intentos)
    con 0 marcas para la misma persona/fecha -- uq_ausencia_falta_persona_fecha (índice único
    parcial sobre tipo_de_ausencia='falta', confirmado y aplicado por db) rechaza el segundo
    INSERT con 23505; se releé en vez de propagar el error, mismo patrón que
    _crear_dia_si_no_existe en de_confianza.py."""
    existente = _ausencia_existente(db, persona_id, fecha_iso)
    if existente:
        return "ausencia_pendiente" if existente["estado_autorizacion"] == "pendiente" else "ausencia_resuelta"

    try:
        db.postgrest.schema("tiempo").table("ausencia").insert(
            {
                "persona_id": persona_id,
                "tipo_de_ausencia": "falta",
                "fecha_inicio": fecha_iso,
                "fecha_fin": fecha_iso,
                "estado_autorizacion": "pendiente",
            }
        ).execute()
        return "ausencia_creada"
    except APIError as error:
        if error.code != UNIQUE_VIOLATION:
            raise
        existente = _ausencia_existente(db, persona_id, fecha_iso)
        return "ausencia_pendiente" if existente and existente["estado_autorizacion"] == "pendiente" else "ausencia_resuelta"


def _crear_tramo(db: Client, dia_id: int, apertura: dict, cierre: dict | None) -> float | None:
    fin_iso = cierre["efectivo"].isoformat() if cierre else None
    minutos = (
        (cierre["efectivo"] - apertura["efectivo"]).total_seconds() / 60.0 if cierre else None
    )
    db.postgrest.schema("tiempo").table("tramo").insert(
        {
            "dia_id": dia_id,
            "marca_apertura_id": apertura["id"],
            "marca_cierre_id": cierre["id"] if cierre else None,
            "inicio": apertura["efectivo"].isoformat(),
            "fin": fin_iso,
            "minutos_trabajados": minutos,
        }
    ).execute()
    return minutos


def _resolver_descuento_pausa_no_registrada(db: Client, fecha_iso: str) -> int:
    """Molde exacto de dias_habiles.py::_dias_habiles_limite -- resolución de una sola fecha
    (el batch corre fecha por fecha, no hace falta la variante batch de alertas_horario.py).
    Fail-open no aplica acá (no envuelto en try/except): db ya es el service_role del batch, no
    una llamada de red aparte -- si Supabase no responde, el batch entero ya está fallando."""
    filas = (
        db.postgrest.schema("tiempo")
        .table("parametro")
        .select("valor")
        .eq("clave", "descuento_pausa_no_registrada_min")
        .lte("vigente_desde", fecha_iso)
        .order("vigente_desde", desc=True)
        .limit(1)
        .execute()
        .data
    )
    if not filas:
        return DESCUENTO_PAUSA_POR_DEFECTO_MIN
    return int(filas[0]["valor"])


def _armar_dia_par(db: Client, persona_id: str, fecha_iso: str, marcas: list[dict]) -> None:
    dia = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .insert({"persona_id": persona_id, "fecha": fecha_iso, "estado": "cerrado"})
        .execute()
        .data[0]
    )

    total_minutos = 0.0
    for apertura, cierre in zip(marcas[0::2], marcas[1::2]):
        total_minutos += _crear_tramo(db, dia["id"], apertura, cierre)

    if len(marcas) == 2:
        # Un solo tramo: entró una vez, salió una vez, nunca marcó la pausa -- se asume que
        # ocurrió sin registrarse y se descuenta un fijo. Con 2+ tramos no hace falta (la pausa
        # sí quedó registrada, es el hueco entre tramos) -- ni siquiera se dispara la consulta.
        descuento_min = _resolver_descuento_pausa_no_registrada(db, fecha_iso)
        total_minutos = max(0.0, total_minutos - descuento_min)

    db.postgrest.schema("tiempo").table("dia").update({"horas_totales": total_minutos / 60.0}).eq(
        "id", dia["id"]
    ).execute()


def _armar_dia_impar(db: Client, persona_id: str, fecha_iso: str, marcas: list[dict]) -> None:
    dia = (
        db.postgrest.schema("tiempo")
        .table("dia")
        .insert({"persona_id": persona_id, "fecha": fecha_iso, "estado": "bloqueado"})
        .execute()
        .data[0]
    )

    completos = marcas[:-1]
    abierto = marcas[-1]
    for apertura, cierre in zip(completos[0::2], completos[1::2]):
        _crear_tramo(db, dia["id"], apertura, cierre)
    _crear_tramo(db, dia["id"], abierto, None)

    # horas_totales se deja NULL a propósito -- ver docstring del módulo (SCJ-PRA-01 #14).
    db.postgrest.schema("tiempo").table("excepcion").insert(
        {"dia_id": dia["id"], "marca_id": None, "motivo_revision": MOTIVO_PARIDAD_IMPAR}
    ).execute()


def ejecutar_cierre_dia(fecha: date, db: Client | None = None) -> dict:
    """SCJ-PRO-12 A1-K3. Si no se pasa un cliente ya armado, arma uno de service_role propio
    (mismo criterio que ejecutar_batch_de_confianza). Una persona que revienta no detiene a las
    demás -- se captura por persona y sigue con las siguientes."""
    if db is None:
        db = get_service_client(get_settings())

    fecha_iso = fecha.isoformat()
    corrida = upsert_corrida_en_progreso(db, TIPO_BATCH, fecha_iso)

    es_no_laborable = fecha.weekday() == DOMINGO or _es_festivo(db, fecha_iso)

    contadores = {
        "cerrado": 0,
        "bloqueado": 0,
        "ausencia_creada": 0,
        "ausencia_pendiente": 0,
        "ausencia_resuelta": 0,
        "saltada": 0,
    }
    errores: list[str] = []

    for persona_id in _personas_normal_flexible_vigentes(db, fecha_iso):
        try:
            if _dia_ya_resuelto(db, persona_id, fecha_iso):
                contadores["saltada"] += 1
                continue
            if es_no_laborable:
                contadores["saltada"] += 1
                continue

            marcas = _marcas_efectivas_del_dia(db, persona_id, fecha)
            if not marcas:
                contadores[_resolver_sin_marcas(db, persona_id, fecha_iso)] += 1
            elif len(marcas) % 2 == 0:
                _armar_dia_par(db, persona_id, fecha_iso, marcas)
                contadores["cerrado"] += 1
            else:
                _armar_dia_impar(db, persona_id, fecha_iso, marcas)
                contadores["bloqueado"] += 1
        except Exception as error:  # noqa: BLE001 -- por diseño: aislar la falla de una persona
            errores.append(f"{persona_id}: {error}")

    resumen = (
        f"{contadores['cerrado']} cerrado(s), {contadores['bloqueado']} bloqueado(s), "
        f"{contadores['ausencia_creada']} ausencia(s) creada(s), {contadores['saltada']} "
        f"saltada(s)"
    )
    if errores:
        logger.error("cierre_dia fecha=%s errores=%s", fecha_iso, errores)
        detalle = f"{resumen}, {len(errores)} error(es) -- ver logs del servidor."
        estado_final = "fallida"
    else:
        detalle = f"{resumen}."
        estado_final = "exitosa"

    return finalizar_corrida(db, corrida["id"], estado_final, detalle)
