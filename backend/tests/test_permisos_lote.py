"""`tiene_permisos` (lote) debe dar EXACTAMENTE lo mismo que llamar `tiene_permiso` por código, con
consultas fijas. Mocks por nombre de tabla -- NUNCA contra la base real."""

from unittest.mock import MagicMock

import pytest

from app.permisos import tiene_permiso, tiene_permisos

# Árbol: jefe -> medio -> operativo
ARBOL = [
    {"id": "jefe", "reporta_a_id": None},
    {"id": "medio", "reporta_a_id": "jefe"},
    {"id": "operativo", "reporta_a_id": "medio"},
]


def _db(vigentes, poseedores, heredables):
    """poseedores: {codigo: [puesto_id,...]}; heredables: {codigo: bool}. Distingue el código pedido en
    puesto_permiso (eq o in_) y en permiso, para poder comparar contra tiene_permiso real."""
    db = MagicMock()

    asignacion = MagicMock()
    asignacion.select.return_value.eq.return_value.is_.return_value.execute.return_value.data = [
        {"puesto_id": p} for p in vigentes
    ]

    pp = MagicMock()

    def pp_eq(_campo, codigo):
        r = MagicMock()
        r.eq.return_value.execute.return_value.data = [
            {"puesto_id": p, "codigo": codigo} for p in poseedores.get(codigo, [])
        ]
        return r

    def pp_in(_campo, codigos):
        r = MagicMock()
        r.eq.return_value.execute.return_value.data = [
            {"puesto_id": p, "codigo": c} for c in codigos for p in poseedores.get(c, [])
        ]
        return r

    pp.select.return_value.eq.side_effect = pp_eq
    pp.select.return_value.in_.side_effect = pp_in

    permiso = MagicMock()

    def permiso_eq(_campo, codigo):
        r = MagicMock()
        r.execute.return_value.data = [{"heredable": heredables[codigo]}] if codigo in heredables else []
        return r

    def permiso_in(_campo, codigos):
        r = MagicMock()
        r.execute.return_value.data = [
            {"codigo": c, "heredable": heredables[c]} for c in codigos if c in heredables
        ]
        return r

    permiso.select.return_value.eq.side_effect = permiso_eq
    permiso.select.return_value.in_.side_effect = permiso_in

    puesto = MagicMock()
    puesto.select.return_value.execute.return_value.data = ARBOL

    tablas = {"asignacion": asignacion, "puesto_permiso": pp, "permiso": permiso, "puesto": puesto}
    db.postgrest.schema.return_value.table.side_effect = lambda n: tablas[n]
    db.tablas = tablas
    return db


CODIGOS = ["directo", "heredable_de_subordinado", "no_heredable_de_subordinado", "ajeno", "inexistente"]
POSEEDORES = {
    "directo": ["jefe"],
    "heredable_de_subordinado": ["operativo"],
    "no_heredable_de_subordinado": ["operativo"],
    "ajeno": ["otro-puesto"],
}
HEREDABLES = {"directo": False, "heredable_de_subordinado": True, "no_heredable_de_subordinado": False, "ajeno": True}


@pytest.mark.parametrize("vigentes", [["jefe"], ["medio"], ["operativo"], ["jefe", "operativo"], []])
def test_el_lote_da_lo_mismo_que_tiene_permiso_por_codigo(vigentes):
    db = _db(vigentes, POSEEDORES, HEREDABLES)
    esperado = {c: tiene_permiso(db, "persona", c) for c in CODIGOS}
    assert tiene_permisos(db, "persona", CODIGOS) == esperado


def test_semantica_concreta_del_jefe_que_hereda_del_subordinado():
    db = _db(["jefe"], POSEEDORES, HEREDABLES)
    r = tiene_permisos(db, "persona", CODIGOS)
    assert r == {
        "directo": True,
        "heredable_de_subordinado": True,  # hereda: el subordinado lo tiene y es heredable
        "no_heredable_de_subordinado": False,  # no hereda
        "ajeno": False,
        "inexistente": False,
    }


def test_el_subordinado_no_hereda_de_su_jefe():
    db = _db(["operativo"], {"directo": ["jefe"]}, {"directo": True})
    assert tiene_permisos(db, "persona", ["directo"]) == {"directo": False}


def test_sin_puestos_vigentes_no_consulta_poseedores():
    db = _db([], POSEEDORES, HEREDABLES)
    assert tiene_permisos(db, "persona", CODIGOS) == {c: False for c in CODIGOS}
    db.tablas["puesto_permiso"].select.assert_not_called()


def test_sin_codigos_no_consulta_nada():
    db = _db(["jefe"], POSEEDORES, HEREDABLES)
    assert tiene_permisos(db, "persona", []) == {}
    db.postgrest.schema.assert_not_called()


def test_consultas_fijas_sin_importar_cuantos_codigos():
    db = _db(["jefe"], POSEEDORES, HEREDABLES)
    tiene_permisos(db, "persona", CODIGOS * 3)  # duplicados se colapsan
    assert db.tablas["puesto_permiso"].select.return_value.in_.call_count == 1
    assert db.tablas["permiso"].select.return_value.in_.call_count == 1
    assert db.tablas["puesto"].select.call_count == 1


def test_si_todo_se_resolvio_directo_no_consulta_herencia():
    db = _db(["jefe"], {"directo": ["jefe"]}, {"directo": True})
    assert tiene_permisos(db, "persona", ["directo"]) == {"directo": True}
    db.tablas["permiso"].select.assert_not_called()
    db.tablas["puesto"].select.assert_not_called()


def test_codigos_duplicados_devuelven_una_sola_clave():
    db = _db(["jefe"], POSEEDORES, HEREDABLES)
    assert list(tiene_permisos(db, "persona", ["directo", "directo"])) == ["directo"]
