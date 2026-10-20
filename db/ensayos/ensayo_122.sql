-- Ensayo de 122_tiempo_ausencia_nadie_resuelve_la_propia.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_122.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Datos SINTÉTICOS creados en la transacción y revertidos. Aplica SOLO 122_.
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica122' || p_k, 'Ensayo122', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens122' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens122' || lower(p_k));
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
-- AE y AF: ausencia_edicion (reclasificar) + aprobacion_ausencia_edicion (resolver) + sus lecturas
SELECT pg_temp.mk_persona('AE', 1, 'ENS122 resuelve A', 'ausencia_edicion');
SELECT pg_temp.mk_persona('AF', 2, 'ENS122 resuelve B', 'ausencia_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT pu.id, c.codigo, 'otorgado' FROM personas.puesto pu CROSS JOIN (VALUES ('ausencia_lectura'), ('aprobacion_ausencia_edicion'), ('aprobacion_ausencia_lectura')) c(codigo)
WHERE pu.nombre_puesto IN ('ENS122 resuelve A', 'ENS122 resuelve B');
-- ausencias pendientes: OWN = de AE; T1..T4 = de terceros (persona tiempo.persona nueva)
CREATE FUNCTION pg_temp.mk_aus(p_k text, p_persona uuid, p_fecha date) RETURNS void AS $$
DECLARE v_p uuid := COALESCE(p_persona, gen_random_uuid()); v_a bigint;
BEGIN
  IF p_persona IS NULL THEN INSERT INTO tiempo.persona (id) VALUES (v_p); END IF;
  INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion) VALUES (v_p, 'falta', p_fecha, p_fecha, 'pendiente') RETURNING id INTO v_a;
  INSERT INTO _ens VALUES ('A_' || p_k, v_a::text);
END $$ LANGUAGE plpgsql;
SELECT pg_temp.mk_aus('OWN', (SELECT v::uuid FROM _ens WHERE k = 'AE'), DATE '2026-11-02');
SELECT pg_temp.mk_aus('T1', NULL, DATE '2026-11-03');
SELECT pg_temp.mk_aus('T2', NULL, DATE '2026-11-04');
SELECT pg_temp.mk_aus('T3', NULL, DATE '2026-11-05');
SELECT pg_temp.mk_aus('T4', NULL, DATE '2026-11-06');

CREATE FUNCTION pg_temp.resolver(p_clave text, p_decision text, p_tipo text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_ausencia_resolver(%s, %L, %L, ''ensayo'')', (SELECT v FROM _ens WHERE k = 'A_' || p_clave), p_decision, p_tipo);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.ins_aprob(p_clave text, p_aprobador text) RETURNS text AS $$
  SELECT format('INSERT INTO tiempo.aprobacion_ausencia (ausencia_id, numero_paso, aprobador_id, decision, motivo, decidido_en) VALUES (%s, 1, %L, ''autorizada'', ''ensayo'', now())',
    (SELECT v FROM _ens WHERE k = 'A_' || p_clave), p_aprobador);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.persiste(p_sub text, p_sql text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;
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
CREATE FUNCTION pg_temp.estado_de(p_clave text) RETURNS text AS $$
  SELECT estado_autorizacion || '/' || tipo_de_ausencia || '/' || (SELECT count(*) FROM tiempo.aprobacion_ausencia WHERE ausencia_id = a.id)
  FROM tiempo.ausencia a WHERE a.id = (SELECT v::bigint FROM _ens WHERE k = 'A_' || p_clave)
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.caso_svc(p_caso text, p_sql text, p_state text, p_hint text DEFAULT NULL, p_dueno boolean DEFAULT false) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  IF NOT p_dueno THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    SET LOCAL ROLE service_role;
  END IF;
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  IF NOT p_dueno THEN RESET ROLE; PERFORM set_config('request.jwt.claims', '', true); END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint), format('obtenido=%s hint=%s %s', v_state, v_hint, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- ---------- A) ANTES de 122_ (documenta el defecto) ----------
SELECT pg_temp.caso2('A0 (defecto) ANTES de 122_: AE resuelve su PROPIA ausencia por el RPC => funciona', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('OWN', 'autorizada', 'permiso_con_goce'), 'ok');
SELECT pg_temp.caso2('A1 (defecto) ANTES de 122_: AE registra una aprobación a nombre de OTRA persona (AF) en una ausencia ajena por PostgREST directo => funciona', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.ins_aprob('T4', (SELECT v FROM _ens WHERE k = 'AF')), 'ok');

SELECT pg_temp.igual('A2 (defecto) ANTES de 122_: AE SÍ edita el tipo de SU PROPIA ausencia pendiente (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('OWN', 'permiso_con_goce')), '1');

\ir ../ddl/122_tiempo_ausencia_nadie_resuelve_la_propia.sql

-- ---------- B) después de 122_ ----------
SELECT pg_temp.caso2('B1 el RPC: AE resuelve su PROPIA ausencia => SCJ26 / ausencia_propia', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('OWN', 'autorizada', 'permiso_con_goce'), 'SCJ26', 'ausencia_propia');
SELECT pg_temp.caso2('B1b el RPC también al RECHAZAR la propia => SCJ26', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('OWN', 'rechazada', NULL), 'SCJ26', 'ausencia_propia');
SELECT pg_temp.igual('B1c el intento rechazado no escribió nada: la propia sigue pendiente, tipo falta y sin pasos', pg_temp.estado_de('OWN'), 'pendiente/falta/0');
SELECT pg_temp.igual('B1d BAJO 1: AE NO edita el tipo de SU PROPIA ausencia pendiente (la policy filtra: 0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('OWN', 'permiso_con_goce')), '0');
SELECT pg_temp.igual('B1e BAJO 1: AE SÍ edita el tipo de una ausencia pendiente AJENA (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('T4', 'permiso_con_goce')), '1');
SELECT pg_temp.igual('B1f BAJO 1: AF (otra persona) SÍ edita el tipo de la pendiente de AE (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AF'), pg_temp.upd_tipo('OWN', 'permiso_con_goce')), '1');
SELECT pg_temp.caso2('B2 INSERT directo de la aprobación de la propia ausencia, aprobador = el mismo AE => SCJ26', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.ins_aprob('OWN', (SELECT v FROM _ens WHERE k = 'AE')), 'SCJ26', 'ausencia_propia');
SELECT pg_temp.caso2('B3 INSERT directo a nombre de OTRA persona (aprobador = AF) en la ausencia de un tercero => 42501 (la policy exige aprobador = persona del caller)', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.ins_aprob('T4', (SELECT v FROM _ens WHERE k = 'AF')), '42501');
SELECT pg_temp.caso2('B4 INSERT directo a nombre de AF sobre la ausencia de AE => 42501 (no se puede esquivar el bloqueo poniendo a otro de aprobador)', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.ins_aprob('OWN', (SELECT v FROM _ens WHERE k = 'AF')), '42501');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.ins_aprob('T1', (SELECT v FROM _ens WHERE k = 'AE')));
SELECT pg_temp.igual('B5 INSERT directo legítimo (aprobador = el caller, ausencia de un tercero) funciona y la ausencia queda autorizada', pg_temp.estado_de('T1'), 'autorizada/falta/1');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('T2', 'autorizada', 'permiso_con_goce'));
SELECT pg_temp.igual('B6 el RPC con la ausencia de OTRA persona sigue funcionando: reclasifica y autoriza', pg_temp.estado_de('T2'), 'autorizada/permiso_con_goce/1');
SELECT pg_temp.verifica('B6b se materializó el día de la ausencia resuelta (origen ausencia_autorizada)',
  $$SELECT EXISTS (SELECT 1 FROM tiempo.dia d JOIN tiempo.ausencia a ON a.persona_id = d.persona_id AND d.fecha = a.fecha_inicio WHERE a.id = (SELECT v::bigint FROM _ens WHERE k = 'A_T2') AND d.origen = 'ausencia_autorizada')$$);
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AF'), pg_temp.resolver('T3', 'rechazada', NULL));
SELECT pg_temp.igual('B7 el RPC con rechazo de una ausencia ajena funciona', pg_temp.estado_de('T3'), 'rechazada/falta/1');
SELECT pg_temp.caso2('B8 resolver una ya resuelta sigue dando SCJ03', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('T2', 'autorizada', 'vacaciones'), 'SCJ03');
SELECT pg_temp.caso2('B9 ausencia inexistente sigue dando SCJ02', (SELECT v FROM _ens WHERE k = 'auth_AE'), 'SELECT tiempo.fn_ausencia_resolver(999999999, ''autorizada'', ''vacaciones'', ''x'')', 'SCJ02');
SELECT pg_temp.caso2('B10 tipo inválido al autorizar una ajena sigue dando SCJ04', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('T4', 'autorizada', 'falta'), 'SCJ04');
SELECT pg_temp.caso_svc('B11 service_role tampoco puede registrar la aprobación de la propia ausencia (aprobador = su dueña) => SCJ26', pg_temp.ins_aprob('OWN', (SELECT v FROM _ens WHERE k = 'AE')), 'SCJ26', 'ausencia_propia');
SELECT pg_temp.caso_svc('B12 el dueño tampoco', pg_temp.ins_aprob('OWN', (SELECT v FROM _ens WHERE k = 'AE')), 'SCJ26', 'ausencia_propia', true);
SELECT pg_temp.caso_svc('B13 service_role SÍ puede registrar la aprobación de OTRA persona sobre la ausencia de AE (camino legítimo del sistema)', pg_temp.ins_aprob('OWN', (SELECT v FROM _ens WHERE k = 'AF')), 'ok');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_AF'), pg_temp.resolver('OWN', 'autorizada', 'permiso_con_goce'));
SELECT pg_temp.igual('B14 AF resuelve la ausencia de AE (otra persona) con reclasificación', pg_temp.estado_de('OWN'), 'autorizada/permiso_con_goce/1');

-- ---------- C) estructura ----------
SELECT pg_temp.verifica('C1 la policy: INSERT para authenticated, con aprobador = fn_caller_persona_id() y el NOT EXISTS con la fila nueva calificada (no una autocomparación)',
  $$SELECT count(*) = 1 AND bool_and(cmd = 'INSERT' AND roles = '{authenticated}' AND with_check LIKE '%fn_caller_persona_id%' AND with_check LIKE '%aprobacion_ausencia.ausencia_id%' AND with_check LIKE '%aprobacion_ausencia.aprobador_id%'
        AND with_check NOT LIKE '%a.persona_id = a.persona_id%')
    FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'aprobacion_ausencia' AND policyname = 'aprobacion_ausencia_insert_requiere_permiso'$$);
SELECT pg_temp.verifica('C1b la policy de UPDATE de ausencia exige pendiente y persona_id distinta de la del caller en USING y en WITH CHECK, y conserva ausencia_edicion',
  $$SELECT count(*) = 1 AND bool_and(cmd = 'UPDATE' AND roles = '{authenticated}' AND qual LIKE '%pendiente%' AND with_check LIKE '%pendiente%' AND qual LIKE '%persona_id <>%fn_caller_persona_id%' AND with_check LIKE '%persona_id <>%fn_caller_persona_id%'
        AND qual LIKE '%ausencia_edicion%' AND with_check LIKE '%ausencia_edicion%')
    FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'ausencia' AND policyname = 'ausencia_update_requiere_permiso'$$);
SELECT pg_temp.verifica('C2 aprobacion_ausencia conserva sus 2 policies (insert y select)',
  $$SELECT count(*) = 2 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'aprobacion_ausencia'$$);
SELECT pg_temp.verifica('C3 la función del trigger: DEFINER, search_path fijo, dueño postgres, sin EXECUTE para nadie; el trigger está habilitado',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres'
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
      AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.aprobacion_ausencia'::regclass AND tgname = 'trg_aprobacion_ausencia_bloquea_propia' AND tgenabled = 'O')
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_aprobacion_ausencia_bloquea_propia'$$);
SELECT pg_temp.verifica('C4 fn_ausencia_resolver: INVOKER, search_path fijo, EXECUTE solo authenticated (ni anon ni PUBLIC), una sola sobrecarga',
  $$SELECT count(*) = 1 AND bool_and(NOT prosecdef AND proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) x WHERE x.grantee = 0))
    FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_ausencia_resolver'$$);

-- ---------- D) reversa (49_ + 50_) y reaplicación ----------
DROP TRIGGER trg_aprobacion_ausencia_bloquea_propia ON tiempo.aprobacion_ausencia;
DROP FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia();
DROP POLICY aprobacion_ausencia_insert_requiere_permiso ON tiempo.aprobacion_ausencia;
CREATE POLICY aprobacion_ausencia_insert_requiere_permiso ON tiempo.aprobacion_ausencia FOR INSERT TO authenticated
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion'));
DROP POLICY ausencia_update_requiere_permiso ON tiempo.ausencia;
CREATE POLICY ausencia_update_requiere_permiso ON tiempo.ausencia FOR UPDATE TO authenticated
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'))
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'));
DROP FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text);
\ir ../ddl/50_tiempo_fn_ausencia_resolver.sql
SELECT pg_temp.mk_aus('R1', (SELECT v::uuid FROM _ens WHERE k = 'AE'), DATE '2026-11-09');
SELECT pg_temp.igual('D0 tras la reversa vuelve el defecto del BAJO 1: AE edita el tipo de su propia pendiente (1 fila)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('R1', 'permiso_con_goce')), '1');
SELECT pg_temp.caso2('D1 tras la reversa vuelve el defecto: AE resuelve su propia ausencia (ok)', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('R1', 'autorizada', 'permiso_con_goce'), 'ok');
\ir ../ddl/122_tiempo_ausencia_nadie_resuelve_la_propia.sql
SELECT pg_temp.igual('D2b reaplicable: AE vuelve a no poder editar el tipo de su propia pendiente (0 filas)', pg_temp.filas_auth((SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.upd_tipo('R1', 'permiso_con_goce')), '0');
SELECT pg_temp.caso2('D2 reaplicable: vuelve a rechazar la propia (SCJ26)', (SELECT v FROM _ens WHERE k = 'auth_AE'), pg_temp.resolver('R1', 'autorizada', 'permiso_con_goce'), 'SCJ26', 'ausencia_propia');
SELECT pg_temp.caso2('D3 reaplicable: la ajena sigue resolviéndose', (SELECT v FROM _ens WHERE k = 'auth_AF'), pg_temp.resolver('R1', 'autorizada', 'permiso_con_goce'), 'ok');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
