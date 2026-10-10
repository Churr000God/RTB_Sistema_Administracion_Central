import json
import logging
import os

from fastapi import FastAPI, Request
from fastapi.exception_handlers import http_exception_handler, request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from starlette._utils import get_route_path
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from postgrest.exceptions import APIError

from app.config import parse_frontend_urls
from app.errores import CODIGOS_MIGRACION_FALTANTE, MENSAJE_DATOS_INVALIDOS
from app.interruptor_huella import PREFIJO as PREFIJO_INTERRUPTOR_HUELLA, SinCacheInterruptor
from app.respuestas_error import ErrorConCampos, manejar_error_con_campos
from app.scheduler import lifespan
from app.terminal_auth import HSTS, CabecerasTerminal, LimiteCuerpoTerminal, advertir_despliegue, es_ruta_terminal

logger = logging.getLogger(__name__)

app = FastAPI(title="SCJ — Personas y Usuarios", lifespan=lifespan)

# Se lee directo del entorno (no de app.config.Settings) para no forzar, sólo por el
# middleware de CORS, la validación de las credenciales de Supabase al importar el
# módulo — eso rompería la colección de pruebas cuando no hay .env con esas llaves.
# FRONTEND_URL admite varios orígenes separados por coma (localhost + IP de Tailscale al mismo
# tiempo, por ejemplo) -- parse_frontend_urls los separa; un solo valor sigue funcionando igual.
ORIGENES_PERMITIDOS = parse_frontend_urls(os.getenv("FRONTEND_URL", "http://localhost:5173"))

app.add_middleware(
    CORSMiddleware,
    allow_origins=ORIGENES_PERMITIDOS,
    allow_methods=["*"],
    allow_headers=["*"],
)

# HSTS en toda respuesta de /api/terminal/* (SCJ-DEC-12 §7), incluidos 401/403/429.
app.add_middleware(SinCacheInterruptor)  # Cache-Control: no-store en todo el prefijo del interruptor (nombres y notas de texto libre)
app.add_middleware(LimiteCuerpoTerminal)
app.add_middleware(CabecerasTerminal)  # el más externo: cubre también el 413 y las respuestas de los handlers

# Avisos de despliegue (FORWARDED_ALLOW_IPS='*', proxies /0): sólo WARNING, no falla el arranque.
advertir_despliegue(os.environ)


app.add_exception_handler(ErrorConCampos, manejar_error_con_campos)



def _datos_invalidos_terminal() -> JSONResponse:
    return JSONResponse(status_code=422, content={"detail": MENSAJE_DATOS_INVALIDOS})


async def manejar_validacion(request: Request, exc: RequestValidationError) -> JSONResponse:
    """En /api/terminal/* la validación del cuerpo responde SIEMPRE el mismo 422 fijo y SIN eco del input (el cuerpo del Pi podría
    llevar datos que no deben volver a salir); el resto de la API conserva el 422 estándar de FastAPI. Es un error de protocolo: el
    Pi no reintenta el mismo lote."""
    if es_ruta_terminal(get_route_path(request.scope)):
        return _datos_invalidos_terminal()
    return await request_validation_exception_handler(request, exc)


async def manejar_http(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    """Un JSON mal formado llega como 400 «error parsing the body»: en /api/terminal/* se unifica con el 422 de validación. Se
    detecta por la CAUSA (JSONDecodeError / UnicodeDecodeError), no por el texto literal que FastAPI pueda cambiar."""
    if (
        es_ruta_terminal(get_route_path(request.scope))
        and exc.status_code == 400
        and isinstance(exc.__cause__, (json.JSONDecodeError, UnicodeDecodeError))
    ):
        return _datos_invalidos_terminal()
    return await http_exception_handler(request, exc)


app.add_exception_handler(RequestValidationError, manejar_validacion)
app.add_exception_handler(StarletteHTTPException, manejar_http)

# PostgREST: función/columna/tabla inexistente = falta aplicar una migración (p. ej. 88_). Orden de despliegue: 88_ -> backend -> 89_.
MENSAJE_SERVICIO_NO_DISPONIBLE = "Servicio no disponible. Avisa a Sistemas."


def ruta_para_log(request: Request) -> str:
    """Plantilla de la ruta (`/api/terminales/{terminal_id}/usuarios`), no la URL real: así un log no lleva ids de
    personas ni caracteres de control inyectados en el path."""
    ruta = request.scope.get("route")
    return getattr(ruta, "path", None) or "(ruta sin resolver)"


@app.exception_handler(Exception)
async def manejador_excepciones_no_capturadas(request: Request, exc: Exception) -> JSONResponse:
    """Starlette trata un handler de Exception/500 como caso especial: lo conecta a
    ServerErrorMiddleware, que en el stack de middlewares queda POR FUERA de CORSMiddleware (no
    a ExceptionMiddleware, que sí queda adentro) -- verificado con una app mínima antes de
    confiar en esto, la respuesta de un handler así NUNCA lleva headers CORS aunque se registre.
    Por eso hay que agregarlos a mano acá, replicando lo que CORSMiddleware haría (bug real
    encontrado 2026-09-11 en /api/dias/{id}/previsualizar-tramos, ver bitácora: sin esto, el
    navegador reporta cualquier 500 no anticipado como bloqueo de CORS en vez del error real)."""
    logger.exception("Excepción no capturada en %s %s", request.method, ruta_para_log(request))
    respuesta = JSONResponse(status_code=500, content={"detail": "Error interno del servidor."})
    if es_ruta_terminal(request.url.path):
        # ServerErrorMiddleware queda por fuera de CabecerasTerminal: se agrega acá (SCJ-DEC-12 §7)
        respuesta.headers["Strict-Transport-Security"] = HSTS
        respuesta.headers["Cache-Control"] = "no-store"
    if request.url.path.startswith(PREFIJO_INTERRUPTOR_HUELLA):
        respuesta.headers["Cache-Control"] = "no-store"  # ServerErrorMiddleware queda por fuera de SinCacheInterruptor
        respuesta.headers["Pragma"] = "no-cache"
    origen = request.headers.get("origin")
    if origen in ORIGENES_PERMITIDOS:
        respuesta.headers["Access-Control-Allow-Origin"] = origen
        respuesta.headers["Vary"] = "Origin"
    return respuesta


async def manejador_error_postgrest(request: Request, exc: APIError) -> JSONResponse:
    """Si la base no tiene el objeto que el código espera (migración sin aplicar) se responde 503 con mensaje fijo y
    ERROR en el log (sin el texto de la base); cualquier otro APIError no anticipado sigue siendo el 500 genérico."""
    if exc.code in CODIGOS_MIGRACION_FALTANTE:
        logger.error("falta una migración en la base (PostgREST %s) en %s %s", exc.code, request.method, ruta_para_log(request))
        respuesta = JSONResponse(status_code=503, content={"detail": MENSAJE_SERVICIO_NO_DISPONIBLE})
        origen = request.headers.get("origin")
        if origen in ORIGENES_PERMITIDOS:
            respuesta.headers["Access-Control-Allow-Origin"] = origen
            respuesta.headers["Vary"] = "Origin"
        return respuesta
    return await manejador_excepciones_no_capturadas(request, exc)


app.add_exception_handler(APIError, manejador_error_postgrest)


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
from app.routers import terminal  # noqa: E402
from app.routers import terminales  # noqa: E402
from app.routers import consentimiento_terminales  # noqa: E402
from app.routers import config_terminales  # noqa: E402
from app.routers import anomalias_terminales  # noqa: E402
from app.routers import interruptor_huella  # noqa: E402

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
app.include_router(terminal.router)
app.include_router(terminales.router)
app.include_router(terminales.router_personas)
app.include_router(consentimiento_terminales.router)
app.include_router(config_terminales.router)
app.include_router(anomalias_terminales.router)
app.include_router(interruptor_huella.router)


@app.get("/salud")
def salud() -> dict:
    return {"estado": "ok"}
