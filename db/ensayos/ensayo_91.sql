-- Ensayo de 91_tiempo_terminal_endurecimiento_rpc.sql (con 88_, cuyo flujo de altas con consentimiento usa). NO es DDL versionado. NO correr sin
-- OK explícito del usuario (en el chat de la sesión que lo corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_91.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 88_ y 91_ ENCIMA de lo ya aplicado (87_). Terminal, personas, usuarios y bitácora de personas SINTÉTICOS;
-- el admin real sólo es caller y autor de uno de los movimientos de persona (todo se revierte). 88_ exige terminal_usuario y la bitácora vacías.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
DO $b$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM tiempo.terminal_usuario) THEN
    EXECUTE 'ALTER SEQUENCE tiempo.seq_terminal_employee_no RESTART WITH 1';
  END IF;
END $b$;
\ir ../ddl/88_tiempo_terminal_consentimiento.sql
\ir ../ddl/91_tiempo_terminal_endurecimiento_rpc.sql

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_uid', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'admin_persona', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_uid');

-- p_sub: NULL = el admin real; '-' = claims SIN sub; otro = ese auth uid.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL, p_hint text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL; v_claims json;
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
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);   -- los claims son de transacción: no dejarlos puestos para los fixtures del dueño
  INSERT INTO _res (caso, ok, detalle) VALUES (
    p_caso,
    (CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok' ELSE v_estado = p_esperado END)
      AND (p_hint IS NULL OR v_hint IS NOT DISTINCT FROM p_hint),
    'obtenido=' || v_estado || ' hint=' || COALESCE(v_hint, '-') || ' ' || left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), p_sql);
END;
$$ LANGUAGE plpgsql;

-- Llama una función que devuelve jsonb como p_rol y evalúa p_check ($1 = resultado).
CREATE FUNCTION pg_temp.rpc(p_caso text, p_rol text, p_llamada text, p_check text, p_sub text DEFAULT NULL) RETURNS void AS $$
DECLARE v_res jsonb; v_ok boolean := false; v_det text := ''; v_claims json;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  IF p_sub = '-' THEN v_claims := json_build_object('role', p_rol);
  ELSE v_claims := json_build_object('sub', COALESCE(p_sub, (SELECT x.v FROM _ens x WHERE x.k='auth_uid')), 'role', p_rol);
  END IF;
  PERFORM set_config('request.jwt.claims', v_claims::text, true);
  BEGIN
    EXECUTE 'SELECT ' || p_llamada INTO v_res;
  EXCEPTION WHEN OTHERS THEN
    v_det := 'EXC ' || SQLSTATE || ' ' || left(SQLERRM, 100); v_res := NULL;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_det = '' THEN
    EXECUTE 'SELECT COALESCE(' || p_check || ', false)' INTO v_ok USING v_res;
  END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_ok, v_det || ' ' || left(COALESCE(v_res::text, 'null'), 300));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.vig() RETURNS text AS $$
  SELECT id::text FROM tiempo.terminal_consentimiento ORDER BY version DESC LIMIT 1;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.asignar(p_persona text, p_term text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$, p_term, p_persona, (SELECT v FROM _ens WHERE k='auth_uid'), pg_temp.vig());
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.tu(p_k text) RETURNS bigint AS $$
  SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.baja_rpc(p_k text) RETURNS text AS $$
  SELECT format('to_jsonb(tiempo.fn_terminal_baja_por_persona_inactiva(%L::uuid))', (SELECT v FROM _ens WHERE k = p_k));
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.mov_rpc(p_k text, p_tipo text, p_detalle text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, %L::text, NULL::integer, %L::text)',
                (SELECT v FROM _ens WHERE k='terminal'), pg_temp.tu(p_k), p_tipo, p_detalle);
$$ LANGUAGE sql;

INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-91', 'Terminal de ensayo 91', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-91';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXXD' || i, 'XEXX010101D' || i, '9999991' || lpad((30 + i)::text, 4, '0'), 'SinteticaD' || i, 'Ensayo91', DATE '2000-01-01', CURRENT_DATE FROM generate_series(1, 5) i;
INSERT INTO _ens SELECT 'P' || i, p.id::text FROM generate_series(1, 5) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXXD' || i;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k LIKE 'P_' ON CONFLICT DO NOTHING;
-- P5 = persona del usuario RH sintético (segundo autor de movimientos de persona).
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', 'rh91@invalid.test' FROM _ens WHERE k = 'auth_rh';
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) SELECT (SELECT v::uuid FROM _ens WHERE k='auth_rh'), (SELECT v::uuid FROM _ens WHERE k='P5'), 'ens91rh';

-- Altas: P1..P3 (activas en el aparato, esperando_huella) y P4 (para el detalle del Pi).
DO $do$
DECLARE t text := (SELECT v FROM _ens WHERE k='terminal'); p text;
BEGIN
  FOREACH p IN ARRAY ARRAY['P1','P2','P3','P4'] LOOP
    EXECUTE pg_temp.asignar((SELECT v FROM _ens WHERE k = p), t);
  END LOOP;
END
$do$;
SELECT pg_temp.verifica('00 fixture: existe el caller admin, la terminal y 4 altas', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND (SELECT count(*) FROM tiempo.terminal_usuario) = 4$$);

-- ---------- A. autor de la baja por persona inactiva ----------
-- P1: dos suspensiones. R1 (admin) se REGISTRÓ antes (creado_en hace 2 días) pero con fecha_efectiva futura; R2 (RH) se registró después (hace 1 día)
-- con fecha_efectiva pasada. El último acto REGISTRADO es R2 (RH); el orden viejo (fecha_efectiva DESC) habría elegido R1 (admin).
INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por, creado_en) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='P1'), 'suspension', now() + interval '10 days', 'R1 ensayo91', (SELECT v::uuid FROM _ens WHERE k='auth_uid'), now() - interval '2 days'),
  ((SELECT v::uuid FROM _ens WHERE k='P1'), 'suspension', now() - interval '30 days', 'R2 ensayo91', (SELECT v::uuid FROM _ens WHERE k='auth_rh'),  now() - interval '1 day');
SELECT pg_temp.rpc('10 la baja automática de P1 se emite (1 alta) como service_role', 'service_role', pg_temp.baja_rpc('P1'), $c$ $1 = '1'::jsonb $c$, '-');
SELECT pg_temp.verifica('10b el autor de la baja_solicitada es el del último movimiento REGISTRADO (RH), no el de la fecha_efectiva más alta (admin)',
  $$SELECT b.registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_rh')
    FROM tiempo.bitacora_movimiento_terminal_usuario b WHERE b.tipo_movimiento = 'baja_solicitada' AND b.persona_id = (SELECT v::uuid FROM _ens WHERE k='P1')$$);
SELECT pg_temp.rpc('10c segunda llamada: idempotente, 0', 'service_role', pg_temp.baja_rpc('P1'), $c$ $1 = '0'::jsonb $c$, '-');

-- P2: mismo creado_en en ambas suspensiones; ahora fecha_efectiva DESEMPATA (la mayor es la de RH).
INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por, creado_en) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='P2'), 'suspension', now() - interval '10 days', 'R3 ensayo91', (SELECT v::uuid FROM _ens WHERE k='auth_uid'), timestamptz '2026-01-15 12:00+00'),
  ((SELECT v::uuid FROM _ens WHERE k='P2'), 'suspension', now() - interval '5 days',  'R4 ensayo91', (SELECT v::uuid FROM _ens WHERE k='auth_rh'),  timestamptz '2026-01-15 12:00+00');
SELECT pg_temp.rpc('11 P2 (mismo creado_en): se emite 1 baja', 'service_role', pg_temp.baja_rpc('P2'), $c$ $1 = '1'::jsonb $c$, '-');
SELECT pg_temp.verifica('11b con creado_en empatado decide fecha_efectiva: el autor es RH (fecha_efectiva mayor)',
  $$SELECT b.registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_rh')
    FROM tiempo.bitacora_movimiento_terminal_usuario b WHERE b.tipo_movimiento = 'baja_solicitada' AND b.persona_id = (SELECT v::uuid FROM _ens WHERE k='P2')$$);
SELECT pg_temp.rpc('11c P3 sigue ACTIVA: 0 y sin baja', 'service_role', pg_temp.baja_rpc('P3'), $c$ $1 = '0'::jsonb $c$, '-');
SELECT pg_temp.verifica('11d P3 conserva su alta', $$SELECT estado <> 'pendiente_baja' FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P3')$$);
SELECT pg_temp.caso('12 authenticated y anon no ejecutan la baja automática (EXECUTE sólo service_role)', 'authenticated', 'SELECT ' || pg_temp.baja_rpc('P3'), '42501');
SELECT pg_temp.caso('12b ... anon', 'anon', 'SELECT ' || pg_temp.baja_rpc('P3'), '42501', '-');

-- ---------- B. detalle del Pi sin invisibles ----------
-- P4: usuario_creado y luego un error con un detalle lleno de caracteres de formato.
SELECT pg_temp.rpc('20 Pi: usuario_creado de P4', 'service_role', pg_temp.mov_rpc('P4', 'usuario_creado', NULL), $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.rpc('20b Pi: error con detalle que trae U+202E, U+200B, U+2028, U+2029, tab, etiqueta U+E0041 y U+FEFF', 'service_role',
  pg_temp.mov_rpc('P4', 'error', E'ab\u202Ecd\u200Bef\u2028gh\u2029ij' || chr(9) || E'kl\U000E0041\uFEFFmn'), $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.verifica('20c el detalle quedó limpio en la bitácora y en error_detalle de la alta: invisibles fuera, U+2028/2029 y tab a espacio',
  $$SELECT b.detalle = 'abcdef gh ij klmn' AND (SELECT error_detalle FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P4')) = 'abcdef gh ij klmn'
    FROM tiempo.bitacora_movimiento_terminal_usuario b WHERE b.tipo_movimiento = 'error' AND b.persona_id = (SELECT v::uuid FROM _ens WHERE k='P4')$$);
SELECT pg_temp.rpc('21 Pi: error cuyo detalle son SÓLO invisibles -> detalle fijo "error sin detalle"', 'service_role',
  pg_temp.mov_rpc('P4', 'error', E'\u200B\u202E\uFEFF'), $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.verifica('21b ... y quedó "error sin detalle"', $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE detalle = 'error sin detalle' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P4')$$);
SELECT pg_temp.rpc('22 Pi: error con un detalle de 600 caracteres -> se recorta a 500', 'service_role',
  pg_temp.mov_rpc('P4', 'error', repeat('x', 600)), $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.verifica('22b ... el detalle guardado mide 500', $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE char_length(detalle) = 500 AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P4')$$);
SELECT pg_temp.rpc('23 Pi: huella_capturada con detalle de sólo invisibles -> detalle NULL (no falla)', 'service_role',
  format('tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, %L::text, 2, %L::text)', (SELECT v FROM _ens WHERE k='terminal'), pg_temp.tu('P4'), 'huella_capturada', E'\u200B\u061C'),
  $c$ $1->>'resultado' = 'registrado' AND $1->>'estado' = 'activo' $c$, '-');
SELECT pg_temp.verifica('23b ... y el detalle de esa fila es NULL', $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'huella_capturada' AND detalle IS NULL AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P4')$$);
SELECT pg_temp.caso('24b tipo no permitido -> SCJ11 transicion_invalida', 'service_role', 'SELECT ' || pg_temp.mov_rpc('P4', 'asignado', NULL), 'SCJ11', '-', 'transicion_invalida');
SELECT pg_temp.rpc('24c alta de otra terminal / inexistente -> no_encontrado', 'service_role',
  format('tiempo.fn_terminal_movimiento_registrar(999999999::bigint, %s::bigint, %L::text, NULL::integer, NULL::text)', pg_temp.tu('P4'), 'error'), $c$ $1->>'resultado' = 'no_encontrado' $c$, '-');
SELECT pg_temp.caso('25 authenticated no ejecuta el RPC del Pi', 'authenticated', 'SELECT ' || pg_temp.mov_rpc('P4', 'error', 'x'), '42501');

\ir verificar_91.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
