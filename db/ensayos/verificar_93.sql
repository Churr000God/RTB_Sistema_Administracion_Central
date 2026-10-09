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
