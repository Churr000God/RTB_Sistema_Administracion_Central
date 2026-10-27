#!/usr/bin/env bash
# Prepara el reloj del host para que Docker no arranque con la hora mal (P-056).
#
# Uso:
#   scripts/preparar_hora_host.sh verificar   # solo lee, no cambia nada
#   scripts/preparar_hora_host.sh instalar    # requiere sudo
#
# Qué hace 'instalar':
#   1. Si el host tiene RTC (reloj con pila), no hace nada: no hace falta.
#   2. Copia los drop-ins de despliegue/host/ a /etc/systemd/system/.
#   3. Habilita systemd-time-wait-sync.service y recarga systemd.
# Los cambios aplican en el siguiente arranque; no reinicia nada.
# Ver docs/07-procesos/ARRANQUE_PI_DE_PRUEBAS.md §0 y bitacora/2026-10-27_reloj_pi_docker_espera_sincronia.md.

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGEN="$RAIZ/despliegue/host"
DESTINO="/etc/systemd/system"
DROPINS=(
  "docker.service.d/10-esperar-hora.conf"
  "systemd-time-wait-sync.service.d/10-tope-espera.conf"
)

tiene_rtc() {
  [[ -n "$(timedatectl show -p RTCTimeUSec --value 2>/dev/null)" ]] || compgen -G "/dev/rtc[0-9]*" >/dev/null
}

# Qué demonio sincroniza la hora: timesyncd, chrony u otro.
demonio_hora() {
  if systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null; then
    echo "timesyncd"
  elif systemctl is-active --quiet chrony.service 2>/dev/null || systemctl is-active --quiet chronyd.service 2>/dev/null; then
    echo "chrony"
  else
    echo "ninguno"
  fi
}

verificar() {
  local fallas=0 demonio
  if tiene_rtc; then
    echo "RTC: sí (este host no necesita el ajuste)"
    return 0
  fi
  echo "RTC: no"
  echo "Hora sincronizada ahora: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo desconocido)"

  demonio="$(demonio_hora)"
  echo "Demonio de hora: $demonio"
  case "$demonio" in
    chrony)
      # time-wait-sync se entera de la sincronía por el kernel; chrony solo se lo dice con rtcsync.
      if grep -qsE '^\s*rtcsync' /etc/chrony/chrony.conf /etc/chrony/conf.d/*.conf /etc/chrony.conf 2>/dev/null; then
        echo "chrony rtcsync: sí"
      else
        echo "AVISO: chrony sin 'rtcsync': el kernel no se entera de la sincronía y cada arranque esperará el tope completo."
        fallas=1
      fi
      ;;
    ninguno)
      echo "AVISO: no hay demonio de hora activo; time-wait-sync esperará siempre hasta el tope."
      fallas=1
      ;;
  esac

  local estado_tws
  estado_tws="$(systemctl is-enabled systemd-time-wait-sync.service 2>/dev/null || true)"
  echo "systemd-time-wait-sync habilitado: ${estado_tws:-desconocido}"
  [[ "$estado_tws" == "enabled" ]] || fallas=1

  if [[ "$(systemctl show systemd-time-wait-sync.service -p Result --value 2>/dev/null)" == "timeout" ]]; then
    echo "AVISO: en este arranque systemd-time-wait-sync venció el tope; Docker arrancó sin hora confirmada."
  fi

  for d in "${DROPINS[@]}"; do
    if [[ -f "$DESTINO/$d" ]] && cmp -s "$ORIGEN/$d" "$DESTINO/$d"; then
      echo "drop-in $d: instalado"
    else
      echo "drop-in $d: FALTA o distinto al del repo"
      fallas=1
    fi
  done

  if systemctl show docker.service -p After --value 2>/dev/null | tr ' ' '\n' | grep -qx time-sync.target; then
    echo "docker.service espera time-sync.target: sí"
  else
    echo "docker.service espera time-sync.target: NO"
    fallas=1
  fi

  if (( fallas )); then
    echo "Resultado: FALTA algo (ver arriba)."
  else
    echo "Resultado: listo."
  fi
  return "$fallas"
}

instalar() {
  if tiene_rtc; then
    echo "El host tiene RTC: no se instala nada."
    return 0
  fi
  for d in "${DROPINS[@]}"; do
    sudo install -D -m 0644 "$ORIGEN/$d" "$DESTINO/$d"
    echo "instalado $DESTINO/$d"
  done
  sudo systemctl enable systemd-time-wait-sync.service
  sudo systemctl daemon-reload
  echo
  if verificar; then
    echo "Aplica en el siguiente arranque."
  else
    echo "Instalado, pero la verificación encontró algo pendiente (ver arriba)." >&2
    return 1
  fi
}

case "${1:-}" in
  verificar) verificar ;;
  instalar)  instalar ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
