"""API de tiempo.banco_de_horas / tiempo.movimiento_de_saldo -- SCJ-DEC-02/SCJ-PRO-13.
monto/vivo_desde de tiempo.banco_de_horas son materializados por trigger
(fn_movimiento_de_saldo_actualiza_banco), nadie los edita a mano -- este router sigue siendo de
sólo lectura.

Este corte suma el desglose de antigüedad del saldo (0-V/2, V/2-V, V+ meses, V = ventana_banco_meses;
6 es sólo el valor de ejemplo sembrado) reconstruido en memoria desde el ledger tiempo.movimiento_de_saldo
(app/banco_antiguedad.py) -- sin migración nueva, vivo_desde no alcanza para distinguir horas
viejas de horas nuevas dentro de la misma persona.

Segundo eje de alerta (SCJ-ESP-01 §VI.6, este corte, sin DDL nueva): MAGNITUD de la deuda como %
de la jornada semanal de la persona (app/banco_alertas_magnitud.py) -- independiente del eje de
antigüedad de arriba. jornada_semanal_horas/porcentaje_jornada_semanal/nivel_alerta son `None`
para quien no tiene jornada normal/flexible vigente (de_confianza incluida, no maneja banco de
horas) -- nunca 0.0, no hay "0% de nada" que mostrar.

Cambio de postura respecto del corte anterior: de get_caller_client a get_service_client para el
dato, sumando el gate explícito del ledger. Con get_caller_client, alguien con
banco_de_horas_lectura pero SIN permiso sobre el ledger vería `[]` de movimientos y toda la
antigüedad en cero SIN error -- falla silenciosa. Con service_role + los dos permisos exigidos
explícitamente (AND entre grupos, OR dentro de cada uno), la autorización es real y visible,
mismo patrón que tramos.py/dias.py.

**Filtro/orden/paginación de tramo_antiguedad se hacen EN MEMORIA** (a diferencia de
busqueda_persona, que sigue resolviéndose server-side contra personas.persona): el desglose no es
una columna real de tiempo.banco_de_horas, se deriva del ledger completo -- no hay forma de
pedirle a PostgREST un `.range()`/`.order()` sobre algo que no existe como columna. Se trae la
tabla de saldos completa + los movimientos de quienes tienen monto > 0, se calcula FIFO una vez, y
recién ahí se filtra/ordena/pagina. Volumen esperado bajo (2 movimientos/persona/mes) -- no
justifica una vista materializada todavía. El `resumen` (métricas globales + top-8 en deuda)
se calcula sobre TODAS las personas, antes de aplicar busqueda_persona/tramo_antiguedad -- son
"la foto completa del banco", no deberían cambiar porque alguien filtró la tabla.

`corte_pendiente` (alerta preventiva, sin DDL nueva): reusa `_procesar_persona(...,
solo_simular=True)` de `batches/corte_quincenal.py` para simular, EN CADA `GET`, si el corte del
último periodo ya vencido se aplicó de verdad para cada persona normal/flexible -- mismo trabajo
que haría el batch real, sin escribir nada. A la escala actual (decenas de personas) es aceptable
correrlo por request; no se cachea en este corte. Personas con corte pendiente que todavía no
tienen fila real en `tiempo.banco_de_horas` aparecen como fila sintética (monto=0,
actualizado_en=None) -- así RH las ve en la pantalla aunque el trigger nunca las haya tocado."""

from datetime import date, datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app.banco_alertas_magnitud import (
    clasificar_nivel_deuda,
    resolver_jornadas_semanales,
    resolver_umbrales_pct,
)
from app.banco_antiguedad import (
    ResultadoAntiguedad,
    calcular_antiguedad_saldo,
    calcular_lotes,
    resolver_ventana_meses,
)
from app.batches.corte_quincenal import _festivos_del_periodo, resolver_ultimo_periodo_vencido
from app.deps import get_caller_client, get_service_client
from app.permisos import requiere_permiso
from app.prevision_corte_quincenal import resolver_personas_con_corte_pendiente
from app.schemas.banco_de_horas import (
    BancoDeHorasListaOut,
    MovimientoSaldoCrear,
    MovimientoSaldoListaOut,
)

router = APIRouter(prefix="/api/banco-de-horas", tags=["banco-de-horas"])

LIMITE_DEFECTO = 50
LIMITE_MAXIMO = 200

TOP_EN_DEUDA_CANTIDAD = 8

CODIGO_TIPO_NO_PERMITIDO = "SCJ01"
CODIGO_MONTO_INVALIDO = "SCJ02"
CODIGO_PERSONA_SIN_BANCO = "SCJ03"
CODIGO_MONTO_EXCEDE_SALDO = "SCJ04"

MENSAJE_PERSONA_SIN_BANCO = "Esta persona no tiene banco de horas."
MENSAJE_MONTO_EXCEDE_SALDO = "El monto excede el saldo total de esta persona."
MENSAJE_MONTO_EXCEDE_FUERA_VENTANA = (
    "El monto excede la porción de deuda con {meses}+ meses de antigüedad de esta persona ({horas} h)."
)

ORDEN_A_CLAVE = {
    "monto_desc": (lambda item: item["monto"], True),
    "monto_asc": (lambda item: item["monto"], False),
    "antiguedad_desc": (lambda item: item["meses_antiguedad_max"], True),
    "antiguedad_asc": (lambda item: item["meses_antiguedad_max"], False),
}


def _resolver_ids_por_busqueda(db: Client, busqueda: str) -> list[str]:
    """Mismo molde que tramos.py/dias.py::_resolver_ids_por_busqueda."""
    filtro = f"primer_nombre.ilike.%{busqueda}%,apellido_paterno.ilike.%{busqueda}%,apellido_materno.ilike.%{busqueda}%"
    filas = (
        db.postgrest.schema("personas")
        .table("persona")
        .select("id")
        .or_(filtro)
        .execute()
        .data
    )
    return [fila["id"] for fila in filas]


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


def _resolver_movimientos_por_banco(db: Client, banco_ids: list[int]) -> dict[int, list[dict]]:
    """Sólo de bancos con monto > 0 -- quien no debe nada no tiene lotes que reconstruir
    (calcular_antiguedad_saldo ya corta ese caso antes de necesitar el ledger)."""
    if not banco_ids:
        return {}
    filas = (
        db.postgrest.schema("tiempo")
        .table("movimiento_de_saldo")
        .select("id, banco_de_horas_id, creado_en, monto")
        .in_("banco_de_horas_id", banco_ids)
        .execute()
        .data
    )
    por_banco: dict[int, list[dict]] = {}
    for fila in filas:
        por_banco.setdefault(fila["banco_de_horas_id"], []).append(fila)
    return por_banco


def _resultado_a_dict(resultado: ResultadoAntiguedad) -> dict:
    return {
        "horas_reciente": resultado.horas_reciente,
        "horas_media": resultado.horas_media,
        "horas_fuera_ventana": resultado.horas_fuera_ventana,
        "meses_antiguedad_max": resultado.meses_antiguedad_max,
        "conciliado": resultado.conciliado,
    }


def _resolver_personas_con_corte_pendiente(db_servicio: Client, hoy: datetime) -> set[str]:
    periodo_desde, periodo_hasta = resolver_ultimo_periodo_vencido(hoy.date())
    periodo_desde_iso = periodo_desde.isoformat()
    periodo_hasta_iso = periodo_hasta.isoformat()
    festivos = _festivos_del_periodo(db_servicio, periodo_desde_iso, periodo_hasta_iso)
    return resolver_personas_con_corte_pendiente(
        db_servicio, periodo_desde, periodo_hasta, periodo_desde_iso, periodo_hasta_iso, festivos
    )


def _campos_alerta_magnitud(
    monto: float, jornada_semanal_horas: float | None, aviso_pct: int, escalamiento_pct: int
) -> dict:
    porcentaje = None
    if jornada_semanal_horas is not None and jornada_semanal_horas > 0:
        porcentaje = round(monto / jornada_semanal_horas * 100, 1)
    return {
        "jornada_semanal_horas": jornada_semanal_horas,
        "porcentaje_jornada_semanal": porcentaje,
        "nivel_alerta": clasificar_nivel_deuda(
            monto, jornada_semanal_horas, aviso_pct, escalamiento_pct
        ),
    }


def _fila_sintetica_corte_pendiente(
    persona_id: str,
    persona_nombre: str | None,
    jornada_semanal_horas: float | None,
    aviso_pct: int,
    escalamiento_pct: int,
) -> dict:
    """Persona con corte pendiente que todavía no tiene fila real en tiempo.banco_de_horas (el
    trigger nunca la tocó) -- se muestra igual, en 0, para que RH la vea. monto=0.0 -> nivel_alerta
    siempre "sin_alerta" si tiene jornada resuelta (0% nunca alcanza ningún umbral), None si no."""
    return {
        "persona_id": persona_id,
        "persona_nombre": persona_nombre,
        "monto": 0.0,
        "vivo_desde": None,
        "actualizado_en": None,
        "horas_reciente": 0.0,
        "horas_media": 0.0,
        "horas_fuera_ventana": 0.0,
        "meses_antiguedad_max": 0,
        "conciliado": True,
        "corte_pendiente": True,
        **_campos_alerta_magnitud(0.0, jornada_semanal_horas, aviso_pct, escalamiento_pct),
    }


def _armar_saldos_completos(db_servicio: Client, hoy: datetime) -> tuple[list[dict], int, int, int]:
    """Toda la tabla banco_de_horas, enriquecida con nombre + desglose de antigüedad + alerta de
    magnitud, más la alerta de corte_pendiente -- base tanto del `resumen` como de `saldos`
    (filtrado/ordenado/paginado después, en memoria)."""
    fecha_iso = date.today().isoformat()
    ventana_meses = resolver_ventana_meses(db_servicio, fecha_iso)
    aviso_pct, escalamiento_pct = resolver_umbrales_pct(db_servicio, fecha_iso)
    filas = (
        db_servicio.postgrest.schema("tiempo")
        .table("banco_de_horas")
        .select("id, persona_id, monto, vivo_desde, actualizado_en")
        .execute()
        .data
    )
    pendientes = _resolver_personas_con_corte_pendiente(db_servicio, hoy)

    if not filas and not pendientes:
        return [], ventana_meses, aviso_pct, escalamiento_pct

    banco_ids_con_deuda = [fila["id"] for fila in filas if float(fila["monto"]) > 0]
    movimientos_por_banco = _resolver_movimientos_por_banco(db_servicio, banco_ids_con_deuda)

    persona_ids_reales = {fila["persona_id"] for fila in filas}
    persona_ids_sinteticas = sorted(pendientes - persona_ids_reales)
    persona_ids_todas = [fila["persona_id"] for fila in filas] + persona_ids_sinteticas
    nombres = _resolver_nombres_persona(db_servicio, persona_ids_todas)
    jornadas = resolver_jornadas_semanales(db_servicio, persona_ids_todas, fecha_iso)

    saldos: list[dict] = []
    for fila in filas:
        vivo_desde = (
            datetime.fromisoformat(fila["vivo_desde"]) if fila["vivo_desde"] is not None else None
        )
        resultado = calcular_antiguedad_saldo(
            movimientos_por_banco.get(fila["id"], []),
            float(fila["monto"]),
            vivo_desde,
            ventana_meses,
            hoy,
        )
        saldos.append(
            {
                "persona_id": fila["persona_id"],
                "persona_nombre": nombres.get(fila["persona_id"]),
                "monto": float(fila["monto"]),
                "vivo_desde": fila["vivo_desde"],
                "actualizado_en": fila["actualizado_en"],
                **_resultado_a_dict(resultado),
                "corte_pendiente": fila["persona_id"] in pendientes,
                **_campos_alerta_magnitud(
                    float(fila["monto"]),
                    jornadas.get(fila["persona_id"]),
                    aviso_pct,
                    escalamiento_pct,
                ),
            }
        )

    for persona_id in persona_ids_sinteticas:
        saldos.append(
            _fila_sintetica_corte_pendiente(
                persona_id, nombres.get(persona_id), jornadas.get(persona_id), aviso_pct, escalamiento_pct
            )
        )

    return saldos, ventana_meses, aviso_pct, escalamiento_pct


def _armar_resumen(
    saldos_completos: list[dict], ventana_meses: int, aviso_pct: int, escalamiento_pct: int
) -> dict:
    en_deuda = [item for item in saldos_completos if item["monto"] > 0]
    fuera_ventana = [item for item in saldos_completos if item["horas_fuera_ventana"] > 0]
    corte_pendiente = [item for item in saldos_completos if item["corte_pendiente"]]
    en_aviso = [item for item in saldos_completos if item["nivel_alerta"] == "aviso"]
    en_escalamiento = [item for item in saldos_completos if item["nivel_alerta"] == "escalamiento"]
    top = sorted(en_deuda, key=lambda item: item["monto"], reverse=True)[:TOP_EN_DEUDA_CANTIDAD]
    return {
        "total_personas": len(saldos_completos),
        "en_deuda": len(en_deuda),
        "sin_deuda": len(saldos_completos) - len(en_deuda),
        "horas_adeudadas": round(sum(item["monto"] for item in en_deuda), 2),
        "horas_fuera_ventana": round(sum(item["horas_fuera_ventana"] for item in fuera_ventana), 2),
        "personas_fuera_ventana": len(fuera_ventana),
        "personas_corte_pendiente": len(corte_pendiente),
        "personas_en_aviso": len(en_aviso),
        "personas_en_escalamiento": len(en_escalamiento),
        "ventana_meses": ventana_meses,
        "aviso_pct": aviso_pct,
        "escalamiento_pct": escalamiento_pct,
        "top_en_deuda": [
            {
                "persona_id": item["persona_id"],
                "persona_nombre": item["persona_nombre"],
                "monto": item["monto"],
                "meses_antiguedad_max": item["meses_antiguedad_max"],
            }
            for item in top
        ],
    }


@router.get("", response_model=BancoDeHorasListaOut)
def listar_banco_de_horas(
    db_servicio: Client = Depends(get_service_client),
    _permiso_banco: None = Depends(requiere_permiso("banco_de_horas_lectura")),
    _permiso_ledger: None = Depends(
        requiere_permiso("movimiento_de_saldo_lectura", "movimiento_de_saldo_edicion")
    ),
    busqueda_persona: str | None = Query(None, description="Texto libre sobre el nombre."),
    tramo_antiguedad: Literal["reciente", "media", "fuera_ventana"] | None = Query(None),
    nivel_alerta: Literal["sin_alerta", "aviso", "escalamiento"] | None = Query(None),
    orden: Literal["monto_desc", "monto_asc", "antiguedad_desc", "antiguedad_asc"] = Query(
        "monto_desc"
    ),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    hoy = datetime.now(timezone.utc)
    saldos_completos, ventana_meses, aviso_pct, escalamiento_pct = _armar_saldos_completos(
        db_servicio, hoy
    )
    resumen = _armar_resumen(saldos_completos, ventana_meses, aviso_pct, escalamiento_pct)

    filtrados = saldos_completos
    if busqueda_persona is not None:
        persona_ids = set(_resolver_ids_por_busqueda(db_servicio, busqueda_persona))
        filtrados = [item for item in filtrados if item["persona_id"] in persona_ids]

    campo_tramo = {
        "reciente": "horas_reciente",
        "media": "horas_media",
        "fuera_ventana": "horas_fuera_ventana",
    }
    if tramo_antiguedad is not None:
        filtrados = [item for item in filtrados if item[campo_tramo[tramo_antiguedad]] > 0]

    if nivel_alerta is not None:
        filtrados = [item for item in filtrados if item["nivel_alerta"] == nivel_alerta]

    clave, descendente = ORDEN_A_CLAVE[orden]
    filtrados = sorted(filtrados, key=clave, reverse=descendente)

    total = len(filtrados)
    saldos = filtrados[desplazamiento : desplazamiento + limite]
    return {"total": total, "resumen": resumen, "saldos": saldos}


def _armar_ledger_de_persona(db: Client, persona_id: str) -> dict:
    """Ledger completo de una persona -- más reciente primero (mismo criterio que marcas.py).
    saldo_corrido es el acumulado hasta ese movimiento (incluido). vivo indica si ese movimiento
    todavía tiene lote sin consumir (reusa calcular_lotes, no una cuenta aparte). Compartido por
    GET /{persona_id}/movimientos y POST /{persona_id}/movimientos -- después de insertar, el
    POST vuelve a armar el ledger completo así el frontend reemplaza su caché sin un segundo
    fetch."""
    banco = (
        db.postgrest.schema("tiempo")
        .table("banco_de_horas")
        .select("id")
        .eq("persona_id", persona_id)
        .execute()
        .data
    )
    if not banco:
        return {"total": 0, "movimientos": []}

    banco_id = banco[0]["id"]
    filas = (
        db.postgrest.schema("tiempo")
        .table("movimiento_de_saldo")
        .select("id, tipo, monto, motivo, autor_id, creado_en")
        .eq("banco_de_horas_id", banco_id)
        .execute()
        .data
    )
    if not filas:
        return {"total": 0, "movimientos": []}

    ordenadas_asc = sorted(filas, key=lambda fila: (fila["creado_en"], fila["id"]))
    lotes_vivos = calcular_lotes(ordenadas_asc)
    ids_vivos = {lote.movimiento_id for lote in lotes_vivos}

    saldo_corrido = 0.0
    saldo_por_id: dict[int, float] = {}
    for fila in ordenadas_asc:
        saldo_corrido = round(saldo_corrido + float(fila["monto"]), 2)
        saldo_por_id[fila["id"]] = saldo_corrido

    autor_ids = sorted({fila["autor_id"] for fila in filas if fila["autor_id"] is not None})
    nombres_autor = _resolver_nombres_persona(db, autor_ids)

    movimientos = [
        {
            "id": fila["id"],
            "creado_en": fila["creado_en"],
            "tipo": fila["tipo"],
            "monto": float(fila["monto"]),
            "motivo": fila["motivo"],
            "autor_nombre": nombres_autor.get(fila["autor_id"]) if fila["autor_id"] else None,
            "saldo_corrido": saldo_por_id[fila["id"]],
            "vivo": fila["id"] in ids_vivos,
        }
        for fila in sorted(filas, key=lambda fila: fila["creado_en"], reverse=True)
    ]
    return {"total": len(movimientos), "movimientos": movimientos}


@router.get("/{persona_id}/movimientos", response_model=MovimientoSaldoListaOut)
def listar_movimientos_de_persona(
    persona_id: str,
    db_servicio: Client = Depends(get_service_client),
    _permiso_banco: None = Depends(requiere_permiso("banco_de_horas_lectura")),
    _permiso_ledger: None = Depends(
        requiere_permiso("movimiento_de_saldo_lectura", "movimiento_de_saldo_edicion")
    ),
) -> dict:
    return _armar_ledger_de_persona(db_servicio, persona_id)


@router.post("/{persona_id}/movimientos", response_model=MovimientoSaldoListaOut)
def registrar_movimiento_manual(
    persona_id: str,
    datos: MovimientoSaldoCrear,
    db: Client = Depends(get_caller_client),
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_permiso("movimiento_de_saldo_edicion")),
) -> dict:
    """Alta manual (arrastrar/descontar/condonar, db/ddl/68_*.sql).

    2 clientes distintos, a propósito -- misma separación que las 2 capas de validación del
    monto: uno para LEER (insumo de esta validación, no autoriza nada) y otro para ESCRIBIR (ahí
    sí importa quién es, RLS real):
    - `db_servicio` (service_role) para toda lectura previa (banco_de_horas + movimiento_de_saldo,
      acá y en la reconstrucción del ledger de la respuesta): la policy de SELECT de
      `banco_de_horas` exige específicamente `banco_de_horas_lectura` (sin OR con
      `movimiento_de_saldo_edicion` -- no existe `banco_de_horas_edicion` en el catálogo). Hoy los
      3 puestos con `movimiento_de_saldo_edicion` también tienen `banco_de_horas_lectura`
      mapeado, pero el endpoint no debería depender de que seguirán acopladas -- si algún día se
      desacoplan, con `get_caller_client` esto fallaría con un 404 falso en vez de la validación
      real (mismo tipo de fragilidad ya corregido una vez en RLS de Estructura Organizacional,
      ver CLAUDE.md).
    - `db` (el caller) SÓLO para el RPC `fn_movimiento_de_saldo_manual_registrar` -- la policy
      `movimiento_de_saldo_insert_manual` (RLS) es la autorización real de la escritura, tiene que
      correr como quien realmente está haciendo el cambio (exige `autor_id = caller`).

    Validación en 2 capas, a propósito:
    1. FINA, acá en Python, ANTES de llamar al RPC: recalcula el desglose de antigüedad de la
       persona ahora mismo (nunca confía en nada cacheado del frontend, mismo FIFO que
       _armar_saldos_completos vía banco_antiguedad.calcular_antiguedad_saldo) y rechaza si el
       monto pedido excede la porción con ventana_banco_meses+ meses de antigüedad
       (horas_fuera_ventana) -- el RPC no puede hacer esta cuenta, no tiene el FIFO reconstruido.
    2. GRUESA, dentro del RPC (ERRCODE SCJ04): backstop contra el saldo TOTAL, por si algo llega
       a invocar el RPC directo sin pasar por este endpoint. En la práctica la capa 1 debería
       atajar casi todos los casos antes de llegar acá."""
    banco = (
        db_servicio.postgrest.schema("tiempo")
        .table("banco_de_horas")
        .select("id, monto, vivo_desde")
        .eq("persona_id", persona_id)
        .execute()
        .data
    )
    if not banco:
        raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PERSONA_SIN_BANCO)

    fila_banco = banco[0]
    movimientos = (
        db_servicio.postgrest.schema("tiempo")
        .table("movimiento_de_saldo")
        .select("id, creado_en, monto")
        .eq("banco_de_horas_id", fila_banco["id"])
        .execute()
        .data
    )
    ventana_meses = resolver_ventana_meses(db_servicio, date.today().isoformat())
    vivo_desde = (
        datetime.fromisoformat(fila_banco["vivo_desde"])
        if fila_banco["vivo_desde"] is not None
        else None
    )
    resultado = calcular_antiguedad_saldo(
        movimientos, float(fila_banco["monto"]), vivo_desde, ventana_meses, datetime.now(timezone.utc)
    )
    if datos.monto > resultado.horas_fuera_ventana:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            MENSAJE_MONTO_EXCEDE_FUERA_VENTANA.format(
                meses=ventana_meses, horas=resultado.horas_fuera_ventana
            ),
        )

    try:
        db.postgrest.schema("tiempo").rpc(
            "fn_movimiento_de_saldo_manual_registrar",
            {
                "p_persona_id": persona_id,
                "p_tipo": datos.tipo,
                "p_monto": datos.monto,
                "p_motivo": datos.motivo,
            },
        ).execute()
    except APIError as error:
        if error.code in (CODIGO_TIPO_NO_PERMITIDO, CODIGO_MONTO_INVALIDO):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error
        if error.code == CODIGO_PERSONA_SIN_BANCO:
            raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_PERSONA_SIN_BANCO) from error
        if error.code == CODIGO_MONTO_EXCEDE_SALDO:
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_MONTO_EXCEDE_SALDO) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    return _armar_ledger_de_persona(db_servicio, persona_id)
