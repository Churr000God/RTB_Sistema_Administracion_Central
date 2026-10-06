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
-- Esperado: personas = 11, tiempo = 20.
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
-- Esperado: 51 y 51 (49 + terminal_usuario_lectura/edicion de 80_*.sql; el puesto administrador los recibe explícitos).
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


-- ============================================================================
-- FASE TERMINAL HIKVISION (después de 80_*.sql y 81_*.sql, SCJ-DEC-11)
-- Todas son consultas de VIOLACIONES: Esperado: 0 filas en cada una. Una fila indica qué se salió
-- del diseño. El ALTER DEFAULT PRIVILEGES de 38_tiempo_permisos.sql da GRANT ALL a anon,
-- authenticated y service_role en todo objeto nuevo; 80_/81_ lo revocan explícito y estas
-- consultas lo comprueban contra una lista de lo permitido (lista blanca).
-- ============================================================================

-- 11) RLS habilitada en las 3 tablas nuevas.
-- Esperado: 0 filas.
SELECT c.relname AS tabla_sin_rls
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'tiempo'
  AND c.relname IN ('terminal', 'terminal_usuario', 'bitacora_movimiento_terminal_usuario')
  AND NOT c.relrowsecurity;

-- 12) Privilegios de TABLA fuera de la lista blanca (anon: ninguno; authenticated: SELECT en las
-- 3 más INSERT en la bitácora; service_role: terminal SELECT/INSERT, terminal_usuario SELECT,
-- bitácora SELECT/INSERT). Cubre DELETE, TRUNCATE, REFERENCES y TRIGGER además de INSERT/UPDATE.
-- Esperado: 0 filas.
WITH t(tabla) AS (VALUES ('terminal'), ('terminal_usuario'), ('bitacora_movimiento_terminal_usuario')),
     r(rol) AS (VALUES ('anon'), ('authenticated'), ('service_role')),
     p(priv) AS (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'),
                        ('REFERENCES'), ('TRIGGER')),
     permitido(tabla, rol, priv) AS (VALUES
       ('terminal', 'authenticated', 'SELECT'),
       ('terminal', 'service_role', 'SELECT'),
       ('terminal', 'service_role', 'INSERT'),
       ('terminal_usuario', 'authenticated', 'SELECT'),
       ('terminal_usuario', 'service_role', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'authenticated', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'authenticated', 'INSERT'),
       ('bitacora_movimiento_terminal_usuario', 'service_role', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'service_role', 'INSERT'))
SELECT t.tabla, r.rol, p.priv AS privilegio_de_mas
FROM t CROSS JOIN r CROSS JOIN p
WHERE has_table_privilege(r.rol, 'tiempo.' || t.tabla, p.priv)
  AND NOT EXISTS (SELECT 1 FROM permitido x WHERE x.tabla = t.tabla AND x.rol = r.rol AND x.priv = p.priv);

-- 13) Privilegios de COLUMNA fuera de la lista blanca (has_any_column_privilege: un GRANT por
-- columna no aparece en has_table_privilege). anon: ninguno en ninguna columna. Única excepción
-- de escritura por columna: service_role UPDATE en terminal.
-- Esperado: 0 filas.
WITH t(tabla) AS (VALUES ('terminal'), ('terminal_usuario'), ('bitacora_movimiento_terminal_usuario')),
     r(rol) AS (VALUES ('anon'), ('authenticated'), ('service_role')),
     p(priv) AS (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')),
     permitido(tabla, rol, priv) AS (VALUES
       ('terminal', 'authenticated', 'SELECT'),
       ('terminal', 'service_role', 'SELECT'),
       ('terminal', 'service_role', 'INSERT'),
       ('terminal', 'service_role', 'UPDATE'),
       ('terminal_usuario', 'authenticated', 'SELECT'),
       ('terminal_usuario', 'service_role', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'authenticated', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'authenticated', 'INSERT'),
       ('bitacora_movimiento_terminal_usuario', 'service_role', 'SELECT'),
       ('bitacora_movimiento_terminal_usuario', 'service_role', 'INSERT'))
SELECT t.tabla, r.rol, p.priv AS privilegio_de_columna_de_mas
FROM t CROSS JOIN r CROSS JOIN p
WHERE has_any_column_privilege(r.rol, 'tiempo.' || t.tabla, p.priv)
  AND NOT EXISTS (SELECT 1 FROM permitido x WHERE x.tabla = t.tabla AND x.rol = r.rol AND x.priv = p.priv);

-- 14) service_role sólo puede actualizar 4 columnas de tiempo.terminal (nunca id, terminal_id ni
-- creado_en).
-- Esperado: 0 filas.
SELECT a.attname AS columna_actualizable_de_mas
FROM pg_attribute a
WHERE a.attrelid = 'tiempo.terminal'::regclass
  AND a.attnum > 0 AND NOT a.attisdropped
  AND has_column_privilege('service_role', 'tiempo.terminal', a.attname, 'UPDATE')
  AND a.attname NOT IN ('ultimo_contacto_en', 'activa', 'nombre', 'modelo');

-- 15) Las 4 secuencias (employeeNo + las 3 identity): ningún rol de la API con USAGE, SELECT ni
-- UPDATE (los INSERT con identity no necesitan privilegio sobre la secuencia).
-- Esperado: 0 filas.
SELECT s.seq, r.rol, p.priv AS privilegio_de_mas
FROM (VALUES ('tiempo.seq_terminal_employee_no'),
             ('tiempo.terminal_id_seq'),
             ('tiempo.terminal_usuario_id_seq'),
             ('tiempo.bitacora_movimiento_terminal_usuario_id_seq')) AS s(seq)
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) AS p(priv)
WHERE has_sequence_privilege(r.rol, s.seq, p.priv);

-- 16) EXECUTE de las 3 funciones de trigger: ni anon/authenticated/service_role ni PUBLIC.
-- (has_function_privilege no acepta 'public' como rol; PUBLIC se detecta con aclexplode, grantee 0.
-- COALESCE con acldefault cubre proacl NULL = EXECUTE a PUBLIC por defecto.)
-- Esperado: 0 filas.
SELECT p.proname, 'public' AS rol_con_execute
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo'
  AND p.proname IN ('fn_bitacora_terminal_usuario_aplica', 'fn_bitacora_terminal_usuario_inmutable',
                    'fn_bitacora_terminal_usuario_truncate')
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT p.proname, r.rol
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
WHERE n.nspname = 'tiempo'
  AND p.proname IN ('fn_bitacora_terminal_usuario_aplica', 'fn_bitacora_terminal_usuario_inmutable',
                    'fn_bitacora_terminal_usuario_truncate')
  AND has_function_privilege(r.rol, p.oid, 'EXECUTE');

-- 17) fn_bitacora_terminal_usuario_aplica: SECURITY DEFINER y search_path fijado en proconfig
-- (un CREATE OR REPLACE descuidado los resetea, ver CLAUDE.md).
-- Esperado: 0 filas.
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'
  AND (NOT p.prosecdef
       OR p.proconfig IS NULL
       OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c
                      WHERE c LIKE 'search_path=%tiempo%personas%pg_temp%'));

-- 18) Los 3 triggers esperados existen, habilitados (tgenabled = 'O') y con el tipo correcto
-- (tgtype: ROW=1, BEFORE=2, INSERT=4, DELETE=8, UPDATE=16, TRUNCATE=32):
-- inmutable BEFORE ROW UPDATE|DELETE = 27, truncate BEFORE STATEMENT TRUNCATE = 34,
-- aplica BEFORE ROW INSERT = 7.
-- Esperado: 0 filas.
SELECT e.tgname AS trigger_esperado, t.tgenabled, t.tgtype, e.tipo_esperado
FROM (VALUES ('trg_bitacora_terminal_usuario_inmutable', 27),
             ('trg_bitacora_terminal_usuario_truncate', 34),
             ('trg_bitacora_terminal_usuario_aplica', 7)) AS e(tgname, tipo_esperado)
LEFT JOIN pg_trigger t
  ON t.tgname = e.tgname
 AND t.tgrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass
 AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> e.tipo_esperado;

-- 19) Policies de las 3 tablas comparadas por nombre, comando y roles (no sólo por conteo). Fila =
-- policy esperada que falta o difiere, o policy no esperada (sobra).
-- Esperado: 0 filas.
WITH esperadas(tabla, policyname, cmd, roles) AS (VALUES
  ('terminal', 'terminal_select_lectura', 'SELECT', '{authenticated}'),
  ('terminal_usuario', 'terminal_usuario_select_lectura', 'SELECT', '{authenticated}'),
  ('bitacora_movimiento_terminal_usuario', 'bitacora_terminal_usuario_select_lectura', 'SELECT', '{authenticated}'),
  ('bitacora_movimiento_terminal_usuario', 'bitacora_terminal_usuario_insert_web', 'INSERT', '{authenticated}')),
reales AS (
  SELECT tablename AS tabla, policyname, cmd, roles::text AS roles
  FROM pg_policies
  WHERE schemaname = 'tiempo'
    AND tablename IN ('terminal', 'terminal_usuario', 'bitacora_movimiento_terminal_usuario')
    AND permissive = 'PERMISSIVE')
SELECT COALESCE(e.tabla, r.tabla) AS tabla, COALESCE(e.policyname, r.policyname) AS policy,
       e.cmd AS cmd_esperado, r.cmd AS cmd_real, e.roles AS roles_esperados, r.roles AS roles_reales
FROM esperadas e
FULL OUTER JOIN reales r ON r.tabla = e.tabla AND r.policyname = e.policyname
WHERE e.policyname IS NULL OR r.policyname IS NULL OR e.cmd <> r.cmd OR e.roles <> r.roles;

-- 20) Permisos nuevos existen con el heredable esperado (confirmado por el usuario 2026-10-05):
-- terminal_usuario_lectura = true, terminal_usuario_edicion = false (si cambia la decisión,
-- cambiar acá y en la sección 4 de 80_*.sql).
-- Esperado: 0 filas.
SELECT e.codigo, e.heredable_esperado, pe.heredable AS heredable_real
FROM (VALUES ('terminal_usuario_lectura', true), ('terminal_usuario_edicion', false))
     AS e(codigo, heredable_esperado)
LEFT JOIN personas.permiso pe ON pe.codigo = e.codigo
WHERE pe.codigo IS NULL OR pe.heredable <> e.heredable_esperado;

-- 21) Otorgamiento: los 3 puestos acordados (incluido el administrador genérico, explícito)
-- tienen los 2 permisos activos.
-- Esperado: 0 filas.
SELECT pu.nombre_puesto, c.codigo AS permiso_faltante
FROM (VALUES ('Responsable de Recursos Humanos'), ('Gerente General'),
             ('Gerente o Encargado de TI')) AS pu(nombre_puesto)
CROSS JOIN (VALUES ('terminal_usuario_lectura'), ('terminal_usuario_edicion')) AS c(codigo)
WHERE NOT EXISTS (
  SELECT 1 FROM personas.puesto p
  JOIN personas.puesto_permiso pp ON pp.puesto_id = p.id AND pp.codigo = c.codigo AND pp.activo
  WHERE p.nombre_puesto = pu.nombre_puesto);

-- 22) El puesto administrador genérico tiene los 2 permisos nuevos activos (no depende del nombre).
-- Esperado: 0 filas.
SELECT p.nombre_puesto, c.codigo AS permiso_faltante
FROM personas.puesto p
CROSS JOIN (VALUES ('terminal_usuario_lectura'), ('terminal_usuario_edicion')) AS c(codigo)
WHERE p.es_administrador_generico
  AND NOT EXISTS (SELECT 1 FROM personas.puesto_permiso pp
                  WHERE pp.puesto_id = p.id AND pp.codigo = c.codigo AND pp.activo);
