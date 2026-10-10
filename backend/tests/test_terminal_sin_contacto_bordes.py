"""Tarjeta 15 (terminal sin contacto) con `ingesta_detenida` y el estado de contacto: huecos que dejó la mutación manual (99_). Reutiliza el fixture y los ayudantes de
test_terminales_c8.py. Mocks por nombre de tabla; NUNCA contra la base real."""

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app import anomalias_terminal
from app.contacto_terminal import estado_contacto, ultimo_contacto
from test_terminales_c8 import _hace, _t15, entorno  # noqa: F401  (entorno es un fixture)


def test_la_ingesta_detenida_alarma_en_atender_aunque_el_contacto_sea_fresco(entorno):
    t = _t15(entorno, ultimo_contacto_en=_hace(seconds=20), ingesta_detenida=True)
    assert (t["estado"], t["nivel"], t["total"]) == ("con_hallazgos", "atender", 1)
    assert t["ejemplos"] == [{"codigo": "ingesta_detenida", "mensaje": "La ingesta del puente está detenida y espera a una persona.", "minutos_sin_latido": 0}]


@pytest.mark.parametrize("valor", [False, None])
def test_sin_ingesta_detenida_o_sin_reportarla_no_hay_hallazgo(entorno, valor):
    t = _t15(entorno, ultimo_contacto_en=_hace(seconds=20), ingesta_detenida=valor)
    assert t["estado"] == "sin_hallazgos" and t["total"] == 0


@pytest.mark.parametrize("valor", [1, "true", "True", "yes", 0, [True]])
def test_solo_un_booleano_real_en_la_fila_cuenta_como_ingesta_detenida(entorno, valor):
    t = _t15(entorno, ultimo_contacto_en=_hace(seconds=20), ingesta_detenida=valor)
    assert t["estado"] == "sin_hallazgos" and t["total"] == 0


def test_una_terminal_inactiva_no_alarma_aunque_reporte_la_ingesta_detenida(entorno):
    t = _t15(entorno, activa=False, ultimo_contacto_en=_hace(minutes=1), ingesta_detenida=True)
    assert t["estado"] == "sin_hallazgos"


def test_sin_latido_y_ingesta_detenida_juntos_son_dos_hallazgos_y_el_nivel_es_atender(entorno):
    t = _t15(entorno, ultimo_contacto_en=_hace(minutes=7), ingesta_detenida=True)
    assert (t["nivel"], t["total"]) == ("atender", 2)
    assert [e["codigo"] for e in t["ejemplos"]] == ["sin_latido_revisar", "ingesta_detenida"]
    assert t["ejemplos"][1]["minutos_sin_latido"] == 7


def test_nunca_comunicada_con_ingesta_detenida_son_dos_hallazgos_y_el_segundo_no_inventa_minutos(entorno):
    t = _t15(entorno, ultimo_contacto_en=None, ingesta_detenida=True)
    assert (t["nivel"], t["total"]) == ("atender", 2)
    assert [(e["codigo"], e["minutos_sin_latido"]) for e in t["ejemplos"]] == [("nunca_comunicada", None), ("ingesta_detenida", None)]


def test_el_nivel_atender_por_ingesta_detenida_aplica_aunque_no_sea_el_primer_hallazgo(entorno):
    t = _t15(entorno, ultimo_contacto_en=_hace(minutes=6), ingesta_detenida=True)
    assert t["ejemplos"][0]["codigo"] == "sin_latido_revisar" and t["nivel"] == "atender"


def _ctx(**kw):
    base = dict(contacto_ilegible=False, activa=True, ultimo_contacto_en=datetime(2026, 10, 12, 18, tzinfo=timezone.utc), ahora=datetime(2026, 10, 12, 18, 0, 5, tzinfo=timezone.utc),
                umbral_sin_contacto_seg=300, ingesta_detenida=None)
    return SimpleNamespace(**(base | kw))


@pytest.mark.parametrize("valor", [1, "true", "x"])
def test_la_regla_exige_un_true_exacto_no_un_valor_verdadero(valor):
    assert anomalias_terminal._terminal_sin_contacto(_ctx(ingesta_detenida=valor), 5, 0) == (0, [])


def test_la_regla_con_true_exacto_da_un_hallazgo():
    total, ejemplos = anomalias_terminal._terminal_sin_contacto(_ctx(ingesta_detenida=True), 5, 0)
    assert total == 1 and ejemplos[0]["codigo"] == "ingesta_detenida"


def test_la_regla_con_contacto_ilegible_lanza_y_no_disfraza_de_nunca():
    with pytest.raises(ValueError):
        anomalias_terminal._terminal_sin_contacto(_ctx(contacto_ilegible=True), 5, 0)


# --- contacto_terminal ---------------------------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("bruto,esperado", [(None, (None, False)), ("", (None, False)), (0, (None, False))])
def test_un_ultimo_contacto_vacio_es_nunca_no_ilegible(bruto, esperado):
    assert ultimo_contacto({"id": 1, "ultimo_contacto_en": bruto}) == esperado


@pytest.mark.parametrize("bruto", ["no-es-fecha", "2026-99-99T00:00:00Z", 12345, [1]])
def test_un_ultimo_contacto_no_parseable_es_ilegible(bruto):
    assert ultimo_contacto({"id": 1, "ultimo_contacto_en": bruto}) == (None, True)


def test_estado_de_contacto_en_los_bordes_del_umbral_y_con_reloj_adelantado():
    ahora = datetime(2026, 10, 12, 18, tzinfo=timezone.utc)
    assert estado_contacto(True, ahora - timedelta(seconds=299), ahora, 300) == ("en_linea", 299)
    assert estado_contacto(True, ahora - timedelta(seconds=300), ahora, 300) == ("sin_contacto", 300)
    assert estado_contacto(True, ahora + timedelta(seconds=90), ahora, 300) == ("en_linea", 0)      # contacto «en el futuro»: 0 s, no negativo
    assert estado_contacto(True, None, ahora, 300) == ("nunca", None)
    assert estado_contacto(False, None, ahora, 300) == ("inactiva", None)
    assert estado_contacto(False, ahora - timedelta(hours=9), ahora, 300) == ("inactiva", 32400)
