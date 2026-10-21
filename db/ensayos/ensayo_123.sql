-- Ensayo de 123_tiempo_tramo_valida_tiempos.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_123.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Usa una persona, 2 marcas, un día y tramos SINTÉTICOS, creados en la transacción (las marcas reales ya están todas en tramos) y actores sintéticos. Aplica SOLO 123_.
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica123' || p_k, 'Ensayo123', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens123' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens123' || lower(p_k));
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

-- Persona y 2 marcas SINTÉTICAS (todas las marcas reales ya están en tramos): captura manual el 2026-10-21 a las 09:00 y 13:00 hora de México; el día y los tramos de prueba también son sintéticos. Todo dentro de la transacción.
CREATE TEMP TABLE _fx (persona_id uuid, f date, m1 bigint, m2 bigint, ef1 timestamptz, ef2 timestamptz);
GRANT SELECT ON _fx TO PUBLIC;
DO $$
DECLARE v_p uuid := gen_random_uuid(); v_m1 bigint; v_m2 bigint;
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (v_p);
  INSERT INTO tiempo.marca (persona_id, terminal_id, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (v_p, 'ENS123', TIMESTAMPTZ '2026-10-21 15:00:00+00', '-06:00', 'sincronizado', 'ens123', 'captura_manual') RETURNING id INTO v_m1;
  INSERT INTO tiempo.marca (persona_id, terminal_id, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (v_p, 'ENS123', TIMESTAMPTZ '2026-10-21 19:00:00+00', '-06:00', 'sincronizado', 'ens123', 'captura_manual') RETURNING id INTO v_m2;
  INSERT INTO _fx VALUES (v_p, DATE '2026-10-21', v_m1, v_m2, TIMESTAMPTZ '2026-10-21 15:00:00+00', TIMESTAMPTZ '2026-10-21 19:00:00+00');
  INSERT INTO tiempo.dia (persona_id, fecha, estado) VALUES (v_p, DATE '2026-10-21', 'cerrado');
  -- las correcciones exigen que la marca tenga una excepción (fn_correccion_valida): se siembra una sintética por marca si el trigger de revisión no la creó
  INSERT INTO tiempo.excepcion (marca_id, motivo_revision, estado)
  SELECT x.id, 'reloj_no_sincronizado', 'pendiente' FROM (VALUES (v_m1), (v_m2)) x(id) WHERE NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.marca_id = x.id);
END $$;
SELECT pg_temp.verifica('PRE las 2 marcas sintéticas, el día y las excepciones existen (si FALLA, el resto del ensayo no es válido)',
  $$SELECT (SELECT count(*) FROM _fx) = 1 AND (SELECT count(*) FROM tiempo.excepcion e JOIN _fx f ON e.marca_id IN (f.m1, f.m2)) >= 2 AND EXISTS (SELECT 1 FROM tiempo.dia d JOIN _fx f ON d.persona_id = f.persona_id AND d.fecha = f.f)$$);

-- inserta un tramo con valores dados: inicio/fin como texto o 'ef1'/'ef2'; minutos como texto numérico o 'calc' (= redondeo de la diferencia real); p_cierre: usar la marca 2 como cierre
CREATE FUNCTION pg_temp.ins_tramo(p_inicio text, p_fin text, p_min text, p_cierre boolean) RETURNS text AS $$
  SELECT format('INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) SELECT d.id, f.m1, %s, %s, %s, %s FROM _fx f JOIN tiempo.dia d ON d.persona_id = f.persona_id AND d.fecha = f.f',
    CASE WHEN p_cierre THEN 'f.m2' ELSE 'NULL' END,
    CASE p_inicio WHEN 'ef1' THEN 'f.ef1' WHEN 'NULL' THEN 'NULL' ELSE quote_literal(p_inicio) || '::timestamptz' END,
    CASE p_fin WHEN 'ef2' THEN 'f.ef2' WHEN 'NULL' THEN 'NULL' ELSE quote_literal(p_fin) || '::timestamptz' END,
    CASE p_min WHEN 'calc' THEN 'round((EXTRACT(EPOCH FROM (f.ef2 - f.ef1)) / 60.0)::numeric, 2)' WHEN 'NULL' THEN 'NULL' ELSE p_min || '::numeric' END);
$$ LANGUAGE sql;
-- ejecuta como DUEÑO (el trigger aplica a todos); revierte el caso
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

-- ---------- A) ANTES de 123_ (documenta el defecto) ----------
SELECT pg_temp.como_dueno('A0 (defecto) ANTES de 123_: un tramo con minutos_trabajados = 9999 e inicio desplazado se acepta', pg_temp.ins_tramo('2000-01-01 00:00:00+00', 'ef2', '9999', true), 'ok');

SELECT pg_temp.como_dueno('A1 (empate) ANTES de 123_: DOS correcciones de la misma marca en la misma transacción se aceptan (mismo creado_en: el «más reciente» queda sin definir)',
  'INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''1 second'', ''ensayo'', persona_id FROM _fx; INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''2 second'', ''ensayo'', persona_id FROM _fx', 'ok');

\ir ../ddl/123_tiempo_tramo_valida_tiempos.sql

-- ---------- B) después de 123_ ----------
SELECT pg_temp.como_dueno('B1 un tramo coherente (inicio y fin efectivos, minutos = diferencia) se acepta', pg_temp.ins_tramo('ef1', 'ef2', 'calc', true), 'ok');
SELECT pg_temp.como_dueno('B2 inicio distinto del efectivo de la apertura => SCJ15 / tramo_tiempos_incoherentes', pg_temp.ins_tramo('2000-01-01 00:00:00+00', 'ef2', 'calc', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B3 fin distinto del efectivo del cierre => SCJ15', pg_temp.ins_tramo('ef1', '2099-01-01 00:00:00+00', 'calc', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B4 minutos inflados (9999) => SCJ15', pg_temp.ins_tramo('ef1', 'ef2', '9999', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B5 minutos NULL con marca de cierre => SCJ15', pg_temp.ins_tramo('ef1', 'ef2', 'NULL', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B6a tolerancia: diferencia +0.01 se acepta',
  format('INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) SELECT d.id, f.m1, f.m2, f.ef1, f.ef2, round((EXTRACT(EPOCH FROM (f.ef2 - f.ef1)) / 60.0)::numeric, 2) + 0.01 FROM _fx f JOIN tiempo.dia d ON d.persona_id = f.persona_id AND d.fecha = f.f'), 'ok');
SELECT pg_temp.como_dueno('B6b tolerancia: diferencia +0.02 se rechaza',
  format('INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) SELECT d.id, f.m1, f.m2, f.ef1, f.ef2, round((EXTRACT(EPOCH FROM (f.ef2 - f.ef1)) / 60.0)::numeric, 2) + 0.02 FROM _fx f JOIN tiempo.dia d ON d.persona_id = f.persona_id AND d.fecha = f.f'), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B7 tramo ABIERTO coherente (sin cierre, fin y minutos NULL) => ok', pg_temp.ins_tramo('ef1', 'NULL', 'NULL', false), 'ok');
SELECT pg_temp.como_dueno('B8 tramo abierto con minutos => SCJ15', pg_temp.ins_tramo('ef1', 'NULL', '30', false), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B9 tramo abierto con fin => SCJ15', pg_temp.ins_tramo('ef1', 'ef2', 'NULL', false), 'SCJ15', 'tramo_tiempos_incoherentes');
-- UPDATE: cerrar_existente (como fn_dia_revisar): un solo UPDATE coherente pasa; uno incoherente no
SELECT pg_temp.como_dueno('B10 UPDATE que cierra un tramo abierto con cierre, fin y minutos coherentes (el camino de fn_dia_revisar) => ok',
  pg_temp.ins_tramo('ef1', 'NULL', 'NULL', false) || '; UPDATE tiempo.tramo SET marca_cierre_id = (SELECT m2 FROM _fx), fin = (SELECT ef2 FROM _fx), minutos_trabajados = (SELECT round((EXTRACT(EPOCH FROM (ef2 - ef1)) / 60.0)::numeric, 2) FROM _fx) WHERE marca_apertura_id = (SELECT m1 FROM _fx)', 'ok');
SELECT pg_temp.como_dueno('B11 UPDATE que cierra con minutos inflados => SCJ15',
  pg_temp.ins_tramo('ef1', 'NULL', 'NULL', false) || '; UPDATE tiempo.tramo SET marca_cierre_id = (SELECT m2 FROM _fx), fin = (SELECT ef2 FROM _fx), minutos_trabajados = 9999 WHERE marca_apertura_id = (SELECT m1 FROM _fx)', 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B12 UPDATE de solo minutos_trabajados sobre un tramo coherente a un valor distinto => SCJ15',
  pg_temp.ins_tramo('ef1', 'ef2', 'calc', true) || '; UPDATE tiempo.tramo SET minutos_trabajados = 9999 WHERE marca_apertura_id = (SELECT m1 FROM _fx)', 'SCJ15', 'tramo_tiempos_incoherentes');
-- momento efectivo con corrección: el tramo debe usar el valor corregido
SELECT pg_temp.como_dueno('B13 con una corrección en la apertura, un tramo con el inicio ORIGINAL se rechaza',
  'INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''10 seconds'', ''ensayo'', persona_id FROM _fx; ' ||
  'INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) SELECT d.id, f.m1, f.m2, f.ef1, f.ef2, round((EXTRACT(EPOCH FROM (f.ef2 - f.ef1)) / 60.0)::numeric, 2) FROM _fx f JOIN tiempo.dia d ON d.persona_id = f.persona_id AND d.fecha = f.f', 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_dueno('B14 con una corrección en la apertura, un tramo con el inicio CORREGIDO y los minutos recalculados se acepta',
  'INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''10 seconds'', ''ensayo'', persona_id FROM _fx; ' ||
  'INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) SELECT d.id, f.m1, f.m2, f.ef1 + interval ''10 seconds'', f.ef2, round((EXTRACT(EPOCH FROM (f.ef2 - (f.ef1 + interval ''10 seconds'')) ) / 60.0)::numeric, 2) FROM _fx f JOIN tiempo.dia d ON d.persona_id = f.persona_id AND d.fecha = f.f', 'ok');
-- service_role (el batch) y un humano con dia_revision_edicion
CREATE FUNCTION pg_temp.como_rol(p_caso text, p_rol text, p_sub text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_rol)::text, true);
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
SELECT pg_temp.mk_persona('RH', 1, 'ENS123 revisa', 'dia_revision_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento) SELECT id, 'dia_lectura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS123 revisa';   -- para que el INSERT … SELECT del helper vea la fila del día
SELECT pg_temp.como_rol('B15 service_role (cierre_dia): un tramo coherente se acepta', 'service_role', '00000000-0000-4000-8000-000000000001', pg_temp.ins_tramo('ef1', 'ef2', 'calc', true), 'ok');
SELECT pg_temp.como_rol('B16 service_role: un tramo con minutos inflados se rechaza', 'service_role', '00000000-0000-4000-8000-000000000001', pg_temp.ins_tramo('ef1', 'ef2', '9999', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_rol('B17 RH con dia_revision_edicion por PostgREST directo: un tramo con minutos inflados, que la policy de 64_ sí deja pasar, se rechaza (el defecto que cierra 123_)', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.ins_tramo('ef1', 'ef2', '9999', true), 'SCJ15', 'tramo_tiempos_incoherentes');
SELECT pg_temp.como_rol('B18 RH: el mismo tramo coherente se acepta', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.ins_tramo('ef1', 'ef2', 'calc', true), 'ok');

SELECT pg_temp.como_dueno('B19 DESEMPATE: dos correcciones de la misma marca en la misma transacción => 23505 (índice único uq_correccion_marca_creado_en): el «más reciente» siempre es único',
  'INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''1 second'', ''ensayo'', persona_id FROM _fx; INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''2 second'', ''ensayo'', persona_id FROM _fx', '23505');
SELECT pg_temp.como_dueno('B20 DESEMPATE: una corrección en la misma marca pero en otra transacción (otro creado_en) sigue permitida',
  'INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id, creado_en) SELECT m1, ef1 + interval ''1 second'', ''ensayo'', persona_id, now() - interval ''1 hour'' FROM _fx; INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) SELECT m1, ef1 + interval ''2 second'', ''ensayo'', persona_id FROM _fx', 'ok');
SELECT pg_temp.verifica('B21 el índice único existe sobre (marca_id, creado_en)',
  $$SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'tiempo' AND indexname = 'uq_correccion_marca_creado_en' AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%(marca_id, creado_en)%')$$);

-- ---------- C) estructura ----------
SELECT pg_temp.verifica('C1 las funciones: trigger DEFINER con search_path fijo y sin EXECUTE para nadie de la API; la interna sin EXECUTE; el trigger habilitado y por fila',
  $$SELECT (SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
                   AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0) FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_tramo_valida_tiempos')
      AND (SELECT NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
                   AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0) FROM pg_proc p WHERE p.pronamespace = 'tiempo'::regnamespace AND p.proname = 'fn_marca_momento_efectivo')
      AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.tramo'::regclass AND tgname = 'trg_tramo_valida_tiempos' AND tgenabled = 'O' AND (tgtype & 1) = 1)$$);
SELECT pg_temp.verifica('C2 el trigger de 86_ sigue habilitado (coexisten) y se ejecuta ANTES que el nuevo (orden alfabético)',
  $$SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.tramo'::regclass AND tgname = 'trg_tramo_valida_coherencia' AND tgenabled = 'O') AND 'trg_tramo_valida_coherencia' < 'trg_tramo_valida_tiempos'$$);
SELECT pg_temp.verifica('C3 fn_marca_momento_efectivo da lo mismo que la definición en línea de fn_marca_fecha_local (86_): corregido si hay corrección, si no el del dispositivo',
  $$SELECT tiempo.fn_marca_momento_efectivo(f.m1) = f.ef1 AND tiempo.fn_marca_momento_efectivo(f.m2) = f.ef2 FROM _fx f$$);

-- ---------- D) reversa y reaplicación ----------
DROP INDEX tiempo.uq_correccion_marca_creado_en;
DROP TRIGGER trg_tramo_valida_tiempos ON tiempo.tramo;
DROP FUNCTION tiempo.fn_tramo_valida_tiempos();
DROP FUNCTION tiempo.fn_marca_momento_efectivo(bigint);
SELECT pg_temp.como_dueno('D1 tras la reversa vuelve el defecto: minutos inflados se aceptan', pg_temp.ins_tramo('ef1', 'ef2', '9999', true), 'ok');
\ir ../ddl/123_tiempo_tramo_valida_tiempos.sql
SELECT pg_temp.como_dueno('D2 reaplicable: vuelve a rechazar los minutos inflados', pg_temp.ins_tramo('ef1', 'ef2', '9999', true), 'SCJ15', 'tramo_tiempos_incoherentes');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
