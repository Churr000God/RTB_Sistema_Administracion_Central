-- Ensayo de 92_personas_bitacora_movimiento_endurece_insert.sql (policy de INSERT de la bitácora de personas, hora fijada por la base, ventana de
-- fecha_efectiva y limpieza del detalle de la bitácora de enrolamiento). NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión
-- que lo corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_92.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 92_ (88_ a 91_ ya están aplicadas). Personas, usuarios, terminal y movimientos SINTÉTICOS; el admin real sólo
-- es caller. Las filas de la bitácora de personas son inmutables, pero todo se revierte con el ROLLBACK (no se inserta nada fuera de la transacción).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
DO $b$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM tiempo.terminal_usuario) THEN
    EXECUTE 'ALTER SEQUENCE tiempo.seq_terminal_employee_no RESTART WITH 1';
  END IF;
END $b$;
\ir ../ddl/92_personas_bitacora_movimiento_endurece_insert.sql

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_uid', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'admin_persona', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_uid');

-- p_sub: NULL = el admin real; '-' = claims SIN sub; otro = ese auth uid.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL, p_hint text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL; v_claims json;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  IF p_sub = '-' THEN v_claims := json_build_object('role', p_rol);
  ELSE v_claims := json_build_object('sub', COALESCE(p_sub, (SELECT x.v FROM _ens x WHERE x.k='auth_uid')), 'role', p_rol);
  END IF;
  PERFORM set_config('request.jwt.claims', v_claims::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);   -- los claims son de transacción: no dejarlos puestos para los fixtures del dueño
  INSERT INTO _res (caso, ok, detalle) VALUES (
    p_caso,
    (CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok' ELSE v_estado = p_esperado END)
      AND (p_hint IS NULL OR v_hint IS NOT DISTINCT FROM p_hint),
    'obtenido=' || v_estado || ' hint=' || COALESCE(v_hint, '-') || ' ' || left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), p_sql);
END;
$$ LANGUAGE plpgsql;

-- Llama una función que devuelve jsonb como p_rol y evalúa p_check ($1 = resultado).
CREATE FUNCTION pg_temp.rpc(p_caso text, p_rol text, p_llamada text, p_check text, p_sub text DEFAULT NULL) RETURNS void AS $$
DECLARE v_res jsonb; v_ok boolean := false; v_det text := ''; v_claims json;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  IF p_sub = '-' THEN v_claims := json_build_object('role', p_rol);
  ELSE v_claims := json_build_object('sub', COALESCE(p_sub, (SELECT x.v FROM _ens x WHERE x.k='auth_uid')), 'role', p_rol);
  END IF;
  PERFORM set_config('request.jwt.claims', v_claims::text, true);
  BEGIN
    EXECUTE 'SELECT ' || p_llamada INTO v_res;
  EXCEPTION WHEN OTHERS THEN
    v_det := 'EXC ' || SQLSTATE || ' ' || left(SQLERRM, 100); v_res := NULL;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_det = '' THEN
    EXECUTE 'SELECT COALESCE(' || p_check || ', false)' INTO v_ok USING v_res;
  END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_ok, v_det || ' ' || left(COALESCE(v_res::text, 'null'), 300));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.vig() RETURNS text AS $$
  SELECT id::text FROM tiempo.terminal_consentimiento ORDER BY version DESC LIMIT 1;
$$ LANGUAGE sql;

-- INSERT en la bitácora de personas con todos los campos explícitos (los pasa el llamador).
CREATE FUNCTION pg_temp.mov_persona(p_persona text, p_tipo text, p_autor text, p_fecha text, p_creado text DEFAULT 'now()') RETURNS text AS $$
  SELECT format('INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por, creado_en) VALUES (%L::uuid, %L, %s, %L, %s, %s)',
                (SELECT v FROM _ens WHERE k = p_persona), p_tipo, p_fecha, 'ensayo92', CASE WHEN p_autor IS NULL THEN 'NULL' ELSE quote_literal((SELECT v FROM _ens WHERE k = p_autor)) || '::uuid' END, p_creado);
$$ LANGUAGE sql;

INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXXF' || i, 'XEXX010101F' || i, '9999992' || lpad((40 + i)::text, 4, '0'), 'SinteticaF' || i, 'Ensayo92', DATE '2000-01-01', CURRENT_DATE FROM generate_series(1, 8) i;
INSERT INTO _ens SELECT 'P' || i, p.id::text FROM generate_series(1, 8) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXXF' || i;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k LIKE 'P_' ON CONFLICT DO NOTHING;
-- Usuarios: RH sintético (tiene cambio_estado_persona) sobre P1 y "sin permisos" sobre P2.
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text), ('auth_sin', gen_random_uuid()::text), ('auth_nuevo', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_rh', 'auth_sin', 'auth_nuevo');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='auth_rh'),  (SELECT v::uuid FROM _ens WHERE k='P1'), 'ens92rh'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_sin'), (SELECT v::uuid FROM _ens WHERE k='P2'), 'ens92sin');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P1'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS92 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P2'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS92 sin permisos';
-- Los usuarios sintéticos crearon su 'alta' por el trigger (esa fila ya existe); se cuentan aparte.
INSERT INTO _ens SELECT 'altas_previas', count(*)::text FROM personas.bitacora_movimiento_persona WHERE persona_id IN (SELECT v::uuid FROM _ens WHERE k IN ('P1','P2'));

SELECT pg_temp.verifica('00 fixture: caller admin y 2 altas automáticas de los usuarios sintéticos', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND (SELECT v::int FROM _ens WHERE k='altas_previas') = 2$$);
SELECT pg_temp.verifica('00b esas altas las creó el trigger como dueño: registrado_por = el propio usuario, fecha_efectiva = creado_en (regresión del alta de usuarios)',
  $$SELECT count(*) = 2 AND bool_and(registrado_por IS NOT NULL AND tipo_movimiento = 'alta' AND abs(extract(epoch from (fecha_efectiva - creado_en))) < 2)
    FROM personas.bitacora_movimiento_persona WHERE persona_id IN (SELECT v::uuid FROM _ens WHERE k IN ('P1','P2'))$$);

-- A. Policy: autor atado a auth.uid(), tipo limitado
SELECT pg_temp.caso('10 admin registra una suspensión de P3 como SÍ MISMO (registrado_por = su uid) -> ok', 'authenticated', pg_temp.mov_persona('P3', 'suspension', 'auth_uid', 'now()'), 'ok');
SELECT pg_temp.verifica('10b la persona quedó suspendida (el trigger de sincronización sigue funcionando)', $$SELECT estado = 'suspension' FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k='P3')$$);
SELECT pg_temp.caso('11 RH registra un movimiento de P4 con registrado_por = el ADMIN (suplantación del autor) -> 42501', 'authenticated', pg_temp.mov_persona('P4', 'suspension', 'auth_uid', 'now()'), '42501', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('11b registrado_por NULL -> 42501', 'authenticated', pg_temp.mov_persona('P4', 'suspension', NULL, 'now()'), '42501');
SELECT pg_temp.caso('11c un movimiento tipo alta hecho a mano por la API -> 42501', 'authenticated', pg_temp.mov_persona('P4', 'alta', 'auth_uid', 'now()'), '42501');
SELECT pg_temp.caso('11d usuario sin cambio_estado_persona, aun siendo él mismo el autor -> 42501', 'authenticated', pg_temp.mov_persona('P4', 'suspension', 'auth_sin', 'now()'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('11e anon -> 42501', 'anon', pg_temp.mov_persona('P4', 'suspension', 'auth_uid', 'now()'), '42501', '-');
SELECT pg_temp.caso('11f RH con su propio uid y el tipo reactivacion de P3 -> ok', 'authenticated', pg_temp.mov_persona('P3', 'reactivacion', 'auth_rh', 'now()'), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('11g P4 no recibió nada de los intentos rechazados (sin movimientos distintos de alta)', $$SELECT NOT EXISTS (SELECT 1 FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P4') AND tipo_movimiento <> 'alta')$$);

-- B. Hora fijada por la base
SELECT pg_temp.caso('20 la API manda creado_en de hace 5 años -> se ignora y queda now()', 'authenticated', pg_temp.mov_persona('P5', 'suspension', 'auth_uid', 'now()', 'timestamptz ''2021-01-01 00:00+00'''), 'ok');
SELECT pg_temp.verifica('20b creado_en = now() (el instante de la transacción)', $$SELECT creado_en = now() FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P5') AND tipo_movimiento = 'suspension'$$);
SELECT pg_temp.caso('21 fecha_efectiva a +10 días -> 22023 fecha_efectiva_invalida', 'authenticated', pg_temp.mov_persona('P6', 'suspension', 'auth_uid', 'now() + interval ''10 days'''), '22023', NULL, 'fecha_efectiva_invalida');
SELECT pg_temp.caso('21a fecha_efectiva a +1 hora -> 22023 (la tolerancia hacia adelante es de 5 minutos)', 'authenticated', pg_temp.mov_persona('P6', 'suspension', 'auth_uid', 'now() + interval ''1 hour'''), '22023', NULL, 'fecha_efectiva_invalida');
SELECT pg_temp.caso('21b fecha_efectiva a +2 minutos -> ok (tolerancia de reloj)', 'authenticated', pg_temp.mov_persona('P6', 'suspension', 'auth_uid', 'now() + interval ''2 minutes'''), 'ok');
SELECT pg_temp.caso('21b2 fecha_efectiva a +10 minutos -> 22023', 'authenticated', pg_temp.mov_persona('P4', 'suspension', 'auth_uid', 'now() + interval ''10 minutes'''), '22023', NULL, 'fecha_efectiva_invalida');
SELECT pg_temp.caso('21c fecha_efectiva a -100 días -> 22023 fecha_efectiva_invalida', 'authenticated', pg_temp.mov_persona('P7', 'suspension', 'auth_uid', 'now() - interval ''100 days'''), '22023', NULL, 'fecha_efectiva_invalida');
SELECT pg_temp.caso('21d fecha_efectiva a -30 días (registro con retraso) -> ok', 'authenticated', pg_temp.mov_persona('P7', 'suspension', 'auth_uid', 'now() - interval ''30 days'''), 'ok');
SELECT pg_temp.verifica('21e ... y conserva su fecha_efectiva retroactiva', $$SELECT fecha_efectiva < now() - interval '29 days' FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P7') AND tipo_movimiento = 'suspension'$$);

-- B2. Diferencial documentado: el trigger de hora corre ANTES de la RLS; un usuario SIN permiso que manda una fecha fuera de ventana recibe 22023 (no 42501).
-- Sólo revela la ventana de fechas, que es pública; ningún dato de personas ni de permisos.
SELECT pg_temp.caso('22 usuario SIN permiso con fecha_efectiva fuera de ventana (+10 días) -> 22023 (el trigger corre antes que la RLS; diferencial documentado)', 'authenticated',
  pg_temp.mov_persona('P4', 'suspension', 'auth_sin', 'now() + interval ''10 days'''), '22023', (SELECT v FROM _ens WHERE k='auth_sin'), 'fecha_efectiva_invalida');
SELECT pg_temp.caso('22b ... y con una fecha válida sigue siendo 42501', 'authenticated', pg_temp.mov_persona('P4', 'suspension', 'auth_sin', 'now()'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));

-- B3. Una baja_definitiva con fecha_efectiva retroactiva ANTERIOR al vigente_desde de una asignación vigente rompe el CHECK de la asignación (vigente_hasta >= vigente_desde):
-- el INSERT completo se revierte y no persiste nada (ni movimiento, ni cambio de estado, ni cierre de asignación).
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P8'), id, CURRENT_DATE - 10 FROM personas.puesto WHERE nombre_puesto = 'Auxiliar Administrativo';
SELECT pg_temp.caso('23 baja_definitiva de P8 con fecha_efectiva 30 días atrás, anterior al vigente_desde de su asignación (hace 10 días) -> 23514 (ck_asignacion_vigencia)', 'authenticated',
  pg_temp.mov_persona('P8', 'baja_definitiva', 'auth_uid', 'now() - interval ''30 days'''), '23514');
SELECT pg_temp.verifica('23b ... y no persistió nada: P8 sigue activa, sin movimiento baja_definitiva y con su asignación vigente abierta',
  $$SELECT (SELECT estado FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k='P8')) = 'activo'
      AND NOT EXISTS (SELECT 1 FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P8') AND tipo_movimiento = 'baja_definitiva')
      AND EXISTS (SELECT 1 FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P8') AND vigente_hasta IS NULL)$$);
SELECT pg_temp.caso('23c la misma baja con fecha_efectiva de hoy sí funciona', 'authenticated', pg_temp.mov_persona('P8', 'baja_definitiva', 'auth_uid', 'now()'), 'ok');
SELECT pg_temp.verifica('23d ... y cierra la asignación con vigente_hasta = hoy', $$SELECT vigente_hasta = CURRENT_DATE FROM personas.asignacion WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P8')$$);

-- C. Dueño y service_role no cambian (alta automática, scripts, otros ensayos)
SELECT pg_temp.caso('30 el DUEÑO conserva creado_en y fecha_efectiva arbitrarios', current_user::text, pg_temp.mov_persona('P4', 'suspension', 'auth_uid', 'now() + interval ''5 days''', 'timestamptz ''2021-01-01 00:00+00'''), 'ok');
SELECT pg_temp.verifica('30b ... creado_en quedó en 2021', $$SELECT creado_en = timestamptz '2021-01-01 00:00+00' FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P4') AND tipo_movimiento = 'suspension'$$);
SELECT pg_temp.caso('30c service_role (como el backend y el bootstrap) puede insertar un movimiento con creado_en explícito', 'service_role', pg_temp.mov_persona('P6', 'reactivacion', 'auth_uid', 'now()', 'timestamptz ''2022-02-02 00:00+00'''), 'ok', '-');
SELECT pg_temp.caso('30d service_role inserta un usuario nuevo => el trigger crea la alta (flujo de creación de personas/usuarios intacto)', 'service_role',
  format('INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES (%L::uuid, %L::uuid, %L)', (SELECT v FROM _ens WHERE k='auth_nuevo'), (SELECT v FROM _ens WHERE k='P7'), 'ens92nuevo'), 'ok', '-');
SELECT pg_temp.verifica('30e ... con registrado_por = el nuevo usuario, tipo alta y hora del servidor',
  $$SELECT count(*) = 1 FROM personas.bitacora_movimiento_persona WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P7') AND tipo_movimiento = 'alta'
      AND registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_nuevo') AND abs(extract(epoch from (creado_en - now()))) < 2$$);

-- D0. Orden de triggers (a0_ < aplica): el error_detalle de la alta que copia el trigger de transiciones ya viene limpio, aun cuando el 'error' lo inserta
-- directamente service_role sin pasar por el RPC del Pi.
SELECT pg_temp.verifica('D0 el trigger de limpieza ordena ANTES que el de transiciones', $$SELECT 'trg_bitacora_terminal_usuario_a0_limpia_detalle' COLLATE "C" < 'trg_bitacora_terminal_usuario_aplica' COLLATE "C"$$);

-- D. B2: el detalle de la bitácora de enrolamiento sin invisibles (también el de origen web)
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-92', 'Terminal de ensayo 92', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-92';
SELECT pg_temp.caso('40 asignar a P3 (88_ aplicada: con consentimiento) -> ok', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id, detalle)
            VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s, 'cliente')$f$, (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P3'), (SELECT v FROM _ens WHERE k='auth_uid'), pg_temp.vig()), 'ok');
SELECT pg_temp.verifica('40b el detalle fijo del asignado no se altera', $$SELECT detalle LIKE 'consentimiento y aviso de privacidad recabados: versión %' FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'asignado' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P3')$$);
SELECT pg_temp.caso('41 baja_solicitada web con un detalle lleno de invisibles y U+2028/2029', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle)
            VALUES (%L::bigint, %L::bigint, %L::uuid, 'baja_solicitada', 'web', %L::uuid, %L)$f$,
         (SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P3')), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P3'), (SELECT v FROM _ens WHERE k='auth_uid'),
         E'la\u202Epersona\u200B se\u2028fue\u2029ya\U000E0041\uFEFF'), 'ok');
SELECT pg_temp.verifica('41b el detalle guardado: invisibles fuera y U+2028/2029 como espacio ("lapersona se fue ya")',
  $$SELECT detalle = 'lapersona se fue ya' FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'baja_solicitada' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P3')$$);

SELECT pg_temp.caso('42 service_role inserta DIRECTO un movimiento error con U+202E y U+200B en el detalle -> ok', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, detalle)
            VALUES (%L::bigint, %L::bigint, %L::uuid, 'error', 'terminal', %L)$f$,
         (SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P3')), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P3'),
         E'fallo\u202Ex\u200By'), 'ok', '-');
SELECT pg_temp.verifica('42b el error_detalle de la alta (copiado por el trigger de transiciones) y el detalle de la bitácora quedan limpios: "falloxy"',
  $$SELECT (SELECT error_detalle FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='P3')) = 'falloxy'
      AND EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'error' AND detalle = 'falloxy' AND persona_id = (SELECT v::uuid FROM _ens WHERE k='P3'))$$);

\ir verificar_92.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
