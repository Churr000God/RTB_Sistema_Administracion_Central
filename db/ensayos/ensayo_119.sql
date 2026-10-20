-- Ensayo de 119_tiempo_corte_quincenal_aplicado.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_119.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Datos SINTÉTICOS creados en la transacción y revertidos. Aplica SOLO 119_ (más lo que se indique en el archivo).
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica119' || p_k, 'Ensayo119', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens119' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens119' || lower(p_k));
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
CREATE FUNCTION pg_temp.nueva_persona(p_k text) RETURNS void AS $$
BEGIN
  INSERT INTO _ens VALUES ('P_' || p_k, gen_random_uuid()::text);
  INSERT INTO tiempo.persona (id) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'P_' || p_k));
END $$ LANGUAGE plpgsql;
SELECT pg_temp.nueva_persona('A'); SELECT pg_temp.nueva_persona('B'); SELECT pg_temp.nueva_persona('C'); SELECT pg_temp.nueva_persona('D'); SELECT pg_temp.nueva_persona('E');

-- llamadas como service_role (el batch); p_firma: 'vieja' (57_) o 'nueva' (119_)
CREATE FUNCTION pg_temp.rpc_vieja(p_k text, p_movs text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_corte_quincenal_aplicar_persona(%L::uuid, ''[]''::jsonb, %L::jsonb, %L)', (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_movs, 'ensayo');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.rpc(p_k text, p_desde text, p_hasta text, p_movs text DEFAULT '[]', p_clas text DEFAULT '[]', p_esp numeric DEFAULT 10, p_trab numeric DEFAULT 4) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_corte_quincenal_aplicar_persona(p_persona_id => %L::uuid, p_periodo_desde => %L::date, p_periodo_hasta => %L::date, p_horas_esperadas => %s, p_horas_trabajadas => %s, p_clasificaciones => %L::jsonb, p_movimientos => %L::jsonb, p_motivo => %L)',
                (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_desde, p_hasta, p_esp, p_trab, p_clas, p_movs, 'ensayo');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.como_service(p_sql text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  SET LOCAL ROLE service_role;
  EXECUTE p_sql;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.caso_rol(p_caso text, p_rol text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
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
CREATE FUNCTION pg_temp.saldo(p_k text) RETURNS numeric AS $$
  SELECT COALESCE((SELECT monto FROM tiempo.banco_de_horas WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_' || p_k)), -1);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido = p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;

-- ---------- A) ANTES de 119_ (documenta el defecto con la función de 57_) ----------
SELECT pg_temp.como_service(pg_temp.rpc_vieja('A', '[{"tramo_id":null,"tipo":"generado_quincena","monto":10}]'));
SELECT pg_temp.como_service(pg_temp.rpc_vieja('A', '[{"tramo_id":null,"tipo":"generado_quincena","monto":10}]'));
SELECT pg_temp.igual('A0 (defecto) ANTES de 119_: aplicar dos veces el mismo corte sin tramos DUPLICA la deuda (20 en vez de 10)', pg_temp.saldo('A')::text, '20.00');
CREATE TEMP TABLE _old AS SELECT 1 AS x WHERE EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_corte_quincenal_aplicar_persona' AND pronargs = 4);
SELECT pg_temp.verifica('A1 antes de 119_ existe la firma vieja de 4 argumentos', $$SELECT EXISTS (SELECT 1 FROM _old)$$);

\ir ../ddl/119_tiempo_corte_quincenal_aplicado.sql

-- ---------- B) después de 119_ ----------
SELECT pg_temp.verifica('B0 la firma vieja desapareció y existe una sola función con 8 argumentos',
  $$SELECT (SELECT count(*) FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_corte_quincenal_aplicar_persona') = 1
       AND (SELECT pronargs FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_corte_quincenal_aplicar_persona') = 8$$);
SELECT pg_temp.como_service(pg_temp.rpc('B', '2026-10-01', '2026-10-15'));   -- listas vacías, resultado 0
SELECT pg_temp.verifica('B1 listas vacías: el periodo queda registrado con resultado 0, esperadas/trabajadas guardadas, y NO se crea banco_de_horas',
  $$SELECT EXISTS (SELECT 1 FROM tiempo.corte_quincenal_aplicado a WHERE a.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_B') AND a.periodo_desde = DATE '2026-10-01' AND a.periodo_hasta = DATE '2026-10-15'
                    AND a.resultado_horas = 0 AND a.horas_esperadas = 10 AND a.horas_trabajadas = 4)
      AND NOT EXISTS (SELECT 1 FROM tiempo.banco_de_horas WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_B'))$$);
SELECT pg_temp.caso_rol('B2 el MISMO periodo otra vez (listas vacías) => SCJ23 / periodo_ya_aplicado', 'service_role', pg_temp.rpc('B', '2026-10-01', '2026-10-15'), 'SCJ23', 'periodo_ya_aplicado');
SELECT pg_temp.como_service(pg_temp.rpc('C', '2026-10-01', '2026-10-15', '[{"tramo_id":null,"tipo":"generado_quincena","monto":12}]'));
SELECT pg_temp.igual('B3 con un generado_quincena de 12: el banco queda en 12', pg_temp.saldo('C')::text, '12.00');
SELECT pg_temp.verifica('B4 resultado_horas = 12 (la suma de los generado_quincena de la llamada)',
  $$SELECT resultado_horas = 12 FROM tiempo.corte_quincenal_aplicado WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_C') AND periodo_desde = DATE '2026-10-01'$$);
SELECT pg_temp.caso_rol('B5 duplicado con movimiento => SCJ23', 'service_role', pg_temp.rpc('C', '2026-10-01', '2026-10-15', '[{"tramo_id":null,"tipo":"generado_quincena","monto":12}]'), 'SCJ23', 'periodo_ya_aplicado');
SELECT pg_temp.igual('B6 el duplicado rechazado NO duplicó la deuda (sigue 12)', pg_temp.saldo('C')::text, '12.00');
SELECT pg_temp.como_service(pg_temp.rpc('C', '2026-10-16', '2026-10-31'));
SELECT pg_temp.verifica('B7 otro periodo de la misma persona sí se registra (2 periodos)',
  $$SELECT count(*) = 2 FROM tiempo.corte_quincenal_aplicado WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_C')$$);
SELECT pg_temp.como_service(pg_temp.rpc('D', '2026-10-01', '2026-10-15'));
SELECT pg_temp.verifica('B8 otra persona, mismo periodo: se registra (la unicidad es por persona + periodo)',
  $$SELECT count(*) = 1 FROM tiempo.corte_quincenal_aplicado WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_D')$$);
SELECT pg_temp.caso_rol('B9 SCJ05 sigue: movimiento con tramo_id ausente de las clasificaciones', 'service_role',
  pg_temp.rpc('E', '2026-10-01', '2026-10-15', '[{"tramo_id":999999999,"tipo":"cubrir","monto":-1}]'), 'SCJ05');
SELECT pg_temp.verifica('B10 atomicidad: tras el SCJ05 no quedó registro del periodo de E (el caso lo revirtió completo)',
  $$SELECT NOT EXISTS (SELECT 1 FROM tiempo.corte_quincenal_aplicado WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P_E'))$$);
SELECT pg_temp.caso_rol('B11 periodo_hasta < periodo_desde => 23514', 'service_role', pg_temp.rpc('E', '2026-10-15', '2026-10-01'), '23514');
SELECT pg_temp.caso_rol('B12 horas negativas => 23514', 'service_role', pg_temp.rpc('E', '2026-10-01', '2026-10-15', '[]', '[]', -1, 0), '23514');
SELECT pg_temp.caso_rol('B13 authenticated NO puede ejecutar el RPC', 'authenticated', pg_temp.rpc('E', '2026-10-01', '2026-10-15'), '42501');
SELECT pg_temp.caso_rol('B14 anon NO puede ejecutar el RPC', 'anon', pg_temp.rpc('E', '2026-10-01', '2026-10-15'), '42501');
SELECT pg_temp.caso_rol('B15 authenticated NO lee la tabla', 'authenticated', 'SELECT count(*) FROM tiempo.corte_quincenal_aplicado', '42501');
SELECT pg_temp.caso_rol('B16 anon NO lee la tabla', 'anon', 'SELECT count(*) FROM tiempo.corte_quincenal_aplicado', '42501');
SELECT pg_temp.caso_rol('B17 service_role SÍ lee la tabla (backend la consulta antes de calcular)', 'service_role', 'SELECT count(*) FROM tiempo.corte_quincenal_aplicado', 'ok');
SELECT pg_temp.caso_rol('B18 service_role NO puede UPDATE', 'service_role', 'UPDATE tiempo.corte_quincenal_aplicado SET resultado_horas = 0', '42501');
SELECT pg_temp.caso_rol('B19 service_role NO puede DELETE', 'service_role', 'DELETE FROM tiempo.corte_quincenal_aplicado', '42501');
SELECT pg_temp.caso_rol('B20 service_role NO puede TRUNCATE', 'service_role', 'TRUNCATE tiempo.corte_quincenal_aplicado', '42501');
SELECT pg_temp.verifica('B21 RLS habilitada y cero policies (deny-by-default a propósito)',
  $$SELECT (SELECT relrowsecurity FROM pg_class WHERE oid = 'tiempo.corte_quincenal_aplicado'::regclass) AND NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'corte_quincenal_aplicado')$$);
SELECT pg_temp.verifica('B22 la función es INVOKER con search_path fijo y EXECUTE solo para service_role',
  $$SELECT NOT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
    FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_corte_quincenal_aplicar_persona'$$);

-- ---------- C) reversa (57_) y reaplicación ----------
DROP FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, date, date, numeric, numeric, jsonb, jsonb, text);
DROP TABLE tiempo.corte_quincenal_aplicado;
\ir ../ddl/57_tiempo_fn_corte_quincenal_aplicar_persona.sql
SELECT pg_temp.verifica('C1 tras la reversa vuelve la firma vieja de 4 argumentos y no queda la tabla',
  $$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_corte_quincenal_aplicar_persona' AND pronargs = 4) AND to_regclass('tiempo.corte_quincenal_aplicado') IS NULL$$);
SELECT pg_temp.verifica('C2 la firma vieja vuelve con EXECUTE para service_role',
  $$SELECT has_function_privilege('service_role', 'tiempo.fn_corte_quincenal_aplicar_persona(uuid, jsonb, jsonb, text)', 'EXECUTE')$$);
\ir ../ddl/119_tiempo_corte_quincenal_aplicado.sql
SELECT pg_temp.como_service(pg_temp.rpc('B', '2026-10-01', '2026-10-15'));
SELECT pg_temp.caso_rol('C3 reaplicable: el registro funciona y el duplicado vuelve a rechazarse', 'service_role', pg_temp.rpc('B', '2026-10-01', '2026-10-15'), 'SCJ23');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
