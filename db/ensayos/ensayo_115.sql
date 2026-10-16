-- Ensayo de 115_personas_asignacion_limite_de_plazas.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_115.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 115_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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


-- puestos de plazas conocidas y personas libres para asignar
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, plazas_totales, reporta_a_id)
SELECT departamento_id, 'ENS115 una plaza', 'operativo', 1, id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, plazas_totales, reporta_a_id)
SELECT departamento_id, 'ENS115 dos plazas', 'operativo', 2, id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, plazas_totales, reporta_a_id)
SELECT departamento_id, 'ENS115 libre', 'operativo', 5, id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO _ens SELECT 'p1', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS115 una plaza';
INSERT INTO _ens SELECT 'p2', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS115 dos plazas';
INSERT INTO _ens SELECT 'plibre', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS115 libre';
-- OBJ, OTRA, S1, S2 y BAJA están sin asignación en estos puestos; asignaciones cerradas para reabrir
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde, vigente_hasta)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'S2'), (SELECT v::uuid FROM _ens WHERE k = 'p1'), CURRENT_DATE - 40, CURRENT_DATE - 2;
INSERT INTO _ens SELECT 'cerrada_S2_p1', id::text FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'S2') AND puesto_id = (SELECT v::uuid FROM _ens WHERE k = 'p1');
-- una asignación vigente de OTRA en el puesto libre (para cambiar-puesto y mover)
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'OTRA'), (SELECT v::uuid FROM _ens WHERE k = 'plibre'), CURRENT_DATE - 5;
INSERT INTO _ens SELECT 'asig_otra_libre', id::text FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'OTRA') AND puesto_id = (SELECT v::uuid FROM _ens WHERE k = 'plibre') AND vigente_hasta IS NULL;

CREATE FUNCTION pg_temp.ins(p_persona text, p_puesto text) RETURNS text AS $$
  SELECT format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, (now() AT TIME ZONE 'America/Mexico_City')::date)$f$, (SELECT v FROM _ens WHERE k = p_persona), (SELECT v FROM _ens WHERE k = p_puesto));
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.hoy() RETURNS date AS $$ SELECT (now() AT TIME ZONE 'America/Mexico_City')::date $$ LANGUAGE sql;

-- Reejecutable tras aplicar 115_ en la base real: si ya existe, se retira DENTRO del ensayo (se revierte con el ROLLBACK) para reproducir el estado «antes»
SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_asignacion_valida_plazas' AND tgrelid = 'personas.asignacion'::regclass) AS ya115 \gset
\if :ya115
DROP TRIGGER trg_asignacion_valida_plazas ON personas.asignacion;
DROP FUNCTION personas.fn_asignacion_valida_plazas();
\endif
-- ANTES de 115_: el hueco (doble alta en un puesto de 1 plaza por la API directa)
SELECT pg_temp.caso2('A0 (documenta el hueco) ANTES de 115_: DOS altas vigentes en un puesto de 1 plaza PASAN por la API directa', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'ok');

\ir ../ddl/115_personas_asignacion_limite_de_plazas.sql

-- A) Estructura
SELECT pg_temp.verifica('A1 trigger BEFORE INSERT OR UPDATE OF puesto_id, vigente_hasta, por fila, habilitado',
  $$SELECT count(*) = 1 AND bool_and((t.tgtype & 1) = 1 AND (t.tgtype & 2) = 2 AND (t.tgtype & 4) = 4 AND (t.tgtype & 16) = 16 AND t.tgenabled = 'O'
        AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a WHERE a.attrelid = t.tgrelid AND a.attnum = ANY (t.tgattr::int2[])) = ARRAY['puesto_id', 'vigente_hasta'])
    FROM pg_trigger t WHERE t.tgrelid = 'personas.asignacion'::regclass AND t.tgname = 'trg_asignacion_valida_plazas'$$);
SELECT pg_temp.verifica('A2 función DEFINER, search_path exacto, dueño postgres, no LEAKPROOF, de tipo trigger y SIN EXECUTE para nadie',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND NOT p.proleakproof AND p.prorettype = 'trigger'::regtype
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_asignacion_valida_plazas'$$);
SELECT pg_temp.verifica('A3 policies siguen en 76', $$SELECT count(*) = 76 FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')$$);

-- B) Altas
SELECT pg_temp.caso2('B1 puesto de 1 plaza VACÍO (S1 y OBJ de la hueco se descartaron: es otro puesto): primer alta => ok', (SELECT v FROM _ens WHERE k = 'auth_R'), pg_temp.ins('OBJ', 'p2'), 'ok');
SELECT pg_temp.caso2('B2 puesto de 1 plaza con 1 vigente + SEGUNDO INSERT => SCJ21 plazas_llenas', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'SCJ21', 'plazas_llenas');
SELECT pg_temp.caso2('B3 puesto de 2 plazas: dos altas ok y la TERCERA => SCJ21', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p2') || '; ' || pg_temp.ins('S1', 'p2') || '; ' || pg_temp.ins('S2', 'p2'), 'SCJ21', 'plazas_llenas');
SELECT pg_temp.caso2('B3b ... las dos primeras solas => ok', (SELECT v FROM _ens WHERE k = 'auth_R'), pg_temp.ins('OBJ', 'p2') || '; ' || pg_temp.ins('S1', 'p2'), 'ok');
SELECT pg_temp.caso2('B4 REABRIR una cerrada en un puesto lleno => SCJ21', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || format($f$; UPDATE personas.asignacion SET vigente_hasta = NULL WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'cerrada_S2_p1')), 'SCJ21', 'plazas_llenas');
SELECT pg_temp.caso2('B4b REABRIR una cerrada en un puesto con plaza libre => ok', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET vigente_hasta = NULL WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'cerrada_S2_p1')), 'ok');
SELECT pg_temp.caso2('B5 MOVER una vigente a un puesto lleno (UPDATE de puesto_id) => SCJ21', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || format($f$; UPDATE personas.asignacion SET puesto_id = %L::uuid WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'p1'), (SELECT v FROM _ens WHERE k = 'asig_otra_libre')), 'SCJ21', 'plazas_llenas');
SELECT pg_temp.caso2('B5b MOVER una vigente a un puesto con plaza libre => ok', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$UPDATE personas.asignacion SET puesto_id = %L::uuid WHERE id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'p2'), (SELECT v FROM _ens WHERE k = 'asig_otra_libre')), 'ok');
SELECT pg_temp.caso2('B6 UPDATE de otras columnas de una vigente en un puesto lleno (p. ej. cerrarla) => ok (no ocupa plaza nueva)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || '; ' || format($f$UPDATE personas.asignacion SET vigente_hasta = (now() AT TIME ZONE 'America/Mexico_City')::date WHERE persona_id = %L::uuid AND puesto_id = %L::uuid$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p1')), 'ok');
SELECT pg_temp.caso2('B7 cerrar la ocupante y dar de alta a otra en la MISMA transacción (cambio de ocupante en 1 plaza) => ok (el conteo ve la propia transacción)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || '; ' || format($f$UPDATE personas.asignacion SET vigente_hasta = (now() AT TIME ZONE 'America/Mexico_City')::date WHERE persona_id = %L::uuid AND puesto_id = %L::uuid; $f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p1')) || pg_temp.ins('S1', 'p1'), 'ok');

-- C) fn_asignacion_cambiar_puesto, baja definitiva, bootstrap
SELECT pg_temp.caso2('C1 cambiar puesto con plaza libre en el destino => ok', (SELECT v FROM _ens WHERE k = 'auth_R'),
  format($f$SELECT personas.fn_asignacion_cambiar_puesto(%L::uuid, %L::uuid, (now() AT TIME ZONE 'America/Mexico_City')::date)$f$, (SELECT v FROM _ens WHERE k = 'asig_otra_libre'), (SELECT v FROM _ens WHERE k = 'p2')), 'ok');
SELECT pg_temp.caso2('C2 cambiar puesto a uno LLENO => SCJ21 (la función revierte completa)', (SELECT v FROM _ens WHERE k = 'auth_R'),
  pg_temp.ins('OBJ', 'p1') || format($f$; SELECT personas.fn_asignacion_cambiar_puesto(%L::uuid, %L::uuid, (now() AT TIME ZONE 'America/Mexico_City')::date)$f$, (SELECT v FROM _ens WHERE k = 'asig_otra_libre'), (SELECT v FROM _ens WHERE k = 'p1')), 'SCJ21', 'plazas_llenas');
DO $$
DECLARE v_abierta int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_R'), 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE pg_temp.ins('OBJ', 'p1');
    BEGIN PERFORM personas.fn_asignacion_cambiar_puesto((SELECT v::uuid FROM _ens WHERE k = 'asig_otra_libre'), (SELECT v::uuid FROM _ens WHERE k = 'p1'), pg_temp.hoy()); EXCEPTION WHEN SQLSTATE 'SCJ21' THEN NULL; END;
    RESET ROLE;
    SELECT count(*) INTO v_abierta FROM personas.asignacion WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'asig_otra_libre') AND vigente_hasta IS NULL;
    INSERT INTO _res (caso, ok, detalle) VALUES ('C2b ... y NO quedó a medias: la asignación original sigue vigente tras el rechazo', v_abierta = 1, format('vigentes=%s', v_abierta));
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'SCJZZ';
  EXCEPTION WHEN SQLSTATE 'SCJZZ' THEN NULL;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$;
SELECT pg_temp.caso2('C3 BAJA DEFINITIVA real con asignación vigente (suspensión + baja; el trigger de bitácora cierra la asignación) => ok', (SELECT v FROM _ens WHERE k = 'auth_S12'),
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens115', %L::uuid);
            INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'baja_definitiva', now(), 'ens115', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12'), (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12')), 'ok');
SELECT pg_temp.caso_interno('C4 BOOTSTRAP: el dueño sin auth.uid() puede sobrepasar la plaza (así nace el usuario base y se tolera el dato actual del puesto administrador) => permitido', 'owner',
  pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'ok');
SELECT pg_temp.caso_interno('C4b BOOTSTRAP: service_role sin auth.uid() => permitido', 'service_role', pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'ok');
SELECT pg_temp.caso2('C5 sin asignacion_edicion (S1) sigue siendo 42501 por RLS (la plaza no cambia la autorización)', (SELECT v FROM _ens WHERE k = 'auth_S1'), pg_temp.ins('OBJ', 'plibre'), '42501');
SELECT pg_temp.verifica('C6 datos reales: el puesto administrador conserva sus vigentes (el trigger no toca filas existentes) y no hay otro puesto real sobre su límite salvo el ya conocido',
  $$SELECT (SELECT count(*) FROM personas.puesto p WHERE p.nombre_puesto NOT LIKE 'ENS11%' AND (SELECT count(*) FROM personas.asignacion a WHERE a.puesto_id = p.id AND a.vigente_hasta IS NULL AND a.persona_id IN (SELECT id FROM personas.persona WHERE primer_nombre NOT LIKE 'Sintetica11%' AND primer_nombre NOT LIKE 'Objetivo11%')) > p.plazas_totales) <= 1$$);

-- C7 guarda de inicio: persona ACTIVA sin asignacion_edicion sobre un puesto LLENO => recibe el 42501 de la RLS (no SCJ21: no se revela la ocupación) y el trigger de plazas NO toma el candado consultivo.
-- Medir pg_locks DESPUÉS del error no sirve (el candado tomado en una subtransacción abortada se libera con ella), así que se usa una SONDA: un trigger de prueba temporal, alfabéticamente DESPUÉS del de plazas
-- (trg_asignacion_zz_sonda), que anota en una secuencia (no transaccional: sobrevive al rollback de la subtransacción) cuántos candados consultivos tiene la sesión en ese momento. Se descarta con el ROLLBACK.
CREATE SEQUENCE pg_temp.sonda_candados;
GRANT USAGE, UPDATE ON SEQUENCE pg_temp.sonda_candados TO PUBLIC;
CREATE FUNCTION pg_temp.sonda_fn() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
  PERFORM setval('pg_temp.sonda_candados', (SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()) + 1, false);
  RETURN NEW;
END $f$;
CREATE TRIGGER trg_asignacion_zz_sonda BEFORE INSERT ON personas.asignacion FOR EACH ROW EXECUTE FUNCTION pg_temp.sonda_fn();
DO $$
DECLARE v_estado text := 'ok'; v_sonda bigint; v_ctrl bigint;
BEGIN
  -- CONTROL: un actor con asignacion_edicion en un puesto LIBRE sí llega a la sonda con el candado tomado (>= 1 candado => valor >= 2)
  BEGIN
    PERFORM setval('pg_temp.sonda_candados', 999, false);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_R'), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE pg_temp.ins('S1', 'plibre');
    RESET ROLE;
    SELECT last_value INTO v_ctrl FROM pg_temp.sonda_candados;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'SCJZZ';
  EXCEPTION WHEN SQLSTATE 'SCJZZ' THEN NULL;
  END;
  RESET ROLE;
  -- PRUEBA: persona activa SIN asignacion_edicion, puesto de 1 plaza LLENO
  BEGIN
    EXECUTE format($f$INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (%L::uuid, %L::uuid, CURRENT_DATE)$f$, (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'p1'));
    PERFORM setval('pg_temp.sonda_candados', 999, false);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_S1'), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
      EXECUTE pg_temp.ins('OTRA', 'p1');   -- a OTRA persona (no a sí misma: eso lo rechazaría 113_ antes de llegar a la sonda)
      v_estado := 'ok';
    EXCEPTION WHEN OTHERS THEN v_estado := SQLSTATE;
    END;
    RESET ROLE;
    SELECT last_value INTO v_sonda FROM pg_temp.sonda_candados;
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'SCJZZ';
  EXCEPTION WHEN SQLSTATE 'SCJZZ' THEN NULL;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES ('C7 guarda de inicio: persona activa SIN asignacion_edicion sobre un puesto lleno => 42501 de la RLS (no SCJ21) y el trigger de plazas NO toma el candado (la sonda posterior ve 0 candados; el control con permiso ve >= 1)',
    v_estado = '42501' AND v_sonda = 1 AND v_ctrl >= 2, format('estado=%s sonda_sin_permiso=%s (1 = 0 candados; 999 = no llegó) control_con_permiso=%s', v_estado, v_sonda, v_ctrl));
END $$;
DROP TRIGGER trg_asignacion_zz_sonda ON personas.asignacion;
SELECT pg_temp.verifica('C7b la guarda está en el cuerpo, justo después de la excepción de auth.uid() nulo y antes del candado',
  $$SELECT position('fn_caller_tiene_permiso(''asignacion_edicion'')' IN prosrc) > position('auth.uid() IS NULL' IN prosrc) AND position('fn_caller_tiene_permiso(''asignacion_edicion'')' IN prosrc) < position('pg_advisory_xact_lock' IN prosrc)
    FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_asignacion_valida_plazas'$$);

-- D) Carrera entre dos altas simultáneas: no se puede ejercer con COMMIT sobre la base real, así que se verifica el MECANISMO (el candado consultivo por puesto) y la lógica
DO $$
DECLARE v_antes int; v_despues int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_R'), 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    SELECT count(*) INTO v_antes FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
    EXECUTE pg_temp.ins('OBJ', 'plibre');
    SELECT count(*) INTO v_despues FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
    INSERT INTO _res (caso, ok, detalle) VALUES ('D1 una alta vigente toma el candado consultivo transaccional del puesto (serializa dos altas simultáneas: la segunda espera a la primera y ve su fila)', v_despues > v_antes, format('candados antes=%s después=%s', v_antes, v_despues));
    RAISE EXCEPTION 'rollback' USING ERRCODE = 'SCJZZ';
  EXCEPTION WHEN SQLSTATE 'SCJZZ' THEN NULL;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$;
SELECT pg_temp.verifica('D2 el cuerpo usa pg_advisory_xact_lock sobre el id del puesto destino y cuenta con id <> NEW.id (no se cuenta a sí misma al reabrir/mover)',
  $$SELECT prosrc LIKE '%pg_advisory_xact_lock%' AND prosrc LIKE '%NEW.puesto_id%' AND prosrc LIKE '%a.id <> NEW.id%' FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_asignacion_valida_plazas'$$);

-- E) Reversa y reaplicación
DROP TRIGGER trg_asignacion_valida_plazas ON personas.asignacion;
DROP FUNCTION personas.fn_asignacion_valida_plazas();
SELECT pg_temp.caso2('E1 tras la reversa vuelve el hueco (doble alta en 1 plaza pasa)', (SELECT v FROM _ens WHERE k = 'auth_R'), pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'ok');
SELECT pg_temp.verifica('E2 tras la reversa no quedan ni el trigger ni la función', $$SELECT NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_asignacion_valida_plazas') AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'fn_asignacion_valida_plazas')$$);
\ir ../ddl/115_personas_asignacion_limite_de_plazas.sql
SELECT pg_temp.caso2('E3 reaplicable: la doble alta vuelve a rechazarse', (SELECT v FROM _ens WHERE k = 'auth_R'), pg_temp.ins('OBJ', 'p1') || '; ' || pg_temp.ins('S1', 'p1'), 'SCJ21', 'plazas_llenas');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
