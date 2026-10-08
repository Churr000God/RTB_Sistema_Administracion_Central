"""Tablero de anomalías de una terminal (CONTRATO_API_TERMINALES_PAQUETE_2.md §9, SCJ-DEC-12 §6).

Diez categorías, cada una calculada AISLADA (si una falla, su tarjeta lleva `estado: "error"` y las demás siguen).
Tres son agregaciones sobre tiempo.marca y las resuelve `fn_terminal_anomalias` (90_, service_role, filtra por la
terminal dentro); el resto son consultas simples. Reglas de visibilidad:
  - Lo que el caller puede leer por RLS (altas, bitácora, personas) se lee con su cliente; los NOMBRES siempre con el
    cliente del caller (nunca se exponen persona_id, employee_no, hashes ni IP).
  - Lo que no puede (marcas, credenciales, rechazos) se lee con service_role SIEMPRE acotado a la terminal de la URL.
  - Las categorías que muestran marcas de PERSONAS (1 y 2) exigen además `marca_lectura` (AND con el gate del tablero)."""

import logging
import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Callable

from postgrest.exceptions import APIError
from supabase import Client

from app.altas_terminal import (
    _consentimientos_por_id,
    ids_pendientes,
    pendientes_de_terminal,
    resolver_nombres_persona,
)
from app.catalogo_terminal import CLAVE_CADUCIDAD, valor_vigente
from app.consentimiento_terminal import leer_vigente
from app.fecha_local import a_datetime

logger = logging.getLogger(__name__)

MIGRACION_FALTANTE = {"PGRST202", "PGRST204", "PGRST205", "42P01"}
CODIGOS_RECHAZO = (
    "forma_invalida", "no_enrolado", "secuencia_duplicada", "secuencia_fuera_de_rango", "conflicto_evento",
)
TOPE_FILAS = 1000
EJEMPLOS = 3


@dataclass
class Contexto:
    db: Client  # cliente del CALLER (RLS)
    db_servicio: Client  # service_role: sólo lecturas de insumo, siempre acotadas a la terminal
    terminal_id: int
    serie: str
    reloj_desfase_seg: int | None
    desde: datetime
    hasta: datetime
    ahora: datetime


@dataclass(frozen=True)
class Categoria:
    clave: str
    numero: int
    titulo: str
    nivel: str  # atender | revisar | informativo
    requiere_marca_lectura: bool
    calcular: Callable[[Contexto, int, int], tuple[int, list[dict]]]


# --- helpers ------------------------------------------------------------------------------------------------------------


def _trozos(lista: list, n: int = 100):
    for i in range(0, len(lista), n):
        yield lista[i : i + n]


def _rpc_agregacion(ctx: Contexto, categoria: str, limite: int, desplazamiento: int) -> tuple[int, list[dict]]:
    datos = (
        ctx.db_servicio.postgrest.schema("tiempo")
        .rpc(
            "fn_terminal_anomalias",
            {
                "p_terminal_id": ctx.terminal_id,
                "p_categoria": categoria,
                "p_desde": ctx.desde.isoformat(),
                "p_hasta": ctx.hasta.isoformat(),
                "p_limite": limite,
                "p_desplazamiento": desplazamiento,
            },
        )
        .execute()
        .data
    )
    if not isinstance(datos, dict) or isinstance(datos.get("total"), bool) or not isinstance(datos.get("total"), int) \
            or not isinstance(datos.get("items"), list):
        raise ValueError("forma inesperada de fn_terminal_anomalias")
    return datos["total"], datos["items"]


def _contar(consulta) -> int:
    return consulta.execute().count or 0


def _marcas(ctx: Contexto):
    return (
        ctx.db_servicio.postgrest.schema("tiempo")
        .table("marca")
        .select("id", count="exact", head=True)
        .eq("terminal_id", ctx.serie)  # tiempo.marca.terminal_id es la SERIE; acotado a ESTA terminal
        .eq("origen", "terminal")
        .gte("momento_dispositivo", ctx.desde.isoformat())
        .lte("momento_dispositivo", ctx.hasta.isoformat())
    )


# --- las 10 categorías ----------------------------------------------------------------------------------------------------


def _marcas_posteriores_a_baja(ctx, limite, desplazamiento):
    total, items = _rpc_agregacion(ctx, "marcas_posteriores_a_baja", limite, desplazamiento)
    nombres = resolver_nombres_persona(ctx.db, [i["persona_id"] for i in items if i.get("persona_id")])
    return total, [
        {
            "persona_nombre": nombres.get(i.get("persona_id")),
            "marca_en": i.get("marca_en"),
            "baja_confirmada_en": i.get("baja_confirmada_en"),
        }
        for i in items
    ]


def _picos_de_tasa(ctx, limite, desplazamiento):
    total, items = _rpc_agregacion(ctx, "picos_de_tasa", limite, desplazamiento)
    nombres = resolver_nombres_persona(ctx.db, [i["persona_id"] for i in items if i.get("persona_id")])
    return total, [
        {
            "persona_nombre": nombres.get(i["persona_id"]) if i.get("persona_id") else None,
            "hora": i.get("hora"),
            "marcas": i.get("marcas"),
            "limite": i.get("limite"),
        }
        for i in items
    ]


def _reloj_degradado(ctx, limite, desplazamiento):
    total = _contar(_marcas(ctx).eq("estado_reloj", "deriva")) + _contar(_marcas(ctx).eq("estado_reloj", "sin_sincronizar"))
    if total == 0 or desplazamiento > 0:
        return total, []
    return total, [{"conteo": total, "desfase_actual_seg": ctx.reloj_desfase_seg}]


def _huecos_de_secuencia(ctx, limite, desplazamiento):
    total, items = _rpc_agregacion(ctx, "huecos_de_secuencia", limite, desplazamiento)
    return total, [
        {"desde": i.get("desde"), "hasta": i.get("hasta"), "faltan": i.get("faltan"), "fecha": i.get("fecha")} for i in items
    ]


def _rechazos_definitivos(ctx, limite, desplazamiento):
    por_codigo = []
    for codigo in CODIGOS_RECHAZO:
        n = _contar(
            ctx.db_servicio.postgrest.schema("tiempo")
            .table("marca_rechazada")
            .select("id", count="exact", head=True)
            .eq("terminal_id", ctx.terminal_id)
            .eq("codigo", codigo)
            .gte("creada_en", ctx.desde.isoformat())
            .lte("creada_en", ctx.hasta.isoformat())
        )
        if n:
            por_codigo.append({"codigo": codigo, "total": n})
    por_codigo.sort(key=lambda x: (-x["total"], x["codigo"]))
    return sum(x["total"] for x in por_codigo), por_codigo[desplazamiento : desplazamiento + limite]


def _credenciales(ctx, limite, desplazamiento):
    filas = (
        ctx.db_servicio.postgrest.schema("tiempo")
        .table("terminal_credencial")
        .select("creada_en, expira_en, revocada_en, ultimo_uso_en, ip_cambiada_en")  # nunca hash ni IP
        .eq("terminal_id", ctx.terminal_id)
        .limit(TOPE_FILAS)
        .execute()
        .data
    )
    llave_max = valor_vigente(ctx.db_servicio, "terminal_llave_max_meses")
    traslape_max = valor_vigente(ctx.db_servicio, "terminal_traslape_llave_max_dias")
    vigentes = [
        f for f in filas
        if not f.get("revocada_en") and (not f.get("expira_en") or a_datetime(f["expira_en"]) > ctx.ahora)
    ]
    hallazgos: list[dict] = []
    for f in vigentes:
        edad = ctx.ahora - a_datetime(f["creada_en"])
        meses = edad.days // 30
        if meses > llave_max:
            hallazgos.append({"tipo": "llave_antigua", "antiguedad_meses": meses})
        if not f.get("ultimo_uso_en") and edad > timedelta(days=1):
            hallazgos.append({"tipo": "llave_sin_uso", "antiguedad_dias": edad.days})
    if len(vigentes) >= 2:
        dias = (ctx.ahora - max(a_datetime(f["creada_en"]) for f in vigentes)).days
        if dias > traslape_max:
            hallazgos.append({"tipo": "traslape_abierto", "dias_abierto": dias})
    for f in filas:
        if f.get("ip_cambiada_en") and ctx.desde <= a_datetime(f["ip_cambiada_en"]) <= ctx.hasta:
            hallazgos.append({"tipo": "cambio_de_ip", "hace_dias": (ctx.ahora - a_datetime(f["ip_cambiada_en"])).days})
    return len(hallazgos), hallazgos[desplazamiento : desplazamiento + limite]


def _altas_vivas(ctx: Contexto, estados: list[str], columnas: str) -> list[dict]:
    return (
        ctx.db.postgrest.schema("tiempo")
        .table("terminal_usuario")
        .select(columnas)
        .eq("terminal_id", ctx.terminal_id)
        .in_("estado", estados)
        .order("id")
        .limit(TOPE_FILAS)
        .execute()
        .data
    )


def _inconsistencias_de_baja(ctx, limite, desplazamiento):
    """Persona que ya no está activa pero conserva un alta que NO se está retirando (el hook y el job fallaron)."""
    altas = _altas_vivas(ctx, ["pendiente_alta", "esperando_huella", "activo"], "persona_id, estado")
    por_persona = {a["persona_id"]: a["estado"] for a in altas}
    hallazgos = []
    for lote in _trozos(sorted(por_persona)):
        personas = (
            ctx.db.postgrest.schema("personas")
            .table("persona")
            .select("id, estado, primer_nombre, apellido_paterno")
            .in_("id", lote)
            .execute()
            .data
        )
        existentes = {p["id"]: p for p in personas}
        for p in personas:
            if p["estado"] != "activo":
                hallazgos.append(
                    {
                        "persona_nombre": f"{p['primer_nombre']} {p['apellido_paterno']}",
                        "estado_persona": p["estado"],
                        "estado_alta": por_persona[p["id"]],
                    }
                )
        # Alta HUÉRFANA: la persona ya no existe en personas.persona (la frontera no tiene FK). Sin nombre que mostrar.
        for persona_id in lote:
            if persona_id not in existentes:
                hallazgos.append({"persona_nombre": None, "estado_persona": "inexistente", "estado_alta": por_persona[persona_id]})
    hallazgos.sort(key=lambda x: (x["persona_nombre"] is None, x["persona_nombre"] or ""))
    return len(hallazgos), hallazgos[desplazamiento : desplazamiento + limite]


def _altas_atascadas(ctx, limite, desplazamiento):
    """pendiente_alta/pendiente_baja con más de N h, y esperando_huella ya vencidas (N = caducidad, Q7)."""
    n = valor_vigente(ctx.db_servicio, CLAVE_CADUCIDAD)
    filas = _altas_vivas(
        ctx, ["pendiente_alta", "pendiente_baja", "esperando_huella"], "persona_id, estado, actualizado_en, usuario_creado_en"
    )
    atascadas = []
    for f in filas:
        base = f.get("usuario_creado_en") if f["estado"] == "esperando_huella" else f.get("actualizado_en")
        if not base:
            continue
        horas = (ctx.ahora - a_datetime(base)) / timedelta(hours=1)
        if horas > n:
            atascadas.append({"persona_id": f["persona_id"], "estado": f["estado"], "horas": int(horas)})
    atascadas.sort(key=lambda x: -x["horas"])
    visibles = atascadas[desplazamiento : desplazamiento + limite]
    nombres = resolver_nombres_persona(ctx.db, [a["persona_id"] for a in visibles])
    return len(atascadas), [
        {"persona_nombre": nombres.get(a["persona_id"]), "estado": a["estado"], "horas": a["horas"]} for a in visibles
    ]


def _altas_recientes(ctx, limite, desplazamiento):
    resultado = (
        ctx.db.postgrest.schema("tiempo")
        .table("bitacora_movimiento_terminal_usuario")
        .select("persona_id, registrado_por, creado_en", count="exact")
        .eq("terminal_id", ctx.terminal_id)
        .eq("tipo_movimiento", "asignado")
        .gte("creado_en", ctx.desde.isoformat())
        .lte("creado_en", ctx.hasta.isoformat())
        .order("creado_en", desc=True)
        .order("id", desc=True)
        .range(desplazamiento, desplazamiento + limite - 1)
        .execute()
    )
    filas = resultado.data
    nombres = resolver_nombres_persona(ctx.db, [f["persona_id"] for f in filas])
    autores = sorted({f["registrado_por"] for f in filas if f.get("registrado_por")})
    nombre_autor: dict[str, str] = {}
    if autores:
        nombre_autor = {
            u["auth_user_id"]: u["nombre_usuario"]
            for u in ctx.db.postgrest.schema("personas")
            .table("usuario")
            .select("auth_user_id, nombre_usuario")
            .in_("auth_user_id", autores)
            .execute()
            .data
        }
    total = resultado.count if resultado.count is not None else len(filas)
    return total, [
        {
            "persona_nombre": nombres.get(f["persona_id"]),
            "asignada_por": nombre_autor.get(f.get("registrado_por")),
            "creado_en": f["creado_en"],
        }
        for f in filas
    ]


def _reconsentimientos_pendientes(ctx, limite, desplazamiento):
    filas = pendientes_de_terminal(ctx.db, ctx.terminal_id, ids_pendientes(ctx.db))
    filas.sort(key=lambda f: f["id"])
    visibles = filas[desplazamiento : desplazamiento + limite]
    if not visibles:
        return len(filas), []
    vigente = leer_vigente(ctx.db)
    version_vigente = vigente["version"] if vigente else None
    material = (
        ctx.db.postgrest.schema("tiempo")
        .table("terminal_consentimiento")
        .select("creado_en")
        .eq("cambio_material", True)
        .order("version", desc=True)
        .limit(1)
        .execute()
        .data
    )
    desde_material = a_datetime(material[0]["creado_en"]) if material else None
    versiones = _consentimientos_por_id(ctx.db, [f["consentimiento_id"] for f in visibles if f.get("consentimiento_id")])
    nombres = resolver_nombres_persona(ctx.db, [f["persona_id"] for f in visibles])
    return len(filas), [
        {
            "persona_nombre": nombres.get(f["persona_id"]),
            "version_confirmada": versiones.get(f.get("consentimiento_id"), {}).get("version"),
            "version_vigente": version_vigente,
            "dias_pendiente": max(0, math.floor((ctx.ahora - desde_material) / timedelta(days=1))) if desde_material else None,
        }
        for f in visibles
    ]


CATEGORIAS: tuple[Categoria, ...] = (
    Categoria("marcas_posteriores_a_baja", 1, "Marcas posteriores a la baja", "atender", True, _marcas_posteriores_a_baja),
    Categoria("picos_de_tasa", 2, "Picos de marcas", "revisar", True, _picos_de_tasa),
    Categoria("reloj_degradado", 3, "Reloj degradado", "revisar", False, _reloj_degradado),
    Categoria("huecos_de_secuencia", 4, "Huecos de secuencia", "revisar", False, _huecos_de_secuencia),
    Categoria("rechazos_definitivos", 5, "Marcas rechazadas", "revisar", False, _rechazos_definitivos),
    Categoria("credenciales", 6, "Credenciales de la terminal", "revisar", False, _credenciales),
    Categoria("inconsistencias_de_baja", 7, "Inconsistencias de baja", "atender", False, _inconsistencias_de_baja),
    Categoria("altas_atascadas", 8, "Altas atascadas", "revisar", False, _altas_atascadas),
    Categoria("altas_recientes", 9, "Altas recientes", "informativo", False, _altas_recientes),
    Categoria("reconsentimientos_pendientes", 10, "Reconsentimientos pendientes", "revisar", False, _reconsentimientos_pendientes),
)
POR_CLAVE = {c.clave: c for c in CATEGORIAS}


def tarjeta(categoria: Categoria, ctx: Contexto, tiene_marca_lectura: bool) -> dict:
    """Una tarjeta del tablero, AISLADA: ninguna excepción sale de aquí."""
    base = {"clave": categoria.clave, "numero": categoria.numero, "titulo": categoria.titulo}
    vacia = {"nivel": None, "total": None, "ejemplos": [], "hay_mas": False}
    if categoria.requiere_marca_lectura and not tiene_marca_lectura:
        return {**base, **vacia, "estado": "no_disponible", "motivo": "sin_permiso"}
    try:
        total, items = categoria.calcular(ctx, EJEMPLOS, 0)
    except APIError as error:
        if error.code in MIGRACION_FALTANTE:
            logger.error("anomalías: falta una migración para %s (PostgREST %s)", categoria.clave, error.code)
            return {**base, **vacia, "estado": "no_disponible", "motivo": "falta_migracion"}
        logger.error("anomalías: falló %s (código %s)", categoria.clave, error.code)
        return {**base, **vacia, "estado": "error", "motivo": None}
    except Exception as error:  # una categoría rota no tumba el tablero
        logger.error("anomalías: falló %s (%s)", categoria.clave, type(error).__name__)
        return {**base, **vacia, "estado": "error", "motivo": None}
    if total == 0:
        return {**base, "estado": "sin_hallazgos", "nivel": None, "total": 0, "ejemplos": [], "hay_mas": False, "motivo": None}
    return {
        **base,
        "estado": "con_hallazgos",
        "nivel": categoria.nivel,
        "total": total,
        "ejemplos": items[:EJEMPLOS],
        "hay_mas": total > len(items[:EJEMPLOS]),
        "motivo": None,
    }
