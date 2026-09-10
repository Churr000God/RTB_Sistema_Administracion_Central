#!/usr/bin/env bash
# Script de despliegue del Sistema de Control de Jornada (SCJ).
#
# Levanta backend (FastAPI) y frontend (Vite/React) con Docker Compose. No
# levanta base de datos: la BD es un proyecto de Supabase remoto (ver
# CLAUDE.md), este script sólo orquesta los dos servicios que sí corren local.
#
# Uso:
#   scripts/desplegar.sh [entorno] <accion>
#
#   entorno: dev (default) | prod
#   accion:  levantar | bajar | reconstruir | registros | pruebas | estado
#
# Ejemplos:
#   scripts/desplegar.sh levantar          # dev, con hot reload
#   scripts/desplegar.sh prod levantar     # producción, nginx + uvicorn sin --reload
#   scripts/desplegar.sh dev pruebas       # corre pytest y vitest dentro de los contenedores
#   scripts/desplegar.sh dev registros     # sigue los logs de ambos servicios
#
# 'prod pruebas' no existe: la imagen prod del backend no tiene pytest
# (--no-dev) y el frontend prod es nginx sin npm. Pruebas siempre corren
# contra las imágenes dev.
#
# 'levantar' también bootstrapea el "usuario base" (SCJ-PRO-05) si hace falta: la
# primera vez, pregunta correo+contraseña (sin eco) para crear su acceso a Kairos;
# despliegues posteriores del mismo entorno no repreguntan. Requiere 'uv' en el host
# (habla con Supabase directo, no con los contenedores) -- ver scripts/bootstrap_usuario_base.py.

set -euo pipefail

SCRIPT_ABSOLUTO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

ENTORNOS_VALIDOS=("dev" "prod")
ACCIONES_VALIDAS=("levantar" "bajar" "reconstruir" "registros" "pruebas" "estado")

uso() {
  sed -n '2,27p' "$SCRIPT_ABSOLUTO" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- parseo de argumentos ---------------------------------------------------

ENTORNO="dev"
if [[ "${1:-}" == "dev" || "${1:-}" == "prod" ]]; then
  ENTORNO="$1"
  shift
fi

ACCION="${1:-}"
if [[ -z "$ACCION" ]]; then
  echo "Error: falta la acción." >&2
  uso
fi

valido() {
  local valor="$1"; shift
  for v in "$@"; do [[ "$valor" == "$v" ]] && return 0; done
  return 1
}

if ! valido "$ACCION" "${ACCIONES_VALIDAS[@]}"; then
  echo "Error: acción '$ACCION' no reconocida. Válidas: ${ACCIONES_VALIDAS[*]}" >&2
  uso
fi

# --- validaciones previas ----------------------------------------------------

if ! command -v docker &>/dev/null; then
  echo "Error: no se encontró 'docker'. Instálalo antes de continuar." >&2
  exit 1
fi

if ! docker compose version &>/dev/null; then
  echo "Error: 'docker compose' no está disponible (¿falta el plugin?)." >&2
  exit 1
fi

verificar_env() {
  local archivo="$1" ejemplo="$2"
  if [[ ! -f "$archivo" ]]; then
    echo "Error: falta $archivo." >&2
    echo "  Cópialo desde la plantilla y llénalo con los valores del proyecto de Supabase:" >&2
    echo "  cp $ejemplo $archivo" >&2
    exit 1
  fi
}

verificar_valor_no_vacio() {
  local archivo="$1" clave="$2"
  local valor
  valor="$(grep -E "^${clave}=" "$archivo" | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "$valor" ]]; then
    echo "Error: $clave está vacío en $archivo. Llénalo con el valor real del dashboard de Supabase." >&2
    exit 1
  fi
}

validar_configuracion() {
  verificar_env ".env" ".env.example"
  verificar_env "frontend/.env" "frontend/.env.example"
  verificar_valor_no_vacio ".env" "SUPABASE_URL"
  verificar_valor_no_vacio ".env" "SUPABASE_ANON_KEY"
  verificar_valor_no_vacio ".env" "SUPABASE_SERVICE_ROLE_KEY"
  verificar_valor_no_vacio "frontend/.env" "VITE_SUPABASE_URL"
  verificar_valor_no_vacio "frontend/.env" "VITE_SUPABASE_ANON_KEY"
}

# --- armado del comando compose ---------------------------------------------

ARCHIVOS_COMPOSE=(-f docker-compose.yml)
if [[ "$ENTORNO" == "prod" ]]; then
  ARCHIVOS_COMPOSE+=(-f docker-compose.prod.yml)
fi

compose() {
  docker compose "${ARCHIVOS_COMPOSE[@]}" "$@"
}

# El build de producción necesita las VITE_* como variables de entorno reales
# al momento de invocar `docker compose build` (son build.args, no env_file) --
# se exportan aquí desde frontend/.env sin imprimir su contenido.
exportar_variables_build_frontend() {
  set -a
  # shellcheck disable=SC1091
  source frontend/.env
  set +a
}

# Bootstrap del usuario base (SCJ-PRO-05, ver bitácora del corte de puesto_permiso): la
# única pieza del bootstrap de un despliegue nuevo que no puede ser SQL puro, porque
# necesita un auth.users real que sólo la Admin API de Supabase puede emitir. Se detecta
# primero si ya existe (scripts/bootstrap_usuario_base.py verificar) para no repreguntar
# en despliegues subsecuentes del mismo entorno. Habla directo con Supabase (no con los
# contenedores), corre en el host vía `uv run` con el entorno de backend/ -- mismo patrón
# que ya usa el proyecto para el generador de datos sintéticos.
bootstrap_usuario_base() {
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a

  local estado
  estado="$(cd backend && uv run python "$RAIZ/scripts/bootstrap_usuario_base.py" verificar)"

  case "$estado" in
    EXISTE)
      return 0
      ;;
    FALTA_PERSONA)
      echo "Aviso: no existe todavía la persona de bootstrap (falta aplicar" >&2
      echo "  db/ddl/26_puesto_permiso_bootstrap_admin_generico.sql). Se omite el paso" >&2
      echo "  de usuario base." >&2
      return 0
      ;;
    FALTA) ;;
    *)
      echo "Error: respuesta inesperada de bootstrap_usuario_base.py verificar: '$estado'" >&2
      return 1
      ;;
  esac

  echo
  echo "== Usuario base de bootstrap =="
  echo "No existe todavía un acceso a Kairos para la persona de bootstrap. Se crea ahora"
  echo "(sólo se pregunta esta vez -- despliegues posteriores de este entorno no repreguntan)."
  local correo contrasena contrasena_confirmar resultado
  read -r -p "Correo del usuario base: " correo
  read -r -s -p "Contraseña: " contrasena
  echo
  read -r -s -p "Confirmar contraseña: " contrasena_confirmar
  echo
  if [[ "$contrasena" != "$contrasena_confirmar" ]]; then
    echo "Error: las contraseñas no coinciden. No se creó el usuario base." >&2
    unset contrasena contrasena_confirmar
    return 1
  fi
  unset contrasena_confirmar

  (cd backend && BOOTSTRAP_CORREO="$correo" BOOTSTRAP_CONTRASENA="$contrasena" \
    uv run python "$RAIZ/scripts/bootstrap_usuario_base.py" crear)
  resultado=$?
  unset contrasena BOOTSTRAP_CONTRASENA correo
  return $resultado
}

# --- acciones ----------------------------------------------------------------

case "$ACCION" in
  levantar)
    validar_configuracion
    if [[ "$ENTORNO" == "prod" ]]; then
      exportar_variables_build_frontend
    fi
    compose up -d --build
    bootstrap_usuario_base
    echo
    echo "Servicios arriba ($ENTORNO):"
    if [[ "$ENTORNO" == "dev" ]]; then
      echo "  Backend:  http://localhost:8000  (docs en /docs, salud en /salud)"
      echo "  Frontend: http://localhost:5173"
    else
      echo "  Backend:  http://localhost:8000"
      echo "  Frontend: http://localhost:8080"
      echo
      echo "Recuerda: FRONTEND_URL en .env y la lista de Redirect URLs del dashboard de"
      echo "Supabase deben apuntar a http://localhost:8080 en este entorno, o la"
      echo "invitación/recuperación de contraseña no va a aterrizar en la app."
    fi
    ;;

  bajar)
    compose down
    ;;

  reconstruir)
    if [[ "$ENTORNO" == "prod" ]]; then
      exportar_variables_build_frontend
    fi
    compose build --no-cache
    ;;

  registros)
    compose logs -f
    ;;

  pruebas)
    if [[ "$ENTORNO" == "prod" ]]; then
      echo "Error: 'prod pruebas' no es soportado." >&2
      echo "  La imagen prod del backend se instala con --no-dev (sin pytest) y el" >&2
      echo "  frontend prod es nginx sirviendo el bundle compilado (sin npm/node)." >&2
      echo "  Corre las pruebas con: scripts/desplegar.sh dev pruebas" >&2
      exit 1
    fi
    echo "== Backend (pytest) =="
    compose exec backend uv run pytest
    echo
    echo "== Frontend (vitest) =="
    compose exec frontend npm test -- --run
    ;;

  estado)
    compose ps
    ;;
esac
