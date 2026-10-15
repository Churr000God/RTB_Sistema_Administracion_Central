-- Ensayo de 111_personas_persona_select_solo_columnas_de_nombre.sql (con 110_). NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_111.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 110_ y 111_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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

SELECT pg_temp.bateria('antes');
-- 110_ ya puede estar aplicada en la base real (lo está desde el despliegue): solo se aplica dentro del ensayo si falta
SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_identidad') AS falta110 \gset
\if :falta110
\ir ../ddl/110_personas_identidad_separada_del_nombre.sql
\endif
SELECT pg_temp.verifica('V0 antes de 111_ authenticated SÍ lee curp (documenta el hueco)', $$SELECT has_column_privilege('authenticated', 'personas.persona', 'curp', 'SELECT')$$);
\ir ../ddl/111_personas_persona_select_solo_columnas_de_nombre.sql
SELECT pg_temp.bateria('post111');
SELECT pg_temp.verifica('E0 la batería de crear/actualizar da el MISMO resultado (SQLSTATE y huella de la fila) antes de 110_ y tras 110_+111_: 22 casos',
  $$SELECT count(*) = 22 AND bool_and(a.resultado = d.resultado)
    FROM _bat a JOIN _bat d ON d.caso = a.caso AND d.fase = 'post111' WHERE a.fase = 'antes'$$);

-- ============================================================================
-- A) Privilegios resultantes
-- ============================================================================
SELECT pg_temp.verifica('A1 authenticated: SIN SELECT (tabla ni columna) en curp, rfc, nss, fecha_nacimiento; CON SELECT en las 9 columnas de nombre/listado; INSERT/UPDATE/DELETE de tabla intactos',
  $$SELECT NOT has_table_privilege('authenticated', 'personas.persona', 'SELECT')
      AND NOT bool_or(has_column_privilege('authenticated', 'personas.persona', c, 'SELECT')) FILTER (WHERE c IN ('curp', 'rfc', 'nss', 'fecha_nacimiento'))
      AND bool_and(has_column_privilege('authenticated', 'personas.persona', c, 'SELECT')) FILTER (WHERE c NOT IN ('curp', 'rfc', 'nss', 'fecha_nacimiento'))
      AND has_table_privilege('authenticated', 'personas.persona', 'INSERT') AND has_table_privilege('authenticated', 'personas.persona', 'UPDATE') AND has_table_privilege('authenticated', 'personas.persona', 'DELETE')
    FROM (SELECT attname::text AS c FROM pg_attribute WHERE attrelid = 'personas.persona'::regclass AND attnum > 0 AND NOT attisdropped) x$$);
SELECT pg_temp.verifica('A2 service_role conserva SELECT de tabla; anon no tiene ningún privilegio de columna',
  $$SELECT has_table_privilege('service_role', 'personas.persona', 'SELECT') AND NOT has_any_column_privilege('anon', 'personas.persona', 'SELECT')$$);

-- ============================================================================
-- B) Lecturas por rol (formas exactas que usa el backend)
-- ============================================================================
SELECT pg_temp.caso('B1 solo Tiempo: nombres como resolver (id, primer_nombre, apellido_paterno WHERE id IN …)', 'authenticated', $$SELECT id, primer_nombre, apellido_paterno FROM personas.persona WHERE id IN (SELECT id FROM personas.persona)$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.caso('B2 solo Tiempo: búsqueda por nombre (ilike con or)', 'authenticated', $$SELECT id FROM personas.persona WHERE primer_nombre ILIKE '%a%' OR apellido_paterno ILIKE '%a%' OR apellido_materno ILIKE '%a%'$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.caso('B3 solo Terminales: listado de candidatos (id, nombres, apellido_materno, estado WHERE estado = activo ORDER BY)', 'authenticated', $$SELECT id, primer_nombre, apellido_paterno, apellido_materno FROM personas.persona WHERE estado = 'activo' ORDER BY apellido_paterno, primer_nombre, id$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S4'));
SELECT pg_temp.caso('B4 embed asignacion -> persona con columnas de nombre (JOIN)', 'authenticated', $$SELECT a.id, p.primer_nombre, p.apellido_paterno FROM personas.asignacion a JOIN personas.persona p ON p.id = a.persona_id$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('B5 listado nuevo del backend: 8 columnas explícitas', 'authenticated', $$SELECT id, primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, estado, fecha_ingreso, fecha_baja FROM personas.persona$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('B6 select * (lo que hacía el listado) => 42501 incluso para ver_modulo_1', 'authenticated', $$SELECT * FROM personas.persona$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('B7 select curp => 42501 para ver_modulo_1 (la identidad solo sale por la RPC)', 'authenticated', $$SELECT curp FROM personas.persona$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('B8 select nss => 42501 para solo Tiempo', 'authenticated', $$SELECT nss FROM personas.persona$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.caso('B9 filtrar por curp (oráculo) => 42501', 'authenticated', $$SELECT id FROM personas.persona WHERE curp = 'XEXX010101HNEXXV20'$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.caso('B10 filtrar por fecha_nacimiento => 42501', 'authenticated', $$SELECT id FROM personas.persona WHERE fecha_nacimiento = DATE '2000-01-01'$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S4'));
SELECT pg_temp.caso('B11 count(*) y embed JOIN con expediente (columnas de nombre) => ok', 'authenticated', $$SELECT count(*) FROM personas.persona p LEFT JOIN personas.expediente e ON e.persona_id = p.id$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('B12 anon => 42501', 'anon', $$SELECT id FROM personas.persona$$, '42501');
SELECT pg_temp.caso('B13 service_role conserva la lectura de curp', 'service_role', $$SELECT curp FROM personas.persona$$, 'ok');
CREATE FUNCTION pg_temp.identidad_como(p_sub text, p_persona uuid) RETURNS text AS $$
DECLARE v_out text; v_n int;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
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
GRANT EXECUTE ON FUNCTION pg_temp.identidad_como(text, uuid) TO PUBLIC;
SELECT pg_temp.verifica('B14 fn_persona_identidad sigue funcionando tras 111_ (DEFINER lee las columnas): ver_modulo_1 recibe la CURP; solo Tiempo 42501; la propia identidad sin permisos ok',
  $$SELECT pg_temp.identidad_como((SELECT v FROM _ens WHERE k = 'auth_S5'), (SELECT v::uuid FROM _ens WHERE k = 'OBJ')) = 'filas=1 curp=XEXX010101HNEXXV20'
      AND pg_temp.identidad_como((SELECT v FROM _ens WHERE k = 'auth_S3'), (SELECT v::uuid FROM _ens WHERE k = 'OBJ')) = '42501'
      AND pg_temp.identidad_como((SELECT v FROM _ens WHERE k = 'auth_S1'), (SELECT v::uuid FROM _ens WHERE k = 'S1')) = 'filas=1 curp=XEXX010101HNEXXV1'$$);
SELECT pg_temp.caso('C1 trigger de bitácora tras 111_: cambio_estado_persona (S8) suspende a la persona objetivo por la bitácora', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens111', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S8')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S8'));
SELECT pg_temp.verifica('C1b ... y la persona objetivo quedó en suspensión', $$SELECT estado = 'suspension' FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'OBJ')$$);

-- Cambio de estado y baja definitiva REALES con 110_+111_ (trigger INVOKER fn_bitacora_sincroniza_persona: solo UPDATE ... WHERE id; cierra asignaciones)
SELECT pg_temp.caso('C2 reactivación real por la bitácora (cambio_estado_persona) tras 111_', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'reactivacion', now(), 'ens111', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S12')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S12'));
SELECT pg_temp.verifica('C2b ... y la persona quedó activa', $$SELECT estado = 'activo' AND fecha_baja IS NULL FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'OBJ')$$);
SELECT pg_temp.caso('C3 suspensión real y luego BAJA DEFINITIVA real con asignación vigente (el trigger cierra la asignación)', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens111', %L::uuid);
            INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'baja_definitiva', now(), 'ens111', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12'), (SELECT v FROM _ens WHERE k = 'BAJA'), (SELECT v FROM _ens WHERE k = 'auth_S12')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S12'));
SELECT pg_temp.verifica('C3b ... baja_definitiva: estado y fecha_baja puestos, y la asignación vigente quedó cerrada',
  $$SELECT (SELECT estado = 'baja_definitiva' AND fecha_baja IS NOT NULL FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'BAJA'))
      AND NOT EXISTS (SELECT 1 FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'BAJA') AND vigente_hasta IS NULL)$$);

-- ============================================================================
-- D) Sección 76 del verificador (solo violaciones) y reversa
-- ============================================================================
CREATE FUNCTION pg_temp.seccion76() RETURNS bigint AS $$
  SELECT count(*) FROM (
    -- (a) identidad legible por authenticated o por anon, o SELECT de tabla
    SELECT 'authenticated:' || c.column_name AS problema FROM (VALUES ('curp'), ('rfc'), ('nss'), ('fecha_nacimiento')) AS c(column_name)
    WHERE has_column_privilege('authenticated', 'personas.persona', c.column_name, 'SELECT')
    UNION ALL SELECT 'tabla' WHERE has_table_privilege('authenticated', 'personas.persona', 'SELECT')
    UNION ALL SELECT 'anon:' || c.column_name FROM (VALUES ('curp'), ('rfc'), ('nss'), ('fecha_nacimiento')) AS c(column_name) WHERE has_column_privilege('anon', 'personas.persona', c.column_name, 'SELECT')
    UNION ALL
    -- (b) columna NUEVA sin GRANT a authenticated que no es de identidad: el listado la perdería en silencio; hay que decidir (conceder o clasificarla como identidad en esta lista)
    SELECT 'sin_grant:' || a.attname FROM pg_attribute a
    WHERE a.attrelid = 'personas.persona'::regclass AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname NOT IN ('curp', 'rfc', 'nss', 'fecha_nacimiento')
      AND NOT has_column_privilege('authenticated', 'personas.persona', a.attname, 'SELECT')
  ) v;
$$ LANGUAGE sql;
SELECT pg_temp.verifica('D0 sección 76 (violaciones) = 0 con 111_ aplicada', $$SELECT pg_temp.seccion76() = 0$$);
GRANT SELECT ON personas.persona TO authenticated;
SELECT pg_temp.verifica('D1 reversa (GRANT SELECT de tabla): authenticated vuelve a leer curp y la sección 76 devuelve 5 violaciones (tabla + 4 columnas)',
  $$SELECT has_column_privilege('authenticated', 'personas.persona', 'curp', 'SELECT') AND pg_temp.seccion76() = 5$$);
REVOKE SELECT ON personas.persona FROM authenticated;
GRANT SELECT (id, actualizado_en, primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, fecha_ingreso, fecha_baja, estado) ON personas.persona TO authenticated;
SELECT pg_temp.verifica('D2 reaplicable: de nuevo cerrado', $$SELECT pg_temp.seccion76() = 0$$);
-- (b) una columna nueva de persona SIN grant se detecta (no pasa en silencio)
ALTER TABLE personas.persona ADD COLUMN ens_columna_nueva text;
SELECT pg_temp.verifica('D3 columna nueva sin GRANT => la sección 76 la reporta (1 violación)', $$SELECT pg_temp.seccion76() = 1$$);
ALTER TABLE personas.persona DROP COLUMN ens_columna_nueva;

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
