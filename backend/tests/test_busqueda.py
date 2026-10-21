"""Búsqueda de personas por nombre: el texto del usuario NO puede inyectar sintaxis en el `or=(…)` de PostgREST (coma, punto, paréntesis y asterisco son sintaxis). Un oráculo con service_role
adivinaba CURP/RFC/NSS letra por letra (`busqueda_persona=x,curp.like.ABC*`)."""

from unittest.mock import MagicMock

import pytest

from app import busqueda
from app.busqueda import MAX_LARGO_BUSQUEDA, filtro_de_nombre, resolver_ids_por_nombre, sanear_busqueda

MALICIOSAS = [
    "x,curp.like.*",
    "x,curp.like.ABC*",
    "a),id.neq.(",
    "%*.",
    "x,rfc.ilike.%AAAA%",
    "juan),or(curp.like.A*",
    "a.b.c",
    "*",
    "(((",
    ",,,",
    "'; drop table persona; --",
]
SOLO_SIMBOLOS = ["%*.", ",,,", "()", "***", "...", "%_%", " \t\n ", "", "x"[:0]]


def _condiciones(filtro: str) -> list[str]:
    return filtro.split(",")


@pytest.mark.parametrize("texto", MALICIOSAS)
def test_el_filtro_armado_siempre_tiene_exactamente_las_tres_condiciones_de_nombre(texto):
    filtro = filtro_de_nombre(texto)
    if filtro is None:
        return
    condiciones = _condiciones(filtro)
    assert len(condiciones) == 3
    assert [c.split(".ilike.")[0] for c in condiciones] == ["primer_nombre", "apellido_paterno", "apellido_materno"]
    for condicion in condiciones:
        valor = condicion.split(".ilike.", 1)[1]
        assert valor.startswith("%") and valor.endswith("%")
        interior = valor[1:-1]
        assert not any(caracter in interior for caracter in ",.()*%_")      # ninguna sintaxis del filtro sobrevive
        assert "curp" not in condicion.split(".ilike.")[0]


def test_el_caso_del_ataque_pierde_las_condiciones_extra():
    filtro = filtro_de_nombre("x,curp.like.ABC*")
    assert filtro == "primer_nombre.ilike.%x curp like ABC%,apellido_paterno.ilike.%x curp like ABC%,apellido_materno.ilike.%x curp like ABC%"
    assert "curp.like" not in filtro


@pytest.mark.parametrize("texto", ["José María", "Núñez", "ñandú", "O'Brien", "Pérez-Gómez", "Ángel Zúñiga", "d'Alessandro-Müller"])
def test_nombres_normales_con_acentos_enie_apostrofo_y_guion_se_conservan(texto):
    assert sanear_busqueda(texto) == texto
    assert filtro_de_nombre(texto) == f"primer_nombre.ilike.%{texto}%,apellido_paterno.ilike.%{texto}%,apellido_materno.ilike.%{texto}%"


def test_los_espacios_se_colapsan_y_el_guion_bajo_y_el_porcentaje_no_son_comodines():
    assert sanear_busqueda("  ana   maría_  %lópez% ") == "ana maría lópez"


@pytest.mark.parametrize("texto", SOLO_SIMBOLOS)
def test_si_tras_sanear_no_queda_nada_no_hay_filtro_y_no_se_consulta(texto):
    assert filtro_de_nombre(texto) is None
    db = MagicMock()
    assert resolver_ids_por_nombre(db, texto) == []                  # «sin coincidencias», NUNCA «todas las personas»
    db.postgrest.schema.assert_not_called()


def test_resolver_ids_por_nombre_consulta_personas_con_el_filtro_saneado_y_devuelve_los_ids():
    db = MagicMock()
    consulta = db.postgrest.schema.return_value.table.return_value.select.return_value.or_
    consulta.return_value.execute.return_value.data = [{"id": "p1"}, {"id": "p2"}]
    assert resolver_ids_por_nombre(db, "x,curp.like.*") == ["p1", "p2"]
    db.postgrest.schema.assert_called_once_with("personas")
    db.postgrest.schema.return_value.table.assert_called_once_with("persona")
    consulta.assert_called_once_with(filtro_de_nombre("x,curp.like.*"))
    assert "curp.like" not in consulta.call_args.args[0]


@pytest.mark.parametrize("modulo", ["tramos", "dias", "banco_de_horas", "ausencias"])
@pytest.mark.parametrize("texto", MALICIOSAS)
def test_los_cuatro_routers_sanean_antes_de_armar_el_or(modulo, texto):
    import importlib

    router = importlib.import_module(f"app.routers.{modulo}")
    db = MagicMock()
    or_ = db.postgrest.schema.return_value.table.return_value.select.return_value.or_
    or_.return_value.execute.return_value.data = []
    assert router._resolver_ids_por_busqueda(db, texto) == []
    for llamada in or_.call_args_list:
        condiciones = _condiciones(llamada.args[0])
        assert len(condiciones) == 3 and all(".ilike." in c for c in condiciones)
        assert "curp.like" not in llamada.args[0]


@pytest.mark.parametrize("modulo", ["tramos", "dias", "banco_de_horas", "ausencias"])
def test_los_cuatro_routers_vacios_tras_sanear_devuelven_lista_vacia_sin_consultar(modulo):
    import importlib

    router = importlib.import_module(f"app.routers.{modulo}")
    db = MagicMock()
    assert router._resolver_ids_por_busqueda(db, "%*.,()") == []
    db.postgrest.schema.assert_not_called()


def test_terminales_conserva_su_comportamiento_y_comparte_la_funcion():
    from app.routers import terminales

    assert terminales._sanear_busqueda is sanear_busqueda
    assert terminales.MIN_BUSQUEDA == 2
    assert terminales._sanear_busqueda("a,b.c") == "a b c"


def test_el_query_busqueda_persona_tiene_max_length_100_en_los_cuatro_endpoints():
    from app.main import app

    esquema = app.openapi()
    for ruta in ("/api/tramos", "/api/dias", "/api/banco-de-horas", "/api/ausencias"):
        parametros = {p["name"]: p for p in esquema["paths"][ruta]["get"]["parameters"]}
        assert parametros["busqueda_persona"]["schema"]["anyOf"][0]["maxLength"] == MAX_LARGO_BUSQUEDA == 100, ruta
    assert busqueda.MAX_LARGO_BUSQUEDA == 100


def test_ningun_modulo_fuera_de_busqueda_py_arma_un_ilike_con_texto_interpolado():
    """Guarda de CI: el filtro de nombre se arma SOLO en app/busqueda.py (con el texto ya saneado)."""
    from pathlib import Path

    raiz = Path(__file__).resolve().parents[1] / "app"
    infractores = [str(ruta.relative_to(raiz)) for ruta in sorted(raiz.rglob("*.py")) if ruta.name != "busqueda.py" and ".ilike.%{" in ruta.read_text(encoding="utf-8")]
    assert infractores == [], f"usa app.busqueda.filtro_de_nombre: {infractores}"


@pytest.mark.parametrize("nombre", ["José", "Ramón", "Núñez", "ñandú", "Ángel Zúñiga"])
def test_una_busqueda_en_nfd_conserva_los_acentos_como_la_nfc(nombre):
    """Pegado desde macOS el acento llega como letra + marca combinante (NFD): se normaliza a NFC y el filtro es idéntico al de la forma compuesta."""
    import unicodedata

    nfd = unicodedata.normalize("NFD", nombre)
    assert nfd != nombre                                       # la prueba de verdad usa la forma descompuesta
    assert sanear_busqueda(nfd) == nombre
    assert filtro_de_nombre(nfd) == filtro_de_nombre(nombre)


def test_jose_y_ramon_en_nfd_no_pierden_el_acento_ni_se_parten():
    import unicodedata

    assert sanear_busqueda(unicodedata.normalize("NFD", "José")) == "José"
    assert sanear_busqueda(unicodedata.normalize("NFD", "Ramón")) == "Ramón"
    assert "Ramo n" not in (filtro_de_nombre(unicodedata.normalize("NFD", "Ramón")) or "")


def test_la_nota_sobre_in_esta_en_el_docstring_del_modulo():
    assert "`.in_` solo con UUID/enteros/constantes; texto del cliente, jamás" in busqueda.__doc__
