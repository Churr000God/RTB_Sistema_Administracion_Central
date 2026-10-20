-- Ensayo de 118_tiempo_ausencia_jornada_neta_con_minutos_comida.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_118.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Datos SINTÉTICOS creados en la transacción y revertidos. Aplica SOLO 118_ (más lo que se indique en el archivo).
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica118' || p_k, 'Ensayo118', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens118' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens118' || lower(p_k));
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

-- ---------- fixtures de Tiempo (sintéticos) ----------
-- p_k: clave; p_tipo: tipo_jornada; filas: jsonb [{dia, entrada, salida, comida}]. Jornada vigente desde 2026-01-01.
CREATE FUNCTION pg_temp.mk_tiempo(p_k text, p_tipo text, p_filas jsonb) RETURNS void AS $$
DECLARE v_id uuid := gen_random_uuid(); v_j bigint; f record;
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (v_id);
  INSERT INTO _ens VALUES ('T_' || p_k, v_id::text);
  INSERT INTO tiempo.jornada_asignada (persona_id, tipo_jornada, vigente_desde) VALUES (v_id, p_tipo, DATE '2026-01-01') RETURNING id INTO v_j;
  FOR f IN SELECT * FROM jsonb_to_recordset(p_filas) AS x(dia text, entrada time, salida time, comida int) LOOP
    INSERT INTO tiempo.patron_semanal (jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida) VALUES (v_j, f.dia, f.entrada, f.salida, f.comida);
  END LOOP;
END $$ LANGUAGE plpgsql;

-- inserta la ausencia (dispara trg_ausencia_resuelve_excepcion) y devuelve las horas_totales del día de prueba (lunes 2026-10-05) o 'NULL'
CREATE FUNCTION pg_temp.ausencia(p_k text, p_tipo text, p_estado text, p_fecha date DEFAULT DATE '2026-10-05') RETURNS text AS $$
DECLARE v_h text;
BEGIN
  INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion)
  VALUES ((SELECT v::uuid FROM _ens WHERE k = 'T_' || p_k), p_tipo, p_fecha, p_fecha, p_estado);
  SELECT COALESCE(d.horas_totales::text, 'NULL') INTO v_h FROM tiempo.dia d
   WHERE d.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'T_' || p_k) AND d.fecha = p_fecha AND d.origen = 'ausencia_autorizada';
  RETURN COALESCE(v_h, 'SIN_DIA');
END $$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido = p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;

SELECT pg_temp.mk_tiempo('A', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');                                                  -- 9 h - 30 min = 8.50
SELECT pg_temp.mk_tiempo('B', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"13:00","comida":0},{"dia":"lunes","entrada":"15:00","salida":"19:00","comida":30}]'); -- partida: 5 + 3.5 = 8.50
SELECT pg_temp.mk_tiempo('C', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":60}]');                                                  -- 8.00 (coincidía con el descuento global)
SELECT pg_temp.mk_tiempo('D', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('E', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('F', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('G', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('H', 'de_confianza', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('I', 'de_confianza', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('J', 'de_confianza', '[{"dia":"martes","entrada":"08:00","salida":"17:00","comida":30}]');  -- sin patrón el lunes
SELECT pg_temp.mk_tiempo('K', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('L', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.mk_tiempo('M', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');

-- ---------- A) ANTES de 118_ (documenta el defecto: función de 66_) ----------
SELECT pg_temp.igual('A0 (defecto) ANTES de 118_: permiso con goce de un lunes 08–17 con comida de 30 min guarda 8.00 (descuento global de 60) y no 8.50',
  pg_temp.ausencia('A', 'permiso_con_goce', 'autorizada'), '8.00');
CREATE TEMP TABLE _def AS SELECT md5(p.prosrc) AS h_antes, p.proacl::text AS acl_antes
  FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_ausencia_resuelve_excepcion';

\ir ../ddl/118_tiempo_ausencia_jornada_neta_con_minutos_comida.sql

-- ---------- B) después de 118_ ----------
SELECT pg_temp.igual('B1 permiso con goce, una fila 08–17, comida 30 => 8.50 (igual que el corte)', pg_temp.ausencia('D', 'permiso_con_goce', 'autorizada'), '8.50');
SELECT pg_temp.igual('B2 jornada partida (08–13 sin comida + 15–19 con 30 min) => 8.50', pg_temp.ausencia('B', 'permiso_con_goce', 'autorizada'), '8.50');
SELECT pg_temp.igual('B3 comida de 60 min (9 h) => 8.00', pg_temp.ausencia('C', 'permiso_con_goce', 'autorizada'), '8.00');
SELECT pg_temp.igual('B4 vacaciones autorizadas => 8.50', pg_temp.ausencia('E', 'vacaciones', 'autorizada'), '8.50');
SELECT pg_temp.igual('B5 incapacidad autorizada => 8.50', pg_temp.ausencia('F', 'incapacidad', 'autorizada'), '8.50');
SELECT pg_temp.igual('B6 permiso sin goce autorizado => 0', pg_temp.ausencia('G', 'permiso_sin_goce', 'autorizada'), '0.00');
SELECT pg_temp.igual('B7 falta rechazada (jornada normal) => 0', pg_temp.ausencia('K', 'falta', 'rechazada'), '0.00');
SELECT pg_temp.igual('B8 de_confianza, ausencia autorizada => jornada neta 8.50', pg_temp.ausencia('H', 'permiso_con_goce', 'autorizada'), '8.50');
SELECT pg_temp.igual('B9 de_confianza, ausencia RECHAZADA => 8.50 (excepción deliberada de 66_, nunca 0)', pg_temp.ausencia('I', 'falta', 'rechazada'), '8.50');
SELECT pg_temp.igual('B10 de_confianza sin patrón ese día => NULL (nunca 0)', pg_temp.ausencia('J', 'permiso_con_goce', 'autorizada'), 'NULL');
SELECT pg_temp.igual('B11 jornada normal sin patrón ese día (sábado 2026-10-10) con permiso con goce => 0', pg_temp.ausencia('L', 'permiso_con_goce', 'autorizada', DATE '2026-10-10'), '0.00');
-- un día que ya no está abierto no se pisa
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'T_M'), DATE '2026-10-05', 'cerrado', 5.00);
SELECT pg_temp.ausencia('M', 'permiso_con_goce', 'autorizada');
SELECT pg_temp.verifica('B12 un día ya cerrado (5.00) NO se sobrescribe',
  $$SELECT d.horas_totales = 5.00 AND d.origen IS NULL FROM tiempo.dia d WHERE d.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'T_M') AND d.fecha = DATE '2026-10-05'$$);
SELECT pg_temp.verifica('B13 paridad con el corte: la fórmula SQL de las 3 jornadas A, B y C da lo mismo que corte_quincenal.py::_horas_patron_fila (suma por fila de salida - entrada - minutos_comida)',
  $$SELECT (SELECT sum(EXTRACT(EPOCH FROM (ps.hora_salida - ps.hora_entrada)) / 3600.0 - ps.minutos_comida / 60.0) FROM tiempo.patron_semanal ps JOIN tiempo.jornada_asignada j ON j.id = ps.jornada_asignada_id
            WHERE j.persona_id IN ((SELECT v::uuid FROM _ens WHERE k = 'T_A'), (SELECT v::uuid FROM _ens WHERE k = 'T_B'), (SELECT v::uuid FROM _ens WHERE k = 'T_C'))) = 8.5 + 8.5 + 8.0$$);
SELECT pg_temp.verifica('B14 sigue SECURITY DEFINER con search_path = tiempo, pg_temp, sin EXECUTE para nadie de la API, usa minutos_comida y ya no lee el descuento global',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND p.prosrc LIKE '%minutos_comida%' AND p.prosrc NOT LIKE '%descuento_pausa_no_registrada_min%'
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND p.proacl::text IS NOT DISTINCT FROM (SELECT acl_antes FROM _def)
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_ausencia_resuelve_excepcion'$$);

-- ---------- C) reversa (cuerpo de 66_) y reaplicación ----------
\ir ../ddl/66_tiempo_ausencia_descuento_pausa_y_confianza.sql
SELECT pg_temp.mk_tiempo('N', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.igual('C1 tras la reversa (66_) vuelve el defecto: 8.00', pg_temp.ausencia('N', 'permiso_con_goce', 'autorizada'), '8.00');
SELECT pg_temp.verifica('C2 tras la reversa sigue DEFINER con search_path fijo (CREATE OR REPLACE de 66_ lo repite)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_ausencia_resuelve_excepcion'$$);
\ir ../ddl/118_tiempo_ausencia_jornada_neta_con_minutos_comida.sql
SELECT pg_temp.mk_tiempo('O', 'normal', '[{"dia":"lunes","entrada":"08:00","salida":"17:00","comida":30}]');
SELECT pg_temp.igual('C3 reaplicable: vuelve a 8.50', pg_temp.ausencia('O', 'permiso_con_goce', 'autorizada'), '8.50');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
