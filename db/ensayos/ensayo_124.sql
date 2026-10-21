-- Ensayo de 124_tiempo_fn_cierre_dia_armar.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_124.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Personas, marcas, días y tramos SINTÉTICOS creados en la transacción. Aplica 124_ y 123_ en AMBOS ÓRDENES (123_ solo dentro de la transacción).
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica124' || p_k, 'Ensayo124', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens124' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens124' || lower(p_k));
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
-- persona sintética con p_n marcas de captura manual el 2026-10-22 a las 08:00, 09:00, ... hora de México (14:00, 15:00, ... UTC)
CREATE FUNCTION pg_temp.mk_fx(p_k text, p_n int) RETURNS void AS $$
DECLARE v_p uuid := gen_random_uuid(); v_m bigint; i int;
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (v_p);
  INSERT INTO _ens VALUES ('P_' || p_k, v_p::text);
  FOR i IN 1..p_n LOOP
    INSERT INTO tiempo.marca (persona_id, terminal_id, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
    VALUES (v_p, 'ENS124', TIMESTAMPTZ '2026-10-22 13:00:00+00' + make_interval(hours => i), '-06:00', 'sincronizado', 'ens124', 'captura_manual') RETURNING id INTO v_m;
    INSERT INTO _ens VALUES ('M_' || p_k || '_' || i, v_m::text);
  END LOOP;
END $$ LANGUAGE plpgsql;
SELECT pg_temp.mk_fx('PAR', 4);     -- 2 tramos cerrados
SELECT pg_temp.mk_fx('IMPAR', 3);   -- 1 tramo cerrado + 1 abierto
SELECT pg_temp.mk_fx('MALO', 2);    -- para las pruebas de atomicidad
SELECT pg_temp.mk_fx('AJENA', 2);   -- marcas de OTRA persona
-- payload de tramos: p_pares tramos cerrados (marcas 1-2, 3-4, …) y, si p_abierto, un tramo abierto con la marca siguiente. p_alterar: 'minutos' infla los minutos del primer tramo
CREATE FUNCTION pg_temp.payload(p_k text, p_pares int, p_abierto boolean, p_alterar text DEFAULT NULL) RETURNS text AS $$
DECLARE v_arr jsonb := '[]'::jsonb; i int; a bigint; c bigint; ia timestamptz; ic timestamptz; v_min numeric;
BEGIN
  FOR i IN 1..p_pares LOOP
    a := (SELECT v::bigint FROM _ens WHERE k = 'M_' || p_k || '_' || (2*i-1));
    c := (SELECT v::bigint FROM _ens WHERE k = 'M_' || p_k || '_' || (2*i));
    ia := (SELECT momento_dispositivo FROM tiempo.marca WHERE id = a);
    ic := (SELECT momento_dispositivo FROM tiempo.marca WHERE id = c);
    v_min := round((EXTRACT(EPOCH FROM (ic - ia)) / 60.0)::numeric, 2);
    IF p_alterar = 'minutos' AND i = 1 THEN v_min := 9999; END IF;
    v_arr := v_arr || jsonb_build_array(jsonb_build_object('marca_apertura_id', a, 'marca_cierre_id', c, 'inicio', ia, 'fin', ic, 'minutos_trabajados', v_min));
  END LOOP;
  IF p_abierto THEN
    a := (SELECT v::bigint FROM _ens WHERE k = 'M_' || p_k || '_' || (2*p_pares+1));
    ia := (SELECT momento_dispositivo FROM tiempo.marca WHERE id = a);
    v_arr := v_arr || jsonb_build_array(jsonb_build_object('marca_apertura_id', a, 'marca_cierre_id', NULL, 'inicio', ia, 'fin', NULL, 'minutos_trabajados', NULL));
  END IF;
  RETURN v_arr::text;
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.llama(p_k text, p_estado text, p_horas text, p_tramos text, p_motivo text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_cierre_dia_armar(p_persona_id => %L::uuid, p_fecha => DATE ''2026-10-22'', p_estado => %L, p_horas_totales => %s, p_tramos => %L::jsonb, p_motivo_excepcion_dia => %L)',
    (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_estado, p_horas, p_tramos, p_motivo);
$$ LANGUAGE sql;
-- ejecuta como p_rol; si sale bien evalúa p_check (como dueño) ANTES de revertir; si falla, evalúa p_check DESPUÉS del rollback (estado limpio). p_state = 'ok' o el SQLSTATE esperado
CREATE FUNCTION pg_temp.prueba(p_caso text, p_rol text, p_sql text, p_state text, p_hint text, p_check text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := ''; v_ok boolean := true;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  BEGIN
    EXECUTE p_sql;
    IF p_check IS NOT NULL THEN RESET ROLE; EXECUTE p_check INTO v_ok; END IF;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  IF v_state <> 'ok' AND p_check IS NOT NULL THEN EXECUTE p_check INTO v_ok; END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint) AND COALESCE(v_ok, false), format('obtenido=%s hint=%s verificacion=%s %s', v_state, v_hint, v_ok, left(v_msg, 60)));
END $$ LANGUAGE plpgsql;
-- chequeos de estado
CREATE FUNCTION pg_temp.ck_dia(p_k text, p_estado text, p_tramos int, p_exc int) RETURNS text AS $$
  SELECT format('SELECT (SELECT count(*) FROM tiempo.dia WHERE persona_id = %L::uuid AND fecha = DATE ''2026-10-22'' AND estado = %L) = 1 AND (SELECT count(*) FROM tiempo.tramo t JOIN tiempo.dia d ON d.id = t.dia_id WHERE d.persona_id = %L::uuid AND d.fecha = DATE ''2026-10-22'') = %s AND (SELECT count(*) FROM tiempo.excepcion e JOIN tiempo.dia d ON d.id = e.dia_id WHERE d.persona_id = %L::uuid AND d.fecha = DATE ''2026-10-22'' AND e.motivo_revision = ''paridad_impar'' AND e.estado = ''pendiente'') = %s',
    (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_estado, (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_tramos, (SELECT v FROM _ens WHERE k = 'P_' || p_k), p_exc);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.ck_sin_dia(p_k text) RETURNS text AS $$
  SELECT format('SELECT NOT EXISTS (SELECT 1 FROM tiempo.dia WHERE persona_id = %L::uuid AND fecha = DATE ''2026-10-22'') AND NOT EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.marca_apertura_id IN (SELECT v::bigint FROM _ens WHERE k LIKE %L))',
    (SELECT v FROM _ens WHERE k = 'P_' || p_k), 'M\_' || p_k || '\_%');
$$ LANGUAGE sql;

-- ---------- A) el defecto (llamadas sueltas: el día queda sin tramos) ----------
DO $$
DECLARE v_p uuid := (SELECT v::uuid FROM _ens WHERE k = 'P_MALO'); v_dia bigint;
BEGIN
  INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES (v_p, DATE '2026-10-22', 'cerrado', 1) RETURNING id INTO v_dia;    -- «commit» del día (llamada suelta 1)
  BEGIN
    INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, inicio) VALUES (v_dia, 999999999, now());                                              -- llamada suelta 2: falla (FK)
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  INSERT INTO _res (caso, ok, detalle) VALUES ('A0 (defecto) llamadas sueltas: si el tramo falla, el día queda CREADO y SIN tramos (y _dia_ya_resuelto lo saltaría para siempre)',
    EXISTS (SELECT 1 FROM tiempo.dia WHERE id = v_dia) AND NOT EXISTS (SELECT 1 FROM tiempo.tramo WHERE dia_id = v_dia), 'dia creado sin tramos');
  DELETE FROM tiempo.dia WHERE id = v_dia;   -- limpia para las pruebas siguientes (todo se revierte igual al final)
END $$;

\ir ../ddl/124_tiempo_fn_cierre_dia_armar.sql

-- ---------- B) con 124_ SOLA (sin 123_) ----------
SELECT pg_temp.prueba('B1 día PAR: cerrado, 2 tramos, 7.50 h, sin excepción de día', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));
SELECT pg_temp.prueba('B2 día IMPAR: bloqueado, 1 tramo cerrado + 1 abierto, horas NULL y excepción de día paridad_impar pendiente', 'service_role', pg_temp.llama('IMPAR', 'bloqueado', 'NULL', pg_temp.payload('IMPAR', 1, true), 'paridad_impar'), 'ok', NULL, pg_temp.ck_dia('IMPAR', 'bloqueado', 2, 1));
SELECT pg_temp.prueba('B3 devuelve el id del día creado', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL,
  format('SELECT EXISTS (SELECT 1 FROM tiempo.dia d WHERE d.persona_id = %L::uuid AND d.fecha = DATE ''2026-10-22'')', (SELECT v FROM _ens WHERE k = 'P_PAR')));
SELECT pg_temp.prueba('B4 el mismo día otra vez => SCJ27 / dia_ya_existe (backend lo trata como ya resuelto)', 'service_role',
  pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL) || '; ' || pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'SCJ27', 'dia_ya_existe', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B5 estado distinto de cerrado/bloqueado (abierto) => SCJ27 / estado_invalido y no crea nada', 'service_role', pg_temp.llama('PAR', 'abierto', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'SCJ27', 'estado_invalido', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B6 cerrado con un tramo abierto => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('IMPAR', 'cerrado', '7.5', pg_temp.payload('IMPAR', 1, true), NULL), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('IMPAR'));
SELECT pg_temp.prueba('B7 cerrado sin horas => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('PAR', 'cerrado', 'NULL', pg_temp.payload('PAR', 2, false), NULL), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B8 cerrado con excepción de día => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), 'paridad_impar'), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B9 bloqueado sin tramo abierto => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('PAR', 'bloqueado', 'NULL', pg_temp.payload('PAR', 2, false), 'paridad_impar'), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B10 bloqueado con horas => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('IMPAR', 'bloqueado', '3', pg_temp.payload('IMPAR', 1, true), 'paridad_impar'), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('IMPAR'));
SELECT pg_temp.prueba('B11 bloqueado sin motivo de excepción => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('IMPAR', 'bloqueado', 'NULL', pg_temp.payload('IMPAR', 1, true), NULL), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('IMPAR'));
SELECT pg_temp.prueba('B12 payload vacío => SCJ27 / tramos_inconsistentes', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', '[]', NULL), 'SCJ27', 'tramos_inconsistentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B12b horas > 24 (25) => SCJ27 / horas_fuera_de_rango y no crea nada', 'service_role', pg_temp.llama('PAR', 'cerrado', '25', pg_temp.payload('PAR', 2, false), NULL), 'SCJ27', 'horas_fuera_de_rango', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B12c horas negativas (-1) => SCJ27 / horas_fuera_de_rango', 'service_role', pg_temp.llama('PAR', 'cerrado', '-1', pg_temp.payload('PAR', 2, false), NULL), 'SCJ27', 'horas_fuera_de_rango', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B12d los límites 0 y 24 SÍ se aceptan', 'service_role', pg_temp.llama('PAR', 'cerrado', '24', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));
SELECT pg_temp.prueba('B12e horas = 0 se acepta', 'service_role', pg_temp.llama('PAR', 'cerrado', '0', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));
SELECT pg_temp.prueba('B13 ATOMICIDAD: el segundo tramo referencia una marca inexistente => SCJ15 / tramo_incoherente (el trigger de 86_ salta antes que la FK) y NO queda el día NI el primer tramo', 'service_role',
  pg_temp.llama('PAR', 'cerrado', '7.5', replace(pg_temp.payload('PAR', 2, false), (SELECT v FROM _ens WHERE k = 'M_PAR_3'), '999999999'), NULL), 'SCJ15', 'tramo_incoherente', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B14 ATOMICIDAD: un tramo con marcas de OTRA persona => SCJ15 / tramo_incoherente (trigger de 86_) y NO queda el día', 'service_role',
  pg_temp.llama('MALO', 'cerrado', '1', (SELECT jsonb_build_array(jsonb_build_object('marca_apertura_id', (SELECT v::bigint FROM _ens WHERE k = 'M_AJENA_1'), 'marca_cierre_id', (SELECT v::bigint FROM _ens WHERE k = 'M_AJENA_2'),
     'inicio', (SELECT momento_dispositivo FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'M_AJENA_1')), 'fin', (SELECT momento_dispositivo FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'M_AJENA_2')), 'minutos_trabajados', 60))::text), NULL),
  'SCJ15', 'tramo_incoherente', pg_temp.ck_sin_dia('MALO'));
SELECT pg_temp.prueba('B15 el día bloqueado + su excepción también son atómicos: la excepción no puede quedar sin día (tramo abierto con marca inexistente => SCJ15, nada queda)', 'service_role',
  pg_temp.llama('IMPAR', 'bloqueado', 'NULL', replace(pg_temp.payload('IMPAR', 1, true), (SELECT v FROM _ens WHERE k = 'M_IMPAR_3'), '999999999'), 'paridad_impar'), 'SCJ15', 'tramo_incoherente', pg_temp.ck_sin_dia('IMPAR'));
SELECT pg_temp.prueba('B16 anon NO puede ejecutar la RPC', 'anon', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), '42501', NULL, pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('B17 authenticated NO puede ejecutar la RPC', 'authenticated', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), '42501', NULL, pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.verifica('B18 estructura: una sola función de 6 argumentos, DEFINER con search_path fijo, dueño postgres, EXECUTE solo service_role',
  $$SELECT count(*) = 1 AND bool_and(pronargs = 6 AND prosecdef AND proconfig = ARRAY['search_path=tiempo, pg_temp'] AND pg_get_userbyid(proowner) = 'postgres' AND NOT proleakproof
        AND has_function_privilege('service_role', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) x WHERE x.grantee = 0))
    FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_cierre_dia_armar'$$);

-- ---------- C) 124_ y DESPUÉS 123_ (orden 1) ----------
\ir ../ddl/123_tiempo_tramo_valida_tiempos.sql
SELECT pg_temp.prueba('C1 con 123_: día PAR coherente => ok', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));
SELECT pg_temp.prueba('C2 con 123_: día IMPAR coherente => ok', 'service_role', pg_temp.llama('IMPAR', 'bloqueado', 'NULL', pg_temp.payload('IMPAR', 1, true), 'paridad_impar'), 'ok', NULL, pg_temp.ck_dia('IMPAR', 'bloqueado', 2, 1));
SELECT pg_temp.prueba('C3 con 123_: el SEGUNDO tramo trae minutos inflados => SCJ15 / tramo_tiempos_incoherentes y NO queda el día NI el primer tramo (la razón de ser de 124_)', 'service_role',
  pg_temp.llama('PAR', 'cerrado', '7.5', (SELECT jsonb_set(pg_temp.payload('PAR', 2, false)::jsonb, '{1,minutos_trabajados}', '9999')::text), NULL), 'SCJ15', 'tramo_tiempos_incoherentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('C4 con 123_: el tramo ABIERTO del día impar con minutos => SCJ15 y NO queda el día ni la excepción de día', 'service_role',
  pg_temp.llama('IMPAR', 'bloqueado', 'NULL', (SELECT jsonb_set(pg_temp.payload('IMPAR', 1, true)::jsonb, '{1,minutos_trabajados}', '30')::text), 'paridad_impar'), 'SCJ15', 'tramo_tiempos_incoherentes',
  pg_temp.ck_sin_dia('IMPAR') || ' AND NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.motivo_revision = ''paridad_impar'' AND e.dia_id IN (SELECT id FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = ''P_IMPAR'')))');

-- ---------- D) el otro orden: 123_ primero y 124_ después ----------
DROP FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text);
SELECT pg_temp.verifica('D0 sin 124_ no existe la RPC (123_ sigue aplicado)', $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_cierre_dia_armar') AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_tramo_valida_tiempos')$$);
\ir ../ddl/124_tiempo_fn_cierre_dia_armar.sql
SELECT pg_temp.prueba('D1 orden 123_ -> 124_: día PAR coherente => ok', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));
SELECT pg_temp.prueba('D2 orden 123_ -> 124_: minutos inflados => SCJ15 y no queda el día', 'service_role',
  pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false, 'minutos'), NULL), 'SCJ15', 'tramo_tiempos_incoherentes', pg_temp.ck_sin_dia('PAR'));
SELECT pg_temp.prueba('D3 orden 123_ -> 124_: día IMPAR coherente => ok', 'service_role', pg_temp.llama('IMPAR', 'bloqueado', 'NULL', pg_temp.payload('IMPAR', 1, true), 'paridad_impar'), 'ok', NULL, pg_temp.ck_dia('IMPAR', 'bloqueado', 2, 1));

-- ---------- E) reversa y reaplicación ----------
DROP FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text);
SELECT pg_temp.prueba('E1 tras la reversa la RPC ya no existe', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), '42883', NULL, pg_temp.ck_sin_dia('PAR'));
\ir ../ddl/124_tiempo_fn_cierre_dia_armar.sql
SELECT pg_temp.prueba('E2 reaplicable: vuelve a funcionar', 'service_role', pg_temp.llama('PAR', 'cerrado', '7.5', pg_temp.payload('PAR', 2, false), NULL), 'ok', NULL, pg_temp.ck_dia('PAR', 'cerrado', 2, 0));

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
