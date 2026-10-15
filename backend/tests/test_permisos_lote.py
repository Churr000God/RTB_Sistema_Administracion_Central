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


# --- tiene_permisos_paralelo: el MISMO resultado que tiene_permisos ---------------------------------------------------------------------------------------

from app.permisos import tiene_permisos_paralelo  # noqa: E402


@pytest.mark.parametrize("vigentes", [["jefe"], ["medio"], ["operativo"], ["jefe", "operativo"], []])
def test_el_paralelo_da_lo_mismo_que_el_lote_y_que_tiene_permiso(vigentes):
    db = _db(vigentes, POSEEDORES, HEREDABLES)
    esperado = {c: tiene_permiso(db, "persona", c) for c in CODIGOS}
    assert tiene_permisos(db, "persona", CODIGOS) == esperado
    assert tiene_permisos_paralelo(db.postgrest.schema("personas"), "persona", CODIGOS) == esperado


def test_el_paralelo_sin_codigos_no_consulta_nada():
    db = _db(["jefe"], POSEEDORES, HEREDABLES)
    assert tiene_permisos_paralelo(db.postgrest.schema("personas"), "persona", []) == {}
    db.postgrest.schema.return_value.table.assert_not_called()


# --- herencia de más de un nivel y permisos no heredables --------------------------------------------------------------------------------------------------

# director → gerente → jefe → operativo → auxiliar (4 niveles hacia abajo) y una rama lateral
ARBOL_PROFUNDO = [
    {"id": "director", "reporta_a_id": None},
    {"id": "gerente", "reporta_a_id": "director"},
    {"id": "jefe", "reporta_a_id": "gerente"},
    {"id": "operativo", "reporta_a_id": "jefe"},
    {"id": "auxiliar", "reporta_a_id": "operativo"},
    {"id": "lateral", "reporta_a_id": "gerente"},
]
CODIGOS_PROFUNDOS = ["heredable_del_auxiliar", "no_heredable_del_auxiliar", "heredable_del_lateral", "directo_del_director", "de_nadie"]
POSEEDORES_PROFUNDOS = {
    "heredable_del_auxiliar": ["auxiliar"],
    "no_heredable_del_auxiliar": ["auxiliar"],
    "heredable_del_lateral": ["lateral"],
    "directo_del_director": ["director"],
}
HEREDABLES_PROFUNDOS = {"heredable_del_auxiliar": True, "no_heredable_del_auxiliar": False, "heredable_del_lateral": True, "directo_del_director": True}


def _db_profundo(vigentes):
    db = _db(vigentes, POSEEDORES_PROFUNDOS, HEREDABLES_PROFUNDOS)
    db.tablas["puesto"].select.return_value.execute.return_value.data = ARBOL_PROFUNDO
    return db


@pytest.mark.parametrize("vigentes", [["director"], ["gerente"], ["jefe"], ["operativo"], ["auxiliar"], ["lateral"], ["jefe", "lateral"], []])
def test_herencia_de_varios_niveles_paralelo_igual_a_lote_y_por_codigo(vigentes):
    db = _db_profundo(vigentes)
    por_codigo = {c: tiene_permiso(db, "persona", c) for c in CODIGOS_PROFUNDOS}
    assert tiene_permisos(db, "persona", CODIGOS_PROFUNDOS) == por_codigo
    assert tiene_permisos_paralelo(db.postgrest.schema("personas"), "persona", CODIGOS_PROFUNDOS) == por_codigo


def test_el_director_hereda_del_auxiliar_cuatro_niveles_abajo_pero_no_lo_no_heredable():
    r = tiene_permisos_paralelo(_db_profundo(["director"]).postgrest.schema("personas"), "persona", CODIGOS_PROFUNDOS)
    assert r["heredable_del_auxiliar"] is True            # varios niveles hacia abajo
    assert r["heredable_del_lateral"] is True             # y por la rama lateral
    assert r["no_heredable_del_auxiliar"] is False        # un permiso NO heredable de un subordinado NO se hereda
    assert r["directo_del_director"] is True and r["de_nadie"] is False


def test_el_subordinado_y_la_rama_lateral_no_heredan_hacia_arriba_ni_de_lado():
    r_jefe = tiene_permisos_paralelo(_db_profundo(["jefe"]).postgrest.schema("personas"), "persona", CODIGOS_PROFUNDOS)
    assert r_jefe["heredable_del_auxiliar"] is True and r_jefe["heredable_del_lateral"] is False        # el lateral no es subordinado de jefe
    assert r_jefe["directo_del_director"] is False                                                       # y el jefe no hereda hacia arriba
    r_aux = tiene_permisos_paralelo(_db_profundo(["auxiliar"]).postgrest.schema("personas"), "persona", CODIGOS_PROFUNDOS)
    assert r_aux["heredable_del_auxiliar"] is True and r_aux["no_heredable_del_auxiliar"] is True       # lo tiene directo
    assert r_aux["directo_del_director"] is False
