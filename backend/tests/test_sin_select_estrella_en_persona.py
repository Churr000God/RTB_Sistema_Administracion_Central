"""Lint de seguridad (separar nombre de identidad, 110_/111_): ningún router o servicio puede leer `personas.persona` con `select("*")`, sin lista de columnas o con un embed
`persona(*)`. Con service_role un `select("*")` leería TODA la identidad (CURP/RFC/NSS/fecha de nacimiento) y la filtraría en una respuesta; con el cliente del caller, tras 111_, fallaría.
Recorre `backend/app` con `ast`: es una guarda de CI, no una prueba de comportamiento."""

import ast
import re
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1] / "app"
EMBED_ESTRELLA = re.compile(r"persona(?::\w+)?(?:!\w+)?\s*\(\s*\*")           # persona(*), persona:persona_id(*), persona!inner(*)
ESTRELLA_SUELTA = re.compile(r"(^|,)\s*\*\s*(,|$)")                           # «*» como columna: select("*") o select("*, expediente(...)")


def _constantes_de_modulo(arbol: ast.Module) -> dict[str, str]:
    return {t.id: n.value.value for n in arbol.body if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)
            for t in n.targets if isinstance(t, ast.Name)}


def _es_tabla_persona(llamada: ast.AST) -> bool:
    """`<algo>.table("persona")` o `tabla("persona")` (alias de `.table`)."""
    if not isinstance(llamada, ast.Call) or not llamada.args:
        return False
    primero = llamada.args[0]
    if not (isinstance(primero, ast.Constant) and primero.value == "persona"):
        return False
    return (isinstance(llamada.func, ast.Attribute) and llamada.func.attr == "table") or (isinstance(llamada.func, ast.Name) and llamada.func.id in ("tabla", "table"))


def _cadena_hasta_persona(nodo: ast.AST) -> bool:
    while isinstance(nodo, (ast.Attribute, ast.Call)):
        if _es_tabla_persona(nodo):
            return True
        nodo = nodo.func.value if isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Attribute) else getattr(nodo, "value", None)
        if nodo is None:
            break
    return False


def violaciones_en(codigo: str, nombre: str = "<memoria>") -> list[str]:
    arbol = ast.parse(codigo)
    constantes = _constantes_de_modulo(arbol)
    malas = []
    for nodo in ast.walk(arbol):
        if not (isinstance(nodo, ast.Call) and isinstance(nodo.func, ast.Attribute) and nodo.func.attr == "select"):
            continue
        sobre_persona = _cadena_hasta_persona(nodo.func.value)
        argumento = nodo.args[0] if nodo.args else None
        texto = None
        if isinstance(argumento, ast.Constant) and isinstance(argumento.value, str):
            texto = argumento.value
        elif isinstance(argumento, ast.Name):
            texto = constantes.get(argumento.id)
        if texto is not None and EMBED_ESTRELLA.search(texto):
            malas.append(f"{nombre}:{nodo.lineno}: embed persona(*)")
            continue
        if not sobre_persona:
            continue
        if argumento is None:
            malas.append(f"{nombre}:{nodo.lineno}: select() sin columnas sobre personas.persona")
        elif texto is None:
            malas.append(f"{nombre}:{nodo.lineno}: select con columnas no verificables (use una cadena literal o una constante de módulo)")
        elif texto.strip() == "" or ESTRELLA_SUELTA.search(texto):
            malas.append(f"{nombre}:{nodo.lineno}: select(*) sobre personas.persona")
    return malas


def test_ningun_archivo_de_app_lee_personas_persona_con_estrella_ni_sin_columnas():
    malas = []
    for archivo in sorted(RAIZ.rglob("*.py")):
        malas += violaciones_en(archivo.read_text(encoding="utf-8"), str(archivo.relative_to(RAIZ.parent)))
    assert malas == [], "personas.persona leída con * o sin columnas:\n" + "\n".join(malas)


# --- el propio lint detecta lo que debe -----------------------------------------------------------------------------------------------------------------


def test_el_lint_detecta_select_estrella_sin_columnas_y_embeds():
    casos = {
        'db.postgrest.schema("personas").table("persona").select("*").execute()': 1,
        'db.postgrest.schema("personas").table("persona").select().execute()': 1,
        'db.postgrest.schema("personas").table("persona").select("*, expediente(tipo_contrato)").eq("id", x).single()': 1,
        'tabla("persona").select("id, *")': 1,
        'db.table("asignacion").select("*, persona:persona_id(*)")': 1,
        'db.table("asignacion").select("id, persona(*)")': 1,
        'db.table("asignacion").select("id, persona!inner(*)")': 1,
        'db.postgrest.schema("personas").table("persona").select(columnas_dinamicas)': 1,
    }
    for fuente, esperado in casos.items():
        assert len(violaciones_en(fuente)) == esperado, fuente


def test_el_lint_acepta_columnas_de_nombre_literales_y_constantes_de_modulo_y_otras_tablas():
    ok = '''
COLUMNAS = "id, primer_nombre, apellido_paterno"
def f(db):
    db.postgrest.schema("personas").table("persona").select("id, primer_nombre, apellido_paterno").execute()
    db.postgrest.schema("personas").table("persona").select(COLUMNAS).execute()
    db.postgrest.schema("personas").table("area").select("*").execute()
    db.postgrest.schema("personas").table("asignacion").select("id, persona:persona_id(primer_nombre, apellido_paterno)").execute()
    db.postgrest.schema("personas").table("usuario").select("auth_user_id, persona:persona_id(estado)").execute()
'''
    assert violaciones_en(ok) == []
