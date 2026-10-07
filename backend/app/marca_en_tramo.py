"""¿La marca ya forma parte de un tramo? Entonces una corrección de su hora NO se puede hacer desde la
API: o falla, o se guarda sin reflejarse en las horas.

`fn_correccion_recalcula_tramo` (AFTER INSERT en tiempo.correccion) es SECURITY INVOKER: su UPDATE de
`tiempo.tramo` pasa por la RLS del usuario (ensayo real de db, BEGIN…ROLLBACK):
- Tramo CERRADO (`marca_cierre_id` NOT NULL), o de un día `cerrado`/`revisado`: `tramo_update_revision`
  (USING `marca_cierre_id IS NULL`) y `dia_update_revision` (USING estado bloqueado/cerrado) hacen que el
  UPDATE afecte 0 filas EN SILENCIO: la corrección se guarda en `tiempo.correccion` pero el tramo conserva
  la hora vieja, y el corte quincenal y el banco de horas (que suman `tramo.minutos_trabajados`) usan la
  vieja. -> 'en_tramo_cerrado'.
- Tramo ABIERTO (`marca_cierre_id` NULL, p. ej. un día bloqueado con una sola marca): el UPDATE falla con
  42501 por el WITH CHECK de `tramo_update_revision` y la corrección entera se rechaza; no hay forma de
  corregirla por la API. -> 'en_tramo'.
Por eso se bloquea ANTES de insertar, con un mensaje claro, en vez de dejar que llegue como un 42501 que
parecería falta de permiso.

Qué cliente: se llama con el cliente de `service_role` (`get_service_client`), NO con el del caller. Es una lectura de
insumo para decidir, no una autorización: la RLS de `tiempo.tramo`/`tiempo.dia` no garantiza lectura a quien
tiene `correccion_edicion` y, con el cliente del caller, un permiso faltante devolvería 0 filas y el guard no
bloquearía (fail-open: la corrección se guardaría sin reflejarse). Sólo filtra por ids enteros ya validados
y devuelve únicamente {marca_id: motivo}; no expone datos de tramos ni de días (mismo criterio de los dos
clientes que `banco_de_horas.py`).

Consecuencia de producto: con 87_*.sql la base también lo rechaza (BEFORE INSERT en tiempo.correccion, SCJ15 /
marca_en_tramo), y como cierre_dia arma los tramos de casi todas las marcas, casi ninguna marca es corregible por
esta vía después del cierre. La UI debe explicarlo ("esta marca ya está en un tramo: revisa el día o usa captura
manual"). Este guard es la primera línea (mensaje claro sin depender de un error de la base).

Criterio (decisión del usuario, opción A + ensayo de db): sólo se corrige una marca que NO está en ningún
tramo (día abierto/bloqueado sin tramos armados)."""

from supabase import Client

ESTADOS_DIA_CERRADOS = ("cerrado", "revisado")

EN_TRAMO = "en_tramo"
EN_TRAMO_CERRADO = "en_tramo_cerrado"


def _estado_del_dia(fila: dict) -> str | None:
    dia = fila.get("dia")
    if isinstance(dia, list):
        dia = dia[0] if dia else None
    return dia.get("estado") if isinstance(dia, dict) else None


def bloqueo_por_tramo(db_servicio: Client, marca_ids: list[int]) -> dict[int, str]:
    """{marca_id: 'en_tramo_cerrado' | 'en_tramo'} sólo para las marcas de `marca_ids` que son marca_apertura
    o marca_cierre de ALGÚN tramo; las demás no aparecen. UNA sola consulta a tiempo.tramo (con el estado del
    día embebido) sin importar cuántas marcas se pregunten; nada si la lista viene vacía."""
    marca_ids = sorted({int(i) for i in marca_ids})  # int(): el filtro or_ se arma con texto
    if not marca_ids:
        return {}
    lista = ",".join(str(i) for i in marca_ids)
    filas = (
        db_servicio.postgrest.schema("tiempo")
        .table("tramo")
        .select("marca_apertura_id, marca_cierre_id, dia:dia_id!inner(estado)")
        .or_(f"marca_apertura_id.in.({lista}),marca_cierre_id.in.({lista})")
        .execute()
        .data
    )
    pedidas = set(marca_ids)
    resultado: dict[int, str] = {}
    for fila in filas:
        cerrado = fila.get("marca_cierre_id") is not None or (
            _estado_del_dia(fila) in ESTADOS_DIA_CERRADOS
        )
        motivo = EN_TRAMO_CERRADO if cerrado else EN_TRAMO
        for marca_id in (fila.get("marca_apertura_id"), fila.get("marca_cierre_id")):
            if marca_id in pedidas:
                resultado[marca_id] = motivo
    return resultado
