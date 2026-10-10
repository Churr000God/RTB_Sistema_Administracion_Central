-- Ensayo de 99_tiempo_terminal_ingesta_detenida.sql (campo opcional del latido). NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_99.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 99_ ENCIMA de lo ya aplicado (88_-98_). Terminal SINTÉTICA; no toca terminales reales ni escribe fuera de la transacción (las secuencias identity avanzan igual).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

-- Estado de la función vigente ANTES de aplicar (para el caso de las propiedades heredadas).
INSERT INTO _ens
SELECT 'antes_secdef', p.prosecdef::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_latido';
INSERT INTO _ens
SELECT 'antes_cfg', array_to_string(p.proconfig, ',') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_latido';
INSERT INTO _ens SELECT 'antes_nfuncs', count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_latido';

\ir ../ddl/99_tiempo_terminal_ingesta_detenida.sql

INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-99', 'Terminal de ensayo 99', 'DS-K1A8503EF-B');
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo, activa) VALUES ('ENSAYO-99I', 'Terminal inactiva de ensayo 99', 'DS-K1A8503EF-B', false);
INSERT INTO _ens SELECT 'tid', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-99';
INSERT INTO _ens SELECT 'tid_inactiva', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-99I';

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), p_sql);
END;
$$ LANGUAGE plpgsql;

-- Ejecuta p_sql como p_rol; p_esperado = 'ok' | SQLSTATE | 'error'. p_hint opcional.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (
    p_caso,
    (CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok' ELSE v_estado = p_esperado END) AND (p_hint IS NULL OR v_hint IS NOT DISTINCT FROM p_hint),
    'obtenido=' || v_estado || ' hint=' || COALESCE(v_hint, '-') || ' ' || left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;

-- Llama el latido como service_role (por NOMBRE, como el backend); p_args = lista de argumentos con nombre; guarda el jsonb en _ens[p_clave].
CREATE FUNCTION pg_temp.latido(p_args text, p_clave text DEFAULT 'ult') RETURNS void AS $$
DECLARE v jsonb;
BEGIN
  SET LOCAL ROLE service_role;
  EXECUTE 'SELECT tiempo.fn_terminal_latido(' || p_args || ')' INTO v;
  RESET ROLE;
  DELETE FROM _ens WHERE k = p_clave;
  INSERT INTO _ens VALUES (p_clave, v::text);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- A) Estructura y atributos
-- ============================================================================
SELECT pg_temp.verifica('A1 la columna existe: boolean, NULL permitido, sin default',
  $$SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='tiempo' AND table_name='terminal' AND column_name='ingesta_detenida'
                   AND data_type='boolean' AND is_nullable='YES' AND column_default IS NULL)$$);
SELECT pg_temp.verifica('A2 la columna tiene comentario', $$SELECT col_description('tiempo.terminal'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid='tiempo.terminal'::regclass AND attname='ingesta_detenida')) IS NOT NULL$$);
SELECT pg_temp.verifica('A3 antes de 99_ había UNA sola fn_terminal_latido (la de 83_)', $$SELECT (SELECT v FROM _ens WHERE k='antes_nfuncs') = '1'$$);
SELECT pg_temp.verifica('A4 la firma VIEJA de 6 argumentos ya no existe', $$SELECT to_regprocedure('tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer)') IS NULL$$);
SELECT pg_temp.verifica('A5 existe la firma NUEVA de 7 argumentos y es la única', $$SELECT to_regprocedure('tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer, boolean)') IS NOT NULL
  AND (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='tiempo' AND p.proname='fn_terminal_latido') = 1$$);
SELECT pg_temp.verifica('A6 SECURITY DEFINER y search_path exacto (iguales que la versión vigente antes de 99_)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND (SELECT v FROM _ens WHERE k='antes_secdef') = 'true' AND (SELECT v FROM _ens WHERE k='antes_cfg') = 'search_path=tiempo, personas, pg_temp'
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='tiempo' AND p.proname='fn_terminal_latido'$$);
SELECT pg_temp.verifica('A7 EXECUTE solo service_role (ni PUBLIC, ni anon, ni authenticated)',
  $$SELECT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='tiempo' AND p.proname='fn_terminal_latido'$$);
SELECT pg_temp.verifica('A8 el cuerpo ya no interpola el id de la terminal en el mensaje de SCJ12',
  $$SELECT p.prosrc NOT LIKE '%no está activa'', p_terminal_id%' AND p.prosrc LIKE '%ingesta_detenida%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='tiempo' AND p.proname='fn_terminal_latido'$$);

-- ============================================================================
-- B) Comportamiento: compatibilidad hacia atrás y valores
-- ============================================================================
SELECT pg_temp.latido('p_terminal_id => (SELECT v::bigint FROM _ens WHERE k=''tid''), p_hora_terminal => now(), p_alcanzable => true, p_reloj_sincronizado => true, p_version_pi => ''1.0'', p_marcas_pendientes => 3', 'r_b1');
SELECT pg_temp.verifica('B1 llamada de 6 argumentos por NOMBRE (como el backend actual): no es ambigua y devuelve las 3 claves',
  $$SELECT (v::jsonb ? 'hora_servidor') AND (v::jsonb ? 'desfase_reloj_seg') AND (v::jsonb ? 'ultima_secuencia_recibida') FROM _ens WHERE k='r_b1'$$);
SELECT pg_temp.verifica('B1b ... y la columna nueva queda NULL, las demás se guardan (version_pi 1.0, marcas_pendientes 3, alcanzable true, contacto no NULL)',
  $$SELECT ingesta_detenida IS NULL AND version_pi='1.0' AND marcas_pendientes=3 AND terminal_alcanzable AND ultimo_contacto_en IS NOT NULL FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);

SELECT pg_temp.latido('p_terminal_id => (SELECT v::bigint FROM _ens WHERE k=''tid''), p_hora_terminal => now(), p_alcanzable => true, p_reloj_sincronizado => true, p_version_pi => ''1.1'', p_marcas_pendientes => 0, p_ingesta_detenida => true');
SELECT pg_temp.verifica('B2 p_ingesta_detenida = true se guarda', $$SELECT ingesta_detenida IS TRUE AND version_pi='1.1' FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);
SELECT pg_temp.latido('p_terminal_id => (SELECT v::bigint FROM _ens WHERE k=''tid''), p_hora_terminal => now(), p_alcanzable => true, p_reloj_sincronizado => true, p_version_pi => ''1.1'', p_marcas_pendientes => 0, p_ingesta_detenida => false');
SELECT pg_temp.verifica('B3 p_ingesta_detenida = false se guarda', $$SELECT ingesta_detenida IS FALSE FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);
SELECT pg_temp.latido('p_terminal_id => (SELECT v::bigint FROM _ens WHERE k=''tid''), p_hora_terminal => now(), p_alcanzable => true, p_reloj_sincronizado => true, p_version_pi => ''1.1'', p_marcas_pendientes => 0, p_ingesta_detenida => true');
SELECT pg_temp.latido('p_terminal_id => (SELECT v::bigint FROM _ens WHERE k=''tid''), p_hora_terminal => now(), p_alcanzable => true, p_reloj_sincronizado => true, p_version_pi => ''1.1'', p_marcas_pendientes => 0');
SELECT pg_temp.verifica('B4 un latido SIN el argumento sobrescribe con NULL (la columna describe el último latido; un puente que deja de reportar no deja una alarma pegada)',
  $$SELECT ingesta_detenida IS NULL FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);
SELECT pg_temp.latido('(SELECT v::bigint FROM _ens WHERE k=''tid''), now(), true, true, ''1.2'', 1, true');
SELECT pg_temp.verifica('B5 llamada POSICIONAL de 7 argumentos', $$SELECT ingesta_detenida IS TRUE AND version_pi='1.2' FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);
SELECT pg_temp.latido('(SELECT v::bigint FROM _ens WHERE k=''tid''), now(), true, true, ''1.2'', 1, NULL');
SELECT pg_temp.verifica('B6 p_ingesta_detenida = NULL explícito también deja NULL', $$SELECT ingesta_detenida IS NULL FROM tiempo.terminal WHERE terminal_id='ENSAYO-99'$$);
SELECT pg_temp.verifica('B7 la otra terminal sintética no se tocó (ultimo_contacto_en NULL)', $$SELECT ultimo_contacto_en IS NULL AND ingesta_detenida IS NULL FROM tiempo.terminal WHERE terminal_id='ENSAYO-99I'$$);

-- ============================================================================
-- C) Rechazos
-- ============================================================================
SELECT pg_temp.caso('C1 terminal inexistente: SCJ12 con HINT terminal_no_valida', 'service_role',
  $$SELECT tiempo.fn_terminal_latido(987654321, now(), true, true, 'x', 0, true)$$, 'SCJ12', 'terminal_no_valida');
SELECT pg_temp.caso('C2 terminal inactiva: SCJ12 con HINT terminal_no_valida', 'service_role',
  $$SELECT tiempo.fn_terminal_latido((SELECT v::bigint FROM _ens WHERE k='tid_inactiva'), now(), true, true, 'x', 0, true)$$, 'SCJ12', 'terminal_no_valida');
-- El mensaje ya no lleva el id de la terminal.
CREATE FUNCTION pg_temp.msg_sin_id() RETURNS void AS $$
DECLARE v_msg text := '';
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM tiempo.fn_terminal_latido(987654321, now(), true, true, 'x', 0, true);
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
  END;
  RESET ROLE;
  INSERT INTO _res (caso, ok, detalle) VALUES ('C3 el mensaje de SCJ12 no contiene el id recibido', v_msg <> '' AND v_msg NOT LIKE '%987654321%', left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;
SELECT pg_temp.msg_sin_id();
SELECT pg_temp.verifica('C4 un rechazo no dejó la columna cambiada en la terminal inactiva', $$SELECT ingesta_detenida IS NULL FROM tiempo.terminal WHERE terminal_id='ENSAYO-99I'$$);

-- ============================================================================
-- D) Privilegios: solo la función escribe la columna
-- ============================================================================
SELECT pg_temp.caso('D1 anon no ejecuta la función', 'anon', $$SELECT tiempo.fn_terminal_latido(1, now(), true, true, 'x', 0, true)$$, '42501');
SELECT pg_temp.caso('D2 authenticated no ejecuta la función', 'authenticated', $$SELECT tiempo.fn_terminal_latido(1, now(), true, true, 'x', 0, true)$$, '42501');
SELECT pg_temp.caso('D3 service_role NO puede UPDATE directo de la columna', 'service_role', $$UPDATE tiempo.terminal SET ingesta_detenida = true WHERE terminal_id = 'ENSAYO-99'$$, '42501');
SELECT pg_temp.caso('D4 authenticated NO puede UPDATE de la columna', 'authenticated', $$UPDATE tiempo.terminal SET ingesta_detenida = true WHERE terminal_id = 'ENSAYO-99'$$, 'error');
SELECT pg_temp.caso('D5 anon NO lee la columna', 'anon', $$SELECT ingesta_detenida FROM tiempo.terminal$$, '42501');
SELECT pg_temp.caso('D6 anon NO puede UPDATE de la columna', 'anon', $$UPDATE tiempo.terminal SET ingesta_detenida = true$$, '42501');
SELECT pg_temp.caso('D7 service_role SÍ lee la columna (el backend arma el tablero con ella)', 'service_role', $$SELECT ingesta_detenida FROM tiempo.terminal$$, 'ok');
SELECT pg_temp.verifica('D8 los privilegios de columna de las 4 columnas anteriores de telemetría siguen sin UPDATE para service_role/authenticated',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['reloj_desfase_seg','terminal_alcanzable','version_pi','marcas_pendientes','ingesta_detenida']) c
      WHERE has_column_privilege('service_role','tiempo.terminal',c,'UPDATE') OR has_column_privilege('authenticated','tiempo.terminal',c,'UPDATE'))$$);
SELECT pg_temp.verifica('D9 los privilegios de tabla de service_role sobre tiempo.terminal no cambiaron respecto a 80_: SELECT, INSERT y UPDATE solo de las 4 columnas de 80_',
  $$SELECT has_table_privilege('service_role','tiempo.terminal','SELECT') AND has_table_privilege('service_role','tiempo.terminal','INSERT') AND NOT has_table_privilege('service_role','tiempo.terminal','DELETE')
     AND NOT has_table_privilege('service_role','tiempo.terminal','TRUNCATE') AND NOT has_table_privilege('service_role','tiempo.terminal','UPDATE')
     AND has_column_privilege('service_role','tiempo.terminal','ultimo_contacto_en','UPDATE') AND has_column_privilege('service_role','tiempo.terminal','activa','UPDATE')$$);
SELECT pg_temp.verifica('D10 RLS de tiempo.terminal sigue activa y con su policy de lectura', $$SELECT c.relrowsecurity AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='tiempo' AND tablename='terminal' AND policyname='terminal_select_lectura') FROM pg_class c WHERE c.oid='tiempo.terminal'::regclass$$);

-- ============================================================================
-- E) verificar_ddl.sql completo con 99_ aplicado: sección 62 en 0 filas (y ninguna sección nueva con filas)
-- ============================================================================
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
