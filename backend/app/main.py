import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import parse_frontend_urls
from app.scheduler import lifespan

app = FastAPI(title="SCJ — Personas y Usuarios", lifespan=lifespan)

# Se lee directo del entorno (no de app.config.Settings) para no forzar, sólo por el
# middleware de CORS, la validación de las credenciales de Supabase al importar el
# módulo — eso rompería la colección de pruebas cuando no hay .env con esas llaves.
# FRONTEND_URL admite varios orígenes separados por coma (localhost + IP de Tailscale al mismo
# tiempo, por ejemplo) -- parse_frontend_urls los separa; un solo valor sigue funcionando igual.
app.add_middleware(
    CORSMiddleware,
    allow_origins=parse_frontend_urls(os.getenv("FRONTEND_URL", "http://localhost:5173")),
    allow_methods=["*"],
    allow_headers=["*"],
)

from app.routers import personas  # noqa: E402
from app.routers import usuarios  # noqa: E402
from app.routers import movimientos  # noqa: E402
from app.routers import sesion  # noqa: E402
from app.routers import areas  # noqa: E402
from app.routers import departamentos  # noqa: E402
from app.routers import puestos  # noqa: E402
from app.routers import asignaciones  # noqa: E402
from app.routers import permisos  # noqa: E402
from app.routers import jornada_asignada  # noqa: E402
from app.routers import corridas_batch  # noqa: E402
from app.routers import marcas  # noqa: E402
from app.routers import correcciones  # noqa: E402
from app.routers import ausencias  # noqa: E402
from app.routers import excepciones  # noqa: E402
from app.routers import banco_de_horas  # noqa: E402
from app.routers import alertas_de_retardo  # noqa: E402
from app.routers import tope_legal  # noqa: E402
from app.routers import dias_festivos  # noqa: E402
from app.routers import parametros  # noqa: E402
from app.routers import tramos  # noqa: E402
from app.routers import dias  # noqa: E402

app.include_router(personas.router)
app.include_router(usuarios.router)
app.include_router(movimientos.router)
app.include_router(sesion.router)
app.include_router(areas.router)
app.include_router(departamentos.router)
app.include_router(puestos.router)
app.include_router(asignaciones.router)
app.include_router(permisos.router)
app.include_router(jornada_asignada.router)
app.include_router(jornada_asignada.router_persona)
app.include_router(corridas_batch.router)
app.include_router(marcas.router)
app.include_router(correcciones.router)
app.include_router(ausencias.router)
app.include_router(excepciones.router)
app.include_router(banco_de_horas.router)
app.include_router(alertas_de_retardo.router)
app.include_router(tope_legal.router)
app.include_router(dias_festivos.router)
app.include_router(parametros.router)
app.include_router(tramos.router)
app.include_router(dias.router)


@app.get("/salud")
def salud() -> dict:
    return {"estado": "ok"}
