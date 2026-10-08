"""Helpers compartidos para simular el cliente de Supabase en las pruebas (antes copiados en cada archivo).

- `tabla(datos, count=None)`: constructor FLUIDO: cualquier método encadenable devuelve la misma tabla,
  sólo `execute()` corta la cadena y devuelve `.data`/`.count`.
- `db_por_nombre(**tablas)`: cliente cuyas tablas se resuelven por NOMBRE, no por orden de llamada
  (`estricto=True`: una tabla no declarada falla la prueba; si no, devuelve una tabla vacía).
NUNCA se usan contra la base real."""

from unittest.mock import MagicMock

METODOS_ENCADENABLES = (
    "select", "eq", "neq", "like", "ilike", "in_", "gte", "lte", "order", "range", "is_", "or_", "limit",
)


class Resultado:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


def tabla(datos, count=None):
    t = MagicMock()
    for metodo in METODOS_ENCADENABLES:
        getattr(t, metodo).return_value = t
    t.execute.return_value = Resultado(datos, count)
    return t


def db_por_nombre(estricto=False, **tablas):
    db = MagicMock()

    def resolver(nombre):
        if nombre in tablas:
            return tablas[nombre]
        if estricto:
            raise KeyError(f"tabla no declarada en la prueba: {nombre}")
        return tabla([])

    db.postgrest.schema.return_value.table.side_effect = resolver
    return db


def cliente_rpc(resultado=None, error=None):
    """Cliente cuyo `.postgrest.schema(...).rpc(nombre, params).execute()` devuelve `resultado` (o lanza
    `error`). Devuelve (cliente, rpc) para inspeccionar las llamadas al RPC."""
    cliente = MagicMock()
    rpc = cliente.postgrest.schema.return_value.rpc
    ejecucion = rpc.return_value.execute
    if error is not None:
        ejecucion.side_effect = error
    else:
        ejecucion.return_value = Resultado(resultado)
    return cliente, rpc


class TablaConCadenas:
    """Tabla que registra, por cada consulta (cada `select`), la cadena COMPLETA de llamadas en orden, y
    devuelve los resultados en secuencia. Permite afirmar qué filtros lleva CADA consulta, no sólo si alguna
    los llevó."""

    def __init__(self, *resultados):
        self._resultados = list(resultados)
        self.cadenas: list[list[tuple]] = []

    def select(self, *args, **kwargs):
        cadena = [("select", args, kwargs)]
        self.cadenas.append(cadena)
        return _Cadena(self, cadena)


class _Cadena:
    def __init__(self, tabla, cadena):
        self._tabla, self._cadena = tabla, cadena

    def __getattr__(self, nombre):
        if nombre == "execute":
            def ejecutar():
                r = self._tabla._resultados.pop(0)
                return r if isinstance(r, Resultado) else Resultado(r)

            return ejecutar

        def paso(*args, **kwargs):
            self._cadena.append((nombre, args, kwargs))
            return self

        return paso


def llamadas(cadena, metodo):
    return [(a, k) for m, a, k in cadena if m == metodo]
