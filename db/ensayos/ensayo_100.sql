-- Ensayo de 100_tiempo_revoca_anon_y_privilegios_de_estructura.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_100.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 100_ ENCIMA de lo ya aplicado (88_-99_). No consulta ni escribe datos reales; solo catálogo de privilegios y una tabla sintética que se revierte.
-- Qué prueba: (A) comparando una foto de privilegios ANTES y DESPUÉS, que 100_ NO agrega nada y solo quita lo previsto (todo de anon; TRUNCATE/REFERENCES/TRIGGER de authenticated y
-- service_role) y que ningún otro privilegio de authenticated/service_role cambia; (B) el comportamiento real como anon con SET ROLE (la anon key simulada); (C) authenticated y service_role
-- siguen funcionando para lo que usa el backend; (D) los privilegios por defecto con una tabla nueva; (E) la REVERSA EXACTA documentada en 100_ restaura la foto previa, y 100_ es idempotente;
-- (F) verificar_ddl.sql completo (sección 63 en 0 filas).
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

-- Foto de privilegios efectivos (incluye los de PUBLIC) de los 3 roles de la API sobre cada relación de tiempo.
CREATE FUNCTION pg_temp.foto(p_fase text) RETURNS void AS $$
BEGIN
  INSERT INTO _foto
  SELECT p_fase, r.rol, c.relname::text, p.priv, 'tabla'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) p(priv)
  WHERE n.nspname = 'tiempo' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, c.relname::text, p.priv, 'columna'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) p(priv)
  WHERE n.nspname = 'tiempo' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_any_column_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, c.relname::text, p.priv, 'secuencia'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) p(priv)
  WHERE n.nspname = 'tiempo' AND c.relkind = 'S' AND has_sequence_privilege(r.rol, c.oid, p.priv);
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
-- Foto previa y reversa (la consulta EXACTA que 100_ documenta en su encabezado)
-- ============================================================================
SELECT pg_temp.foto('antes');
INSERT INTO _reversa (sentencia)
SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
              CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
WHERE n.nspname = 'tiempo' AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
GROUP BY c.oid, c.relkind, r.rolname;
INSERT INTO _res (caso, ok, detalle) SELECT 'P0 la foto previa tiene relaciones y la reversa tiene sentencias', (SELECT count(*) FROM _foto WHERE fase = 'antes') > 0 AND (SELECT count(*) FROM _reversa) > 0,
  'filas foto=' || (SELECT count(*) FROM _foto WHERE fase = 'antes') || ' sentencias reversa=' || (SELECT count(*) FROM _reversa);

\ir ../ddl/100_tiempo_revoca_anon_y_privilegios_de_estructura.sql

SELECT pg_temp.foto('despues');

-- Defaults de objetos (security): se IMPRIME siempre el pg_default_acl COMPLETO (todos los roles y esquemas, incluidos los globales de Supabase, defaclnamespace = 0), pase o falle D1.
-- Si D1 falla NO se corrige con un REVOKE global sin verlo: un default global para anon no lo retira ALTER DEFAULT PRIVILEGES IN SCHEMA; se reporta.
\echo '=== pg_default_acl COMPLETO tras aplicar 100_ (rol | esquema | tipo | aclitems) ==='
SELECT pg_get_userbyid(d.defaclrole) AS rol, COALESCE(n.nspname, '(global)') AS esquema, d.defaclobjtype AS tipo, d.defaclacl::text AS aclitems
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace ORDER BY 1, 2, 3;
INSERT INTO _res (caso, ok, detalle)
SELECT 'D0 (informativo) defaults que otorgan algo a anon (cualquier rol/esquema, incluido global)', true,
       COALESCE(string_agg(pg_get_userbyid(d.defaclrole) || '/' || COALESCE(n.nspname, '(global)') || '/' || d.defaclobjtype, '; '), 'ninguno')
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a JOIN pg_roles g ON g.oid = a.grantee WHERE g.rolname = 'anon';

-- ============================================================================
-- A) Diferencia de privilegios
-- ============================================================================
SELECT pg_temp.verifica('A1 100_ NO agrega ningún privilegio (todo lo de después estaba antes)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (d.rol, d.rel, d.priv, d.nivel)))$$);
SELECT pg_temp.verifica('A2 lo que se quita es SOLO: todo de anon, y TRUNCATE/REFERENCES/TRIGGER de authenticated y service_role',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes'
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel))
        AND NOT (a.rol = 'anon' OR a.priv IN ('TRUNCATE', 'REFERENCES', 'TRIGGER')))$$);
SELECT pg_temp.verifica('A3 authenticated y service_role CONSERVAN SELECT/INSERT/UPDATE/DELETE y de columna SELECT/INSERT/UPDATE exactamente igual',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.rol IN ('authenticated', 'service_role') AND a.priv IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'USAGE')
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel)))$$);
SELECT pg_temp.verifica('A4 después: anon sin ningún privilegio sobre ninguna relación de tiempo', $$SELECT NOT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rol = 'anon')$$);
SELECT pg_temp.verifica('A5 después: ni authenticated ni service_role tienen TRUNCATE, REFERENCES ni TRIGGER', $$SELECT NOT EXISTS (SELECT 1 FROM _foto WHERE fase = 'despues' AND rol IN ('authenticated', 'service_role') AND priv IN ('TRUNCATE', 'REFERENCES', 'TRIGGER'))$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'A6 (informativo) cuántos privilegios quitó 100_', true,
  'anon=' || count(*) FILTER (WHERE a.rol = 'anon') || ' authenticated=' || count(*) FILTER (WHERE a.rol = 'authenticated') || ' service_role=' || count(*) FILTER (WHERE a.rol = 'service_role')
FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel));

-- ============================================================================
-- B) anon (la anon key sin sesión) ya no toca nada de tiempo
-- ============================================================================
SELECT pg_temp.caso('B1 anon SELECT tiempo.marca', 'anon', $$SELECT 1 FROM tiempo.marca LIMIT 1$$, '42501');
SELECT pg_temp.caso('B2 anon INSERT tiempo.marca', 'anon', $$INSERT INTO tiempo.marca DEFAULT VALUES$$, '42501');
SELECT pg_temp.caso('B3 anon UPDATE tiempo.marca', 'anon', $$UPDATE tiempo.marca SET id = id$$, '42501');
SELECT pg_temp.caso('B4 anon DELETE tiempo.marca', 'anon', $$DELETE FROM tiempo.marca$$, '42501');
SELECT pg_temp.caso('B5 anon TRUNCATE tiempo.marca (no está sujeto a RLS)', 'anon', $$TRUNCATE tiempo.marca$$, '42501');
SELECT pg_temp.caso('B6 anon SELECT tiempo.parametro', 'anon', $$SELECT 1 FROM tiempo.parametro LIMIT 1$$, '42501');
SELECT pg_temp.caso('B7 anon SELECT tiempo.jornada_asignada', 'anon', $$SELECT 1 FROM tiempo.jornada_asignada LIMIT 1$$, '42501');
SELECT pg_temp.caso('B8 anon SELECT tiempo.banco_de_horas', 'anon', $$SELECT 1 FROM tiempo.banco_de_horas LIMIT 1$$, '42501');
SELECT pg_temp.caso('B9 anon SELECT tiempo.terminal', 'anon', $$SELECT 1 FROM tiempo.terminal LIMIT 1$$, '42501');
SELECT pg_temp.caso('B10 anon nextval de una secuencia de tiempo', 'anon', $$SELECT nextval('tiempo.terminal_id_seq')$$, '42501');
SELECT pg_temp.caso('B11 anon TRUNCATE tiempo.tope_legal', 'anon', $$TRUNCATE tiempo.tope_legal$$, '42501');

-- ============================================================================
-- C) authenticated y service_role siguen funcionando para lo que usa el backend
-- ============================================================================
SELECT pg_temp.caso('C1 authenticated SELECT tiempo.marca (RLS decide filas; sin sesión devuelve 0, sin error)', 'authenticated', $$SELECT 1 FROM tiempo.marca LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C2 authenticated TRUNCATE tiempo.marca denegado', 'authenticated', $$TRUNCATE tiempo.marca$$, '42501');
SELECT pg_temp.caso('C3 authenticated no puede crear un FK hacia tiempo.terminal (REFERENCES)', 'authenticated', $$CREATE TEMP TABLE _ref_ensayo (a bigint REFERENCES tiempo.terminal (id))$$, '42501');
SELECT pg_temp.caso('C4 service_role SELECT tiempo.parametro', 'service_role', $$SELECT 1 FROM tiempo.parametro LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C5 service_role SELECT tiempo.banco_de_horas', 'service_role', $$SELECT 1 FROM tiempo.banco_de_horas LIMIT 1$$, 'ok');
SELECT pg_temp.caso('C6 service_role TRUNCATE tiempo.terminal denegado', 'service_role', $$TRUNCATE tiempo.terminal$$, '42501');
SELECT pg_temp.caso('C7 service_role TRUNCATE tiempo.dia_festivo denegado', 'service_role', $$TRUNCATE tiempo.dia_festivo$$, '42501');
SELECT pg_temp.caso('C8 service_role sigue ejecutando la RPC de latido (privilegio de función intacto; terminal -1 => SCJ12, no 42501)', 'service_role', $$SELECT tiempo.fn_terminal_latido(-1, now(), true, true, 'x', 0, NULL)$$, 'SCJ12');

-- ============================================================================
-- D) Privilegios por defecto: una tabla nueva ya no nace con GRANT ALL
-- ============================================================================
CREATE TABLE tiempo._ensayo_100 (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, x integer);
CREATE SEQUENCE tiempo._ensayo_100_seq;
SELECT pg_temp.verifica('D1 tabla nueva: anon sin ningún privilegio',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p WHERE has_table_privilege('anon', 'tiempo._ensayo_100', p))$$);
SELECT pg_temp.verifica('D2 tabla nueva: authenticated y service_role sí tienen SELECT, INSERT, UPDATE y DELETE',
  $$SELECT bool_and(has_table_privilege(r, 'tiempo._ensayo_100', p)) FROM unnest(ARRAY['authenticated','service_role']) r CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) p$$);
SELECT pg_temp.verifica('D3 tabla nueva: authenticated y service_role NO tienen TRUNCATE, REFERENCES ni TRIGGER',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['authenticated','service_role']) r CROSS JOIN unnest(ARRAY['TRUNCATE','REFERENCES','TRIGGER']) p WHERE has_table_privilege(r, 'tiempo._ensayo_100', p))$$);
SELECT pg_temp.verifica('D4 secuencia nueva: anon sin privilegios; authenticated y service_role con USAGE',
  $$SELECT NOT has_sequence_privilege('anon', 'tiempo._ensayo_100_seq', 'USAGE') AND has_sequence_privilege('authenticated', 'tiempo._ensayo_100_seq', 'USAGE') AND has_sequence_privilege('service_role', 'tiempo._ensayo_100_seq', 'USAGE')$$);
DROP SEQUENCE tiempo._ensayo_100_seq;
DROP TABLE tiempo._ensayo_100;

-- ============================================================================
-- E) Reversa exacta e idempotencia
-- ============================================================================
SELECT pg_temp.foto('tras_100');   -- (idéntica a 'despues'; sirve de base de la comparación de idempotencia)
DO $$
DECLARE s record;
BEGIN
  FOR s IN SELECT sentencia FROM _reversa ORDER BY n LOOP EXECUTE s.sentencia; END LOOP;
  ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo GRANT ALL ON TABLES TO anon, authenticated, service_role;
  ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
END
$$;
SELECT pg_temp.foto('reversa');
SELECT pg_temp.verifica('E1 la reversa documentada deja los privilegios IDÉNTICOS a la foto previa (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);
SELECT pg_temp.verifica('E2 tras la reversa los privilegios por defecto vuelven a ser GRANT ALL para anon (estado de 38_)',
  $$SELECT EXISTS (SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a JOIN pg_roles g ON g.oid = a.grantee
                   WHERE n.nspname = 'tiempo' AND d.defaclobjtype = 'r' AND g.rolname = 'anon')$$);

\ir ../ddl/100_tiempo_revoca_anon_y_privilegios_de_estructura.sql
SELECT pg_temp.foto('reaplicada');
SELECT pg_temp.verifica('E3 100_ es idempotente: reaplicarla tras la reversa deja la misma foto que la primera vez (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_100' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_100' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);
\ir ../ddl/100_tiempo_revoca_anon_y_privilegios_de_estructura.sql
SELECT pg_temp.verifica('E4 aplicarla una vez más no falla ni cambia los privilegios por defecto',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace CROSS JOIN LATERAL aclexplode(d.defaclacl) a JOIN pg_roles g ON g.oid = a.grantee
                       WHERE n.nspname = 'tiempo' AND d.defaclobjtype IN ('r', 'S') AND g.rolname = 'anon')$$);

-- ============================================================================
-- F) verificar_ddl.sql completo con 100_ aplicada: sección 63 en 0 filas, y ninguna sección nueva con filas
-- ============================================================================
\ir ../verificar_ddl.sql

\echo '=== pg_default_acl COMPLETO al final (tras reaplicar 100_) ==='
SELECT pg_get_userbyid(d.defaclrole) AS rol, COALESCE(n.nspname, '(global)') AS esquema, d.defaclobjtype AS tipo, d.defaclacl::text AS aclitems
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace ORDER BY 1, 2, 3;
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
