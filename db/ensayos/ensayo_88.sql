-- Ensayo de 88_tiempo_terminal_consentimiento.sql: texto de consentimiento versionado, columna consentimiento_id, SCJ16,
-- reconsentimiento ('reconsentido', lote) y regresión del flujo del Pi. NO es DDL versionado. NO correr sin OK explícito del
-- usuario (en el chat de la sesión que lo corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_88.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 88_ ENCIMA de lo ya aplicado (87_). Personas, terminal y usuarios SINTÉTICOS; el
-- administrador real sólo actúa como caller (claims). Requiere un usuario activo asignado al puesto es_administrador_generico y
-- que tiempo.terminal_usuario y la bitácora estén vacías (88_ aborta si no). La secuencia del employee_no se reinicia con ALTER
-- SEQUENCE RESTART al inicio (transaccional: el ROLLBACK la restaura).
-- NOTA: los ensayos históricos 82_84/85/86/87 NO son compatibles con la base posterior a 88_ (sus 'asignado' no traen
-- consentimiento_id); sirvieron para su migración y no se vuelven a correr.
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

-- id de la versión vigente (el literal se arma como dueño; el rol sólo ejecuta el texto).
CREATE FUNCTION pg_temp.vig() RETURNS text AS $$
  SELECT id::text FROM tiempo.terminal_consentimiento ORDER BY version DESC LIMIT 1;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.ver(p_version int) RETURNS text AS $$
  SELECT id::text FROM tiempo.terminal_consentimiento WHERE version = p_version;
$$ LANGUAGE sql;

-- INSERT de 'asignado' de una persona; p_consent = literal SQL del consentimiento_id ('NULL' o un número).
CREATE FUNCTION pg_temp.asignar(p_persona text, p_consent text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$,
    (SELECT v FROM _ens WHERE k='terminal'), p_persona, (SELECT v FROM _ens WHERE k='auth_uid'), p_consent);
$$ LANGUAGE sql;

-- INSERT de 'reconsentido' sobre la alta de una persona (clave de _ens).
CREATE FUNCTION pg_temp.reconsent(p_k text, p_consent text, p_uid text DEFAULT NULL) RETURNS text AS $$
  -- VALUES con ids resueltos como dueño (si fuera INSERT ... SELECT, un llamador sin permiso no vería terminal_usuario y el INSERT afectaría 0 filas sin error).
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id, detalle)
    VALUES (%L::bigint, %L::bigint, %L::uuid, 'reconsentido', 'web', %L::uuid, %s, 'prueba')$f$,
    (SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1),
    (SELECT terminal_id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1),
    (SELECT v FROM _ens WHERE k = p_k), COALESCE(p_uid, (SELECT v FROM _ens WHERE k='auth_uid')), p_consent);
$$ LANGUAGE sql;
-- Movimiento del Pi (origen terminal) con ids resueltos como dueño.
CREATE FUNCTION pg_temp.pi_mov(p_k text, p_tipo text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen)
    VALUES (%L::bigint, %L::bigint, %L::uuid, %L, 'terminal')$f$,
    (SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1),
    (SELECT terminal_id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1),
    (SELECT v FROM _ens WHERE k = p_k), p_tipo);
$$ LANGUAGE sql;

-- 'asignado' con un registrado_por EXPLÍCITO (para probar suplantación del autor).
CREATE FUNCTION pg_temp.asignar_como(p_persona text, p_consent text, p_autor text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$,
    (SELECT v FROM _ens WHERE k='terminal'), p_persona, p_autor, p_consent);
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.tu(p_k text) RETURNS bigint AS $$
  SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1;
$$ LANGUAGE sql;

-- Terminal de ensayo y personas sintéticas P1..P4 (alta), PR (usuario RH) y PS (usuario sin permisos).
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-88', 'Terminal de ensayo 88', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-88';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXX' || n, 'XEXX010101' || n, '9999999' || lpad((10 + i)::text, 4, '0'), 'Sintetica' || n, 'Ensayo88', DATE '2000-01-01', CURRENT_DATE
FROM (VALUES (1, 'A1'), (2, 'A2'), (3, 'A3'), (4, 'A4'), (5, 'A5'), (6, 'A6'), (7, 'A7')) AS t(i, n);
INSERT INTO _ens SELECT 'P' || i, id::text FROM (VALUES (1, 'A1'), (2, 'A2'), (3, 'A3'), (4, 'A4'), (5, 'A5'), (6, 'A6'), (7, 'A7')) AS t(i, n)
  JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXX' || t.n;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k IN ('P1','P2','P3','P4','P5','P6','P7') ON CONFLICT DO NOTHING;
-- P5 = persona del usuario RH sintético; P6 = persona del usuario sin permisos.
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text), ('auth_sin', gen_random_uuid()::text), ('auth_gg', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email)
SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_rh', 'auth_sin', 'auth_gg');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='auth_rh'),  (SELECT v::uuid FROM _ens WHERE k='P5'), 'ens88rh'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_sin'), (SELECT v::uuid FROM _ens WHERE k='P6'), 'ens88sin'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_gg'),  (SELECT v::uuid FROM _ens WHERE k='P7'), 'ens88gg');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P5'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos';
-- P7 = Gerente General (tiene terminal_usuario_edicion pero NO es el puesto administrador genérico).
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P7'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS88 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P6'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS88 sin permisos';

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin y la terminal de ensayo', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND EXISTS (SELECT 1 FROM _ens WHERE k='terminal')$$);
SELECT pg_temp.verifica('01 permiso terminal_config_edicion: no heredable, activo SOLO para TI y Gerente General (RH no)',
  $$SELECT EXISTS (SELECT 1 FROM personas.permiso WHERE codigo='terminal_config_edicion' AND NOT heredable)
      AND (SELECT array_agg(p.nombre_puesto::text ORDER BY p.nombre_puesto) FROM personas.puesto_permiso pp JOIN personas.puesto p ON p.id = pp.puesto_id
            WHERE pp.codigo='terminal_config_edicion' AND pp.activo) = ARRAY['Gerente General', 'Gerente o Encargado de TI']$$);
SELECT pg_temp.verifica('02 semilla: una sola versión (1), provisional, sin autor, sin cambio material, hash correcto',
  $$SELECT count(*) = 1 AND bool_and(version = 1 AND provisional AND creado_por IS NULL AND NOT cambio_material
                                     AND texto_sha256 = encode(sha256(convert_to(texto,'UTF8')),'hex'))
    FROM tiempo.terminal_consentimiento$$);

-- A. Inmutabilidad y grants de la tabla
SELECT pg_temp.caso('10 UPDATE directo como dueño -> el trigger lo impide', current_user::text, $$UPDATE tiempo.terminal_consentimiento SET nota = 'x'$$, 'P0001');
SELECT pg_temp.caso('10b DELETE como dueño -> el trigger lo impide', current_user::text, $$DELETE FROM tiempo.terminal_consentimiento$$, 'P0001');
SELECT pg_temp.caso('10c TRUNCATE como dueño -> imposible (las FK de la bitácora y de la tabla viva lo impiden antes; el trigger BEFORE TRUNCATE es la segunda barrera)', current_user::text, $$TRUNCATE tiempo.terminal_consentimiento$$, 'error');
SELECT pg_temp.caso('10d INSERT directo como authenticated (admin) -> 42501', 'authenticated',
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) VALUES (99, 'x', repeat('0', 64), NULL)$$, '42501');
SELECT pg_temp.caso('10e INSERT directo como service_role -> 42501', 'service_role',
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) VALUES (99, 'x', repeat('0', 64), NULL)$$, '42501', '-');
SELECT pg_temp.caso('10f SELECT como anon -> 42501', 'anon', $$SELECT * FROM tiempo.terminal_consentimiento$$, '42501', '-');
SELECT pg_temp.caso('10h el usuario sin permisos ve 0 filas (RLS)', 'authenticated',
  $$SELECT 1 / (CASE WHEN (SELECT count(*) FROM tiempo.terminal_consentimiento) = 0 THEN 1 ELSE 0 END)$$, 'ok', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('10i RH (terminal_usuario_edicion) ve la versión 1', 'authenticated',
  $$SELECT 1 / (CASE WHEN (SELECT count(*) FROM tiempo.terminal_consentimiento) = 1 THEN 1 ELSE 0 END)$$, 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));

-- B. Asignación y SCJ16 (con la versión 1 vigente)
SELECT pg_temp.caso('20 asignado SIN consentimiento_id -> SCJ16 consentimiento_requerido', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P1'), 'NULL'), 'SCJ16', NULL, 'consentimiento_requerido');
SELECT pg_temp.caso('20b asignado con una versión inexistente -> SCJ16 consentimiento_desactualizado', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P1'), '999999999'), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.caso('21 asignado con la versión vigente (1), como admin -> ok', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P1'), pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('21b la alta quedó con employee_no = 1 (los SCJ16 de 20/20b no quemaron números: el trigger rechaza antes del nextval)',
  $$SELECT employee_no = 1 FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P1')$$);
SELECT pg_temp.verifica('21c la bitácora guarda consentimiento_id = versión 1 y la alta (tabla viva) también',
  $$SELECT b.consentimiento_id = c.id AND tu.consentimiento_id = c.id
    FROM tiempo.bitacora_movimiento_terminal_usuario b JOIN tiempo.terminal_usuario tu ON tu.id = b.terminal_usuario_id
    JOIN tiempo.terminal_consentimiento c ON c.version = 1
    WHERE b.tipo_movimiento = 'asignado' AND b.persona_id = (SELECT v::uuid FROM _ens WHERE k='P1')$$);
SELECT pg_temp.verifica('21d el detalle del asignado lo fijó la base: "consentimiento y aviso de privacidad recabados: versión 1" (nunca NULL)',
  $$SELECT detalle = 'consentimiento y aviso de privacidad recabados: versión 1' FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'asignado' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P1')$$);
SELECT pg_temp.caso('21e un asignado que trae su propio detalle: la base lo sobrescribe', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id, detalle)
            VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s, 'texto del cliente')$f$,
         (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P2'), (SELECT v FROM _ens WHERE k='auth_uid'), pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('21f ... y quedó el detalle fijo, no el del cliente', $$SELECT detalle = 'consentimiento y aviso de privacidad recabados: versión 1' FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'asignado' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P2')$$);
SELECT pg_temp.caso('22 asignado como RH (terminal_usuario_edicion) con la versión vigente -> ok', 'authenticated', pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P3'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('22b asignado por el usuario sin permisos -> 42501 (RLS)', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P4'), pg_temp.vig()), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('23 consentimiento_id en un movimiento que no lo admite (usuario_creado con versión) -> CHECK 23514', current_user::text,
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, consentimiento_id)
            SELECT tu.id, tu.terminal_id, tu.persona_id, 'usuario_creado', 'terminal', %s FROM tiempo.terminal_usuario tu WHERE tu.persona_id = %L::uuid$f$,
         pg_temp.vig(), (SELECT v FROM _ens WHERE k='P1')), '23514');
SELECT pg_temp.caso('23b asignado... sin consentimiento y por el dueño: el trigger lo rechaza igual (SCJ16)', current_user::text,
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P6'), (SELECT v FROM _ens WHERE k='auth_uid')),
  'SCJ16', NULL, 'consentimiento_requerido');

-- M1 (security): quien NO tiene terminal_usuario_edicion no obtiene oráculo ni efectos del trigger; sólo el 42501 de la RLS.
INSERT INTO _ens SELECT 'seq_m1', last_value::text FROM tiempo.seq_terminal_employee_no;
SELECT pg_temp.caso('26a sin permiso asigna a una persona YA enrolada (P1) -> 42501, NO SCJ12 alta_duplicada', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P1'), pg_temp.vig()), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26b sin permiso asigna con una terminal inexistente -> 42501, NO SCJ12 terminal_no_valida', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
            VALUES (999999999, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$, (SELECT v FROM _ens WHERE k='P6'), (SELECT v FROM _ens WHERE k='auth_sin'), pg_temp.vig()), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26c sin permiso con una versión inexistente de consentimiento -> 42501, NO SCJ16', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P6'), '999999999'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26d sin permiso sin consentimiento_id -> 42501, NO SCJ16 requerido', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P6'), 'NULL'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26e sin permiso asigna a una persona inactiva/inexistente -> 42501, NO SCJ12 persona_no_activa', 'authenticated', pg_temp.asignar('00000000-0000-0000-0000-00000000dead', pg_temp.vig()), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26f anon -> 42501', 'anon', pg_temp.asignar((SELECT v FROM _ens WHERE k='P6'), pg_temp.vig()), '42501', '-');
SELECT pg_temp.caso('26g CON permiso pero movimiento que no es web (usuario_creado con origen terminal) -> 42501 (la RLS lo rechaza; el trigger no procesa)', 'authenticated', pg_temp.pi_mov('P1', 'usuario_creado'), '42501');
SELECT pg_temp.caso('26g2 SIN permiso con un movimiento origen terminal (usuario_creado) -> 42501', 'authenticated', pg_temp.pi_mov('P1', 'usuario_creado'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('26h claims role=authenticated SIN sub y un asignado web -> 42501', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P6'), pg_temp.vig()), '42501', '-');
SELECT pg_temp.verifica('26i NINGUNO de esos rechazos tuvo efectos: la secuencia del employee_no no avanzó y P1 sigue pendiente_alta',
  $$SELECT (SELECT last_value FROM tiempo.seq_terminal_employee_no) = (SELECT v::bigint FROM _ens WHERE k='seq_m1')
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) = 'pendiente_alta'$$);

-- Armar estados: P1 activo (con un error registrado), P2 esperando_huella, P3 pendiente_alta, P4 asignada y dada de baja.
SELECT pg_temp.verifica('24 P1, P2 y P3 ya están asignadas (21, 21e, 22)', $$SELECT count(*) = 3 FROM tiempo.terminal_usuario$$);
SELECT pg_temp.caso('24b asignar P4 (versión 1)', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P4'), pg_temp.vig()), 'ok');
INSERT INTO _ens VALUES ('tid', (SELECT v FROM _ens WHERE k='terminal'));
CREATE FUNCTION pg_temp.mov_rpc(p_k text, p_tipo text, p_huellas text, p_detalle text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, %L::text, %s::integer, %L::text)',
                (SELECT v FROM _ens WHERE k='terminal'), pg_temp.tu(p_k), p_tipo, p_huellas, p_detalle);
$$ LANGUAGE sql;
SELECT pg_temp.rpc('25 Pi: usuario_creado de P1, huella_capturada de P1 (regresión del flujo del Pi) -> activo', 'service_role',
  pg_temp.mov_rpc('P1', 'usuario_creado', 'NULL', NULL), $c$ $1->>'estado' = 'esperando_huella' $c$, '-');
SELECT pg_temp.rpc('25b huella_capturada P1', 'service_role', pg_temp.mov_rpc('P1', 'huella_capturada', '2', NULL), $c$ $1->>'estado' = 'activo' $c$, '-');
SELECT pg_temp.rpc('25c Pi: usuario_creado de P2 -> esperando_huella', 'service_role', pg_temp.mov_rpc('P2', 'usuario_creado', 'NULL', NULL), $c$ $1->>'estado' = 'esperando_huella' $c$, '-');
SELECT pg_temp.rpc('25d Pi: error sobre P1 (queda error_detalle)', 'service_role', pg_temp.mov_rpc('P1', 'error', 'NULL', 'fallo de prueba'), $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.caso('25e baja de P4 por RH (baja_solicitada) y Pi confirma', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            SELECT tu.id, tu.terminal_id, tu.persona_id, 'baja_solicitada', 'web', %L::uuid FROM tiempo.terminal_usuario tu WHERE tu.persona_id = %L::uuid$f$,
         (SELECT v FROM _ens WHERE k='auth_uid'), (SELECT v FROM _ens WHERE k='P4')), 'ok');
SELECT pg_temp.rpc('25f Pi: baja_confirmada de P4 -> baja', 'service_role', pg_temp.mov_rpc('P4', 'baja_confirmada', 'NULL', NULL), $c$ $1->>'estado' = 'baja' $c$, '-');
SELECT pg_temp.verifica('25g estados armados: P1 activo (error y 2 huellas), P2 esperando_huella, P3 pendiente_alta, P4 baja; todos con la versión 1',
  $$SELECT (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) = 'activo'
      AND (SELECT error_detalle FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) = 'fallo de prueba'
      AND (SELECT huellas_capturadas FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) = 2
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P2')) = 'esperando_huella'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P3')) = 'pendiente_alta'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P4')) = 'baja'
      AND (SELECT count(*) FROM tiempo.terminal_usuario WHERE consentimiento_id = pg_temp.ver(1)::bigint) = 4$$);
SELECT pg_temp.verifica('25h usuario_creado_en: lo fijó el trigger en P1 y P2 (usuario creado), NULL en P3 (pendiente_alta) y en P4 (nunca se creó)',
  $$SELECT (SELECT usuario_creado_en FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) IS NOT NULL
      AND (SELECT usuario_creado_en FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P2')) IS NOT NULL
      AND (SELECT usuario_creado_en FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P3')) IS NULL
      AND (SELECT usuario_creado_en FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P4')) IS NULL$$);
SELECT pg_temp.rpc('26 sin versión material todavía: reconsentimientos pendientes = 0', 'service_role',
  $$to_jsonb((SELECT count(*) FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids()))$$, $c$ $1 = '0'::jsonb $c$, '-');

-- C. Publicar versiones
SELECT pg_temp.caso('30b publicar como RH -> 42501 sin_permiso', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar('Texto nuevo', false, NULL)$$, '42501', (SELECT v FROM _ens WHERE k='auth_rh'), 'sin_permiso');
SELECT pg_temp.caso('30c publicar como usuario sin permisos -> 42501', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar('Texto nuevo', false, NULL)$$, '42501', (SELECT v FROM _ens WHERE k='auth_sin'), 'sin_permiso');
SELECT pg_temp.caso('30d publicar como anon -> 42501 (sin EXECUTE)', 'anon', $$SELECT tiempo.fn_terminal_consentimiento_publicar('Texto nuevo', false, NULL)$$, '42501', '-');
SELECT pg_temp.caso('30e publicar como service_role -> 42501 (sin EXECUTE)', 'service_role', $$SELECT tiempo.fn_terminal_consentimiento_publicar('Texto nuevo', false, NULL)$$, '42501', '-');
SELECT pg_temp.caso('31 texto vacío -> 22023 texto_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar(E'  \t ', false, NULL)$$, '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31b texto de 4001 caracteres -> 22023 texto_invalido', 'authenticated', format('SELECT tiempo.fn_terminal_consentimiento_publicar(%L, false, NULL)', repeat('a', 4001)), '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31c nota de 201 caracteres -> 22023 nota_invalida', 'authenticated', format('SELECT tiempo.fn_terminal_consentimiento_publicar(%L, false, %L)', 'Texto', repeat('n', 201)), '22023', NULL, 'nota_invalida');
SELECT pg_temp.caso('31c2 texto de sólo saltos de línea (M2) -> 22023 texto_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar(E'\n\n', false, NULL)$$, '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31c3 texto de espacios y saltos mezclados -> 22023 texto_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar(E'   \n  \r\n \t ', false, NULL)$$, '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31c4 texto de sólo caracteres invisibles (U+200B, U+202E, U+FEFF) -> 22023 texto_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar(E'\u200B\u202E\uFEFF', false, NULL)$$, '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31c4b texto de sólo U+00AD, U+061C, U+2028 y una etiqueta U+E0001 (invisibles ampliados) -> 22023 texto_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_consentimiento_publicar(E'\u00AD\u061C\u2028\U000E0001', false, NULL)$$, '22023', NULL, 'texto_invalido');
SELECT pg_temp.caso('31c5 INSERT directo (dueño) con texto de sólo "\n\n" -> CHECK 23514', current_user::text,
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) SELECT 99, E'\n\n', encode(sha256(convert_to(E'\n\n','UTF8')),'hex'), id FROM tiempo.persona LIMIT 1$$, '23514');
SELECT pg_temp.caso('31c7 INSERT directo (dueño) con U+061C dentro del texto -> CHECK 23514', current_user::text,
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) SELECT 99, E'abc\u061Cdef', encode(sha256(convert_to(E'abc\u061Cdef','UTF8')),'hex'), id FROM tiempo.persona LIMIT 1$$, '23514');
SELECT pg_temp.caso('31c8 INSERT directo (dueño) con U+00AD (guion blando) dentro del texto -> CHECK 23514', current_user::text,
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) SELECT 99, E'abc\u00ADdef', encode(sha256(convert_to(E'abc\u00ADdef','UTF8')),'hex'), id FROM tiempo.persona LIMIT 1$$, '23514');
SELECT pg_temp.caso('31c9 INSERT directo (dueño) con una etiqueta U+E0041 en medio de un texto normal -> CHECK 23514', current_user::text,
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) SELECT 99, E'Texto normal \U000E0041 con etiqueta', encode(sha256(convert_to(E'Texto normal \U000E0041 con etiqueta','UTF8')),'hex'), id FROM tiempo.persona LIMIT 1$$, '23514');
SELECT pg_temp.caso('31c6 INSERT directo (dueño) con un carácter de reordenamiento U+202E dentro del texto -> CHECK 23514', current_user::text,
  $$INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, creado_por) SELECT 99, E'abc\u202Edef', encode(sha256(convert_to(E'abc\u202Edef','UTF8')),'hex'), id FROM tiempo.persona LIMIT 1$$, '23514');
SELECT pg_temp.verifica('31d ninguna de esas llamadas publicó nada', $$SELECT count(*) = 1 FROM tiempo.terminal_consentimiento$$);
SELECT pg_temp.rpc('32 publicar la versión 2 como TI/admin (texto con salto de línea y caracteres de control) -> publicada; la anterior era provisional => cambio material forzado; 3 pendientes (P1,P2,P3; P4 está en baja)', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, false, %L)', E'  \nPrimera línea\tcon\u200B tab\u202E\r\nSegunda línea\x01fin\u2028Tercera\u2029línea\n\n', 'versión definitiva'),
  $c$ $1->>'resultado' = 'publicada' AND ($1->>'version')::int = 2 AND ($1->>'cambio_material')::boolean AND ($1->>'pendientes')::int = 3 $c$);
SELECT pg_temp.verifica('32b texto saneado: invisibles (U+200B, U+202E) quitados, U+2028/U+2029 convertidos en salto de línea (no pegan palabras), \t y \x01 a espacio, \r\n quedó \n, saltos y espacios de los extremos fuera, hash correcto, autor = el admin, nota guardada',
  $$SELECT texto = E'Primera línea con tab\nSegunda línea fin\nTercera\nlínea' AND creado_por = (SELECT v::uuid FROM _ens WHERE k='admin_persona')
      AND nota = 'versión definitiva' AND cambio_material AND NOT provisional
      AND texto_sha256 = encode(sha256(convert_to(texto,'UTF8')),'hex')
    FROM tiempo.terminal_consentimiento WHERE version = 2$$);
SELECT pg_temp.rpc('32c publicar el MISMO texto sobre una definitiva -> sin_cambio (no crea versión)', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, true, NULL)', E'Primera línea con tab\nSegunda línea fin\nTercera\nlínea'), $c$ $1->>'resultado' = 'sin_cambio' AND ($1->>'version')::int = 2 $c$);
SELECT pg_temp.rpc('32d versión 3 con cambio_material=false -> publicada, no material', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, false, NULL)', 'Texto menor v3'), $c$ ($1->>'version')::int = 3 AND NOT ($1->>'cambio_material')::boolean $c$);
SELECT pg_temp.caso('32f publicar con p_base_version = 2 cuando la vigente ya es la 3 (publicación concurrente) -> SCJ16 version_base_desactualizada', 'authenticated',
  $$SELECT tiempo.fn_terminal_consentimiento_publicar('Otro texto sobre base vieja', false, NULL, 2)$$, 'SCJ16', NULL, 'version_base_desactualizada');
SELECT pg_temp.rpc('32g p_base_version = 3 (la vigente) con el mismo texto -> acepta la base y responde sin_cambio', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, false, NULL, 3)', 'Texto menor v3'), $c$ $1->>'resultado' = 'sin_cambio' $c$);
SELECT pg_temp.verifica('32e hay 3 versiones y la vigente es la 3', $$SELECT count(*) = 3 AND max(version) = 3 FROM tiempo.terminal_consentimiento$$);

-- D. Versión desactualizada (siempre se rechaza)
INSERT INTO _ens SELECT 'seq_antes', last_value::text FROM tiempo.seq_terminal_employee_no;
SELECT pg_temp.caso('40 asignado con la versión 1 (ya no vigente) -> SCJ16 consentimiento_desactualizado', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P5'), pg_temp.ver(1)), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.caso('40b asignado con la versión 2 (tampoco es la vigente) -> SCJ16', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P5'), pg_temp.ver(2)), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.verifica('40c esos dos rechazos SCJ16 no quemaron employee_no (la secuencia no avanzó)',
  $$SELECT (SELECT last_value FROM tiempo.seq_terminal_employee_no) = (SELECT v::bigint FROM _ens WHERE k='seq_antes')$$);
-- Suplantación del autor para esquivar la regla de auto-asignación (P5 = persona del usuario RH sintético, todavía sin alta aquí).
SELECT pg_temp.caso('40d0 RH manda registrado_por AJENO (el admin genérico) para asignarse a sí mismo (P5) -> 42501 (la RLS exige registrado_por = auth.uid())', 'authenticated',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P5'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_uid')), '42501', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('40d1 ... y no quedó ninguna alta de P5 (el trigger corrió, pero todo se revirtió con el rechazo)', $$SELECT count(*) = 0 FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P5')$$);
SELECT pg_temp.caso('40d2 como DUEÑO con registrado_por = RH y persona = RH (P5) -> SCJ12 auto_asignacion_prohibida (la regla no depende de auth.uid())', current_user::text,
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P5'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', NULL, 'auto_asignacion_prohibida');
SELECT pg_temp.caso('40d3 como service_role con registrado_por = RH y persona = RH (P5) -> SCJ12 auto_asignacion_prohibida', 'service_role',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P5'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', '-', 'auto_asignacion_prohibida');
SELECT pg_temp.verifica('40d4 ... tampoco dejaron alta de P5', $$SELECT count(*) = 0 FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P5')$$);
SELECT pg_temp.caso('40d asignado con la versión vigente (3) -> ok', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P5'), pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('40e la alta nueva guardó la versión 3', $$SELECT consentimiento_id = pg_temp.vig()::bigint FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P5')$$);

-- E. Reconsentimiento pendiente (versión material = 2; la vigente es la 3 pero no material)
SELECT pg_temp.rpc('50 pendientes: P1 (activo), P2 (esperando_huella) y P3 (pendiente_alta) con la versión 1 < 2 (material); NO P4 (baja) ni P5 (versión 3)', 'service_role',
  $$to_jsonb(ARRAY(SELECT i FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids() AS i))$$,
  $c$ $1 = to_jsonb(ARRAY[pg_temp.tu('P1'), pg_temp.tu('P2'), pg_temp.tu('P3')]) $c$, '-');
SELECT pg_temp.rpc('50b RH (RLS) ve los mismos pendientes', 'authenticated',
  $$to_jsonb(ARRAY(SELECT i FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids() AS i))$$,
  $c$ jsonb_array_length($1) = 3 $c$, (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.rpc('50c el usuario sin permisos ve 0 pendientes (RLS de terminal_usuario)', 'authenticated',
  $$to_jsonb(ARRAY(SELECT i FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids() AS i))$$,
  $c$ jsonb_array_length($1) = 0 $c$, (SELECT v FROM _ens WHERE k='auth_sin'));

SELECT pg_temp.caso('51 reconsentido de P1 con la versión 1 (antigua) -> SCJ16 consentimiento_desactualizado', 'authenticated', pg_temp.reconsent('P1', pg_temp.ver(1)), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.caso('51b reconsentido de P1 con la versión 2 (no es la vigente) -> SCJ16', 'authenticated', pg_temp.reconsent('P1', pg_temp.ver(2)), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.caso('51c reconsentido de P1 sin consentimiento_id -> SCJ16 consentimiento_requerido', 'authenticated', pg_temp.reconsent('P1', 'NULL'), 'SCJ16', NULL, 'consentimiento_requerido');
SELECT pg_temp.caso('51d reconsentido de P4 (baja) con la versión vigente -> SCJ11 transicion_invalida', 'authenticated', pg_temp.reconsent('P4', pg_temp.vig()), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('51e reconsentido de P5 (ya tiene la versión vigente) -> SCJ11 transicion_invalida', 'authenticated', pg_temp.reconsent('P5', pg_temp.vig()), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('51f reconsentido como el usuario sin permisos -> 42501 (RLS)', 'authenticated', pg_temp.reconsent('P1', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_sin')), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('51f2 reconsentido SIN permiso con una versión vieja -> 42501, NO SCJ16 (sin oráculo)', 'authenticated', pg_temp.reconsent('P1', pg_temp.ver(1), (SELECT v FROM _ens WHERE k='auth_sin')), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('51f3 reconsentido SIN permiso sobre una alta en baja (P4) -> 42501, NO SCJ11', 'authenticated', pg_temp.reconsent('P4', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_sin')), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('51g reconsentido con autor ajeno (registrado_por distinto del caller) -> 42501 (anti-suplantación)', 'authenticated',
  pg_temp.reconsent('P1', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_sin')), '42501');
SELECT pg_temp.caso('52 reconsentido de P1 (activo, con error y 2 huellas) como RH con la versión vigente -> ok', 'authenticated', pg_temp.reconsent('P1', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('52b P1 sigue activo, con 2 huellas, CONSERVA error_detalle y ahora tiene la versión 3; la bitácora lo registra con autor RH',
  $$SELECT tu.estado = 'activo' AND tu.huellas_capturadas = 2 AND tu.error_detalle = 'fallo de prueba' AND tu.consentimiento_id = pg_temp.vig()::bigint
      AND EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario b WHERE b.terminal_usuario_id = tu.id AND b.tipo_movimiento = 'reconsentido'
                  AND b.registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_rh') AND b.consentimiento_id = pg_temp.vig()::bigint)
    FROM tiempo.terminal_usuario tu WHERE tu.id = pg_temp.tu('P1')$$);
SELECT pg_temp.verifica('52d el detalle del reconsentido lo fijó la base (no el "prueba" del cliente)',
  $$SELECT detalle = 'reconsentimiento recabado: versión 3' FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'reconsentido' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P1')$$);
SELECT pg_temp.caso('52c reconsentido repetido de P1 -> SCJ11 transicion_invalida', 'authenticated', pg_temp.reconsent('P1', pg_temp.vig()), 'SCJ11', NULL, 'transicion_invalida');

-- F. Lote
SELECT pg_temp.caso('60 lote vacío -> 22023 lote_invalido', 'authenticated', format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[]::bigint[], %s)', pg_temp.vig()), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('60b lote NULL -> 22023 lote_invalido', 'authenticated', format('SELECT tiempo.fn_terminal_reconsentir(NULL::bigint[], %s)', pg_temp.vig()), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('60c lote de 201 altas -> 22023 lote_invalido', 'authenticated', format('SELECT tiempo.fn_terminal_reconsentir((SELECT array_agg(g::bigint) FROM generate_series(1, 201) g), %s)', pg_temp.vig()), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('60d lote con una versión antigua -> SCJ16 consentimiento_desactualizado', 'authenticated', format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[%s]::bigint[], %s)', pg_temp.tu('P2'), pg_temp.ver(2)), 'SCJ16', NULL, 'consentimiento_desactualizado');
SELECT pg_temp.caso('60e lote como anon -> 42501 (sin EXECUTE)', 'anon', format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[%s]::bigint[], %s)', pg_temp.tu('P2'), pg_temp.vig()), '42501', '-');
SELECT pg_temp.caso('60f lote ESTRICTO con altas no elegibles (P1 ya reconsintió, P4 en baja, un id inexistente) -> 22023 lote_no_elegible', 'authenticated',
  format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[%s, %s, %s, 999999999]::bigint[], %s, true)', pg_temp.tu('P2'), pg_temp.tu('P1'), pg_temp.tu('P4'), pg_temp.vig()), '22023', (SELECT v FROM _ens WHERE k='auth_rh'), 'lote_no_elegible');
SELECT pg_temp.verifica('60g ... y el estricto no registró NADA, ni siquiera la elegible P2 (todo o nada)',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'reconsentido'$$);
SELECT pg_temp.rpc('61 lote como RH: [P2, P3, P4, P1, id inexistente] -> registradas 2 (P2, P3); omitidas P1 (ya reconsintió), P4 (baja) e inexistente', 'authenticated',
  format('tiempo.fn_terminal_reconsentir(ARRAY[%s, %s, %s, %s, 999999999, %s]::bigint[], %s)', pg_temp.tu('P2'), pg_temp.tu('P3'), pg_temp.tu('P4'), pg_temp.tu('P1'), pg_temp.tu('P2'), pg_temp.vig()),
  $c$ ($1->>'registradas')::int = 2 AND $1->'omitidas' @> to_jsonb(ARRAY[pg_temp.tu('P1'), pg_temp.tu('P4'), 999999999]) AND jsonb_array_length($1->'omitidas') = 3 $c$, (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('61b P2 sigue en esperando_huella y P3 en pendiente_alta (el reconsentimiento no cambia estado), ambas con la versión 3',
  $$SELECT (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P2')) = 'esperando_huella'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P3')) = 'pendiente_alta'
      AND (SELECT count(*) FROM tiempo.terminal_usuario WHERE id IN (pg_temp.tu('P2'), pg_temp.tu('P3')) AND consentimiento_id = pg_temp.vig()::bigint) = 2$$);
SELECT pg_temp.verifica('61c un movimiento "reconsentido" por alta (3 en total: P1, P2, P3) y ninguno de baja',
  $$SELECT count(*) = 3 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'reconsentido'$$);
SELECT pg_temp.rpc('61d ya no quedan pendientes', 'service_role', $$to_jsonb((SELECT count(*) FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids()))$$, $c$ $1 = '0'::jsonb $c$, '-');
SELECT pg_temp.rpc('61e lote repetido: todo se omite, nada se registra', 'authenticated',
  format('tiempo.fn_terminal_reconsentir(ARRAY[%s, %s]::bigint[], %s)', pg_temp.tu('P2'), pg_temp.tu('P3'), pg_temp.vig()),
  $c$ ($1->>'registradas')::int = 0 AND jsonb_array_length($1->'omitidas') = 2 $c$, (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('61f el usuario sin permisos usa el lote -> 42501 sin_permiso (no un SCJ16 confuso)', 'authenticated',
  format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[%s]::bigint[], %s)', pg_temp.tu('P2'), pg_temp.vig()), '42501', (SELECT v FROM _ens WHERE k='auth_sin'), 'sin_permiso');

-- G. Nueva versión material -> vuelve a haber pendientes; las marcas NO se bloquean
SELECT pg_temp.rpc('70 publicar la versión 4 con cambio_material=true -> pendientes = 4 (P1, P2, P3 y P5; P4 está en baja)', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, true, %L)', 'Texto material v4', 'cambio de finalidad'),
  $c$ ($1->>'version')::int = 4 AND ($1->>'cambio_material')::boolean AND ($1->>'pendientes')::int = 4 $c$);
INSERT INTO _ens VALUES ('m0', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
SELECT pg_temp.rpc('71 un reconsentimiento pendiente NO bloquea marcas: la marca de P1 (pendiente) se confirma', 'service_role',
  format($f$tiempo.fn_marca_terminal_registrar(%s::bigint, %L::jsonb)$f$, (SELECT v FROM _ens WHERE k='terminal'),
         jsonb_build_array(jsonb_build_object('evento_id', gen_random_uuid(), 'employee_no', (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')),
           'secuencia_local', 1, 'momento_dispositivo', (SELECT v FROM _ens WHERE k = 'm0'), 'desfase_local', '-06:00', 'estado_reloj', 'sincronizado', 'version_software', '1.0.0'))::text),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.caso('72 un alta con reconsentimiento pendiente (P3) puede darse de baja sin reconsentir (baja_solicitada no exige versión)', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            SELECT tu.id, tu.terminal_id, tu.persona_id, 'baja_solicitada', 'web', %L::uuid FROM tiempo.terminal_usuario tu WHERE tu.id = %s$f$,
         (SELECT v FROM _ens WHERE k='auth_uid'), pg_temp.tu('P3')), 'ok');

-- H. Permisos de ejecución de las funciones internas
SELECT pg_temp.caso('80 función de trigger de la tabla nueva no es ejecutable por authenticated', 'authenticated', 'SELECT tiempo.fn_terminal_consentimiento_inmutable()', '42501');
SELECT pg_temp.caso('80b ... ni por service_role', 'service_role', 'SELECT tiempo.fn_terminal_consentimiento_truncate()', '42501', '-');
SELECT pg_temp.caso('80c fn_bitacora_terminal_usuario_aplica sigue sin EXECUTE para la API', 'authenticated', 'SELECT tiempo.fn_bitacora_terminal_usuario_aplica()', '42501');
SELECT pg_temp.caso('80d la lista de pendientes no es ejecutable por anon', 'anon', 'SELECT * FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids()', '42501', '-');

-- J. Auto-asignación prohibida salvo el administrador genérico (regla de seguridad llevada a la base)
INSERT INTO _ens SELECT 'seq_j', last_value::text FROM tiempo.seq_terminal_employee_no;
SELECT pg_temp.caso('90 RH (terminal_usuario_edicion) se asigna a SÍ MISMO (P5) -> SCJ12 auto_asignacion_prohibida', 'authenticated',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P5'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'auto_asignacion_prohibida');
SELECT pg_temp.verifica('90b ... sin efectos: no avanzó el employee_no y no hay segunda alta de P5', $$SELECT (SELECT last_value FROM tiempo.seq_terminal_employee_no) = (SELECT v::bigint FROM _ens WHERE k='seq_j') AND (SELECT count(*) FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P5')) = 1$$);
SELECT pg_temp.caso('90c RH asigna a OTRA persona (P6) -> ok', 'authenticated', pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P6'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('90d el administrador genérico SÍ puede asignarse a sí mismo -> ok', 'authenticated',
  pg_temp.asignar((SELECT v FROM _ens WHERE k='admin_persona'), pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('90e ... y quedó el alta propia del administrador', $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='admin_persona')$$);
SELECT pg_temp.caso('90f Gerente General (tiene terminal_usuario_edicion pero NO es administrador genérico) se asigna a sí mismo (P7) -> SCJ12 auto_asignacion_prohibida', 'authenticated',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P7'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_gg')), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_gg'), 'auto_asignacion_prohibida');
SELECT pg_temp.verifica('90f2 ... y ese rechazo tampoco quemó employee_no (secuencia igual a la de antes de 90d y 90c: sólo avanzó por las 2 altas válidas)',
  $$SELECT (SELECT last_value FROM tiempo.seq_terminal_employee_no) - (SELECT v::bigint FROM _ens WHERE k='seq_j') = 2$$);
SELECT pg_temp.caso('90g Gerente General asigna a OTRA persona (P7 no; P4 ya está en baja y puede reasignarse) -> ok', 'authenticated',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P4'), pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_gg')), 'ok', (SELECT v FROM _ens WHERE k='auth_gg'));
SELECT pg_temp.rpc('90h ayudas internas (como dueño): el usuario admin es administrador genérico y su persona coincide; RH y Gerente General no son administrador genérico', current_user::text,
  $$jsonb_build_array(personas.fn_usuario_es_administrador_generico((SELECT v::uuid FROM _ens WHERE k='auth_uid')), personas.fn_persona_de_usuario((SELECT v::uuid FROM _ens WHERE k='auth_uid')),
                      personas.fn_usuario_es_administrador_generico((SELECT v::uuid FROM _ens WHERE k='auth_rh')), personas.fn_usuario_es_administrador_generico((SELECT v::uuid FROM _ens WHERE k='auth_gg')))$$,
  $c$ $1->>0 = 'true' AND $1->>1 = (SELECT v FROM _ens WHERE k='admin_persona') AND $1->>2 = 'false' AND $1->>3 = 'false' $c$);
SELECT pg_temp.caso('90i las ayudas internas no son ejecutables por authenticated', 'authenticated', $$SELECT personas.fn_usuario_es_administrador_generico('00000000-0000-0000-0000-000000000000'::uuid)$$, '42501');
SELECT pg_temp.caso('90j ... ni por anon', 'anon', $$SELECT personas.fn_persona_de_usuario('00000000-0000-0000-0000-000000000000'::uuid)$$, '42501', '-');
SELECT pg_temp.caso('90k ... ni por service_role', 'service_role', $$SELECT personas.fn_persona_de_usuario('00000000-0000-0000-0000-000000000000'::uuid)$$, '42501', '-');

-- K. BAJO-2: nadie registra el reconsentimiento de su PROPIA alta (salvo el administrador genérico); pedir la propia baja sí se puede
SELECT pg_temp.caso('K0 el admin asigna a P7 (persona del usuario Gerente General) con la versión vigente -> ok', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='P7'), pg_temp.vig()), 'ok');
SELECT pg_temp.rpc('K1 el admin publica la versión 5 con cambio material -> todas las altas vivas quedan con el reconsentimiento pendiente', 'authenticated',
  format('tiempo.fn_terminal_consentimiento_publicar(%L, true, %L)', 'Texto material v5', 'cambio de finalidad 2'), $c$ ($1->>'version')::int = 5 AND ($1->>'pendientes')::int >= 6 $c$);
SELECT pg_temp.caso('K2 RH (no admin) registra el reconsentimiento de SU PROPIA alta (P5) -> SCJ12 auto_reconsentimiento_prohibido', 'authenticated',
  pg_temp.reconsent('P5', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'auto_reconsentimiento_prohibido');
SELECT pg_temp.verifica('K2b ... sin efectos: P5 conserva la versión 3 y no hay ningún reconsentido de P5',
  $$SELECT (SELECT consentimiento_id FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P5')) = pg_temp.ver(3)::bigint
      AND NOT EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'reconsentido' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P5'))$$);
SELECT pg_temp.caso('K3 Gerente General (no admin) registra el reconsentimiento de SU PROPIA alta (P7) -> SCJ12 auto_reconsentimiento_prohibido', 'authenticated',
  pg_temp.reconsent('P7', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_gg')), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_gg'), 'auto_reconsentimiento_prohibido');
SELECT pg_temp.caso('K4 el administrador genérico registra el reconsentimiento de SU PROPIA alta -> ok', 'authenticated', pg_temp.reconsent('admin_persona', pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('K4b ... y su alta quedó con la versión 5', $$SELECT consentimiento_id = pg_temp.vig()::bigint FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='admin_persona')$$);
SELECT pg_temp.caso('K5 RH registra el reconsentimiento de una alta AJENA (P1) -> ok', 'authenticated', pg_temp.reconsent('P1', pg_temp.vig(), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.rpc('K6 lote de RH con su alta propia (P5) y dos ajenas pendientes (P2, P6): se registran 2, P5 se omite con motivo alta_propia', 'authenticated',
  format('tiempo.fn_terminal_reconsentir(ARRAY[%s, %s, %s]::bigint[], %s)', pg_temp.tu('P5'), pg_temp.tu('P2'), pg_temp.tu('P6'), pg_temp.vig()),
  $c$ ($1->>'registradas')::int = 2 AND $1->'omitidas' = to_jsonb(ARRAY[pg_temp.tu('P5')]) AND $1->'motivos_omision'->>(pg_temp.tu('P5'))::text = 'alta_propia' $c$, (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('K6b ... P5 sigue sin reconsentir', $$SELECT consentimiento_id = pg_temp.ver(3)::bigint FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P5')$$);
SELECT pg_temp.caso('K7 lote ESTRICTO de RH que incluye su alta propia (P5) y una ajena pendiente (P4) -> 22023 lote_no_elegible y no registra nada', 'authenticated',
  format('SELECT tiempo.fn_terminal_reconsentir(ARRAY[%s, %s]::bigint[], %s, true)', pg_temp.tu('P5'), pg_temp.tu('P4'), pg_temp.vig()), '22023', (SELECT v FROM _ens WHERE k='auth_rh'), 'lote_no_elegible');
SELECT pg_temp.verifica('K7b ... P4 tampoco se reconsintió (todo o nada)', $$SELECT consentimiento_id <> pg_temp.vig()::bigint FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P4')$$);
SELECT pg_temp.rpc('K8 lote del administrador genérico con su alta propia ya al día y una ajena pendiente (P4): sólo se registra P4; la propia se omite por no estar pendiente (no por ser propia)', 'authenticated',
  format('tiempo.fn_terminal_reconsentir(ARRAY[%s, %s]::bigint[], %s)', (SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='admin_persona')), pg_temp.tu('P4'), pg_temp.vig()),
  $c$ ($1->>'registradas')::int = 1 AND (SELECT bool_and(m = 'no_elegible') FROM jsonb_each_text($1->'motivos_omision') AS t(k, m)) $c$);
SELECT pg_temp.caso('K9 RH pide su PROPIA baja (baja_solicitada de P5) -> ok (la prohibición es sólo para asignarse y reconsentirse)', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            SELECT tu.id, tu.terminal_id, tu.persona_id, 'baja_solicitada', 'web', %L::uuid FROM tiempo.terminal_usuario tu WHERE tu.id = %s$f$, (SELECT v FROM _ens WHERE k='auth_rh'), pg_temp.tu('P5')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('K10 las ayudas del llamador: ejecutables por authenticated, no por anon ni service_role', 'anon', 'SELECT personas.fn_caller_persona_id()', '42501', '-');
SELECT pg_temp.caso('K10b ... service_role', 'service_role', 'SELECT personas.fn_caller_es_administrador_generico()', '42501', '-');
SELECT pg_temp.rpc('K10c ... authenticated (RH: no es admin; admin: sí)', 'authenticated', $$jsonb_build_array(personas.fn_caller_es_administrador_generico(), personas.fn_caller_persona_id())$$,
  $c$ $1->>0 = 'false' $c$, (SELECT v FROM _ens WHERE k='auth_rh'));

-- I. Verificador acumulado hasta 88_ (extracto de db/verificar_ddl.sql: secciones 1 a 50, sin las de 89_)
\ir verificar_88.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
