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
-- Esperado: personas = 11, tiempo = 24 (20 + terminal_credencial de 82_ + marca_rechazada de 84_ + excepcion_descarte de 86_ + terminal_consentimiento de 88_).
SELECT table_schema, count(*)
FROM information_schema.tables
WHERE table_schema IN ('personas', 'tiempo') AND table_type = 'BASE TABLE'
GROUP BY table_schema
ORDER BY table_schema;

-- 2) Tablas con RLS habilitada y CERO policies (deny-by-default silencioso, no error visible).
-- Esperado: ninguna fila de personas; en tiempo, sólo las que 41_tiempo_rls_deny_default.sql
-- deja deliberadamente sin policy (confirmar contra ese archivo si aparece alguna inesperada), más
-- tiempo.terminal_credencial (82_*.sql, deliberado: sólo service_role, ninguna policy).
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

-- 6) Rol terminal_checador (retirado por 93_): ya no puede INSERT ni SELECT en tiempo.marca.
-- Esperado: insertable = false, selectable = false.
SELECT
  has_table_privilege('terminal_checador', 'tiempo.marca', 'INSERT') AS insertable,
  has_table_privilege('terminal_checador', 'tiempo.marca', 'SELECT') AS selectable;

-- 7) Catálogo de permisos y permisos activos del puesto administrador genérico.
-- Esperado: 53 y 53 (el catálogo creció con 80_, 86_, 88_ y 89_; el puesto administrador los recibe todos explícitos).
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
       OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, personas, pg_temp']);

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

-- ============================================================================
-- FASE AUTENTICACIÓN DE TERMINAL Y RUTA DE MARCAS (después de 82_, 83_ y 84_*.sql, SCJ-DEC-12)
-- Todas son consultas de VIOLACIONES: Esperado: 0 filas en cada una. Las secciones 11 a 22 siguen
-- valiendo para las 3 tablas de 80_/81_; éstas cubren lo nuevo.
-- ============================================================================

-- 23) RLS habilitada en tiempo.terminal_credencial y tiempo.marca_rechazada.
-- Esperado: 0 filas.
SELECT c.relname AS tabla_sin_rls
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'tiempo'
  AND c.relname IN ('terminal_credencial', 'marca_rechazada')
  AND NOT c.relrowsecurity;

-- 24) Privilegios de TABLA fuera de la lista blanca. terminal_credencial: sólo service_role SELECT e
-- INSERT. marca_rechazada: authenticated y service_role sólo SELECT (B5: nadie de la API inserta; la
-- escribe fn_terminal_rechazo_registrar, SECURITY DEFINER). Sin UPDATE, DELETE ni TRUNCATE para nadie.
-- anon: nada en ninguna.
-- Esperado: 0 filas.
WITH t(tabla) AS (VALUES ('terminal_credencial'), ('marca_rechazada')),
     r(rol) AS (VALUES ('anon'), ('authenticated'), ('service_role')),
     p(priv) AS (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'),
                        ('REFERENCES'), ('TRIGGER')),
     permitido(tabla, rol, priv) AS (VALUES
       ('terminal_credencial', 'service_role', 'SELECT'),
       ('terminal_credencial', 'service_role', 'INSERT'),
       ('marca_rechazada', 'authenticated', 'SELECT'),
       ('marca_rechazada', 'service_role', 'SELECT'))
SELECT t.tabla, r.rol, p.priv AS privilegio_de_mas
FROM t CROSS JOIN r CROSS JOIN p
WHERE has_table_privilege(r.rol, 'tiempo.' || t.tabla, p.priv)
  AND NOT EXISTS (SELECT 1 FROM permitido x WHERE x.tabla = t.tabla AND x.rol = r.rol AND x.priv = p.priv);

-- 25) Privilegios de COLUMNA fuera de la lista blanca: SELECT, INSERT, UPDATE y REFERENCES de los 3 roles
-- sobre cada columna de las 2 tablas nuevas de 82_/84_ (has_column_privilege incluye también los de
-- tabla). Lista blanca: terminal_credencial: service_role SELECT e INSERT (todas las columnas) y UPDATE sólo
-- de revocada_en, expira_en y etiqueta (hash, ultimo_uso_en, ultima_ip e ip_cambiada_en no son
-- actualizables por la API); marca_rechazada: authenticated y service_role sólo SELECT. anon: nada.
-- Esperado: 0 filas.
SELECT t.tabla, a.attname AS columna, r.rol, p.priv AS privilegio_de_columna_de_mas
FROM (VALUES ('terminal_credencial'), ('marca_rechazada')) AS t(tabla)
JOIN pg_attribute a ON a.attrelid = ('tiempo.' || t.tabla)::regclass AND a.attnum > 0 AND NOT a.attisdropped
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE has_column_privilege(r.rol, 'tiempo.' || t.tabla, a.attname, p.priv)
  AND NOT (
       (t.tabla = 'terminal_credencial' AND r.rol = 'service_role' AND p.priv IN ('SELECT', 'INSERT'))
    OR (t.tabla = 'terminal_credencial' AND r.rol = 'service_role' AND p.priv = 'UPDATE'
        AND a.attname IN ('revocada_en', 'expira_en', 'etiqueta'))
    OR (t.tabla = 'marca_rechazada' AND r.rol IN ('authenticated', 'service_role') AND p.priv = 'SELECT'));

-- 26) Las 4 columnas nuevas de tiempo.terminal (82_) no son actualizables por service_role (las escribe
-- sólo fn_terminal_latido, SECURITY DEFINER). Complementa la sección 14.
-- Esperado: 0 filas.
SELECT a.attname AS columna_actualizable_de_mas
FROM pg_attribute a
WHERE a.attrelid = 'tiempo.terminal'::regclass
  AND a.attname IN ('reloj_desfase_seg', 'terminal_alcanzable', 'version_pi', 'marcas_pendientes')
  AND (has_column_privilege('service_role', 'tiempo.terminal', a.attname, 'UPDATE')
       OR has_column_privilege('authenticated', 'tiempo.terminal', a.attname, 'UPDATE')
       OR has_column_privilege('anon', 'tiempo.terminal', a.attname, 'SELECT'));

-- 27) terminal_credencial.hash: char(64) con CHECK de formato ^[0-9a-f]{64}$ y UNIQUE.
-- Esperado: 0 filas.
SELECT 'hash no es char(64)' AS problema
WHERE NOT EXISTS (
  SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'tiempo' AND table_name = 'terminal_credencial' AND column_name = 'hash'
    AND data_type = 'character' AND character_maximum_length = 64)
UNION ALL
SELECT 'falta CHECK de formato del hash'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_constraint
  WHERE conrelid = 'tiempo.terminal_credencial'::regclass AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%[0-9a-f]{64}%')
UNION ALL
SELECT 'falta UNIQUE del hash'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_constraint
  WHERE conrelid = 'tiempo.terminal_credencial'::regclass AND contype = 'u'
    AND conname = 'uq_terminal_credencial_hash');

-- 28) Secuencias identity de las 2 tablas nuevas (y la del employeeNo, ya cubierta en la sección 15):
-- ningún rol de la API con USAGE, SELECT ni UPDATE.
-- Esperado: 0 filas.
SELECT s.seq, r.rol, p.priv AS privilegio_de_mas
FROM (VALUES ('tiempo.terminal_credencial_id_seq'), ('tiempo.marca_rechazada_id_seq')) AS s(seq)
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) AS p(priv)
WHERE has_sequence_privilege(r.rol, s.seq, p.priv);

-- 29) EXECUTE de las funciones de 83_/84_. (a) NINGUNA función nueva es ejecutable por PUBLIC, anon,
-- authenticated ni terminal_checador. (b) las 8 que llama el backend (la 8.ª, fn_terminal_baja_por_caducidad, es de 85_) SÍ son ejecutables por
-- service_role. (c) las 3 internas (fn_terminal_rechazo_registrar y las de los triggers SCJ13 y SCJ14) NO lo son
-- por service_role. fn_bitacora_terminal_usuario_aplica se cubre en la sección 16.
-- Esperado: 0 filas.
WITH f(proname, llamable) AS (VALUES
  ('fn_terminal_autenticar', true), ('fn_terminal_mapa', true),
  ('fn_terminal_movimiento_registrar', true), ('fn_terminal_latido', true),
  ('fn_marca_terminal_registrar', true), ('fn_terminal_baja_por_persona_inactiva', true),
  ('fn_marca_rechazada_purgar', true), ('fn_terminal_baja_por_caducidad', true),
  ('fn_terminal_rechazo_registrar', false), ('fn_terminal_valida_desactivacion', false),
  ('fn_terminal_credencial_revocacion_inmutable', false))
SELECT f.proname, 'falta la función' AS problema
FROM f
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT p.proname, 'EXECUTE a PUBLIC'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN f ON f.proname = p.proname
WHERE n.nspname = 'tiempo'
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT p.proname, 'EXECUTE a ' || r.rol
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN f ON f.proname = p.proname
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('terminal_checador')) AS r(rol)
WHERE n.nspname = 'tiempo' AND has_function_privilege(r.rol, p.oid, 'EXECUTE')
UNION ALL
SELECT p.proname, 'service_role sin EXECUTE'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN f ON f.proname = p.proname
WHERE n.nspname = 'tiempo' AND f.llamable AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
UNION ALL
SELECT p.proname, 'service_role con EXECUTE sobre función interna'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN f ON f.proname = p.proname
WHERE n.nspname = 'tiempo' AND NOT f.llamable AND has_function_privilege('service_role', p.oid, 'EXECUTE');

-- 30) Las 11 funciones nuevas (83_/84_/85_) son SECURITY DEFINER con search_path fijado en proconfig
-- (tiempo, personas, pg_temp), y fn_bitacora_terminal_usuario_aplica conserva ambas cláusulas tras el
-- CREATE OR REPLACE de 83_ (el cuerpo debe contener el FOR SHARE de 'asignado').
-- Esperado: 0 filas.
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo'
  AND p.proname IN ('fn_terminal_autenticar', 'fn_terminal_mapa', 'fn_terminal_movimiento_registrar',
                    'fn_terminal_latido', 'fn_marca_terminal_registrar',
                    'fn_terminal_baja_por_persona_inactiva', 'fn_marca_rechazada_purgar',
                    'fn_terminal_baja_por_caducidad',
                    'fn_terminal_rechazo_registrar', 'fn_terminal_valida_desactivacion',
                    'fn_terminal_credencial_revocacion_inmutable')
  AND (NOT p.prosecdef
       OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, personas, pg_temp'])
UNION ALL
SELECT p.proname, p.prosecdef, p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'
  AND p.prosrc NOT LIKE '%FOR SHARE%';

-- 31) Trigger SCJ13 de desactivación: existe, habilitado y con el tipo correcto (tgtype: ROW=1,
-- BEFORE=2, UPDATE=16 -> 19), sobre la columna activa (tgattr no vacío) y con WHEN (tgqual no nulo).
-- Y la excepción deliberada: tiempo.marca_rechazada NO lleva triggers de inmutabilidad (la purga los
-- dispararía): ningún trigger no interno sobre ella.
-- Esperado: 0 filas.
SELECT 'trg_terminal_valida_desactivacion' AS trigger_esperado, t.tgenabled, t.tgtype
FROM (SELECT 1) x
LEFT JOIN pg_trigger t
  ON t.tgname = 'trg_terminal_valida_desactivacion'
 AND t.tgrelid = 'tiempo.terminal'::regclass AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> 19 OR t.tgattr::text = '' OR t.tgqual IS NULL
UNION ALL
SELECT t.tgname, t.tgenabled, t.tgtype
FROM pg_trigger t
WHERE t.tgrelid = 'tiempo.marca_rechazada'::regclass AND NOT t.tgisinternal;

-- 32) Policies de las 2 tablas nuevas, comparadas por nombre, comando y roles: terminal_credencial no
-- debe tener ninguna; marca_rechazada exactamente 1 SELECT para authenticated. Fila = falta, sobra o
-- difiere.
-- Esperado: 0 filas.
WITH esperadas(tabla, policyname, cmd, roles) AS (VALUES
  ('marca_rechazada', 'marca_rechazada_select_lectura', 'SELECT', '{authenticated}')),
reales AS (
  SELECT tablename AS tabla, policyname, cmd, roles::text AS roles
  FROM pg_policies
  WHERE schemaname = 'tiempo' AND tablename IN ('terminal_credencial', 'marca_rechazada')
    AND permissive = 'PERMISSIVE')
SELECT COALESCE(e.tabla, r.tabla) AS tabla, COALESCE(e.policyname, r.policyname) AS policy,
       e.cmd AS cmd_esperado, r.cmd AS cmd_real, e.roles AS roles_esperados, r.roles AS roles_reales
FROM esperadas e
FULL OUTER JOIN reales r ON r.tabla = e.tabla AND r.policyname = e.policyname
WHERE e.policyname IS NULL OR r.policyname IS NULL OR e.cmd <> r.cmd OR e.roles <> r.roles;

-- 33) Las 4 columnas de estado existen en tiempo.terminal con el tipo esperado, y el CHECK de
-- marcas_pendientes.
-- Esperado: 0 filas.
SELECT e.columna, 'falta o con otro tipo' AS problema
FROM (VALUES ('reloj_desfase_seg', 'integer'), ('terminal_alcanzable', 'boolean'),
             ('version_pi', 'character varying'), ('marcas_pendientes', 'integer')) AS e(columna, tipo)
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'tiempo' AND c.table_name = 'terminal'
                    AND c.column_name = e.columna AND c.data_type = e.tipo)
UNION ALL
SELECT 'marcas_pendientes', 'falta ck_terminal_marcas_pendientes'
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'tiempo.terminal'::regclass AND conname = 'ck_terminal_marcas_pendientes');

-- ============================================================================
-- Endurecimiento tras la revisión de security de 82_/83_/84_ (V1, V4, M3)
-- ============================================================================

-- 34) Policies de las 4 tablas de la terminal: además del nombre/comando/roles (secciones 19 y 32), la
-- EXPRESIÓN (qual / with_check) debe ser EXACTAMENTE la esperada: una policy degradada a "... OR true" no
-- pasaría. pg_policies muestra la expresión con casts y paréntesis; se normaliza quitando los casts de tipo
-- y los paréntesis (auth.uid() se protege antes como AUTHUID). Los textos esperados son los que produce la
-- base real para 80_/81_ (verificados en solo lectura) y, para marca_rechazada_select_lectura (84_), el
-- mismo predicado que las otras 3 policies de lectura (validado por el ensayo del 2026-10-06). Si una
-- versión futura de Postgres cambiara cómo imprime estas expresiones, esta consulta marcará las 5 policies
-- por igual: es una señal de revisar la normalización, no necesariamente una policy rota.
-- Esperado: 0 filas.
WITH esperadas(tablename, policyname, q, w) AS (VALUES
  ('terminal', 'terminal_select_lectura',
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_lectura'' OR personas.fn_caller_tiene_permiso''terminal_usuario_edicion''', ''),
  ('terminal_usuario', 'terminal_usuario_select_lectura',
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_lectura'' OR personas.fn_caller_tiene_permiso''terminal_usuario_edicion''', ''),
  ('bitacora_movimiento_terminal_usuario', 'bitacora_terminal_usuario_select_lectura',
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_lectura'' OR personas.fn_caller_tiene_permiso''terminal_usuario_edicion''', ''),
  ('marca_rechazada', 'marca_rechazada_select_lectura',
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_lectura'' OR personas.fn_caller_tiene_permiso''terminal_usuario_edicion''', ''),
  ('bitacora_movimiento_terminal_usuario', 'bitacora_terminal_usuario_insert_web', '',
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_edicion'' AND origen = ''web'' AND tipo_movimiento = ANY ARRAY[''asignado'', ''baja_solicitada'', ''reconsentido'', ''huella_confirmada_manual''][] AND registrado_por = AUTHUID')),
pol AS (
  SELECT tablename, policyname,
         regexp_replace(regexp_replace(replace(COALESCE(qual, ''), 'auth.uid()', 'AUTHUID'),
           '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g') AS q,
         regexp_replace(regexp_replace(replace(COALESCE(with_check, ''), 'auth.uid()', 'AUTHUID'),
           '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g') AS w
  FROM pg_policies
  WHERE schemaname = 'tiempo'
    AND tablename IN ('terminal', 'terminal_usuario', 'bitacora_movimiento_terminal_usuario', 'marca_rechazada')
)
SELECT e.tablename, e.policyname, 'la expresión no es exactamente la esperada' AS problema, p.q AS q_real, p.w AS w_real
FROM esperadas e
JOIN pol p ON p.tablename = e.tablename AND p.policyname = e.policyname
WHERE p.q IS DISTINCT FROM e.q OR p.w IS DISTINCT FROM e.w;

-- 35) terminal_checador (el rol del lector R503Pro, 37_*.sql) no tiene ningún privilegio sobre las 5
-- tablas nuevas, de tabla ni de columna.
-- Esperado: 0 filas.
SELECT t.tabla, p.priv AS privilegio_de_mas
FROM (VALUES ('terminal'), ('terminal_usuario'), ('bitacora_movimiento_terminal_usuario'),
             ('terminal_credencial'), ('marca_rechazada')) AS t(tabla)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(priv)
WHERE has_table_privilege('terminal_checador', 'tiempo.' || t.tabla, p.priv)
UNION ALL
SELECT t.tabla, 'columna ' || p.priv
FROM (VALUES ('terminal'), ('terminal_usuario'), ('bitacora_movimiento_terminal_usuario'),
             ('terminal_credencial'), ('marca_rechazada')) AS t(tabla)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE has_any_column_privilege('terminal_checador', 'tiempo.' || t.tabla, p.priv);

-- 36) Dueños: las tablas y funciones nuevas pertenecen al MISMO rol que el resto del esquema (el de
-- migración, dueño de tiempo.marca). Un SECURITY DEFINER cuyo dueño tuviera más privilegios que ése
-- ampliaría lo que la función puede hacer.
-- Esperado: 0 filas.
SELECT 'tabla' AS tipo, c.relname AS objeto, pg_get_userbyid(c.relowner) AS dueno
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'tiempo'
  AND c.relname IN ('terminal', 'terminal_usuario', 'bitacora_movimiento_terminal_usuario',
                    'terminal_credencial', 'marca_rechazada')
  AND c.relowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT 'función', p.proname, pg_get_userbyid(p.proowner)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo'
  AND (p.proname LIKE 'fn\_terminal\_%' OR p.proname LIKE 'fn\_marca\_terminal\_%'
       OR p.proname LIKE 'fn\_marca\_rechazada\_%' OR p.proname LIKE 'fn\_bitacora\_terminal\_%')
  AND p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass);

-- 37) Barrido genérico: toda función SECURITY DEFINER del esquema tiempo tiene search_path fijado en
-- proconfig (cualquier valor que termine en pg_temp), y las funciones de la terminal (nombres de 80_-84_)
-- no son ejecutables por PUBLIC. Las funciones anteriores a la terminal (triggers de marca, ausencia,
-- etc.) pueden conservar EXECUTE por PUBLIC a propósito y no entran en la segunda parte.
-- Esperado: 0 filas.
SELECT p.proname, 'SECURITY DEFINER sin search_path fijo' AS problema
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.prosecdef
  AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, ARRAY[]::text[])) c
                  WHERE c LIKE 'search_path=%pg_temp')
UNION ALL
SELECT p.proname, 'EXECUTE a PUBLIC en una función de la terminal'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo'
  AND (p.proname LIKE 'fn\_terminal\_%' OR p.proname LIKE 'fn\_marca\_terminal\_%'
       OR p.proname LIKE 'fn\_marca\_rechazada\_%' OR p.proname LIKE 'fn\_bitacora\_terminal\_%')
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE');

-- 38) Las restricciones de unicidad de las que depende el RPC de marcas y la regla de un alta vigente por
-- persona existen con esos nombres exactos (el RPC desambigua el 23505 por nombre de restricción).
-- Esperado: 0 filas.
SELECT e.nombre AS restriccion_o_indice_faltante
FROM (VALUES ('uq_terminal_usuario_persona_vigente'), ('uq_marca_evento_id'), ('uq_marca_terminal_secuencia'),
             ('uq_terminal_usuario_employee_no'), ('uq_marca_rechazada_terminal_evento')) AS e(nombre)
WHERE NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'tiempo' AND c.relname = e.nombre AND c.relkind = 'i');

-- 39) Trigger SCJ14 sobre tiempo.terminal_credencial: existe, habilitado, BEFORE UPDATE de fila (tgtype 19),
-- acotado a la columna revocada_en (tgattr no vacío) y con WHEN (tgqual no nulo).
-- Esperado: 0 filas.
SELECT 'trg_terminal_credencial_revocacion_inmutable' AS trigger_esperado, t.tgenabled, t.tgtype
FROM (SELECT 1) x
LEFT JOIN pg_trigger t
  ON t.tgname = 'trg_terminal_credencial_revocacion_inmutable'
 AND t.tgrelid = 'tiempo.terminal_credencial'::regclass AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> 19 OR t.tgattr::text = '' OR t.tgqual IS NULL;

-- 40) fn_terminal_baja_por_caducidad (85_*.sql, SCJ-DEC-12 §12.7): existe una sola, con la firma esperada
-- (un argumento integer con valor por defecto), devuelve integer, es SECURITY DEFINER con search_path exacto,
-- y sólo service_role puede ejecutarla (la sección 29 cubre PUBLIC/anon/authenticated y la 30 el search_path;
-- aquí se comprueba además la firma y el valor por defecto, que el backend usa al llamarla sin argumentos).
-- Esperado: 0 filas.
SELECT 'firma, tipo de retorno o valor por defecto distintos de los esperados' AS problema
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_baja_por_caducidad'
    AND p.pronargs = 1 AND p.proargtypes[0] = 'integer'::regtype AND p.pronargdefaults = 1
    AND p.prorettype = 'integer'::regtype AND p.prosecdef
    AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp'])
UNION ALL
SELECT 'más de una función con ese nombre'
WHERE (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_baja_por_caducidad') > 1;

-- ============================================================================
-- FASE CIERRE DE DIA CERRADO (después de 86_*.sql, hallazgo de security 2026-10-07)
-- ============================================================================

-- 41) tiempo.excepcion_descarte (86_): RLS habilitada; authenticated y service_role sólo SELECT (ningún otro privilegio
-- de tabla ni de columna); anon y terminal_checador nada; su secuencia identity sin privilegios; una sola policy de
-- SELECT para authenticated.
-- Esperado: 0 filas.
SELECT 'sin RLS' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = 'tiempo.excepcion_descarte'::regclass AND c.relrowsecurity)
UNION ALL
SELECT 'privilegio de tabla de más', r.rol || ':' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(priv)
WHERE has_table_privilege(r.rol, 'tiempo.excepcion_descarte', p.priv)
  AND NOT (p.priv = 'SELECT' AND r.rol IN ('authenticated', 'service_role'))
UNION ALL
SELECT 'privilegio de columna de más', r.rol || ':' || p.priv || ':' || a.attname
FROM pg_attribute a
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE a.attrelid = 'tiempo.excepcion_descarte'::regclass AND a.attnum > 0 AND NOT a.attisdropped
  AND has_column_privilege(r.rol, 'tiempo.excepcion_descarte', a.attname, p.priv)
UNION ALL
SELECT 'secuencia con privilegio', r.rol || ':' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) AS p(priv)
WHERE has_sequence_privilege(r.rol, 'tiempo.excepcion_descarte_id_seq', p.priv)
UNION ALL
SELECT 'policy distinta de la esperada', policyname || ':' || cmd || ':' || roles::text
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'excepcion_descarte'
  AND NOT (policyname = 'excepcion_descarte_select_lectura' AND cmd = 'SELECT' AND roles::text = '{authenticated}')
UNION ALL
SELECT 'falta la policy de SELECT', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'excepcion_descarte'
                  AND policyname = 'excepcion_descarte_select_lectura')
UNION ALL
-- La expresión debe ser exactamente la esperada (como §34): una policy degradada a USING (true) o "... OR true" no pasa.
-- Misma normalización que §34 (se quitan casts de tipo y paréntesis).
SELECT 'la expresión de la policy no es exactamente la esperada',
       regexp_replace(regexp_replace(COALESCE(qual, ''), '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g')
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'excepcion_descarte' AND policyname = 'excepcion_descarte_select_lectura'
  AND regexp_replace(regexp_replace(COALESCE(qual, ''), '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g')
      IS DISTINCT FROM 'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''excepcion_lectura'' OR personas.fn_caller_tiene_permiso''excepcion_edicion'''
UNION ALL
SELECT 'la policy tiene with_check', with_check
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'excepcion_descarte' AND policyname = 'excepcion_descarte_select_lectura'
  AND with_check IS NOT NULL;

-- 42) Funciones de 86_: (a) fn_excepcion_dia_cerrado_descartar es SECURITY DEFINER con search_path exacto y
-- EXECUTE sólo para authenticated (no PUBLIC, no anon, no service_role, no terminal_checador); (b) las 6 funciones
-- internas/de trigger no son ejecutables por nadie de la API ni por PUBLIC; (c) fn_excepcion_protege_dia_cerrado y
-- fn_tramo_valida_coherencia son SECURITY DEFINER con search_path exacto 'tiempo, pg_temp'; las demás internas tienen
-- search_path fijo (INVOKER); (d) el dueño de todas es el de tiempo.marca.
-- Esperado: 0 filas.
WITH f(proname, rol_esperado, definer, search_path) AS (VALUES
  ('fn_excepcion_dia_cerrado_descartar', 'authenticated', true,  'search_path=tiempo, personas, pg_temp'),
  ('fn_marca_fecha_local',               NULL,            false, 'search_path=tiempo, pg_temp'),
  ('fn_excepcion_protege_columnas',      NULL,            false, 'search_path=tiempo, pg_temp'),
  ('fn_excepcion_protege_dia_cerrado',   NULL,            true,  'search_path=tiempo, pg_temp'),
  ('fn_tramo_valida_coherencia',         NULL,            true,  'search_path=tiempo, pg_temp'),
  ('fn_excepcion_descarte_inmutable',    NULL,            false, 'search_path=tiempo, pg_temp'),
  ('fn_excepcion_descarte_truncate',     NULL,            false, 'search_path=tiempo, pg_temp'))
SELECT f.proname, 'falta la función' AS problema
FROM f WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                         WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT f.proname, 'SECURITY DEFINER distinto de lo esperado'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.prosecdef IS DISTINCT FROM f.definer
UNION ALL
SELECT f.proname, 'search_path distinto de ' || f.search_path
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proconfig IS DISTINCT FROM ARRAY[f.search_path]
UNION ALL
SELECT f.proname, 'EXECUTE a PUBLIC'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT f.proname, 'EXECUTE inesperado para ' || r.rol
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, p.oid, 'EXECUTE') AND r.rol IS DISTINCT FROM f.rol_esperado
UNION ALL
SELECT f.proname, 'falta EXECUTE para ' || f.rol_esperado
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE f.rol_esperado IS NOT NULL AND NOT has_function_privilege(f.rol_esperado, p.oid, 'EXECUTE')
UNION ALL
SELECT f.proname, 'dueño distinto del de tiempo.marca'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
-- Condiciones críticas en el cuerpo (como el 'FOR SHARE' de §37): una versión que conserve la estructura pero pierda la
-- condición no pasaría. Cada fila es (función, fragmento que debe aparecer en prosrc).
SELECT c.proname, 'el cuerpo no contiene: ' || c.fragmento
FROM (VALUES
  ('fn_excepcion_protege_dia_cerrado', 'd.revisado_en = now()'),
  ('fn_excepcion_protege_dia_cerrado', 'x.creado_en = now()'),
  ('fn_excepcion_protege_dia_cerrado', 'fn_marca_fecha_local'),
  ('fn_excepcion_protege_columnas',    'starts_with'),
  ('fn_tramo_valida_coherencia',       'fn_marca_fecha_local'),
  ('fn_excepcion_dia_cerrado_descartar', 'fn_caller_tiene_permiso'),
  ('fn_excepcion_dia_cerrado_descartar', 'excepcion_dia_cerrado_descarte'),
  ('fn_excepcion_dia_cerrado_descartar', 'auth.uid()')
) AS c(proname, fragmento)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'tiempo' AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0);

-- 43) Triggers de 86_: trg_excepcion_protege_columnas (BEFORE UPDATE por fila, tgtype 19), el constraint trigger
-- recreado (AFTER UPDATE, DEFERRABLE INITIALLY DEFERRED, tgtype 17, con WHEN sobre el PREFIJO dia\_cerrado: la
-- igualdad exacta de 78_ ya no debe aparecer), trg_tramo_valida_coherencia (BEFORE INSERT OR UPDATE por fila,
-- tgtype 23) y los dos de inmutabilidad de excepcion_descarte (27 y 34). Todos habilitados (tgenabled = 'O').
-- Esperado: 0 filas.
SELECT e.tgname AS trigger_esperado, t.tgenabled, t.tgtype, e.tipo_esperado
FROM (VALUES ('tiempo.excepcion', 'trg_excepcion_protege_columnas', 19),
             ('tiempo.excepcion', 'trg_excepcion_protege_dia_cerrado', 17),
             ('tiempo.tramo', 'trg_tramo_valida_coherencia', 23),
             ('tiempo.excepcion_descarte', 'trg_excepcion_descarte_inmutable', 27),
             ('tiempo.excepcion_descarte', 'trg_excepcion_descarte_truncate', 34)) AS e(tabla, tgname, tipo_esperado)
LEFT JOIN pg_trigger t ON t.tgname = e.tgname AND t.tgrelid = e.tabla::regclass AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> e.tipo_esperado
UNION ALL
SELECT t.tgname, t.tgenabled, t.tgtype, NULL
FROM pg_trigger t
WHERE t.tgname = 'trg_excepcion_protege_dia_cerrado' AND t.tgrelid = 'tiempo.excepcion'::regclass
  AND NOT (t.tgconstraint <> 0 AND t.tgdeferrable AND t.tginitdeferred
           AND strpos(pg_get_triggerdef(t.oid), 'dia\_cerrado%') > 0
           AND strpos(pg_get_triggerdef(t.oid), '= ''dia_cerrado''') = 0);

-- 44) Permiso de acción excepcion_dia_cerrado_descarte (86_): existe, NO heredable, y activo para los 3 puestos
-- acordados (el administrador genérico incluido, explícito).
-- Esperado: 0 filas.
SELECT 'permiso inexistente o heredable' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM personas.permiso WHERE codigo = 'excepcion_dia_cerrado_descarte' AND heredable = false)
UNION ALL
SELECT 'puesto sin el permiso activo', pu.nombre_puesto
FROM (VALUES ('Responsable de Recursos Humanos'), ('Gerente General'), ('Gerente o Encargado de TI')) AS pu(nombre_puesto)
WHERE NOT EXISTS (
  SELECT 1 FROM personas.puesto p
  JOIN personas.puesto_permiso pp ON pp.puesto_id = p.id AND pp.codigo = 'excepcion_dia_cerrado_descarte' AND pp.activo
  WHERE p.nombre_puesto = pu.nombre_puesto)
UNION ALL
SELECT 'el puesto administrador genérico no lo tiene', p.nombre_puesto
FROM personas.puesto p
WHERE p.es_administrador_generico
  AND NOT EXISTS (SELECT 1 FROM personas.puesto_permiso pp
                  WHERE pp.puesto_id = p.id AND pp.codigo = 'excepcion_dia_cerrado_descarte' AND pp.activo);

-- ============================================================================
-- FASE CORRECCIÓN SOBRE MARCA EN TRAMO (después de 87_*.sql)
-- ============================================================================

-- 45) Trigger y función de 87_: el trigger existe, habilitado, BEFORE INSERT por fila (tgtype 7) en tiempo.correccion y corre ANTES
-- de trg_correccion_valida y de cualquier otro BEFORE INSERT por fila (orden alfabético de nombres, comprobado contra pg_trigger); la función es SECURITY DEFINER con search_path exacto, sin EXECUTE
-- para PUBLIC ni para ningún rol de la API, del mismo dueño que tiempo.marca, y su cuerpo contiene la condición crítica
-- (apertura O cierre de un tramo, SCJ15, hint marca_en_tramo, y la rama de salida que evita que el trigger sea un oráculo: anon, auth.uid() IS NOT NULL, fn_caller_activo y RETURN NEW).
-- Esperado: 0 filas.
SELECT 'falta o mal el trigger' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'tiempo.correccion'::regclass AND t.tgname = 'trg_correccion_bloquea_marca_en_tramo'
                    AND NOT t.tgisinternal AND t.tgenabled = 'O' AND t.tgtype = 7)
UNION ALL
SELECT 'hay otro trigger BEFORE INSERT por fila que corre antes que el de 87_', t.tgname::text
FROM pg_trigger t
WHERE t.tgrelid = 'tiempo.correccion'::regclass AND NOT t.tgisinternal
  AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 AND (t.tgtype & 4) <> 0
  AND t.tgname::text COLLATE "C" < 'trg_correccion_bloquea_marca_en_tramo' COLLATE "C"
UNION ALL
SELECT 'trg_correccion_valida falta, no es BEFORE INSERT por fila, o corre antes que el de 87_', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'tiempo.correccion'::regclass AND t.tgname = 'trg_correccion_valida' AND NOT t.tgisinternal
                    AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 AND (t.tgtype & 4) <> 0
                    AND t.tgname::text COLLATE "C" > 'trg_correccion_bloquea_marca_en_tramo' COLLATE "C")
UNION ALL
SELECT 'falta la función', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo')
UNION ALL
SELECT 'función distinta de la esperada', 'secdef=' || p.prosecdef || ' config=' || COALESCE(p.proconfig::text, 'NULL')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND (NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, personas, pg_temp'])
UNION ALL
SELECT 'EXECUTE a PUBLIC', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT 'EXECUTE inesperado para ' || r.rol, NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND has_function_privilege(r.rol, p.oid, 'EXECUTE')
UNION ALL
SELECT 'dueño distinto del de tiempo.marca', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT 'el cuerpo no contiene: ' || c.fragmento, NULL
FROM (VALUES ('marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id'), ('SCJ15'), ('marca_en_tramo'),
             ('auth.role() = ''anon'''), ('correccion_edicion'), ('auth.uid() IS NOT NULL'), ('fn_caller_activo'),
             ('RETURN NEW')) AS c(fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
                    AND strpos(p.prosrc, c.fragmento) > 0);


-- ============================================================================
-- FASE CONSENTIMIENTO Y CONFIGURACIÓN DE TERMINALES (después de 88_*.sql y 89_*.sql)
-- ============================================================================

-- 46) tiempo.terminal_consentimiento (88_): RLS habilitada; authenticated y service_role sólo SELECT (ningún otro privilegio de
-- tabla ni de columna); anon y terminal_checador nada; secuencia sin privilegios; UNA policy SELECT cuya expresión es exactamente la
-- esperada (activo y terminal_usuario_lectura | terminal_usuario_edicion | terminal_config_edicion, sin with_check); y la semilla.
-- Esperado: 0 filas.
SELECT 'sin RLS' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = 'tiempo.terminal_consentimiento'::regclass AND c.relrowsecurity)
UNION ALL
SELECT 'privilegio de tabla de más', r.rol || ':' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(priv)
WHERE has_table_privilege(r.rol, 'tiempo.terminal_consentimiento', p.priv)
  AND NOT (p.priv = 'SELECT' AND r.rol IN ('authenticated', 'service_role'))
UNION ALL
SELECT 'privilegio de columna de más', r.rol || ':' || p.priv || ':' || a.attname
FROM pg_attribute a
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE a.attrelid = 'tiempo.terminal_consentimiento'::regclass AND a.attnum > 0 AND NOT a.attisdropped
  AND has_column_privilege(r.rol, 'tiempo.terminal_consentimiento', a.attname, p.priv)
UNION ALL
SELECT 'secuencia con privilegio', r.rol || ':' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) AS p(priv)
WHERE has_sequence_privilege(r.rol, 'tiempo.terminal_consentimiento_id_seq', p.priv)
UNION ALL
SELECT 'policy distinta de la esperada', policyname || ':' || cmd || ':' || roles::text
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'terminal_consentimiento'
  AND NOT (policyname = 'terminal_consentimiento_select_lectura' AND cmd = 'SELECT' AND roles::text = '{authenticated}')
UNION ALL
SELECT 'falta la policy de SELECT', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'terminal_consentimiento'
                  AND policyname = 'terminal_consentimiento_select_lectura')
UNION ALL
SELECT 'la expresión de la policy no es exactamente la esperada',
       regexp_replace(regexp_replace(COALESCE(qual, ''), '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g')
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'terminal_consentimiento' AND policyname = 'terminal_consentimiento_select_lectura'
  AND regexp_replace(regexp_replace(COALESCE(qual, ''), '::(character varying|varchar|text|name|uuid|bigint|integer|boolean)', '', 'g'), '[()]', '', 'g')
      IS DISTINCT FROM 'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_lectura'' OR personas.fn_caller_tiene_permiso''terminal_usuario_edicion'' OR personas.fn_caller_tiene_permiso''terminal_config_edicion'''
UNION ALL
SELECT 'la policy tiene with_check', with_check
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'terminal_consentimiento' AND policyname = 'terminal_consentimiento_select_lectura'
  AND with_check IS NOT NULL
UNION ALL
SELECT 'falta la semilla provisional (versión 1 sin autor)', NULL
WHERE NOT EXISTS (SELECT 1 FROM tiempo.terminal_consentimiento WHERE version = 1 AND provisional AND creado_por IS NULL)
UNION ALL
SELECT 'hay una versión sin autor que no es la semilla', version::text
FROM tiempo.terminal_consentimiento WHERE creado_por IS NULL AND NOT (version = 1 AND provisional)
UNION ALL
SELECT 'faltan restricciones de la tabla', c.nombre
FROM (VALUES ('uq_terminal_consentimiento_version'), ('ck_terminal_consentimiento_version'), ('ck_terminal_consentimiento_texto'),
             ('ck_terminal_consentimiento_hash'), ('ck_terminal_consentimiento_provisional'), ('ck_terminal_consentimiento_autor')) AS c(nombre)
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = 'tiempo.terminal_consentimiento'::regclass AND k.conname = c.nombre);

-- 47) Funciones de 88_ y la reescrita de 88_: SECURITY DEFINER/INVOKER esperado, search_path exacto, EXECUTE exactamente para los
-- roles esperados (nadie más, PUBLIC tampoco), dueño igual al de tiempo.marca, y las condiciones críticas en el cuerpo (prosrc).
-- Esperado: 0 filas.
WITH f(proname, definer, search_path, roles) AS (VALUES
  ('fn_terminal_consentimiento_publicar',         true,  'search_path=tiempo, personas, pg_temp', ARRAY['authenticated']),
  ('fn_terminal_reconsentir',                     false, 'search_path=tiempo, personas, pg_temp', ARRAY['authenticated']),
  ('fn_terminal_reconsentimiento_pendiente_ids',  false, 'search_path=tiempo, pg_temp',           ARRAY['authenticated', 'service_role']),
  ('fn_terminal_consentimiento_inmutable',        false, 'search_path=tiempo, pg_temp',           ARRAY[]::text[]),
  ('fn_terminal_consentimiento_truncate',         false, 'search_path=tiempo, pg_temp',           ARRAY[]::text[]),
  ('fn_bitacora_terminal_usuario_aplica',         true,  'search_path=tiempo, personas, pg_temp', ARRAY[]::text[]))
SELECT f.proname, 'falta la función' AS problema
FROM f WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                         WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT f.proname, 'SECURITY DEFINER distinto de lo esperado'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.prosecdef IS DISTINCT FROM f.definer
UNION ALL
SELECT f.proname, 'search_path distinto de ' || COALESCE(f.search_path, '(ninguno)')
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proconfig IS DISTINCT FROM CASE WHEN f.search_path IS NULL THEN NULL ELSE ARRAY[f.search_path] END
UNION ALL
SELECT f.proname, 'EXECUTE a PUBLIC'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT f.proname, 'EXECUTE distinto de lo esperado para ' || r.rol
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, p.oid, 'EXECUTE') <> (r.rol = ANY (f.roles))
UNION ALL
SELECT f.proname, 'dueño distinto del de tiempo.marca'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT f2.proname, 'ayuda interna de personas ausente o con atributos distintos (INVOKER, search_path=personas, pg_temp, EXECUTE para nadie)'
FROM (VALUES ('fn_persona_de_usuario'), ('fn_usuario_es_administrador_generico')) AS f2(proname)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'personas' AND p.proname = f2.proname AND NOT p.prosecdef
    AND p.proconfig = ARRAY['search_path=personas, pg_temp']
    AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x WHERE x.grantee <> p.proowner AND x.privilege_type = 'EXECUTE'))
UNION ALL
SELECT f3.proname, 'envoltorio del llamador ausente o con atributos distintos (DEFINER, search_path=personas, pg_temp, EXECUTE sólo authenticated)'
FROM (VALUES ('fn_caller_persona_id'), ('fn_caller_es_administrador_generico')) AS f3(proname)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'personas' AND p.proname = f3.proname AND p.prosecdef
    AND p.proconfig = ARRAY['search_path=personas, pg_temp']
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE'))
UNION ALL
SELECT c.proname, 'el cuerpo no contiene: ' || c.fragmento
FROM (VALUES
  ('fn_terminal_consentimiento_publicar', 'fn_caller_activo'),
  ('fn_terminal_consentimiento_publicar', 'terminal_config_edicion'),
  ('fn_terminal_consentimiento_publicar', 'auth.uid()'),
  ('fn_terminal_consentimiento_publicar', 'LOCK TABLE tiempo.terminal_consentimiento IN SHARE ROW EXCLUSIVE MODE'),
  ('fn_terminal_consentimiento_publicar', 'sha256'),
  ('fn_terminal_consentimiento_publicar', 'version_base_desactualizada'),
  ('fn_terminal_reconsentir', 'consentimiento_desactualizado'),
  ('fn_terminal_reconsentir', 'cardinality'),
  ('fn_terminal_reconsentir', 'lote_no_elegible'),
  ('fn_terminal_reconsentir', 'alta_propia'),
  ('fn_terminal_reconsentir', 'terminal_usuario_edicion'),
  ('fn_terminal_reconsentir', 'fn_caller_persona_id'),
  ('fn_terminal_reconsentir', 'fn_caller_es_administrador_generico'),
  ('fn_terminal_reconsentir', 'reconsentido'),
  ('fn_bitacora_terminal_usuario_aplica', 'FOR SHARE'),
  ('fn_bitacora_terminal_usuario_aplica', 'LOCK TABLE tiempo.terminal_consentimiento IN ROW EXCLUSIVE MODE'),
  ('fn_bitacora_terminal_usuario_aplica', 'consentimiento_desactualizado'),
  ('fn_bitacora_terminal_usuario_aplica', 'consentimiento_requerido'),
  ('fn_bitacora_terminal_usuario_aplica', 'reconsentido'),
  ('fn_bitacora_terminal_usuario_aplica', 'consentimiento y aviso de privacidad recabados: versión'),
  ('fn_bitacora_terminal_usuario_aplica', 'usuario_creado_en'),
  ('fn_bitacora_terminal_usuario_aplica', 'auto_asignacion_prohibida'),
  ('fn_bitacora_terminal_usuario_aplica', 'auto_reconsentimiento_prohibido'),
  ('fn_bitacora_terminal_usuario_aplica', 'fn_usuario_es_administrador_generico'),
  ('fn_bitacora_terminal_usuario_aplica', 'fn_persona_de_usuario'),
  ('fn_bitacora_terminal_usuario_aplica', 'NEW.registrado_por'),
  ('fn_bitacora_terminal_usuario_aplica', 'NEW.origen IS DISTINCT FROM ''web'''),
  ('fn_bitacora_terminal_usuario_aplica', 'auth.role() IN (''anon'', ''authenticated'')'),
  ('fn_terminal_consentimiento_publicar', 'btrim(v_texto, E'' \n'')'),
  ('fn_terminal_consentimiento_publicar', 'WITH ORDINALITY'),
  ('fn_terminal_consentimiento_publicar', 'chr(8232)')
) AS c(proname, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0);

-- 48) Triggers de la tabla nueva y de la bitácora: existen, habilitados y con el tgtype esperado (inmutabilidad BEFORE UPDATE OR
-- DELETE por fila = 27; BEFORE TRUNCATE por statement = 34; el de transiciones de la bitácora BEFORE INSERT por fila = 7).
-- Esperado: 0 filas.
SELECT e.tgname AS trigger_esperado, t.tgenabled, t.tgtype, e.tipo_esperado
FROM (VALUES ('tiempo.terminal_consentimiento', 'trg_terminal_consentimiento_inmutable', 27),
             ('tiempo.terminal_consentimiento', 'trg_terminal_consentimiento_truncate', 34),
             ('tiempo.bitacora_movimiento_terminal_usuario', 'trg_bitacora_terminal_usuario_aplica', 7)) AS e(tabla, tgname, tipo_esperado)
LEFT JOIN pg_trigger t ON t.tgname = e.tgname AND t.tgrelid = e.tabla::regclass AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> e.tipo_esperado;

-- 49) Bitácora y tabla viva: la columna consentimiento_id y sus restricciones, con definición exacta; la policy de INSERT incluye
-- 'reconsentido'; y la integridad de datos (cada alta guarda la versión de su último movimiento asignado/reconsentido).
-- Esperado: 0 filas.
SELECT 'falta la columna consentimiento_id' AS problema, tabla AS detalle
FROM (VALUES ('tiempo.bitacora_movimiento_terminal_usuario', 'YES'), ('tiempo.terminal_usuario', 'NO')) AS e(tabla, nulo_esperado)
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema || '.' || c.table_name = e.tabla AND c.column_name = 'consentimiento_id'
                    AND c.data_type = 'bigint' AND c.is_nullable = e.nulo_esperado)
UNION ALL
SELECT 'falta la columna usuario_creado_en en la tabla viva', NULL
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = 'tiempo' AND c.table_name = 'terminal_usuario'
                  AND c.column_name = 'usuario_creado_en' AND c.data_type = 'timestamp with time zone' AND c.is_nullable = 'YES')
UNION ALL
SELECT 'falta la FK de consentimiento_id', e.tabla
FROM (VALUES ('tiempo.bitacora_movimiento_terminal_usuario'), ('tiempo.terminal_usuario')) AS e(tabla)
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = e.tabla::regclass AND k.contype = 'f' AND k.confrelid = 'tiempo.terminal_consentimiento'::regclass)
UNION ALL
SELECT 'restricción distinta de la esperada', c.nombre
FROM (VALUES
  ('ck_bitacora_terminal_usuario_tipo', 'reconsentido'),
  ('ck_bitacora_terminal_usuario_origen_tipo', 'reconsentido'),
  ('ck_bitacora_terminal_usuario_consentimiento', 'consentimiento_id IS NOT NULL')) AS c(nombre, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND k.conname = c.nombre
                    AND strpos(pg_get_constraintdef(k.oid), c.fragmento) > 0)
UNION ALL
SELECT 'la policy de INSERT no incluye reconsentido', policyname
FROM pg_policies
WHERE schemaname = 'tiempo' AND tablename = 'bitacora_movimiento_terminal_usuario' AND policyname = 'bitacora_terminal_usuario_insert_web'
  AND strpos(with_check, 'reconsentido') = 0
UNION ALL
SELECT 'alta con una versión distinta de la de su último movimiento', tu.id::text
FROM tiempo.terminal_usuario tu
WHERE tu.consentimiento_id IS DISTINCT FROM (SELECT b.consentimiento_id FROM tiempo.bitacora_movimiento_terminal_usuario b
                                              WHERE b.terminal_usuario_id = tu.id AND b.consentimiento_id IS NOT NULL
                                              ORDER BY b.id DESC LIMIT 1);

-- 50) Permiso terminal_config_edicion (88_): existe, NO heredable, activo para exactamente 'Gerente o Encargado de TI' y
-- 'Gerente General' (RH y los demás puestos NO), y el puesto administrador genérico lo tiene.
-- Esperado: 0 filas.
SELECT 'permiso ausente o heredable' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM personas.permiso WHERE codigo = 'terminal_config_edicion' AND NOT heredable)
UNION ALL
SELECT 'puesto sin el permiso', e.puesto
FROM (VALUES ('Gerente o Encargado de TI'), ('Gerente General')) AS e(puesto)
WHERE NOT EXISTS (SELECT 1 FROM personas.puesto p JOIN personas.puesto_permiso pp ON pp.puesto_id = p.id
                  WHERE p.nombre_puesto = e.puesto AND pp.codigo = 'terminal_config_edicion' AND pp.activo)
UNION ALL
SELECT 'puesto con el permiso que no debería tenerlo', p.nombre_puesto
FROM personas.puesto p JOIN personas.puesto_permiso pp ON pp.puesto_id = p.id
WHERE pp.codigo = 'terminal_config_edicion' AND pp.activo
  AND p.nombre_puesto NOT IN ('Gerente o Encargado de TI', 'Gerente General')
UNION ALL
SELECT 'el puesto administrador genérico no lo tiene', NULL
WHERE NOT EXISTS (SELECT 1 FROM personas.puesto p JOIN personas.puesto_permiso pp ON pp.puesto_id = p.id
                  WHERE p.es_administrador_generico AND pp.codigo = 'terminal_config_edicion' AND pp.activo);

-- 51) Claves de configuración de terminales (89_): las 5 existen con UNA sola vigencia activa, valor entero dentro de su rango, y no
-- hay otras claves terminal_%.
-- Esperado: 0 filas.
SELECT 'clave sin vigencia activa única' AS problema, c.clave AS detalle
FROM tiempo.fn_terminal_config_catalogo() c
WHERE (SELECT count(*) FROM tiempo.parametro p WHERE p.clave = c.clave AND p.vigente_hasta IS NULL) <> 1
UNION ALL
SELECT 'valor fuera de rango o mal formado', p.clave || '=' || p.valor
FROM tiempo.parametro p JOIN tiempo.fn_terminal_config_catalogo() c ON c.clave = p.clave
WHERE p.vigente_hasta IS NULL
  AND (p.valor !~ '^[0-9]{1,6}$' OR p.valor::integer < c.minimo OR p.valor::integer > c.maximo)
UNION ALL
SELECT 'el traslape de llaves supera la mitad de la antigüedad máxima', t.valor || ' dias vs ' || m.valor || ' meses'
FROM tiempo.parametro t, tiempo.parametro m
WHERE t.clave = 'terminal_traslape_llave_max_dias' AND t.vigente_hasta IS NULL
  AND m.clave = 'terminal_llave_max_meses' AND m.vigente_hasta IS NULL
  AND t.valor ~ '^[0-9]{1,6}$' AND m.valor ~ '^[0-9]{1,6}$'
  AND t.valor::integer * 2 > m.valor::integer * 30
UNION ALL
SELECT 'clave terminal_ fuera del catálogo', p.clave
FROM tiempo.parametro p
WHERE p.clave LIKE 'terminal\_%' AND p.clave NOT IN (SELECT clave FROM tiempo.fn_terminal_config_catalogo())
  -- 97_: las dos claves del interruptor de la activación por huella viven FUERA del catálogo a propósito (las comprueba la sección 60).
  AND p.clave NOT IN ('terminal_inferir_huella_activa', 'terminal_inferir_huella_hasta');

-- 52) Funciones de 89_ y el guard de fn_parametro_actualizar_valor: SECURITY DEFINER/INVOKER esperado, search_path exacto, EXECUTE exactamente para los
-- roles esperados (nadie más, PUBLIC tampoco), dueño igual al de tiempo.marca, y las condiciones críticas en el cuerpo (prosrc).
-- Esperado: 0 filas.
WITH f(proname, definer, search_path, roles) AS (VALUES
  ('fn_terminal_config_actualizar',               true,  'search_path=tiempo, personas, pg_temp', ARRAY['authenticated']),
  ('fn_terminal_config_valor',                    true,  'search_path=tiempo, pg_temp',           ARRAY['service_role']),
  ('fn_terminal_config_catalogo',                 false, 'search_path=pg_temp',                   ARRAY['authenticated', 'service_role']),
  ('fn_parametro_actualizar_valor',               false, NULL,                                    ARRAY['service_role']))
SELECT f.proname, 'falta la función' AS problema
FROM f WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                         WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT f.proname, 'SECURITY DEFINER distinto de lo esperado'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.prosecdef IS DISTINCT FROM f.definer
UNION ALL
SELECT f.proname, 'search_path distinto de ' || COALESCE(f.search_path, '(ninguno)')
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proconfig IS DISTINCT FROM CASE WHEN f.search_path IS NULL THEN NULL ELSE ARRAY[f.search_path] END
UNION ALL
SELECT f.proname, 'EXECUTE a PUBLIC'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT f.proname, 'EXECUTE distinto de lo esperado para ' || r.rol
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, p.oid, 'EXECUTE') <> (r.rol = ANY (f.roles))
UNION ALL
SELECT f.proname, 'dueño distinto del de tiempo.marca'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT c.proname, 'el cuerpo no contiene: ' || c.fragmento
FROM (VALUES
  ('fn_terminal_config_actualizar', 'fn_caller_activo'),
  ('fn_terminal_config_actualizar', 'terminal_config_edicion'),
  ('fn_terminal_config_actualizar', 'auth.uid()'),
  ('fn_terminal_config_actualizar', 'clave_no_editable'),
  ('fn_terminal_config_actualizar', 'valor_invalido'),
  ('fn_terminal_config_actualizar', 'terminal_traslape_llave_max_dias'),
  ('fn_terminal_config_actualizar', 'terminal_llave_max_meses'),
  ('fn_terminal_config_actualizar', 'pg_advisory_xact_lock'),
  ('fn_parametro_actualizar_valor', 'clave_reservada'),
  ('fn_parametro_actualizar_valor', 'terminal\_%')
) AS c(proname, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0);

-- 53) tiempo.fn_terminal_anomalias (90_): SECURITY INVOKER, STABLE, search_path exacto, EXECUTE sólo service_role (ni PUBLIC, anon ni
-- authenticated), dueño igual al de tiempo.marca, y las condiciones críticas en el cuerpo (filtra por la serie de la terminal, umbrales
-- fijos 10 y 1000 por hora, ventana máxima de 90 días, categorías cerradas).
-- Esperado: 0 filas.
SELECT 'falta la función' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias')
UNION ALL
SELECT 'atributos distintos de los esperados', 'secdef=' || p.prosecdef || ' volatilidad=' || p.provolatile::text || ' config=' || COALESCE(p.proconfig::text, 'NULL')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias'
  AND (p.prosecdef OR p.provolatile <> 's' OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, pg_temp'])
UNION ALL
SELECT 'EXECUTE a PUBLIC', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias'
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT 'EXECUTE distinto de lo esperado para ' || r.rol, NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias'
  AND has_function_privilege(r.rol, p.oid, 'EXECUTE') <> (r.rol = 'service_role')
UNION ALL
SELECT 'dueño distinto del de tiempo.marca', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias'
  AND p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT 'el cuerpo no contiene: ' || c.fragmento, NULL
FROM (VALUES ('m.terminal_id = v_serie'), ('c_pico_persona_hora  constant integer := 10'), ('c_pico_terminal_hora constant integer := 1000'),
             ('interval ''90 days'''), ('categoria_invalida'), ('marcas_posteriores_a_baja'), ('picos_de_tasa'), ('huecos_de_secuencia')) AS c(fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_anomalias' AND strpos(p.prosrc, c.fragmento) > 0);

-- 54) fn_terminal_baja_por_persona_inactiva y fn_terminal_movimiento_registrar tras 91_: siguen SECURITY DEFINER con search_path exacto y EXECUTE
-- sólo service_role (ni PUBLIC, anon, authenticated ni terminal_checador), dueño igual al de tiempo.marca; y sus cuerpos contienen las condiciones
-- críticas de 91_ (autor por creado_en DESC con fecha_efectiva sólo de desempate; saneo de invisibles/bidi y de U+2028/2029 en el detalle).
-- Esperado: 0 filas.
WITH f(proname) AS (VALUES ('fn_terminal_baja_por_persona_inactiva'), ('fn_terminal_movimiento_registrar'))
SELECT f.proname, 'falta la función' AS problema
FROM f WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT f.proname, 'atributos distintos de los esperados (DEFINER, search_path=tiempo, personas, pg_temp)'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, personas, pg_temp']
UNION ALL
SELECT f.proname, 'EXECUTE a PUBLIC'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT f.proname, 'EXECUTE distinto de lo esperado para ' || r.rol
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, p.oid, 'EXECUTE') <> (r.rol = 'service_role')
UNION ALL
SELECT f.proname, 'dueño distinto del de tiempo.marca'
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT c.proname, 'el cuerpo no contiene: ' || c.fragmento
FROM (VALUES
  ('fn_terminal_baja_por_persona_inactiva', 'ORDER BY b.creado_en DESC, b.fecha_efectiva DESC'),
  ('fn_terminal_movimiento_registrar', 'chr(8232)'),
  ('fn_terminal_movimiento_registrar', 'chr(8233)'),
  ('fn_terminal_movimiento_registrar', '\u200B-\u200F'),
  ('fn_terminal_movimiento_registrar', '\U000E0000-\U000E007F'),
  ('fn_terminal_movimiento_registrar', '[[:cntrl:]]'),
  ('fn_terminal_movimiento_registrar', 'error sin detalle')
) AS c(proname, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0);

-- 55) Endurecimiento de 92_: (a) la policy de INSERT de personas.bitacora_movimiento_persona ata registrado_por a auth.uid(), exige cambio_estado_persona y limita el
-- tipo a suspension/reactivacion/baja_definitiva; (b) trg_bitacora_persona_fija_hora (BEFORE INSERT por fila, tgtype 7) y su función (INVOKER, search_path exacto, EXECUTE
-- para nadie) con las condiciones críticas en el cuerpo; (c) trg_bitacora_terminal_usuario_detalle (BEFORE INSERT por fila, tgtype 7) y su función, igual.
-- Esperado: 0 filas.
SELECT 'falta la policy de INSERT o está degradada' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (
  SELECT 1 FROM pg_policies
  WHERE schemaname = 'personas' AND tablename = 'bitacora_movimiento_persona' AND policyname = 'bitacora_insert_requiere_permiso' AND cmd = 'INSERT'
    AND strpos(with_check, 'fn_caller_activo') > 0
    AND strpos(with_check, 'fn_caller_tiene_permiso(''cambio_estado_persona''') > 0
    AND strpos(with_check, 'registrado_por = auth.uid()') > 0
    AND strpos(with_check, '''suspension''') > 0 AND strpos(with_check, '''reactivacion''') > 0 AND strpos(with_check, '''baja_definitiva''') > 0
    AND strpos(with_check, '''alta''') = 0 AND strpos(with_check, ' OR ') = 0)
UNION ALL
SELECT 'hay otra policy de INSERT en la bitácora de personas', policyname
FROM pg_policies
WHERE schemaname = 'personas' AND tablename = 'bitacora_movimiento_persona' AND cmd = 'INSERT' AND policyname <> 'bitacora_insert_requiere_permiso'
UNION ALL
SELECT 'trigger ausente, deshabilitado o con otro tgtype', e.tgname
FROM (VALUES ('personas.bitacora_movimiento_persona', 'trg_bitacora_persona_fija_hora', 7),
             ('tiempo.bitacora_movimiento_terminal_usuario', 'trg_bitacora_terminal_usuario_a0_limpia_detalle', 7)) AS e(tabla, tgname, tipo)
LEFT JOIN pg_trigger t ON t.tgname = e.tgname AND t.tgrelid = e.tabla::regclass AND NOT t.tgisinternal
WHERE t.oid IS NULL OR t.tgenabled <> 'O' OR t.tgtype <> e.tipo
UNION ALL
SELECT 'el trigger de limpieza del detalle no corre ANTES que el de transiciones', l.tgname::text
FROM pg_trigger l
WHERE l.tgrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND l.tgname = 'trg_bitacora_terminal_usuario_a0_limpia_detalle' AND NOT l.tgisinternal
  AND NOT EXISTS (SELECT 1 FROM pg_trigger a
                  WHERE a.tgrelid = l.tgrelid AND a.tgname = 'trg_bitacora_terminal_usuario_aplica' AND NOT a.tgisinternal
                    AND l.tgname::text COLLATE "C" < a.tgname::text COLLATE "C")
UNION ALL
SELECT 'otro BEFORE INSERT por fila corre antes que el de limpieza del detalle', t.tgname::text
FROM pg_trigger t
WHERE t.tgrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND NOT t.tgisinternal
  AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 AND (t.tgtype & 4) <> 0
  AND t.tgname::text <> 'trg_bitacora_terminal_usuario_a0_limpia_detalle'
  AND t.tgname::text COLLATE "C" < 'trg_bitacora_terminal_usuario_a0_limpia_detalle' COLLATE "C"
UNION ALL
SELECT f.proname, 'atributos distintos (INVOKER, search_path exacto, EXECUTE para nadie)'
FROM (VALUES ('personas', 'fn_bitacora_persona_fija_hora', 'search_path=personas, pg_temp'),
             ('tiempo', 'fn_bitacora_terminal_usuario_limpia_detalle', 'search_path=tiempo, pg_temp')) AS f(esquema, proname, sp)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = f.esquema AND p.proname = f.proname AND NOT p.prosecdef AND p.proconfig = ARRAY[f.sp]
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE'))
UNION ALL
SELECT c.proname, 'el cuerpo no contiene: ' || c.fragmento
FROM (VALUES
  ('fn_bitacora_persona_fija_hora', 'auth.role() IN (''anon'', ''authenticated'')'),
  ('fn_bitacora_persona_fija_hora', 'NEW.creado_en := now()'),
  ('fn_bitacora_persona_fija_hora', 'fecha_efectiva_invalida'),
  ('fn_bitacora_terminal_usuario_limpia_detalle', 'chr(8232)'),
  ('fn_bitacora_terminal_usuario_limpia_detalle', '\u200B-\u200F'),
  ('fn_bitacora_terminal_usuario_limpia_detalle', '\U000E0000-\U000E007F')
) AS c(proname, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname IN ('personas', 'tiempo') AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0);

-- 56) Retiro de terminal_checador (93_): el rol queda vacío. Todas las partes son consultas de VIOLACIONES.
-- Esperado: 0 filas. (El rol existe, es NOLOGIN, sin policies, sin ACL de tabla/columna/secuencia/esquema/función/default, sin dependencias compartidas y sin otros miembros que postgres.)
SELECT 'policy que aún lo nombra' AS hallazgo, p.schemaname || '.' || p.tablename || '.' || p.policyname AS detalle
FROM pg_policies p WHERE 'terminal_checador' = ANY (p.roles)
UNION ALL
SELECT 'privilegio de tabla/secuencia', n.nspname || '.' || c.relname || ' ' || a.privilege_type
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, LATERAL aclexplode(c.relacl) a
WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'privilegio de esquema', n.nspname || ' ' || a.privilege_type
FROM pg_namespace n, LATERAL aclexplode(n.nspacl) a
WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'privilegio de función', p.oid::regprocedure::text || ' ' || a.privilege_type
FROM pg_proc p, LATERAL aclexplode(p.proacl) a
WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'ACL por defecto', d.defaclrole::regrole::text || ' ' || d.defaclobjtype::text
FROM pg_default_acl d, LATERAL aclexplode(d.defaclacl) a
WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'miembro de ' || r.rolname, m.rolname
FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
WHERE m.rolname = 'terminal_checador'
UNION ALL
SELECT 'miembro del rol distinto de postgres (postgres conserva sólo ADMIN OPTION, sin SET ni INHERIT)', m.rolname
FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname = 'terminal_checador' AND m.rolname <> 'postgres'
UNION ALL
SELECT 'postgres con SET o INHERIT sobre el rol', m.rolname
FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname = 'terminal_checador' AND m.rolname = 'postgres' AND (am.set_option OR am.inherit_option)
UNION ALL
SELECT 'privilegio de columna', c.relnamespace::regnamespace::text || '.' || c.relname || '.' || at.attname || ' ' || a.privilege_type
FROM pg_attribute at JOIN pg_class c ON c.oid = at.attrelid, LATERAL aclexplode(at.attacl) a
WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'dependencia compartida (pg_shdepend)', d.classid::regclass::text || ' ' || d.objid || ' deptype=' || d.deptype::text
FROM pg_shdepend d WHERE d.refclassid = 'pg_authid'::regclass AND d.refobjid = (SELECT oid FROM pg_roles WHERE rolname = 'terminal_checador')
UNION ALL
SELECT 'el rol puede iniciar sesión', rolname FROM pg_roles WHERE rolname = 'terminal_checador' AND rolcanlogin
UNION ALL
SELECT 'el rol no existe (verificadores rotos)', 'terminal_checador' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'terminal_checador');

-- NOTA: las secciones 57 y 58 describen el estado DESPUÉS de aplicar 94_ (57) y 95_ (58); antes de aplicarlas devuelven filas. La fila de la policy
-- bitacora_terminal_usuario_insert_web de la sección de policies (con huella_confirmada_manual) también corresponde al estado posterior a 94_.
-- 57) Huella sin conteo (94_): esquema, policy y funciones. Todas las partes son consultas de VIOLACIONES.
-- Esperado: 0 filas.
WITH cons AS (
  SELECT c.conname, pg_get_constraintdef(c.oid) AS def, c.confdeltype
  FROM pg_constraint c
  WHERE c.conrelid IN ('tiempo.bitacora_movimiento_terminal_usuario'::regclass, 'tiempo.terminal_usuario'::regclass)
), fn AS (
  SELECT p.proname, p.prosecdef, p.provolatile, p.proconfig, p.prosrc, p.oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'tiempo'
    AND p.proname IN ('fn_bitacora_terminal_usuario_aplica', 'fn_terminal_baja_por_caducidad', 'fn_terminal_anomalias')
)
SELECT 'constraint de tipo sin los dos tipos nuevos' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM cons WHERE conname = 'ck_bitacora_terminal_usuario_tipo'
                  AND def LIKE '%huella_confirmada_manual%' AND def LIKE '%huella_inferida%')
UNION ALL
SELECT 'origen_tipo: falta huella_confirmada_manual como web o sobra huella_inferida', NULL
WHERE NOT EXISTS (SELECT 1 FROM cons WHERE conname = 'ck_bitacora_terminal_usuario_origen_tipo'
                  AND def LIKE '%huella_confirmada_manual%' AND def NOT LIKE '%huella_inferida%')
UNION ALL
SELECT 'falta ck_bitacora_terminal_usuario_marca', NULL
WHERE NOT EXISTS (SELECT 1 FROM cons WHERE conname = 'ck_bitacora_terminal_usuario_marca' AND def LIKE '%huella_inferida%')
UNION ALL
SELECT 'ck_..._huellas fue modificada (sólo huella_capturada lleva conteo)', NULL
WHERE NOT EXISTS (SELECT 1 FROM cons WHERE conname = 'ck_bitacora_terminal_usuario_huellas' AND def LIKE '%huella_capturada%' AND def NOT LIKE '%huella_inferida%')
UNION ALL
SELECT 'faltan los CHECK de huella_evidencia en terminal_usuario', NULL
WHERE (SELECT count(*) FROM cons WHERE conname IN ('ck_terminal_usuario_huella_evidencia', 'ck_terminal_usuario_evidencia_conteo')) <> 2
UNION ALL
SELECT 'marca_id: falta la FK a tiempo.marca o no es NO ACTION', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass
                  AND c.contype = 'f' AND c.confrelid = 'tiempo.marca'::regclass AND c.confdeltype = 'a')
UNION ALL
SELECT 'falta el índice único parcial sobre marca_id', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'tiempo' AND indexname = 'uq_bitacora_terminal_usuario_marca'
                  AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%marca_id IS NOT NULL%')
UNION ALL
SELECT 'bitácora: tipo_movimiento demasiado corto para huella_confirmada_manual (24 caracteres)', NULL
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'tiempo' AND table_name = 'bitacora_movimiento_terminal_usuario'
                  AND column_name = 'tipo_movimiento' AND character_maximum_length >= 24)
UNION ALL
SELECT 'huella_evidencia: columna ausente o con tipo distinto de varchar(10)', NULL
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'tiempo' AND table_name = 'terminal_usuario'
                  AND column_name = 'huella_evidencia' AND character_maximum_length = 10)
UNION ALL
SELECT 'huella_evidencia: rol con INSERT/UPDATE de columna', r.rol || ' ' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE')) AS p(priv)
WHERE has_column_privilege(r.rol, 'tiempo.terminal_usuario', 'huella_evidencia', p.priv)
UNION ALL
SELECT 'policy de INSERT web: falta huella_confirmada_manual, sobra huella_inferida o no es authenticated', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'tiempo' AND p.tablename = 'bitacora_movimiento_terminal_usuario'
                  AND p.policyname = 'bitacora_terminal_usuario_insert_web' AND p.cmd = 'INSERT' AND p.roles = '{authenticated}'
                  AND p.with_check LIKE '%huella_confirmada_manual%' AND p.with_check NOT LIKE '%huella_inferida%'
                  AND p.with_check LIKE '%terminal_usuario_edicion%' AND p.with_check LIKE '%auth.uid()%')
UNION ALL
SELECT 'trigger de transiciones: no es DEFINER con search_path exacto, o le faltan las ramas/hints de 94_', f.proname
FROM fn f WHERE f.proname = 'fn_bitacora_terminal_usuario_aplica'
  AND NOT (f.prosecdef AND f.provolatile = 'v' AND f.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
           AND f.prosrc LIKE '%huella_inferida%' AND f.prosrc LIKE '%huella_confirmada_manual%' AND f.prosrc LIKE '%marca_no_corresponde%'
           AND f.prosrc LIKE '%auto_confirmacion_huella_prohibida%' AND f.prosrc LIKE '%nota_requerida%' AND f.prosrc LIKE '%huella_evidencia%'
           AND f.prosrc LIKE '%c_cuatro_ojos%' AND f.prosrc LIKE '%c_nota_min_manual%')
UNION ALL
SELECT 'caducidad: no es DEFINER con search_path exacto o no considera las tres evidencias', f.proname
FROM fn f WHERE f.proname = 'fn_terminal_baja_por_caducidad'
  AND NOT (f.prosecdef AND f.provolatile = 'v' AND f.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
           AND f.prosrc LIKE '%huella_inferida%' AND f.prosrc LIKE '%huella_confirmada_manual%' AND f.prosrc LIKE '%huella_capturada%'
           AND f.prosrc LIKE '%FOR UPDATE SKIP LOCKED%')
UNION ALL
SELECT 'anomalías: no es INVOKER/STABLE con search_path exacto o faltan las categorías nuevas', f.proname
FROM fn f WHERE f.proname = 'fn_terminal_anomalias'
  AND NOT (NOT f.prosecdef AND f.provolatile = 's' AND f.proconfig = ARRAY['search_path=tiempo, pg_temp']
           AND f.prosrc LIKE '%huellas_inferidas_exceso%' AND f.prosrc LIKE '%inferida_sin_marcas%' AND f.prosrc LIKE '%asignador_confirmador%')
UNION ALL
SELECT 'EXECUTE de más: el trigger no lo ejecuta nadie; caducidad y anomalías sólo service_role', f.proname || ' ' || r.rol
FROM fn f CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, f.oid, 'EXECUTE')
  AND NOT (f.proname <> 'fn_bitacora_terminal_usuario_aplica' AND r.rol = 'service_role')
UNION ALL
SELECT 'PUBLIC conserva EXECUTE', f.proname FROM fn f
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE((SELECT proacl FROM pg_proc WHERE oid = f.oid), acldefault('f', (SELECT proowner FROM pg_proc WHERE oid = f.oid)))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT 'cuenta de permisos distinta de 53 (D1: no hay permiso nuevo)', (SELECT count(*)::text FROM personas.permiso)
WHERE (SELECT count(*) FROM personas.permiso) <> 53;

-- 58) fn_marca_terminal_registrar tras 95_: lee modo_verificacion, activa con FOR UPDATE bloqueante (NUNCA SKIP LOCKED), sigue DEFINER con search_path
-- exacto y EXECUTE sólo service_role. Esperado: 0 filas.
SELECT 'fn_marca_terminal_registrar: propiedades o contenido de 95_ incorrectos' AS problema, p.proname AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_marca_terminal_registrar'
  AND NOT (p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
           AND p.prosrc LIKE '%modo_verificacion%' AND p.prosrc LIKE '%huella_inferida%' AND p.prosrc LIKE '%lock_timeout%'
           AND p.prosrc LIKE '%FOR UPDATE%' AND p.prosrc NOT LIKE '%SKIP LOCKED%'
           AND p.prosrc NOT LIKE '%SQLERRM%'
           AND has_function_privilege('service_role', p.oid, 'EXECUTE')
           AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
           AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE'));

-- 59) Logs sin identidad: ninguna función de tiempo ni de personas emite un RAISE WARNING/NOTICE/LOG/INFO que interpole employee_no o persona_id
-- (regla de security: nunca identidad en los logs del servidor). Consulta estática sobre pg_proc.prosrc, en dos pasadas sobre el texto SIN comentarios:
-- (1) con los ';' de los literales entre comillas neutralizados (un ';' dentro del mensaje cortaría el [^;]* y dejaría fuera los argumentos), busca las
-- palabras employee_no, persona_id o "persona %"; (2) con el CONTENIDO de todos los literales vaciado, busca las variables que cargan identidad (v_emp,
-- v_persona, p_persona, p_persona_id, rec.persona_id, rec.employee_no, NEW.employee_no, NEW.persona_id). Los literales se separan por PARIDAD de comillas
-- (string_to_array por ' : los elementos pares están dentro de un literal, y '' queda alineado); un reemplazo con regexp por pares se desalinea y puede
-- borrar el ';' que termina el RAISE. Cualquier función futura que loguee identidad falla aquí.
-- Esperado: 0 filas DESPUÉS de aplicar 95_ y 96_. Antes devuelve las funciones de 83_/84_/91_ que aún loguean identidad.
WITH s AS (
  SELECT n.nspname, p.proname, string_to_array(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '''') AS partes
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('tiempo', 'personas')
), t AS (
  SELECT nspname, proname,
         (SELECT string_agg(CASE WHEN u.o % 2 = 0 THEN replace(u.e, ';', ',') ELSE u.e END, '''' ORDER BY u.o)
          FROM unnest(partes) WITH ORDINALITY AS u(e, o)) AS s1,
         (SELECT string_agg(CASE WHEN u.o % 2 = 0 THEN '' ELSE u.e END, '''' ORDER BY u.o)
          FROM unnest(partes) WITH ORDINALITY AS u(e, o)) AS s2
  FROM s
)
SELECT nspname || '.' || proname AS funcion, 'RAISE de log con employee_no/persona_id' AS problema
FROM t
WHERE s1 ~* 'RAISE\s+(WARNING|NOTICE|LOG|INFO)[^;]*(employee_no|persona_id|persona %)'
   OR s2 ~* 'RAISE\s+(WARNING|NOTICE|LOG|INFO)[^;]*(\mv_emp\M|\mv_persona\M|\mp_persona\M|\mp_persona_id\M|\mrec\.(persona_id|employee_no)\M|NEW\.employee_no|NEW\.persona_id)'
ORDER BY 1;

-- 60) Interruptor de la activación por huella (97_): filas sembradas, formato, bitácora de configuración (inmutable, sin INSERT para nadie), trigger de auditoría y funciones.
-- Todas las partes son consultas de VIOLACIONES; un objeto que falta devuelve una fila (no un error). Esperado: 0 filas DESPUÉS de aplicar 97_.
-- (Consulta informativa del estado actual, para ejecutar a mano:  SELECT tiempo.fn_terminal_inferir_huella_estado();  y las últimas filas de tiempo.bitacora_config_terminal.)
WITH k(clave) AS (VALUES ('terminal_inferir_huella_activa'), ('terminal_inferir_huella_hasta')),
f(proname, definer, vol, search_path, roles) AS (VALUES
  ('fn_parametro_inferir_audita',            true,  'v', 'search_path=tiempo, pg_temp',                 ARRAY[]::text[]),
  ('fn_parametro_inferir_escribe',           true,  'v', 'search_path=tiempo, pg_temp',                 ARRAY[]::text[]),
  ('fn_parametro_truncate_bloqueado',        false, 'v', 'search_path=tiempo, pg_temp',                 ARRAY[]::text[]),
  ('fn_texto_sin_invisibles',                false, 'i', 'search_path=pg_temp',                         ARRAY[]::text[]),
  ('fn_terminal_inferir_huella_cambiar',     true,  'v', 'search_path=tiempo, personas, pg_temp',       ARRAY['authenticated']),
  ('fn_terminal_inferir_huella_estado',      true,  's', 'search_path=tiempo, pg_temp',                 ARRAY['service_role']),
  ('fn_terminal_config_actualizar',          true,  'v', 'search_path=tiempo, personas, pg_temp',       ARRAY['authenticated']),
  ('fn_bitacora_config_terminal_inmutable',  false, 'v', 'search_path=tiempo, pg_temp',                 ARRAY[]::text[]),
  ('fn_bitacora_config_terminal_truncate',   false, 'v', 'search_path=tiempo, pg_temp',                 ARRAY[]::text[])
)
SELECT 'clave sin UNA vigencia activa' AS problema, k.clave AS detalle
FROM k WHERE (SELECT count(*) FROM tiempo.parametro p WHERE p.clave = k.clave AND p.vigente_hasta IS NULL) <> 1
UNION ALL
SELECT 'valor del interruptor distinto de 0/1', p.valor
FROM tiempo.parametro p WHERE p.clave = 'terminal_inferir_huella_activa' AND p.vigente_hasta IS NULL AND p.valor NOT IN ('0', '1')
UNION ALL
SELECT 'vencimiento con formato inválido', p.valor
FROM tiempo.parametro p WHERE p.clave = 'terminal_inferir_huella_hasta' AND p.vigente_hasta IS NULL
  AND p.valor !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$'
UNION ALL
SELECT 'clave del interruptor DENTRO del catálogo de fn_terminal_config_catalogo', c.clave
FROM tiempo.fn_terminal_config_catalogo() c WHERE c.clave IN (SELECT clave FROM k)
UNION ALL
SELECT 'falta o difiere el CHECK', e.nombre
FROM (VALUES ('ck_parametro_inferir_huella_activa', 'terminal_inferir_huella_activa'), ('ck_parametro_inferir_huella_hasta', 'terminal_inferir_huella_hasta')) AS e(nombre, frag)
WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'tiempo.parametro'::regclass AND c.conname = e.nombre AND strpos(pg_get_constraintdef(c.oid), e.frag) > 0)
UNION ALL
SELECT 'falta la bitácora de configuración', NULL WHERE to_regclass('tiempo.bitacora_config_terminal') IS NULL
UNION ALL
SELECT 'la bitácora de configuración no tiene RLS', NULL FROM pg_class WHERE oid = to_regclass('tiempo.bitacora_config_terminal') AND NOT relrowsecurity
UNION ALL
SELECT 'privilegio de tabla de más en la bitácora', r.rol || ' ' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(priv)
WHERE has_table_privilege(r.rol, to_regclass('tiempo.bitacora_config_terminal'), p.priv)
UNION ALL
SELECT 'privilegio de columna de más en la bitácora', r.rol || ' ' || p.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('REFERENCES')) AS p(priv)
WHERE has_any_column_privilege(r.rol, to_regclass('tiempo.bitacora_config_terminal'), p.priv)
UNION ALL
SELECT 'SELECT de la bitácora distinto del esperado', r.rol
FROM (VALUES ('anon', false), ('authenticated', true), ('service_role', true), ('terminal_checador', false)) AS r(rol, debe)
WHERE to_regclass('tiempo.bitacora_config_terminal') IS NOT NULL
  AND has_table_privilege(r.rol, to_regclass('tiempo.bitacora_config_terminal'), 'SELECT') <> r.debe
UNION ALL
SELECT 'la bitácora de configuración no tiene exactamente 1 policy SELECT authenticated con permiso', NULL
WHERE to_regclass('tiempo.bitacora_config_terminal') IS NOT NULL
  AND (SELECT count(*) FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'bitacora_config_terminal') <> 1
UNION ALL
SELECT 'policy de la bitácora distinta de la esperada', NULL
WHERE to_regclass('tiempo.bitacora_config_terminal') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'tiempo' AND p.tablename = 'bitacora_config_terminal'
                  AND p.policyname = 'bitacora_config_terminal_select_lectura' AND p.cmd = 'SELECT' AND p.roles = '{authenticated}'
                  AND p.qual LIKE '%terminal_config_edicion%' AND p.qual LIKE '%fn_caller_activo%')
UNION ALL
SELECT 'trigger de la bitácora ausente, deshabilitado o con tipo distinto', e.tgname
FROM (VALUES ('trg_bitacora_config_terminal_inmutable', 27), ('trg_bitacora_config_terminal_truncate', 34)) AS e(tgname, tipo)
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = to_regclass('tiempo.bitacora_config_terminal') AND t.tgname = e.tgname
                  AND NOT t.tgisinternal AND t.tgenabled = 'O' AND t.tgtype = e.tipo)
UNION ALL
SELECT 'trigger de auditoría de tiempo.parametro ausente, deshabilitado o con tipo distinto (AFTER ROW INSERT|UPDATE|DELETE = 29)', 'trg_parametro_inferir_huella_audita'
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                  WHERE t.tgrelid = 'tiempo.parametro'::regclass AND t.tgname = 'trg_parametro_inferir_huella_audita' AND NOT t.tgisinternal
                    AND t.tgenabled = 'O' AND t.tgtype = 29 AND p.proname = 'fn_parametro_inferir_audita')
UNION ALL
SELECT 'trigger BEFORE TRUNCATE de tiempo.parametro ausente, deshabilitado o con tipo distinto (BEFORE STATEMENT TRUNCATE = 34)', 'trg_parametro_truncate_bloqueado'
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                  WHERE t.tgrelid = 'tiempo.parametro'::regclass AND t.tgname = 'trg_parametro_truncate_bloqueado' AND NOT t.tgisinternal
                    AND t.tgenabled = 'O' AND t.tgtype = 34 AND p.proname = 'fn_parametro_truncate_bloqueado')
UNION ALL
-- M2 de security: lista COMPLETA de triggers y reglas de las dos tablas que sostienen el interruptor; cualquier trigger BEFORE que cancele filas o regla INSTEAD ajeno salta aquí.
SELECT 'trigger inesperado en tiempo.parametro', t.tgname
FROM pg_trigger t WHERE t.tgrelid = 'tiempo.parametro'::regclass AND NOT t.tgisinternal
  AND t.tgname NOT IN ('trg_parametro_inferir_huella_audita', 'trg_parametro_truncate_bloqueado')
UNION ALL
SELECT 'regla (RULE) en tiempo.parametro', r.rulename
FROM pg_rewrite r WHERE r.ev_class = 'tiempo.parametro'::regclass AND r.rulename <> '_RETURN'
UNION ALL
SELECT 'policy en tiempo.parametro (debe seguir deny-all sin policies)', p.policyname
FROM pg_policies p WHERE p.schemaname = 'tiempo' AND p.tablename = 'parametro'
UNION ALL
SELECT 'tiempo.parametro sin RLS', NULL FROM pg_class WHERE oid = 'tiempo.parametro'::regclass AND NOT relrowsecurity
UNION ALL
SELECT 'trigger inesperado en la bitácora de configuración', t.tgname
FROM pg_trigger t WHERE t.tgrelid = to_regclass('tiempo.bitacora_config_terminal') AND NOT t.tgisinternal
  AND t.tgname NOT IN ('trg_bitacora_config_terminal_inmutable', 'trg_bitacora_config_terminal_truncate')
UNION ALL
SELECT 'regla (RULE) en la bitácora de configuración', r.rulename
FROM pg_rewrite r WHERE r.ev_class = to_regclass('tiempo.bitacora_config_terminal') AND r.rulename <> '_RETURN'
UNION ALL
SELECT 'función ausente', f.proname
FROM f WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = f.proname)
UNION ALL
SELECT 'SECURITY DEFINER distinto de lo esperado', f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.prosecdef IS DISTINCT FROM f.definer
UNION ALL
SELECT 'volatilidad distinta de la esperada', f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.provolatile::text <> f.vol
UNION ALL
SELECT 'search_path distinto de ' || f.search_path, f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proconfig IS DISTINCT FROM ARRAY[f.search_path]
UNION ALL
SELECT 'EXECUTE a PUBLIC', f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT 'EXECUTE distinto de lo esperado para ' || r.rol, f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE has_function_privilege(r.rol, p.oid, 'EXECUTE') <> (r.rol = ANY (f.roles))
UNION ALL
SELECT 'dueño distinto del de tiempo.marca', f.proname
FROM f JOIN pg_proc p ON p.proname = f.proname JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'tiempo'
WHERE p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT 'condiciones críticas ausentes en el cuerpo', c.proname || ': ' || c.fragmento
FROM (VALUES
  ('fn_terminal_inferir_huella_cambiar', 'terminal_config_edicion'),
  ('fn_terminal_inferir_huella_cambiar', 'nota_requerida'),
  ('fn_terminal_inferir_huella_cambiar', 'hasta_invalido'),
  ('fn_terminal_inferir_huella_cambiar', 'sin_consentimiento_vigente'),
  ('fn_terminal_inferir_huella_cambiar', 'terminal_no_activa'),
  ('fn_terminal_inferir_huella_cambiar', 'scj.txid_interruptor'),
  ('fn_terminal_inferir_huella_estado',  'vigencias_inconsistentes'),
  ('fn_terminal_inferir_huella_estado',  '''30 days'''),
  ('fn_terminal_inferir_huella_estado',  'hasta_excede_tope'),
  ('fn_terminal_inferir_huella_estado',  'via_funcion'),
  ('fn_terminal_inferir_huella_estado',  'sin_respaldo_de_la_funcion'),
  ('fn_parametro_inferir_audita',        'scj.txid_interruptor'),
  ('fn_parametro_inferir_audita',        'txid_current()'),
  ('fn_terminal_config_actualizar',      'terminal_inferir_huella_activa'),
  ('fn_terminal_config_actualizar',      'clave_no_editable')
) AS c(proname, fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = c.proname AND strpos(p.prosrc, c.fragmento) > 0)
UNION ALL
SELECT 'el lector de estado nombra al lector tolerante (acota el valor)', p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_inferir_huella_estado' AND strpos(p.prosrc, 'fn_terminal_config_valor') > 0;

-- 61) fn_marca_terminal_registrar tras 98_: lee el estado EFECTIVO del interruptor con la única definición, no usa el lector tolerante, sigue DEFINER con search_path exacto
-- y EXECUTE solo service_role. Esperado: 0 filas DESPUÉS de aplicar 98_.
SELECT 'fn_marca_terminal_registrar: propiedades o contenido de 98_ incorrectos' AS problema, p.proname AS detalle
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_marca_terminal_registrar'
  AND NOT (p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
           AND p.prosrc LIKE '%fn_terminal_inferir_huella_estado%' AND p.prosrc LIKE '%AND v_inferir%'
           AND p.prosrc NOT LIKE '%fn_terminal_config_valor%' AND p.prosrc NOT LIKE '%SKIP LOCKED%' AND p.prosrc NOT LIKE '%SQLERRM%'
           AND has_function_privilege('service_role', p.oid, 'EXECUTE')
           AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
           AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
           AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'));

-- 62) Campo opcional del latido (99_): tiempo.terminal.ingesta_detenida y fn_terminal_latido de 7 argumentos. Columna boolean NULL sin default, que nadie fuera del dueño y la función
-- puede escribir (ni service_role ni authenticated tienen UPDATE de la columna; anon no la lee); UNA sola fn_terminal_latido (sin overload viejo que deje la llamada ambigua),
-- DEFINER con search_path exacto, EXECUTE solo service_role, que escribe la columna y no interpola el id de la terminal en el mensaje de SCJ12. Esperado: 0 filas DESPUÉS de aplicar 99_.
SELECT 'columna ingesta_detenida: falta, con otro tipo, NOT NULL o con default' AS problema, 'tiempo.terminal' AS detalle
WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns c
                  WHERE c.table_schema = 'tiempo' AND c.table_name = 'terminal' AND c.column_name = 'ingesta_detenida'
                    AND c.data_type = 'boolean' AND c.is_nullable = 'YES' AND c.column_default IS NULL)
UNION ALL
SELECT 'columna ingesta_detenida: privilegio de más (UPDATE de service_role o authenticated, o SELECT de anon)', 'tiempo.terminal'
WHERE EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = 'tiempo.terminal'::regclass AND a.attname = 'ingesta_detenida' AND NOT a.attisdropped)
  AND (has_column_privilege('service_role', 'tiempo.terminal', 'ingesta_detenida', 'UPDATE')
       OR has_column_privilege('authenticated', 'tiempo.terminal', 'ingesta_detenida', 'UPDATE')
       OR has_column_privilege('anon', 'tiempo.terminal', 'ingesta_detenida', 'SELECT'))
UNION ALL
SELECT 'fn_terminal_latido: no hay exactamente UNA función con 7 argumentos (queda un overload viejo o falta la nueva)', count(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_latido'
HAVING count(*) <> 1 OR count(*) FILTER (WHERE p.pronargs = 7) <> 1
UNION ALL
SELECT 'fn_terminal_latido: propiedades o contenido de 99_ incorrectos', p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_latido' AND p.pronargs = 7
  AND NOT (p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
           AND p.prosrc LIKE '%ingesta_detenida%' AND p.prosrc NOT LIKE '%no está activa'', p_terminal_id%'
           AND has_function_privilege('service_role', p.oid, 'EXECUTE')
           AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
           AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'));
