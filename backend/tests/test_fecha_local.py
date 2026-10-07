from datetime import date, datetime, timezone

import pytest

from app.fecha_local import desfase_a_timedelta, fecha_local_efectiva


@pytest.mark.parametrize(
    "momento,desfase,esperada",
    [
        ("2026-10-07T03:00:00+00:00", "-06:00", date(2026, 10, 6)),  # cruza la medianoche hacia atrás
        ("2026-10-07T05:59:59Z", "-06:00", date(2026, 10, 6)),
        ("2026-10-07T06:00:00Z", "-06:00", date(2026, 10, 7)),
        ("2026-10-06T23:30:00+00:00", "+05:30", date(2026, 10, 7)),  # cruza hacia adelante
        ("2026-10-07T12:00:00", "-06:00", date(2026, 10, 7)),  # sin zona: se toma UTC
        (datetime(2026, 10, 7, 3, 0, tzinfo=timezone.utc), "-06:00", date(2026, 10, 6)),
    ],
)
def test_fecha_local_efectiva(momento, desfase, esperada):
    assert fecha_local_efectiva(momento, desfase) == esperada


@pytest.mark.parametrize("malo", ["", "-6:00", "06:00", "+0600", "x"])
def test_desfase_invalido_levanta(malo):
    with pytest.raises(ValueError):
        desfase_a_timedelta(malo)
