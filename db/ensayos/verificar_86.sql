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
   'personas.fn_caller_activo AND personas.fn_caller_tiene_permiso''terminal_usuario_edicion'' AND origen = ''web'' AND tipo_movimiento = ANY ARRAY[''asignado'', ''baja_solicitada''][] AND registrado_por = AUTHUID')),
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
