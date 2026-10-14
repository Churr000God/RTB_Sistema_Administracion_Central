-- Ensayo de 102_personas_revoca_anon_y_privilegios_de_estructura.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_102.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 102_ ENCIMA de lo ya aplicado (88_-100_). No inserta filas en ninguna bitácora inmutable ni en ninguna tabla real: solo catálogo de privilegios, intentos
-- de acceso que deben fallar por privilegio (antes de tocar filas) y una tabla sintética de personas que se revierte. Las bitácoras se prueban por has_table_privilege, no por escritura.
-- Qué prueba: (A) foto de privilegios de personas Y de tiempo antes/después: 102_ no agrega nada, solo quita lo previsto en personas (todo de anon salvo SELECT sobre personas.permiso;
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN de authenticated y service_role) y NO cambia ningún privilegio de tiempo; (B) anon con SET ROLE; (C) authenticated y service_role; (D) defaults con una
-- tabla nueva; (E) reversa exacta e idempotencia; (F) verificar_ddl.sql completo (sección 66 en 0 filas).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (fase text, rol text, rel text, priv text, nivel text);
CREATE TEMP TABLE _reversa (n serial, sentencia text);
GRANT ALL ON _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

-- Foto de privilegios efectivos (incluye los de PUBLIC) de los 3 roles de la API sobre cada relación de personas y de tiempo.
CREATE FUNCTION pg_temp.foto(p_fase text) RETURNS void AS $$
BEGIN
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'tabla'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN unnest(CASE WHEN current_setting('server_version_num')::integer >= 170000
                         THEN ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']
                         ELSE ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] END) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'columna'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_any_column_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'secuencia'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind = 'S' AND has_sequence_privilege(r.rol, c.oid, p.priv);
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- Ejecuta p_sql como p_rol; p_esperado = 'ok' | SQLSTATE.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 90));
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Foto previa y reversa (la consulta EXACTA que 102_ documenta en su encabezado, para personas)
-- ============================================================================
CREATE TEMP TABLE _pol AS SELECT count(*)::integer AS n FROM pg_policies WHERE schemaname IN ('personas', 'tiempo');
SELECT pg_temp.foto('antes');
INSERT INTO _reversa (sentencia)
SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
              CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
WHERE n.nspname = 'personas' AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
GROUP BY c.oid, c.relkind, r.rolname;
INSERT INTO _res (caso, ok, detalle) SELECT 'P0 la foto previa tiene relaciones y la reversa tiene sentencias', (SELECT count(*) FROM _foto WHERE fase = 'antes') > 0 AND (SELECT count(*) FROM _reversa) > 0,
  'filas foto=' || (SELECT count(*) FROM _foto WHERE fase = 'antes') || ' sentencias reversa=' || (SELECT count(*) FROM _reversa);
INSERT INTO _res (caso, ok, detalle)
SELECT 'P1 (informativo) privilegios de anon sobre las tablas de personas ANTES, por tabla', true,
       COALESCE(string_agg(rel || '=' || n, '; ' ORDER BY rel), 'ninguno')
FROM (SELECT rel, count(*) AS n FROM _foto WHERE fase = 'antes' AND rol = 'anon' AND rel LIKE 'personas.%' AND nivel = 'tabla' GROUP BY rel) x;

\echo '=== pg_default_acl (todos los esquemas) ANTES de aplicar 102_ ==='
SELECT pg_get_userbyid(d.defaclrole) AS rol, COALESCE(n.nspname, '(global)') AS esquema, d.defaclobjtype AS tipo, d.defaclacl::text AS aclitems
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname IN ('personas', 'tiempo') OR n.nspname IS NULL ORDER BY 1, 2, 3;

\ir ../ddl/102_personas_revoca_anon_y_privilegios_de_estructura.sql

SELECT pg_temp.foto('despues');

\echo '=== pg_default_acl DESPUÉS de aplicar 102_ (personas y tiempo) ==='
SELECT pg_get_userbyid(d.defaclrole) AS rol, COALESCE(n.nspname, '(global)') AS esquema, d.defaclobjtype AS tipo, d.defaclacl::text AS aclitems
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname IN ('personas', 'tiempo') OR n.nspname IS NULL ORDER BY 1, 2, 3;

-- ============================================================================
-- A) Diferencia de privilegios
-- ============================================================================
SELECT pg_temp.verifica('A1 102_ NO agrega ningún privilegio (todo lo de después estaba antes), en personas y en tiempo',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (d.rol, d.rel, d.priv, d.nivel)))$$);
SELECT pg_temp.verifica('A2 lo que se quita en personas es SOLO: todo de anon (salvo SELECT en permiso), y TRUNCATE/REFERENCES/TRIGGER/MAINTAIN de authenticated y service_role',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.rel LIKE 'personas.%'
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel))
        AND NOT (a.rol = 'anon' OR a.priv IN ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')))$$);
SELECT pg_temp.verifica('A3 NADA cambia en tiempo (la foto de tiempo es idéntica antes y después, en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.rel LIKE 'tiempo.%' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND d.rel LIKE 'tiempo.%' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (d.rol, d.rel, d.priv, d.nivel)))$$);
SELECT pg_temp.verifica('A4 authenticated y service_role CONSERVAN SELECT/INSERT/UPDATE/DELETE (y de columna SELECT/INSERT/UPDATE) exactamente igual en personas',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.rel LIKE 'personas.%' AND a.rol IN ('authenticated', 'service_role') AND a.priv IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'USAGE')
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel)))$$);
SELECT pg_temp.verifica('A5 después: anon sin ningún privilegio sobre personas, salvo SELECT sobre personas.permiso (tabla y columna)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rol = 'anon' AND rel LIKE 'personas.%' AND NOT (rel = 'personas.permiso' AND priv = 'SELECT'))$$);
SELECT pg_temp.verifica('A5b después: anon SÍ conserva SELECT sobre personas.permiso (humo del Data API, sección 9 del verificador)',
  $$SELECT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rol = 'anon' AND rel = 'personas.permiso' AND priv = 'SELECT' AND nivel = 'tabla')$$);
SELECT pg_temp.verifica('A6 después: ni authenticated ni service_role tienen TRUNCATE, REFERENCES ni TRIGGER en personas',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rel LIKE 'personas.%' AND rol IN ('authenticated', 'service_role') AND priv IN ('TRUNCATE', 'REFERENCES', 'TRIGGER'))$$);
SELECT pg_temp.verifica('A6b después: ni authenticated ni service_role tienen MAINTAIN en personas (service_role salvo el heredado de pg_maintain)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rel LIKE 'personas.%' AND priv = 'MAINTAIN' AND (rol = 'authenticated'
        OR (rol = 'service_role' AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE g.rolname = 'pg_maintain' AND u.rolname = 'service_role'))))$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'A7 (informativo) cuántos privilegios quitó 102_', true,
  'anon=' || count(*) FILTER (WHERE a.rol = 'anon') || ' authenticated=' || count(*) FILTER (WHERE a.rol = 'authenticated') || ' service_role=' || count(*) FILTER (WHERE a.rol = 'service_role')
FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel));

-- ============================================================================
-- B) anon (la anon key sin sesión) ya no toca la identidad
-- ============================================================================
SELECT pg_temp.caso('B1 anon SELECT personas.persona (CURP/RFC/NSS)', 'anon', $$SELECT 1 FROM personas.persona LIMIT 1$$, '42501');
SELECT pg_temp.caso('B2 anon SELECT personas.expediente', 'anon', $$SELECT 1 FROM personas.expediente LIMIT 1$$, '42501');
SELECT pg_temp.caso('B3 anon SELECT personas.usuario', 'anon', $$SELECT 1 FROM personas.usuario LIMIT 1$$, '42501');
SELECT pg_temp.caso('B4 anon SELECT personas.bitacora_movimiento_persona', 'anon', $$SELECT 1 FROM personas.bitacora_movimiento_persona LIMIT 1$$, '42501');
SELECT pg_temp.caso('B5 anon SELECT personas.asignacion', 'anon', $$SELECT 1 FROM personas.asignacion LIMIT 1$$, '42501');
SELECT pg_temp.caso('B6 anon INSERT personas.persona', 'anon', $$INSERT INTO personas.persona DEFAULT VALUES$$, '42501');
SELECT pg_temp.caso('B7 anon UPDATE personas.persona', 'anon', $$UPDATE personas.persona SET primer_nombre = primer_nombre$$, '42501');
SELECT pg_temp.caso('B8 anon DELETE personas.persona', 'anon', $$DELETE FROM personas.persona$$, '42501');
SELECT pg_temp.caso('B9 anon TRUNCATE personas.persona (no está sujeto a RLS)', 'anon', $$TRUNCATE personas.persona$$, '42501');
SELECT pg_temp.caso('B10 anon SELECT personas.permiso (excepción documentada: ok, RLS no le deja filas)', 'anon', $$SELECT 1 FROM personas.permiso LIMIT 1$$, 'ok');
SELECT pg_temp.caso('B11 anon INSERT personas.permiso denegado', 'anon', $$INSERT INTO personas.permiso DEFAULT VALUES$$, '42501');
SELECT pg_temp.caso('B12 anon DELETE personas.permiso denegado', 'anon', $$DELETE FROM personas.permiso$$, '42501');
SELECT pg_temp.caso('B13 anon TRUNCATE personas.permiso denegado', 'anon', $$TRUNCATE personas.permiso$$, '42501');
SELECT pg_temp.verifica('B14 anon sin ningún privilegio sobre las dos bitácoras inmutables (por has_table_privilege; no se escribe en ellas)',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['personas.bitacora_movimiento_persona', 'personas.bitacora_movimiento_puesto_permiso']) t CROSS JOIN unnest(CASE WHEN current_setting('server_version_num')::integer >= 170000
        THEN ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] ELSE ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] END) p WHERE has_table_privilege('anon', t, p))$$);

-- ============================================================================
-- C) authenticated y service_role siguen funcionando; las bitácoras conservan su inmutabilidad
-- ============================================================================
SELECT pg_temp.caso('C1 authenticated SELECT personas.persona (RLS decide filas; sin sesión devuelve 0, sin error)', 'authenticated', $$SELECT 1 FROM personas.persona LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C2 authenticated SELECT personas.permiso', 'authenticated', $$SELECT 1 FROM personas.permiso LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C3 authenticated TRUNCATE personas.persona denegado', 'authenticated', $$TRUNCATE personas.persona$$, '42501');
SELECT pg_temp.caso('C4 service_role SELECT personas.persona', 'service_role', $$SELECT 1 FROM personas.persona LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C5 service_role SELECT personas.usuario', 'service_role', $$SELECT 1 FROM personas.usuario LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C6 service_role SELECT personas.bitacora_movimiento_persona', 'service_role', $$SELECT 1 FROM personas.bitacora_movimiento_persona LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C7 service_role TRUNCATE personas.persona denegado', 'service_role', $$TRUNCATE personas.persona$$, '42501');
SELECT pg_temp.verifica('C8 después: las dos bitácoras NO tienen TRUNCATE para authenticated ni service_role (por catálogo, sin escribir); su inmutabilidad real es el trigger (C9), no el privilegio',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['personas.bitacora_movimiento_persona', 'personas.bitacora_movimiento_puesto_permiso']) t CROSS JOIN unnest(ARRAY['authenticated', 'service_role']) r
        WHERE has_table_privilege(r, t, 'TRUNCATE'))$$);
SELECT pg_temp.verifica('C8b UPDATE/DELETE de las dos bitácoras para authenticated y service_role quedan EXACTAMENTE como estaban (102_ no los toca; ver A4)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.rel IN ('personas.bitacora_movimiento_persona', 'personas.bitacora_movimiento_puesto_permiso') AND a.priv IN ('UPDATE', 'DELETE') AND a.rol IN ('authenticated', 'service_role')
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
    AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND d.rel IN ('personas.bitacora_movimiento_persona', 'personas.bitacora_movimiento_puesto_permiso') AND d.priv IN ('UPDATE', 'DELETE') AND d.rol IN ('authenticated', 'service_role')
        AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (d.rol, d.rel, d.priv, d.nivel)))$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'C8c (informativo) UPDATE/DELETE vigentes sobre las bitácoras tras 102_', true,
       COALESCE(string_agg(rel || ':' || rol || ':' || priv, '; ' ORDER BY rel, rol, priv), 'ninguno')
FROM _foto WHERE fase = 'despues' AND rel IN ('personas.bitacora_movimiento_persona', 'personas.bitacora_movimiento_puesto_permiso') AND priv IN ('UPDATE', 'DELETE') AND nivel = 'tabla';
SELECT pg_temp.verifica('C9 los triggers de inmutabilidad de las bitácoras de personas siguen habilitados (102_ no los toca)',
  $$SELECT count(*) >= 2 AND bool_and(t.tgenabled = 'O') FROM pg_trigger t WHERE t.tgrelid IN ('personas.bitacora_movimiento_persona'::regclass, 'personas.bitacora_movimiento_puesto_permiso'::regclass) AND NOT t.tgisinternal$$);
SELECT pg_temp.verifica('C10 el número de policies no cambió respecto de antes de aplicar (102_ no crea ni cambia policies; 77 con la base previa a 104_, 76 después)',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = (SELECT n FROM _pol)$$);

-- ============================================================================
-- D) Privilegios por defecto: una tabla nueva ya no nace con GRANT ALL
-- ============================================================================
CREATE TABLE personas._ensayo_102 (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, x integer);
CREATE SEQUENCE personas._ensayo_102_seq;
SELECT pg_temp.verifica('D1 tabla nueva: anon sin ningún privilegio',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(CASE WHEN current_setting('server_version_num')::integer >= 170000 THEN ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] ELSE ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] END) p WHERE has_table_privilege('anon', 'personas._ensayo_102', p))$$);
SELECT pg_temp.verifica('D2 tabla nueva: authenticated y service_role sí tienen SELECT, INSERT, UPDATE y DELETE',
  $$SELECT bool_and(has_table_privilege(r, 'personas._ensayo_102', p)) FROM unnest(ARRAY['authenticated','service_role']) r CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p$$);
SELECT pg_temp.verifica('D3 tabla nueva: authenticated y service_role NO tienen TRUNCATE, REFERENCES, TRIGGER ni MAINTAIN (salvo el heredado de pg_maintain)',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['authenticated','service_role']) r CROSS JOIN unnest(CASE WHEN current_setting('server_version_num')::integer >= 170000 THEN ARRAY['TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] ELSE ARRAY['TRUNCATE','REFERENCES','TRIGGER'] END) p
        WHERE has_table_privilege(r, 'personas._ensayo_102', p) AND NOT (r = 'service_role' AND p = 'MAINTAIN' AND EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE g.rolname = 'pg_maintain' AND u.rolname = 'service_role')))$$);
SELECT pg_temp.verifica('D4 secuencia nueva: anon sin privilegios; authenticated y service_role con USAGE',
  $$SELECT NOT has_sequence_privilege('anon', 'personas._ensayo_102_seq', 'USAGE') AND has_sequence_privilege('authenticated', 'personas._ensayo_102_seq', 'USAGE') AND has_sequence_privilege('service_role', 'personas._ensayo_102_seq', 'USAGE')$$);
DROP SEQUENCE personas._ensayo_102_seq;
DROP TABLE personas._ensayo_102;

-- ============================================================================
-- E) Reversa exacta e idempotencia
-- ============================================================================
SELECT pg_temp.foto('tras_102');
DO $$
DECLARE s record;
BEGIN
  FOR s IN SELECT sentencia FROM _reversa ORDER BY n LOOP EXECUTE s.sentencia; END LOOP;
  ALTER DEFAULT PRIVILEGES IN SCHEMA personas GRANT ALL ON TABLES TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA personas GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
END
$$;
SELECT pg_temp.foto('reversa');
SELECT pg_temp.verifica('E1 la reversa documentada deja los privilegios IDÉNTICOS a la foto previa (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);
SELECT pg_temp.verifica('E2 tras la reversa los privilegios por defecto de personas vuelven a incluir a anon (estado de 08_)',
  $$SELECT EXISTS (SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a JOIN pg_roles g ON g.oid = a.grantee
                   WHERE n.nspname = 'personas' AND d.defaclobjtype = 'r' AND g.rolname = 'anon')$$);

\ir ../ddl/102_personas_revoca_anon_y_privilegios_de_estructura.sql
SELECT pg_temp.foto('reaplicada');
SELECT pg_temp.verifica('E3 102_ es idempotente: reaplicarla tras la reversa deja la misma foto que la primera vez (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_102' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_102' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);
\ir ../ddl/102_personas_revoca_anon_y_privilegios_de_estructura.sql
SELECT pg_temp.verifica('E4 aplicarla una vez más no falla y los defaults de personas no incluyen a anon',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a JOIN pg_roles g ON g.oid = a.grantee
                       WHERE n.nspname = 'personas' AND d.defaclobjtype IN ('r', 'S') AND g.rolname = 'anon')$$);

-- ============================================================================
-- F) verificar_ddl.sql completo con 102_ aplicada: sección 66 en 0 filas, y ninguna sección nueva con filas
-- ============================================================================
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
