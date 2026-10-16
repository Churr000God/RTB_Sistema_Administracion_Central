-- Ensayo de 112_personas_fn_caller_tiene_permiso_definer.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_112.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 112_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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
-- ---------- batería de equivalencia (se corre ANTES y DESPUÉS de 110_; cada caso se revierte con una excepción y el resultado compara código SQLSTATE + huella de la fila) ----------
CREATE TEMP TABLE _bat (fase text, caso text, resultado text);
GRANT ALL ON _bat TO PUBLIC;
CREATE FUNCTION pg_temp.huella(p_id uuid) RETURNS text AS $$
  SELECT COALESCE((SELECT md5(concat_ws('|', curp, rfc, nss, primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, fecha_nacimiento::text, fecha_ingreso::text, estado, fecha_baja::text)
                        || '|' || COALESCE((SELECT concat_ws('|', e.tipo_contrato, e.documento_ref) FROM personas.expediente e WHERE e.persona_id = p.id), '-'))
                  FROM personas.persona p WHERE p.id = p_id), 'sin-fila');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.corre(p_fase text, p_caso text, p_auth text, p_sql text, p_verifica uuid DEFAULT NULL, p_curp text DEFAULT NULL, p_prep text DEFAULT NULL) RETURNS void AS $$
DECLARE v_out text := '?';
BEGIN
  BEGIN
    IF p_prep IS NOT NULL THEN EXECUTE p_prep; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql;
    RESET ROLE;
    v_out := 'ok:' || COALESCE(pg_temp.huella(COALESCE(p_verifica, (SELECT id FROM personas.persona WHERE curp = p_curp))), '-');
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_out := SQLSTATE;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _bat VALUES (p_fase, p_caso, v_out);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.bateria(p_fase text) RETURNS void AS $$
DECLARE
  obj  text := (SELECT v FROM _ens WHERE k = 'OBJ');
  otra text := (SELECT v FROM _ens WHERE k = 'OTRA');
  s1 text := (SELECT v FROM _ens WHERE k = 'auth_S1');  s6 text := (SELECT v FROM _ens WHERE k = 'auth_S6');
  s7 text := (SELECT v FROM _ens WHERE k = 'auth_S7');  s8 text := (SELECT v FROM _ens WHERE k = 'auth_S8');
  s10 text := (SELECT v FROM _ens WHERE k = 'auth_S10'); s11 text := (SELECT v FROM _ens WHERE k = 'auth_S11'); s9 text := (SELECT v FROM _ens WHERE k = 'auth_S9');
  base text := 'SELECT personas.fn_persona_actualizar_datos(' || quote_literal(obj) || '::uuid';
BEGIN
  PERFORM pg_temp.corre(p_fase, 'U01 solo nombre', s7, base || ', p_primer_nombre => ''Editado'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U02 curp en minúsculas (sin normalizar en SQL: igual que antes)', s7, base || ', p_curp => ''xexx010101hnexxv30'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U03 rfc + nss + fecha_nacimiento + fecha_ingreso', s7, base || ', p_rfc => ''XEXV01010099'', p_nss => ''99999700099'', p_fecha_nacimiento => DATE ''1990-05-05'', p_fecha_ingreso => DATE ''2020-01-01'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U15 solo fecha_ingreso', s7, base || ', p_fecha_ingreso => DATE ''2021-03-03'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U04 todos nulos (solo actualizado_en)', s7, base || ')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U05 tipo_contrato + documento_ref', s11, base || ', p_tipo_contrato => ''por_proyecto'', p_documento_ref => ''RTB-RH-EIT-2026-931'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U06 solo documento_ref con formato inválido (23514)', s11, base || ', p_documento_ref => ''mal'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U07 curp duplicada de otra persona (23505)', s7, base || ', p_curp => ''XEXX010101HNEXXV21'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U08 persona inexistente (SCJ10)', s7, 'SELECT personas.fn_persona_actualizar_datos(gen_random_uuid(), p_primer_nombre => ''x'')');
  PERFORM pg_temp.corre(p_fase, 'U09 solo cambio_estado_persona intenta cambiar identidad (42501 del trigger)', s8, base || ', p_curp => ''XEXX010101HNEXXV31'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U10 persona sin permisos (RLS: 0 filas => SCJ10)', s1, base || ', p_primer_nombre => ''x'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U11 suspendida (RLS: 0 filas => SCJ10)', s9, base || ', p_primer_nombre => ''x'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U12 jefe que HEREDA persona_edicion', s10, base || ', p_primer_nombre => ''Heredado'')', obj::uuid);
  PERFORM pg_temp.corre(p_fase, 'U13 expediente sin existir para la persona: solo tipo_contrato (23502 NOT NULL)', s11,
    'SELECT personas.fn_persona_actualizar_datos(' || quote_literal(otra) || '::uuid, p_tipo_contrato => ''por_proyecto'')', otra::uuid, NULL,
    'DELETE FROM personas.expediente WHERE persona_id = ' || quote_literal(otra) || '::uuid');
  PERFORM pg_temp.corre(p_fase, 'U14 expediente creado por edición (ambos campos, persona sin expediente)', s11,
    'SELECT personas.fn_persona_actualizar_datos(' || quote_literal(otra) || '::uuid, p_tipo_contrato => ''por_proyecto'', p_documento_ref => ''RTB-RH-EIT-2026-932'')', otra::uuid, NULL,
    'DELETE FROM personas.expediente WHERE persona_id = ' || quote_literal(otra) || '::uuid');
  -- crear
  PERFORM pg_temp.corre(p_fase, 'C01 crear normal (minúsculas en curp/rfc: se normalizan)', s6,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''  xexx010101hnexxv40 '', ''xexv01010040'', ''99999700040'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''RTB-RH-EIT-2026-940'')',
    NULL, 'XEXX010101HNEXXV40');
  PERFORM pg_temp.corre(p_fase, 'C02 crear con nombres opcionales', s6,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV41'', ''XEXV01010041'', ''99999700041'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''RTB-RH-EIT-2026-941'', ''Segundo'', ''Materno'')', NULL, 'XEXX010101HNEXXV41');
  PERFORM pg_temp.corre(p_fase, 'C03 curp duplicada (23505)', s6,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV20'', ''XEXV01010042'', ''99999700042'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''RTB-RH-EIT-2026-942'')');
  PERFORM pg_temp.corre(p_fase, 'C04 documento_ref con formato inválido (23514, no queda persona)', s6,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV43'', ''XEXV01010043'', ''99999700043'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''mal'')');
  PERFORM pg_temp.corre(p_fase, 'C05 sin alta_personas_usuarios (42501)', s1,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV44'', ''XEXV01010044'', ''99999700044'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''RTB-RH-EIT-2026-944'')');
  PERFORM pg_temp.corre(p_fase, 'C06 solo persona_edicion no puede crear (42501)', s7,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV45'', ''XEXV01010045'', ''99999700045'', DATE ''2000-02-02'', CURRENT_DATE, ''indefinido'', ''RTB-RH-EIT-2026-945'')');
  PERFORM pg_temp.corre(p_fase, 'C07 tipo_contrato fuera de dominio (23514)', s6,
    'SELECT personas.fn_persona_crear(''Alta'', ''Nueva'', ''XEXX010101HNEXXV46'', ''XEXV01010046'', ''99999700046'', DATE ''2000-02-02'', CURRENT_DATE, ''inexistente'', ''RTB-RH-EIT-2026-946'')');
END;
$$ LANGUAGE plpgsql;

-- Casos de borde extra: S13 ocupa un puesto SUBORDINADO que tiene un permiso heredable (persona_edicion ya está en ese puesto) y uno NO heredable (terminal_usuario_edicion);
-- el JEFE (S10) tiene propio excepcion_lectura: el subordinado NO debe heredarlo hacia abajo.
SELECT pg_temp.mk_persona('S13', 13, NULL, NULL);
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'S13'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS110 subordinado herencia';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'terminal_usuario_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS110 subordinado herencia';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'excepcion_lectura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS110 jefe herencia';
-- Persona de baja definitiva y con usuario (no activa): ver_modulo_1 por su puesto
SELECT pg_temp.mk_persona('S14', 14, 'ENS110 baja con permisos', 'ver_modulo_1');
UPDATE personas.persona SET estado = 'baja_definitiva' WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'S14');

-- ---------- instantáneas ----------
CREATE TEMP TABLE _f (fase text, quien text, clave text, valor text);       -- valor de cada función de permiso por persona y código
CREATE TEMP TABLE _c (fase text, quien text, tabla text, valor text);       -- filas visibles por persona y tabla (o SQLSTATE)
CREATE TEMP TABLE _p (fase text, consulta text, ms numeric);                 -- rendimiento
GRANT ALL ON _f, _c, _p TO PUBLIC;

CREATE FUNCTION pg_temp.como(p_quien text) RETURNS void AS $$
BEGIN
  IF p_quien = 'service_role' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true); SET LOCAL ROLE service_role;
  ELSIF p_quien = 'sin_sub' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = p_quien), 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  END IF;
END $$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.snap(p_fase text) RETURNS void AS $$
DECLARE q text; t record; cod text; v text; n bigint;
BEGIN
  FOR q IN SELECT k FROM _ens WHERE k LIKE 'auth\_%' ESCAPE '\' UNION ALL SELECT 'sin_sub' UNION ALL SELECT 'service_role' LOOP
    PERFORM pg_temp.como(q);
    FOR cod IN SELECT codigo FROM personas.permiso UNION ALL SELECT 'codigo_inexistente' LOOP
      BEGIN v := personas.fn_caller_tiene_permiso(cod)::text; EXCEPTION WHEN OTHERS THEN v := SQLSTATE; END;
      INSERT INTO _f VALUES (p_fase, q, 'tiene:' || cod, v);
    END LOOP;
    FOREACH cod IN ARRAY ARRAY['fn_caller_ve_padron', 'fn_caller_ve_identidad', 'fn_caller_ve_estructura_permisos', 'fn_caller_activo'] LOOP
      BEGIN EXECUTE format('SELECT personas.%I()::text', cod) INTO v; EXCEPTION WHEN OTHERS THEN v := SQLSTATE; END;
      INSERT INTO _f VALUES (p_fase, q, 'fn:' || cod, v);
    END LOOP;
    FOR t IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind = 'r' AND c.relrowsecurity ORDER BY 1, 2 LOOP
      BEGIN EXECUTE format('SELECT count(*) FROM %I.%I', t.nspname, t.relname) INTO n; v := n::text; EXCEPTION WHEN OTHERS THEN v := SQLSTATE; END;
      INSERT INTO _c VALUES (p_fase, q, t.nspname || '.' || t.relname, v);
    END LOOP;
    RESET ROLE;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.perf(p_fase text) RETURNS void AS $$
DECLARE i int; j json; r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('directorio', 'SELECT p.id, p.primer_nombre, p.apellido_paterno, e.tipo_contrato FROM personas.persona p LEFT JOIN personas.expediente e ON e.persona_id = p.id ORDER BY p.apellido_paterno'),
    ('ficha', 'SELECT p.id, p.primer_nombre, (SELECT count(*) FROM personas.usuario u WHERE u.persona_id = p.id), (SELECT count(*) FROM personas.asignacion a WHERE a.persona_id = p.id) FROM personas.persona p WHERE p.id = (SELECT id FROM personas.persona ORDER BY id LIMIT 1)'),
    ('tiempo ausencias con nombres', 'SELECT a.id, p.primer_nombre, p.apellido_paterno FROM tiempo.ausencia a JOIN personas.persona p ON p.id = a.persona_id'),
    ('asignaciones con nombres', 'SELECT a.id, p.primer_nombre FROM personas.asignacion a JOIN personas.persona p ON p.id = a.persona_id WHERE a.vigente_hasta IS NULL')
  ) AS x(nombre, sql) LOOP
    FOR i IN 1..5 LOOP
      PERFORM pg_temp.como('auth_admin');
      EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || r.sql INTO j;
      RESET ROLE;
      INSERT INTO _p VALUES (p_fase, r.nombre, (j->0->>'Execution Time')::numeric);
    END LOOP;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;

-- ---------- ANTES de 112_ ----------
INSERT INTO _ens SELECT 'def_antes', pg_get_functiondef('personas.fn_caller_tiene_permiso(text)'::regprocedure);
SELECT pg_temp.snap('antes');
SELECT pg_temp.bateria('antes');
SELECT pg_temp.perf('antes');
SELECT pg_temp.verifica('A0 ANTES: fn_caller_tiene_permiso es SECURITY INVOKER (documenta el punto de partida)', $$SELECT NOT prosecdef FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);

\ir ../ddl/112_personas_fn_caller_tiene_permiso_definer.sql

SELECT pg_temp.snap('despues');
SELECT pg_temp.bateria('despues');
SELECT pg_temp.perf('despues');

-- ============================================================================
-- A) Estructura
-- ============================================================================
SELECT pg_temp.verifica('A1 SECURITY DEFINER, STABLE, search_path = personas, pg_temp, dueño postgres, no LEAKPROOF, devuelve boolean, un solo parámetro text',
  $$SELECT p.prosecdef AND p.provolatile = 's' AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND NOT p.proleakproof
        AND pg_get_function_result(p.oid) = 'boolean' AND pg_get_function_arguments(p.oid) = 'p_codigo text'
    FROM pg_proc p WHERE p.oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);
SELECT pg_temp.verifica('A2 EXECUTE solo authenticated y service_role (ni PUBLIC ni anon)',
  $$SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);
SELECT pg_temp.verifica('A3 la función solo usa auth.uid() y devuelve boolean: su cuerpo no usa ninguna identidad ajena (parámetro único = código) y empieza con la guarda de persona activa',
  $$SELECT prosrc LIKE '%auth.uid()%' AND prosrc LIKE '%personas.fn_caller_activo()%' AND prosrc !~* 'p_persona|p_usuario|p_auth' FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);
SELECT pg_temp.verifica('A4 policies totales sigue en 76 y las 64 que la usan no cambiaron',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 76
      AND (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo') AND (qual LIKE '%fn_caller_tiene_permiso%' OR with_check LIKE '%fn_caller_tiene_permiso%')) = 64$$);

-- ============================================================================
-- B) Equivalencia
-- ============================================================================
SELECT pg_temp.verifica('B1 fn_caller_tiene_permiso: el MISMO valor antes y después para TODOS los códigos (53 + uno inexistente) y todas las personas del fixture, el admin real, una sesión sin sub y service_role',
  $$SELECT count(*) = (SELECT count(*) FROM _f WHERE fase = 'antes' AND clave LIKE 'tiene:%') AND bool_and(a.valor = d.valor)
    FROM _f a JOIN _f d ON d.clave = a.clave AND d.quien = a.quien AND d.fase = 'despues' WHERE a.fase = 'antes' AND a.clave LIKE 'tiene:%'$$);
SELECT pg_temp.verifica('B1b ... y la muestra es significativa: hay valores true y false, y al menos 700 comparaciones',
  $$SELECT count(*) >= 700 AND bool_or(valor = 'true') AND bool_or(valor = 'false') FROM _f WHERE fase = 'despues' AND clave LIKE 'tiene:%'$$);
SELECT pg_temp.verifica('B2 las funciones que dependen de ella (ve_padron, ve_identidad, ve_estructura_permisos, activo): mismo valor antes y después para cada persona',
  $$SELECT count(*) = (SELECT count(*) FROM _f WHERE fase = 'antes' AND clave LIKE 'fn:%') AND bool_and(a.valor = d.valor)
    FROM _f a JOIN _f d ON d.clave = a.clave AND d.quien = a.quien AND d.fase = 'despues' WHERE a.fase = 'antes' AND a.clave LIKE 'fn:%'$$);
SELECT pg_temp.verifica('B3 filas visibles por persona en CADA tabla de personas y tiempo con RLS (SELECT de todas las policies que la usan): mismo resultado antes y después, sin ningún error nuevo',
  $$SELECT count(*) = (SELECT count(*) FROM _c WHERE fase = 'antes') AND bool_and(a.valor = d.valor)
    FROM _c a JOIN _c d ON d.tabla = a.tabla AND d.quien = a.quien AND d.fase = 'despues' WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('B3b ... sobre un conjunto amplio de tablas (>= 30) y sin recursión ni 54001 (stack depth) en ninguna lectura',
  $$SELECT count(DISTINCT tabla) >= 30 AND NOT bool_or(valor IN ('54001', '42P17')) FROM _c WHERE fase = 'despues'$$);
SELECT pg_temp.verifica('B4 batería de crear/actualizar (INSERT/UPDATE bajo RLS y triggers, 22 casos): SQLSTATE y huella idénticos antes y después',
  $$SELECT count(*) = 22 AND bool_and(a.resultado = d.resultado) FROM _bat a JOIN _bat d ON d.caso = a.caso AND d.fase = 'despues' WHERE a.fase = 'antes'$$);

-- ============================================================================
-- C) Casos de borde, valores concretos
-- ============================================================================
CREATE FUNCTION pg_temp.v(p_fase text, p_quien text, p_clave text) RETURNS text AS $$ SELECT valor FROM _f WHERE fase = p_fase AND quien = p_quien AND clave = p_clave $$ LANGUAGE sql;
SELECT pg_temp.verifica('C1 suspendida (S9, ver_modulo_1 por su puesto) => false en TODO, antes y después (la guarda de persona activa conserva el efecto de la RLS); baja definitiva (S14) igual',
  $$SELECT NOT EXISTS (SELECT 1 FROM _f WHERE fase IN ('antes', 'despues') AND quien IN ('auth_S9', 'auth_S14') AND clave LIKE 'tiene:%' AND valor <> 'false')$$);
SELECT pg_temp.verifica('C2 persona sin puesto (S1) y sesión sin sub y service_role => false en todo',
  $$SELECT NOT EXISTS (SELECT 1 FROM _f WHERE fase = 'despues' AND quien IN ('auth_S1', 'sin_sub', 'service_role') AND clave LIKE 'tiene:%' AND valor <> 'false')$$);
SELECT pg_temp.verifica('C3 jefe que hereda (S10): persona_edicion = true (heredable del subordinado), terminal_usuario_edicion = false (NO heredable), excepcion_lectura = true (propio)',
  $$SELECT pg_temp.v('despues', 'auth_S10', 'tiene:persona_edicion') = 'true' AND pg_temp.v('despues', 'auth_S10', 'tiene:terminal_usuario_edicion') = 'false' AND pg_temp.v('despues', 'auth_S10', 'tiene:excepcion_lectura') = 'true'$$);
SELECT pg_temp.verifica('C4 subordinado (S13): persona_edicion y terminal_usuario_edicion = true (propios); excepcion_lectura del jefe = false (no hereda hacia ABAJO ni hacia arriba)',
  $$SELECT pg_temp.v('despues', 'auth_S13', 'tiene:persona_edicion') = 'true' AND pg_temp.v('despues', 'auth_S13', 'tiene:terminal_usuario_edicion') = 'true' AND pg_temp.v('despues', 'auth_S13', 'tiene:excepcion_lectura') = 'false'$$);
SELECT pg_temp.verifica('C5 solo Tiempo (S3): marca_lectura = true y persona_edicion = false; admin real: todos los permisos del catálogo = true',
  $$SELECT pg_temp.v('despues', 'auth_S3', 'tiene:marca_lectura') = 'true' AND pg_temp.v('despues', 'auth_S3', 'tiene:persona_edicion') = 'false'
      AND (SELECT count(*) FROM _f WHERE fase = 'despues' AND quien = 'auth_admin' AND clave LIKE 'tiene:%' AND clave <> 'tiene:codigo_inexistente' AND valor = 'true') = (SELECT count(*) FROM personas.permiso)$$);
SELECT pg_temp.verifica('C6 NO se filtra el permiso ajeno: la función tiene un solo parámetro (el código) y con la identidad de S5 nunca devuelve el permiso de S3 (marca_lectura de S3 no aparece en S5)',
  $$SELECT pg_temp.v('despues', 'auth_S5', 'tiene:marca_lectura') = 'false' AND (SELECT pronargs FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure) = 1$$);

-- ============================================================================
-- D) Rendimiento (EXPLAIN ANALYZE como authenticated con el usuario base, mediana de 5 consultas, dentro del ensayo)
-- ============================================================================
CREATE TEMP TABLE _med AS
  SELECT consulta, round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) FILTER (WHERE fase = 'antes'))::numeric, 2) AS antes_ms,
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) FILTER (WHERE fase = 'despues'))::numeric, 2) AS despues_ms
  FROM _p GROUP BY consulta;
SELECT pg_temp.verifica('D1 ninguna consulta empeora (ms después <= ms antes x 1.5 + 2) y la de Tiempo con nombres mejora al menos 2x',
  $$SELECT bool_and(despues_ms <= antes_ms * 1.5 + 2) AND (SELECT despues_ms * 2 <= antes_ms FROM _med WHERE consulta = 'tiempo ausencias con nombres') FROM _med$$);

-- ============================================================================
-- E) Reversa (ALTER FUNCTION … SECURITY INVOKER: conserva search_path y ACL; la guarda de persona activa queda y es inocua como INVOKER) y reaplicación
-- ============================================================================
ALTER FUNCTION personas.fn_caller_tiene_permiso(text) SECURITY INVOKER;
SELECT pg_temp.verifica('E0 tras la reversa (ALTER … SECURITY INVOKER): vuelve a ser INVOKER, conserva search_path exacto y la ACL idéntica a la de antes de 112_ (md5 de acl+config)', $$SELECT NOT prosecdef AND proconfig = ARRAY['search_path=personas, pg_temp'] AND md5(COALESCE(proacl::text, '') || COALESCE(proconfig::text, '')) = '3537c7d00d77bf5e40f8a127dafedaae' FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);
SELECT pg_temp.snap('reversa');
SELECT pg_temp.verifica('E1 tras la reversa (INVOKER con la guarda inocua): los valores de TODOS los códigos y personas, incluidas la suspendida y la de baja, son idénticos a los de antes',
  $$SELECT count(*) = (SELECT count(*) FROM _f WHERE fase = 'antes') AND bool_and(a.valor = d.valor) FROM _f a JOIN _f d ON d.clave = a.clave AND d.quien = a.quien AND d.fase = 'reversa' WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('E2 la ACL tras la reversa es la misma (CREATE OR REPLACE conserva grants): authenticated y service_role, sin PUBLIC ni anon',
  $$SELECT has_function_privilege('authenticated', oid, 'EXECUTE') AND has_function_privilege('service_role', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE') FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);
\ir ../ddl/112_personas_fn_caller_tiene_permiso_definer.sql
SELECT pg_temp.snap('final');
SELECT pg_temp.verifica('E3 reaplicable: DEFINER otra vez y los valores vuelven a coincidir con los de antes',
  $$SELECT (SELECT prosecdef FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure)
      AND (SELECT count(*) = (SELECT count(*) FROM _f WHERE fase = 'antes') AND bool_and(a.valor = d.valor) FROM _f a JOIN _f d ON d.clave = a.clave AND d.quien = a.quien AND d.fase = 'final' WHERE a.fase = 'antes')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT consulta, antes_ms, despues_ms FROM _med ORDER BY consulta;
SELECT (SELECT count(*) FROM _f WHERE fase = 'antes' AND clave LIKE 'tiene:%') AS comparaciones_permiso, (SELECT count(*) FROM _c WHERE fase = 'antes') AS comparaciones_tabla, (SELECT count(DISTINCT quien) FROM _f) AS sesiones;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
