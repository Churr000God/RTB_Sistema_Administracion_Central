-- Ensayo de 120_tiempo_movimiento_de_saldo_compensacion.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_120.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Datos SINTÉTICOS creados en la transacción y revertidos. Aplica SOLO 120_ (más lo que se indique en el archivo).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _vis (fase text, quien text, personas bigint, expedientes bigint);
GRANT ALL ON _ens, _res, _vis TO PUBLIC;
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

CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL) RETURNS void AS $$
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
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 120));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.mide(p_fase text, p_quien text, p_rol text, p_sub text) RETURNS void AS $$
DECLARE a bigint; b bigint;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_rol)::text, true);
  SELECT count(*) INTO a FROM personas.persona;
  SELECT count(*) INTO b FROM personas.expediente;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _vis VALUES (p_fase, p_quien, a, b);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.caso2(p_caso text, p_sub text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint), format('obtenido=%s hint=%s %s', v_state, v_hint, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- Ejecuta p_sql como el caller; si pasa, evalúa p_check (boolean, como dueño) sobre el estado resultante y revierte el caso.
CREATE FUNCTION pg_temp.exito(p_caso text, p_sub text, p_sql text, p_check text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := ''; v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE p_check INTO v_ok;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = 'ok' AND COALESCE(v_ok, false), format('estado=%s verificacion=%s %s', v_state, v_ok, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- ---------- fixture ----------
CREATE FUNCTION pg_temp.mk_persona(p_k text, p_n int, p_puesto text, p_permiso text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica120' || p_k, 'Ensayo120', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens120' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens120' || lower(p_k));
  IF p_puesto IS NOT NULL THEN
    INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
    SELECT departamento_id, p_puesto, 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
    IF p_permiso IS NOT NULL THEN
      INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
      SELECT id, p_permiso, 'otorgado' FROM personas.puesto WHERE nombre_puesto = p_puesto;
    END IF;
    INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
    SELECT (SELECT v::uuid FROM _ens WHERE k = p_k), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = p_puesto;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ---------- fixtures de bancos (sintéticos, como dueño) ----------
CREATE FUNCTION pg_temp.mk_banco(p_k text, p_movs jsonb) RETURNS void AS $$
DECLARE v_p uuid := gen_random_uuid(); v_b bigint; m record; v_id bigint;
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (v_p);
  INSERT INTO _ens VALUES ('P_' || p_k, v_p::text);
  INSERT INTO tiempo.banco_de_horas (persona_id) VALUES (v_p) RETURNING id INTO v_b;
  INSERT INTO _ens VALUES ('B_' || p_k, v_b::text);
  FOR m IN SELECT * FROM jsonb_to_recordset(p_movs) AS x(clave text, tipo text, monto numeric) LOOP
    INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo) VALUES (v_b, m.tipo, m.monto, 'ensayo') RETURNING id INTO v_id;
    INSERT INTO _ens VALUES ('M_' || p_k || '_' || m.clave, v_id::text);
  END LOOP;
END $$ LANGUAGE plpgsql;
SELECT pg_temp.mk_banco('X', '[{"clave":"gen","tipo":"generado_quincena","monto":20}]');
SELECT pg_temp.mk_banco('Y', '[{"clave":"gen","tipo":"generado_quincena","monto":20},{"clave":"cub","tipo":"cubrir","monto":-15}]');
SELECT pg_temp.mk_banco('Z', '[{"clave":"gen","tipo":"generado_quincena","monto":8},{"clave":"con","tipo":"condonar","monto":-3}]');
SELECT pg_temp.mk_banco('W', '[{"clave":"gen","tipo":"generado_quincena","monto":6}]');
SELECT pg_temp.mk_banco('V', '[{"clave":"gen","tipo":"generado_quincena","monto":9}]');   -- para el bloque de reaplicación (X y W ya quedaron en 0)
SELECT pg_temp.mk_banco('U', '[{"clave":"gen1","tipo":"generado_quincena","monto":20},{"clave":"gen2","tipo":"generado_quincena","monto":20}]');   -- saldo 40: permite probar el CHECK y el índice único sin que antes salte la validación de saldo

CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido = p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.saldo(p_k text) RETURNS numeric AS $$ SELECT monto FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'B_' || p_k) $$ LANGUAGE sql;
-- llamada al RPC como el actor p_sub (auth uid) sobre el movimiento M_<clave>
CREATE FUNCTION pg_temp.rpc(p_clave text, p_motivo text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_movimiento_de_saldo_compensar(%s, %L)', (SELECT v FROM _ens WHERE k = 'M_' || p_clave), p_motivo);
$$ LANGUAGE sql;
-- ejecuta y PERSISTE (dentro de la transacción del ensayo) como el actor, para encadenar casos
CREATE FUNCTION pg_temp.persiste(p_sub text, p_sql text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;

-- ---------- A) ANTES de 120_ (documenta el defecto: no hay forma de compensar) ----------
CREATE FUNCTION pg_temp.como_dueno(p_caso text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint), format('obtenido=%s hint=%s %s', v_state, v_hint, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;
SELECT pg_temp.como_dueno('A0 (defecto) ANTES de 120_: el ledger no admite el tipo compensacion (23514)',
  format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo) VALUES (%s, ''compensacion'', -20, ''x'')', (SELECT v FROM _ens WHERE k = 'B_X')), '23514');

\ir ../ddl/120_tiempo_movimiento_de_saldo_compensacion.sql

-- ---------- actores (después de 120_, que crea el permiso) ----------
SELECT pg_temp.mk_persona('CP', 1, 'ENS120 compensa', 'movimiento_de_saldo_compensar');
SELECT pg_temp.mk_persona('SP', 2, 'ENS120 sin permiso', 'movimiento_de_saldo_edicion');   -- tiene otro permiso del ledger, NO el de compensar
SELECT pg_temp.mk_persona('JF', 3, 'ENS120 jefe', NULL);
UPDATE personas.puesto SET reporta_a_id = (SELECT id FROM personas.puesto WHERE nombre_puesto = 'ENS120 jefe') WHERE nombre_puesto = 'ENS120 compensa';

-- ---------- B) RPC ----------
SELECT pg_temp.caso2('B1 sin el permiso (aunque tenga movimiento_de_saldo_edicion) => 42501', (SELECT v FROM _ens WHERE k = 'auth_SP'), pg_temp.rpc('X_gen', 'error del corte'), '42501');
SELECT pg_temp.caso2('B2 el JEFE del puesto con el permiso NO lo hereda (no heredable) => 42501', (SELECT v FROM _ens WHERE k = 'auth_JF'), pg_temp.rpc('X_gen', 'error del corte'), '42501');
SELECT pg_temp.caso2('B3 motivo en blanco => SCJ24 / motivo_obligatorio', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('X_gen', '   '), 'SCJ24', 'motivo_obligatorio');
SELECT pg_temp.caso2('B4 movimiento inexistente => SCJ24 / movimiento_inexistente', (SELECT v FROM _ens WHERE k = 'auth_CP'), 'SELECT tiempo.fn_movimiento_de_saldo_compensar(999999999, ''error del corte'')', 'SCJ24', 'movimiento_inexistente');
SELECT pg_temp.caso2('B5 compensar un movimiento que no es generado_quincena (condonar) => SCJ24 / no_compensable', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('Z_con', 'error del corte'), 'SCJ24', 'no_compensable');
SELECT pg_temp.caso2('B6 compensar un cubrir => SCJ24 / no_compensable', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('Y_cub', 'error del corte'), 'SCJ24', 'no_compensable');
SELECT pg_temp.caso2('B7 saldo insuficiente (gen 20 y cubrir -15: quedan 5 y compensar -20 los dejaría en -15) => SCJ24 / saldo_insuficiente', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('Y_gen', 'error del corte'), 'SCJ24', 'saldo_insuficiente');
SELECT pg_temp.igual('B8 antes de compensar el banco X tiene 20', pg_temp.saldo('X')::text, '20.00');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('X_gen', '  Error del corte 01-15 oct: permisos con goce contados como cero.  '));
SELECT pg_temp.igual('B9 compensar el generado_quincena de 20: el trigger de 104_ mueve el saldo a 0', pg_temp.saldo('X')::text, '0.00');
SELECT pg_temp.verifica('B10 la fila de compensación: tipo, monto exacto negativo, ligada al original, autor = persona de la sesión, motivo recortado, fecha',
  $$SELECT c.tipo = 'compensacion' AND c.monto = -20 AND c.compensa_movimiento_id = (SELECT v::bigint FROM _ens WHERE k = 'M_X_gen')
       AND c.autor_id = (SELECT v::uuid FROM _ens WHERE k = 'CP') AND c.motivo = 'Error del corte 01-15 oct: permisos con goce contados como cero.' AND c.creado_en IS NOT NULL
       AND c.banco_de_horas_id = (SELECT v::bigint FROM _ens WHERE k = 'B_X')
    FROM tiempo.movimiento_de_saldo c WHERE c.compensa_movimiento_id = (SELECT v::bigint FROM _ens WHERE k = 'M_X_gen')$$);
SELECT pg_temp.verifica('B11 vivo_desde vuelve a NULL cuando el saldo toca 0', $$SELECT vivo_desde IS NULL FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'B_X')$$);
SELECT pg_temp.caso2('B12 compensar OTRA VEZ el mismo movimiento => SCJ24 / ya_compensado', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('X_gen', 'otra vez'), 'SCJ24', 'ya_compensado');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('W_gen', 'error del corte, caso parcial'));
SELECT pg_temp.igual('B13 compensar un movimiento cuando el saldo es exactamente su monto (6) deja 0', pg_temp.saldo('W')::text, '0.00');
SELECT pg_temp.caso('B14 anon NO puede ejecutar el RPC', 'anon', pg_temp.rpc('Y_gen', 'x'), '42501');
SELECT pg_temp.caso('B15 service_role NO puede ejecutar el RPC (no hay auth.uid(): es una vía humana)', 'service_role', pg_temp.rpc('Y_gen', 'x'), '42501');

-- ---------- B2) más casos del RPC: banco propio (M1), tope del motivo (B2) ----------
-- banco PROPIO de CP: se crea como dueño (la persona ya existe en tiempo.persona por la sincronización con personas.persona)
INSERT INTO tiempo.banco_de_horas (persona_id) SELECT v::uuid FROM _ens WHERE k = 'CP';
INSERT INTO _ens SELECT 'B_OWN', id::text FROM tiempo.banco_de_horas WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'CP');
WITH ins AS (INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo) SELECT v::bigint, 'generado_quincena', 7, 'ensayo' FROM _ens WHERE k = 'B_OWN' RETURNING id)
INSERT INTO _ens SELECT 'M_OWN_gen', id::text FROM ins;
SELECT pg_temp.caso2('B16 M1: compensar un movimiento del banco PROPIO => SCJ24 / compensacion_propia (aunque tenga el permiso)', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('OWN_gen', 'intento de compensar lo propio'), 'SCJ24', 'compensacion_propia');
SELECT pg_temp.igual('B17 M1: el intento propio rechazado no movió el saldo (sigue 7)', (SELECT monto::text FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'B_OWN')), '7.00');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('U_gen1', 'error del corte, primer movimiento de U'));
SELECT pg_temp.igual('B18 U: compensar su primer generado (20) deja 20', pg_temp.saldo('U')::text, '20.00');
SELECT pg_temp.caso2('B19 B2: motivo de 501 caracteres => SCJ24 / motivo_demasiado_largo', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('U_gen2', repeat('x', 501)), 'SCJ24', 'motivo_demasiado_largo');
SELECT pg_temp.caso2('B20 B2: motivo de exactamente 500 caracteres => ok', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('U_gen2', repeat('x', 500)), 'ok');
SELECT pg_temp.caso2('B21 B2: motivo de 501 caracteres con espacios alrededor que se recortan a 500 => ok (el tope es sobre el motivo recortado)', (SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('U_gen2', '  ' || repeat('x', 500) || '  '), 'ok');

-- ---------- C) la base valida SEA CUAL SEA el camino de escritura (como dueño) ----------
CREATE FUNCTION pg_temp.ins_comp(p_banco text, p_compensa text, p_monto numeric, p_motivo text, p_autor text) RETURNS text AS $$
  SELECT format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id, compensa_movimiento_id) VALUES (%s, ''compensacion'', %s, %L, %L, %s)',
    (SELECT v FROM _ens WHERE k = 'B_' || p_banco), p_monto, p_motivo, p_autor, COALESCE((SELECT v FROM _ens WHERE k = 'M_' || p_compensa), 'NULL'));
$$ LANGUAGE sql;
SELECT pg_temp.como_dueno('C1 monto que no es el opuesto exacto => SCJ24', pg_temp.ins_comp('Y', 'Y_gen', -5, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'compensacion_no_coincide');
SELECT pg_temp.como_dueno('C2 compensación en OTRO banco que el del original => SCJ24', pg_temp.ins_comp('Z', 'Y_gen', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'compensacion_no_coincide');
SELECT pg_temp.como_dueno('C3 compensar un condonar => SCJ24', pg_temp.ins_comp('Z', 'Z_con', 3, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'no_compensable');
SELECT pg_temp.como_dueno('C4 monto positivo sobre un generado_quincena => SCJ24', pg_temp.ins_comp('Y', 'Y_gen', 20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'compensacion_no_coincide');
SELECT pg_temp.como_dueno('C5 B1: compensación por insert directo que dejaría el saldo negativo (Y tiene 5 y compensa -20) => SCJ24 / saldo_insuficiente', pg_temp.ins_comp('Y', 'Y_gen', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'saldo_insuficiente');
SELECT pg_temp.caso('C5b B1: también con service_role', 'service_role', pg_temp.ins_comp('Y', 'Y_gen', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24');
SELECT pg_temp.como_dueno('C5c B1: compensar dos veces el mismo movimiento cuando ya no hay saldo (X quedó en 0) => SCJ24 / saldo_insuficiente (salta antes que el índice único)', pg_temp.ins_comp('X', 'X_gen', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'saldo_insuficiente');
SELECT pg_temp.como_dueno('C5d el índice único parcial es el respaldo cuando SÍ hay saldo (U tiene 20 tras compensar gen1 y se vuelve a compensar gen1 con -20) => 23505', pg_temp.ins_comp('U', 'U_gen1', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), '23505');
SELECT pg_temp.como_dueno('C6 compensación con motivo en blanco (con saldo suficiente) => 23514', pg_temp.ins_comp('U', 'U_gen2', -20, '   ', (SELECT v FROM _ens WHERE k = 'CP')), '23514');
SELECT pg_temp.como_dueno('C6b B2: motivo de 501 caracteres por insert directo => 23514 (CHECK)', pg_temp.ins_comp('U', 'U_gen2', -20, repeat('x', 501), (SELECT v FROM _ens WHERE k = 'CP')), '23514');
SELECT pg_temp.como_dueno('C7 compensación sin autor (con saldo suficiente) => 23514', format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, compensa_movimiento_id) VALUES (%s, ''compensacion'', -20, ''x'', %s)', (SELECT v FROM _ens WHERE k = 'B_U'), (SELECT v FROM _ens WHERE k = 'M_U_gen2')), '23514');
SELECT pg_temp.como_dueno('C8 tipo compensacion sin compensa_movimiento_id => SCJ24 (movimiento inexistente)', format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, ''compensacion'', -20, ''x'', %L)', (SELECT v FROM _ens WHERE k = 'B_Y'), (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24', 'movimiento_inexistente');
SELECT pg_temp.como_dueno('C9 compensa_movimiento_id en un tipo que no es compensacion => 23514', format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, compensa_movimiento_id) VALUES (%s, ''generado_quincena'', 1, ''x'', %s)', (SELECT v FROM _ens WHERE k = 'B_Y'), (SELECT v FROM _ens WHERE k = 'M_Y_gen')), '23514');
SELECT pg_temp.caso('C10 service_role tampoco se salta la validación: monto incorrecto => SCJ24', 'service_role', pg_temp.ins_comp('Y', 'Y_gen', -5, 'x', (SELECT v FROM _ens WHERE k = 'CP')), 'SCJ24');
SELECT pg_temp.caso('C11 authenticated NO inserta directo en el ledger', 'authenticated', pg_temp.ins_comp('U', 'U_gen2', -20, 'x', (SELECT v FROM _ens WHERE k = 'CP')), '42501', (SELECT v FROM _ens WHERE k = 'auth_CP'));
SELECT pg_temp.caso('C12 authenticated NO actualiza el ledger', 'authenticated', 'UPDATE tiempo.movimiento_de_saldo SET motivo = ''x''', '42501', (SELECT v FROM _ens WHERE k = 'auth_CP'));
SELECT pg_temp.caso('C13 service_role NO borra del ledger', 'service_role', 'DELETE FROM tiempo.movimiento_de_saldo', '42501');

-- ---------- D) catálogo y estructura ----------
SELECT pg_temp.verifica('D1 el permiso movimiento_de_saldo_compensar existe y NO es heredable', $$SELECT NOT heredable FROM personas.permiso WHERE codigo = 'movimiento_de_saldo_compensar'$$);
SELECT pg_temp.verifica('D2 sembrado en Gerente General y Gerente o Encargado de TI, NO en Responsable de Recursos Humanos',
  $$SELECT (SELECT count(*) FROM personas.puesto_permiso pp JOIN personas.puesto pu ON pu.id = pp.puesto_id WHERE pp.codigo = 'movimiento_de_saldo_compensar' AND pp.activo AND pu.nombre_puesto IN ('Gerente General', 'Gerente o Encargado de TI')) = 2
      AND NOT EXISTS (SELECT 1 FROM personas.puesto_permiso pp JOIN personas.puesto pu ON pu.id = pp.puesto_id WHERE pp.codigo = 'movimiento_de_saldo_compensar' AND pp.activo AND pu.nombre_puesto = 'Responsable de Recursos Humanos')$$);
SELECT pg_temp.verifica('D3 todo puesto administrador genérico activo conserva el permiso nuevo (el administrador no pierde acceso)',
  $$SELECT NOT EXISTS (SELECT 1 FROM personas.puesto pu WHERE pu.es_administrador_generico AND pu.activo AND NOT EXISTS (SELECT 1 FROM personas.puesto_permiso pp WHERE pp.puesto_id = pu.id AND pp.codigo = 'movimiento_de_saldo_compensar' AND pp.activo))$$);
SELECT pg_temp.verifica('D4 el RPC es DEFINER con search_path fijo, autorización interna, autor desde auth.uid() y EXECUTE solo authenticated',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND p.prosrc LIKE '%fn_caller_tiene_permiso(''movimiento_de_saldo_compensar'')%' AND p.prosrc LIKE '%auth.uid()%'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_movimiento_de_saldo_compensar'$$);
SELECT pg_temp.verifica('D5 la función de trigger es DEFINER con search_path fijo y sin EXECUTE para nadie de la API',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_movimiento_compensacion_valida'$$);
SELECT pg_temp.verifica('D6 el trigger existe y está habilitado; los tipos anteriores siguen admitidos',
  $$SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.movimiento_de_saldo'::regclass AND tgname = 'trg_movimiento_compensacion_valida' AND tgenabled = 'O')
      AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ck_movimiento_de_saldo_tipo' AND conrelid = 'tiempo.movimiento_de_saldo'::regclass) LIKE '%generado_quincena%arrastrar%descontar%condonar%compensacion%'$$);

-- ---------- E) reversa y reaplicación ----------
DELETE FROM tiempo.movimiento_de_saldo WHERE tipo = 'compensacion';
DROP FUNCTION tiempo.fn_movimiento_de_saldo_compensar(bigint, text);
DROP TRIGGER trg_movimiento_compensacion_valida ON tiempo.movimiento_de_saldo;
DROP FUNCTION tiempo.fn_movimiento_compensacion_valida();
DROP INDEX tiempo.uq_movimiento_de_saldo_compensa;
ALTER TABLE tiempo.movimiento_de_saldo DROP CONSTRAINT ck_movimiento_de_saldo_compensacion;
ALTER TABLE tiempo.movimiento_de_saldo DROP COLUMN compensa_movimiento_id;
ALTER TABLE tiempo.movimiento_de_saldo DROP CONSTRAINT ck_movimiento_de_saldo_tipo;
ALTER TABLE tiempo.movimiento_de_saldo ADD CONSTRAINT ck_movimiento_de_saldo_tipo CHECK (tipo IN ('generado_quincena', 'cubrir', 'arrastrar', 'descontar', 'condonar'));
SELECT pg_temp.como_dueno('E1 tras la reversa vuelve el defecto (tipo compensacion => 23514)',
  format('INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo) VALUES (%s, ''compensacion'', -20, ''x'')', (SELECT v FROM _ens WHERE k = 'B_X')), '23514');
\ir ../ddl/120_tiempo_movimiento_de_saldo_compensacion.sql
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_CP'), pg_temp.rpc('V_gen', 'reaplicada'));
SELECT pg_temp.verifica('E2 reaplicable: la compensación vuelve a funcionar y el permiso/siembra no se duplicaron',
  $$SELECT EXISTS (SELECT 1 FROM tiempo.movimiento_de_saldo WHERE tipo = 'compensacion' AND compensa_movimiento_id = (SELECT v::bigint FROM _ens WHERE k = 'M_V_gen'))
      AND (SELECT count(*) FROM personas.puesto_permiso pp WHERE pp.codigo = 'movimiento_de_saldo_compensar' AND pp.activo AND pp.puesto_id IN (SELECT id FROM personas.puesto WHERE nombre_puesto IN ('Gerente General', 'Gerente o Encargado de TI'))) = 2$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
