-- Ensayo de 104_tiempo_movimiento_saldo_actualiza_banco_definer.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_104.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 104_ ENCIMA de lo ya aplicado (88_-103_, o al menos 88_-100_). Personas, usuarios, bancos y movimientos SINTÉTICOS creados en la transacción y
-- revertidos (incluye filas en personas.bitacora_movimiento_persona por el alta del usuario sintético, que el ROLLBACK descarta). El administrador real solo es caller (y autor) de movimientos manuales.
-- (A0) ANTES de aplicar 104_ documenta el defecto vigente; (A) atributos; (B) tres tipos manuales con el permiso (admin): saldo y vivo_desde exactos; (C) camino del batch (service_role);
-- (D) vía directa cerrada para TODOS (también con permiso) con cada forma de abuso, autorización dentro del RPC (sin permiso, suspendida, solo lectura, anon) y validaciones intactas; (E) propiedades
-- estáticas (cuerpo, policy, grants, RPC); (F) verificador completo (secciones 68 y 69 en 0 filas).
-- CONCURRENCIA (no simulable en una sola transacción): la ausencia de actualización perdida se apoya en la semántica de PostgreSQL (UPDATE toma el candado de la fila y, en READ COMMITTED, una segunda
-- sesión espera y re-evalúa «monto + NEW.monto» sobre la versión actualizada) y en la prueba E2 (una sola sentencia UPDATE, sin SELECT del monto). Una prueba con dos sesiones reales exige COMMIT
-- (residuo) y no se hace contra la base real.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_admin', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'persona_admin', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_admin');

-- p_sub: NULL = el admin real; otro = ese auth uid. p_esperado = 'ok' | SQLSTATE.
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
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 100));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.monto(p_k text) RETURNS numeric AS $$ SELECT monto FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = p_k); $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.vivo(p_k text) RETURNS timestamptz AS $$ SELECT vivo_desde FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = p_k); $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.suma(p_k text) RETURNS numeric AS $$ SELECT COALESCE(sum(monto), 0) FROM tiempo.movimiento_de_saldo WHERE banco_de_horas_id = (SELECT v::bigint FROM _ens WHERE k = p_k); $$ LANGUAGE sql;

-- ---------- fixture: personas sintéticas, stub de tiempo, bancos, un usuario sin permisos ----------
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXY' || i, 'XEXY010101' || i, '9999994' || '00' || i, 'Sintetica' || i, 'Ensayo104', DATE '2000-01-01', CURRENT_DATE
FROM unnest(ARRAY['71', '72', '73', '74']) i;
INSERT INTO _ens SELECT 'P' || (ord), p.id::text FROM unnest(ARRAY['71', '72', '73', '74']) WITH ORDINALITY u(i, ord) JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXY' || u.i;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k ~ '^P[0-9]$' ON CONFLICT DO NOTHING;
-- P1 = banco BB (pre-prueba del defecto), P2 = banco BA (pruebas principales), P3 = banco BC (acumulación del batch), P4 = usuario sin permisos (con banco BD).
INSERT INTO tiempo.banco_de_horas (persona_id, monto) SELECT v::uuid, 0 FROM _ens WHERE k IN ('P1', 'P2', 'P3', 'P4');
INSERT INTO _ens SELECT CASE e.k WHEN 'P1' THEN 'BB' WHEN 'P2' THEN 'BA' WHEN 'P3' THEN 'BC' ELSE 'BD' END, b.id::text FROM _ens e JOIN tiempo.banco_de_horas b ON b.persona_id = e.v::uuid WHERE e.k IN ('P1', 'P2', 'P3', 'P4');
INSERT INTO _ens VALUES ('auth_sin', gen_random_uuid()::text), ('auth_lec', gen_random_uuid()::text), ('auth_susp', gen_random_uuid()::text), ('auth_edi', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_sin', 'auth_lec', 'auth_susp', 'auth_edi');
-- Más personas: P5 = suspendida CON el permiso de edición; P6 = activa con SOLO banco_de_horas_lectura; P7 = activa con movimiento_de_saldo_edicion (no administrador).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXY' || i, 'XEXY010101' || i, '9999994' || '00' || i, 'Sintetica' || i, 'Ensayo104', DATE '2000-01-01', CURRENT_DATE FROM unnest(ARRAY['75', '76', '77']) i;
INSERT INTO _ens SELECT 'P' || (4 + ord), p.id::text FROM unnest(ARRAY['75', '76', '77']) WITH ORDINALITY u(i, ord) JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXY' || u.i;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k IN ('P5', 'P6', 'P7') ON CONFLICT DO NOTHING;
-- Puestos sintéticos hijos del Gerente General (no heredan nada hacia abajo): uno con movimiento_de_saldo_edicion y otro con SOLO banco_de_horas_lectura.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS104 edicion', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS104 edicion B', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS104 lectura', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'movimiento_de_saldo_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS104 edicion';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'movimiento_de_saldo_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS104 edicion B';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'banco_de_horas_lectura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS104 lectura';
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k = 'auth_sin'),  (SELECT v::uuid FROM _ens WHERE k = 'P4'), 'ens104sin'),
  ((SELECT v::uuid FROM _ens WHERE k = 'auth_susp'), (SELECT v::uuid FROM _ens WHERE k = 'P5'), 'ens104susp'),
  ((SELECT v::uuid FROM _ens WHERE k = 'auth_lec'),  (SELECT v::uuid FROM _ens WHERE k = 'P6'), 'ens104lec'),
  ((SELECT v::uuid FROM _ens WHERE k = 'auth_edi'),  (SELECT v::uuid FROM _ens WHERE k = 'P7'), 'ens104edi');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'P5'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS104 edicion';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'P6'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS104 lectura';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'P7'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS104 edicion B';
-- P5 queda suspendida (conserva el puesto): fn_caller_activo debe responder false.
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'P5');
-- saldo inicial de BB (como lo haría el batch, ANTES de aplicar 104_; el trigger vigente corre como el dueño y sí actualiza)
INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en)
VALUES ((SELECT v::bigint FROM _ens WHERE k = 'BB'), 'generado_quincena', 10, 'ens104', TIMESTAMPTZ '2026-01-15 10:00:00+00');

-- ---------- A0: el defecto VIGENTE (antes de aplicar 104_) ----------
SELECT pg_temp.caso('A0a (informativo) ANTES de 104_: el RPC manual (authenticated, admin) inserta el movimiento', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 3, 'ens104 defecto')$f$, (SELECT v FROM _ens WHERE k = 'P1')), 'ok');
INSERT INTO _res (caso, ok, detalle)
SELECT 'A0b (informativo) ANTES de 104_: el saldo del banco NO cambió pese al movimiento (defecto: UPDATE filtrado por RLS) -- banco=' || pg_temp.monto('BB') || ' ledger=' || pg_temp.suma('BB'),
       true, 'si banco=10 y ledger=7 el defecto se reproduce; si banco=ledger, la base ya no lo tiene';

\ir ../ddl/104_tiempo_movimiento_saldo_actualiza_banco_definer.sql

-- ============================================================================
-- A) Atributos
-- ============================================================================
SELECT pg_temp.verifica('A1 SECURITY DEFINER, search_path = tiempo, pg_temp y dueño postgres',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_actualiza_banco'$$);
SELECT pg_temp.verifica('A2 sin EXECUTE para PUBLIC, anon, authenticated ni service_role',
  $$SELECT NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_actualiza_banco'$$);
SELECT pg_temp.verifica('A3 el trigger sigue siendo AFTER INSERT FOR EACH ROW sobre movimiento_de_saldo, habilitado y único',
  $$SELECT count(*) = 1 AND bool_and(t.tgenabled = 'O') AND bool_and((t.tgtype & 4) = 4 AND (t.tgtype & 2) = 0 AND (t.tgtype & 1) = 1 AND (t.tgtype & (8 | 16 | 32)) = 0)
    FROM pg_trigger t WHERE t.tgrelid = 'tiempo.movimiento_de_saldo'::regclass AND NOT t.tgisinternal AND t.tgname = 'trg_movimiento_de_saldo_actualiza_banco'$$);
SELECT pg_temp.verifica('A4 el trigger no se puede invocar a mano (nadie tiene EXECUTE; además RETURNS trigger)',
  $$SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon', 'authenticated', 'service_role']) r WHERE has_function_privilege(r, 'tiempo.fn_movimiento_de_saldo_actualiza_banco()', 'EXECUTE'))$$);

-- ============================================================================
-- B) Con permiso (admin real como caller y autor): los tres tipos
-- ============================================================================
-- Saldo inicial de BA como el batch (service_role, BYPASSRLS): +10 con creado_en fijo.
SELECT pg_temp.caso('B0 el batch (service_role) inserta generado_quincena +10', 'service_role',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'generado_quincena', 10, 'ens104', TIMESTAMPTZ '2026-01-15 10:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BA')), 'ok');
SELECT pg_temp.verifica('B0b monto = 10 y vivo_desde = el creado_en del movimiento, exactamente', $$SELECT pg_temp.monto('BA') = 10 AND pg_temp.vivo('BA') = TIMESTAMPTZ '2026-01-15 10:00:00+00'$$);
SELECT pg_temp.caso('B1 renovar antigüedad (arrastrar 4): par -4/+4', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'arrastrar', 4, 'ens104 renovar')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'ok');
SELECT pg_temp.verifica('B1b el total NO cambia (10), dos filas nuevas en el ledger y vivo_desde se conserva', $$SELECT pg_temp.monto('BA') = 10 AND pg_temp.suma('BA') = 10
  AND (SELECT count(*) FROM tiempo.movimiento_de_saldo WHERE banco_de_horas_id = (SELECT v::bigint FROM _ens WHERE k = 'BA') AND tipo = 'arrastrar') = 2
  AND pg_temp.vivo('BA') = TIMESTAMPTZ '2026-01-15 10:00:00+00'$$);
SELECT pg_temp.caso('B2 descontar 3', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 3, 'ens104 descontar')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'ok');
SELECT pg_temp.verifica('B2b monto = 7, ledger = 7, vivo_desde se conserva', $$SELECT pg_temp.monto('BA') = 7 AND pg_temp.suma('BA') = 7 AND pg_temp.vivo('BA') = TIMESTAMPTZ '2026-01-15 10:00:00+00'$$);
SELECT pg_temp.caso('B3 condonar 7 (llega a 0)', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'condonar', 7, 'ens104 condonar')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'ok');
SELECT pg_temp.verifica('B3b monto = 0, ledger = 0 y vivo_desde = NULL', $$SELECT pg_temp.monto('BA') = 0 AND pg_temp.suma('BA') = 0 AND pg_temp.vivo('BA') IS NULL$$);
SELECT pg_temp.caso('B4 renovar con el saldo EXACTO (arrastrar 5 sobre 5): el par -5/+5 pasa por 0 y reabre vivo_desde', 'service_role',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'generado_quincena', 5, 'ens104', TIMESTAMPTZ '2026-02-01 08:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BA')), 'ok');
SELECT pg_temp.verifica('B4b tras +5 desde 0: monto = 5 y vivo_desde = 2026-02-01', $$SELECT pg_temp.monto('BA') = 5 AND pg_temp.vivo('BA') = TIMESTAMPTZ '2026-02-01 08:00:00+00'$$);
SELECT pg_temp.caso('B4c arrastrar 5 sobre 5', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'arrastrar', 5, 'ens104 renovar total')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'ok');
SELECT pg_temp.verifica('B4d queda en 5 y vivo_desde se reabre en el creado_en del movimiento (now() de la transacción)', $$SELECT pg_temp.monto('BA') = 5 AND pg_temp.suma('BA') = 5 AND pg_temp.vivo('BA') IS NOT NULL AND pg_temp.vivo('BA') >= TIMESTAMPTZ '2026-02-01 08:00:00+00'$$);

-- ============================================================================
-- C) Camino del batch (service_role): sin cambio de comportamiento
-- ============================================================================
SELECT pg_temp.caso('C1 batch: +2', 'service_role', format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'generado_quincena', 2, 'ens104', TIMESTAMPTZ '2026-03-01 08:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BC')), 'ok');
SELECT pg_temp.caso('C2 batch: +3 (acumula)', 'service_role', format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'generado_quincena', 3, 'ens104', TIMESTAMPTZ '2026-03-02 08:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BC')), 'ok');
SELECT pg_temp.verifica('C3 monto = 5 = ledger, vivo_desde = el del primer movimiento (no se reabre), actualizado_en = el del último',
  $$SELECT pg_temp.monto('BC') = 5 AND pg_temp.suma('BC') = 5 AND pg_temp.vivo('BC') = TIMESTAMPTZ '2026-03-01 08:00:00+00'
    AND (SELECT actualizado_en FROM tiempo.banco_de_horas WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'BC')) = TIMESTAMPTZ '2026-03-02 08:00:00+00'$$);
SELECT pg_temp.caso('C4 batch: cubrir -5 llega a 0', 'service_role', format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'cubrir', -5, 'ens104', TIMESTAMPTZ '2026-03-03 08:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BC')), 'ok');
SELECT pg_temp.verifica('C4b monto = 0 y vivo_desde = NULL', $$SELECT pg_temp.monto('BC') = 0 AND pg_temp.vivo('BC') IS NULL$$);
SELECT pg_temp.caso('C5 batch: saldo a favor (-2 desde 0): monto = -2 y vivo_desde sigue NULL (no abre vigencia con saldo negativo)', 'service_role', format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, creado_en) VALUES (%s, 'cubrir', -2, 'ens104', TIMESTAMPTZ '2026-03-04 08:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BC')), 'ok');
SELECT pg_temp.verifica('C5b monto = -2 y vivo_desde = NULL', $$SELECT pg_temp.monto('BC') = -2 AND pg_temp.vivo('BC') IS NULL$$);

-- ============================================================================
-- D) Sin permiso: el INSERT falla y el banco no cambia
-- ============================================================================
SELECT pg_temp.caso('D1 usuario sin permisos: INSERT directo en movimiento_de_saldo => 42501 (RLS)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'descontar', -1, 'ens104 sin permiso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'P4')),
  '42501', (SELECT v FROM _ens WHERE k = 'auth_sin'));
SELECT pg_temp.caso('D2 usuario sin permisos: el RPC => 42501 (la autorización pasó al RPC DEFINER)', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 sin permiso')$f$, (SELECT v FROM _ens WHERE k = 'P2')), '42501', (SELECT v FROM _ens WHERE k = 'auth_sin'));
SELECT pg_temp.caso('D3 con permiso, INSERT directo con autor_id de OTRA persona (suplantación) => 42501 (sin privilegio INSERT)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'descontar', -1, 'ens104 suplanta', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'P4')), '42501');
SELECT pg_temp.verifica('D4 el banco BA no cambió por los intentos fallidos', $$SELECT pg_temp.monto('BA') = 5 AND pg_temp.suma('BA') = 5$$);
SELECT pg_temp.caso('D5 tipo no permitido por la vía manual (generado_quincena como authenticated) => 42501 (policy)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'generado_quincena', 1, 'ens104', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');

-- ---- D6–D12: la vía directa está CERRADA para quien TIENE el permiso (admin): cada forma de abuso => 42501 (sin privilegio) y el banco no cambia ----
SELECT pg_temp.caso('D6 INSERT directo con permiso: monto POSITIVO (aumentar deuda)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'descontar', 5, 'ens104 abuso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.caso('D7 INSERT directo con permiso: monto NEGATIVO mayor que la deuda', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'condonar', -50, 'ens104 abuso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.caso('D8 INSERT directo con permiso: monto 0', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'descontar', 0, 'ens104 abuso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.caso('D9 INSERT directo con permiso: UNA sola fila arrastrar con +X sin su par', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'arrastrar', 3, 'ens104 abuso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.caso('D10 INSERT directo con permiso: creado_en en el pasado (distorsionaría vivo_desde y el FIFO)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id, creado_en) VALUES (%s, 'descontar', -1, 'ens104 abuso', %L::uuid, TIMESTAMPTZ '2020-01-01 00:00:00+00')$f$, (SELECT v FROM _ens WHERE k = 'BA'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.caso('D11 INSERT directo con permiso: banco AJENO (BC)', 'authenticated',
  format($f$INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id) VALUES (%s, 'descontar', -1, 'ens104 abuso', %L::uuid)$f$, (SELECT v FROM _ens WHERE k = 'BC'), (SELECT v FROM _ens WHERE k = 'persona_admin')), '42501');
SELECT pg_temp.verifica('D12 ningún abuso movió nada: BA = 5 = ledger y BC = -2 = ledger', $$SELECT pg_temp.monto('BA') = 5 AND pg_temp.suma('BA') = 5 AND pg_temp.monto('BC') = -2 AND pg_temp.suma('BC') = -2$$);
-- ---- D13–D16: autorización dentro del RPC ----
SELECT pg_temp.caso('D13 persona SUSPENDIDA (con el permiso de edición por su puesto): el RPC => 42501', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 suspendida')$f$, (SELECT v FROM _ens WHERE k = 'P2')), '42501', (SELECT v FROM _ens WHERE k = 'auth_susp'));
SELECT pg_temp.caso('D14 usuario con OTRO permiso (banco_de_horas_lectura) pero SIN movimiento_de_saldo_edicion: el RPC => 42501', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 solo lectura')$f$, (SELECT v FROM _ens WHERE k = 'P2')), '42501', (SELECT v FROM _ens WHERE k = 'auth_lec'));
SELECT pg_temp.caso('D15 anon: sin EXECUTE del RPC => 42501', 'anon',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 anon')$f$, (SELECT v FROM _ens WHERE k = 'P2')), '42501');
SELECT pg_temp.verifica('D16 el banco BA sigue en 5 tras los rechazos del RPC', $$SELECT pg_temp.monto('BA') = 5 AND pg_temp.suma('BA') = 5$$);
-- ---- D17: un usuario NO administrador con movimiento_de_saldo_edicion (P7, activo): funciona, y el autor es él (fn_caller_* siguen leyendo los claims dentro de DEFINER) ----
SELECT pg_temp.caso('D17 persona ACTIVA con movimiento_de_saldo_edicion (no admin) descuenta 1 => ok', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 edicion')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_edi'));
SELECT pg_temp.verifica('D17b BA = 4 = ledger y el autor del movimiento es P7 (sale de auth.uid(), no del cliente) y creado_en lo fijó el servidor',
  $$SELECT pg_temp.monto('BA') = 4 AND pg_temp.suma('BA') = 4
    AND (SELECT autor_id FROM tiempo.movimiento_de_saldo WHERE motivo = 'ens104 edicion') = (SELECT v::uuid FROM _ens WHERE k = 'P7')
    AND (SELECT creado_en FROM tiempo.movimiento_de_saldo WHERE motivo = 'ens104 edicion') = now()$$);
SELECT pg_temp.caso('D18 el RPC con monto mayor que el saldo => SCJ04 (validaciones intactas)', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 99, 'ens104 excede')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'SCJ04');
SELECT pg_temp.caso('D19 el RPC con tipo no permitido (cubrir) => SCJ01', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'cubrir', 1, 'ens104 tipo')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'SCJ01');
SELECT pg_temp.caso('D20 el RPC con monto 0 => SCJ02', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 0, 'ens104 cero')$f$, (SELECT v FROM _ens WHERE k = 'P2')), 'SCJ02');
SELECT pg_temp.caso('D21 el RPC sobre persona sin banco => SCJ03', 'authenticated',
  format($f$SELECT * FROM tiempo.fn_movimiento_de_saldo_manual_registrar(%L::uuid, 'descontar', 1, 'ens104 sin banco')$f$, (SELECT v FROM _ens WHERE k = 'P7')), 'SCJ03');

-- ============================================================================
-- E) Propiedades estáticas del cuerpo y de la superficie (policy, grants, RPC)
-- ============================================================================
SELECT pg_temp.verifica('E1 el cuerpo tiene exactamente UNA sentencia UPDATE sobre banco_de_horas y ningún SELECT del monto',
  $$SELECT (length(p.prosrc) - length(replace(p.prosrc, 'UPDATE tiempo.banco_de_horas', ''))) / length('UPDATE tiempo.banco_de_horas') = 1 AND p.prosrc !~* 'select\s+monto'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_actualiza_banco'$$);
SELECT pg_temp.verifica('E2 la rama IF NOT FOUND levanta SCJ18 con HINT banco_inexistente y mensaje sin identidad',
  $$SELECT p.prosrc LIKE '%IF NOT FOUND%' AND p.prosrc LIKE '%SCJ18%' AND p.prosrc LIKE '%banco_inexistente%' AND (regexp_match(p.prosrc, 'RAISE EXCEPTION([^;]*?)USING'))[1] !~ 'NEW\.|banco_de_horas_id'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_actualiza_banco'$$);
SELECT pg_temp.verifica('E3 SCJ18 no se usaba antes en ninguna otra función de tiempo/personas (código nuevo libre)',
  $$SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('tiempo', 'personas') AND p.prosrc LIKE '%SCJ18%') = 1$$);
-- El invariante en las filas sintéticas: todo banco creado aquí cuadra con su ledger (la sección 68 del verificador lo comprueba en toda la base).
SELECT pg_temp.verifica('E5 la policy de INSERT ya no existe y authenticated no tiene INSERT (ni de columna) sobre movimiento_de_saldo; service_role conserva INSERT; la policy de SELECT sigue',
  $$SELECT NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'movimiento_de_saldo' AND (cmd IN ('INSERT', 'ALL') OR policyname = 'movimiento_de_saldo_insert_manual'))
    AND NOT has_any_column_privilege('authenticated', 'tiempo.movimiento_de_saldo', 'INSERT') AND has_table_privilege('service_role', 'tiempo.movimiento_de_saldo', 'INSERT')
    AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'movimiento_de_saldo' AND policyname = 'movimiento_de_saldo_select_requiere_permiso')$$);
SELECT pg_temp.verifica('E6 el RPC: SECURITY DEFINER, search_path = tiempo, personas, pg_temp, dueño postgres, ACL {postgres, authenticated} (sin PUBLIC, anon ni service_role)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres'
    AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_manual_registrar'$$);
SELECT pg_temp.verifica('E7 el RPC autoriza al principio y no acepta creado_en ni autor del cliente',
  $$SELECT position('fn_caller_tiene_permiso(''movimiento_de_saldo_edicion'')' IN p.prosrc) > 0 AND position('fn_caller_tiene_permiso' IN p.prosrc) < position('INSERT INTO' IN p.prosrc)
    AND p.prosrc NOT LIKE '%creado_en%' AND p.prosrc LIKE '%auth.uid()%' AND p.prosrc LIKE '%FOR UPDATE%'
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_movimiento_de_saldo_manual_registrar'$$);
SELECT pg_temp.verifica('E4 invariante banco = ledger en los 3 bancos sintéticos que recibieron movimientos de 104_ (BA, BC) y BB queda desalineado SOLO si el defecto vigente existía antes',
  $$SELECT pg_temp.monto('BA') = pg_temp.suma('BA') AND pg_temp.monto('BC') = pg_temp.suma('BC')$$);

-- ============================================================================
-- F) verificar_ddl.sql completo (secciones 68 y 69 en 0 filas; BB, desalineado por el defecto previo, se corrige/explica abajo)
-- ============================================================================
-- BB fue desalineado A PROPÓSITO antes de aplicar 104_ (A0); se elimina del ledger y del banco dentro de la transacción para que la sección 68 mida solo el comportamiento posterior.
DELETE FROM tiempo.movimiento_de_saldo WHERE banco_de_horas_id = (SELECT v::bigint FROM _ens WHERE k = 'BB');
UPDATE tiempo.banco_de_horas SET monto = 0, vivo_desde = NULL WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'BB');
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
