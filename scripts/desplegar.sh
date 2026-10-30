#!/usr/bin/env bash
# Script de despliegue del Sistema de Control de Jornada (SCJ).
#
# Levanta backend (FastAPI) y frontend (Vite/React) con Docker Compose. No
# levanta base de datos: la BD es un proyecto de Supabase remoto (ver
# CLAUDE.md), este script sólo orquesta los dos servicios que sí corren local.
#
# Uso:
#   scripts/desplegar.sh [entorno] <accion> [servicio]
#
#   entorno: dev (default) | prod
#   accion:  levantar [servicio] | bajar | reconstruir | registros | pruebas | estado
#
# Ejemplos:
#   scripts/desplegar.sh levantar               # dev, con hot reload
#   scripts/desplegar.sh prod levantar          # producción, nginx + uvicorn sin --reload
#   scripts/desplegar.sh prod levantar backend  # sólo ese servicio (--no-deps), el otro sigue arriba
#   scripts/desplegar.sh dev pruebas            # corre pytest y vitest dentro de los contenedores
#   scripts/desplegar.sh dev registros          # sigue los logs de ambos servicios
#
# 'prod pruebas' no existe: la imagen prod del backend no tiene pytest
# (--no-dev) y el frontend prod es nginx sin npm. Pruebas siempre corren
# contra las imágenes dev.
#
# Perfil de máquina (sólo prod): DESPLEGAR_PERFIL=pi|ninguno. Si la variable no está
# definida o está vacía, se lee de .perfil-despliegue en la raíz del clon (archivo local,
# no versionado). En el Pi de pruebas ese archivo contiene "pi" y suma docker-compose.pi.yml.
#
# 'levantar' también bootstrapea el "usuario base" (SCJ-PRO-05) si hace falta: la
# primera vez, pregunta correo+contraseña (sin eco) para crear su acceso al sistema;
# despliegues posteriores del mismo entorno no repreguntan. Requiere 'uv' en el host
# (habla con Supabase directo, no con los contenedores) -- ver scripts/bootstrap_usuario_base.py.
# Sin 'uv' (el Pi de pruebas) se avisa y se omiten la verificación de esquema y el bootstrap.

set -euo pipefail

SCRIPT_ABSOLUTO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

ENTORNOS_VALIDOS=("dev" "prod")
ACCIONES_VALIDAS=("levantar" "bajar" "reconstruir" "registros" "pruebas" "estado")

uso() {
  sed -n '2,33p' "$SCRIPT_ABSOLUTO" | sed 's/^# \{0,1\}//'
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

# Servicio puntual (sólo 'levantar'): sube ese servicio con --no-deps y deja el resto como está.
SERVICIO="${2:-}"
if [[ -n "$SERVICIO" && "$ACCION" != "levantar" ]]; then
  echo "Error: sólo 'levantar' acepta un servicio puntual." >&2
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

# Perfil de máquina. Criterio: la variable gana sólo si trae un valor; vacía cuenta como no definida
# (un `DESPLEGAR_PERFIL= ./scripts/...` o un export vacío no apaga en silencio el perfil del archivo).
# Para desactivar el perfil a propósito en una máquina que tiene el archivo: DESPLEGAR_PERFIL=ninguno.
# El 29-oct-2026 un despliegue en el Pi sin DESPLEGAR_PERFIL=pi dejó el 8000 en 0.0.0.0; por eso el
# perfil vive en un archivo de la máquina y no depende de acordarse de la variable.
ARCHIVO_PERFIL=".perfil-despliegue"

resolver_perfil() {
  local perfil="${DESPLEGAR_PERFIL:-}" origen="DESPLEGAR_PERFIL"
  if [[ -z "$perfil" && -f "$ARCHIVO_PERFIL" ]]; then
    # Primera línea que no sea comentario ni vacía, sin espacios.
    perfil="$(grep -vE '^[[:space:]]*(#|$)' "$ARCHIVO_PERFIL" | head -n1 | tr -d '[:space:]' || true)"
    origen="$ARCHIVO_PERFIL"
  fi
  [[ -n "$perfil" ]] || origen="por defecto"
  case "$perfil" in
    "" | ninguno) PERFIL="ninguno" ;;
    pi) PERFIL="pi" ;;
    *)
      echo "Error: perfil '$perfil' no reconocido (leído de $origen). Válidos: pi, ninguno." >&2
      exit 1
      ;;
  esac
  PERFIL_ORIGEN="$origen"
}

PERFIL="ninguno"
PERFIL_ORIGEN="ninguno"
ARCHIVOS_COMPOSE=(-f docker-compose.yml)
if [[ "$ENTORNO" == "prod" ]]; then
  resolver_perfil
  ARCHIVOS_COMPOSE+=(-f docker-compose.prod.yml)
  # Perfil del Pi de pruebas: bind 127.0.0.1:8000, subred fija y límite de logs.
  if [[ "$PERFIL" == "pi" ]]; then
    ARCHIVOS_COMPOSE+=(-f docker-compose.pi.yml)
  fi
fi

compose() {
  docker compose "${ARCHIVOS_COMPOSE[@]}" "$@"
}

# Si en esta máquina `tailscale serve` publica 127.0.0.1:8000, el backend DEBE ir con el perfil pi:
# sin él, docker-compose.prod.yml publica el 8000 en 0.0.0.0 (API en http plano por la LAN).
# Sin `tailscale` instalado (laptop) o si no se puede leer su estado, no se bloquea nada.
verificar_perfil_contra_tailscale() {
  [[ "$ENTORNO" == "prod" && "$PERFIL" != "pi" ]] || return 0
  command -v tailscale &>/dev/null || return 0
  local estado
  estado="$(tailscale serve status --json 2>/dev/null || true)"
  if grep -qE '"Proxy"[[:space:]]*:[[:space:]]*"https?://(127\.0\.0\.1|localhost):8000/?"' <<<"$estado"; then
    echo "Error: esta máquina publica 127.0.0.1:8000 por 'tailscale serve', pero el perfil es '$PERFIL'" >&2
    echo "  (origen: $PERFIL_ORIGEN). Sin el perfil pi el backend quedaría en 0.0.0.0:8000." >&2
    echo "  Crea el archivo de perfil:  echo pi > $RAIZ/$ARCHIVO_PERFIL" >&2
    echo "  (DESPLEGAR_PERFIL=ninguno no se acepta en una máquina así: es justo el error que esto evita.)" >&2
    exit 1
  fi
}

mostrar_archivos_compose() {
  [[ "$ENTORNO" == "prod" ]] || return 0
  local archivos=() i
  for ((i = 1; i < ${#ARCHIVOS_COMPOSE[@]}; i += 2)); do archivos+=("${ARCHIVOS_COMPOSE[i]}"); done
  echo "Perfil: $PERFIL (origen: $PERFIL_ORIGEN)"
  echo "Archivos compose: ${archivos[*]}"
}

# Un `up --no-deps <servicio>` no puede recrear la red del proyecto si otro contenedor sigue
# conectado: si cambió su configuración (p. ej. el IPAM fijo de docker-compose.pi.yml), compose
# intenta borrarla, falla y deja el servicio CAÍDO (pasó el 30-oct-2026). Se le pregunta al propio
# compose con --dry-run: si planea borrar una red, la acción parcial no es segura. Esto usa la misma
# comparación que compose (hash de configuración de la red, IPAM incluido), no sólo la subred.
# Devuelve 0 si la red se puede conservar, 1 si compose la recrearía; aborta si no se puede saber.
red_se_conserva_en_parcial() {
  local servicio="$1" plan
  if ! plan="$(compose --dry-run up -d --no-deps "$servicio" 2>&1)"; then
    echo "Error: no se pudo simular el despliegue parcial (docker compose --dry-run):" >&2
    printf '  %s\n' "$plan" | tail -n 5 >&2
    echo "  Usa el levantamiento completo: scripts/desplegar.sh $ENTORNO levantar" >&2
    exit 1
  fi
  ! grep -qE '^[[:space:]]*Network[[:space:]].*[[:space:]]Remov' <<<"$plan"
}

confirmar() {
  local pregunta="$1" respuesta
  if [[ ! -t 0 ]]; then
    echo "Sin terminal interactiva para confirmar; se cancela." >&2
    return 1
  fi
  read -r -p "$pregunta [s/N] " respuesta
  [[ "$respuesta" == "s" || "$respuesta" == "S" ]]
}

verificar_perfil_contra_tailscale

# El build de producción necesita las VITE_* como variables de entorno reales
# al momento de invocar `docker compose build` (son build.args, no env_file) --
# se exportan aquí desde frontend/.env sin imprimir su contenido.
exportar_variables_build_frontend() {
  set -a
  # shellcheck disable=SC1091
  source frontend/.env
  set +a
}

# Orden de despliegue obligado: DDL -> backend -> frontend. Algunas lecturas del backend piden columnas que crea una migración (hoy 94_: huella_evidencia); si la migración
# falta, el despliegue ABORTA aquí (scripts/verificar_esquema.py: 0 = ok, 1 = falta una migración, 2 = no se pudo consultar la base: se avisa y se sigue).
verificar_esquema_requerido() {
  if ! command -v uv &>/dev/null; then
    echo "Aviso: no hay 'uv' en este host; no se verificó que el esquema tenga las migraciones requeridas." >&2
    return 0
  fi
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  local codigo=0
  (cd backend && uv run python "$RAIZ/scripts/verificar_esquema.py") || codigo=$?
  if [[ "$codigo" -eq 1 ]]; then
    echo "Despliegue abortado: aplica las migraciones que faltan (db/ddl) y vuelve a intentar." >&2
    exit 1
  fi
}

# Bootstrap del usuario base (SCJ-PRO-05, ver bitácora del corte de puesto_permiso): la
# única pieza del bootstrap de un despliegue nuevo que no puede ser SQL puro, porque
# necesita un auth.users real que sólo la Admin API de Supabase puede emitir. Se detecta
# primero si ya existe (scripts/bootstrap_usuario_base.py verificar) para no repreguntar
# en despliegues subsecuentes del mismo entorno. Habla directo con Supabase (no con los
# contenedores), corre en el host vía `uv run` con el entorno de backend/ -- mismo patrón
# que ya usa el proyecto para el generador de datos sintéticos.
bootstrap_usuario_base() {
  if ! command -v uv &>/dev/null; then
    echo "Aviso: no hay 'uv' en este host; se omite el bootstrap del usuario base." >&2
    return 0
  fi
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
  echo "No existe todavía un acceso al sistema para la persona de bootstrap. Se crea ahora"
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
    mostrar_archivos_compose
    if [[ "$ENTORNO" == "prod" ]]; then
      exportar_variables_build_frontend
    fi
    if [[ -n "$SERVICIO" ]]; then
      if ! compose config --services | grep -qxF "$SERVICIO"; then
        echo "Error: servicio '$SERVICIO' no existe. Válidos: $(compose config --services | tr '\n' ' ')" >&2
        exit 1
      fi
      if ! red_se_conserva_en_parcial "$SERVICIO"; then
        echo "Aviso: la configuración de la red del proyecto cambió (p. ej. el IPAM de docker-compose.pi.yml)." >&2
        echo "  Un 'up --no-deps $SERVICIO' fallaría al recrearla con los otros contenedores conectados" >&2
        echo "  y dejaría '$SERVICIO' caído. Hace falta bajar y levantar TODO el proyecto (corte de backend y frontend)." >&2
        if ! confirmar "¿Hacer down + up completo ahora?"; then
          echo "Cancelado. No se cambió nada." >&2
          exit 1
        fi
        SERVICIO=""
        verificar_esquema_requerido
        compose down
        compose up -d --build
      else
        verificar_esquema_requerido
        compose up -d --build --no-deps "$SERVICIO"
        echo
        echo "Servicio '$SERVICIO' actualizado ($ENTORNO)."
        exit 0
      fi
    else
      verificar_esquema_requerido
      compose up -d --build
    fi
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
    mostrar_archivos_compose
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
