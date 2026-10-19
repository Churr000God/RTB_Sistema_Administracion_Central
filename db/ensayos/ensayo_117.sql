-- Ensayo de 117_tiempo_correccion_insert_policy_marca_propia.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_117.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 117_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica117' || p_k, 'Ensayo117', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens117' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens117' || lower(p_k));
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

-- ---------- actores: solo correccion_edicion (RH), correccion_edicion + excepcion_reapertura (TI), sin permisos ----------
SELECT pg_temp.mk_persona('CE', 1, 'ENS117 solo correccion', 'correccion_edicion');
SELECT pg_temp.mk_persona('TI', 2, 'ENS117 correccion y reapertura', 'correccion_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'excepcion_reapertura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS117 correccion y reapertura';
SELECT pg_temp.mk_persona('SP', 3, 'ENS117 solo lectura', 'excepcion_lectura');
-- los tres actores leen excepciones y marcas (el trigger fn_correccion_valida es INVOKER y las lee con la RLS del caller); solo difiere correccion_edicion / excepcion_reapertura
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT pu.id, c.codigo, 'otorgado' FROM personas.puesto pu CROSS JOIN (VALUES ('excepcion_lectura'), ('marca_lectura')) c(codigo)
 WHERE pu.nombre_puesto IN ('ENS117 solo correccion', 'ENS117 correccion y reapertura') OR (pu.nombre_puesto = 'ENS117 solo lectura' AND c.codigo = 'marca_lectura');

-- Marcas reales (solo lectura): PEND = con excepción pendiente y ninguna resuelta, fuera de tramo; RES = solo resueltas, fuera de tramo. autor = cualquier tiempo.persona.
INSERT INTO _ens SELECT 'PEND', min(m.id)::text FROM tiempo.marca m
 WHERE EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.marca_id = m.id AND e.estado = 'pendiente' AND e.motivo_revision NOT LIKE 'dia_cerrado%')
   AND NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.marca_id = m.id AND e.estado = 'resuelto')
   AND NOT EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.marca_apertura_id = m.id OR t.marca_cierre_id = m.id);
-- RES: se fabrica dentro de la transacción (no hay ninguna marca solo-resuelta fuera de tramo): la marca 13907 (pendiente reloj_no_sincronizado, sin tramo) pasa su excepción a resuelta como dueño.
UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE marca_id = 13907 AND estado = 'pendiente' AND motivo_revision = 'reloj_no_sincronizado';
INSERT INTO _ens SELECT 'RES', '13907' WHERE EXISTS (SELECT 1 FROM tiempo.excepcion WHERE marca_id = 13907 AND estado = 'resuelto') AND NOT EXISTS (SELECT 1 FROM tiempo.excepcion WHERE marca_id = 13907 AND estado = 'pendiente');
INSERT INTO _ens SELECT 'AUTOR', id::text FROM tiempo.persona LIMIT 1;
SELECT pg_temp.verifica('PRE las dos marcas y el autor existen', $$SELECT (SELECT count(*) FROM _ens WHERE k IN ('PEND','RES','AUTOR') AND v IS NOT NULL) = 3$$);

-- corrección «idéntica» a la hora actual de la marca: pasa las validaciones de orden y deja solo la policy como variable
CREATE FUNCTION pg_temp.ins(p_marca text) RETURNS text AS $$
  SELECT format('INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (%s, %L::timestamptz, %L, %L::uuid)',
                m.id, m.momento_dispositivo, 'ensayo 117', (SELECT v FROM _ens WHERE k = 'AUTOR'))
  FROM tiempo.marca m WHERE m.id = (SELECT v::bigint FROM _ens WHERE k = p_marca);
$$ LANGUAGE sql;

-- ---------- A) ANTES de 117_ (documenta el defecto) ----------
SELECT pg_temp.caso2('A0 (defecto) ANTES de 117_: correccion_edicion sola, excepción PENDIENTE => 42501 (la policy exige reapertura a todos)', (SELECT v FROM _ens WHERE k = 'auth_CE'), pg_temp.ins('PEND'), '42501');
SELECT pg_temp.verifica('A1 (defecto) ANTES de 117_: la policy compara e.marca_id = e.marca_id',
  $$SELECT with_check LIKE '%e.marca_id = e.marca_id%' FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'correccion' AND policyname = 'correccion_insert_requiere_permiso'$$);

\ir ../ddl/117_tiempo_correccion_insert_policy_marca_propia.sql

-- ---------- B) después de 117_ ----------
SELECT pg_temp.caso2('B1 correccion_edicion sola, excepción PENDIENTE => ok (RH puede corregir)', (SELECT v FROM _ens WHERE k = 'auth_CE'), pg_temp.ins('PEND'), 'ok');
SELECT pg_temp.caso2('B2 correccion_edicion sola, excepción RESUELTA => 42501 (reabrir exige excepcion_reapertura)', (SELECT v FROM _ens WHERE k = 'auth_CE'), pg_temp.ins('RES'), '42501');
SELECT pg_temp.caso2('B3 correccion_edicion + excepcion_reapertura, excepción RESUELTA => ok', (SELECT v FROM _ens WHERE k = 'auth_TI'), pg_temp.ins('RES'), 'ok');
SELECT pg_temp.caso2('B4 correccion_edicion + excepcion_reapertura, excepción PENDIENTE => ok', (SELECT v FROM _ens WHERE k = 'auth_TI'), pg_temp.ins('PEND'), 'ok');
SELECT pg_temp.caso2('B5 sin correccion_edicion, excepción PENDIENTE => 42501', (SELECT v FROM _ens WHERE k = 'auth_SP'), pg_temp.ins('PEND'), '42501');
SELECT pg_temp.caso2('B6 sin correccion_edicion, excepción RESUELTA => 42501', (SELECT v FROM _ens WHERE k = 'auth_SP'), pg_temp.ins('RES'), '42501');
SELECT pg_temp.verifica('B7 la policy sigue siendo INSERT para authenticated, califica correccion.marca_id y ya no compara e.marca_id = e.marca_id',
  $$SELECT count(*) = 1 AND bool_and(cmd = 'INSERT' AND roles = '{authenticated}' AND with_check LIKE '%correccion.marca_id%' AND with_check NOT LIKE '%e.marca_id = e.marca_id%') FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'correccion' AND policyname = 'correccion_insert_requiere_permiso'$$);
SELECT pg_temp.verifica('B8 tiempo.correccion conserva sus 2 policies (insert y select), RLS activada, y el ledger sigue sin UPDATE/DELETE para authenticated',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'correccion') = 2
      AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'tiempo.correccion'::regclass)
      AND NOT has_table_privilege('authenticated', 'tiempo.correccion', 'UPDATE') AND NOT has_table_privilege('authenticated', 'tiempo.correccion', 'DELETE')$$);

-- ---------- C) reversa (texto de 48_) y reaplicación ----------
DROP POLICY correccion_insert_requiere_permiso ON tiempo.correccion;
CREATE POLICY correccion_insert_requiere_permiso ON tiempo.correccion FOR INSERT TO authenticated
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('correccion_edicion')
    AND (NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.marca_id = marca_id AND e.estado = 'resuelto') OR personas.fn_caller_tiene_permiso('excepcion_reapertura')));
SELECT pg_temp.caso2('C1 tras la reversa vuelve el defecto (PENDIENTE con correccion_edicion sola => 42501)', (SELECT v FROM _ens WHERE k = 'auth_CE'), pg_temp.ins('PEND'), '42501');
\ir ../ddl/117_tiempo_correccion_insert_policy_marca_propia.sql
SELECT pg_temp.caso2('C2 reaplicable: vuelve a funcionar', (SELECT v FROM _ens WHERE k = 'auth_CE'), pg_temp.ins('PEND'), 'ok');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
