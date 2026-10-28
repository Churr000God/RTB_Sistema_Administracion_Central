-- Ensayo de 128_personas_baja_fecha_de_mexico.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_128.sql     (SIN -1; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Personas, usuario, puestos, asignaciones y movimientos de bitácora SINTÉTICOS creados en la transacción (la bitácora es
-- inmutable, pero el ROLLBACK la descarta). El administrador real solo es caller (claims). Aplica SOLO 128_ (127_ ya está aplicada).
--
-- DETERMINISTA SIN MOVER now(): la baja admite fecha_efectiva retroactiva (fn_bitacora_persona_fija_hora: hasta 90 días atrás), así que los casos usan
-- instantes FIJOS de la franja 18:00–24:00 de CDMX de AYER (p. ej. ayer 20:30 CDMX = hoy 02:30 UTC). Con TimeZone = UTC, el código viejo da la fecha de
-- HOY (defecto) y el nuevo la de AYER (fecha en México del instante). Fase A = antes de 128_, D = después, Z = otras zonas de sesión, R = residual conocido.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
SET LOCAL TimeZone = 'UTC';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (prosecdef boolean, proconfig text, provolatile "char", proacl text, dueno text, lang text);
GRANT ALL ON _ens, _res, _foto TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

CREATE FUNCTION pg_temp.k(p text) RETURNS text AS $$ SELECT v FROM _ens WHERE k = p $$ LANGUAGE sql STABLE;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- p_quien: NULL = dueño; 'adm' = authenticated con los claims del admin real; 'rh' = authenticated con los claims del RH sintético; 'svc' = service_role.
-- Ejecuta p_sql, evalúa p_check como dueño y revierte el caso (subtransacción).
CREATE FUNCTION pg_temp.caso(p_caso text, p_quien text, p_sql text, p_state text, p_check text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := ''; v_ok boolean := NULL;
BEGIN
  IF p_quien IN ('adm', 'rh') THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', pg_temp.k('auth_' || p_quien), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
  ELSIF p_quien = 'svc' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    SET LOCAL ROLE service_role;
  END IF;
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
    IF p_check IS NOT NULL THEN EXECUTE p_check INTO v_ok; END IF;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle)
  VALUES (p_caso, v_state = p_state AND (p_check IS NULL OR v_state <> 'ok' OR COALESCE(v_ok, false)), format('obtenido=%s check=%s %s', v_state, v_ok, left(v_msg, 110)));
END;
$$ LANGUAGE plpgsql;

-- Baja (o el movimiento p_tipo) de BJ con fecha_efectiva = p_instante (NULL = DEFAULT now()), registrada por p_quien.
CREATE FUNCTION pg_temp.sql_mov(p_tipo text, p_instante text, p_quien text) RETURNS text AS $$
  SELECT CASE WHEN p_instante IS NULL
    THEN format('INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, motivo, registrado_por) VALUES (%L, %L, %L, %s)',
                pg_temp.k('BJ'), p_tipo, 'ensayo 128', CASE WHEN p_quien = 'svc' THEN 'NULL' ELSE quote_literal(pg_temp.k('auth_' || p_quien)) || '::uuid' END)
    ELSE format('INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L, %L, %L::timestamptz, %L, %s)',
                pg_temp.k('BJ'), p_tipo, p_instante, 'ensayo 128', CASE WHEN p_quien = 'svc' THEN 'NULL' ELSE quote_literal(pg_temp.k('auth_' || p_quien)) || '::uuid' END)
  END;
$$ LANGUAGE sql STABLE;

-- Comprobación: fecha_baja y vigente_hasta de la asignación de BJ (NULL = sigue abierta) igual a lo esperado, y estado.
CREATE FUNCTION pg_temp.sql_chk(p_estado text, p_fecha_baja text, p_hasta text) RETURNS text AS $$
  SELECT format($q$SELECT (SELECT estado = %1$L AND fecha_baja IS NOT DISTINCT FROM %2$L::date FROM personas.persona WHERE id = %4$L)
                     AND (SELECT vigente_hasta IS NOT DISTINCT FROM %3$L::date FROM personas.asignacion WHERE id = %5$L)$q$,
                p_estado, p_fecha_baja, p_hasta, pg_temp.k('BJ'), pg_temp.k('ASG_BJ'));
$$ LANGUAGE sql STABLE;

-- Instante fijo: día (hoy_mx + p_dias) a la hora p_hora de CDMX.
CREATE FUNCTION pg_temp.cdmx(p_dias int, p_hora text) RETURNS text AS $$
  SELECT ((personas.fn_hoy_mexico() + p_dias + p_hora::time) AT TIME ZONE 'America/Mexico_City')::text;
$$ LANGUAGE sql STABLE;

-- ---------- datos base ----------
INSERT INTO _ens VALUES ('hoy', personas.fn_hoy_mexico()::text);
INSERT INTO _ens VALUES ('ayer', (personas.fn_hoy_mexico() - 1)::text);
INSERT INTO _ens
SELECT 'auth_adm', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
SELECT pg_temp.verifica('P1 admin con cambio_estado_persona y asignacion_edicion',
  $$SELECT count(*) = 2 FROM personas.puesto_permiso pp JOIN personas.puesto pu ON pu.id = pp.puesto_id AND pu.es_administrador_generico
    WHERE pp.activo AND pp.codigo IN ('cambio_estado_persona', 'asignacion_edicion')$$);

-- Puesto sintético para BJ y para el RH sintético (mismo patrón que ensayo_125).
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS128 puesto', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS128 solo cambio de estado', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'cambio_estado_persona', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS128 solo cambio de estado';

-- BJ: persona a la que se da de baja, con una asignación vigente desde 2026-01-01.
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV8', 'XEXV01010128', '99999712800', 'Sintetica128', 'Ensayo128', DATE '2000-01-01', DATE '2020-01-01');
INSERT INTO _ens SELECT 'BJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV8';
WITH a AS (
  INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
  SELECT pg_temp.k('BJ')::uuid, id, DATE '2026-01-01' FROM personas.puesto WHERE nombre_puesto = 'ENS128 puesto' RETURNING id)
INSERT INTO _ens SELECT 'ASG_BJ', id::text FROM a;

-- RH sintético: persona activa con usuario y SOLO cambio_estado_persona (sin asignacion_edicion), para el caso R1.
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV9', 'XEXV01010129', '99999712900', 'Sintetica128RH', 'Ensayo128', DATE '2000-01-01', DATE '2020-01-01');
INSERT INTO _ens SELECT 'RH', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV9';
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) VALUES (pg_temp.k('auth_rh')::uuid, 'authenticated', 'authenticated', 'ens128rh@invalid.test');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES (pg_temp.k('auth_rh')::uuid, pg_temp.k('RH')::uuid, 'ens128rh');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT pg_temp.k('RH')::uuid, id, DATE '2026-01-01' FROM personas.puesto WHERE nombre_puesto = 'ENS128 solo cambio de estado';

-- Foto de atributos ANTES de 128_.
INSERT INTO _foto
SELECT p.prosecdef, p.proconfig::text, p.provolatile, p.proacl::text, pg_get_userbyid(p.proowner), l.lanname
FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang WHERE p.oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure;

SELECT pg_temp.verifica('P2 instante de prueba: ayer 20:30 CDMX cae HOY en UTC (franja 18–24)',
  format($q$SELECT (%L::timestamptz AT TIME ZONE 'UTC')::date = %L::date$q$, pg_temp.cdmx(-1, '20:30'), pg_temp.k('hoy')));

-- ---------- A: ANTES de 128_ (TimeZone = UTC) ----------
SELECT pg_temp.caso('A1 [defecto] baja ayer 20:30 CDMX => fecha_baja y cierre = HOY (fecha UTC)', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '20:30'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('hoy'), pg_temp.k('hoy')));
SELECT pg_temp.caso('A2 baja ayer 10:00 CDMX => ayer (de día ya era correcto)', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '10:00'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));

-- ---------- aplica 128_ ----------
\ir ../ddl/128_personas_baja_fecha_de_mexico.sql

-- ---------- D: DESPUÉS de 128_ (TimeZone = UTC) ----------
SELECT pg_temp.caso('D1 baja ayer 20:30 CDMX (authenticated, admin) => fecha_baja y cierre = AYER', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '20:30'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT pg_temp.caso('D2 baja ayer 18:00 CDMX => ayer', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '18:00'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT pg_temp.caso('D3 baja ayer 23:59:59 CDMX => ayer', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '23:59:59'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT pg_temp.caso('D4 baja ayer 10:00 CDMX => ayer (las bajas de día no cambian)', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '10:00'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT pg_temp.caso('D5 baja hoy 00:00:00 CDMX => hoy', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(0, '00:00:00'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('hoy'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D6 baja con fecha_efectiva por omisión (now()) => hoy en México', 'adm',
  pg_temp.sql_mov('baja_definitiva', NULL, 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('hoy'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D7 baja anteayer 19:00 CDMX por service_role => anteayer', 'svc',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-2, '19:00'), 'svc'), 'ok', pg_temp.sql_chk('baja_definitiva', (pg_temp.k('hoy')::date - 2)::text, (pg_temp.k('hoy')::date - 2)::text));
SELECT pg_temp.caso('D8 suspensión ayer 20:30 CDMX => suspension, sin fecha_baja, asignación abierta', 'adm',
  pg_temp.sql_mov('suspension', pg_temp.cdmx(-1, '20:30'), 'adm'), 'ok', pg_temp.sql_chk('suspension', NULL, NULL));

-- ---------- Z: otras zonas de sesión ----------
SELECT set_config('TimeZone', 'Pacific/Kiritimati', true);
SELECT pg_temp.caso('Z1 [UTC+14] baja ayer 20:30 CDMX => ayer', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '20:30'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT set_config('TimeZone', 'Pacific/Pago_Pago', true);
SELECT pg_temp.caso('Z2 [UTC-11] baja ayer 20:30 CDMX => ayer', 'adm',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '20:30'), 'adm'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT set_config('TimeZone', 'UTC', true);

-- ---------- R: residual conocido, fuera de alcance (se documenta, no se corrige) ----------
-- Quien tiene cambio_estado_persona SIN asignacion_edicion da de baja a la persona pero el UPDATE de asignacion del trigger (INVOKER) lo filtra la RLS:
-- la asignación queda ABIERTA sin error. Hoy ningún puesto real está en esa combinación.
SELECT pg_temp.caso('R1 [residual] baja por quien NO tiene asignacion_edicion => persona en baja, asignación sigue abierta', 'rh',
  pg_temp.sql_mov('baja_definitiva', pg_temp.cdmx(-1, '20:30'), 'rh'), 'ok', pg_temp.sql_chk('baja_definitiva', pg_temp.k('ayer'), NULL));

-- ---------- F: catálogo después de 128_ ----------
SELECT pg_temp.verifica('F1 atributos idénticos a la foto (SECURITY, search_path, volatilidad, ACL, dueño, lenguaje)',
  $$SELECT EXISTS (SELECT 1 FROM _foto f, pg_proc p JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure
      AND p.prosecdef = f.prosecdef AND p.proconfig::text IS NOT DISTINCT FROM f.proconfig AND p.provolatile = f.provolatile
      AND p.proacl::text IS NOT DISTINCT FROM f.proacl AND pg_get_userbyid(p.proowner) = f.dueno AND l.lanname = f.lang)$$);
SELECT pg_temp.verifica('F2 usa fn_hoy_mexico(NEW.fecha_efectiva) dos veces y ya no ::date',
  $$SELECT regexp_count(prosrc, 'personas\.fn_hoy_mexico\(NEW\.fecha_efectiva\)') = 2 AND prosrc !~ '::\s*date' FROM pg_proc WHERE oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure$$);
SELECT pg_temp.verifica('F3 el COMMENT menciona 128_',
  $$SELECT obj_description('personas.fn_bitacora_sincroniza_persona()'::regprocedure, 'pg_proc') LIKE '%128_:%'$$);
SELECT pg_temp.verifica('F4 el trigger sigue AFTER INSERT por fila, habilitado, apuntando a la función',
  $$SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'personas.bitacora_movimiento_persona'::regclass AND tgname = 'trg_bitacora_sincroniza_persona'
      AND tgfoid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure AND tgtype = 5 AND tgenabled = 'O')$$);
SELECT pg_temp.verifica('F5 sección 89 sigue en 0 (ninguna función con CURRENT_DATE/LOCALTIMESTAMP/now()::date)',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace IN ('tiempo'::regnamespace, 'personas'::regnamespace)
      AND p.prosrc ~* '\mcurrent_date\M|\mlocaltimestamp\M|now\(\)\s*::\s*date|\mcurrent_timestamp\s*::\s*date')$$);

\echo '--- secciones 89 y 90 de verificar_ddl.sql (esperado: 0 filas cada una) ---'
\ir verificar_127_128.sql

-- ---------- resultado ----------
SELECT n, caso, ok, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE ok) || '/' || count(*) AS resultado FROM _res;

ROLLBACK;
