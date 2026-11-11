"""Tipo de id compartido por routers y schemas de entrada: un `str` que debe ser un UUID válido, devuelto en forma canónica.

Un id que no es UUID llegaba tal cual a PostgREST, Postgres fallaba con 22P02 y el endpoint respondía 500. Con este tipo FastAPI responde 422 antes de tocar la base.
Se queda como `str` (no `uuid.UUID`) para que helpers, filtros de supabase-py y el JSON de salida no cambien.

Se devuelve `str(UUID(valor))` (minúsculas con guiones) y no el texto original: Postgres acepta MAYÚSCULAS, `{…}` y sin guiones, y esas formas pasaban a la base pero rompían las comparaciones de
strings en Python (`datos.puesto_id in <ids de la base>` daba False y evadía la regla anti auto-otorgamiento). `uuid.UUID()` también acepta formas que `uuid_in` de Postgres rechaza
(`urn:uuid:…`, `uuid:…`), pero como se normaliza, a la base solo llega la forma canónica."""

from typing import Annotated
from uuid import UUID

from pydantic import AfterValidator


def _validar_uuid(valor: str) -> str:
    try:
        return str(UUID(valor))
    except ValueError as exc:
        raise ValueError("Debe ser un UUID válido.") from exc


IdUuid = Annotated[str, AfterValidator(_validar_uuid)]
