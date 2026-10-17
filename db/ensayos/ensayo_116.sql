-- Ensayo de 116_personas_actualizar_datos_expediente_parcial.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_116.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 116_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
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
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica116' || p_k, 'Ensayo116', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens116' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens116' || lower(p_k));
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

SELECT pg_temp.mk_persona('RH', 1, 'ENS116 edicion y alta', 'persona_edicion');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'alta_personas_usuarios', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS116 edicion y alta';
SELECT pg_temp.mk_persona('ED', 2, 'ENS116 solo edicion', 'persona_edicion');
SELECT pg_temp.mk_persona('AL', 3, 'ENS116 solo alta', 'alta_personas_usuarios');
SELECT pg_temp.mk_persona('SP', 4, 'ENS116 sin permisos', NULL);
SELECT pg_temp.mk_persona('CE', 5, 'ENS116 solo cambio estado', 'cambio_estado_persona');

-- OBJ: expediente existente (indefinido, folio ...920). OTRA: expediente con folio ...921. SINEXP: persona SIN expediente.
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV20', 'XEXV01010020', '99999700020', 'Objetivo116', 'Ensayo116', DATE '2000-01-01', CURRENT_DATE),
       ('XEXX010101HNEXXV21', 'XEXV01010021', '99999700021', 'Otra116', 'Ensayo116', DATE '2000-01-01', CURRENT_DATE),
       ('XEXX010101HNEXXV22', 'XEXV01010022', '99999700022', 'SinExp116', 'Ensayo116', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'OBJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV20';
INSERT INTO _ens SELECT 'OTRA', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV21';
INSERT INTO _ens SELECT 'SINEXP', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV22';
INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
VALUES ((SELECT v::uuid FROM _ens WHERE k = 'OBJ'), 'indefinido', 'RTB-RH-EIT-2026-920'),
       ((SELECT v::uuid FROM _ens WHERE k = 'OTRA'), 'indefinido', 'RTB-RH-EIT-2026-921');

-- llamada con solo los parámetros nombrados que se pasan
CREATE FUNCTION pg_temp.act(p_k text, p_args text) RETURNS text AS $$
  SELECT format('SELECT personas.fn_persona_actualizar_datos(%L::uuid%s)', (SELECT v FROM _ens WHERE k = p_k), CASE WHEN p_args = '' THEN '' ELSE ', ' || p_args END);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.exp_de(p_k text) RETURNS text AS $$
  SELECT format('SELECT tipo_contrato || %L || documento_ref FROM personas.expediente WHERE persona_id = %L::uuid', '|', (SELECT v FROM _ens WHERE k = p_k));
$$ LANGUAGE sql;

-- ---------- A) ANTES de 116_ (documenta el defecto, función de 110_) ----------
SELECT pg_temp.caso2('A0 (defecto) ANTES de 116_: editar SOLO el folio de un expediente existente => 23502 (not_null_violation)', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-930'''), '23502');
SELECT pg_temp.caso2('A1 (defecto) ANTES de 116_: editar SOLO tipo_contrato => 23502', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_tipo_contrato => ''por_proyecto'''), '23502');
CREATE TEMP TABLE _def AS SELECT md5(pg_get_functiondef(p.oid)) AS h_antes, p.proacl::text AS acl_antes
  FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos';

-- ---------- aplicar 116_ ----------
\ir ../ddl/116_personas_actualizar_datos_expediente_parcial.sql

-- ---------- B) casos mínimos ----------
SELECT pg_temp.exito('B1 solo folio, expediente existente => ok; cambia el folio y conserva tipo_contrato', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-930'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND tipo_contrato = ''indefinido'' AND documento_ref = ''RTB-RH-EIT-2026-930'')', (SELECT v FROM _ens WHERE k = 'OBJ')));
SELECT pg_temp.exito('B2 solo tipo_contrato, expediente existente => ok; conserva el folio', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_tipo_contrato => ''por_proyecto'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND tipo_contrato = ''por_proyecto'' AND documento_ref = ''RTB-RH-EIT-2026-920'')', (SELECT v FROM _ens WHERE k = 'OBJ')));
SELECT pg_temp.exito('B3 los dos a la vez, expediente existente => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_tipo_contrato => ''prestacion_servicios'', p_documento_ref => ''RTB-RH-EIT-2026-931'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND tipo_contrato = ''prestacion_servicios'' AND documento_ref = ''RTB-RH-EIT-2026-931'')', (SELECT v FROM _ens WHERE k = 'OBJ')));
SELECT pg_temp.exito('B4 ninguno de los dos (solo un nombre) => ok; el expediente no se toca y el nombre cambia', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_primer_nombre => ''Renombrada'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND tipo_contrato = ''indefinido'' AND documento_ref = ''RTB-RH-EIT-2026-920'') AND EXISTS (SELECT 1 FROM personas.persona WHERE id = %L::uuid AND primer_nombre = ''Renombrada'')', (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'OBJ')));
SELECT pg_temp.caso2('B5 persona SIN expediente y solo el folio => SCJ22 con HINT expediente_incompleto (no 23502)', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('SINEXP', 'p_documento_ref => ''RTB-RH-EIT-2026-940'''), 'SCJ22', 'expediente_incompleto');
SELECT pg_temp.caso2('B6 persona SIN expediente y solo tipo_contrato => SCJ22', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('SINEXP', 'p_tipo_contrato => ''indefinido'''), 'SCJ22', 'expediente_incompleto');
SELECT pg_temp.exito('B7 persona SIN expediente y los dos => ok; se crea', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('SINEXP', 'p_tipo_contrato => ''indefinido'', p_documento_ref => ''RTB-RH-EIT-2026-940'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND tipo_contrato = ''indefinido'' AND documento_ref = ''RTB-RH-EIT-2026-940'')', (SELECT v FROM _ens WHERE k = 'SINEXP')));
SELECT pg_temp.caso2('B8 SCJ22 sin datos de la persona: el mensaje es fijo', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('SINEXP', 'p_documento_ref => ''RTB-RH-EIT-2026-940'''), 'SCJ22', 'expediente_incompleto');
SELECT pg_temp.verifica('B8b el mensaje de SCJ22 no interpola valores (sin %)', $$SELECT position('Para crear el expediente se requieren tipo de contrato y folio.' IN prosrc) > 0 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_actualizar_datos'$$);
SELECT pg_temp.caso2('B9 folio con formato inválido, expediente existente => 23514', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''FOLIO MAL'''), '23514');
SELECT pg_temp.caso2('B10 folio con formato inválido al crear el expediente => 23514', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('SINEXP', 'p_tipo_contrato => ''indefinido'', p_documento_ref => ''FOLIO MAL'''), '23514');
SELECT pg_temp.caso2('B11 tipo_contrato fuera del catálogo => 23514', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_tipo_contrato => ''inventado'''), '23514');
SELECT pg_temp.caso2('B12 folio duplicado de OTRA persona (solo folio) => 23505', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-921'''), '23505');
SELECT pg_temp.caso2('B13 persona inexistente => SCJ10', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  'SELECT personas.fn_persona_actualizar_datos(gen_random_uuid(), p_documento_ref => ''RTB-RH-EIT-2026-950'')', 'SCJ10');

-- ---------- C) autorización: la RLS sigue mandando ----------
SELECT pg_temp.caso2('C1 sin ningún permiso, solo folio, expediente existente => rechazo (SCJ10: la RLS de UPDATE de persona la filtra, comportamiento previo)', (SELECT v FROM _ens WHERE k = 'auth_SP'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-960'''), 'SCJ10');
SELECT pg_temp.caso2('C2 sin ningún permiso, solo tipo_contrato => rechazo (SCJ10)', (SELECT v FROM _ens WHERE k = 'auth_SP'),
  pg_temp.act('OBJ', 'p_tipo_contrato => ''por_proyecto'''), 'SCJ10');
SELECT pg_temp.caso2('C3 sin permiso y persona SIN expediente, solo folio => rechazo (SCJ10, nunca SCJ22 ni éxito)', (SELECT v FROM _ens WHERE k = 'auth_SP'),
  pg_temp.act('SINEXP', 'p_documento_ref => ''RTB-RH-EIT-2026-961'''), 'SCJ10');
SELECT pg_temp.caso2('C4 solo alta_personas_usuarios (sin persona_edicion), editar folio existente => rechazo', (SELECT v FROM _ens WHERE k = 'auth_AL'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-962'''), 'SCJ10');
SELECT pg_temp.caso2('C5 solo persona_edicion, editar folio de expediente existente (UPDATE: persona_edicion basta) => ok', (SELECT v FROM _ens WHERE k = 'auth_ED'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-963'''), 'ok');
SELECT pg_temp.caso2('C6 solo persona_edicion, CREAR expediente (INSERT exige alta_personas_usuarios) => 42501', (SELECT v FROM _ens WHERE k = 'auth_ED'),
  pg_temp.act('SINEXP', 'p_tipo_contrato => ''indefinido'', p_documento_ref => ''RTB-RH-EIT-2026-964'''), '42501');

SELECT pg_temp.caso2('C7 solo cambio_estado_persona (ve y actualiza persona, pero no tiene persona_edicion), solo folio de expediente existente => 42501 propio (la RLS de UPDATE de expediente filtra la fila)', (SELECT v FROM _ens WHERE k = 'auth_CE'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-965'''), '42501');

-- ---------- D) estructura de la función ----------
SELECT pg_temp.verifica('D1 sigue SECURITY INVOKER con search_path exacto y sin ON CONFLICT',
  $$SELECT NOT prosecdef AND proconfig = ARRAY['search_path=personas, pg_temp'] AND prosrc NOT ILIKE '%ON CONFLICT%' AND prosrc LIKE '%SCJ22%' FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_persona_actualizar_datos'$$);
SELECT pg_temp.verifica('D2 ACL: EXECUTE solo para authenticated (ni PUBLIC, ni anon, ni service_role)',
  $$SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0)
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos'$$);
SELECT pg_temp.verifica('D3 una sola sobrecarga (la firma de 12 parámetros) y el UPDATE de persona conserva los fragmentos fijos de 110_ (sin format ni %I)',
  $$SELECT count(*) = 1 AND bool_and(p.pronargs = 12 AND p.prosrc !~* 'format\(' AND p.prosrc !~ '%I' AND p.prosrc LIKE '%curp = $1%' AND p.prosrc LIKE '%WHERE id = $10%')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos'$$);
SELECT pg_temp.verifica('D4 el trigger trg_persona_protege_columnas_identidad sigue intacto y habilitado',
  $$SELECT count(*) = 1 FROM pg_trigger WHERE tgrelid = 'personas.persona'::regclass AND tgname = 'trg_persona_protege_columnas_identidad' AND tgenabled = 'O'$$);
SELECT pg_temp.verifica('D5 la función cambió respecto a 110_ (huella distinta) y el ACL no cambió',
  $$SELECT (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos') <> (SELECT h_antes FROM _def)
      AND (SELECT p.proacl::text FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos') IS NOT DISTINCT FROM (SELECT acl_antes FROM _def)$$);

-- ---------- E) reversa (cuerpo de 110_) y reaplicación ----------
CREATE OR REPLACE FUNCTION personas.fn_persona_actualizar_datos(
  p_persona_id uuid, p_curp varchar(18) DEFAULT NULL, p_rfc varchar(13) DEFAULT NULL, p_nss varchar(11) DEFAULT NULL, p_primer_nombre varchar(100) DEFAULT NULL,
  p_segundo_nombre varchar(100) DEFAULT NULL, p_apellido_paterno varchar(100) DEFAULT NULL, p_apellido_materno varchar(100) DEFAULT NULL, p_fecha_nacimiento date DEFAULT NULL,
  p_fecha_ingreso date DEFAULT NULL, p_tipo_contrato varchar(30) DEFAULT NULL, p_documento_ref varchar(50) DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_sql  text := 'UPDATE personas.persona SET actualizado_en = now()';
  v_filas bigint;
BEGIN
  IF p_curp IS NOT NULL             THEN v_sql := v_sql || ', curp = $1';             END IF;
  IF p_rfc IS NOT NULL              THEN v_sql := v_sql || ', rfc = $2';              END IF;
  IF p_nss IS NOT NULL              THEN v_sql := v_sql || ', nss = $3';              END IF;
  IF p_primer_nombre IS NOT NULL    THEN v_sql := v_sql || ', primer_nombre = $4';    END IF;
  IF p_segundo_nombre IS NOT NULL   THEN v_sql := v_sql || ', segundo_nombre = $5';   END IF;
  IF p_apellido_paterno IS NOT NULL THEN v_sql := v_sql || ', apellido_paterno = $6'; END IF;
  IF p_apellido_materno IS NOT NULL THEN v_sql := v_sql || ', apellido_materno = $7'; END IF;
  IF p_fecha_nacimiento IS NOT NULL THEN v_sql := v_sql || ', fecha_nacimiento = $8'; END IF;
  IF p_fecha_ingreso IS NOT NULL    THEN v_sql := v_sql || ', fecha_ingreso = $9';    END IF;
  v_sql := v_sql || ' WHERE id = $10';
  EXECUTE v_sql
    USING p_curp, p_rfc, p_nss, p_primer_nombre, p_segundo_nombre, p_apellido_paterno, p_apellido_materno,
          p_fecha_nacimiento, p_fecha_ingreso, p_persona_id;
  GET DIAGNOSTICS v_filas = ROW_COUNT;
  IF v_filas = 0 THEN
    RAISE EXCEPTION 'personas.persona % no existe', p_persona_id USING ERRCODE = 'SCJ10';
  END IF;
  IF p_tipo_contrato IS NOT NULL OR p_documento_ref IS NOT NULL THEN
    INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
    VALUES (p_persona_id, p_tipo_contrato, p_documento_ref)
    ON CONFLICT (persona_id) DO UPDATE
      SET tipo_contrato = COALESCE(EXCLUDED.tipo_contrato, personas.expediente.tipo_contrato),
          documento_ref = COALESCE(EXCLUDED.documento_ref, personas.expediente.documento_ref);
  END IF;
END;
$$;
SELECT pg_temp.verifica('E1 tras la reversa el ACL se conserva (CREATE OR REPLACE no lo toca)',
  $$SELECT (SELECT p.proacl::text FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_persona_actualizar_datos') IS NOT DISTINCT FROM (SELECT acl_antes FROM _def)$$);
SELECT pg_temp.caso2('E2 tras la reversa vuelve el defecto (solo folio => 23502)', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-930'''), '23502');
\ir ../ddl/116_personas_actualizar_datos_expediente_parcial.sql
SELECT pg_temp.exito('E3 reaplicable: solo folio vuelve a funcionar', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  pg_temp.act('OBJ', 'p_documento_ref => ''RTB-RH-EIT-2026-930'''),
  format('SELECT EXISTS (SELECT 1 FROM personas.expediente WHERE persona_id = %L::uuid AND documento_ref = ''RTB-RH-EIT-2026-930'')', (SELECT v FROM _ens WHERE k = 'OBJ')));

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
