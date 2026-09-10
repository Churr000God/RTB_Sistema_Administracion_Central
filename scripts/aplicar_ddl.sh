#!/usr/bin/env bash
# scripts/aplicar_ddl.sh
#
# Aplica todo el DDL de RTB-CRM-APP (db/ddl/00_*.sql a db/ddl/70_*.sql, 71 archivos) contra una
# base de Supabase VACÍA. NO es idempotente — pensado para una sola corrida sobre schema limpio.
# Si algo falla a mitad, el script corta (no sigue aplicando a ciegas) y la salida es:
#   DROP SCHEMA personas CASCADE; DROP SCHEMA tiempo CASCADE; DROP ROLE terminal_checador;
# y volver a correr desde cero — no hay modo de reanudar a mitad.
#
# Requiere DATABASE_URL en el entorno (o en .env de la raíz, sourceado antes de llamar a este
# script) apuntando al SESSION POOLER de Supabase, puerto 5432 — no al transaction pooler
# (6543): el DDL corre en transacciones largas y el transaction pooler no las soporta bien
# (causa del cuelgue histórico documentado en CLAUDE.md). Formato esperado
# (Project Settings → Database → Connection string → Session pooler):
#
#   postgresql://postgres.<referencia-de-proyecto>:<password>@<host-del-pooler>:5432/postgres
#
# Uso:
#   source .env && ./scripts/aplicar_ddl.sh
#   DATABASE_URL="postgresql://..." ./scripts/aplicar_ddl.sh
#
# Dos archivos pueden fallar por privilegios del rol que corre el DDL (ver reporte de "db" a
# "orchestrator" para el detalle completo y el fallback exacto de cada uno):
#   - db/ddl/07_personas_storage.sql   (toca storage.buckets/storage.objects — necesita
#     privilegios de supabase_storage_admin; si falla, aplicar a mano en el dashboard)
#   - db/ddl/37_tiempo_rls_terminal.sql (CREATE ROLE terminal_checador + GRANT a authenticator —
#     necesita CREATEROLE; si falla, correrlo desde el SQL Editor del dashboard, que corre como
#     postgres)
# El script no los trata distinto en la corrida normal — el corte al primer error ya los aísla:
# si cualquiera de los dos falla, el script para ahí mismo y el archivo que falló queda impreso
# en la última línea.

set -euo pipefail

if [ -z "${DATABASE_URL:-}" ]; then
  echo "Error: DATABASE_URL no está definida. source .env primero, o exportala a mano." >&2
  echo "Debe ser el session pooler (puerto 5432), no el transaction pooler (6543)." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

for f in db/ddl/*.sql; do
  echo "== $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -f "$f"
done

echo "== db/indices/01_indices.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -f db/indices/01_indices.sql

echo "DDL aplicado completo. Correr db/verificar_ddl.sql antes de seguir con el bootstrap."
