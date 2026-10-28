-- Extracto de db/verificar_ddl.sql: secciones 89 (127_) y 90 (128_). La fuente vigente es db/verificar_ddl.sql; regenerar si cambia.
-- 89) «Hoy» en hora de México (127_, P-055). Solo violaciones. Esperado: 0 filas DESPUÉS de aplicar 127_ (antes de aplicarla devuelve 11: las 10 funciones con CURRENT_DATE más la fila de conteo).
-- Ninguna función de tiempo/personas puede tomar la fecha de la sesión (TimeZone = UTC en esta base) con CURRENT_DATE, LOCALTIMESTAMP, now()::date o
-- current_timestamp::date: la fecha de «hoy» sale de personas.fn_hoy_mexico(). Fuera de esta regla, a propósito: un instante ya guardado convertido a fecha
-- (p. ej. fecha_efectiva::date en fn_bitacora_sincroniza_persona) y el UTC explícito de fn_terminal_inferir_huella_* ((now() AT TIME ZONE 'UTC')::date, 97_).
-- Además, las 10 funciones de 127_ deben seguir llamando a personas.fn_hoy_mexico().
-- Nota (security, 28-oct): las claves terminal_inferir_huella_% de tiempo.parametro siguen en fecha UTC a propósito (decisión de Diego). Cualquier chequeo de
-- «vigente_desde > fn_hoy_mexico()» sobre tiempo.parametro debe filtrar clave NOT LIKE 'terminal_inferir_huella_%': entre las 18:00 y las 24:00 de CDMX esas filas
-- pueden empezar legítimamente «mañana». La precondición DO de 127_ (ya aplicada) no lo filtra: si se vuelve a correr 127_ en esa franja (p. ej. en ensayo_127),
-- puede abortar sin que haya un problema real; correrlo de día.
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS objeto, 'usa la fecha de la sesión (UTC) en vez de personas.fn_hoy_mexico()' AS problema
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('tiempo', 'personas')
  AND p.prosrc ~* '\mcurrent_date\M|\mlocaltimestamp\M|now\(\)\s*::\s*date|\mcurrent_timestamp\s*::\s*date'
UNION ALL
SELECT 'tiempo/personas', 'falta personas.fn_hoy_mexico() en alguna de las 10 funciones de 127_'
WHERE (SELECT count(*) FROM pg_proc p
       WHERE p.oid IN ('personas.fn_persona_sincroniza_baja()'::regprocedure, 'tiempo.fn_jornada_asignada_protege_borrado()'::regprocedure,
                       'tiempo.fn_jornada_asignada_protege_vigencias()'::regprocedure, 'tiempo.fn_patron_semanal_solo_jornada_futura()'::regprocedure,
                       'tiempo.fn_jornada_en_curso_mover_limite(bigint, date)'::regprocedure,
                       'tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer)'::regprocedure,
                       'tiempo.fn_jornada_futura_eliminar(bigint)'::regprocedure, 'tiempo.fn_parametro_actualizar_valor(character varying, text, uuid)'::regprocedure,
                       'tiempo.fn_terminal_config_actualizar(text, text)'::regprocedure, 'tiempo.fn_terminal_config_valor(text)'::regprocedure)
         AND p.prosrc LIKE '%personas.fn_hoy_mexico()%') <> 10;

-- 90) Baja por la bitácora en fecha de México (128_). Solo violaciones. Esperado: 0 filas DESPUÉS de aplicar 128_ (antes de aplicarla devuelve 2).
-- Ninguna función de tiempo/personas puede convertir fecha_efectiva (timestamptz) a fecha o timestamp con la zona de la sesión (UTC): ::date, ::timestamp, CAST(... AS date) o date(...); y
-- personas.fn_bitacora_sincroniza_persona debe usar personas.fn_hoy_mexico(NEW.fecha_efectiva) en sus dos líneas (fecha_baja y cierre de asignaciones),
-- seguir INVOKER sin search_path, con dueño postgres y sin EXECUTE para PUBLIC, anon, authenticated ni service_role.
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS objeto, 'convierte fecha_efectiva a fecha o timestamp con la zona de la sesión (::date, ::timestamp, CAST o date()) en vez de personas.fn_hoy_mexico(fecha_efectiva)' AS problema
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('tiempo', 'personas') AND p.prosrc ~* 'fecha_efectiva\s*::\s*(date|timestamp)|cast\s*\(\s*[a-z_.]*fecha_efectiva\s+as\s+date|date\s*\(\s*[a-z_.]*fecha_efectiva'
UNION ALL
SELECT 'personas.fn_bitacora_sincroniza_persona()', 'no usa fn_hoy_mexico(NEW.fecha_efectiva) dos veces, o cambió de SECURITY/search_path/dueño, o tiene EXECUTE para algún rol de la API'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p
  WHERE p.oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure
    AND regexp_count(p.prosrc, 'personas\.fn_hoy_mexico\(NEW\.fecha_efectiva\)') = 2
    AND NOT p.prosecdef AND p.proconfig IS NULL AND pg_get_userbyid(p.proowner) = 'postgres'
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)
);
