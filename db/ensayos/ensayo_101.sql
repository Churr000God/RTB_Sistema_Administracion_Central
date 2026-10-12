-- Ensayo de 101_tiempo_terminal_bitacora_aplica_sin_identidad_en_errores.sql. NO es DDL versionado. NO correr sin OK explícito del usuario ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_101.sql     (SIN -1; puerto 5432)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 101_ (sobre 88_-100_). Terminales sintéticas; no toca altas ni personas reales (el trigger es BEFORE INSERT y levanta antes de cualquier efecto).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _ant (k text PRIMARY KEY, v text);
INSERT INTO _ant SELECT 'cfg', array_to_string(p.proconfig, ',') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica';
INSERT INTO _ant SELECT 'secdef', p.prosecdef::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica';
INSERT INTO _ant SELECT 'acl', COALESCE(p.proacl::text, 'NULL') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica';
INSERT INTO _ant SELECT 'trg', string_agg(t.tgname || ':' || t.tgenabled::text || ':' || t.tgtype, ',' ORDER BY t.tgname) FROM pg_trigger t WHERE t.tgrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND NOT t.tgisinternal;
INSERT INTO _ant SELECT 'cmt', md5(obj_description(p.oid, 'pg_proc')) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica';

\ir ../ddl/101_tiempo_terminal_bitacora_aplica_sin_identidad_en_errores.sql

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- Ejecuta el INSERT como dueño (auth.role() NULL: el filtro de la API no aplica) y verifica SQLSTATE, HINT y que el mensaje NO contenga p_prohibido.
CREATE FUNCTION pg_temp.rechaza(p_caso text, p_sql text, p_estado text, p_hint text, p_prohibido text) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_estado AND v_hint IS NOT DISTINCT FROM p_hint AND position(p_prohibido IN v_msg) = 0,
    'obtenido=' || v_estado || ' hint=' || COALESCE(v_hint, '-') || ' msg=' || left(v_msg, 90));
END;
$$ LANGUAGE plpgsql;

INSERT INTO tiempo.terminal (terminal_id, nombre, modelo, activa) VALUES ('ENSAYO-101I', 'Terminal inactiva de ensayo 101', 'DS-K1A8503EF-B', false);
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo, activa) VALUES ('ENSAYO-101', 'Terminal de ensayo 101', 'DS-K1A8503EF-B', true);

SELECT pg_temp.verifica('1 SECURITY DEFINER y search_path exacto (iguales a antes)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND (SELECT v FROM _ant WHERE k = 'secdef') = 'true' AND (SELECT v FROM _ant WHERE k = 'cfg') = 'search_path=tiempo, personas, pg_temp'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'$$);
SELECT pg_temp.verifica('2 la ACL no cambió y nadie de la API ejecuta la función',
  $$SELECT COALESCE(p.proacl::text, 'NULL') = (SELECT v FROM _ant WHERE k = 'acl') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'$$);
SELECT pg_temp.verifica('3 los triggers de la bitácora siguen intactos (mismos nombres, estado y tipo)',
  $$SELECT string_agg(t.tgname || ':' || t.tgenabled::text || ':' || t.tgtype, ',' ORDER BY t.tgname) = (SELECT v FROM _ant WHERE k = 'trg') FROM pg_trigger t WHERE t.tgrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND NOT t.tgisinternal$$);
SELECT pg_temp.verifica('4 el COMENTARIO de la función no cambió', $$SELECT md5(obj_description(p.oid, 'pg_proc')) = (SELECT v FROM _ant WHERE k = 'cmt') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'$$);
SELECT pg_temp.verifica('5 el cuerpo ya no interpola identificadores en ningún RAISE (ver sección 64 del verificador)',
  $$SELECT p.prosrc NOT LIKE '%NEW.persona_id, NEW.terminal_id%' AND p.prosrc NOT LIKE '%v_vivo.id, v_vivo.terminal_id%' AND p.prosrc NOT LIKE '%NEW.employee_no, v_vivo.id%' AND p.prosrc NOT LIKE '%NEW.terminal_id USING%'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_bitacora_terminal_usuario_aplica'$$);

-- Comportamiento: mismos ERRCODE y HINT, sin el identificador en el mensaje (la persona es un uuid aleatorio: el chequeo de terminal va antes que el de persona).
SELECT pg_temp.rechaza('6 asignado con terminal INACTIVA: SCJ12 terminal_no_valida y el mensaje no contiene el id de la terminal',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen) VALUES (%s, gen_random_uuid(), 'asignado', 'web')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I')),
  'SCJ12', 'terminal_no_valida', (SELECT id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I'));
SELECT pg_temp.rechaza('7 asignado con terminal ACTIVA y persona inexistente: SCJ12 persona_no_activa y el mensaje no contiene el uuid',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen) VALUES (%s, '00000000-0000-4000-8000-000000000101', 'asignado', 'web')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101')),
  'SCJ12', 'persona_no_activa', '00000000-0000-4000-8000-000000000101');
SELECT pg_temp.rechaza('8 movimiento sobre una alta inexistente: SCJ11 transicion_invalida y el mensaje no contiene el id recibido',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, terminal_usuario_id, tipo_movimiento, origen) VALUES (%s, '00000000-0000-4000-8000-000000000101', 987654321, 'usuario_creado', 'terminal')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101')),
  'SCJ11', 'transicion_invalida', '987654321');
SELECT pg_temp.verifica('9 ninguna fila se escribió en la bitácora por los rechazos', $$SELECT NOT EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_id IN (SELECT id FROM tiempo.terminal WHERE terminal_id LIKE 'ENSAYO-101%'))$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
