-- Ensayo de 110_personas_identidad_separada_del_nombre.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_110.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 110_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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

-- ---------- ANTES de 110_: línea base de la batería con las funciones actuales ----------
SELECT pg_temp.bateria('antes');
SELECT pg_temp.mide('antes', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.verifica('A0 (documenta el hueco) ANTES de 110_: una persona SIN puesto ve TODOS los expedientes? NO: ve solo el propio por 108_; pero sí lee TODA la identidad de la persona que alcanza',
  $$SELECT expedientes = 1 FROM _vis WHERE fase = 'antes'$$);

\ir ../ddl/110_personas_identidad_separada_del_nombre.sql
SELECT pg_temp.bateria('despues');
SELECT pg_temp.verifica('E0 la batería de crear/actualizar da el MISMO resultado (SQLSTATE y huella de la fila) antes y después de 110_: 21 casos',
  $$SELECT count(*) = 21 AND bool_and(a.resultado = d.resultado)
    FROM _bat a JOIN _bat d ON d.caso = a.caso AND d.fase = 'despues' WHERE a.fase = 'antes'$$);

-- ============================================================================
-- A) Estructura
-- ============================================================================
SELECT pg_temp.verifica('A1 fn_caller_ve_identidad y fn_persona_identidad: SECURITY DEFINER, search_path = personas, pg_temp, dueño postgres, EXECUTE solo authenticated y service_role',
  $$SELECT count(*) = 2 AND bool_and(p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND NOT p.proleakproof
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname IN ('fn_caller_ve_identidad', 'fn_persona_identidad')$$);
SELECT pg_temp.verifica('A2 fn_persona_crear y fn_persona_actualizar_datos siguen SECURITY INVOKER con search_path fijo y EXECUTE solo authenticated (ni PUBLIC, anon ni service_role)',
  $$SELECT count(*) = 2 AND bool_and(NOT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp']
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname IN ('fn_persona_crear', 'fn_persona_actualizar_datos')$$);
SELECT pg_temp.verifica('A3 ninguna de las dos usa RETURNING * ni COALESCE sobre columnas de identidad; el UPDATE dinámico solo contiene literales fijos (sin format ni %I)',
  $$SELECT bool_and(CASE p.proname
        WHEN 'fn_persona_crear' THEN p.prosrc !~* 'RETURNING \*'
        ELSE p.prosrc !~* 'COALESCE\(p_(curp|rfc|nss|fecha_nacimiento)' AND p.prosrc !~* 'format\(' AND p.prosrc !~ '%I' END)
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname IN ('fn_persona_crear', 'fn_persona_actualizar_datos')$$);
SELECT pg_temp.verifica('A4 la policy de expediente exige fn_caller_ve_identidad y el total de policies sigue en 76',
  $$SELECT (SELECT qual LIKE '%fn_caller_ve_identidad%' AND qual NOT LIKE '%fn_caller_ve_padron%' FROM pg_policies WHERE schemaname = 'personas' AND tablename = 'expediente' AND cmd = 'SELECT')
      AND (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 76$$);

-- ============================================================================
-- B) Expedientes y personas que VE cada rol
-- ============================================================================
SELECT pg_temp.mide('despues', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.mide('despues', 'S2 puesto sin permisos', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S2'));
SELECT pg_temp.mide('despues', 'S3 solo Tiempo', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.mide('despues', 'S4 solo Terminales', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S4'));
SELECT pg_temp.mide('despues', 'S5 ver_modulo_1', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.mide('despues', 'S6 alta_personas_usuarios', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S6'));
SELECT pg_temp.mide('despues', 'S7 persona_edicion', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S7'));
SELECT pg_temp.mide('despues', 'S8 cambio_estado_persona', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S8'));
SELECT pg_temp.mide('despues', 'S9 suspendida', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S9'));
SELECT pg_temp.mide('despues', 'S10 jefe por herencia', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S10'));
SELECT pg_temp.mide('despues', 'service_role', 'service_role', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.verifica('B1 sin puesto, puesto sin permisos, solo Tiempo y solo Terminales: expedientes = 1 (solo el propio)',
  $$SELECT count(*) = 4 AND bool_and(expedientes = 1) FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S1 %' OR quien LIKE 'S2 %' OR quien LIKE 'S3 %' OR quien LIKE 'S4 %')$$);
SELECT pg_temp.verifica('B2 conjunto estricto (ver_modulo_1, alta, persona_edicion, cambio_estado, y el jefe que hereda): ven TODOS los expedientes',
  $$SELECT count(*) = 5 AND bool_and(expedientes = (SELECT v::bigint FROM _ens WHERE k = 'tot_e'))
    FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S5 %' OR quien LIKE 'S6 %' OR quien LIKE 'S7 %' OR quien LIKE 'S8 %' OR quien LIKE 'S10 %')$$);
SELECT pg_temp.verifica('B3 suspendida: 0 expedientes y 0 personas; service_role ve todo; solo Tiempo/Terminales siguen viendo TODAS las personas (nombres, 108_)',
  $$SELECT (SELECT expedientes = 0 AND personas = 0 FROM _vis WHERE fase = 'despues' AND quien LIKE 'S9 %')
      AND (SELECT expedientes = (SELECT v::bigint FROM _ens WHERE k = 'tot_e') AND personas = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') FROM _vis WHERE fase = 'despues' AND quien = 'service_role')
      AND (SELECT count(*) = 2 AND bool_and(personas = (SELECT v::bigint FROM _ens WHERE k = 'tot_p')) FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S3 %' OR quien LIKE 'S4 %'))$$);

-- ============================================================================
-- C) fn_persona_identidad
-- ============================================================================
CREATE FUNCTION pg_temp.identidad_como(p_rol text, p_sub text, p_persona uuid) RETURNS text AS $$
DECLARE v_out text; v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_sub IS NULL THEN json_build_object('role', p_rol)::text ELSE json_build_object('sub', p_sub, 'role', p_rol)::text END, true);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  BEGIN
    SELECT count(*), max(curp) INTO v_n, v_out FROM personas.fn_persona_identidad(p_persona);
    v_out := 'filas=' || v_n || ' curp=' || COALESCE(v_out, '-');
  EXCEPTION WHEN OTHERS THEN v_out := SQLSTATE;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_out;
END;
$$ LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION pg_temp.identidad_como(text, text, uuid) TO PUBLIC;
CREATE TEMP TABLE _id (quien text, que text, resultado text);
INSERT INTO _id SELECT q, 'otra persona', pg_temp.identidad_como('authenticated', (SELECT v FROM _ens WHERE k = 'auth_' || q), (SELECT v::uuid FROM _ens WHERE k = 'OBJ'))
  FROM unnest(ARRAY['S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'S9', 'S10']) AS q;
INSERT INTO _id SELECT q, 'propia', pg_temp.identidad_como('authenticated', (SELECT v FROM _ens WHERE k = 'auth_' || q), (SELECT v::uuid FROM _ens WHERE k = q))
  FROM unnest(ARRAY['S1', 'S2', 'S3', 'S4', 'S9']) AS q;
INSERT INTO _id VALUES ('anon', 'otra persona', pg_temp.identidad_como('anon', NULL, (SELECT v::uuid FROM _ens WHERE k = 'OBJ')));
INSERT INTO _id VALUES ('service_role', 'otra persona (sin auth.uid)', pg_temp.identidad_como('service_role', NULL, (SELECT v::uuid FROM _ens WHERE k = 'OBJ')));
INSERT INTO _id VALUES ('S5', 'inexistente', pg_temp.identidad_como('authenticated', (SELECT v FROM _ens WHERE k = 'auth_S5'), gen_random_uuid()));
SELECT pg_temp.verifica('C1 sin puesto, puesto sin permisos, solo Tiempo, solo Terminales y suspendida: 42501 al pedir la identidad de OTRA persona',
  $$SELECT count(*) = 5 AND bool_and(resultado = '42501') FROM _id WHERE que = 'otra persona' AND quien IN ('S1', 'S2', 'S3', 'S4', 'S9')$$);
SELECT pg_temp.verifica('C2 ver_modulo_1, alta, persona_edicion, cambio_estado y el jefe por herencia: reciben 1 fila con la CURP correcta',
  $$SELECT count(*) = 5 AND bool_and(resultado = 'filas=1 curp=XEXX010101HNEXXV20') FROM _id WHERE que = 'otra persona' AND quien IN ('S5', 'S6', 'S7', 'S8', 'S10')$$);
SELECT pg_temp.verifica('C3 la persona lee SU PROPIA identidad aunque no tenga ningún permiso; la suspendida no (42501)',
  $$SELECT (SELECT count(*) = 4 AND bool_and(resultado LIKE 'filas=1 curp=XEXX010101HNEXXV%') FROM _id WHERE que = 'propia' AND quien IN ('S1', 'S2', 'S3', 'S4'))
      AND (SELECT resultado = '42501' FROM _id WHERE que = 'propia' AND quien = 'S9')$$);
SELECT pg_temp.verifica('C4 anon 42501; service_role SIN auth.uid 42501 (el backend la llama con el cliente del caller); persona inexistente => 0 filas',
  $$SELECT (SELECT resultado = '42501' FROM _id WHERE quien = 'anon') AND (SELECT resultado = '42501' FROM _id WHERE quien = 'service_role')
      AND (SELECT resultado = 'filas=0 curp=-' FROM _id WHERE que = 'inexistente')$$);
DO $$
DECLARE v_n int; v_tc text; v_dr text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_S5'), 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*), max(tipo_contrato), max(documento_ref) INTO v_n, v_tc, v_dr FROM personas.fn_persona_identidad((SELECT v::uuid FROM _ens WHERE k = 'OBJ'));
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES ('C5 la identidad incluye el expediente: tipo_contrato y documento_ref de la persona objetivo, para quien pasa el gate',
    v_n = 1 AND v_tc = 'indefinido' AND v_dr = 'RTB-RH-EIT-2026-920', format('filas=%s', v_n));
END $$;

-- ============================================================================
-- D) Reversa documentada: restaura el estado anterior y la batería vuelve a dar los mismos resultados
-- ============================================================================
DROP POLICY expediente_select_caller_activo ON personas.expediente;
CREATE POLICY expediente_select_caller_activo ON personas.expediente FOR SELECT USING (personas.fn_caller_activo() AND (persona_id = (SELECT personas.fn_caller_persona_id()) OR (SELECT personas.fn_caller_ve_padron())));
CREATE OR REPLACE FUNCTION personas.fn_persona_crear(
  p_primer_nombre varchar(100), p_apellido_paterno varchar(100), p_curp varchar(18), p_rfc varchar(13), p_nss varchar(11), p_fecha_nacimiento date, p_fecha_ingreso date,
  p_tipo_contrato varchar(30), p_documento_ref varchar(50), p_segundo_nombre varchar(100) DEFAULT NULL, p_apellido_materno varchar(100) DEFAULT NULL
) RETURNS personas.persona LANGUAGE plpgsql SECURITY INVOKER SET search_path = personas, pg_temp AS $f$
DECLARE v_persona personas.persona;
BEGIN
  INSERT INTO personas.persona (primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, curp, rfc, nss, fecha_nacimiento, fecha_ingreso)
  VALUES (p_primer_nombre, p_segundo_nombre, p_apellido_paterno, p_apellido_materno, upper(btrim(p_curp)), upper(btrim(p_rfc)), p_nss, p_fecha_nacimiento, p_fecha_ingreso)
  RETURNING * INTO v_persona;
  INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref) VALUES (v_persona.id, p_tipo_contrato, p_documento_ref);
  RETURN v_persona;
END;
$f$;
CREATE OR REPLACE FUNCTION personas.fn_persona_actualizar_datos(
  p_persona_id uuid, p_curp varchar(18) DEFAULT NULL, p_rfc varchar(13) DEFAULT NULL, p_nss varchar(11) DEFAULT NULL, p_primer_nombre varchar(100) DEFAULT NULL,
  p_segundo_nombre varchar(100) DEFAULT NULL, p_apellido_paterno varchar(100) DEFAULT NULL, p_apellido_materno varchar(100) DEFAULT NULL, p_fecha_nacimiento date DEFAULT NULL,
  p_fecha_ingreso date DEFAULT NULL, p_tipo_contrato varchar(30) DEFAULT NULL, p_documento_ref varchar(50) DEFAULT NULL
) RETURNS void AS $f$
BEGIN
  UPDATE personas.persona AS per
  SET curp = COALESCE(p_curp, per.curp), rfc = COALESCE(p_rfc, per.rfc), nss = COALESCE(p_nss, per.nss), primer_nombre = COALESCE(p_primer_nombre, per.primer_nombre),
      segundo_nombre = COALESCE(p_segundo_nombre, per.segundo_nombre), apellido_paterno = COALESCE(p_apellido_paterno, per.apellido_paterno),
      apellido_materno = COALESCE(p_apellido_materno, per.apellido_materno), fecha_nacimiento = COALESCE(p_fecha_nacimiento, per.fecha_nacimiento),
      fecha_ingreso = COALESCE(p_fecha_ingreso, per.fecha_ingreso), actualizado_en = now()
  WHERE per.id = p_persona_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'personas.persona % no existe', p_persona_id USING ERRCODE = 'SCJ10'; END IF;
  IF p_tipo_contrato IS NOT NULL OR p_documento_ref IS NOT NULL THEN
    INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref) VALUES (p_persona_id, p_tipo_contrato, p_documento_ref)
    ON CONFLICT (persona_id) DO UPDATE SET tipo_contrato = COALESCE(EXCLUDED.tipo_contrato, personas.expediente.tipo_contrato), documento_ref = COALESCE(EXCLUDED.documento_ref, personas.expediente.documento_ref);
  END IF;
END;
$f$ LANGUAGE plpgsql;
ALTER FUNCTION personas.fn_persona_actualizar_datos(uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar) RESET search_path;
DROP FUNCTION personas.fn_persona_identidad(uuid);
DROP FUNCTION personas.fn_caller_ve_identidad();
SELECT pg_temp.bateria('reversa');
SELECT pg_temp.verifica('D1 la batería de crear/actualizar da el MISMO resultado (SQLSTATE y huella de la fila) antes de 110_ y tras la reversa: 21 casos',
  $$SELECT count(*) = 21 AND bool_and(a.resultado = d.resultado)
    FROM _bat a JOIN _bat d ON d.caso = a.caso AND d.fase = 'reversa' WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('D2 tras la reversa: las 2 funciones nuevas no existen',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname IN ('fn_persona_identidad', 'fn_caller_ve_identidad'))$$);
\ir ../ddl/110_personas_identidad_separada_del_nombre.sql
SELECT pg_temp.verifica('D3 110_ reaplicable tras la reversa', $$SELECT count(*) = 2 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname IN ('fn_persona_identidad', 'fn_caller_ve_identidad')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT quien, que, resultado FROM _id ORDER BY que, quien;
SELECT caso, a.resultado AS antes, d.resultado AS despues FROM _bat a JOIN _bat d USING (caso) WHERE a.fase = 'antes' AND d.fase = 'despues' ORDER BY caso;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
