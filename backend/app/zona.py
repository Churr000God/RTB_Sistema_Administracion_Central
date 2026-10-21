"""UNA sola fuente de «hoy» y «ahora» en México para todo lo que decide por DÍA de negocio (cierre de día, vigencias, ventanas de días hábiles, periodos de corte, validación de fechas).

El contenedor corre en UTC (`/etc/localtime` = Etc/UTC, sin TZ): `date.today()` y `datetime.now()` sin zona devuelven la fecha/hora UTC, que de las 18:00 a las 24:00 de México ya es «mañana». El código NO
depende de la zona del contenedor: pide la hora a esta zona explícita. Los instantes que solo se guardan o se comparan (`datetime.now(timezone.utc)`) siguen en UTC: no son «el día»."""

from datetime import date, datetime
from zoneinfo import ZoneInfo

ZONA_MEXICO = ZoneInfo("America/Mexico_City")


def ahora_mexico() -> datetime:
    return datetime.now(ZONA_MEXICO)


def hoy_mexico() -> date:
    """La fecha de HOY en México. Las pruebas congelan el reloj parcheando `app.zona.ahora_mexico`."""
    return ahora_mexico().date()
