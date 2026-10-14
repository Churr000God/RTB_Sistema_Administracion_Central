-- Ensayo de 105_funciones_revoca_execute_triggers_y_helpers.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_105.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 105_ ENCIMA de lo ya aplicado. Personas, usuario, puesto, marca, ausencia y jornada SINTÉTICOS creados en la transacción y revertidos (incluye filas en
-- bitácoras inmutables, que el ROLLBACK descarta). El administrador real solo es caller/autor.
-- Qué prueba: (A) foto de ACL EFECTIVO y proconfig de TODAS las funciones de personas/tiempo/public antes/después: cambia EXACTAMENTE lo listado y nada más; (B) DISPARO REAL de los 13 triggers (contador
-- pg_stat_get_xact_function_calls con track_functions = 'all' en la transacción), con roles que no tienen EXECUTE; (C) lecturas con RLS como authenticated con claims reales: mismos conteos antes y después;
-- (D) RPC de authenticated con claims (jornada, movimiento de saldo manual, configuración de terminal, persona, pendientes de reconsentimiento); (E) cada función revocada => 42501 para anon, authenticated
-- (y service_role en las de trigger); (F) reversa documentada y ensayada; (G) verificar_ddl.sql completo (sección 70 en 0 filas).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
SET LOCAL track_functions = 'all';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (fase text, fn text, pub boolean, anon boolean, auth boolean, svc boolean, cfg text, secdef boolean);
CREATE TEMP TABLE _cnt (fase text, tabla text, n bigint);
-- Lo que 105_ cambia, EXACTAMENTE: (función, rol que PIERDE el EXECUTE).
CREATE TEMP TABLE _esperado (fn text, rol text);
INSERT INTO _esperado
SELECT t.fn, r.rol FROM unnest(ARRAY[
  'personas.fn_bitacora_inmutable()', 'personas.fn_bitacora_puesto_permiso_inmutable()', 'personas.fn_bitacora_sincroniza_persona()', 'personas.fn_persona_sincroniza_baja()',
  'personas.fn_persona_sincroniza_tiempo()', 'personas.fn_puesto_permiso_sincroniza()', 'personas.fn_usuario_bitacora_alta()',
  'tiempo.fn_aprobacion_ausencia_actualiza_ausencia()', 'tiempo.fn_ausencia_resuelve_excepcion()', 'tiempo.fn_correccion_recalcula_tramo()', 'tiempo.fn_correccion_valida()',
  'tiempo.fn_marca_valida_revision()', 'tiempo.fn_patron_semanal_valida_tope_legal()']) t(fn)
CROSS JOIN unnest(ARRAY['pub', 'anon', 'auth', 'svc']) r(rol);
-- fn_terminal_config_catalogo (89_) solo tenía authenticated y service_role (PUBLIC y anon ya revocados): pierde esos dos.
INSERT INTO _esperado VALUES ('tiempo.fn_terminal_config_catalogo()', 'auth'), ('tiempo.fn_terminal_config_catalogo()', 'svc');
INSERT INTO _esperado VALUES ('personas.fn_caller_activo()', 'pub'), ('personas.fn_caller_activo()', 'anon'),
                             ('personas.fn_caller_tiene_permiso(p_codigo text)', 'pub'), ('personas.fn_caller_tiene_permiso(p_codigo text)', 'anon');
GRANT ALL ON _ens, _res, _foto, _cnt TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_admin', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'persona_admin', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_admin');

-- Ejecuta p_sql como p_rol (claims = admin real salvo p_sub); p_esperado = 'ok' | SQLSTATE.
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
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 110));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- Foto del estado EFECTIVO de EXECUTE (PUBLIC, anon, authenticated, service_role), proconfig y secdef de las funciones propias.
CREATE FUNCTION pg_temp.foto(p_fase text) RETURNS void AS $$
  INSERT INTO _foto
  SELECT p_fase, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
         EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'),
         has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE'), has_function_privilege('service_role', p.oid, 'EXECUTE'),
         COALESCE(array_to_string(p.proconfig, ';'), '-'), p.prosecdef
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname IN ('personas', 'tiempo', 'public') AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e');
$$ LANGUAGE sql;

-- Cuenta filas de p_tabla como authenticated con claims del admin real (RLS aplica).
CREATE FUNCTION pg_temp.cuenta(p_fase text, p_tabla text) RETURNS void AS $$
DECLARE v bigint;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin'), 'role', 'authenticated')::text, true);
  EXECUTE format('SELECT count(*) FROM %s', p_tabla) INTO v;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _cnt VALUES (p_fase, p_tabla, v);
END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.foto('antes');
SELECT pg_temp.cuenta('antes', t) FROM unnest(ARRAY['tiempo.tramo', 'tiempo.dia', 'tiempo.ausencia', 'tiempo.marca', 'personas.persona', 'personas.asignacion', 'personas.puesto', 'tiempo.banco_de_horas',
  'tiempo.movimiento_de_saldo', 'tiempo.terminal', 'tiempo.terminal_usuario', 'tiempo.jornada_asignada', 'tiempo.excepcion']) t;
SELECT pg_temp.verifica('P0 precondición: TODO lo esperado existía antes (si no, 105_ ya estaba aplicada)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _esperado e JOIN _foto a ON a.fase = 'antes' AND a.fn = e.fn WHERE NOT (CASE e.rol WHEN 'pub' THEN a.pub WHEN 'anon' THEN a.anon WHEN 'auth' THEN a.auth ELSE a.svc END))
        AND (SELECT count(DISTINCT fn) FROM _esperado) = (SELECT count(DISTINCT e.fn) FROM _esperado e JOIN _foto a ON a.fase = 'antes' AND a.fn = e.fn)$$);

\ir ../ddl/105_funciones_revoca_execute_triggers_y_helpers.sql

SELECT pg_temp.foto('despues');

-- ============================================================================
-- A) Foto de ACL: cambia EXACTAMENTE lo esperado
-- ============================================================================
SELECT pg_temp.verifica('A1 nada GANA EXECUTE (todo lo concedido después ya lo estaba antes)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto d JOIN _foto a ON a.fase = 'antes' AND a.fn = d.fn WHERE d.fase = 'despues'
        AND ((d.pub AND NOT a.pub) OR (d.anon AND NOT a.anon) OR (d.auth AND NOT a.auth) OR (d.svc AND NOT a.svc)))$$);
SELECT pg_temp.verifica('A2 lo que se PIERDE es EXACTAMENTE la lista esperada (ni más ni menos)',
  $$WITH perdidos AS (
      SELECT a.fn, r.rol FROM _foto a JOIN _foto d ON d.fase = 'despues' AND d.fn = a.fn CROSS JOIN (VALUES ('pub'), ('anon'), ('auth'), ('svc')) r(rol)
      WHERE a.fase = 'antes' AND (CASE r.rol WHEN 'pub' THEN a.pub AND NOT d.pub WHEN 'anon' THEN a.anon AND NOT d.anon WHEN 'auth' THEN a.auth AND NOT d.auth ELSE a.svc AND NOT d.svc END))
    SELECT NOT EXISTS (SELECT 1 FROM perdidos p WHERE NOT EXISTS (SELECT 1 FROM _esperado e WHERE (e.fn, e.rol) = (p.fn, p.rol)))
       AND NOT EXISTS (SELECT 1 FROM _esperado e WHERE NOT EXISTS (SELECT 1 FROM perdidos p WHERE (e.fn, e.rol) = (p.fn, p.rol)))$$);
SELECT pg_temp.verifica('A3 proconfig, SECURITY DEFINER y el conjunto de funciones NO cambian (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND d.fn = a.fn AND d.cfg = a.cfg AND d.secdef = a.secdef))
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.fn = d.fn))$$);
SELECT pg_temp.verifica('A4 las dos helper CONSERVAN EXECUTE para authenticated y service_role (explícito)',
  $$SELECT bool_and(auth AND svc AND NOT pub AND NOT anon) FROM _foto WHERE fase = 'despues' AND fn IN ('personas.fn_caller_activo()', 'personas.fn_caller_tiene_permiso(p_codigo text)')$$);
SELECT pg_temp.verifica('A5 fn_dia_calcular_armado_tramos y las 15 RPC de authenticated no cambian',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a JOIN _foto d ON d.fase = 'despues' AND d.fn = a.fn WHERE a.fase = 'antes' AND a.fn LIKE 'tiempo.fn_dia_calcular_armado_tramos%' AND (a.auth <> d.auth OR a.svc <> d.svc))$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'A6 (informativo) funciones con EXECUTE para PUBLIC antes -> después', true,
  (SELECT count(*) FROM _foto WHERE fase = 'antes' AND pub) || ' -> ' || (SELECT count(*) FROM _foto WHERE fase = 'despues' AND pub) || ' (la que queda: public.rls_auto_enable, documentada)';

-- ============================================================================
-- C) Lecturas con RLS como authenticated (claims del admin real): mismos conteos antes y después de 105_
-- ============================================================================
SELECT pg_temp.cuenta('despues', t) FROM unnest(ARRAY['tiempo.tramo', 'tiempo.dia', 'tiempo.ausencia', 'tiempo.marca', 'personas.persona', 'personas.asignacion', 'personas.puesto', 'tiempo.banco_de_horas',
  'tiempo.movimiento_de_saldo', 'tiempo.terminal', 'tiempo.terminal_usuario', 'tiempo.jornada_asignada', 'tiempo.excepcion']) t;
-- (se cuentan ANTES de crear las filas sintéticas del ensayo, para que los conteos sean comparables)
SELECT pg_temp.verifica('C1 mismos conteos con RLS antes y después en las 13 tablas leídas (tramo, dia, ausencia, marca, persona, asignacion, puesto, banco_de_horas, movimiento_de_saldo, terminal, terminal_usuario, jornada_asignada, excepcion)',
  $$SELECT bool_and(a.n = d.n) AND count(*) = 13 FROM _cnt a JOIN _cnt d ON d.fase = 'despues' AND d.tabla = a.tabla WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('C2 con RLS el admin sigue viendo filas reales (>0) en persona, asignacion, puesto y terminal',
  $$SELECT bool_and(n > 0) FROM _cnt WHERE fase = 'despues' AND tabla IN ('personas.persona', 'personas.asignacion', 'personas.puesto', 'tiempo.terminal')$$);

-- ============================================================================
-- B) Disparo REAL de los 13 triggers (sin EXECUTE para nadie): contador de llamadas de la transacción
-- ============================================================================
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXY81', 'XEXY01010181', '99999940081', 'Sintetica81', 'Ensayo105', DATE '2000-01-01', CURRENT_DATE);   -- dispara fn_persona_sincroniza_baja (BUi) y fn_persona_sincroniza_tiempo (Ai)
INSERT INTO _ens SELECT 'P1', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXY81';
SELECT pg_temp.verifica('B0 el stub tiempo.persona apareció (efecto de fn_persona_sincroniza_tiempo)', $$SELECT EXISTS (SELECT 1 FROM tiempo.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'P1'))$$);
INSERT INTO _ens VALUES ('auth_u', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_u'), 'authenticated', 'authenticated', 'ens105@invalid.test');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_u'), (SELECT v::uuid FROM _ens WHERE k = 'P1'), 'ens105');  -- fn_usuario_bitacora_alta (+ fn_bitacora_sincroniza_persona)
-- inmutables: SIEMPRE levantan excepción, y pg_stat no cuenta una función que termina en error: se prueba por el MENSAJE del propio trigger (como dueño; distinguible de un error de privilegio 42501).
DO $$
DECLARE v_msg text;
BEGIN
  BEGIN UPDATE personas.bitacora_movimiento_persona SET motivo = motivo WHERE id = (SELECT id FROM personas.bitacora_movimiento_persona LIMIT 1);
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
  INSERT INTO _res (caso, ok, detalle) VALUES ('B7 fn_bitacora_inmutable dispara y rechaza el UPDATE (sin EXECUTE para nadie)', v_msg LIKE '%es de solo inserción%', left(COALESCE(v_msg, 'sin error'), 110));
  v_msg := NULL;
  BEGIN UPDATE personas.bitacora_movimiento_puesto_permiso SET motivo = motivo WHERE id = (SELECT id FROM personas.bitacora_movimiento_puesto_permiso LIMIT 1);
  EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
  INSERT INTO _res (caso, ok, detalle) VALUES ('B8 fn_bitacora_puesto_permiso_inmutable dispara y rechaza el UPDATE (sin EXECUTE para nadie)', v_msg LIKE '%es de solo inserción%', left(COALESCE(v_msg, 'sin error'), 110));
END $$;
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS105 puesto', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'banco_de_horas_lectura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS105 puesto';   -- fn_puesto_permiso_sincroniza
SELECT pg_temp.verifica('B1 efecto de fn_puesto_permiso_sincroniza: apareció puesto_permiso activo',
  $$SELECT EXISTS (SELECT 1 FROM personas.puesto_permiso pp JOIN personas.puesto p ON p.id = pp.puesto_id WHERE p.nombre_puesto = 'ENS105 puesto' AND pp.codigo = 'banco_de_horas_lectura' AND pp.activo)$$);
-- marca con reloj no sincronizado => fn_marca_valida_revision (AFTER INSERT) y excepción
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
VALUES ((SELECT v::uuid FROM _ens WHERE k = 'P1'), 'ENS105', 1, TIMESTAMPTZ '2026-02-10 14:00:00+00', '+00:00', 'sin_sincronizar', 'ens105', 'terminal');
INSERT INTO _ens SELECT 'marca', id::text FROM tiempo.marca WHERE terminal_id = 'ENS105' AND secuencia_local = 1;
SELECT pg_temp.verifica('B2 efecto de fn_marca_valida_revision: la marca quedó con requiere_revision', $$SELECT requiere_revision FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'marca')$$);
-- corrección por authenticated (admin, sin EXECUTE de las funciones de trigger): fn_correccion_valida (BEFORE) y fn_correccion_recalcula_tramo (AFTER)
SELECT pg_temp.caso('B3 corrección como authenticated (dispara fn_correccion_valida y fn_correccion_recalcula_tramo)', 'authenticated',
  format($f$INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (%s, TIMESTAMPTZ '2026-02-10 14:30:00+00', 'ens105', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'marca'), (SELECT v FROM _ens WHERE k = 'persona_admin')), 'ok');
-- ausencia pendiente + aprobación autorizada: fn_ausencia_resuelve_excepcion y fn_aprobacion_ausencia_actualiza_ausencia
INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion)
VALUES ((SELECT v::uuid FROM _ens WHERE k = 'P1'), 'vacaciones', DATE '2026-03-02', DATE '2026-03-03', 'pendiente');
INSERT INTO _ens SELECT 'aus', id::text FROM tiempo.ausencia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P1');
INSERT INTO tiempo.aprobacion_ausencia (ausencia_id, numero_paso, aprobador_id, decision, decidido_en)
VALUES ((SELECT v::bigint FROM _ens WHERE k = 'aus'), 1, (SELECT v::uuid FROM _ens WHERE k = 'persona_admin'), 'autorizada', now());
SELECT pg_temp.verifica('B4 efecto de fn_aprobacion_ausencia_actualiza_ausencia: la ausencia quedó autorizada', $$SELECT estado_autorizacion = 'autorizada' FROM tiempo.ausencia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'aus')$$);
-- jornada + patrón: fn_patron_semanal_valida_tope_legal, por el RPC de authenticated
SELECT pg_temp.caso('B5 RPC fn_jornada_asignar_renovar como authenticated (dispara fn_patron_semanal_valida_tope_legal)', 'authenticated',
  format($f$SELECT tiempo.fn_jornada_asignar_renovar(%L::uuid, 'normal', (CURRENT_DATE + 7), '[{"dia_semana":"lunes","hora_entrada":"09:00","hora_salida":"17:00","minutos_comida":30}]'::jsonb, false, NULL, false)$f$, (SELECT v FROM _ens WHERE k = 'P1')), 'ok');
-- fn_patron_semanal_valida_tope_legal es un CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED: se fuerza su disparo aquí (con ROLLBACK nunca llegaría al COMMIT).
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
-- Cada uno de los 11 que terminan normalmente debe haberse ejecutado al menos una vez en esta transacción (los 2 inmutables, B7 y B8).
SELECT pg_temp.verifica('B6 el trigger disparó (llamadas > 0): ' || f.fn,
  format($q$SELECT COALESCE(pg_stat_get_xact_function_calls(%L::regprocedure), 0) > 0$q$, f.fn))
FROM unnest(ARRAY[
  'personas.fn_bitacora_sincroniza_persona()', 'personas.fn_persona_sincroniza_baja()',
  'personas.fn_persona_sincroniza_tiempo()', 'personas.fn_puesto_permiso_sincroniza()', 'personas.fn_usuario_bitacora_alta()',
  'tiempo.fn_aprobacion_ausencia_actualiza_ausencia()', 'tiempo.fn_ausencia_resuelve_excepcion()', 'tiempo.fn_correccion_recalcula_tramo()', 'tiempo.fn_correccion_valida()',
  'tiempo.fn_marca_valida_revision()', 'tiempo.fn_patron_semanal_valida_tope_legal()']) f(fn);

-- ============================================================================
-- D) RPC de authenticated con claims (no deben regresar)
-- ============================================================================
INSERT INTO tiempo.banco_de_horas (persona_id, monto) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'P1'), 0);
INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en)
SELECT id, 'generado_quincena', 10, 'ens105', TIMESTAMPTZ '2026-01-15 10:00:00+00' FROM tiempo.banco_de_horas WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P1');
SELECT pg_temp.caso('D1 RPC movimiento de saldo manual (descontar 2) como authenticated', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 2, 'ens105')$f$, (SELECT v FROM _ens WHERE k = 'P1')), 'ok');
SELECT pg_temp.verifica('D1b el saldo bajó a 8', $$SELECT monto = 8 FROM tiempo.banco_de_horas WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'P1')$$);
SELECT pg_temp.caso('D2 RPC fn_terminal_config_actualizar como authenticated (usa internamente el catálogo revocado)', 'authenticated',
  $$SELECT tiempo.fn_terminal_config_actualizar('terminal_retencion_rechazos_dias', '45')$$, 'ok');
SELECT pg_temp.caso('D3 RPC fn_terminal_reconsentimiento_pendiente_ids como authenticated', 'authenticated', $$SELECT tiempo.fn_terminal_reconsentimiento_pendiente_ids()$$, 'ok');
SELECT pg_temp.caso('D4 RPC fn_persona_actualizar_datos como authenticated', 'authenticated',
  format($f$SELECT personas.fn_persona_actualizar_datos(%L::uuid, p_primer_nombre => 'Sintetica81b')$f$, (SELECT v FROM _ens WHERE k = 'P1')), 'ok');
SELECT pg_temp.caso('D5 las helper siguen ejecutables por authenticated y service_role', 'authenticated', $$SELECT personas.fn_caller_activo(), personas.fn_caller_tiene_permiso('banco_de_horas_lectura')$$, 'ok');
SELECT pg_temp.caso('D5b ... y por service_role', 'service_role', $$SELECT personas.fn_caller_activo(), personas.fn_caller_tiene_permiso('banco_de_horas_lectura')$$, 'ok');
SELECT pg_temp.caso('D6 service_role sigue llamando fn_dia_calcular_armado_tramos (dias.py:167)', 'service_role', $$SELECT * FROM tiempo.fn_dia_calcular_armado_tramos(-1)$$, 'ok');

-- ============================================================================
-- E) Lo revocado responde 42501
-- ============================================================================
SELECT pg_temp.caso('E1 anon: ' || f.fn, 'anon', 'SELECT ' || f.fn, '42501')
FROM unnest(ARRAY[
  'personas.fn_bitacora_inmutable()', 'personas.fn_bitacora_puesto_permiso_inmutable()', 'personas.fn_bitacora_sincroniza_persona()', 'personas.fn_persona_sincroniza_baja()',
  'personas.fn_persona_sincroniza_tiempo()', 'personas.fn_puesto_permiso_sincroniza()', 'personas.fn_usuario_bitacora_alta()',
  'tiempo.fn_aprobacion_ausencia_actualiza_ausencia()', 'tiempo.fn_ausencia_resuelve_excepcion()', 'tiempo.fn_correccion_recalcula_tramo()', 'tiempo.fn_correccion_valida()',
  'tiempo.fn_marca_valida_revision()', 'tiempo.fn_patron_semanal_valida_tope_legal()', 'tiempo.fn_terminal_config_catalogo()',
  'personas.fn_caller_activo()', $$personas.fn_caller_tiene_permiso('x')$$]) f(fn);
SELECT pg_temp.caso('E2 authenticated: ' || f.fn, 'authenticated', 'SELECT ' || f.fn, '42501')
FROM unnest(ARRAY['personas.fn_bitacora_inmutable()', 'personas.fn_persona_sincroniza_tiempo()', 'tiempo.fn_correccion_valida()', 'tiempo.fn_marca_valida_revision()',
                  'tiempo.fn_patron_semanal_valida_tope_legal()', 'tiempo.fn_terminal_config_catalogo()']) f(fn);
SELECT pg_temp.caso('E3 service_role: ' || f.fn, 'service_role', 'SELECT ' || f.fn, '42501')
FROM unnest(ARRAY['personas.fn_bitacora_inmutable()', 'personas.fn_persona_sincroniza_tiempo()', 'tiempo.fn_correccion_valida()', 'tiempo.fn_terminal_config_catalogo()']) f(fn);

-- ============================================================================
-- F) Reversa documentada: el estado EFECTIVO vuelve exacto
-- ============================================================================
SELECT pg_temp.foto('tras_105');
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'personas.fn_bitacora_inmutable()', 'personas.fn_bitacora_puesto_permiso_inmutable()', 'personas.fn_bitacora_sincroniza_persona()', 'personas.fn_persona_sincroniza_baja()',
    'personas.fn_persona_sincroniza_tiempo()', 'personas.fn_puesto_permiso_sincroniza()', 'personas.fn_usuario_bitacora_alta()',
    'tiempo.fn_aprobacion_ausencia_actualiza_ausencia()', 'tiempo.fn_ausencia_resuelve_excepcion()', 'tiempo.fn_correccion_recalcula_tramo()', 'tiempo.fn_correccion_valida()',
    'tiempo.fn_marca_valida_revision()', 'tiempo.fn_patron_semanal_valida_tope_legal()',
    'personas.fn_caller_activo()', 'personas.fn_caller_tiene_permiso(text)']
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', f);
  END LOOP;
  -- el catálogo NO tenía PUBLIC: solo authenticated y service_role (89_)
  GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_catalogo() TO authenticated, service_role;
END
$$;
SELECT pg_temp.foto('reversa');
SELECT pg_temp.verifica('F1 tras la reversa el EXECUTE efectivo vuelve EXACTO a la foto previa (PUBLIC implica los demás), en ambos sentidos',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a JOIN _foto r ON r.fase = 'reversa' AND r.fn = a.fn WHERE a.fase = 'antes' AND (a.pub <> r.pub OR a.anon <> r.anon OR a.auth <> r.auth OR a.svc <> r.svc))$$);
\ir ../ddl/105_funciones_revoca_execute_triggers_y_helpers.sql
SELECT pg_temp.foto('reaplicada');
SELECT pg_temp.verifica('F2 105_ es idempotente: reaplicarla tras la reversa deja la misma foto que la primera vez',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a JOIN _foto r ON r.fase = 'reaplicada' AND r.fn = a.fn WHERE a.fase = 'tras_105' AND (a.pub <> r.pub OR a.anon <> r.anon OR a.auth <> r.auth OR a.svc <> r.svc))$$);

-- ============================================================================
-- G) verificar_ddl.sql completo con 105_ aplicada: sección 70 en 0 filas (la 71 da su fila hasta 106_)
-- ============================================================================
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
