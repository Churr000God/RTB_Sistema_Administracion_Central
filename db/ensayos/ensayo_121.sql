-- Ensayo de 121_tiempo_ausencia_tipo_inmutable_al_resolverse.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_121.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Datos SINTÉTICOS creados en la transacción y revertidos. Aplica SOLO 121_.
-- ROLLBACK descarta). El administrador real solo es caller. Cada rol se mide con SET ROLE authenticated + claims con su auth uid: cuántas filas VE de persona, expediente, usuario y asignacion.
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica121' || p_k, 'Ensayo121', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens121' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens121' || lower(p_k));
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

-- ---------- fixtures ----------
CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido = p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;
-- ausencia sintética: p_k clave; p_estado inicial; p_tipo. Persona tiempo.persona nueva por ausencia.
CREATE FUNCTION pg_temp.mk_ausencia(p_k text, p_tipo text, p_estado text, p_inicio date) RETURNS void AS $$
DECLARE v_p uuid := gen_random_uuid(); v_a bigint;
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (v_p);
  INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion) VALUES (v_p, p_tipo, p_inicio, p_inicio, p_estado) RETURNING id INTO v_a;
  INSERT INTO _ens VALUES ('A_' || p_k, v_a::text);
END $$ LANGUAGE plpgsql;
SELECT pg_temp.mk_ausencia('PEN', 'falta', 'pendiente', DATE '2026-11-02');
SELECT pg_temp.mk_ausencia('AUT', 'permiso_sin_goce', 'autorizada', DATE '2026-11-03');
SELECT pg_temp.mk_ausencia('REC', 'falta', 'rechazada', DATE '2026-11-04');
SELECT pg_temp.mk_ausencia('RES', 'falta', 'pendiente', DATE '2026-11-05');    -- para fn_ausencia_resolver
SELECT pg_temp.mk_ausencia('RE2', 'falta', 'pendiente', DATE '2026-11-06');    -- para fn_ausencia_resolver con rechazo

SELECT pg_temp.mk_persona('AE', 1, 'ENS121 ausencias', 'ausencia_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT pu.id, c.codigo, 'otorgado' FROM personas.puesto pu CROSS JOIN (VALUES ('ausencia_lectura'), ('aprobacion_ausencia_edicion'), ('aprobacion_ausencia_lectura')) c(codigo) WHERE pu.nombre_puesto = 'ENS121 ausencias';

-- filas afectadas por un UPDATE ejecutado como authenticated (la policy filtra sin error); revierte el caso
CREATE FUNCTION pg_temp.filas_auth(p_sub text, p_sql text) RETURNS text AS $$
DECLARE v_n bigint := -1; v_err text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_err := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  RETURN CASE WHEN v_err <> '' THEN 'error:' || v_err ELSE v_n::text END;
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.upd_tipo(p_clave text, p_tipo text) RETURNS text AS $$
  SELECT format('UPDATE tiempo.ausencia SET tipo_de_ausencia = %L WHERE id = %s', p_tipo, (SELECT v FROM _ens WHERE k = 'A_' || p_clave));
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.tipo_de(p_clave text) RETURNS text AS $$ SELECT tipo_de_ausencia FROM tiempo.ausencia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'A_' || p_clave) $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.persiste(p_sub text, p_sql text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;

-- ---------- A) ANTES de 121_ (documenta el defecto) ----------
SELECT pg_temp.igual('A0 (defecto) ANTES de 121_: authenticated con ausencia_edicion SÍ cambia el tipo de una ausencia YA AUTORIZADA (1 fila)',
  pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('AUT', 'permiso_con_goce')), '1');
SELECT pg_temp.caso('A1 (defecto) ANTES de 121_: service_role también', 'service_role', pg_temp.upd_tipo('AUT', 'vacaciones'), 'ok');

\ir ../ddl/121_tiempo_ausencia_tipo_inmutable_al_resolverse.sql

-- ---------- B) después de 121_ ----------
SELECT pg_temp.igual('B1 authenticated cambia el tipo de una ausencia PENDIENTE (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('PEN', 'vacaciones')), '1');
SELECT pg_temp.igual('B2 authenticated NO cambia el tipo de una AUTORIZADA (la policy filtra: 0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('AUT', 'permiso_con_goce')), '0');
SELECT pg_temp.igual('B3 authenticated NO cambia el tipo de una RECHAZADA (0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('REC', 'permiso_con_goce')), '0');
SELECT pg_temp.igual('B4 el tipo de la autorizada no cambió', pg_temp.tipo_de('AUT'), 'vacaciones');   -- 'vacaciones' lo dejó A1; lo importante es que B2 no lo movió a permiso_con_goce
SELECT pg_temp.caso2('B5 authenticated NO cambia la autorizada ni siquiera si además cambia el estado (sin permiso de columna sobre estado_autorizacion => 42501)', (SELECT v FROM _ens WHERE k = 'auth_AE'),
  format('UPDATE tiempo.ausencia SET tipo_de_ausencia = ''permiso_con_goce'', estado_autorizacion = ''pendiente'' WHERE id = %s', (SELECT v FROM _ens WHERE k = 'A_AUT')), '42501');
CREATE FUNCTION pg_temp.como_dueno_121(p_caso text, p_sql text, p_state text) RETURNS void AS $$
DECLARE v_state text := 'ok';
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_state := SQLSTATE;
  END;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state, format('obtenido=%s', v_state));
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.caso_svc(p_caso text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  SET LOCAL ROLE service_role;
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
SELECT pg_temp.caso_svc('B6 service_role NO cambia el tipo de una AUTORIZADA => SCJ25 / ausencia_resuelta_tipo_inmutable', pg_temp.upd_tipo('AUT', 'permiso_con_goce'), 'SCJ25', 'ausencia_resuelta_tipo_inmutable');
SELECT pg_temp.caso_svc('B7 service_role NO cambia el tipo de una RECHAZADA => SCJ25', pg_temp.upd_tipo('REC', 'permiso_con_goce'), 'SCJ25', 'ausencia_resuelta_tipo_inmutable');
SELECT pg_temp.caso_svc('B8 service_role SÍ cambia el tipo de una PENDIENTE', pg_temp.upd_tipo('PEN', 'incapacidad'), 'ok');
SELECT pg_temp.caso_svc('B9 service_role: un SET al MISMO valor en una autorizada pasa (no hay cambio real)', pg_temp.upd_tipo('AUT', 'vacaciones'), 'ok');
SELECT pg_temp.caso_svc('B10 service_role: tocar otra columna de una autorizada no dispara el trigger (es OF tipo_de_ausencia)',
  format('UPDATE tiempo.ausencia SET documento_ref = ''RTB-X-1'' WHERE id = %s', (SELECT v FROM _ens WHERE k = 'A_AUT')), 'ok');
SELECT pg_temp.como_dueno_121('B11 el dueño tampoco puede cambiar el tipo de una autorizada', pg_temp.upd_tipo('AUT', 'permiso_con_goce'), 'SCJ25');

-- ---------- C) la reclasificación legítima sigue funcionando: fn_ausencia_resolver ----------
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AE'), format('SELECT tiempo.fn_ausencia_resolver(%s, ''autorizada'', ''permiso_con_goce'', ''ensayo'')', (SELECT v FROM _ens WHERE k = 'A_RES')));
SELECT pg_temp.igual('C1 fn_ausencia_resolver reclasifica y autoriza: tipo permiso_con_goce y estado autorizada',
  (SELECT tipo_de_ausencia || '/' || estado_autorizacion FROM tiempo.ausencia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'A_RES')), 'permiso_con_goce/autorizada');
SELECT pg_temp.verifica('C2 quedó el paso de aprobación y se materializó el día de la ausencia',
  $$SELECT EXISTS (SELECT 1 FROM tiempo.aprobacion_ausencia WHERE ausencia_id = (SELECT v::bigint FROM _ens WHERE k = 'A_RES') AND decision = 'autorizada')
      AND EXISTS (SELECT 1 FROM tiempo.dia d JOIN tiempo.ausencia a ON a.persona_id = d.persona_id AND d.fecha = a.fecha_inicio WHERE a.id = (SELECT v::bigint FROM _ens WHERE k = 'A_RES') AND d.origen = 'ausencia_autorizada')$$);
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AE'), format('SELECT tiempo.fn_ausencia_resolver(%s, ''rechazada'', NULL, ''ensayo'')', (SELECT v FROM _ens WHERE k = 'A_RE2')));
SELECT pg_temp.igual('C3 fn_ausencia_resolver con rechazo: estado rechazada', (SELECT estado_autorizacion FROM tiempo.ausencia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'A_RE2')), 'rechazada');
SELECT pg_temp.caso2('C4 resolver otra vez una ya resuelta sigue dando SCJ03 (no SCJ25)', (SELECT v FROM _ens WHERE k = 'auth_AE'),
  format('SELECT tiempo.fn_ausencia_resolver(%s, ''autorizada'', ''vacaciones'', ''otra vez'')', (SELECT v FROM _ens WHERE k = 'A_RES')), 'SCJ03');
SELECT pg_temp.igual('C5 tras resolverse, authenticated ya no cambia su tipo (0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('RES', 'vacaciones')), '0');

-- ---------- D) estructura ----------
SELECT pg_temp.verifica('D1 la policy exige estado pendiente en USING y WITH CHECK, para authenticated y UPDATE',
  $$SELECT count(*) = 1 AND bool_and(cmd = 'UPDATE' AND roles = '{authenticated}' AND qual LIKE '%pendiente%' AND with_check LIKE '%pendiente%' AND qual LIKE '%ausencia_edicion%' AND with_check LIKE '%ausencia_edicion%')
    FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'ausencia' AND policyname = 'ausencia_update_requiere_permiso'$$);
SELECT pg_temp.verifica('D2 tiempo.ausencia conserva sus 2 policies (select y update; no hay de insert, la ausencia nace por service_role) y el GRANT de columna sigue siendo solo tipo_de_ausencia para authenticated',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'ausencia') = 2
      AND has_column_privilege('authenticated', 'tiempo.ausencia', 'tipo_de_ausencia', 'UPDATE') AND NOT has_column_privilege('authenticated', 'tiempo.ausencia', 'estado_autorizacion', 'UPDATE')$$);
SELECT pg_temp.verifica('D3 la función del trigger no tiene EXECUTE para nadie, es INVOKER y con search_path fijo; el trigger está habilitado',
  $$SELECT NOT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
      AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.ausencia'::regclass AND tgname = 'trg_ausencia_bloquea_cambio_tipo_resuelta' AND tgenabled = 'O')
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_ausencia_bloquea_cambio_tipo_resuelta'$$);

-- ---------- E) reversa (texto de 49_) y reaplicación ----------
DROP TRIGGER trg_ausencia_bloquea_cambio_tipo_resuelta ON tiempo.ausencia;
DROP FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta();
DROP POLICY ausencia_update_requiere_permiso ON tiempo.ausencia;
CREATE POLICY ausencia_update_requiere_permiso ON tiempo.ausencia FOR UPDATE TO authenticated
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'))
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'));
SELECT pg_temp.igual('E1 tras la reversa vuelve el defecto: authenticated cambia el tipo de una autorizada (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('AUT', 'permiso_con_goce')), '1');
\ir ../ddl/121_tiempo_ausencia_tipo_inmutable_al_resolverse.sql
SELECT pg_temp.igual('E2 reaplicable: vuelve a bloquear (0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('AUT', 'permiso_con_goce')), '0');
SELECT pg_temp.caso_svc('E3 reaplicable: service_role vuelve a recibir SCJ25', pg_temp.upd_tipo('AUT', 'permiso_con_goce'), 'SCJ25');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
