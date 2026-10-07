"""SCJ-DEC-12 §1 / B4: script de TI que provisiona la llave de la terminal. Mocks del cliente de
Supabase -- NUNCA se ejecuta contra la base real. La llave se muestra UNA vez en pantalla y sólo
su hash viaja a la base; no se escribe en logs ni se imprime el hash."""

import hashlib
import importlib.util
import logging
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from postgrest import ReturnMethod

from app import terminal_auth

RUTA = Path(__file__).resolve().parents[1] / "scripts" / "alta_credencial_terminal.py"
SERIE = "TERM-FICTICIA-01"


def _cargar_script():
    spec = importlib.util.spec_from_file_location("alta_credencial_terminal", RUTA)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


@pytest.fixture
def script():
    return _cargar_script()


def _db(terminal=({"id": 5, "terminal_id": SERIE, "activa": True},)):
    db = MagicMock()
    tabla = MagicMock()
    tabla.select.return_value.eq.return_value.execute.return_value.data = list(terminal)
    db.postgrest.schema.return_value.table.return_value = tabla
    return db, tabla


def test_el_script_corre_con_help_como_proceso_aparte():
    resultado = subprocess.run(
        [sys.executable, str(RUTA), "--help"], capture_output=True, text=True, timeout=60
    )
    assert resultado.returncode == 0, resultado.stderr
    assert "--serie" in resultado.stdout and "--etiqueta" in resultado.stdout
    ayuda = " ".join(resultado.stdout.split())
    assert "NO redirijas la salida" in ayuda
    assert "scrollback" in ayuda


def test_registrar_credencial_inserta_solo_el_hash_y_devuelve_la_llave(script):
    db, tabla = _db()
    llave = script.registrar_credencial(db, SERIE, "Pi original")
    assert terminal_auth.FORMATO_LLAVE.fullmatch(llave)
    args, kwargs = tabla.insert.call_args
    carga = args[0]
    assert carga == {
        "terminal_id": 5,
        "hash": hashlib.sha256(llave.encode()).hexdigest(),
        "etiqueta": "Pi original",
    }
    assert llave not in repr(carga)
    assert kwargs["returning"] == ReturnMethod.minimal  # no trae de vuelta ni el hash


def test_la_etiqueta_es_opcional(script):
    db, tabla = _db()
    script.registrar_credencial(db, SERIE, None)
    assert tabla.insert.call_args.args[0]["etiqueta"] is None


def test_terminal_inexistente_falla_sin_insertar(script):
    db, tabla = _db(terminal=())
    with pytest.raises(script.ErrorProvision):
        script.registrar_credencial(db, "NO-EXISTE", None)
    tabla.insert.assert_not_called()


def test_terminal_inactiva_falla_sin_insertar(script):
    db, tabla = _db(terminal=({"id": 5, "terminal_id": SERIE, "activa": False},))
    with pytest.raises(script.ErrorProvision):
        script.registrar_credencial(db, SERIE, None)
    tabla.insert.assert_not_called()


def test_main_muestra_la_llave_una_vez_y_nunca_el_hash(script, capsys, caplog):
    db, tabla = _db()
    with caplog.at_level(logging.DEBUG):
        codigo = script.main(["--serie", SERIE, "--etiqueta", "Pi original"], db=db)
    salida = capsys.readouterr()
    llave = tabla.insert.call_args.args[0]["hash"]  # sólo para obtener el hash del insert
    assert codigo == 0
    encontradas = [t for t in salida.out.split() if t.startswith("scjt_")]
    assert len(encontradas) == 1
    assert terminal_auth.FORMATO_LLAVE.fullmatch(encontradas[0])
    assert hashlib.sha256(encontradas[0].encode()).hexdigest() == llave
    assert llave not in salida.out and llave not in salida.err
    assert encontradas[0] not in salida.err
    assert "una sola vez" in salida.out.lower()
    # nada de la llave ni del hash en los logs
    assert encontradas[0] not in caplog.text and llave not in caplog.text


def test_main_sale_con_codigo_1_y_sin_llave_si_la_terminal_no_existe(script, capsys):
    db, tabla = _db(terminal=())
    codigo = script.main(["--serie", "NO-EXISTE"], db=db)
    salida = capsys.readouterr()
    assert codigo == 1
    assert "scjt_" not in salida.out
    tabla.insert.assert_not_called()


def test_main_rechaza_una_etiqueta_de_mas_de_60_caracteres(script):
    db, tabla = _db()
    with pytest.raises(SystemExit):
        script.main(["--serie", SERIE, "--etiqueta", "x" * 61], db=db)
    tabla.insert.assert_not_called()


def test_main_exige_la_serie(script):
    db, _ = _db()
    with pytest.raises(SystemExit):
        script.main([], db=db)


def test_si_el_insert_falla_no_se_muestra_ninguna_llave(script, capsys):
    db, tabla = _db()
    tabla.insert.return_value.execute.side_effect = RuntimeError("caída")
    codigo = script.main(["--serie", SERIE], db=db)
    salida = capsys.readouterr()
    assert codigo == 1
    assert "scjt_" not in salida.out
    assert "scjt_" not in salida.err


def test_la_etiqueta_se_sanea_de_caracteres_de_control_como_en_sql(script):
    db, tabla = _db()
    script.registrar_credencial(db, SERIE, "  Pi\x00 ori\x07gi\x1bnal\x7f\x85  ")
    assert tabla.insert.call_args.args[0]["etiqueta"] == "Pi original"


@pytest.mark.parametrize("entrada,esperado", [("\x00\x1f", None), ("   ", None), (None, None), ("ok", "ok")])
def test_sanear_etiqueta_vacia_o_nula_queda_en_none(script, entrada, esperado):
    assert script.sanear_etiqueta(entrada) == esperado


def test_el_largo_de_la_etiqueta_se_mide_tras_el_saneo(script):
    db, tabla = _db()
    # 60 caracteres útiles + controles: pasa; 61 útiles: no
    assert script.main(["--serie", SERIE, "--etiqueta", "a" * 60 + "\x01\x02"], db=db) == 0
    with pytest.raises(SystemExit):
        script.main(["--serie", SERIE, "--etiqueta", "a" * 61], db=db)
