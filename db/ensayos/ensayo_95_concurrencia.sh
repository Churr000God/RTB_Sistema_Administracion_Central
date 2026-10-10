#!/usr/bin/env bash
# Ensayo de concurrencia de 94_/95_ (M1 y R1 de security): DOS conexiones psql coordinadas, cada una dentro de BEGIN … ROLLBACK, sin cambios permanentes.
# NO correr sin OK explícito del usuario (en el chat de la sesión que lo corre), con VENTANA AVISADA y SOLO después de aplicar 94_ y 95_. Usa una
# alta REAL en esperando_huella (los fixtures sintéticos de ensayo_95.sql viven en una transacción que otra conexión no ve; comprometer un fixture no
# está permitido). La sesión 1 retiene el lock de la alta (FOR UPDATE) como lo haría un movimiento del Pi o una activación; la sesión 2 ejercita el
# RPC de marcas (casos 1 y 2) o la caducidad (caso 3). Todo se revierte; la alta real queda bloqueada como máximo ESPERA_LARGA segundos (los
# movimientos reales del Pi sobre ESA alta esperan ese tiempo). Si no hay ninguna alta real en esperando_huella sale con código 2 sin tocar nada y la
# concurrencia queda sin probar (se verifica por revisión de código y en la primera alta real).
# Reglas de security: conexión DIRECTA por la variable de entorno (puerto 5432, nunca el pooler 6543); no imprime employee_no ni persona_id.
#   DATABASE_URL_DIRECTA=postgresql://... db/ensayos/ensayo_95_concurrencia.sh
set -euo pipefail
: "${DATABASE_URL_DIRECTA:?exporta DATABASE_URL_DIRECTA (puerto 5432, no el pooler 6543)}"
case "$DATABASE_URL_DIRECTA" in *:6543/*) echo "DATABASE_URL_DIRECTA apunta al pooler (6543): usa la conexión directa (5432)." >&2; exit 3;; esac
PSQL=(psql -X -q -At "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1)
ESPERA_CORTA=1   # menor que lock_timeout (2 s): la sesión 2 espera y ACTIVA
ESPERA_LARGA=4   # mayor que lock_timeout (2 s): la sesión 2 agota la espera y NO activa, pero su marca queda confirmada

# 1) Alta real en esperando_huella (solo lectura). No se imprime employee_no.
FILA=$("${PSQL[@]}" -F '|' -c "SELECT tu.id, tu.terminal_id, tu.employee_no, t.terminal_id, (tu.usuario_creado_en < now() - interval '4 hours')::int FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id WHERE tu.estado = 'esperando_huella' AND tu.usuario_creado_en IS NOT NULL ORDER BY tu.id LIMIT 1")
if [ -z "$FILA" ]; then echo "No hay ninguna alta real en esperando_huella; la concurrencia queda SIN PROBAR (código 2)."; exit 2; fi
IFS='|' read -r ALTA TERM_ID EMP SERIE VIEJA <<<"$FILA"
echo "alta=$ALTA terminal_id=$TERM_ID (alta con más de 4 h de espera: $([ "$VIEJA" = 1 ] && echo sí || echo no))"

# Lanza la sesión 1 (retiene la alta $ALTA durante $1 s) y espera ACTIVAMENTE a que de verdad tenga el lock (ya está en pg_sleep), sin sleep a ciegas.
retener() {
  PGAPPNAME=ens95_s1 "${PSQL[@]}" <<SQL1 >/dev/null &
BEGIN;
SELECT 1 FROM tiempo.terminal_usuario WHERE id = $ALTA FOR UPDATE;
SELECT pg_sleep($1);
ROLLBACK;
SQL1
  S1_PID=$!
  local i
  for i in $(seq 1 100); do
    if [ "$("${PSQL[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'ens95_s1' AND wait_event = 'PgSleep'")" -ge 1 ]; then return 0; fi
    sleep 0.1
  done
  echo "La sesión 1 no llegó a retener la alta en 10 s; se aborta." >&2; kill "$S1_PID" 2>/dev/null || true; exit 4
}

marca_con_huella() {   # $1 = espera de la sesión 1
  retener "$1"
  "${PSQL[@]}" 2>&1 <<SQL2
BEGIN;
SELECT clock_timestamp() AS t0 \gset
WITH r AS (
  SELECT tiempo.fn_marca_terminal_registrar($TERM_ID, jsonb_build_array(jsonb_build_object(
    'evento_id', gen_random_uuid(), 'employee_no', $EMP,
    'secuencia_local', (SELECT COALESCE(max(secuencia_local), 0) + 1 FROM tiempo.marca WHERE terminal_id = '$SERIE' AND origen = 'terminal'),
    'momento_dispositivo', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'desfase_local', '-06:00', 'estado_reloj', 'sincronizado',
    'modo_verificacion', 'huella'))) AS j)
SELECT 'marca: ' || (j->'resultados'->0->>'estado') FROM r;
SELECT 'alta tras la llamada (dentro de la transacción): ' || estado || ' / evidencia ' || COALESCE(huella_evidencia, '-') FROM tiempo.terminal_usuario WHERE id = $ALTA;
SELECT 'tardó (s): ' || round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 1);
ROLLBACK;
SQL2
  wait "$S1_PID"
}

caducidad_con_alta_tomada() {
  retener "$ESPERA_LARGA"
  "${PSQL[@]}" 2>&1 <<SQL3
BEGIN;
SELECT clock_timestamp() AS t0 \gset
SELECT 'caducidad(4 h) emitió ' || tiempo.fn_terminal_baja_por_caducidad(4) || ' bajas (las de OTRAS altas vencidas, si las hubiera; se revierten)';
SELECT 'la alta tomada por la sesión 1 quedó: ' || estado || ' (esperado: esperando_huella)' FROM tiempo.terminal_usuario WHERE id = $ALTA;
SELECT 'la caducidad NO esperó el lock; tardó (s): ' || round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 1) || ' (esperado: ~0)';
ROLLBACK;
SQL3
  wait "$S1_PID"
}

echo "== Caso 1: la sesión 1 retiene la alta ${ESPERA_CORTA}s (< lock_timeout 2s). Esperado: la sesión 2 espera y ACTIVA (evidencia inferida) =="
marca_con_huella "$ESPERA_CORTA"
echo "== Caso 2: la sesión 1 retiene la alta ${ESPERA_LARGA}s (> 2s). Esperado: WARNING sqlstate=55P03, marca confirmada, alta SIGUE en esperando_huella =="
marca_con_huella "$ESPERA_LARGA"
if [ "$VIEJA" = 1 ]; then
  echo "== Caso 3 (R1): la sesión 1 retiene una alta VENCIDA (> 4 h). Esperado: la caducidad NO la da de baja ni espera (SKIP LOCKED) =="
  caducidad_con_alta_tomada
else
  echo "== Caso 3 (R1) NO APLICABLE: la alta real tiene menos de 4 h de espera (piso de la caducidad); queda sin probar la omisión por lock =="
fi

# 2) Comprobación de no-residuo (solo lectura).
"${PSQL[@]}" -c "SELECT 'sin residuo: altas esperando_huella reales = ' || count(*) FROM tiempo.terminal_usuario WHERE estado = 'esperando_huella'"
