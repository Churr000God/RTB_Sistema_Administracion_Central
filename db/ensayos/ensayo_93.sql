-- Ensayo de 93_tiempo_retira_terminal_checador.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo
-- corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_93.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 93_ ENCIMA de lo ya aplicado (37_ y el resto). Los INSERT en tiempo.marca son de prueba y se revierten
-- (la secuencia identity avanza igual). Persona: una existente de tiempo.persona (sólo como FK); el admin real sólo es caller de la captura manual.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens SELECT 'persona', id::text FROM tiempo.persona LIMIT 1;
INSERT INTO _ens
SELECT 'auth_uid', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;

-- p_sub: NULL = el admin real; '-' = claims SIN sub.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_claims json;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  IF p_sub = '-' THEN v_claims := json_build_object('role', p_rol);
  ELSE v_claims := json_build_object('sub', COALESCE(p_sub, (SELECT x.v FROM _ens x WHERE x.k='auth_uid')), 'role', p_rol);
  END IF;
  PERFORM set_config('request.jwt.claims', v_claims::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso,
    CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok' ELSE v_estado = p_esperado END,
    'obtenido=' || v_estado || ' ' || left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), p_sql);
END;
$$ LANGUAGE plpgsql;

-- INSERT de prueba en tiempo.marca (origen terminal o captura_manual). Cada llamada usa un evento_id/secuencia distintos.
CREATE FUNCTION pg_temp.ins(p_origen text, p_seq bigint) RETURNS text AS $$
SELECT format($f$INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (%L::uuid, 'ENS93', %s, now() - interval '1 hour', '-06:00', 'sincronizado', 'ens', %L)$f$,
  (SELECT v FROM _ens WHERE k = 'persona'), COALESCE(p_seq::text, 'NULL'), p_origen);
$$ LANGUAGE sql;

-- ================= ANTES de 93_ (estado que se retira) =================
SELECT pg_temp.verifica('01 antes: el rol existe, es NOLOGIN y es miembro de authenticator',
  $$SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='terminal_checador' AND NOT rolcanlogin)
      AND EXISTS (SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
                  WHERE r.rolname='terminal_checador' AND m.rolname='authenticator')$$);
SELECT pg_temp.verifica('02 antes: existe la policy terminal_inserta_su_origen',
  $$SELECT count(*) = 1 FROM pg_policies WHERE schemaname='tiempo' AND tablename='marca' AND policyname='terminal_inserta_su_origen'$$);
SELECT pg_temp.caso('03 antes: terminal_checador SÍ inserta una marca origen=terminal', 'terminal_checador', pg_temp.ins('terminal', 930001), 'ok', '-');
SELECT pg_temp.caso('04 antes: terminal_checador NO inserta captura_manual (la policy fuerza origen)', 'terminal_checador', pg_temp.ins('captura_manual', NULL), 'error', '-');

-- Camino de PostgREST: authenticator hace SET ROLE al rol del claim. Antes de 93_ puede; después no.
SELECT pg_temp.caso('05 antes: authenticator SÍ puede hacer SET ROLE terminal_checador (así entra un JWT con ese claim)', 'authenticator', 'SET LOCAL ROLE terminal_checador', 'ok', '-');

-- ================= APLICA 93_ =================
\ir ../ddl/93_tiempo_retira_terminal_checador.sql

-- ================= DESPUÉS =================
SELECT pg_temp.caso('09 después: authenticator ya NO puede hacer SET ROLE terminal_checador (un JWT con ese claim falla)', 'authenticator', 'SET LOCAL ROLE terminal_checador', 'error', '-');
-- Sólo para el ensayo: postgres llegaba a ese rol por la cadena postgres -> authenticator -> terminal_checador, que 93_ corta a propósito. Para poder
-- seguir probando los privilegios RESIDUALES del rol se le da a postgres (tiene ADMIN OPTION) SET directo dentro de esta transacción; se revierte con el ROLLBACK.
GRANT terminal_checador TO postgres WITH SET TRUE, INHERIT FALSE;
SELECT pg_temp.caso('10 después: terminal_checador ya NO inserta origen=terminal (42501)', 'terminal_checador', pg_temp.ins('terminal', 930002), '42501', '-');
SELECT pg_temp.caso('11 después: terminal_checador no inserta captura_manual', 'terminal_checador', pg_temp.ins('captura_manual', NULL), 'error', '-');
SELECT pg_temp.caso('12 después: terminal_checador no lee tiempo.marca', 'terminal_checador', 'SELECT count(*) FROM tiempo.marca', 'error', '-');
SELECT pg_temp.verifica('13 después: sin INSERT ni SELECT en tiempo.marca ni USAGE en el esquema',
  $$SELECT NOT has_table_privilege('terminal_checador','tiempo.marca','INSERT') AND NOT has_table_privilege('terminal_checador','tiempo.marca','SELECT')
      AND NOT has_schema_privilege('terminal_checador','tiempo','USAGE')$$);
SELECT pg_temp.verifica('14 después: la policy terminal_inserta_su_origen ya no existe',
  $$SELECT count(*) = 0 FROM pg_policies WHERE policyname = 'terminal_inserta_su_origen'$$);
SELECT pg_temp.verifica('15 después: authenticator ya no es miembro del rol (PostgREST no puede SET ROLE)',
  $$SELECT count(*) = 0 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.roleid JOIN pg_roles m ON m.oid=am.member
    WHERE r.rolname='terminal_checador' AND m.rolname='authenticator'$$);
SELECT pg_temp.verifica('16 después: el rol sigue existiendo y es NOLOGIN (los verificadores siguen corriendo)',
  $$SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='terminal_checador' AND NOT rolcanlogin)$$);
SELECT pg_temp.verifica('17 después: RLS de tiempo.marca sigue habilitada y las 2 policies humanas intactas',
  $$SELECT (SELECT relrowsecurity FROM pg_class WHERE oid='tiempo.marca'::regclass)
      AND (SELECT count(*) FROM pg_policies WHERE schemaname='tiempo' AND tablename='marca') = 2
      AND EXISTS (SELECT 1 FROM pg_policies WHERE tablename='marca' AND policyname='marca_insert_captura_manual')
      AND EXISTS (SELECT 1 FROM pg_policies WHERE tablename='marca' AND policyname='marca_select_requiere_permiso')$$);

-- Camino legítimo de la terminal: el RPC inserta como dueño (SECURITY DEFINER), que no depende de la policy borrada.
SELECT pg_temp.verifica('20 el RPC de marcas sigue siendo SECURITY DEFINER con dueño BYPASSRLS y sin FORCE ROW LEVEL SECURITY, EXECUTE sólo service_role',
  $$SELECT p.prosecdef AND r.rolbypassrls AND NOT (SELECT relforcerowsecurity FROM pg_class WHERE oid='tiempo.marca'::regclass)
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
    WHERE p.oid = 'tiempo.fn_marca_terminal_registrar(bigint, jsonb)'::regprocedure$$);
SELECT pg_temp.caso('21 el dueño (la vía del RPC DEFINER) sigue insertando origen=terminal', 'postgres', pg_temp.ins('terminal', 930003), 'ok', '-');
SELECT pg_temp.caso('22 el humano con captura_manual_edicion sigue insertando captura_manual', 'authenticated', pg_temp.ins('captura_manual', NULL), 'ok');
SELECT pg_temp.caso('23 authenticated NO inserta origen=terminal (ya no hay policy que lo permita)', 'authenticated', pg_temp.ins('terminal', 930004), 'error');
SELECT pg_temp.caso('24 anon NO inserta marcas', 'anon', pg_temp.ins('terminal', 930005), 'error', '-');

\ir verificar_93.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
