from datetime import date, time

from app.alertas_horario import (
    TOLERANCIA_POR_DEFECTO_MIN,
    entrada_salida_programadas,
    evaluar_alertas,
    jornada_vigente,
    momento_local,
    tolerancia_vigente,
)

ENTRADA = time(8, 0)
SALIDA = time(17, 0)
TOLERANCIA = 5


def test_evaluar_alertas_retardo_con_signo():
    alerta_entrada, alerta_salida = evaluar_alertas(
        time(8, 15), SALIDA, ENTRADA, SALIDA, TOLERANCIA
    )
    assert alerta_entrada == "retardo"
    assert alerta_salida is None


def test_evaluar_alertas_entrada_anticipada():
    """Caso que alertas_de_retardo.py no distingue -- llegar muy temprano también es una alerta,
    con dirección propia."""
    alerta_entrada, _ = evaluar_alertas(time(7, 40), SALIDA, ENTRADA, SALIDA, TOLERANCIA)
    assert alerta_entrada == "entrada_anticipada"


def test_evaluar_alertas_frontera_inclusiva_no_dispara():
    """Exactamente en el límite de tolerancia -- ni retardo/anticipada ni tardía/anticipada,
    mismo criterio que el BETWEEN inclusivo del trigger."""
    alerta_entrada, alerta_salida = evaluar_alertas(
        time(8, 5), time(17, 5), ENTRADA, SALIDA, TOLERANCIA
    )
    assert alerta_entrada is None
    assert alerta_salida is None

    alerta_entrada, alerta_salida = evaluar_alertas(
        time(7, 55), time(16, 55), ENTRADA, SALIDA, TOLERANCIA
    )
    assert alerta_entrada is None
    assert alerta_salida is None


def test_evaluar_alertas_independencia_entrada_no_afecta_salida():
    """Una sola alerta puede dispararse sin la otra -- a diferencia de alertas_de_retardo.py, que
    exige que fallen las dos a la vez."""
    alerta_entrada, alerta_salida = evaluar_alertas(
        time(8, 30), SALIDA, ENTRADA, SALIDA, TOLERANCIA
    )
    assert alerta_entrada == "retardo"
    assert alerta_salida is None


def test_evaluar_alertas_salida_tardia_sin_afectar_entrada():
    alerta_entrada, alerta_salida = evaluar_alertas(
        ENTRADA, time(17, 45), ENTRADA, SALIDA, TOLERANCIA
    )
    assert alerta_entrada is None
    assert alerta_salida == "salida_tardia"


def test_evaluar_alertas_una_sola_marca_se_compara_contra_ambos_extremos():
    """Con una sola marca en el día, primera==ultima -- se compara igual contra ambos extremos,
    sin caso especial (mismo criterio que alertas_de_retardo.py)."""
    unica = time(8, 15)
    alerta_entrada, alerta_salida = evaluar_alertas(unica, unica, ENTRADA, SALIDA, TOLERANCIA)
    assert alerta_entrada == "retardo"
    assert alerta_salida == "salida_anticipada"


def test_tolerancia_vigente_por_defecto_es_cero():
    assert tolerancia_vigente([], date(2026, 9, 8)) == TOLERANCIA_POR_DEFECTO_MIN


def test_tolerancia_vigente_con_vigencias_multiples():
    tolerancias = [
        (date(2026, 6, 1), 10),
        (date(2026, 1, 1), 5),
    ]
    assert tolerancia_vigente(tolerancias, date(2026, 8, 1)) == 10
    assert tolerancia_vigente(tolerancias, date(2026, 3, 1)) == 5
    assert tolerancia_vigente(tolerancias, date(2025, 12, 1)) == TOLERANCIA_POR_DEFECTO_MIN


def test_entrada_salida_programadas_jornada_partida():
    """Jornada partida admite varias filas para el mismo día de semana -- min(hora_entrada)/
    max(hora_salida)."""
    patron_del_dia = [
        {"hora_entrada": "08:00:00", "hora_salida": "12:00:00"},
        {"hora_entrada": "14:00:00", "hora_salida": "18:00:00"},
    ]
    entrada, salida = entrada_salida_programadas(patron_del_dia)
    assert entrada == time(8, 0)
    assert salida == time(18, 0)


def test_jornada_vigente_tiebreak_por_vigente_desde_mayor():
    """Defensivo: SCJ-DEC-04 exige vigencias sin traslape, pero si dos calificaran para la misma
    fecha, gana la más reciente."""
    jornadas = [
        {"id": 1, "vigente_desde": "2026-01-01", "vigente_hasta": None},
        {"id": 2, "vigente_desde": "2026-06-01", "vigente_hasta": None},
    ]
    resultado = jornada_vigente(jornadas, date(2026, 9, 8))
    assert resultado["id"] == 2


def test_jornada_vigente_ninguna_califica_devuelve_none():
    jornadas = [{"id": 1, "vigente_desde": "2026-01-01", "vigente_hasta": "2026-02-01"}]
    assert jornada_vigente(jornadas, date(2026, 9, 8)) is None


def test_momento_local_con_desfase_negativo_cruza_a_dia_anterior():
    resultado = momento_local("2026-09-08T05:00:00+00:00", "-06:00")
    assert resultado.date() == date(2026, 9, 7)
    assert resultado.time() == time(23, 0)


def test_momento_local_con_desfase_positivo():
    resultado = momento_local("2026-09-08T05:00:00+00:00", "+02:00")
    assert resultado.date() == date(2026, 9, 8)
    assert resultado.time() == time(7, 0)
