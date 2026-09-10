# Backend SCJ — FastAPI + uv.
#
# Dos targets: `dev` (hot reload, incluye pytest) y `prod` (sin dependencias de
# desarrollo, sin --reload, usuario no-root). El compose de dev usa `dev`; el
# override de producción usa `prod`.

FROM python:3.11-slim AS base

# uv se copia del binario oficial en vez de instalarse con pip — más rápido y
# reproducible (misma técnica que recomienda la doc de Astral).
COPY --from=ghcr.io/astral-sh/uv:0.12.5 /uv /uvx /usr/local/bin/

WORKDIR /app

# Sin esto, uv intenta compilar/enlazar hardlinks entre la caché y /app, que no
# funciona entre filesystems distintos (caché en una capa, /app en otra).
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_HTTP_TIMEOUT=120 \
    PYTHONUNBUFFERED=1

# Copiar sólo los manifiestos primero: si el código cambia pero las dependencias
# no, esta capa se reusa de la caché de Docker.
COPY pyproject.toml uv.lock ./

# --- dev -----------------------------------------------------------------
FROM base AS dev
RUN uv sync --frozen
COPY . .
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
    CMD uv run python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/salud')" || exit 1
# El compose de dev monta ./backend:/app encima de la imagen y guarda .venv en
# un volumen nombrado aparte -- ese volumen nace vacío la primera vez, así que
# hay que repetir `uv sync` al arrancar (idempotente, rápido si ya está listo).
CMD ["sh", "-c", "uv sync --frozen && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload"]

# --- prod ------------------------------------------------------------------
FROM base AS prod
RUN uv sync --frozen --no-dev
COPY app ./app

# `uv run` re-sincroniza el proyecto (con el grupo dev incluido) en cada
# arranque salvo que se le diga que no lo haga -- sin esto, el usuario no-root
# de abajo no puede escribir en .venv (quedó dueño de root) y el contenedor
# revienta en el primer arranque con "Permission denied".
ENV UV_NO_SYNC=1

RUN useradd --create-home --shell /usr/sbin/nologin scj && chown -R scj:scj /app
USER scj

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD uv run python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/salud')" || exit 1
CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
