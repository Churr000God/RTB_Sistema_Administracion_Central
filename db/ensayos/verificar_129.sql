-- Extracto de db/verificar_ddl.sql: secciones 55, 91 y 92 (129_). La fuente vigente es db/verificar_ddl.sql; regenerar si cambia.
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

-- 91) Baja definitiva exige asignacion_edicion (129_). Solo violaciones. Esperado: 0 filas DESPUÉS de aplicar 129_ (antes de aplicarla devuelve 1).
-- La policy de INSERT de personas.bitacora_movimiento_persona debe seguir siendo la única, de INSERT, PERMISSIVE, para PUBLIC y sin USING, y su WITH CHECK debe
-- llevar el CASE que exige fn_caller_tiene_permiso('asignacion_edicion') cuando tipo_movimiento = 'baja_definitiva' (escrito sin OR por la sección 55).
SELECT 'bitacora_insert_requiere_permiso' AS objeto, 'no es INSERT/PERMISSIVE/PUBLIC sin USING, o la baja_definitiva no exige asignacion_edicion' AS problema
WHERE NOT EXISTS (
  SELECT 1 FROM pg_policy po
  WHERE po.polrelid = 'personas.bitacora_movimiento_persona'::regclass AND po.polname = 'bitacora_insert_requiere_permiso'
    AND po.polcmd = 'a' AND po.polpermissive AND po.polroles = '{0}'::oid[] AND po.polqual IS NULL
    AND pg_get_expr(po.polwithcheck, po.polrelid) ~ 'CASE\s+WHEN \(\(tipo_movimiento\)::text = ''baja_definitiva''::text\) THEN personas\.fn_caller_tiene_permiso\(''asignacion_edicion''::text\)\s+ELSE true\s+END'
);

-- 92) INFORMATIVA (129_): puestos que tienen cambio_estado_persona (directo o heredado de un subordinado: es heredable) pero NO asignacion_edicion (no heredable).
-- Tras 129_ esos puestos pueden suspender y reactivar pero NO dar de baja (42501). Esperado: 0 filas al 28-oct-2026; una fila no es un error del DDL, es un
-- aviso para RH/TI (otorgar asignacion_edicion o aceptar que ese puesto no da bajas).
WITH RECURSIVE desc_ AS (
  SELECT pu.id AS raiz, pu.id AS id FROM personas.puesto pu
  UNION
  SELECT d.raiz, h.id FROM desc_ d JOIN personas.puesto h ON h.reporta_a_id = d.id
),
efectivo AS (
  SELECT pu.id AS puesto_id, pe.codigo
  FROM personas.puesto pu
  CROSS JOIN personas.permiso pe
  WHERE pe.codigo IN ('cambio_estado_persona', 'asignacion_edicion')
    AND (EXISTS (SELECT 1 FROM personas.puesto_permiso pp WHERE pp.puesto_id = pu.id AND pp.codigo = pe.codigo AND pp.activo)
         OR (pe.heredable AND EXISTS (SELECT 1 FROM desc_ d JOIN personas.puesto_permiso pp ON pp.puesto_id = d.id AND pp.codigo = pe.codigo AND pp.activo
                                      WHERE d.raiz = pu.id)))
)
SELECT pu.nombre_puesto AS puesto, pu.activo,
       (SELECT count(*) FROM personas.asignacion a WHERE a.puesto_id = pu.id AND a.vigente_hasta IS NULL) AS ocupantes_vigentes,
       CASE WHEN EXISTS (SELECT 1 FROM personas.puesto_permiso pp WHERE pp.puesto_id = pu.id AND pp.codigo = 'cambio_estado_persona' AND pp.activo)
            THEN 'directo' ELSE 'heredado' END AS cambio_estado_persona
FROM personas.puesto pu
WHERE EXISTS (SELECT 1 FROM efectivo e WHERE e.puesto_id = pu.id AND e.codigo = 'cambio_estado_persona')
  AND NOT EXISTS (SELECT 1 FROM efectivo e WHERE e.puesto_id = pu.id AND e.codigo = 'asignacion_edicion')
ORDER BY pu.nombre_puesto;
