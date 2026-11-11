-- Extracto de db/verificar_ddl.sql: sección 93 (130_). La fuente vigente es db/verificar_ddl.sql; regenerar si cambia.
-- 93) Cierre del auto-otorgamiento de permisos por puesto (130_). Solo violaciones. Esperado: 0 filas DESPUÉS de aplicar 130_ (antes de aplicarla devuelve 11: función nueva, sincroniza INVOKER, 6 privilegios de escritura y 3 policies).
-- (a) personas.fn_bitacora_puesto_permiso_regla_autootorgamiento() existe como SECURITY DEFINER con search_path = personas, pg_temp, dueño postgres, sin EXECUTE
--     para PUBLIC, anon, authenticated ni service_role, con los tres HINT literales; y trg_bitacora_puesto_permiso_regla_autootorgamiento existe habilitado,
--     BEFORE INSERT FOR EACH ROW sobre personas.bitacora_movimiento_puesto_permiso, llamando a esa función.
-- (b) personas.fn_puesto_permiso_sincroniza() es SECURITY DEFINER con search_path = personas, pg_temp, del mismo dueño que personas.puesto_permiso (postgres) y sin
--     EXECUTE para ningún rol de la API; la tabla no tiene FORCE ROW LEVEL SECURITY (si lo tuviera, el trigger DEFINER quedaría sujeto a RLS sin policies de escritura).
-- (c) personas.puesto_permiso sin INSERT/UPDATE/DELETE para anon, authenticated ni service_role.
-- (d) personas.puesto_permiso sin ninguna policy que no sea de SELECT (una de escritura reabre el otorgamiento directo sin bitácora).
-- Sin cualquiera de ellos, alguien con puesto_permiso_edicion vuelve a otorgarse permisos por PostgREST. Línea base de policies tras 130_: 73 (76 - 3).
SELECT 'personas.fn_bitacora_puesto_permiso_regla_autootorgamiento() / trg_bitacora_puesto_permiso_regla_autootorgamiento' AS objeto,
       'falta, cambió de SECURITY/search_path/dueño, tiene EXECUTE para algún rol de la API, perdió un HINT, o el trigger no es BEFORE INSERT ROW habilitado' AS problema
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_trigger t ON t.tgfoid = p.oid
  WHERE n.nspname = 'personas' AND p.proname = 'fn_bitacora_puesto_permiso_regla_autootorgamiento' AND p.pronargs = 0
    AND p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND NOT p.proleakproof
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND strpos(p.prosrc, 'HINT = ''autootorgamiento_directo''') > 0 AND strpos(p.prosrc, 'HINT = ''autootorgamiento_por_herencia''') > 0
    AND strpos(p.prosrc, 'HINT = ''autor_distinto_del_caller''') > 0 AND strpos(p.prosrc, 'ERRCODE = ''SCJ29''') > 0
    AND t.tgrelid = 'personas.bitacora_movimiento_puesto_permiso'::regclass AND t.tgname = 'trg_bitacora_puesto_permiso_regla_autootorgamiento'
    AND NOT t.tgisinternal AND t.tgenabled = 'O'
    AND (t.tgtype & 1) = 1      -- ROW
    AND (t.tgtype & 2) = 2      -- BEFORE
    AND (t.tgtype & 4) = 4      -- INSERT
    AND (t.tgtype & (8 | 16 | 32)) = 0  -- ni DELETE, ni UPDATE, ni TRUNCATE
)
UNION ALL
SELECT 'personas.fn_puesto_permiso_sincroniza()', 'no es DEFINER con search_path = personas, pg_temp, su dueño no es el de puesto_permiso, tiene EXECUTE para un rol de la API, o la tabla tiene FORCE RLS'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_class c ON c.oid = 'personas.puesto_permiso'::regclass
  WHERE p.oid = 'personas.fn_puesto_permiso_sincroniza()'::regprocedure
    AND p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND p.proowner = c.relowner
    AND NOT c.relforcerowsecurity
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
)
UNION ALL
SELECT 'personas.puesto_permiso → ' || r.rol, 'conserva ' || pr.priv
FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol)
CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE')) AS pr(priv)
WHERE has_table_privilege(r.rol, 'personas.puesto_permiso', pr.priv)
UNION ALL
SELECT 'personas.puesto_permiso.' || p.policyname, 'policy que no es de SELECT (' || p.cmd || ')'
FROM pg_policies p
WHERE p.schemaname = 'personas' AND p.tablename = 'puesto_permiso' AND p.cmd <> 'SELECT';
