"""Lógica de permisos compartida por los routers del módulo Estructura Organizacional
(SCJ-PRO-05). No es un router -- es lo que consumen `Depends(requiere_permiso(...))` en cada
endpoint que necesita gatear por permiso, además del `get_caller_client` de siempre.

`tiene_permiso` implementa la herencia jerárquica: el JEFE hereda lo que ya tiene el
subordinado (confirmado contra RTB-ESP-01 §III.4) -- mismo sentido que ya usaba
`otorgar_permiso` (routers/permisos.py) al bloquear el auto-otorgamiento por herencia, sólo que
acá se recorre hacia abajo desde cada puesto vigente del caller en vez de validar un destino."""

from fastapi import Depends, HTTPException, status
from supabase import Client

from app.deps import CallerIdentity, get_caller_client, get_caller_identity


def resolver_persona_id(db: Client, caller: CallerIdentity) -> str:
    """fn_caller_activo() ya exige que el caller tenga fila en personas.usuario para llegar
    hasta acá (mismo razonamiento que movimientos.py) -- no hace falta manejo de "no
    encontrado"."""
    fila = (
        db.postgrest.schema("personas")
        .table("usuario")
        .select("persona_id")
        .eq("auth_user_id", caller.auth_user_id)
        .execute()
        .data
    )
    return fila[0]["persona_id"]


def resolver_puestos_vigentes(db: Client, persona_id: str) -> list[str]:
    filas = (
        db.postgrest.schema("personas")
        .table("asignacion")
        .select("puesto_id")
        .eq("persona_id", persona_id)
        .is_("vigente_hasta", "null")
        .execute()
        .data
    )
    return [fila["puesto_id"] for fila in filas]


def mapa_hijos_por_puesto(db: Client) -> dict[str, list[str]]:
    """El árbol completo de puestos es chico (~15-20 filas) -- se trae entero y se arma en
    memoria en vez de un RPC nuevo (WITH RECURSIVE): es sólo lectura y el volumen no lo
    justifica."""
    filas = (
        db.postgrest.schema("personas").table("puesto").select("id, reporta_a_id").execute().data
    )
    hijos: dict[str, list[str]] = {}
    for fila in filas:
        padre = fila["reporta_a_id"]
        if padre is not None:
            hijos.setdefault(padre, []).append(fila["id"])
    return hijos


def descendientes_incluido_si_mismo(hijos: dict[str, list[str]], puesto_id: str) -> set[str]:
    vistos = {puesto_id}
    pendientes = [puesto_id]
    while pendientes:
        actual = pendientes.pop()
        for hijo in hijos.get(actual, []):
            if hijo not in vistos:
                vistos.add(hijo)
                pendientes.append(hijo)
    return vistos


def tiene_permiso(db: Client, persona_id: str, codigo: str) -> bool:
    puestos_vigentes = resolver_puestos_vigentes(db, persona_id)
    if not puestos_vigentes:
        return False

    poseedores = {
        fila["puesto_id"]
        for fila in (
            db.postgrest.schema("personas")
            .table("puesto_permiso")
            .select("puesto_id")
            .eq("codigo", codigo)
            .eq("activo", True)
            .execute()
            .data
        )
    }
    if poseedores.intersection(puestos_vigentes):
        return True

    permiso = (
        db.postgrest.schema("personas")
        .table("permiso")
        .select("heredable")
        .eq("codigo", codigo)
        .execute()
        .data
    )
    if not permiso or not permiso[0]["heredable"]:
        return False

    hijos = mapa_hijos_por_puesto(db)
    return any(
        descendientes_incluido_si_mismo(hijos, vigente) & poseedores
        for vigente in puestos_vigentes
    )


def tiene_alguno(db: Client, persona_id: str, *codigos: str) -> bool:
    return any(tiene_permiso(db, persona_id, codigo) for codigo in codigos)


def requiere_permiso(*codigos: str):
    """Factory de dependencia FastAPI: Depends(requiere_permiso("area_edicion")). Se agrega
    ADEMÁS de get_caller_client (RLS), no en su lugar -- éste valida la lógica de negocio de
    permisos, RLS sigue siendo la última línea de defensa real. Varios códigos son OR (basta
    uno) -- para lectura-o-edición. Para exigir TODOS los códigos (AND), usar
    requiere_todos_los_permisos."""

    def dependencia(
        db: Client = Depends(get_caller_client),
        caller: CallerIdentity = Depends(get_caller_identity),
    ) -> None:
        persona_id = resolver_persona_id(db, caller)
        if not tiene_alguno(db, persona_id, *codigos):
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"No tenés el permiso necesario ({' o '.join(codigos)}) para esta acción.",
            )

    return dependencia


def requiere_todos_los_permisos(*codigos: str):
    """Como requiere_permiso, pero exige TODOS los códigos (AND), no basta con uno -- para un
    endpoint que escribe en más de una tabla gateada por permisos distintos (SCJ-PRO-09:
    jornada_asignada_edicion + patron_semanal_edicion no se puede asumir que el mapeo de
    puesto_permiso los otorgue siempre juntos)."""

    def dependencia(
        db: Client = Depends(get_caller_client),
        caller: CallerIdentity = Depends(get_caller_identity),
    ) -> None:
        persona_id = resolver_persona_id(db, caller)
        faltantes = [codigo for codigo in codigos if not tiene_permiso(db, persona_id, codigo)]
        if faltantes:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN,
                f"No tenés los permisos necesarios ({', '.join(faltantes)}) para esta acción.",
            )

    return dependencia


def es_administrador_generico(db: Client, persona_id: str) -> bool:
    """¿Ocupa la persona (hoy, por una asignación vigente) un puesto con `es_administrador_generico`?
    (hoy «Gerente o Encargado de TI»). Sirve a la excepción de la auto-asignación a una terminal
    (SCJ-DEC-12 §4, SCJ-PRO-15 §V.3): el mismo flag que ya leen asignaciones.py y permisos.py. Un solo
    puesto vigente con el flag basta; sin puestos vigentes, False."""
    puestos = resolver_puestos_vigentes(db, persona_id)
    if not puestos:
        return False
    filas = (
        db.postgrest.schema("personas")
        .table("puesto")
        .select("es_administrador_generico")
        .in_("id", puestos)
        .execute()
        .data
    )
    return any(fila["es_administrador_generico"] for fila in filas)


def tiene_permisos(db: Client, persona_id: str, codigos) -> dict[str, bool]:
    """Igual que `tiene_permiso` para VARIOS códigos a la vez, con las mismas reglas (poseedor directo, o
    herencia jerárquica sólo si el permiso es heredable) pero con consultas fijas en vez de ~5 por código:
    puestos vigentes (1), poseedores de todos los códigos (1), heredabilidad de los que no se resolvieron
    directo (1) y, sólo si alguno es heredable, el árbol de puestos (1). Lo usa /api/sesion, que pregunta
    por ocho códigos en cada carga."""
    codigos = list(dict.fromkeys(codigos))
    resultado = {codigo: False for codigo in codigos}
    if not codigos:
        return resultado
    puestos_vigentes = resolver_puestos_vigentes(db, persona_id)
    if not puestos_vigentes:
        return resultado

    filas = (
        db.postgrest.schema("personas")
        .table("puesto_permiso")
        .select("puesto_id, codigo")
        .in_("codigo", codigos)
        .eq("activo", True)
        .execute()
        .data
    )
    poseedores: dict[str, set[str]] = {codigo: set() for codigo in codigos}
    for fila in filas:
        if fila["codigo"] in poseedores:
            poseedores[fila["codigo"]].add(fila["puesto_id"])

    propios = set(puestos_vigentes)
    pendientes = []
    for codigo in codigos:
        if poseedores[codigo] & propios:
            resultado[codigo] = True
        elif poseedores[codigo]:
            pendientes.append(codigo)  # sin poseedores no hay nada que heredar
    if not pendientes:
        return resultado

    heredables = {
        fila["codigo"]
        for fila in (
            db.postgrest.schema("personas")
            .table("permiso")
            .select("codigo, heredable")
            .in_("codigo", pendientes)
            .execute()
            .data
        )
        if fila["heredable"]
    }
    if not heredables:
        return resultado

    hijos = mapa_hijos_por_puesto(db)
    alcanzables: set[str] = set()
    for puesto in puestos_vigentes:
        alcanzables |= descendientes_incluido_si_mismo(hijos, puesto)
    for codigo in heredables:
        if alcanzables & poseedores[codigo]:
            resultado[codigo] = True
    return resultado
