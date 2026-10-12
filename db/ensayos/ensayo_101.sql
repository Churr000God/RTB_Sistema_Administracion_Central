-- Ensayo de 101_tiempo_terminal_bitacora_aplica_sin_identidad_en_errores.sql. NO es DDL versionado. NO correr sin OK explícito del usuario ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_101.sql     (SIN -1; puerto 5432)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 101_ (sobre 88_-100_). Terminales, persona y alta SINTÉTICAS (creadas en la transacción y revertidas); el administrador real solo figura como autor (registrado_por) de la alta sintética.
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

-- Comportamiento (7 raises cambiados: 6-8 y 11-14; el 7.º, 'ya tiene aceptada', es el 14): mismos ERRCODE y HINT, sin el identificador en el mensaje (la persona es un uuid aleatorio: el chequeo de terminal va antes que el de persona).
SELECT pg_temp.rechaza('6 asignado con terminal INACTIVA: SCJ12 terminal_no_valida y el mensaje no contiene el id de la terminal',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen) VALUES (%s, gen_random_uuid(), 'asignado', 'web')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I')),
  'SCJ12', 'terminal_no_valida', (SELECT id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I'));
SELECT pg_temp.rechaza('7 asignado con terminal ACTIVA y persona inexistente: SCJ12 persona_no_activa y el mensaje no contiene el uuid',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen) VALUES (%s, '00000000-0000-4000-8000-000000000101', 'asignado', 'web')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101')),
  'SCJ12', 'persona_no_activa', '00000000-0000-4000-8000-000000000101');
SELECT pg_temp.rechaza('8 movimiento sobre una alta inexistente: SCJ11 transicion_invalida y el mensaje no contiene el id recibido',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, terminal_usuario_id, tipo_movimiento, origen) VALUES (%s, '00000000-0000-4000-8000-000000000101', 987654321, 'usuario_creado', 'terminal')$f$, (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101')),
  'SCJ11', 'transicion_invalida', '987654321');
SELECT pg_temp.verifica('9 ninguna fila se escribió en la bitácora por los rechazos', $$SELECT NOT EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_id = (SELECT id FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I'))$$);

-- ---- Los 4 raises restantes: persona sintética con una alta REAL creada dentro de la transacción (se revierte) ----
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXY91', 'XEXY01010191', '99999940091', 'Sintetica91', 'Ensayo101', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO tiempo.persona (id) SELECT id FROM personas.persona WHERE curp = 'XEXX010101HNEXXY91' ON CONFLICT DO NOTHING;
CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
INSERT INTO _ens SELECT 'persona', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXY91';
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101';
INSERT INTO _ens SELECT 'terminal_otra', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-101I';
INSERT INTO _ens SELECT 'autor', u.auth_user_id::text FROM personas.usuario u JOIN personas.persona p ON p.id = u.persona_id AND p.estado = 'activo'
  JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL JOIN personas.puesto pu ON pu.id = a.puesto_id AND pu.es_administrador_generico LIMIT 1;
INSERT INTO _ens SELECT 'consent', id::text FROM tiempo.terminal_consentimiento ORDER BY version DESC LIMIT 1;
-- Alta real: asignado (como dueño, autor = el administrador) y usuario_creado del Pi (el RPC pone employee_no y terminal_usuario).
INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
SELECT (SELECT v::bigint FROM _ens WHERE k = 'terminal'), (SELECT v::uuid FROM _ens WHERE k = 'persona'), 'asignado', 'web', (SELECT v::uuid FROM _ens WHERE k = 'autor'), (SELECT v::bigint FROM _ens WHERE k = 'consent');
INSERT INTO _ens SELECT 'tu', id::text FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona');
SELECT tiempo.fn_terminal_movimiento_registrar((SELECT v::bigint FROM _ens WHERE k = 'terminal'), (SELECT v::bigint FROM _ens WHERE k = 'tu'), 'usuario_creado', NULL, NULL);
INSERT INTO _ens SELECT 'emp', employee_no::text FROM tiempo.terminal_usuario WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'tu');
SELECT pg_temp.verifica('10 la alta sintética quedó en esperando_huella (precondición de los casos 11-14)',
  $$SELECT estado = 'esperando_huella' FROM tiempo.terminal_usuario WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'tu')$$);
SELECT pg_temp.rechaza('11 alta duplicada (la persona ya tiene alta vigente): SCJ12 alta_duplicada y el mensaje no contiene el uuid de la persona',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id) VALUES (%s, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$,
         (SELECT v FROM _ens WHERE k = 'terminal'), (SELECT v FROM _ens WHERE k = 'persona'), (SELECT v FROM _ens WHERE k = 'autor'), (SELECT v FROM _ens WHERE k = 'consent')),
  'SCJ12', 'alta_duplicada', (SELECT v FROM _ens WHERE k = 'persona'));
SELECT pg_temp.rechaza('12 terminal/persona no coinciden con la alta: SCJ11 transicion_invalida y el mensaje no contiene el uuid de la persona',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, origen) VALUES (%s, %s, %L::uuid, %s, 'huella_capturada', 'terminal')$f$,
         (SELECT v FROM _ens WHERE k = 'tu'), (SELECT v FROM _ens WHERE k = 'terminal_otra'), (SELECT v FROM _ens WHERE k = 'persona'), (SELECT v FROM _ens WHERE k = 'emp')),
  'SCJ11', 'transicion_invalida', (SELECT v FROM _ens WHERE k = 'persona'));
SELECT pg_temp.rechaza('13 employee_no no coincide con el de la alta: SCJ11 transicion_invalida y el mensaje no contiene el uuid de la persona',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, origen) VALUES (%s, %s, %L::uuid, %s, 'huella_capturada', 'terminal')$f$,
         (SELECT v FROM _ens WHERE k = 'tu'), (SELECT v FROM _ens WHERE k = 'terminal'), (SELECT v FROM _ens WHERE k = 'persona'), (SELECT (v::integer + 1)::text FROM _ens WHERE k = 'emp')),
  'SCJ11', 'transicion_invalida', (SELECT v FROM _ens WHERE k = 'persona'));
SELECT pg_temp.rechaza('14 la alta ya tiene aceptada esa versión del texto (reconsentido con la misma versión): SCJ11 transicion_invalida y el mensaje no contiene el uuid de la persona',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, origen, registrado_por, consentimiento_id) VALUES (%s, %s, %L::uuid, %s, 'reconsentido', 'web', %L::uuid, %s)$f$,
         (SELECT v FROM _ens WHERE k = 'tu'), (SELECT v FROM _ens WHERE k = 'terminal'), (SELECT v FROM _ens WHERE k = 'persona'), (SELECT v FROM _ens WHERE k = 'emp'), (SELECT v FROM _ens WHERE k = 'autor'), (SELECT v FROM _ens WHERE k = 'consent')),
  'SCJ11', 'transicion_invalida', (SELECT v FROM _ens WHERE k = 'persona'));
SELECT pg_temp.verifica('15 los 4 rechazos no escribieron nada: la bitácora de la persona sintética tiene exactamente asignado y usuario_creado',
  $$SELECT count(*) = 2 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
