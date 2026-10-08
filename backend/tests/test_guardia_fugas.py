"""Guardia por AST contra la fuga del texto de la base (security M3 de C0). Regla:

    Un objeto de error (`except … as X`, o un parámetro `error`/`exc`/`e`/`err` o anotado `APIError`) y todo lo derivado de él
    (.message, .details, .hint, .code, str(X), f"{X}", y las VARIABLES a las que se asigne, propagando) NO puede llegar a un
    «sumidero» visible para el usuario: argumentos de HTTPException/ErrorConCampos/JSONResponse/Response y valores de `return`.

    Contextos seguros (el valor no se relaya, sólo se decide con él): comparaciones, la condición de un IfExp, el índice de un
    subíndice (`MAPA[error.code]`) y el argumento de `.get(...)`. Registrar en el log NO es un sumidero (se sanea con limpiar_para_log).
    Excepción documentada: los `except ValueError` (texto propio del backend, no de la base)."""

import ast
from pathlib import Path

import pytest

SUMIDEROS = {"HTTPException", "ErrorConCampos", "JSONResponse", "Response", "PlainTextResponse", "HTMLResponse", "ORJSONResponse"}
NOMBRES_DE_ERROR = {"error", "exc", "e", "err"}
ATRIBUTOS = {"message", "details", "hint", "code"}
IGNORAR_EXCEPT = {"ValueError"}  # texto propio del backend (validar_formato_valor), no de la base


def _nombre_llamada(call: ast.Call) -> str:
    f = call.func
    return f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) else ""


# Llamadas que CONVIERTEN el objeto de error en texto/datos (pasarle el error a cualquier otra función es seguro porque esa función
# se analiza por su cuenta: su parámetro `error` es un objeto de error).
CONVIERTEN = {"str", "repr", "ascii", "format", "getattr", "vars", "dict", "list", "tuple", "join"}


def _usos_inseguros(expr, objetos: set[str], derivadas: set[str]):
    """Nodos de `expr` que relayan datos del error (sin contar los contextos seguros: comparar, elegir con índice/.get, condición)."""
    pila = [expr]
    while pila:
        n = pila.pop()
        if isinstance(n, ast.Compare):
            continue  # comparar no relaya
        if isinstance(n, ast.IfExp):
            pila += [n.body, n.orelse]  # la condición decide, no se relaya
            continue
        if isinstance(n, ast.Subscript):
            pila.append(n.value)  # el índice sólo elige (MAPA[error.code])
            continue
        if isinstance(n, ast.Call):
            nombre = _nombre_llamada(n)
            if nombre == "get" and isinstance(n.func, ast.Attribute):
                pila.append(n.func.value)  # MAPA.get(error.hint, fijo): el argumento sólo elige
                pila += n.args[1:]
                continue
            if nombre not in CONVIERTEN:
                pila.append(n.func)
                for arg in [*n.args, *[k.value for k in n.keywords]]:
                    # el objeto de error crudo como argumento se delega a la función llamada (que se analiza aparte)
                    if isinstance(arg, ast.Name) and arg.id in objetos:
                        continue
                    pila.append(arg)
                continue
        if isinstance(n, ast.Attribute) and n.attr in ATRIBUTOS and isinstance(n.value, ast.Name) and n.value.id in objetos | derivadas:
            yield n
            continue
        if isinstance(n, ast.Name) and n.id in objetos | derivadas:
            yield n
            continue
        pila += list(ast.iter_child_nodes(n))


def _fugas_de_unidad(nodos, objetos: set[str], archivo: str) -> list[str]:
    """Analiza una unidad (cuerpo de una función o de un `except`) con sus objetos de error. Propaga el «taint» por asignaciones."""
    derivadas: set[str] = set()
    cambio = True
    while cambio:
        cambio = False
        for raiz in nodos:
            for n in ast.walk(raiz):
                if isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)) and n.value is not None:
                    if any(True for _ in _usos_inseguros(n.value, objetos, derivadas)):
                        objetivos = n.targets if isinstance(n, ast.Assign) else [n.target]
                        for o in objetivos:
                            for t in ast.walk(o):
                                if isinstance(t, ast.Name) and t.id not in objetos | derivadas:
                                    derivadas.add(t.id)
                                    cambio = True
    fugas = []
    for raiz in nodos:
        for n in ast.walk(raiz):
            if isinstance(n, ast.Call) and _nombre_llamada(n) in SUMIDEROS:
                for arg in [*n.args, *[k.value for k in n.keywords]]:
                    for uso in _usos_inseguros(arg, objetos, derivadas):
                        fugas.append(f"{archivo}:{uso.lineno} -> {_nombre_llamada(n)}({ast.unparse(uso)})")
            if isinstance(n, ast.Return) and n.value is not None:
                for uso in _usos_inseguros(n.value, objetos, derivadas):
                    fugas.append(f"{archivo}:{uso.lineno} -> return {ast.unparse(uso)}")
    return fugas


def _parametros_de_error(funcion) -> set[str]:
    """Parámetros que son un objeto de error: anotados con APIError/Exception, o sin anotar y llamados error/exc/e/err."""
    nombres = set()
    for a in [*funcion.args.args, *funcion.args.kwonlyargs, *funcion.args.posonlyargs]:
        if a.annotation is not None:
            anot = ast.unparse(a.annotation)
            if "APIError" in anot or anot == "Exception":
                nombres.add(a.arg)
        elif a.arg in NOMBRES_DE_ERROR:
            nombres.add(a.arg)
    return nombres


def fugas_en(arbol, archivo: str) -> list[str]:
    """(2) cada función con parámetros de error se analiza entera; (1)(3) cada `except … as X` se analiza por separado (así el mismo
    nombre `error` en un `except ValueError` y en otro `except APIError` no se mezcla)."""
    fugas: list[str] = []
    for n in ast.walk(arbol):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            objetos = _parametros_de_error(n)
            if objetos:
                fugas += _fugas_de_unidad(n.body, objetos, archivo)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            tipo = ast.unparse(n.type) if n.type is not None else ""
            if tipo not in IGNORAR_EXCEPT:
                fugas += _fugas_de_unidad(n.body, {n.name}, archivo)
    return sorted(set(fugas))


def test_ninguna_fuga_en_app():
    raiz = Path(__file__).resolve().parents[1] / "app"
    fugas = []
    for p in sorted(raiz.rglob("*.py")):
        fugas += fugas_en(ast.parse(p.read_text(encoding="utf-8")), p.name)
    assert fugas == [], "\n".join(fugas)


FUENTES_CON_FUGA = {
    "directa": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise HTTPException(422, error.message)\n",
    "str": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, str(e))\n",
    "fstring": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, f'fallo {e}')\n",
    "detail_kw": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(status_code=422, detail=e.details)\n",
    "concat": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, (e.hint or '') + 'x')\n",
    "code_fstring": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, detail=f'{e.code}')\n",
    # (1) por variable
    "variable": "def f():\n    try:\n        x()\n    except APIError as error:\n        crudo = error.message or ''\n        raise HTTPException(422, crudo)\n",
    "variable_en_cadena": "def f():\n    try:\n        x()\n    except APIError as error:\n        a = error.message\n        b = a.strip()\n        c = f'{b}!'\n        raise HTTPException(422, c)\n",
    "tupla": "def f():\n    try:\n        x()\n    except APIError as error:\n        codigo, hint = error.code, error.hint\n        raise HTTPException(422, hint)\n",
    # (2) helper con el error como parámetro, fuera de un except
    "helper_param": "def lanzar(error: APIError):\n    raise HTTPException(422, error.message)\n",
    "helper_param_sin_anotar": "def lanzar(error, mapa):\n    par = mapa.get(error.code)\n    raise HTTPException(422, error.message)\n",
    "helper_str": "def lanzar(exc):\n    raise HTTPException(422, str(exc))\n",
    # (3) otras respuestas
    "return_dict": "def f():\n    try:\n        x()\n    except APIError as error:\n        return {'detail': error.message}\n",
    "return_helper": "def f(error: APIError):\n    return error.message\n",
    "jsonresponse": "def f():\n    try:\n        x()\n    except APIError as error:\n        return JSONResponse(status_code=422, content={'detail': error.message})\n",
    "response": "def f(error: APIError):\n    return Response(content=error.details)\n",
    "error_con_campos": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise ErrorConCampos(409, 'fijo', {'x': error.message})\n",
    "str_sobre_variable_derivada_en_llamada": "def f():\n    try:\n        x()\n    except APIError as error:\n        crudo = error.message\n        raise HTTPException(422, limpia(crudo))\n",
    "objeto_via_str_en_helper": "def f(error: APIError):\n    texto = str(error)\n    return {'detail': texto}\n",
    "codigo_hermano": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise ErrorConCampos(409, 'fijo', {}, codigo=error.hint)\n",
}


@pytest.mark.parametrize("fuente", list(FUENTES_CON_FUGA.values()), ids=list(FUENTES_CON_FUGA))
def test_la_guardia_detecta_cada_forma_de_fuga(fuente):
    assert fugas_en(ast.parse(fuente), "prueba.py") != []


FUENTES_SEGURAS = {
    "mensaje_fijo": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, 'fijo')\n",
    "comparar": "def f():\n    try:\n        x()\n    except APIError as e:\n        if e.code == 'X' and e.hint in ('a', 'b'):\n            raise HTTPException(409, MENSAJE)\n        raise HTTPException(422, 'fijo')\n",
    "elegir_con_el_codigo": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(*MAPA[e.code])\n",
    "get_con_el_hint": "def f():\n    try:\n        x()\n    except APIError as e:\n        estado, mensaje = MAPA.get(e.hint, (409, 'fijo'))\n        raise HTTPException(estado, mensaje)\n",
    "ifexp_por_codigo": "def f():\n    try:\n        x()\n    except APIError as e:\n        raise HTTPException(422, A if e.code == 'x' else B)\n",
    "solo_log": "def f(error: APIError):\n    logger.error('%s', limpiar_para_log(error.message))\n    crudo = error.message or ''\n    if crudo.startswith('x'):\n        return 1\n    return None\n",
    "variable_no_fluye": "def f():\n    try:\n        x()\n    except APIError as error:\n        crudo = error.message\n        logger.error(crudo)\n        raise HTTPException(422, 'fijo')\n",
    "valueerror_propio": "def f():\n    try:\n        x()\n    except ValueError as error:\n        raise HTTPException(422, str(error))\n",
    "from_error": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise HTTPException(422, 'fijo') from error\n",
    "delegar_el_error_a_otra_funcion": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise traducir(error)\n",
    "retornar_traduccion": "def f(error: APIError):\n    return traducir(error)\n",
    "parametro_no_error": "async def manejador(request, exc: ErrorConCampos):\n    return JSONResponse(content={'detail': exc.detail})\n",
    "mismo_nombre_en_valueerror_y_apierror": "def f():\n    try:\n        a()\n    except ValueError as error:\n        raise HTTPException(422, str(error))\n    except APIError as error:\n        raise HTTPException(422, 'fijo')\n",
    "relanzar": "def f():\n    try:\n        x()\n    except APIError as error:\n        raise error\n",
}


@pytest.mark.parametrize("fuente", list(FUENTES_SEGURAS.values()), ids=list(FUENTES_SEGURAS))
def test_la_guardia_no_acusa_usos_seguros(fuente):
    assert fugas_en(ast.parse(fuente), "prueba.py") == []
