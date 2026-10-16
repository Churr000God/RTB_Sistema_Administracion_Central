-- Ensayo de 113_personas_asignacion_reglas_autoasignacion_y_vigencia.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_113.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 113_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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

-- ---------- fixture ----------
CREATE FUNCTION pg_temp.mk_persona(p_k text, p_n int, p_puesto text, p_permiso text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica110' || p_k, 'Ensayo110', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
  VALUES ((SELECT v::uuid FROM _ens WHERE k = p_k), 'indefinido', 'RTB-RH-EIT-2026-' || (900 + p_n));
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens110' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens110' || lower(p_k));
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

SELECT pg_temp.mk_persona('S1', 1, NULL, NULL);                                      -- sin puesto
SELECT pg_temp.mk_persona('S2', 2, 'ENS110 sin permisos', NULL);                     -- puesto sin permisos
SELECT pg_temp.mk_persona('S3', 3, 'ENS110 tiempo', 'marca_lectura');                -- solo Tiempo
SELECT pg_temp.mk_persona('S4', 4, 'ENS110 terminales', 'terminal_usuario_lectura'); -- solo Terminales
SELECT pg_temp.mk_persona('S5', 5, 'ENS110 rh modulo1', 'ver_modulo_1');             -- RH/TI
SELECT pg_temp.mk_persona('S6', 6, 'ENS110 alta', 'alta_personas_usuarios');
SELECT pg_temp.mk_persona('S7', 7, 'ENS110 edicion', 'persona_edicion');
SELECT pg_temp.mk_persona('S8', 8, 'ENS110 cambio estado', 'cambio_estado_persona');
SELECT pg_temp.mk_persona('S9', 9, 'ENS110 suspendida', 'ver_modulo_1');             -- se suspende abajo
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'S9');
-- RH completo: persona_edicion + alta_personas_usuarios (el INSERT ... ON CONFLICT de expediente exige la policy de INSERT, que es de alta)
SELECT pg_temp.mk_persona('S11', 11, 'ENS110 edicion y alta', 'persona_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'alta_personas_usuarios', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS110 edicion y alta';
-- Actor de baja/reactivación: cambio_estado_persona + asignacion_edicion (la baja definitiva cierra las asignaciones vigentes)
SELECT pg_temp.mk_persona('S12', 12, 'ENS110 baja y asignaciones', 'cambio_estado_persona');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'asignacion_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS110 baja y asignaciones';
-- Persona con asignación vigente para la baja definitiva
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV22', 'XEXV01010022', '99999700022', 'Baja110', 'Ensayo110', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'BAJA', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV22';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS110 puesto de la baja', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'BAJA'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS110 puesto de la baja';
-- Jefe sin permisos propios: hereda persona_edicion (heredable) de su subordinado
SELECT pg_temp.mk_persona('S10', 10, 'ENS110 jefe herencia', NULL);
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS110 subordinado herencia', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'ENS110 jefe herencia';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'persona_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS110 subordinado herencia';
-- Objetivo: persona con expediente, sin usuario
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV20', 'XEXV01010020', '99999700020', 'Objetivo110', 'Ensayo110', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'OBJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV20';
INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'OBJ'), 'indefinido', 'RTB-RH-EIT-2026-920');
-- Segunda persona con CURP conocida para los casos de duplicado
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV21', 'XEXV01010021', '99999700021', 'Otra110', 'Ensayo110', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'OTRA', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV21';

INSERT INTO _ens SELECT 'tot_p', count(*)::text FROM personas.persona;
INSERT INTO _ens SELECT 'tot_e', count(*)::text FROM personas.expediente;

-- ---------- actores y objetos propios de este ensayo ----------
SELECT pg_temp.mk_persona('R', 30, 'ENS113 puesto rh', 'asignacion_edicion');            -- RH: puede asignar; tiene SU PROPIA asignación vigente
SELECT pg_temp.mk_persona('V', 31, 'ENS113 puesto poderoso', 'alta_personas_usuarios');  -- víctima: ocupa un puesto con más permisos
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS113 puesto libre', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS113 puesto destino', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
-- OTRA (sin usuario) con una asignación vigente para probar fn_asignacion_cambiar_puesto
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'OTRA'), id, CURRENT_DATE - 5 FROM personas.puesto WHERE nombre_puesto = 'ENS113 puesto libre';
INSERT INTO _ens SELECT 'asig_otra', id::text FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'OTRA') AND vigente_hasta IS NULL;
INSERT INTO _ens SELECT 'asig_propia_R', id::text FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'R') AND vigente_hasta IS NULL;
INSERT INTO _ens SELECT 'asig_V', id::text FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'V') AND vigente_hasta IS NULL;
INSERT INTO _ens SELECT 'p_poderoso', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS113 puesto poderoso';
INSERT INTO _ens SELECT 'p_libre', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS113 puesto libre';
INSERT INTO _ens SELECT 'p_destino', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS113 puesto destino';
INSERT INTO _ens SELECT 'p_rh', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS113 puesto rh';

-- caso con SQLSTATE y HINT
CREATE FUNCTION pg_temp.caso2(p_caso text, p_sub text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  IF p_sub IS NULL THEN PERFORM set_config('request.jwt.claims', '', true); SET LOCAL ROLE authenticated;   -- sin sub no es un caller válido: se usa el rol de servicio
  ELSE PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated; END IF;
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
-- igual pero como rol interno sin sesión (dueño / service_role sin auth.uid())
CREATE FUNCTION pg_temp.caso_interno(p_caso text, p_rol text, p_sql text, p_state text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_rol = 'service_role' THEN '{"role":"service_role"}' ELSE '' END, true);
  IF p_rol <> 'owner' THEN EXECUTE format('SET LOCAL ROLE %I', p_rol); END IF;
  BEGIN
    EXECUTE p_sql; RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION WHEN SQLSTATE 'SCJZZ' THEN NULL; WHEN OTHERS THEN v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state, format('obtenido=%s %s', v_state, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- ---------- ANTES de 113_: el hueco ----------
SELECT pg_temp.caso2('A0 (documenta el hueco) ANTES de 113_: RH se asigna a sí mismo al puesto de la víctima (cadena completa: termina la ajena y se asigna)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = CURRENT_DATE WHERE id = %L::uuid; INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE)$f$,
         (SELECT v FROM _ens WHERE k = 'asig_V'), (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_poderoso')), 'ok');
SELECT pg_temp.caso2('A0b ANTES de 113_: asignación con vigente_desde FUTURO aceptada (da permisos YA)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE + 30)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'ok');

\ir ../ddl/113_personas_asignacion_reglas_autoasignacion_y_vigencia.sql

-- ============================================================================
-- A) Estructura
-- ============================================================================
SELECT pg_temp.verifica('A1 trigger BEFORE INSERT OR UPDATE OF persona_id, puesto_id, vigente_desde, FOR EACH ROW, habilitado, sobre personas.asignacion',
  $$SELECT count(*) = 1 AND bool_and((t.tgtype & 2) = 2 AND (t.tgtype & 4) = 4 AND (t.tgtype & 16) = 16 AND (t.tgtype & 1) = 1 AND t.tgenabled = 'O'
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a WHERE a.attrelid = t.tgrelid AND a.attnum = ANY (t.tgattr::int2[])) = ARRAY['persona_id', 'puesto_id', 'vigente_desde'])
    FROM pg_trigger t WHERE t.tgrelid = 'personas.asignacion'::regclass AND t.tgname = 'trg_asignacion_valida_reglas'$$);
SELECT pg_temp.verifica('A2 la función del trigger: INVOKER, search_path fijo, retorna trigger, SIN EXECUTE para nadie (ni PUBLIC, anon, authenticated ni service_role)',
  $$SELECT NOT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND p.prorettype = 'trigger'::regtype
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_asignacion_valida_reglas'$$);
SELECT pg_temp.verifica('A3 fn_hoy_mexico: STABLE, INVOKER, search_path fijo, EXECUTE solo authenticated y service_role',
  $$SELECT NOT p.prosecdef AND p.provolatile = 's' AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_hoy_mexico'$$);
SELECT pg_temp.verifica('A4 policies siguen en 76 (113_ no toca RLS)', $$SELECT count(*) = 76 FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')$$);

-- ============================================================================
-- B) Autoasignación
-- ============================================================================
SELECT pg_temp.caso2('B1 INSERT de una asignación PROPIA (RH a sí mismo) => SCJ19', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'SCJ19', 'autoasignacion_no_permitida');
SELECT pg_temp.caso2('B2 UPDATE de puesto_id en la fila PROPIA (recolocarse) => SCJ19', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET puesto_id = %L::uuid WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'p_poderoso'), (SELECT v FROM _ens WHERE k = 'asig_propia_R')), 'SCJ19', 'autoasignacion_no_permitida');
SELECT pg_temp.caso2('B3 UPDATE de persona_id de una fila AJENA a sí mismo => SCJ19', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET persona_id = %L::uuid WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'asig_V')), 'SCJ19', 'autoasignacion_no_permitida');
SELECT pg_temp.caso2('B4 CADENA: terminar la asignación ajena (paso 1 permitido) y asignarse a sí mismo (último paso) => SCJ19', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = personas.fn_hoy_mexico() WHERE id = %L::uuid; INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$,
         (SELECT v FROM _ens WHERE k = 'asig_V'), (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_poderoso')), 'SCJ19', 'autoasignacion_no_permitida');
SELECT pg_temp.caso2('B4b ... el paso 1 solo (terminar la ajena) sigue permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = personas.fn_hoy_mexico() WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'asig_V')), 'ok');
SELECT pg_temp.caso2('B5 asignar a OTRA persona => permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'ok');
SELECT pg_temp.caso2('B6 mover una fila ajena a OTRO puesto (UPDATE puesto_id de la asignación de V) => permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET puesto_id = %L::uuid WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'p_destino'), (SELECT v FROM _ens WHERE k = 'asig_V')), 'ok');
SELECT pg_temp.caso2('B7 terminar la asignación PROPIA (UPDATE de vigente_hasta) no está cubierto por la regla (no cambia persona ni puesto): permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = personas.fn_hoy_mexico() WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'asig_propia_R')), 'ok');
SELECT pg_temp.caso_interno('B8 BOOTSTRAP: dueño sin auth.uid() asigna a una persona a un puesto (así nace el usuario base) => permitido', 'owner',
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_poderoso')), 'ok');
SELECT pg_temp.caso_interno('B9 BOOTSTRAP: service_role sin auth.uid() => permitido (también para una persona que es "el caller" del resto del ensayo)', 'service_role',
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE)$f$, (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_poderoso')), 'ok');

-- ============================================================================
-- C) Vigencia futura (hora de México)
-- ============================================================================
SELECT pg_temp.caso2('C1 INSERT con vigente_desde = mañana (México) => SCJ20', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico() + 1)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'SCJ20', 'vigencia_futura_no_permitida');
SELECT pg_temp.caso2('C2 INSERT con vigente_desde = hoy (México) => permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'ok');
SELECT pg_temp.caso2('C3 INSERT con vigente_desde pasado (hace 400 días) => permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico() - 400)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), 'ok');
SELECT pg_temp.caso2('C4 UPDATE de vigente_desde de una fila ajena a mañana => SCJ20', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_desde = personas.fn_hoy_mexico() + 1 WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'asig_otra')), 'SCJ20', 'vigencia_futura_no_permitida');
SELECT pg_temp.caso2('C4b UPDATE de vigente_desde de una fila ajena a una fecha pasada => permitido', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_desde = personas.fn_hoy_mexico() - 10 WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'asig_otra')), 'ok');
SELECT pg_temp.verifica('C5 FRANJA 18:00–24:00 CDMX (fn_hoy_mexico con instantes explícitos): 17:59 CDMX = día N, 18:00 CDMX (00:00 UTC del N+1) = día N, 23:59 CDMX = día N, 00:00 CDMX (06:00 UTC) = N+1; la fecha UTC (CURRENT_DATE) iría un día adelante en la franja',
  $$SELECT personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-16 23:59:59+00') = DATE '2026-10-16'
      AND personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 00:00:00+00') = DATE '2026-10-16'
      AND personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 05:59:59+00') = DATE '2026-10-16'
      AND personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 06:00:00+00') = DATE '2026-10-17'
      AND (TIMESTAMPTZ '2026-10-17 03:00:00+00')::date = DATE '2026-10-17' AND personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 03:00:00+00') = DATE '2026-10-16'
      AND personas.fn_hoy_mexico(TIMESTAMPTZ '2026-12-31 23:00:00-06') = DATE '2026-12-31' AND personas.fn_hoy_mexico(TIMESTAMPTZ '2027-01-01 06:00:00+00') = DATE '2027-01-01'$$);
SELECT pg_temp.verifica('C6 el trigger usa la fecha de México: en la franja (p. ej. 19:00 CDMX = 01:00 UTC del día siguiente) una asignación con la fecha de México de HOY se acepta y la fecha UTC (mañana en México) se rechaza: la comparación del trigger (vigente_desde > fn_hoy_mexico(now())) es la misma expresión',
  $$SELECT NOT (DATE '2026-10-16' > personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 01:00:00+00')) AND (DATE '2026-10-17' > personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-17 01:00:00+00'))
      AND (SELECT prosrc LIKE '%fn_hoy_mexico(now())%' AND prosrc NOT LIKE '%CURRENT_DATE%' FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_asignacion_valida_reglas')$$);
SELECT pg_temp.caso_interno('C7 camino interno sin auth.uid() (dueño) con fecha futura => permitido a propósito (migraciones/bootstrap con CURRENT_DATE UTC no se rompen en la franja)', 'owner',
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE + 1)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_destino')), 'ok');

-- ============================================================================
-- D) Lo que NO debe romperse
-- ============================================================================
SELECT pg_temp.caso2('D1 fn_asignacion_cambiar_puesto de una asignación AJENA con fecha de hoy => ok', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$SELECT personas.fn_asignacion_cambiar_puesto(%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'asig_otra'), (SELECT v FROM _ens WHERE k = 'p_destino')), 'ok');
SELECT pg_temp.caso2('D2 ... con fecha FUTURA => SCJ20 (y no queda nada a medias: la función es una transacción)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$SELECT personas.fn_asignacion_cambiar_puesto(%L::uuid, %L::uuid, personas.fn_hoy_mexico() + 3)$f$, (SELECT v FROM _ens WHERE k = 'asig_otra'), (SELECT v FROM _ens WHERE k = 'p_destino')), 'SCJ20', 'vigencia_futura_no_permitida');
SELECT pg_temp.caso2('D3 ... sobre la asignación PROPIA (recolocarse con el RPC) => SCJ19', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$SELECT personas.fn_asignacion_cambiar_puesto(%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'asig_propia_R'), (SELECT v FROM _ens WHERE k = 'p_destino')), 'SCJ19', 'autoasignacion_no_permitida');
SELECT pg_temp.caso2('D4 BAJA DEFINITIVA real de una persona con asignación vigente (trigger de bitácora cierra la asignación: UPDATE de vigente_hasta) => ok', (SELECT v FROM _ens WHERE k = 'auth_S12'),
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens113', %L::uuid);
            INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'baja_definitiva', now(), 'ens113', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12'), (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12')), 'ok');
SELECT pg_temp.caso2('D5 cambio de estado (suspensión) de otra persona => ok', (SELECT v FROM _ens WHERE k = 'auth_S12'),
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens113', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S12')), 'ok');
SELECT pg_temp.caso2('D6 sin asignacion_edicion (S1) no puede asignar a nadie: sigue siendo 42501 por RLS (la regla no cambia la autorización)', (SELECT v FROM _ens WHERE k = 'auth_S1'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p_libre')), '42501');

-- ============================================================================
-- E) Reversa y reaplicación
-- ============================================================================
DROP TRIGGER trg_asignacion_valida_reglas ON personas.asignacion;
DROP FUNCTION personas.fn_asignacion_valida_reglas();
DROP FUNCTION personas.fn_hoy_mexico(timestamptz);
SELECT pg_temp.caso2('E1 tras la reversa se vuelve al hueco de antes (A0: la cadena completa vuelve a pasar)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = CURRENT_DATE WHERE id = %L::uuid; INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE)$f$,
         (SELECT v FROM _ens WHERE k = 'asig_V'), (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_poderoso')), 'ok');
SELECT pg_temp.verifica('E2 tras la reversa no quedan ni el trigger ni las 2 funciones', $$SELECT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_asignacion_valida_reglas') AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('fn_asignacion_valida_reglas', 'fn_hoy_mexico'))$$);
\ir ../ddl/113_personas_asignacion_reglas_autoasignacion_y_vigencia.sql
SELECT pg_temp.caso2('E3 reaplicable: la cadena vuelve a rechazarse', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, personas.fn_hoy_mexico())$f$, (SELECT v FROM _ens WHERE k = 'R'), (SELECT v FROM _ens WHERE k = 'p_destino')), 'SCJ19');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
