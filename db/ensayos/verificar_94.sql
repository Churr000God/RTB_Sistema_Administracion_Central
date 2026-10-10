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
