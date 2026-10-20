"""Lint de seguridad (113_): NINGÚN código de `backend/app` escribe en `personas.asignacion` (insert/update/upsert/delete, ni por RPC `fn_asignacion_*`) con el cliente de SERVICIO.
Las reglas de 113_ (autoasignación y vigencia futura) dependen de `auth.uid()` del CALLER: con service_role (sin auth.uid()) se saltarían en silencio. Hoy los routers usan
`get_caller_client`. Recorre `backend/app` con `ast`; es una guarda de CI, no una prueba de comportamiento.

Qué detecta: (a) en un archivo con un sitio de escritura sobre asignación, cualquier referencia a `get_service_client`, `create_client` o `service_role`; (b) la función que contiene el sitio
de escritura con un parámetro de cliente de servicio (default `Depends(get_service_client)` o un nombre que lo diga: *servicio*/*service*). Límite: una función de ayuda que reciba un cliente ya
armado no se puede rastrear hasta su origen; por eso la regla (a) es por archivo."""

import ast
import re
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1] / "app"
ESCRITURAS = frozenset({"insert", "update", "upsert", "delete"})
NOMBRE_DE_SERVICIO = re.compile(r"servicio|service", re.I)
RPC_DE_ASIGNACION = re.compile(r"^fn_asignacion_")


def _es_tabla_asignacion(nodo: ast.AST) -> bool:
    if not isinstance(nodo, ast.Call) or not nodo.args:
        return False
    primero = nodo.args[0]
    if not (isinstance(primero, ast.Constant) and primero.value == "asignacion"):
        return False
    return (isinstance(nodo.func, ast.Attribute) and nodo.func.attr == "table") or (isinstance(nodo.func, ast.Name) and nodo.func.id in ("tabla", "table"))


def _cadena_pasa_por_tabla_asignacion(nodo: ast.AST) -> bool:
    while isinstance(nodo, (ast.Attribute, ast.Call)):
        if _es_tabla_asignacion(nodo):
            return True
        nodo = nodo.func.value if isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Attribute) else getattr(nodo, "value", None)
        if nodo is None:
            break
    return False


def _sitios_de_escritura(arbol: ast.AST) -> list[ast.Call]:
    sitios = []
    for nodo in ast.walk(arbol):
        if not (isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Attribute)):
            continue
        if nodo.func.attr in ESCRITURAS and _cadena_pasa_por_tabla_asignacion(nodo.func.value):
            sitios.append(nodo)
        elif nodo.func.attr == "rpc" and nodo.args and isinstance(nodo.args[0], ast.Constant) and isinstance(nodo.args[0].value, str) and RPC_DE_ASIGNACION.match(nodo.args[0].value):
            sitios.append(nodo)
    return sitios


def _parametro_de_servicio(funcion: ast.AST) -> bool:
    argumentos = funcion.args
    todos = [*argumentos.posonlyargs, *argumentos.args, *argumentos.kwonlyargs]
    defaults = [*([None] * (len(argumentos.posonlyargs) + len(argumentos.args) - len(argumentos.defaults))), *argumentos.defaults, *argumentos.kw_defaults]
    for arg, default in zip(todos, defaults):
        if NOMBRE_DE_SERVICIO.search(arg.arg):
            return True
        if default is not None and "get_service_client" in ast.dump(default):
            return True
    return False


def violaciones_en(codigo: str, nombre: str = "<memoria>") -> list[str]:
    arbol = ast.parse(codigo)
    sitios = _sitios_de_escritura(arbol)
    if not sitios:
        return []
    malas = []
    for nodo in ast.walk(arbol):
        if isinstance(nodo, ast.Name) and nodo.id in ("get_service_client", "crear_cliente_servicio", "create_client"):
            malas.append(f"{nombre}:{nodo.lineno}: el archivo escribe en asignación y referencia {nodo.id}")
        elif isinstance(nodo, ast.Attribute) and nodo.attr in ("get_service_client", "crear_cliente_servicio", "create_client", "supabase_service_role_key"):
            malas.append(f"{nombre}:{nodo.lineno}: el archivo escribe en asignación y referencia {nodo.attr}")
        elif isinstance(nodo, ast.Constant) and isinstance(nodo.value, str) and "service_role" in nodo.value.lower():
            malas.append(f"{nombre}:{nodo.lineno}: el archivo escribe en asignación y menciona service_role")
    for funcion in ast.walk(arbol):
        if not isinstance(funcion, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        internos = {id(n) for n in ast.walk(funcion)}
        if any(id(s) in internos for s in sitios) and _parametro_de_servicio(funcion):
            malas.append(f"{nombre}:{funcion.lineno}: la función {funcion.name} escribe en asignación y recibe un cliente de servicio")
    return malas


def test_ningun_archivo_de_app_escribe_en_asignacion_con_el_cliente_de_servicio():
    malas = []
    escriben = []
    for archivo in sorted(RAIZ.rglob("*.py")):
        codigo = archivo.read_text(encoding="utf-8")
        if _sitios_de_escritura(ast.parse(codigo)):
            escriben.append(archivo.name)
        malas += violaciones_en(codigo, str(archivo.relative_to(RAIZ.parent)))
    assert malas == [], "personas.asignacion escrita con el cliente de servicio:\n" + "\n".join(malas)
    assert "asignaciones.py" in escriben          # el lint SÍ ve los sitios reales (si dejara de verlos, no estaría protegiendo nada)


def test_el_lint_detecta_escrituras_con_cliente_de_servicio():
    casos = [
        'def f(db=Depends(get_service_client)):\n    db.postgrest.schema("personas").table("asignacion").insert({}).execute()',
        'def f(db_servicio):\n    db_servicio.postgrest.schema("personas").table("asignacion").update({}).eq("id", 1).execute()',
        'def f(db):\n    db.postgrest.schema("personas").rpc("fn_asignacion_cambiar_puesto", {}).execute()\nx = get_service_client',
        'def f(db):\n    cliente = create_client(url, clave)\n    cliente.postgrest.schema("personas").table("asignacion").delete().eq("id", 1).execute()',
        'def f(db):\n    tabla("asignacion").upsert({})\nENV = "SUPABASE_SERVICE_ROLE_KEY y service_role"',
    ]
    for fuente in casos:
        assert violaciones_en(fuente), fuente


def test_el_lint_acepta_el_cliente_de_caller_y_las_lecturas_con_servicio():
    ok = [
        'def f(db=Depends(get_caller_client)):\n    db.postgrest.schema("personas").table("asignacion").insert({}).execute()',
        'def f(db: Client = Depends(get_caller_client)):\n    return db.postgrest.schema("personas").rpc("fn_asignacion_cambiar_puesto", {}).execute()',
        # el servicio SOLO lee asignación (y escribe en otra tabla): permitido
        'def f(db=Depends(get_service_client)):\n    db.postgrest.schema("personas").table("asignacion").select("id").execute()\n    db.postgrest.schema("tiempo").table("dia").insert({}).execute()',
    ]
    for fuente in ok:
        assert violaciones_en(fuente) == [], fuente
