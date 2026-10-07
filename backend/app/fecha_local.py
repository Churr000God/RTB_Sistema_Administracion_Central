"""Fecha local EFECTIVA de una marca (mismo criterio que `tiempo.fn_marca_fecha_local`, 86_*.sql, y que
`fn_dia_calcular_armado_tramos`/el batch de cierre de día): valor de la corrección más reciente si
existe, si no `momento_dispositivo`; más `desfase_local` (±HH:MM). Es la fecha del `tiempo.dia` al
que pertenece la marca, que es lo que importa para saber si una excepción `dia_cerrado` se resuelve
revisando el día o descartando la marca (SCJ-DEC-06)."""

import re
from datetime import date, datetime, timedelta, timezone

_DESFASE = re.compile(r"([+-])(\d{2}):(\d{2})")


def a_datetime(valor: str | datetime) -> datetime:
    if isinstance(valor, datetime):
        resultado = valor
    else:
        resultado = datetime.fromisoformat(valor.replace("Z", "+00:00"))
    return resultado if resultado.tzinfo else resultado.replace(tzinfo=timezone.utc)


def desfase_a_timedelta(desfase: str) -> timedelta:
    coincidencia = _DESFASE.fullmatch(desfase)
    if not coincidencia:
        raise ValueError(f"desfase_local inválido: {desfase!r}")
    signo = -1 if coincidencia.group(1) == "-" else 1
    return signo * timedelta(hours=int(coincidencia.group(2)), minutes=int(coincidencia.group(3)))


def fecha_local_efectiva(momento: str | datetime, desfase: str) -> date:
    """`momento` es el valor EFECTIVO (corregido o el del dispositivo)."""
    return (a_datetime(momento).astimezone(timezone.utc) + desfase_a_timedelta(desfase)).date()
