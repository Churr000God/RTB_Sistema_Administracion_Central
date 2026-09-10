"""API de tiempo.dia (pantalla de sólo lectura + la única transición manual que permite
SCJ-DEC-06: bloqueado -> revisado). tiempo.dia nunca tuvo pantalla propia -- sólo se leía desde
adentro del sistema (alertas_de_retardo.py, tope_legal.py, el embed de tramos.py) y la escriben
los batches con service_role. Este router suma la primera pieza de escritura humana sobre esta
tabla (db/ddl/62_tiempo_dia_revision.sql: columnas de auditoría + permiso dia_revision_edicion +
policy de UPDATE + RPC fn_dia_revisar).

GET /api/dias usa get_service_client + requiere_todos_los_permisos("dia_lectura",
"marca_lectura") -- el AND es a propósito: con service_role la RLS de tiempo.marca/
tiempo.correccion queda bypasseada, y esta pantalla expone horas de marca reales derivadas de
ambas -- el gate es el único control ahí. Los 3 puestos (RH, Gerencia General, TI) ya tienen los
dos códigos, no cierra ninguna puerta real.

POST /api/dias/{dia_id}/revisar usa get_caller_client (NUNCA service_role) +
requiere_permiso("dia_revision_edicion") -- la policy dia_update_revision (RLS) es la
autorización real, este 403 sólo da un mensaje legible antes de llegar a la BD."""

from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from postgrest.exceptions import APIError
from supabase import Client

from app import alertas_horario
from app.deps import get_caller_client, get_service_client
from app.permisos import requiere_permiso, requiere_todos_los_permisos
from app.prevision_corte_quincenal import resolver_dias_faltantes, resolver_periodo_en_curso
from app.schemas.dias import (
    DiaListaOut,
    DiaPrevisualizacionOut,
    DiaRevisadoOut,
    DiaRevisarRequest,
    DiasFaltantesOut,
)

router = APIRouter(prefix="/api/dias", tags=["dias"])

LIMITE_DEFECTO = 50
LIMITE_MAXIMO = 200

CODIGO_DIA_NO_ENCONTRADO = "SCJ06"
CODIGO_DIA_NO_BLOQUEADO = "SCJ07"
CODIGO_HORAS_INVALIDAS = "SCJ08"
CODIGO_HUERFANA_SIN_PAREJA = "SCJ09"

MENSAJE_DIA_NO_ENCONTRADO = "El día no existe."
MENSAJE_DIA_NO_BLOQUEADO = (
    "Este día ya no está bloqueado -- alguien más se te adelantó, o nunca lo estuvo."
)
MENSAJE_HORAS_INVALIDAS = "Horas trabajadas inválidas -- debe estar entre 0 y 24."
MENSAJE_HUERFANA_SIN_PAREJA = (
    "Este día tiene una marca sin pareja -- corregí la marca faltante o usá captura manual antes "
    "de revisar."
)

ACCIONES_TRAMO_CON_HORAS = ("cerrar_existente", "nuevo")
ACCION_HUERFANA_SIN_PAREJA = "huerfana_sin_pareja"

SELECT_DIA = "id, persona_id, fecha, estado, horas_totales, origen"

ORDEN_A_COLUMNA: dict[str, tuple[str, bool]] = {
    "fecha_desc": ("fecha", True),
    "fecha_asc": ("fecha", False),
    "horas_desc": ("horas_totales", True),
    "horas_asc": ("horas_totales", False),
}


def _resolver_ids_por_busqueda(db: Client, busqueda: str) -> list[str]:
    """Texto libre sobre primer_nombre/apellido_paterno/apellido_materno -- mismo molde que
    tramos.py::_resolver_ids_por_busqueda."""
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


def _resolver_excepciones_pendientes(
    db_servicio: Client, marcas_por_dia: dict[tuple[str, date], dict], dia_ids: list[int]
) -> tuple[dict[tuple[str, date], int], dict[int, int]]:
    """Guía sin bloquear nada (SCJ-PRO-08/10/11 siguen su curso normal, revisar un día no exige
    resolverlas primero) -- dos consultas batch a tiempo.excepcion, mutuamente excluyentes por
    diseño (ck_excepcion_marca_o_dia): las que cuelgan de una marca (persona_inactiva,
    dia_cerrado, fuera_de_horario, ...) y las que cuelgan del día directo (paridad_impar, sin
    marca_id, SCJ-PRO-08). Se cuentan por separado acá; el llamador suma las dos por fila."""
    todos_los_marca_ids = sorted(
        {marca_id for bucket in marcas_por_dia.values() for marca_id in bucket["marca_ids"]}
    )
    por_marca: dict[int, int] = {}
    if todos_los_marca_ids:
        filas = (
            db_servicio.postgrest.schema("tiempo")
            .table("excepcion")
            .select("marca_id")
            .in_("marca_id", todos_los_marca_ids)
            .eq("estado", "pendiente")
            .execute()
            .data
        )
        for fila in filas:
            por_marca[fila["marca_id"]] = por_marca.get(fila["marca_id"], 0) + 1

    por_dia_directo: dict[int, int] = {}
    if dia_ids:
        filas = (
            db_servicio.postgrest.schema("tiempo")
            .table("excepcion")
            .select("dia_id")
            .in_("dia_id", dia_ids)
            .eq("estado", "pendiente")
            .execute()
            .data
        )
        for fila in filas:
            por_dia_directo[fila["dia_id"]] = por_dia_directo.get(fila["dia_id"], 0) + 1

    por_clave = {
        clave: sum(por_marca.get(marca_id, 0) for marca_id in bucket["marca_ids"])
        for clave, bucket in marcas_por_dia.items()
    }
    return por_clave, por_dia_directo


def _enriquecer_pagina(db_servicio: Client, filas: list[dict]) -> list[dict]:
    """Ventana min(fecha)..max(fecha) de la página YA paginada (nota de rendimiento: con orden
    por fecha -- el default -- la ventana es mínima; con orden por horas y sin filtro de fecha
    puede ser amplia, acotada por ix_marca_persona_id ya existente. Follow-up fuera de este corte:
    no hay índice sobre momento_dispositivo)."""
    if not filas:
        return []

    persona_ids = sorted({fila["persona_id"] for fila in filas})
    fechas = [date.fromisoformat(fila["fecha"]) for fila in filas]
    desde, hasta = min(fechas), max(fechas)

    marcas = alertas_horario.resolver_marcas_efectivas(db_servicio, persona_ids, desde, hasta)
    jornadas_por_persona = alertas_horario.resolver_jornadas(db_servicio, persona_ids, desde, hasta)
    jornada_ids = sorted({j["id"] for jornadas in jornadas_por_persona.values() for j in jornadas})
    patrones = alertas_horario.resolver_patrones(db_servicio, jornada_ids)
    tolerancias = alertas_horario.resolver_tolerancias(db_servicio, hasta)
    excepciones_por_clave, excepciones_por_dia_id = _resolver_excepciones_pendientes(
        db_servicio, marcas, [fila["id"] for fila in filas]
    )

    resultado: list[dict] = []
    for fila in filas:
        persona_id = fila["persona_id"]
        fecha = date.fromisoformat(fila["fecha"])
        clave_marca = (persona_id, fecha)
        marca_del_dia = marcas.get(clave_marca)

        alerta_entrada = alerta_salida = None
        if marca_del_dia is not None and fila["origen"] is None:
            jornada = alertas_horario.jornada_vigente(jornadas_por_persona.get(persona_id, []), fecha)
            if jornada is not None and jornada["genera_alerta_horario"]:
                patron_del_dia = patrones.get(jornada["id"], {}).get(alertas_horario.dia_semana(fecha))
                if patron_del_dia:
                    entrada_programada, salida_programada = alertas_horario.entrada_salida_programadas(
                        patron_del_dia
                    )
                    tolerancia = alertas_horario.tolerancia_vigente(tolerancias, fecha)
                    alerta_entrada, alerta_salida = alertas_horario.evaluar_alertas(
                        marca_del_dia["primera_local"],
                        marca_del_dia["ultima_local"],
                        entrada_programada,
                        salida_programada,
                        tolerancia,
                    )

        excepciones_pendientes = excepciones_por_clave.get(
            clave_marca, 0
        ) + excepciones_por_dia_id.get(fila["id"], 0)

        resultado.append(
            {
                **fila,
                "primera_marca": marca_del_dia["primera"] if marca_del_dia else None,
                "ultima_marca": marca_del_dia["ultima"] if marca_del_dia else None,
                "alerta_entrada": alerta_entrada,
                "alerta_salida": alerta_salida,
                "excepciones_pendientes": excepciones_pendientes,
            }
        )
    return resultado


@router.get("", response_model=DiaListaOut)
def listar_dias(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_todos_los_permisos("dia_lectura", "marca_lectura")),
    busqueda_persona: str | None = Query(None, description="Texto libre sobre el nombre."),
    desde: date | None = Query(None, description="fecha >= desde."),
    hasta: date | None = Query(None, description="fecha <= hasta."),
    estado: Literal["abierto", "cerrado", "bloqueado", "revisado"] | None = Query(None),
    orden: Literal["fecha_desc", "fecha_asc", "horas_desc", "horas_asc"] = Query("fecha_desc"),
    limite: int = Query(LIMITE_DEFECTO, ge=1, le=LIMITE_MAXIMO),
    desplazamiento: int = Query(0, ge=0),
) -> dict:
    """No se puede ordenar por persona server-side (cruza esquema, SCJ-FRO-01) -- mismo límite
    que tramos.py."""
    persona_ids: list[str] | None = None
    if busqueda_persona is not None:
        persona_ids = _resolver_ids_por_busqueda(db_servicio, busqueda_persona)
        if not persona_ids:
            return {"total": 0, "dias": []}

    consulta = db_servicio.postgrest.schema("tiempo").table("dia").select(SELECT_DIA, count="exact")
    if persona_ids is not None:
        consulta = consulta.in_("persona_id", persona_ids)
    if desde is not None:
        consulta = consulta.gte("fecha", desde.isoformat())
    if hasta is not None:
        consulta = consulta.lte("fecha", hasta.isoformat())
    if estado is not None:
        consulta = consulta.eq("estado", estado)

    columna, descendente = ORDEN_A_COLUMNA[orden]
    resultado = (
        consulta.order(columna, desc=descendente)
        .range(desplazamiento, desplazamiento + limite - 1)
        .execute()
    )

    filas_enriquecidas = _enriquecer_pagina(db_servicio, resultado.data)
    nombres = _resolver_nombres_persona(
        db_servicio, sorted({fila["persona_id"] for fila in filas_enriquecidas})
    )
    dias = [
        {**fila, "persona_nombre": nombres.get(fila["persona_id"])} for fila in filas_enriquecidas
    ]
    return {"total": resultado.count, "dias": dias}


@router.get("/pendientes-corte-quincenal", response_model=DiasFaltantesOut)
def dias_pendientes_corte_quincenal(
    db_servicio: Client = Depends(get_service_client),
    _permiso: None = Depends(requiere_todos_los_permisos("dia_lectura", "marca_lectura")),
) -> dict:
    """Alerta preventiva -- a quién le falta un tiempo.dia en el periodo EN CURSO (todavía sin
    cerrar), para que RH pueda actuar antes de que el corte quincenal se trabe cuando llegue su
    hora (SCJ-PRO-13). Mismo gate que el resto del router: expone datos derivados de
    tiempo.marca/tiempo.dia, no sólo tiempo.dia. Sin filtros/paginación -- resumen chico
    (decenas de personas, unas pocas fechas cada una)."""
    periodo_desde, periodo_hasta = resolver_periodo_en_curso(date.today())
    faltantes = resolver_dias_faltantes(db_servicio, periodo_desde, periodo_hasta, date.today())

    fechas_por_persona: dict[str, list[str]] = {}
    for item in faltantes:
        fechas_por_persona.setdefault(item["persona_id"], []).append(item["fecha"])

    nombres = _resolver_nombres_persona(db_servicio, list(fechas_por_persona.keys()))
    personas = [
        {
            "persona_id": persona_id,
            "persona_nombre": nombres.get(persona_id),
            "fechas_faltantes": fechas,
        }
        for persona_id, fechas in fechas_por_persona.items()
    ]
    return {"periodo_desde": periodo_desde, "periodo_hasta": periodo_hasta, "personas": personas}


@router.get("/{dia_id}/previsualizar-tramos", response_model=DiaPrevisualizacionOut)
def previsualizar_tramos(
    dia_id: int,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("dia_revision_edicion")),
) -> dict:
    """Sólo lectura -- tiempo.fn_dia_calcular_armado_tramos no escribe nada, simula cómo
    quedarían los tramos si se revisara el día ahora mismo (db/ddl/65_*.sql). Mismo gate que
    revisar_dia: si no podés revisar, tampoco tiene sentido que veas la previsualización."""
    resultado = (
        db.postgrest.schema("tiempo")
        .rpc("fn_dia_calcular_armado_tramos", {"p_dia_id": dia_id})
        .execute()
    )
    filas = resultado.data
    minutos_calculados = sum(
        fila["minutos_trabajados"]
        for fila in filas
        if fila["accion"] in ACCIONES_TRAMO_CON_HORAS
    )
    tiene_huerfana = any(fila["accion"] == ACCION_HUERFANA_SIN_PAREJA for fila in filas)
    return {
        "horas_calculadas": minutos_calculados / 60.0,
        "tiene_huerfana_sin_pareja": tiene_huerfana,
    }


@router.post("/{dia_id}/revisar", response_model=DiaRevisadoOut)
def revisar_dia(
    dia_id: int,
    datos: DiaRevisarRequest,
    db: Client = Depends(get_caller_client),
    _permiso: None = Depends(requiere_permiso("dia_revision_edicion")),
) -> dict:
    """SCJ-DEC-06: bloqueado -> revisado. horas_totales las escribe RH a mano -- un día bloqueado
    es, por definición, un caso que el sistema no puede calcular solo. Actor y momento se
    resuelven dentro de fn_dia_revisar (auth.uid()/now()), no se mandan desde acá -- mismo patrón
    que fn_ausencia_resolver. dia_update_revision (RLS) es la autorización real; este endpoint
    sólo traduce los ERRCODE del RPC a HTTP legible."""
    try:
        resultado = (
            db.postgrest.schema("tiempo")
            .rpc(
                "fn_dia_revisar",
                {"p_dia_id": dia_id, "p_horas_totales": datos.horas_totales},
            )
            .execute()
        )
    except APIError as error:
        if error.code == CODIGO_DIA_NO_ENCONTRADO:
            raise HTTPException(status.HTTP_404_NOT_FOUND, MENSAJE_DIA_NO_ENCONTRADO) from error
        if error.code == CODIGO_DIA_NO_BLOQUEADO:
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_DIA_NO_BLOQUEADO) from error
        if error.code == CODIGO_HORAS_INVALIDAS:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, MENSAJE_HORAS_INVALIDAS) from error
        if error.code == CODIGO_HUERFANA_SIN_PAREJA:
            raise HTTPException(status.HTTP_409_CONFLICT, MENSAJE_HUERFANA_SIN_PAREJA) from error
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, error.message) from error

    fila = resultado.data
    nombres = _resolver_nombres_persona(db, [fila["persona_id"]])
    return {**fila, "persona_nombre": nombres.get(fila["persona_id"])}
