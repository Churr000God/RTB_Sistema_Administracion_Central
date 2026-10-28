-- Ensayo de 127_tiempo_personas_hoy_en_hora_de_mexico.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_127.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Persona de tiempo, jornadas, patrón, persona de personas y filas de parámetro SINTÉTICAS creadas en la transacción.
-- El administrador real solo es caller (claims). 127_ YA ESTÁ APLICADA (28-oct-2026): el ensayo aplica la REVERSA (vigente_127_fecha_mexico.sql, fase R), reproduce
-- el defecto con el código previo (fase A), vuelve a aplicar 127_ y prueba el código nuevo (D, Z, F). La foto se toma del estado actual.
--
-- CÓMO SE HACE DETERMINISTA LA FRANJA 18:00–24:00 DE CDMX. now() no se puede mover, pero es fijo durante toda la transacción. Lo que define el defecto es que
-- CURRENT_DATE (fecha de la zona de la SESIÓN) valga «mañana en México». Aquí se fija la zona de la sesión (SET LOCAL TimeZone) a una zona donde, en el instante
-- de la transacción, la fecha es hoy_mx + 1: es exactamente lo que pasa con TimeZone = UTC entre las 18:00 y las 24:00 de CDMX. Con eso:
--   fase A (ANTES de 127_): los casos reproducen el defecto (jornada de mañana tratada como vigente, etc.);
--   fase D (DESPUÉS de 127_, misma zona): los mismos casos siguen la fecha de México.
-- Además, la fase H prueba fn_hoy_mexico(p_ahora) con instantes fijos de la franja (18:00, 20:30, 23:59:59 y 00:00 de CDMX) y la fase Z repite casos con otras
-- zonas de sesión (UTC y Pacific/Pago_Pago) para mostrar que, tras 127_, el resultado ya no depende de la zona de la sesión.
-- Restricción: la zona más adelantada es UTC+14, así que la fase A necesita correr cuando en CDMX son las 04:00 o más tarde (si no, el caso P0 falla y se aborta).
-- La precondición DO de 127_ no filtra las claves terminal_inferir_huella_% (siguen en UTC a propósito): si una de esas vigencias empieza «mañana» (posible
-- entre las 18:00 y las 24:00 de CDMX), el \ir de 127_ aborta sin que haya un problema real. Correr de día (04:00–18:00 de CDMX).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (firma text PRIMARY KEY, prosecdef boolean, proconfig text, provolatile "char", proacl text, dueno text, args text, rettype text, src_md5 text, comentario text);
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

-- Ejecuta p_sql como p_quien (NULL = dueño postgres; 'adm' = authenticated con los claims del admin real; 'svc' = service_role), fuerza los constraint
-- triggers diferidos (cadena de jornadas, tope legal) DENTRO del caso, y si p_check no es NULL lo evalúa como dueño sobre el estado resultante. Siempre revierte
-- el caso (subtransacción). ok = SQLSTATE obtenido = p_state (y HINT = p_hint si se da) y, si hay p_check, que sea verdadero.
CREATE FUNCTION pg_temp.caso(p_caso text, p_quien text, p_sql text, p_state text, p_check text DEFAULT NULL, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := ''; v_ok boolean := NULL;
BEGIN
  IF p_quien = 'adm' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', pg_temp.k('auth_admin'), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
  ELSIF p_quien = 'svc' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    SET LOCAL ROLE service_role;
  END IF;
  BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
    IF p_check IS NOT NULL THEN EXECUTE p_check INTO v_ok; END IF;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  SET CONSTRAINTS ALL DEFERRED;
  INSERT INTO _res (caso, ok, detalle)
  VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint) AND (p_check IS NULL OR v_state <> 'ok' OR COALESCE(v_ok, false)),
          format('obtenido=%s hint=%s check=%s %s', v_state, v_hint, v_ok, left(v_msg, 90)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido IS NOT DISTINCT FROM p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;

-- ---------- datos base ----------
INSERT INTO _ens VALUES ('hoy', personas.fn_hoy_mexico()::text);
INSERT INTO _ens
SELECT 'auth_admin', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;

-- Precondiciones del caller: el admin tiene los tres permisos que usan los casos 'adm'.
SELECT pg_temp.verifica('P1 admin con jornada_asignada_edicion, patron_semanal_edicion y terminal_config_edicion',
  $$SELECT count(*) = 3 FROM personas.puesto_permiso pp JOIN personas.puesto pu ON pu.id = pp.puesto_id AND pu.es_administrador_generico
    WHERE pp.activo AND pp.codigo IN ('jornada_asignada_edicion', 'patron_semanal_edicion', 'terminal_config_edicion')$$);

-- Fixture de jornadas: persona de tiempo sintética P; J1 (normal, desde 2026-01-01) en curso que cierra HOY (México); J2 empieza MAÑANA (México) y es la última.
INSERT INTO _ens VALUES ('P', gen_random_uuid()::text);
INSERT INTO tiempo.persona (id) VALUES (pg_temp.k('P')::uuid);
WITH j AS (
  INSERT INTO tiempo.jornada_asignada (persona_id, tipo_jornada, vigente_desde, vigente_hasta)
  VALUES (pg_temp.k('P')::uuid, 'normal', DATE '2026-01-01', pg_temp.k('hoy')::date) RETURNING id)
INSERT INTO _ens SELECT 'J1', id::text FROM j;
WITH j AS (
  INSERT INTO tiempo.jornada_asignada (persona_id, tipo_jornada, vigente_desde)
  VALUES (pg_temp.k('P')::uuid, 'normal', pg_temp.k('hoy')::date + 1) RETURNING id)
INSERT INTO _ens SELECT 'J2', id::text FROM j;
INSERT INTO tiempo.patron_semanal (jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida)
SELECT j.v::bigint, d, TIME '09:00', TIME '17:00', 60
FROM _ens j CROSS JOIN unnest(ARRAY['lunes', 'martes', 'miercoles', 'jueves', 'viernes']) d WHERE j.k IN ('J1', 'J2');
SET CONSTRAINTS ALL IMMEDIATE;   -- la cadena y el tope legal del fixture son válidos
SET CONSTRAINTS ALL DEFERRED;

-- Persona de personas sintética para la baja (sin usuario ni puesto).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXV7', 'XEXV01010127', '99999712700', 'Sintetica127', 'Ensayo127', DATE '2000-01-01', DATE '2020-01-01');
INSERT INTO _ens SELECT 'BJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV7';

-- Valores vigentes de parámetros que usan los casos.
INSERT INTO _ens SELECT 'tol_valor', valor FROM tiempo.parametro WHERE clave = 'tolerancia_retardo_min' AND vigente_hasta IS NULL;
INSERT INTO _ens SELECT 'anom_valor', tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias')::text;
INSERT INTO _ens SELECT 'anom_nuevo', (CASE WHEN tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias') < 90 THEN tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias') + 1 ELSE 89 END)::text;
SELECT pg_temp.verifica('P2 hay vigencia activa de tolerancia_retardo_min y de terminal_anomalias_ventana_dias',
  $$SELECT pg_temp.k('tol_valor') IS NOT NULL AND EXISTS (SELECT 1 FROM tiempo.parametro WHERE clave = 'terminal_anomalias_ventana_dias' AND vigente_hasta IS NULL)$$);

-- Foto de las 10 funciones en el estado ACTUAL de la base (127_ ya aplicada el 28-oct-2026): atributos, md5 del cuerpo y comentario. La fase R aplica la
-- reversa, comprueba el estado previo y vuelve a aplicar 127_; F3 y R5 comparan contra esta foto.
INSERT INTO _foto
SELECT p.oid::regprocedure::text, p.prosecdef, p.proconfig::text, p.provolatile, p.proacl::text, pg_get_userbyid(p.proowner),
       pg_get_function_arguments(p.oid), pg_get_function_result(p.oid), md5(p.prosrc), obj_description(p.oid, 'pg_proc')
FROM pg_proc p
WHERE p.oid IN ('personas.fn_persona_sincroniza_baja()'::regprocedure, 'tiempo.fn_jornada_asignada_protege_borrado()'::regprocedure,
                'tiempo.fn_jornada_asignada_protege_vigencias()'::regprocedure, 'tiempo.fn_patron_semanal_solo_jornada_futura()'::regprocedure,
                'tiempo.fn_jornada_en_curso_mover_limite(bigint, date)'::regprocedure,
                'tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer)'::regprocedure,
                'tiempo.fn_jornada_futura_eliminar(bigint)'::regprocedure, 'tiempo.fn_parametro_actualizar_valor(character varying, text, uuid)'::regprocedure,
                'tiempo.fn_terminal_config_actualizar(text, text)'::regprocedure, 'tiempo.fn_terminal_config_valor(text)'::regprocedure);
SELECT pg_temp.igual('P3 foto de las 10 funciones', (SELECT count(*) FROM _foto)::text, '10');

-- ---------- H: fn_hoy_mexico con instantes fijos de la franja ----------
SELECT pg_temp.igual('H1 18:00 CDMX es el mismo día en México', personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-28 18:00:00-06')::text, '2026-10-28');
SELECT pg_temp.igual('H2 20:30 CDMX es el mismo día en México', personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-28 20:30:00-06')::text, '2026-10-28');
SELECT pg_temp.igual('H3 20:30 CDMX ya es el día siguiente en UTC', (TIMESTAMPTZ '2026-10-28 20:30:00-06' AT TIME ZONE 'UTC')::date::text, '2026-10-29');
SELECT pg_temp.igual('H4 23:59:59 CDMX sigue siendo el mismo día', personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-28 23:59:59-06')::text, '2026-10-28');
SELECT pg_temp.igual('H5 00:00 CDMX ya es el día siguiente', personas.fn_hoy_mexico(TIMESTAMPTZ '2026-10-29 00:00:00-06')::text, '2026-10-29');

-- ---------- zona de sesión con CURRENT_DATE = mañana en México (la franja 18–24 de CDMX con TimeZone = UTC) ----------
DO $$
DECLARE z text;
BEGIN
  SELECT x INTO z FROM unnest(ARRAY['UTC', 'Asia/Tokyo', 'Pacific/Kiritimati']) x
  WHERE (now() AT TIME ZONE x)::date = personas.fn_hoy_mexico() + 1 LIMIT 1;
  IF z IS NULL THEN
    RAISE EXCEPTION 'ensayo_127: ninguna zona da CURRENT_DATE = mañana en México en este instante; correr cuando en CDMX sean las 04:00 o más tarde';
  END IF;
  PERFORM set_config('TimeZone', z, true);
  INSERT INTO _ens VALUES ('zona', z);
END $$;
SELECT pg_temp.verifica('P0 CURRENT_DATE de la sesión = mañana en México (condición del defecto)', $$SELECT CURRENT_DATE = pg_temp.k('hoy')::date + 1$$);

-- ---------- R: reversa ejecutable (vigente_127_fecha_mexico.sql) ----------
\ir vigente_127_fecha_mexico.sql
SELECT pg_temp.verifica('R1 tras la reversa: las 10 usan CURRENT_DATE y ninguna fn_hoy_mexico',
  $$SELECT count(*) = 10 FROM pg_proc p WHERE p.oid::regprocedure::text IN (SELECT firma FROM _foto) AND p.prosrc ~* '\mcurrent_date\M' AND p.prosrc !~ 'fn_hoy_mexico'$$);
SELECT pg_temp.verifica('R2 tras la reversa: SECURITY, search_path, volatilidad, ACL, dueño, argumentos y retorno iguales a la foto',
  $$SELECT count(*) = 10 FROM _foto f JOIN pg_proc p ON p.oid::regprocedure::text = f.firma
    WHERE p.prosecdef = f.prosecdef AND p.proconfig::text IS NOT DISTINCT FROM f.proconfig AND p.provolatile = f.provolatile
      AND p.proacl::text IS NOT DISTINCT FROM f.proacl AND pg_get_userbyid(p.proowner) = f.dueno
      AND pg_get_function_arguments(p.oid) = f.args AND pg_get_function_result(p.oid) = f.rettype$$);
SELECT pg_temp.verifica('R3 tras la reversa: comentarios previos (sin 127_) y cuerpos distintos de la foto',
  $$SELECT count(*) = 10 FROM _foto f JOIN pg_proc p ON p.oid::regprocedure::text = f.firma
    WHERE obj_description(p.oid, 'pg_proc') NOT LIKE '%127_:%' AND md5(p.prosrc) <> f.src_md5$$);

-- ---------- A: ANTES de 127_ (reproduce el defecto) ----------
SELECT pg_temp.caso('A1 [defecto] eliminar la jornada de mañana => SCJ02 (la cree ya empezada)', NULL,
  format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J2')), 'SCJ02');
SELECT pg_temp.caso('A2 [defecto] editar la jornada de mañana => SCJ02', NULL,
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'normal', %L::date + 2, '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":60}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'SCJ02');
SELECT pg_temp.caso('A3 [defecto] mover el límite de la jornada en curso => SCJ02 (no la ve vigente hoy)', NULL,
  format('SELECT tiempo.fn_jornada_en_curso_mover_limite(%s, %L::date + 5)', pg_temp.k('J1'), pg_temp.k('hoy')), 'SCJ02');
SELECT pg_temp.caso('A4 [defecto] UPDATE directo: alargar el cierre de hoy y mover la de mañana => 23514', NULL,
  format('UPDATE tiempo.jornada_asignada SET vigente_hasta = %2$L::date + 2 WHERE id = %1$s; UPDATE tiempo.jornada_asignada SET vigente_desde = %2$L::date + 3 WHERE id = %3$s',
         pg_temp.k('J1'), pg_temp.k('hoy'), pg_temp.k('J2')), '23514');
SELECT pg_temp.caso('A5 [defecto] editar el patrón de la jornada de mañana => 23514', NULL,
  format($q$UPDATE tiempo.patron_semanal SET hora_salida = '16:00' WHERE jornada_asignada_id = %s$q$, pg_temp.k('J2')), '23514');
SELECT pg_temp.caso('A6 [defecto] baja sin fecha => fecha_baja = mañana', NULL,
  format($q$UPDATE personas.persona SET estado = 'baja_definitiva' WHERE id = %L$q$, pg_temp.k('BJ')), 'ok',
  format($q$SELECT fecha_baja = %L::date + 1 FROM personas.persona WHERE id = %L$q$, pg_temp.k('hoy'), pg_temp.k('BJ')));
SELECT pg_temp.caso('A7 [defecto] fn_parametro_actualizar_valor abre la vigencia mañana', 'svc',
  format($q$SELECT tiempo.fn_parametro_actualizar_valor('tolerancia_retardo_min', %L, %L::uuid)$q$, pg_temp.k('tol_valor'), pg_temp.k('auth_admin')), 'ok',
  format($q$SELECT vigente_desde = %L::date + 1 FROM tiempo.parametro WHERE clave = 'tolerancia_retardo_min' AND vigente_hasta IS NULL$q$, pg_temp.k('hoy')));
SELECT pg_temp.caso('A8 [defecto] fn_terminal_config_valor ya lee la vigencia que empieza mañana', NULL,
  format($q$UPDATE tiempo.parametro SET vigente_hasta = %1$L::date WHERE clave = 'terminal_anomalias_ventana_dias' AND vigente_hasta IS NULL;
            INSERT INTO tiempo.parametro (clave, valor, vigente_desde, registrado_por) VALUES ('terminal_anomalias_ventana_dias', %2$L, %1$L::date + 1, %3$L::uuid)$q$,
         pg_temp.k('hoy'), pg_temp.k('anom_nuevo'), pg_temp.k('auth_admin')), 'ok',
  format($q$SELECT tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias') = %s$q$, pg_temp.k('anom_nuevo')));

-- ---------- aplica 127_ ----------
\ir ../ddl/127_tiempo_personas_hoy_en_hora_de_mexico.sql
SELECT pg_temp.verifica('P4 la zona de la sesión sigue dando CURRENT_DATE = mañana', $$SELECT CURRENT_DATE = pg_temp.k('hoy')::date + 1$$);
SELECT pg_temp.verifica('R5 127_ reaplicada: cuerpos (md5) y comentarios idénticos a la foto',
  $$SELECT count(*) = 10 FROM _foto f JOIN pg_proc p ON p.oid::regprocedure::text = f.firma
    WHERE md5(p.prosrc) = f.src_md5 AND obj_description(p.oid, 'pg_proc') IS NOT DISTINCT FROM f.comentario$$);

-- ---------- D: DESPUÉS de 127_ (misma zona; manda la fecha de México) ----------
-- Jornada que empieza mañana en México: sigue siendo futura, editable y eliminable.
SELECT pg_temp.caso('D1 eliminar la jornada de mañana (dueño) => ok, la anterior se reabre', NULL,
  format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J2')), 'ok',
  format('SELECT NOT EXISTS (SELECT 1 FROM tiempo.jornada_asignada WHERE id = %s) AND (SELECT vigente_hasta IS NULL FROM tiempo.jornada_asignada WHERE id = %s)', pg_temp.k('J2'), pg_temp.k('J1')));
SELECT pg_temp.caso('D2 eliminar la jornada de mañana (authenticated, admin) => ok', 'adm',
  format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J2')), 'ok',
  format('SELECT NOT EXISTS (SELECT 1 FROM tiempo.jornada_asignada WHERE id = %s)', pg_temp.k('J2')));
SELECT pg_temp.caso('D3 DELETE directo de patrón y jornada de mañana => ok (triggers de borrado y de patrón)', NULL,
  format('DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = %1$s; DELETE FROM tiempo.jornada_asignada WHERE id = %1$s; UPDATE tiempo.jornada_asignada SET vigente_hasta = NULL WHERE id = %2$s',
         pg_temp.k('J2'), pg_temp.k('J1')), 'ok',
  format('SELECT NOT EXISTS (SELECT 1 FROM tiempo.jornada_asignada WHERE id = %s)', pg_temp.k('J2')));
SELECT pg_temp.caso('D4 editar la jornada de mañana a pasado mañana (dueño) => ok, la anterior cierra mañana', NULL,
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'normal', %L::date + 2, '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":60}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'ok',
  format('SELECT (SELECT vigente_desde FROM tiempo.jornada_asignada WHERE id = %1$s) = %3$L::date + 2 AND (SELECT vigente_hasta FROM tiempo.jornada_asignada WHERE id = %2$s) = %3$L::date + 1',
         pg_temp.k('J2'), pg_temp.k('J1'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D5 editar la jornada de mañana sin mover la fecha (authenticated, admin) => ok', 'adm',
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'flexible', %L::date + 1, '[{"dia_semana":"martes","hora_entrada":"10:00","hora_salida":"18:00","minutos_comida":30}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'ok',
  format($q$SELECT tipo_jornada = 'flexible' FROM tiempo.jornada_asignada WHERE id = %s$q$, pg_temp.k('J2')));
SELECT pg_temp.caso('D6 editar la jornada para que empiece HOY => SCJ04 (hoy no es futuro)', NULL,
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'normal', %L::date, '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":60}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'SCJ04');
SELECT pg_temp.caso('D7 eliminar la jornada en curso => SCJ02', NULL,
  format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J1')), 'SCJ02');
SELECT pg_temp.caso('D8 mover el límite de la jornada en curso a hoy+5 (dueño) => ok, la siguiente empieza hoy+6', NULL,
  format('SELECT tiempo.fn_jornada_en_curso_mover_limite(%s, %L::date + 5)', pg_temp.k('J1'), pg_temp.k('hoy')), 'ok',
  format('SELECT (SELECT vigente_hasta FROM tiempo.jornada_asignada WHERE id = %1$s) = %3$L::date + 5 AND (SELECT vigente_desde FROM tiempo.jornada_asignada WHERE id = %2$s) = %3$L::date + 6',
         pg_temp.k('J1'), pg_temp.k('J2'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D9 mover el límite de la jornada en curso (authenticated, admin) => ok', 'adm',
  format('SELECT tiempo.fn_jornada_en_curso_mover_limite(%s, %L::date + 3)', pg_temp.k('J1'), pg_temp.k('hoy')), 'ok',
  format('SELECT vigente_hasta = %L::date + 3 FROM tiempo.jornada_asignada WHERE id = %s', pg_temp.k('hoy'), pg_temp.k('J1')));
SELECT pg_temp.caso('D10 mover el límite a HOY => SCJ04', NULL,
  format('SELECT tiempo.fn_jornada_en_curso_mover_limite(%s, %L::date)', pg_temp.k('J1'), pg_temp.k('hoy')), 'SCJ04');
SELECT pg_temp.caso('D11 UPDATE directo: alargar el cierre de hoy y mover la de mañana => ok', NULL,
  format('UPDATE tiempo.jornada_asignada SET vigente_hasta = %2$L::date + 2 WHERE id = %1$s; UPDATE tiempo.jornada_asignada SET vigente_desde = %2$L::date + 3 WHERE id = %3$s',
         pg_temp.k('J1'), pg_temp.k('hoy'), pg_temp.k('J2')), 'ok',
  format('SELECT vigente_desde = %L::date + 3 FROM tiempo.jornada_asignada WHERE id = %s', pg_temp.k('hoy'), pg_temp.k('J2')));
SELECT pg_temp.caso('D12 UPDATE directo: cierre en el pasado (ayer) => 23514', NULL,
  format('UPDATE tiempo.jornada_asignada SET vigente_hasta = %L::date - 1 WHERE id = %s', pg_temp.k('hoy'), pg_temp.k('J1')), '23514');
SELECT pg_temp.caso('D13 UPDATE directo: cambiar el tipo de la jornada en curso => 23514', NULL,
  format($q$UPDATE tiempo.jornada_asignada SET tipo_jornada = 'flexible', genera_alerta_horario = false WHERE id = %s$q$, pg_temp.k('J1')), '23514');
SELECT pg_temp.caso('D14 UPDATE directo: mover la de mañana a HOY => 23514', NULL,
  format('UPDATE tiempo.jornada_asignada SET vigente_desde = %2$L::date WHERE id = %3$s; UPDATE tiempo.jornada_asignada SET vigente_hasta = %2$L::date - 1 WHERE id = %1$s',
         pg_temp.k('J1'), pg_temp.k('hoy'), pg_temp.k('J2')), '23514');
SELECT pg_temp.caso('D15 editar el patrón de la jornada de mañana => ok', NULL,
  format($q$UPDATE tiempo.patron_semanal SET hora_salida = '16:00' WHERE jornada_asignada_id = %s$q$, pg_temp.k('J2')), 'ok',
  format($q$SELECT bool_and(hora_salida = '16:00') FROM tiempo.patron_semanal WHERE jornada_asignada_id = %s$q$, pg_temp.k('J2')));
SELECT pg_temp.caso('D16 editar el patrón de la jornada en curso => 23514', NULL,
  format($q$UPDATE tiempo.patron_semanal SET hora_salida = '16:00' WHERE jornada_asignada_id = %s$q$, pg_temp.k('J1')), '23514');
SELECT pg_temp.caso('D17 borrar el patrón de la jornada en curso => 23514', NULL,
  format('DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = %s', pg_temp.k('J1')), '23514');

-- Baja: la fecha por omisión es hoy en México.
SELECT pg_temp.caso('D18 baja sin fecha => fecha_baja = hoy en México', NULL,
  format($q$UPDATE personas.persona SET estado = 'baja_definitiva' WHERE id = %L$q$, pg_temp.k('BJ')), 'ok',
  format($q$SELECT fecha_baja = %L::date AND estado = 'baja_definitiva' FROM personas.persona WHERE id = %L$q$, pg_temp.k('hoy'), pg_temp.k('BJ')));
SELECT pg_temp.caso('D19 baja con fecha explícita => se respeta', NULL,
  format($q$UPDATE personas.persona SET estado = 'baja_definitiva', fecha_baja = DATE '2026-10-01' WHERE id = %L$q$, pg_temp.k('BJ')), 'ok',
  format($q$SELECT fecha_baja = DATE '2026-10-01' FROM personas.persona WHERE id = %L$q$, pg_temp.k('BJ')));

-- Parámetros: la vigencia nueva empieza hoy en México; el segundo cambio del día corrige en sitio.
SELECT pg_temp.caso('D20 fn_parametro_actualizar_valor (service_role) dos veces => una vigencia desde hoy, ninguna futura, sin intervalos invertidos', 'svc',
  format($q$SELECT tiempo.fn_parametro_actualizar_valor('tolerancia_retardo_min', '11', %1$L::uuid); SELECT tiempo.fn_parametro_actualizar_valor('tolerancia_retardo_min', %2$L, %1$L::uuid)$q$,
         pg_temp.k('auth_admin'), pg_temp.k('tol_valor')), 'ok',
  format($q$SELECT (SELECT vigente_desde = %1$L::date AND valor = %2$L FROM tiempo.parametro WHERE clave = 'tolerancia_retardo_min' AND vigente_hasta IS NULL)
            AND NOT EXISTS (SELECT 1 FROM tiempo.parametro WHERE clave NOT LIKE 'terminal\_inferir\_huella\_%%' AND (vigente_desde > %1$L::date OR vigente_hasta < vigente_desde))
            AND (SELECT count(*) FROM tiempo.parametro WHERE clave = 'tolerancia_retardo_min' AND vigente_desde = %1$L::date) = 1$q$,
         pg_temp.k('hoy'), pg_temp.k('tol_valor')));
SELECT pg_temp.caso('D21 fn_terminal_config_actualizar (authenticated, admin) => vigente_desde = hoy en México', 'adm',
  format($q$SELECT tiempo.fn_terminal_config_actualizar('terminal_anomalias_ventana_dias', %L)$q$, pg_temp.k('anom_nuevo')), 'ok',
  format($q$SELECT (SELECT vigente_desde = %1$L::date AND valor = %2$L FROM tiempo.parametro WHERE clave = 'terminal_anomalias_ventana_dias' AND vigente_hasta IS NULL)
            AND tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias') = %2$s
            AND NOT EXISTS (SELECT 1 FROM tiempo.parametro WHERE clave = 'terminal_anomalias_ventana_dias' AND (vigente_desde > %1$L::date OR vigente_hasta < vigente_desde))$q$,
         pg_temp.k('hoy'), pg_temp.k('anom_nuevo')));
SELECT pg_temp.caso('D22 fn_terminal_config_valor NO lee todavía la vigencia que empieza mañana', NULL,
  format($q$UPDATE tiempo.parametro SET vigente_hasta = %1$L::date WHERE clave = 'terminal_anomalias_ventana_dias' AND vigente_hasta IS NULL;
            INSERT INTO tiempo.parametro (clave, valor, vigente_desde, registrado_por) VALUES ('terminal_anomalias_ventana_dias', %2$L, %1$L::date + 1, %3$L::uuid)$q$,
         pg_temp.k('hoy'), pg_temp.k('anom_nuevo'), pg_temp.k('auth_admin')), 'ok',
  format($q$SELECT tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias') = %s$q$, pg_temp.k('anom_valor')));
SELECT pg_temp.caso('D23 fn_terminal_config_valor como service_role => ok', 'svc',
  $q$SELECT tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias')$q$, 'ok');

-- ---------- Z: otras zonas de sesión; tras 127_ el resultado no depende de ellas ----------
SELECT set_config('TimeZone', 'UTC', true);
SELECT pg_temp.caso('Z1 [UTC] eliminar la jornada de mañana => ok', NULL, format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J2')), 'ok');
SELECT pg_temp.caso('Z2 [UTC] editar para que empiece hoy => SCJ04', NULL,
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'normal', %L::date, '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":60}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'SCJ04');
SELECT set_config('TimeZone', 'Pacific/Pago_Pago', true);
SELECT pg_temp.caso('Z3 [UTC-11] eliminar la jornada de mañana => ok', NULL, format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J2')), 'ok');
SELECT pg_temp.caso('Z4 [UTC-11] editar para que empiece hoy => SCJ04', NULL,
  format($q$SELECT tiempo.fn_jornada_futura_actualizar(%s, 'normal', %L::date, '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":60}]'::jsonb)$q$, pg_temp.k('J2'), pg_temp.k('hoy')), 'SCJ04');
SELECT pg_temp.caso('Z5 [UTC-11] eliminar la jornada en curso => SCJ02', NULL, format('SELECT tiempo.fn_jornada_futura_eliminar(%s)', pg_temp.k('J1')), 'SCJ02');
SELECT pg_temp.caso('Z6 [UTC-11] baja sin fecha => hoy en México', NULL,
  format($q$UPDATE personas.persona SET estado = 'baja_definitiva' WHERE id = %L$q$, pg_temp.k('BJ')), 'ok',
  format($q$SELECT fecha_baja = %L::date FROM personas.persona WHERE id = %L$q$, pg_temp.k('hoy'), pg_temp.k('BJ')));
SELECT set_config('TimeZone', pg_temp.k('zona'), true);

-- ---------- F: catálogo después de 127_ ----------
SELECT pg_temp.verifica('F1 ninguna función de tiempo/personas usa CURRENT_DATE, LOCALTIMESTAMP ni now()::date',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace IN ('tiempo'::regnamespace, 'personas'::regnamespace)
      AND p.prosrc ~* '\mcurrent_date\M|\mlocaltimestamp\M|now\(\)\s*::\s*date|\mcurrent_timestamp\s*::\s*date')$$);
SELECT pg_temp.verifica('F2 las 10 funciones llaman a personas.fn_hoy_mexico()',
  $$SELECT count(*) = 10 FROM pg_proc p WHERE p.oid::regprocedure::text IN (SELECT firma FROM _foto) AND p.prosrc LIKE '%personas.fn_hoy_mexico()%'$$);
SELECT pg_temp.verifica('F3 atributos idénticos a la foto: SECURITY, search_path, volatilidad, ACL, dueño, argumentos (con DEFAULT) y tipo de retorno',
  $$SELECT count(*) = 10 FROM _foto f JOIN pg_proc p ON p.oid::regprocedure::text = f.firma
    WHERE p.prosecdef = f.prosecdef AND p.proconfig::text IS NOT DISTINCT FROM f.proconfig AND p.provolatile = f.provolatile
      AND p.proacl::text IS NOT DISTINCT FROM f.proacl AND pg_get_userbyid(p.proowner) = f.dueno
      AND pg_get_function_arguments(p.oid) = f.args AND pg_get_function_result(p.oid) = f.rettype$$);
SELECT pg_temp.verifica('F4 ninguna de las 10 da EXECUTE a PUBLIC ni a anon',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid::regprocedure::text IN (SELECT firma FROM _foto)
      AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)))$$);
SELECT pg_temp.verifica('F5 los 10 comentarios mencionan 127_',
  $$SELECT count(*) = 10 FROM pg_proc p WHERE p.oid::regprocedure::text IN (SELECT firma FROM _foto) AND obj_description(p.oid, 'pg_proc') LIKE '%127_%'$$);
SELECT pg_temp.verifica('F6 fn_hoy_mexico conserva EXECUTE solo para authenticated y service_role (sin PUBLIC ni anon)',
  $$SELECT has_function_privilege('authenticated', 'personas.fn_hoy_mexico(timestamptz)', 'EXECUTE') AND has_function_privilege('service_role', 'personas.fn_hoy_mexico(timestamptz)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'personas.fn_hoy_mexico(timestamptz)', 'EXECUTE')$$);
SELECT pg_temp.verifica('F7 fuera de alcance intactas: fn_jornada_asignada_valida_cadena sin fecha de hoy; fn_terminal_inferir_huella_* con UTC explícito',
  $$SELECT (SELECT prosrc !~* 'fn_hoy_mexico' FROM pg_proc WHERE oid = 'tiempo.fn_jornada_asignada_valida_cadena()'::regprocedure)
       AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname IN ('fn_terminal_inferir_huella_cambiar', 'fn_terminal_inferir_huella_estado')
              AND prosrc LIKE '%(now() AT TIME ZONE ''UTC'')::date%') = 2$$);

-- Sección 89 de verificar_ddl.sql (debe devolver 0 filas tras 127_).
\echo '--- sección 89 de verificar_ddl.sql (esperado: 0 filas) ---'
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS objeto, 'usa la fecha de la sesión (UTC) en vez de personas.fn_hoy_mexico()' AS problema
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('tiempo', 'personas')
  AND p.prosrc ~* '\mcurrent_date\M|\mlocaltimestamp\M|now\(\)\s*::\s*date|\mcurrent_timestamp\s*::\s*date'
UNION ALL
SELECT 'tiempo/personas', 'falta personas.fn_hoy_mexico() en alguna de las 10 funciones de 127_'
WHERE (SELECT count(*) FROM pg_proc p
       WHERE p.oid IN ('personas.fn_persona_sincroniza_baja()'::regprocedure, 'tiempo.fn_jornada_asignada_protege_borrado()'::regprocedure,
                       'tiempo.fn_jornada_asignada_protege_vigencias()'::regprocedure, 'tiempo.fn_patron_semanal_solo_jornada_futura()'::regprocedure,
                       'tiempo.fn_jornada_en_curso_mover_limite(bigint, date)'::regprocedure,
                       'tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer)'::regprocedure,
                       'tiempo.fn_jornada_futura_eliminar(bigint)'::regprocedure, 'tiempo.fn_parametro_actualizar_valor(character varying, text, uuid)'::regprocedure,
                       'tiempo.fn_terminal_config_actualizar(text, text)'::regprocedure, 'tiempo.fn_terminal_config_valor(text)'::regprocedure)
         AND p.prosrc LIKE '%personas.fn_hoy_mexico()%') <> 10;

-- ---------- resultado ----------
SELECT n, caso, ok, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE ok) || '/' || count(*) AS resultado FROM _res;

ROLLBACK;
