-- db/verificar_ddl.sql
--
-- Consultas de verificación por fase (plan §2.3), en el mismo orden en que se cierran las fases
-- de db/ddl/*.sql. Se corren pegando cada bloque en el SQL Editor del dashboard, o con:
--   psql "$DATABASE_URL" -f db/verificar_ddl.sql
-- No modifican nada — todas son de sólo lectura. Un resultado fuera de lo "esperado" no se
-- corrige a mano: indica qué archivo de db/ddl/ no se aplicó o falló a medias.

-- ============================================================================
-- FASE DDL
-- ============================================================================

-- 1) Tablas por esquema.
-- Esperado: personas = 11, tiempo = 17.
SELECT table_schema, count(*)
FROM information_schema.tables
WHERE table_schema IN ('personas', 'tiempo') AND table_type = 'BASE TABLE'
GROUP BY table_schema
ORDER BY table_schema;

-- 2) Tablas con RLS habilitada y CERO policies (deny-by-default silencioso, no error visible).
-- Esperado: ninguna fila de personas; en tiempo, sólo las que 41_tiempo_rls_deny_default.sql
-- deja deliberadamente sin policy (confirmar contra ese archivo si aparece alguna inesperada).
SELECT n.nspname AS esquema, c.relname AS tabla
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('personas', 'tiempo')
  AND c.relkind = 'r'
  AND c.relrowsecurity = true
  AND NOT EXISTS (
    SELECT 1 FROM pg_policies p
    WHERE p.schemaname = n.nspname AND p.tablename = c.relname
  )
ORDER BY 1, 2;

-- 3) has_schema_privilege para anon/authenticated/service_role sobre personas y tiempo.
-- Esperado: true en las 6 filas (USAGE en el schema; el GRANT específico por tabla es otra cosa).
SELECT rol, esquema, has_schema_privilege(rol, esquema, 'USAGE') AS tiene_usage
FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('personas'), ('tiempo')) AS e(esquema)
ORDER BY esquema, rol;

-- 4) Tablas sin SELECT para authenticated (grant a nivel tabla, no RLS).
-- Esperado: 0 filas.
SELECT table_schema, table_name
FROM information_schema.tables t
WHERE table_schema IN ('personas', 'tiempo')
  AND table_type = 'BASE TABLE'
  AND NOT has_table_privilege('authenticated', table_schema || '.' || table_name, 'SELECT')
ORDER BY 1, 2;

-- 5) Bucket de storage `expedientes`.
-- Esperado: 1 fila, public = false.
SELECT id, name, public FROM storage.buckets WHERE id = 'expedientes';

-- 6) Rol terminal_checador: puede INSERT en tiempo.marca, NO puede SELECT. Así, a propósito.
-- Esperado: insertable = true, selectable = false.
SELECT
  has_table_privilege('terminal_checador', 'tiempo.marca', 'INSERT') AS insertable,
  has_table_privilege('terminal_checador', 'tiempo.marca', 'SELECT') AS selectable;

-- 7) Catálogo de permisos y permisos activos del puesto administrador genérico.
-- Esperado: 49 y 49.
SELECT count(*) AS total_permisos FROM personas.permiso;

SELECT count(*) AS permisos_admin_genérico
FROM personas.puesto_permiso pp
JOIN personas.puesto p ON p.id = pp.puesto_id
WHERE p.es_administrador_generico = true
  AND pp.activo = true;

-- 8) Cuántos puestos tienen es_administrador_generico = true.
-- Esperado: exactamente 1.
SELECT count(*) FROM personas.puesto WHERE es_administrador_generico = true;

-- ============================================================================
-- FASE DATA API (después de exponer personas/tiempo en el dashboard)
-- ============================================================================

-- 9) curl de humo contra PostgREST con el esquema personas expuesto:
--   curl -s -o /dev/null -w '%{http_code}\n' "$SUPABASE_URL/rest/v1/permiso" \
--     -H "apikey: $SUPABASE_ANON_KEY" -H "Accept-Profile: personas"
-- Esperado: 200 (cuerpo [] si no hay sesión — RLS deny-by-default para anon). Errores comunes:
--   404 con código PGRST106 -> el esquema no está expuesto en Data API.
--   "permission denied for schema personas" -> falta el GRANT explícito (08_personas_permisos.sql).

-- ============================================================================
-- FASE BOOTSTRAP (después de crear el usuario base)
-- ============================================================================

-- 10) Usuarios de auth.users sin fila correspondiente en personas.usuario (huérfanos).
-- Esperado: 0 filas.
SELECT au.id, au.email
FROM auth.users au
LEFT JOIN personas.usuario u ON u.auth_user_id = au.id
WHERE u.auth_user_id IS NULL;
