-- Ensayo de 107_personas_fn_persona_crear.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_107.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 107_. Personas, expedientes y un usuario sintético creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el ROLLBACK descarta).
-- El administrador real solo es caller. Cada rechazo se ejecuta como authenticated con claims y se comprueba SQLSTATE y que NO quede persona ni expediente.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_admin', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- Ejecuta p_sql como p_rol con claims de p_sub (NULL = admin real); p_esperado = 'ok' | SQLSTATE; p_msg opcional: el mensaje debe contener ese texto.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL, p_msg text DEFAULT NULL) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', COALESCE(p_sub, (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin')), 'role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado AND (p_msg IS NULL OR position(p_msg IN v_msg) > 0), 'obtenido=' || v_estado || ' ' || left(v_msg, 120));
END;
$$ LANGUAGE plpgsql;

-- Llamada al RPC por nombre de argumento (como PostgREST). p_curp etc. parametrizables.
CREATE FUNCTION pg_temp.crear(p_curp text, p_rfc text, p_nss text, p_tipo text DEFAULT 'indefinido', p_doc text DEFAULT 'RTB-RH-EIT-2026-901', p_nombre text DEFAULT 'Sintetica107') RETURNS text AS $$
  SELECT format($f$SELECT personas.fn_persona_crear(p_primer_nombre => %L, p_apellido_paterno => 'Ensayo107', p_curp => %L, p_rfc => %L, p_nss => %L,
                                                    p_fecha_nacimiento => DATE '2000-01-01', p_fecha_ingreso => CURRENT_DATE, p_tipo_contrato => %L, p_documento_ref => %L)$f$,
                p_nombre, p_curp, p_rfc, p_nss, p_tipo, p_doc);
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.n_personas() RETURNS bigint AS $$ SELECT count(*) FROM personas.persona; $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.n_expedientes() RETURNS bigint AS $$ SELECT count(*) FROM personas.expediente; $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.n_tiempo_persona() RETURNS bigint AS $$ SELECT count(*) FROM tiempo.persona; $$ LANGUAGE sql;

INSERT INTO _ens VALUES ('n_p0', pg_temp.n_personas()::text), ('n_e0', pg_temp.n_expedientes()::text), ('n_t0', pg_temp.n_tiempo_persona()::text);

-- usuario sintético sin permisos (persona activa, sin asignación)
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXY90', 'XEXY01010190', '99999940090', 'SinPermisos', 'Ensayo107', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'P_sin', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXY90';
INSERT INTO _ens VALUES ('auth_sin', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_sin'), 'authenticated', 'authenticated', 'ens107sin@invalid.test');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_sin'), (SELECT v::uuid FROM _ens WHERE k = 'P_sin'), 'ens107sin');
-- (la persona sintética sin permisos cuenta en la línea base de los conteos)
UPDATE _ens SET v = (v::bigint + 1)::text WHERE k = 'n_p0';
UPDATE _ens SET v = (v::bigint + 1)::text WHERE k = 'n_t0';

\ir ../ddl/107_personas_fn_persona_crear.sql

-- ============================================================================
-- A) Atributos
-- ============================================================================
SELECT pg_temp.verifica('A1 SECURITY INVOKER, search_path = personas, pg_temp, dueño postgres, LANGUAGE plpgsql, devuelve personas.persona',
  $$SELECT NOT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND l.lanname = 'plpgsql' AND pg_get_function_result(p.oid) = 'personas.persona'
    FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_crear'$$);
SELECT pg_temp.verifica('A2 EXECUTE solo para authenticated (ni PUBLIC, ni anon, ni service_role)',
  $$SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_crear'$$);
SELECT pg_temp.verifica('A3 firma exacta: 11 argumentos, los 2 últimos con DEFAULT NULL',
  $$SELECT pronargs = 11 AND pronargdefaults = 2 AND pg_get_function_identity_arguments(oid) LIKE 'p_primer_nombre character varying, p_apellido_paterno character varying, p_curp character varying, p_rfc character varying, p_nss character varying, p_fecha_nacimiento date, p_fecha_ingreso date, p_tipo_contrato character varying, p_documento_ref character varying, p_segundo_nombre character varying, p_apellido_materno character varying'
    FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_crear'$$);

-- ============================================================================
-- B) Caso feliz (admin con alta_personas_usuarios)
-- ============================================================================
SELECT pg_temp.caso('B1 alta correcta como authenticated (admin)', 'authenticated', pg_temp.crear('xexx010101hnexxy91', ' xexy01010191 ', '99999940091', 'indefinido', 'RTB-RH-EIT-2026-901'), 'ok');
SELECT pg_temp.verifica('B2 quedó UNA persona y UN expediente más, con curp/rfc en MAYÚSCULAS y sin espacios, estado activo y expediente ligado',
  $$SELECT pg_temp.n_personas() = (SELECT v::bigint FROM _ens WHERE k = 'n_p0') + 1 AND pg_temp.n_expedientes() = (SELECT v::bigint FROM _ens WHERE k = 'n_e0') + 1
     AND EXISTS (SELECT 1 FROM personas.persona p JOIN personas.expediente e ON e.persona_id = p.id
                 WHERE p.curp = 'XEXX010101HNEXXY91' AND p.rfc = 'XEXY01010191' AND p.estado = 'activo' AND e.tipo_contrato = 'indefinido' AND e.documento_ref = 'RTB-RH-EIT-2026-901')$$);
SELECT pg_temp.verifica('B3 el trigger de la frontera creó el stub tiempo.persona', $$SELECT pg_temp.n_tiempo_persona() = (SELECT v::bigint FROM _ens WHERE k = 'n_t0') + 1$$);
-- el RPC devuelve la fila completa (con id): se comprueba como dueño
DO $$
DECLARE v personas.persona;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin'), 'role', 'authenticated')::text, true);
  SELECT * INTO v FROM personas.fn_persona_crear(p_primer_nombre => 'Sintetica107b', p_apellido_paterno => 'Ensayo107', p_curp => 'XEXX010101HNEXXY92', p_rfc => 'XEXY01010192', p_nss => '99999940092',
        p_fecha_nacimiento => DATE '2000-01-01', p_fecha_ingreso => CURRENT_DATE, p_tipo_contrato => 'por_proyecto', p_documento_ref => 'RTB-RH-EIT-2026-902',
        p_segundo_nombre => 'Segundo', p_apellido_materno => 'Materno');
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES ('B4 el RPC devuelve la fila completa (id, nombres, curp, estado) y los opcionales se guardan',
    v.id IS NOT NULL AND v.curp = 'XEXX010101HNEXXY92' AND v.estado = 'activo' AND v.segundo_nombre = 'Segundo' AND v.apellido_materno = 'Materno' AND v.primer_nombre = 'Sintetica107b',
    'id=' || COALESCE(v.id::text, 'NULL'));
END $$;

-- ============================================================================
-- C) Atomicidad: cada rechazo => SQLSTATE nativo y NADA persiste (ni persona ni expediente)
-- ============================================================================
INSERT INTO _ens VALUES ('n_p1', pg_temp.n_personas()::text), ('n_e1', pg_temp.n_expedientes()::text), ('n_t1', pg_temp.n_tiempo_persona()::text);
SELECT pg_temp.caso('C1 documento_ref mal formado => 23514 (ck_expediente_documento_ref_formato) con la persona ya insertada por el primer INSERT', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY93', 'XEXY01010193', '99999940093', 'indefinido', 'RTB-XX-123'), '23514', NULL, 'ck_expediente_documento_ref_formato');
SELECT pg_temp.verifica('C1b ... y NO quedó la persona (CURP XEXX010101HNEXXY93 libre) ni expediente ni stub de tiempo',
  $$SELECT NOT EXISTS (SELECT 1 FROM personas.persona WHERE curp = 'XEXX010101HNEXXY93') AND pg_temp.n_personas() = (SELECT v::bigint FROM _ens WHERE k = 'n_p1')
     AND pg_temp.n_expedientes() = (SELECT v::bigint FROM _ens WHERE k = 'n_e1') AND pg_temp.n_tiempo_persona() = (SELECT v::bigint FROM _ens WHERE k = 'n_t1')$$);
SELECT pg_temp.caso('C1c ... y reintentar con la MISMA CURP y el folio corregido funciona (no queda CURP consumida)', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY93', 'XEXY01010193', '99999940093', 'indefinido', 'RTB-RH-EIT-2026-903'), 'ok');
INSERT INTO _ens VALUES ('n_p2', pg_temp.n_personas()::text), ('n_e2', pg_temp.n_expedientes()::text);
SELECT pg_temp.caso('C2 tipo_contrato fuera del dominio => 23514', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY94', 'XEXY01010194', '99999940094', 'tiempo_completo', 'RTB-RH-EIT-2026-904'), '23514', NULL, 'ck_expediente_tipo_contrato');
SELECT pg_temp.caso('C3 CURP duplicada => 23505 (uq_persona_curp)', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY91', 'XEXY01010195', '99999940095', 'indefinido', 'RTB-RH-EIT-2026-905'), '23505', NULL, 'uq_persona_curp');
SELECT pg_temp.caso('C4 RFC duplicado => 23505 (uq_persona_rfc)', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY96', 'XEXY01010191', '99999940096', 'indefinido', 'RTB-RH-EIT-2026-906'), '23505', NULL, 'uq_persona_rfc');
SELECT pg_temp.caso('C5 NSS duplicado => 23505 (uq_persona_nss)', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY97', 'XEXY01010197', '99999940091', 'indefinido', 'RTB-RH-EIT-2026-907'), '23505', NULL, 'uq_persona_nss');
SELECT pg_temp.caso('C6 documento_ref duplicado (persona nueva, expediente que choca) => 23505 (uq_expediente_documento_ref) y la persona NO queda', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY98', 'XEXY01010198', '99999940098', 'indefinido', 'RTB-RH-EIT-2026-901'), '23505', NULL, 'uq_expediente_documento_ref');
SELECT pg_temp.verifica('C7 tras C2–C6: mismos conteos que antes (ninguna persona ni expediente nuevo) y ninguna de las CURP rechazadas existe',
  $$SELECT pg_temp.n_personas() = (SELECT v::bigint FROM _ens WHERE k = 'n_p2') AND pg_temp.n_expedientes() = (SELECT v::bigint FROM _ens WHERE k = 'n_e2')
     AND NOT EXISTS (SELECT 1 FROM personas.persona WHERE curp IN ('XEXX010101HNEXXY94', 'XEXX010101HNEXXY96', 'XEXX010101HNEXXY97', 'XEXX010101HNEXXY98'))$$);
SELECT pg_temp.verifica('C8 toda persona de las altas del ensayo tiene expediente (sin huérfanas)',
  $$SELECT NOT EXISTS (SELECT 1 FROM personas.persona p WHERE p.curp IN ('XEXX010101HNEXXY91', 'XEXX010101HNEXXY92', 'XEXX010101HNEXXY93') AND NOT EXISTS (SELECT 1 FROM personas.expediente e WHERE e.persona_id = p.id))$$);

-- ============================================================================
-- D) Autorización y privilegios
-- ============================================================================
SELECT pg_temp.caso('D1 usuario activo SIN alta_personas_usuarios => 42501 (RLS de INSERT)', 'authenticated',
  pg_temp.crear('XEXX010101HNEXXY99', 'XEXY01010199', '99999940099', 'indefinido', 'RTB-RH-EIT-2026-908'), '42501', (SELECT v FROM _ens WHERE k = 'auth_sin'));
SELECT pg_temp.verifica('D1b ... y no quedó nada', $$SELECT NOT EXISTS (SELECT 1 FROM personas.persona WHERE curp = 'XEXX010101HNEXXY99') AND pg_temp.n_expedientes() = (SELECT v::bigint FROM _ens WHERE k = 'n_e2')$$);
SELECT pg_temp.caso('D2 anon => 42501 (sin EXECUTE)', 'anon', pg_temp.crear('XEXX010101HNEXXY99', 'XEXY01010199', '99999940099'), '42501');
SELECT pg_temp.caso('D3 service_role => 42501 (sin EXECUTE; el router usa el cliente del caller)', 'service_role', pg_temp.crear('XEXX010101HNEXXY99', 'XEXY01010199', '99999940099'), '42501');
SELECT pg_temp.caso('D4 los argumentos obligatorios no tienen DEFAULT: llamada sin p_curp => 42883 (PostgREST lo reporta como PGRST202)', 'authenticated',
  $$SELECT personas.fn_persona_crear(p_primer_nombre => 'x', p_apellido_paterno => 'y')$$, '42883');

-- ============================================================================
-- E) Reversa y verificador
-- ============================================================================
DROP FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar);
SELECT pg_temp.verifica('E1 la reversa (DROP FUNCTION) deja la base sin la función y sin dependientes (policies/triggers intactos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_crear')$$);
\ir ../ddl/107_personas_fn_persona_crear.sql
SELECT pg_temp.verifica('E2 107_ es reaplicable tras la reversa', $$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_crear')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
