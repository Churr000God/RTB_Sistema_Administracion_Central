-- Ensayo de 82_*, 83_* y 84_* (SCJ-DEC-12) + regresión de los 61 casos de 80_/81_ tras el CREATE OR
-- REPLACE de fn_bitacora_terminal_usuario_aplica. NO es DDL versionado. NO correr sin OK de
-- orchestrator/usuario ni antes de la revisión de security.
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <este archivo>      (SIN -1: el BEGIN/ROLLBACK ya está en el script)
-- E2 (security): conexión DIRECTA o SESSION POOLER (puerto 5432), NUNCA el transaction pooler (6543): el ensayo
-- usa SET LOCAL, advisory locks y una transacción larga, que ese pooler no soporta de forma fiable.
-- Todo dentro de una transacción real que termina en ROLLBACK (Prefer: tx=rollback no sirve acá).
-- 80_ y 81_ YA están aplicados en la base real: este ensayo aplica 82, 83 y 84 ENCIMA y corre los 61
-- casos de 80_/81_ (con 89-91 adaptados al trigger SCJ13) más los casos nuevos.
-- Requisitos: existe un usuario activo asignado hoy al puesto es_administrador_generico (el usuario
-- base de bootstrap) y no hay altas reales en tiempo.terminal_usuario (varios casos cuentan filas y
-- esperan employee_no = 1 y 2).
-- Las secuencias no son transaccionales: para no quemar números reales de employee_no, el ensayo
-- hace ALTER SEQUENCE ... RESTART al inicio (transaccional: el ROLLBACK restaura la secuencia real).
-- Si en una corrida real el RESTART resultara no transaccional, sólo reinicia en 1 una secuencia que
-- aún no se usó (el DO de abajo lo omite si ya hay altas).
\set ON_ERROR_STOP on
BEGIN;
-- E1 (security): topes para que un bloqueo o un error no deje la transacción abierta ni cuelgue la base.
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
DO $b$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM tiempo.terminal_usuario) THEN
    EXECUTE 'ALTER SEQUENCE tiempo.seq_terminal_employee_no RESTART WITH 1';
  END IF;
END $b$;
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/82_tiempo_terminal_credencial_y_estado.sql
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/83_tiempo_terminal_rpc.sql
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/84_tiempo_marca_rechazada.sql

-- ---------- fixtures y helpers (como dueño) ----------
CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_uid', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p   ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'persona_id', u.persona_id::text
FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_uid');
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'persona_id' ON CONFLICT DO NOTHING;
INSERT INTO tiempo.persona (id) VALUES ('00000000-0000-0000-0000-00000000dead') ON CONFLICT DO NOTHING;
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-001', 'Terminal de ensayo', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-001';

-- Ejecuta p_sql con el rol/claims dados. p_esperado: 'ok' | 'error' (cualquiera) | SQLSTATE exacto.
-- p_hint (opcional): token estable esperado en el HINT de la excepción.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text,
                             p_sub text DEFAULT NULL, p_hint text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', COALESCE(p_sub, (SELECT v FROM _ens WHERE k='auth_uid')), 'role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;
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

-- Atajos de movimientos
CREATE FUNCTION pg_temp.mov(p_tipo text, p_extra text DEFAULT '') RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por %s)
    SELECT tu.id, tu.terminal_id, tu.persona_id, %L,
           CASE WHEN %L IN ('asignado','baja_solicitada') THEN 'web' ELSE 'terminal' END,
           CASE WHEN %L IN ('asignado','baja_solicitada') THEN %L::uuid END %s
    FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = %L::uuid AND tu.estado <> 'baja'
    ORDER BY tu.id DESC LIMIT 1$f$,
    CASE WHEN p_extra <> '' THEN ', ' || split_part(p_extra, '|', 1) ELSE '' END,
    p_tipo, p_tipo, p_tipo, (SELECT v FROM _ens WHERE k='auth_uid'),
    CASE WHEN p_extra <> '' THEN ', ' || split_part(p_extra, '|', 2) ELSE '' END,
    (SELECT v FROM _ens WHERE k='persona_id'));
$$ LANGUAGE sql;

CREATE FUNCTION pg_temp.asignar(p_persona text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid)$f$,
    (SELECT v FROM _ens WHERE k='terminal'), p_persona, (SELECT v FROM _ens WHERE k='auth_uid'));
$$ LANGUAGE sql;

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid')$$);
SELECT pg_temp.verifica('01 permisos otorgados: 3 puestos x 2 (incl. admin)',
  $$SELECT count(*) = 6 FROM personas.puesto_permiso pp WHERE pp.activo AND pp.codigo IN ('terminal_usuario_lectura','terminal_usuario_edicion')$$);

-- Asignar
SELECT pg_temp.caso('10 asignado (edicion) ok', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='persona_id')), 'ok');
SELECT pg_temp.verifica('11 fila viva pendiente_alta, employee_no=1',
  $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE estado='pendiente_alta' AND employee_no = 1$$);
SELECT pg_temp.verifica('12 bitácora llenó terminal_usuario_id y employee_no',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento='asignado' AND terminal_usuario_id IS NOT NULL AND employee_no = 1$$);
SELECT pg_temp.caso('13 segundo asignado misma persona/terminal -> SCJ12 alta_duplicada', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='persona_id')), 'SCJ12', NULL, 'alta_duplicada');
SELECT pg_temp.caso('14 asignado persona inexistente/inactiva -> SCJ12 persona_no_activa', 'authenticated', pg_temp.asignar('00000000-0000-0000-0000-00000000dead'), 'SCJ12', NULL, 'persona_no_activa');
SELECT pg_temp.caso('15 asignado con terminal inexistente -> SCJ12 terminal_no_valida', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (999999999, %L::uuid, 'asignado', 'web', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='persona_id'), (SELECT v FROM _ens WHERE k='auth_uid')),
  'SCJ12', NULL, 'terminal_no_valida');
-- Terminal inactiva (fixture como dueño: insertada ya inactiva)
INSERT INTO tiempo.terminal (terminal_id, nombre, activa) VALUES ('ENSAYO-INACT', 'Terminal inactiva de ensayo', false);
INSERT INTO _ens SELECT 'terminal_inactiva', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-INACT';
SELECT pg_temp.caso('16 asignado con terminal inactiva -> SCJ12 terminal_no_valida', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='terminal_inactiva'), (SELECT v FROM _ens WHERE k='persona_id'), (SELECT v FROM _ens WHERE k='auth_uid')),
  'SCJ12', NULL, 'terminal_no_valida');
SELECT pg_temp.verifica('17 los asignados rechazados no quemaron employee_no (la siguiente alta será 2, no mayor)',
  $$SELECT count(*) = 1 AND max(employee_no) = 1 FROM tiempo.terminal_usuario$$);
-- Respaldo del índice único parcial (la carrera real de 2 sesiones concurrentes no se puede
-- simular en un solo script; esto prueba que el índice existe y dispara): como dueño, un 2º alta
-- vigente directo en la tabla viva.
SELECT pg_temp.caso('18 índice único parcial: 2ª alta vigente misma persona/terminal -> 23505', current_user::text,
  format($f$INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado) VALUES (%L::bigint, %L::uuid, 888, 'pendiente_alta')$f$,
         (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='persona_id')), '23505');

-- Cadena completa
SELECT pg_temp.caso('20 usuario_creado (service_role)', 'service_role', pg_temp.mov('usuario_creado'), 'ok');
SELECT pg_temp.caso('21 huella_capturada 2 (service_role)', 'service_role', pg_temp.mov('huella_capturada', 'huellas_capturadas|2'), 'ok');
SELECT pg_temp.verifica('22 estado activo, huellas=2', $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE estado='activo' AND huellas_capturadas = 2$$);
SELECT pg_temp.caso('23 error (service_role) no cambia estado', 'service_role', pg_temp.mov('error', 'detalle|''lector ocupado'''), 'ok');
SELECT pg_temp.verifica('24 error_detalle lleno y estado activo', $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE estado='activo' AND error_detalle = 'lector ocupado'$$);
SELECT pg_temp.caso('25 baja_confirmada desde activo -> SCJ11', 'service_role', pg_temp.mov('baja_confirmada'), 'SCJ11');
SELECT pg_temp.caso('26 baja_solicitada (edicion, web) ok', 'authenticated', pg_temp.mov('baja_solicitada'), 'ok');
SELECT pg_temp.caso('27 segunda baja_solicitada -> SCJ11', 'authenticated', pg_temp.mov('baja_solicitada'), 'SCJ11');
SELECT pg_temp.caso('28 baja_confirmada ok', 'service_role', pg_temp.mov('baja_confirmada'), 'ok');
SELECT pg_temp.verifica('29 fila viva en baja, huellas=2, error limpio',
  $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE estado='baja' AND huellas_capturadas = 2 AND error_detalle IS NULL$$);
SELECT pg_temp.caso('30 error sobre alta en baja -> SCJ11', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, detalle)
            SELECT id, terminal_id, persona_id, 'error', 'terminal', 'x' FROM tiempo.terminal_usuario WHERE estado='baja' LIMIT 1$f$), 'SCJ11');
SELECT pg_temp.caso('31 re-asignar tras baja ok (nuevo employee_no=2)', 'authenticated', pg_temp.asignar((SELECT v FROM _ens WHERE k='persona_id')), 'ok');
SELECT pg_temp.verifica('32 employee_no nunca reutilizado', $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE estado='pendiente_alta' AND employee_no = 2$$);

-- Inmutabilidad
SELECT pg_temp.caso('40 UPDATE bitácora como service_role falla', 'service_role', $$UPDATE tiempo.bitacora_movimiento_terminal_usuario SET detalle='x'$$, 'error');
SELECT pg_temp.caso('41 DELETE bitácora como service_role falla', 'service_role', $$DELETE FROM tiempo.bitacora_movimiento_terminal_usuario$$, 'error');
SELECT pg_temp.caso('42 TRUNCATE bitácora como service_role falla', 'service_role', $$TRUNCATE tiempo.bitacora_movimiento_terminal_usuario$$, '42501');
SELECT pg_temp.caso('43 UPDATE bitácora como dueño aborta por trigger', current_user::text, $$UPDATE tiempo.bitacora_movimiento_terminal_usuario SET detalle='x'$$, 'P0001');
SELECT pg_temp.caso('44 DELETE bitácora como dueño aborta por trigger', current_user::text, $$DELETE FROM tiempo.bitacora_movimiento_terminal_usuario$$, 'P0001');

-- Tabla viva y terminal: sin escritura directa
SELECT pg_temp.caso('50 authenticated INSERT directo terminal_usuario falla', 'authenticated', format($f$INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado) VALUES (%L::bigint, %L::uuid, 777, 'activo')$f$, (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='persona_id')), '42501');
SELECT pg_temp.caso('51 authenticated UPDATE directo terminal_usuario falla', 'authenticated', $$UPDATE tiempo.terminal_usuario SET estado='activo'$$, '42501');
SELECT pg_temp.caso('52 service_role UPDATE directo terminal_usuario falla', 'service_role', $$UPDATE tiempo.terminal_usuario SET estado='activo'$$, '42501');
SELECT pg_temp.caso('53 authenticated INSERT en terminal falla', 'authenticated', $$INSERT INTO tiempo.terminal (terminal_id, nombre) VALUES ('X','x')$$, '42501');
SELECT pg_temp.caso('54 service_role DELETE terminal falla', 'service_role', $$DELETE FROM tiempo.terminal$$, '42501');
SELECT pg_temp.caso('55 service_role UPDATE ultimo_contacto_en ok', 'service_role', $$UPDATE tiempo.terminal SET ultimo_contacto_en = now()$$, 'ok');
SELECT pg_temp.caso('56 nextval de la secuencia como authenticated falla', 'authenticated', $$SELECT nextval('tiempo.seq_terminal_employee_no')$$, '42501');

-- Lectura
SELECT pg_temp.caso('60 anon SELECT terminal', 'anon', $$SELECT 1 FROM tiempo.terminal LIMIT 1$$, '42501');
SELECT pg_temp.caso('61 anon SELECT terminal_usuario', 'anon', $$SELECT 1 FROM tiempo.terminal_usuario LIMIT 1$$, '42501');
SELECT pg_temp.caso('62 anon SELECT bitácora', 'anon', $$SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario LIMIT 1$$, '42501');
SELECT pg_temp.caso('63 authenticated sin usuario/permiso ve 0 filas (RLS)', 'authenticated',
  $q$DO $b$ BEGIN IF (SELECT count(*) FROM tiempo.terminal_usuario) <> 0 THEN RAISE EXCEPTION 'vio filas' USING ERRCODE='XX999'; END IF; END $b$$q$,
  'ok', '11111111-1111-1111-1111-111111111111');
SELECT pg_temp.caso('64 authenticated con permiso ve la fila', 'authenticated',
  $q$DO $b$ BEGIN IF (SELECT count(*) FROM tiempo.terminal_usuario) = 0 THEN RAISE EXCEPTION 'no vio filas' USING ERRCODE='XX999'; END IF; END $b$$q$, 'ok');

-- Bitácora: INSERT humano
SELECT pg_temp.caso('70 authenticated insertando origen=terminal (usuario_creado) falla por RLS', 'authenticated', pg_temp.mov('usuario_creado'), '42501');
SELECT pg_temp.caso('71 registrado_por ajeno falla por RLS (baja_solicitada válida de estado, así el trigger no corta antes)', 'authenticated',
  replace(pg_temp.mov('baja_solicitada'), (SELECT v FROM _ens WHERE k='auth_uid'), '22222222-2222-2222-2222-222222222222'), '42501');
-- El id de la fila viva se resuelve acá (como dueño) porque el caller sin permiso no la vería por RLS.
SELECT pg_temp.caso('72 caller sin usuario/permiso no puede insertar baja_solicitada', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (%L::bigint, %L::bigint, %L::uuid, 'baja_solicitada', 'web', '11111111-1111-1111-1111-111111111111')$f$,
         (SELECT id FROM tiempo.terminal_usuario WHERE estado = 'pendiente_alta' LIMIT 1),
         (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='persona_id')),
  '42501', '11111111-1111-1111-1111-111111111111');
-- Fixture como dueño: alta ajena ('activo') para probar los CHECK de la bitácora sin que el
-- trigger BEFORE corte antes (los CHECK se evalúan DESPUÉS de los triggers BEFORE).
INSERT INTO tiempo.persona (id) VALUES ('00000000-0000-0000-0000-00000000beef') ON CONFLICT DO NOTHING;
INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado)
  SELECT v::bigint, '00000000-0000-0000-0000-00000000beef', 900, 'activo' FROM _ens WHERE k = 'terminal';
SELECT pg_temp.caso('73 huella_capturada sin conteo falla (NOT NULL de la fila viva o CHECK de la bitácora)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen)
            SELECT id, terminal_id, persona_id, 'huella_capturada', 'terminal' FROM tiempo.terminal_usuario WHERE employee_no = 900$f$), 'error');
SELECT pg_temp.caso('73b huella_capturada con 11 huellas falla (CHECK 23514)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, huellas_capturadas)
            SELECT id, terminal_id, persona_id, 'huella_capturada', 'terminal', 11 FROM tiempo.terminal_usuario WHERE employee_no = 900$f$), '23514');
SELECT pg_temp.caso('73c huella_capturada con 0 huellas falla (CHECK de la bitácora 23514)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, huellas_capturadas)
            SELECT id, terminal_id, persona_id, 'huella_capturada', 'terminal', 0 FROM tiempo.terminal_usuario WHERE employee_no = 900$f$), '23514');
SELECT pg_temp.caso('74 CHECK: error sin detalle falla', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen)
            SELECT id, terminal_id, persona_id, 'error', 'terminal' FROM tiempo.terminal_usuario WHERE estado='pendiente_alta' LIMIT 1$f$), '23514');
SELECT pg_temp.caso('75 CHECK: origen web sin autor falla (baja_solicitada válida de estado sobre la alta ajena)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen)
            SELECT id, terminal_id, persona_id, 'baja_solicitada', 'web' FROM tiempo.terminal_usuario WHERE employee_no = 900$f$), '23514');

-- ---------- casos de security (revisión 2026-10-05) ----------
SELECT pg_temp.caso('80 TRUNCATE bitácora como dueño aborta por trigger de statement', current_user::text,
  $$TRUNCATE tiempo.bitacora_movimiento_terminal_usuario$$, 'P0001');
SELECT pg_temp.caso('81 service_role INSERT en terminal funciona con la secuencia identity revocada', 'service_role',
  $$INSERT INTO tiempo.terminal (terminal_id, nombre) VALUES ('ENSAYO-002', 'Otra terminal de ensayo')$$, 'ok');
SELECT pg_temp.caso('82 service_role UPDATE de columna no permitida (terminal_id) falla', 'service_role',
  $$UPDATE tiempo.terminal SET terminal_id = 'CAMBIADA' WHERE terminal_id = 'ENSAYO-002'$$, '42501');
SELECT pg_temp.caso('83 service_role UPDATE de columna permitida (ultimo_contacto_en) ok', 'service_role',
  $$UPDATE tiempo.terminal SET ultimo_contacto_en = now() WHERE terminal_id = 'ENSAYO-002'$$, 'ok');

SELECT pg_temp.caso('84 baja_solicitada con terminal_usuario_id de otra persona -> SCJ11', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (%L::bigint, %L::bigint, %L::uuid, 'baja_solicitada', 'web', %L::uuid)$f$,
         (SELECT id FROM tiempo.terminal_usuario WHERE employee_no = 900),
         (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='persona_id'), (SELECT v FROM _ens WHERE k='auth_uid')),
  'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.verifica('85 la alta ajena quedó intacta (sigue activo)', $$SELECT count(*) = 1 FROM tiempo.terminal_usuario WHERE employee_no = 900 AND estado = 'activo'$$);

-- Largo de texto libre
SELECT pg_temp.caso('86 detalle de 501 caracteres falla (CHECK)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, detalle)
            SELECT id, terminal_id, persona_id, 'error', 'terminal', repeat('x', 501) FROM tiempo.terminal_usuario WHERE estado = 'pendiente_alta' LIMIT 1$f$), '23514');
SELECT pg_temp.caso('87 detalle de 500 caracteres ok', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, detalle)
            SELECT id, terminal_id, persona_id, 'error', 'terminal', repeat('x', 500) FROM tiempo.terminal_usuario WHERE estado = 'pendiente_alta' LIMIT 1$f$), 'ok');
SELECT pg_temp.caso('88 error_detalle de 501 caracteres en la tabla viva falla (CHECK, como dueño)', current_user::text,
  $$UPDATE tiempo.terminal_usuario SET error_detalle = repeat('x', 501) WHERE employee_no = 900$$, '23514');

-- terminal.activa sólo se exige en 'asignado', no en baja_solicitada
-- 89-91 adaptados al trigger SCJ13 (SCJ-DEC-12 §6): antes de 83_ se podía desactivar una terminal con
-- altas; ahora no.
SELECT pg_temp.caso('89 service_role desactiva una terminal CON altas vigentes -> SCJ13', 'service_role',
  format($f$UPDATE tiempo.terminal SET activa = false WHERE id = %L::bigint$f$, (SELECT v FROM _ens WHERE k='terminal')),
  'SCJ13', NULL, 'terminal_con_altas_vigentes');
SELECT pg_temp.caso('90 asignado con terminal inactiva -> SCJ12 terminal_no_valida', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            VALUES (%L::bigint, '00000000-0000-0000-0000-00000000dead'::uuid, 'asignado', 'web', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k='terminal_inactiva'), (SELECT v FROM _ens WHERE k='auth_uid')),
  'SCJ12', NULL, 'terminal_no_valida');
-- Fixture como dueño: una alta 'activo' en la terminal inactiva (el trigger SCJ13 sólo vigila el UPDATE de activa).
INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado)
  SELECT v::bigint, '00000000-0000-0000-0000-00000000beef', 901, 'activo' FROM _ens WHERE k = 'terminal_inactiva';
SELECT pg_temp.caso('91 baja_solicitada sobre una alta de terminal inactiva sigue funcionando', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
            SELECT id, terminal_id, persona_id, 'baja_solicitada', 'web', %L::uuid FROM tiempo.terminal_usuario WHERE employee_no = 901$f$,
         (SELECT v FROM _ens WHERE k='auth_uid')), 'ok');


-- =====================================================================================================
-- CASOS NUEVOS (SCJ-DEC-12): fixtures, helpers y RPC. Numeración 100+.
-- =====================================================================================================
INSERT INTO tiempo.persona (id) VALUES
  ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002')
ON CONFLICT DO NOTHING;
INSERT INTO tiempo.terminal (terminal_id, nombre) VALUES
  ('ENSAYO-RPC', 'RPC 1'), ('ENSAYO-RPC2', 'RPC 2'), ('ENSAYO-TOPE', 'Tope'),
  ('ENSAYO-BAJA', 'Sólo bajas'), ('ENSAYO-VACIA', 'Sin altas');
INSERT INTO _ens SELECT 'rpc1',  id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC';
INSERT INTO _ens SELECT 'rpc2',  id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC2';
INSERT INTO _ens SELECT 'tope',  id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-TOPE';
INSERT INTO _ens SELECT 'baja',  id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-BAJA';
INSERT INTO _ens SELECT 'vacia', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-VACIA';
INSERT INTO _ens VALUES ('m0', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

-- E3 (security): persona SINTÉTICA de ensayo (S), creada dentro de la transacción, para los casos de baja por
-- persona inactiva (210-215). El usuario base real (P) NO se suspende nunca; sólo actúa como caller.
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXS1', 'XEXX010101S1', '99999999991', 'Sintetica', 'Ensayo', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'persona_s', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXS1';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'persona_s' ON CONFLICT DO NOTHING;

-- Altas de fixture (como dueño: la tabla viva sólo la escribe el trigger de la bitácora para la API).
-- P = persona real del bootstrap, B = beef, S = sintética, D1/D2 = personas sólo de tiempo (no existen en
-- personas). creado_en/actualizado_en explícitos: las altas son "viejas" (30 días) para que las marcas con
-- momento antiguo de los casos de reloj no caigan en la regla M1; la alta 14 se dio de baja "ahora" y la 16
-- hace 3 horas (casos M1).
INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado, huellas_capturadas, creado_en, actualizado_en)
SELECT t.id, x.persona, x.emp, x.estado, x.h, x.creada, x.actualizada
FROM (VALUES
  ('ENSAYO-RPC',   (SELECT v::uuid FROM _ens WHERE k = 'persona_id'),   11, 'activo',           1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC',   '00000000-0000-0000-0000-00000000beef'::uuid,        12, 'esperando_huella', 0, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC',   '00000000-0000-0000-0000-000000000001'::uuid,        13, 'pendiente_baja',   1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC',   '00000000-0000-0000-0000-00000000beef'::uuid,        14, 'baja',             1, now() - interval '30 days', now()),
  ('ENSAYO-RPC',   '00000000-0000-0000-0000-000000000002'::uuid,        15, 'pendiente_alta',   0, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC',   '00000000-0000-0000-0000-00000000beef'::uuid,        16, 'baja',             1, now() - interval '30 days', now() - interval '3 hours'),
  ('ENSAYO-RPC',   (SELECT v::uuid FROM _ens WHERE k = 'persona_s'),    17, 'activo',           1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC2',  (SELECT v::uuid FROM _ens WHERE k = 'persona_id'),   21, 'activo',           1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-RPC2',  (SELECT v::uuid FROM _ens WHERE k = 'persona_s'),    22, 'activo',           1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-TOPE',  (SELECT v::uuid FROM _ens WHERE k = 'persona_id'),   31, 'activo',           1, now() - interval '30 days', now() - interval '30 days'),
  ('ENSAYO-BAJA',  '00000000-0000-0000-0000-00000000beef'::uuid,        41, 'baja',             1, now() - interval '30 days', now() - interval '30 days')
) AS x(serie, persona, emp, estado, h, creada, actualizada)
JOIN tiempo.terminal t ON t.terminal_id = x.serie;
INSERT INTO _ens SELECT 'tu11', id::text FROM tiempo.terminal_usuario WHERE employee_no = 11 AND terminal_id = (SELECT v::bigint FROM _ens WHERE k='rpc1');
INSERT INTO _ens SELECT 'tu12', id::text FROM tiempo.terminal_usuario WHERE employee_no = 12 AND terminal_id = (SELECT v::bigint FROM _ens WHERE k='rpc1');
INSERT INTO _ens SELECT 'tu13', id::text FROM tiempo.terminal_usuario WHERE employee_no = 13 AND terminal_id = (SELECT v::bigint FROM _ens WHERE k='rpc1');
INSERT INTO _ens SELECT 'tu21', id::text FROM tiempo.terminal_usuario WHERE employee_no = 21 AND terminal_id = (SELECT v::bigint FROM _ens WHERE k='rpc2');

-- ---------- helpers de los RPC ----------
-- Evento válido de la terminal (jsonb). p_extra pisa/añade claves. momento = m0 por defecto.
CREATE FUNCTION pg_temp.ev(p_emp integer, p_seq bigint, p_extra jsonb DEFAULT '{}') RETURNS jsonb AS $$
  SELECT jsonb_build_object('evento_id', gen_random_uuid(), 'employee_no', p_emp, 'secuencia_local', p_seq,
    'momento_dispositivo', (SELECT v FROM _ens WHERE k = 'm0'), 'desfase_local', '-06:00',
    'estado_reloj', 'sincronizado', 'version_software', '1.0.0') || p_extra;
$$ LANGUAGE sql;

-- Momento ISO en UTC desplazado respecto de ahora (ej. '6 minutes', '-8 days').
CREATE FUNCTION pg_temp.ahora_mas(p_int text) RETURNS text AS $$
  SELECT to_char((now() + p_int::interval) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$ LANGUAGE sql;

-- SQL de la llamada al RPC de marcas (el literal se arma como dueño; el rol sólo ejecuta el texto).
CREATE FUNCTION pg_temp.lote(p_tid text, p_eventos jsonb) RETURNS text AS $$
  SELECT format('tiempo.fn_marca_terminal_registrar(%s::bigint, %L::jsonb)', p_tid, p_eventos::text);
$$ LANGUAGE sql;

-- Llama una función que devuelve jsonb como p_rol y evalúa p_check (expresión sobre $1 = el resultado).
CREATE FUNCTION pg_temp.rpc(p_caso text, p_rol text, p_llamada text, p_check text) RETURNS void AS $$
DECLARE v jsonb; v_ok boolean := false; v_det text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  BEGIN
    EXECUTE 'SELECT ' || p_llamada INTO v;
  EXCEPTION WHEN OTHERS THEN
    v_det := 'EXC ' || SQLSTATE || ' ' || left(SQLERRM, 100); v := NULL;
  END;
  RESET ROLE;
  IF v_det = '' THEN
    EXECUTE 'SELECT COALESCE(' || p_check || ', false)' INTO v_ok USING v;
  END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_ok, v_det || ' ' || left(COALESCE(v::text, 'null'), 300));
END;
$$ LANGUAGE plpgsql;

-- ---------- fn_marca_terminal_registrar: cada código de SCJ-CDT-01 §IX.6 ----------
INSERT INTO _ens VALUES ('ev100', pg_temp.ev(11, 1, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000001"}')::text);

SELECT pg_temp.rpc('100 marcas: evento válido -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array((SELECT v::jsonb FROM _ens WHERE k='ev100'))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' AND $1->'resultados'->0->>'evento_id' = '11111111-aaaa-4aaa-8aaa-000000000001'
      AND ($1->>'momento_recepcion') IS NOT NULL AND jsonb_array_length($1->'resultados') = 1 $c$);
SELECT pg_temp.verifica('101 la marca quedó con origen terminal, serie de la terminal y persona resuelta',
  $$SELECT count(*) = 1 FROM tiempo.marca m
    WHERE m.evento_id = '11111111-aaaa-4aaa-8aaa-000000000001' AND m.origen = 'terminal'
      AND m.terminal_id = 'ENSAYO-RPC' AND m.secuencia_local = 1
      AND m.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_id')$$);
SELECT pg_temp.rpc('102 marcas: reintento idéntico -> duplicado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array((SELECT v::jsonb FROM _ens WHERE k='ev100'))),
  $c$ $1->'resultados'->0->>'estado' = 'duplicado' AND ($1->'resultados'->0->'codigo') IS NULL $c$);
SELECT pg_temp.verifica('102b el duplicado no insertó una segunda marca',
  $$SELECT count(*) = 1 FROM tiempo.marca WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000001'$$);
SELECT pg_temp.rpc('103 marcas: mismo evento_id con otro momento -> conflicto_evento', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    (SELECT v::jsonb FROM _ens WHERE k='ev100') || jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('-1 hour')))),
  $c$ $1->'resultados'->0->>'estado' = 'rechazo_definitivo' AND $1->'resultados'->0->>'codigo' = 'conflicto_evento' $c$);
SELECT pg_temp.rpc('104 marcas: evento_id nuevo con la misma secuencia -> secuencia_duplicada', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(11, 1))),
  $c$ $1->'resultados'->0->>'estado' = 'rechazo_definitivo' AND $1->'resultados'->0->>'codigo' = 'secuencia_duplicada' $c$);

SELECT pg_temp.rpc('105 marcas: employee_no sin alta -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(99, 2, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000099"}'))),
  $c$ $1->'resultados'->0->>'estado' = 'rechazo_definitivo' AND $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.verifica('105b no_enrolado NO insertó marca y SÍ dejó evidencia en marca_rechazada',
  $$SELECT (SELECT count(*) FROM tiempo.marca WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000099') = 0
      AND (SELECT count(*) FROM tiempo.marca_rechazada r WHERE r.evento_id = '11111111-aaaa-4aaa-8aaa-000000000099'
             AND r.codigo = 'no_enrolado' AND r.employee_no = 99
             AND r.terminal_id = (SELECT v::bigint FROM _ens WHERE k = 'rpc1')) = 1$$);
SELECT pg_temp.rpc('106 marcas: el mismo no_enrolado reintentado sigue rechazado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(99, 2, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000099"}'))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.verifica('106b el reintento no duplicó la evidencia (ON CONFLICT DO NOTHING)',
  $$SELECT count(*) = 1 FROM tiempo.marca_rechazada WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000099'$$);
SELECT pg_temp.rpc('107 marcas: alta en pendiente_alta -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(15, 3))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.rpc('108 marcas: alta en baja SÍ resuelve (marca encolada antes de la baja) y es de su persona', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(14, 3, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000014"}'))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.verifica('108b la marca de la alta en baja es de la persona de esa alta',
  $$SELECT count(*) = 1 FROM tiempo.marca WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000014'
      AND persona_id = '00000000-0000-0000-0000-00000000beef'$$);
-- M1 (security): una alta en baja no sirve para falsear marcas fuera de su vida.
SELECT pg_temp.rpc('108c M1: marca de una alta dada de baja hace 3 h, con momento posterior a la baja (+1 h) -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(16, 9))),
  $c$ $1->'resultados'->0->>'estado' = 'rechazo_definitivo' AND $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.rpc('108d M1: marca de esa misma alta con momento dentro de la hora de holgura posterior a la baja -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(16, 10, jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('-2 hours -30 minutes'))))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.rpc('108e M1: marca de la alta 14 (baja ahora) con momento de hace 2 h, anterior a la baja -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(14, 11, jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('-2 hours'))))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.rpc('108f M1: marca anterior a la creación de la alta (-1 h) -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 12, jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('-31 days'))))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.rpc('108g M1: marca con 30 min de anticipación a la creación de la alta (dentro de la holgura) -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 13, jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('-30 days -30 minutes'))))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.rpc('109 marcas: alta en pendiente_baja resuelve', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(13, 4))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.rpc('110 marcas: alta en esperando_huella resuelve', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(12, 5))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);

-- Aislamiento entre terminales: el employee_no de una terminal no existe en la otra.
SELECT pg_temp.rpc('111 aislamiento: employee_no de RPC1 usado en RPC2 -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc2'), jsonb_build_array(pg_temp.ev(11, 1))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.rpc('111b aislamiento: employee_no de RPC2 usado en RPC1 -> no_enrolado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(21, 6))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);

-- Forma inválida: 23 variantes en un solo lote; todas deben quedar rechazo_definitivo/forma_invalida.
SELECT pg_temp.rpc('112 marcas: 23 variantes de forma inválida (incl. fechas locales, yesterday e infinity) -> todas forma_invalida', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 101, '{"evento_id":"no-es-uuid"}'),
    pg_temp.ev(0,  102),
    pg_temp.ev(11, 103, '{"employee_no":"abc"}'),
    pg_temp.ev(100000000, 104),
    pg_temp.ev(11, -1),
    pg_temp.ev(11, 106, '{"secuencia_local":"x"}'),
    pg_temp.ev(11, 107, '{"desfase_local":"-13:00"}'),
    pg_temp.ev(11, 108, '{"desfase_local":"+14:01"}'),
    pg_temp.ev(11, 109, '{"desfase_local":"-06:60"}'),
    pg_temp.ev(11, 110, '{"desfase_local":"0600"}'),
    pg_temp.ev(11, 111, '{"estado_reloj":"x"}'),
    pg_temp.ev(11, 112, '{"version_software":""}'),
    pg_temp.ev(11, 113, '{"version_software":"12345678901234567"}'),
    pg_temp.ev(11, 114, '{"momento_dispositivo":"2026-10-06T10:00:00"}'),
    pg_temp.ev(11, 115, '{"momento_dispositivo":"2023-12-31T23:59:59Z"}'),
    pg_temp.ev(11, 116, jsonb_build_object('momento_dispositivo', pg_temp.ahora_mas('2 years'))),
    pg_temp.ev(11, 117, '{"momento_dispositivo":"basura"}'),
    pg_temp.ev(11, 118, '{"momento_dispositivo":"06/10/2026 10:00:00Z"}'),
    pg_temp.ev(11, 119, '{"momento_dispositivo":"yesterday 10:00Z"}'),
    pg_temp.ev(11, 120, '{"momento_dispositivo":"infinity"}'),
    pg_temp.ev(11, 121, '{"momento_dispositivo":"-infinity"}'),
    to_jsonb(5),
    '{}'::jsonb)),
  $c$ jsonb_array_length($1->'resultados') = 23
      AND (SELECT bool_and(r->>'estado' = 'rechazo_definitivo' AND r->>'codigo' = 'forma_invalida')
           FROM jsonb_array_elements($1->'resultados') r) $c$);
SELECT pg_temp.rpc('112b marcas: bordes válidos del desfase (-12:00 y +14:00) -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 7, '{"desfase_local":"-12:00"}'), pg_temp.ev(11, 8, '{"desfase_local":"+14:00"}'))),
  $c$ (SELECT bool_and(r->>'estado' = 'confirmado') FROM jsonb_array_elements($1->'resultados') r) $c$);
SELECT pg_temp.verifica('112c la evidencia de forma_invalida se guardó sin texto libre (columnas acotadas)',
  $$SELECT count(*) >= 15 FROM tiempo.marca_rechazada
    WHERE codigo = 'forma_invalida' AND terminal_id = (SELECT v::bigint FROM _ens WHERE k = 'rpc1')$$);

-- secuencia_local acotada (bordes en una terminal con maximo = 0: RPC2).
SELECT pg_temp.rpc('113 marcas: secuencia = max + 1 000 001 -> secuencia_fuera_de_rango', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc2'), jsonb_build_array(pg_temp.ev(21, 1000001))),
  $c$ $1->'resultados'->0->>'codigo' = 'secuencia_fuera_de_rango' $c$);
SELECT pg_temp.rpc('113b marcas: secuencia = max + 1 000 000 -> confirmado (borde)', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc2'), jsonb_build_array(pg_temp.ev(21, 1000000))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);

-- Degradación del reloj (sólo empeora) y sus dos bordes.
SELECT pg_temp.rpc('114 reloj: +6 min, -8 días degradan a deriva; +4 min y -6 días no; declarado deriva no mejora', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 20, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000020','momento_dispositivo',pg_temp.ahora_mas('6 minutes'))),
    pg_temp.ev(11, 21, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000021','momento_dispositivo',pg_temp.ahora_mas('4 minutes'))),
    pg_temp.ev(11, 22, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000022','momento_dispositivo',pg_temp.ahora_mas('-8 days'))),
    pg_temp.ev(11, 23, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000023','momento_dispositivo',pg_temp.ahora_mas('-6 days'))),
    pg_temp.ev(11, 24, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000024','momento_dispositivo',pg_temp.ahora_mas('6 minutes'),'estado_reloj','deriva')),
    pg_temp.ev(11, 25, jsonb_build_object('evento_id','11111111-aaaa-4aaa-8aaa-000000000025','estado_reloj','sin_sincronizar')))),
  $c$ (SELECT bool_and(r->>'estado' = 'confirmado') FROM jsonb_array_elements($1->'resultados') r) $c$);
SELECT pg_temp.verifica('114b estado_reloj quedó deriva/sincronizado/deriva/sincronizado/deriva/sin_sincronizar',
  $$SELECT (SELECT string_agg(estado_reloj, ',' ORDER BY secuencia_local) FROM tiempo.marca
            WHERE evento_id::text LIKE '11111111-aaaa-4aaa-8aaa-0000000000%' AND secuencia_local BETWEEN 20 AND 25 AND terminal_id = 'ENSAYO-RPC')
         = 'deriva,sincronizado,deriva,sincronizado,deriva,sin_sincronizar'$$);
SELECT pg_temp.verifica('114c la degradación creó la excepción reloj_no_sincronizado (la crea el trigger existente)',
  $$SELECT count(*) = 4 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE e.motivo_revision = 'reloj_no_sincronizado' AND m.terminal_id = 'ENSAYO-RPC' AND m.secuencia_local BETWEEN 20 AND 25$$);

-- origen y persona los decide el servidor, no el evento.
SELECT pg_temp.rpc('115 origen/persona_id/requiere_revision del evento se ignoran', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(11, 30, jsonb_build_object(
    'evento_id', '11111111-aaaa-4aaa-8aaa-000000000030', 'origen', 'captura_manual',
    'persona_id', '00000000-0000-0000-0000-00000000beef', 'requiere_revision', true)))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.verifica('115b la marca quedó origen=terminal y de la persona del alta, no la del evento',
  $$SELECT count(*) = 1 FROM tiempo.marca WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000030'
      AND origen = 'terminal' AND persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_id')$$);

-- Errores de lote.
SELECT pg_temp.caso('116 lote vacío -> 22023 lote_invalido', 'service_role',
  format('SELECT tiempo.fn_marca_terminal_registrar(%s::bigint, ''[]''::jsonb)', (SELECT v FROM _ens WHERE k='rpc1')), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('116b lote de 201 eventos -> 22023 lote_invalido', 'service_role',
  'SELECT ' || pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), (SELECT jsonb_agg(pg_temp.ev(11, 5000 + g)) FROM generate_series(1, 201) g)), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('116c lote que no es arreglo -> 22023', 'service_role',
  format('SELECT tiempo.fn_marca_terminal_registrar(%s::bigint, ''{}''::jsonb)', (SELECT v FROM _ens WHERE k='rpc1')), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('116d lote NULL -> 22023', 'service_role',
  format('SELECT tiempo.fn_marca_terminal_registrar(%s::bigint, NULL::jsonb)', (SELECT v FROM _ens WHERE k='rpc1')), '22023', NULL, 'lote_invalido');
SELECT pg_temp.caso('116e lote de exactamente 200 eventos es aceptado', 'service_role',
  'SELECT ' || pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), (SELECT jsonb_agg(pg_temp.ev(11, 6000 + g)) FROM generate_series(1, 200) g)), 'ok');
SELECT pg_temp.caso('117 terminal inexistente -> SCJ12 terminal_no_valida', 'service_role',
  'SELECT tiempo.fn_marca_terminal_registrar(999999999::bigint, ''[]''::jsonb)', 'SCJ12', NULL, 'terminal_no_valida');
SELECT pg_temp.caso('117b terminal inactiva -> SCJ12 terminal_no_valida', 'service_role',
  'SELECT ' || pg_temp.lote((SELECT v FROM _ens WHERE k='terminal_inactiva'), jsonb_build_array(pg_temp.ev(901, 1))), 'SCJ12', NULL, 'terminal_no_valida');

-- Índice de la respuesta: se conserva el orden original aunque se procese por secuencia_local.
SELECT pg_temp.rpc('118 respuesta: indice y evento_id siguen el orden original del lote', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(
    pg_temp.ev(11, 40, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000040"}'),
    pg_temp.ev(11, 35, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000035"}'))),
  $c$ $1->'resultados'->0->>'indice' = '0' AND $1->'resultados'->0->>'evento_id' = '11111111-aaaa-4aaa-8aaa-000000000040'
      AND $1->'resultados'->1->>'indice' = '1' AND $1->'resultados'->1->>'evento_id' = '11111111-aaaa-4aaa-8aaa-000000000035'
      AND (SELECT bool_and(r->>'estado' = 'confirmado') FROM jsonb_array_elements($1->'resultados') r) $c$);

-- Una marca de una persona NO activa se inserta igual y el trigger existente la señala (se prueba al final,
-- después de suspender a la persona).

-- ---------- fn_terminal_autenticar ----------
CREATE FUNCTION pg_temp.h(p_nombre text) RETURNS text AS $$
  SELECT encode(sha256(convert_to('scjt_ensayo_' || p_nombre, 'UTF8')), 'hex');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.auth(p_hash text, p_ip text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_autenticar(%L, %L)', p_hash, p_ip);
$$ LANGUAGE sql;

INSERT INTO tiempo.terminal_credencial (terminal_id, hash, etiqueta, revocada_en, expira_en)
SELECT (SELECT v::bigint FROM _ens WHERE k = 'rpc1'), pg_temp.h(x.k), x.k, x.rev, x.exp
FROM (VALUES ('valida', NULL::timestamptz, NULL::timestamptz),
             ('revocada', now() - interval '1 day', NULL::timestamptz),
             ('expirada', NULL::timestamptz, now() - interval '1 hour')) AS x(k, rev, exp);
INSERT INTO tiempo.terminal_credencial (terminal_id, hash, etiqueta)
SELECT v::bigint, pg_temp.h('inactiva'), 'inactiva' FROM _ens WHERE k = 'terminal_inactiva';

SELECT pg_temp.rpc('120 autenticar: llave válida -> serie, credencial e ip_cambio=false', 'service_role',
  pg_temp.auth(pg_temp.h('valida'), '10.0.0.1'),
  $c$ $1->>'serie' = 'ENSAYO-RPC' AND ($1->>'credencial_id') IS NOT NULL AND ($1->>'ip_cambio')::boolean = false
      AND ($1->>'terminal_id') = (SELECT v FROM _ens WHERE k = 'rpc1') $c$);
SELECT pg_temp.verifica('120b autenticar escribió ultimo_uso_en, ultima_ip y ultimo_contacto_en de la terminal',
  $$SELECT (SELECT ultimo_uso_en IS NOT NULL AND ultima_ip = '10.0.0.1'::inet FROM tiempo.terminal_credencial WHERE etiqueta = 'valida')
      AND (SELECT ultimo_contacto_en IS NOT NULL FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC')$$);
SELECT pg_temp.rpc('121 autenticar: misma IP -> ip_cambio=false', 'service_role',
  pg_temp.auth(pg_temp.h('valida'), '10.0.0.1'), $c$ ($1->>'ip_cambio')::boolean = false $c$);
SELECT pg_temp.rpc('122 autenticar: otra IP -> ip_cambio=true (siempre se registra, aunque haya <30 s)', 'service_role',
  pg_temp.auth(pg_temp.h('valida'), '10.0.0.2'), $c$ ($1->>'ip_cambio')::boolean = true $c$);
SELECT pg_temp.verifica('122b el cambio de IP quedó en ultima_ip e ip_cambiada_en',
  $$SELECT ultima_ip = '10.0.0.2'::inet AND ip_cambiada_en IS NOT NULL FROM tiempo.terminal_credencial WHERE etiqueta = 'valida'$$);
SELECT pg_temp.rpc('123 autenticar: formato de hash inválido -> NULL (sin consulta)', 'service_role',
  pg_temp.auth('zzz', '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('123b autenticar: hash en mayúsculas -> NULL', 'service_role',
  pg_temp.auth(upper(pg_temp.h('valida')), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('123c autenticar: hash desconocido -> NULL', 'service_role',
  pg_temp.auth(repeat('0', 64), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('124 autenticar: llave revocada -> NULL', 'service_role',
  pg_temp.auth(pg_temp.h('revocada'), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('124b autenticar: llave expirada -> NULL', 'service_role',
  pg_temp.auth(pg_temp.h('expirada'), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('124c autenticar: llave válida de una terminal inactiva -> NULL', 'service_role',
  pg_temp.auth(pg_temp.h('inactiva'), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.rpc('125 autenticar: IP no interpretable no rompe (ip_cambio=false)', 'service_role',
  pg_temp.auth(pg_temp.h('valida'), 'no-es-ip'), $c$ $1->>'serie' = 'ENSAYO-RPC' AND ($1->>'ip_cambio')::boolean = false $c$);

-- ---------- fn_terminal_mapa ----------
SELECT pg_temp.rpc('130 mapa RPC1: altas no-baja (11,12,13,15,17), sin persona_id ni persona_activa', 'service_role',
  format('tiempo.fn_terminal_mapa(%s::bigint)', (SELECT v FROM _ens WHERE k='rpc1')),
  $c$ (SELECT array_agg((r->>'employee_no')::integer ORDER BY (r->>'employee_no')::integer) FROM jsonb_array_elements($1) r) = ARRAY[11,12,13,15,17]
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements($1) r WHERE r ? 'persona_id' OR r ? 'persona_activa' OR r ? 'nombre')
      AND (SELECT bool_and(r ?& ARRAY['terminal_usuario_id','employee_no','estado','huellas_capturadas']) FROM jsonb_array_elements($1) r) $c$);
SELECT pg_temp.rpc('130b mapa RPC2: sólo sus altas (21 y 22)', 'service_role',
  format('tiempo.fn_terminal_mapa(%s::bigint)', (SELECT v FROM _ens WHERE k='rpc2')),
  $c$ (SELECT array_agg((r->>'employee_no')::integer ORDER BY (r->>'employee_no')::integer) FROM jsonb_array_elements($1) r) = ARRAY[21,22] $c$);
SELECT pg_temp.rpc('130c mapa de una terminal inexistente -> []', 'service_role',
  'tiempo.fn_terminal_mapa(999999999::bigint)', $c$ $1 = '[]'::jsonb $c$);

-- ---------- fn_terminal_movimiento_registrar ----------
CREATE FUNCTION pg_temp.mov_rpc(p_tid text, p_tu text, p_tipo text, p_huellas text, p_detalle text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, %L::text, %s::integer, %L::text)',
                p_tid, p_tu, p_tipo, p_huellas, p_detalle);
$$ LANGUAGE sql;

SELECT pg_temp.rpc('140 movimiento: huella_capturada (2) sobre esperando_huella -> registrado/activo', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu12'), 'huella_capturada', '2', NULL),
  $c$ $1->>'resultado' = 'registrado' AND $1->>'estado' = 'activo' $c$);
SELECT pg_temp.verifica('140b la bitácora quedó origen=terminal, sin autor, con el employee_no y la persona de la alta',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario b
    WHERE b.terminal_usuario_id = (SELECT v::bigint FROM _ens WHERE k = 'tu12') AND b.tipo_movimiento = 'huella_capturada'
      AND b.origen = 'terminal' AND b.registrado_por IS NULL AND b.employee_no = 12 AND b.huellas_capturadas = 2
      AND b.persona_id = '00000000-0000-0000-0000-00000000beef'$$);
SELECT pg_temp.rpc('141 movimiento: el mismo conteo otra vez -> ya_aplicado', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu12'), 'huella_capturada', '2', NULL),
  $c$ $1->>'resultado' = 'ya_aplicado' $c$);
SELECT pg_temp.verifica('141b ya_aplicado no insertó una segunda fila',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario
    WHERE terminal_usuario_id = (SELECT v::bigint FROM _ens WHERE k = 'tu12') AND tipo_movimiento = 'huella_capturada'$$);
SELECT pg_temp.rpc('142 movimiento: otro conteo sobre activo -> registrado', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu12'), 'huella_capturada', '3', NULL),
  $c$ $1->>'resultado' = 'registrado' $c$);
SELECT pg_temp.rpc('143 movimiento: usuario_creado sobre una alta ya activa -> ya_aplicado', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu12'), 'usuario_creado', 'NULL', NULL),
  $c$ $1->>'resultado' = 'ya_aplicado' $c$);
SELECT pg_temp.caso('144 movimiento: usuario_creado sobre pendiente_baja -> SCJ11', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu13'), 'usuario_creado', 'NULL', NULL),
  'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.rpc('145 movimiento: baja_confirmada sobre pendiente_baja -> registrado/baja', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu13'), 'baja_confirmada', 'NULL', NULL),
  $c$ $1->>'resultado' = 'registrado' AND $1->>'estado' = 'baja' $c$);
SELECT pg_temp.rpc('145b movimiento: baja_confirmada repetida -> ya_aplicado', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu13'), 'baja_confirmada', 'NULL', NULL),
  $c$ $1->>'resultado' = 'ya_aplicado' $c$);
SELECT pg_temp.rpc('146 movimiento: alta de OTRA terminal -> no_encontrado (no revela que existe)', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu21'), 'error', 'NULL', 'x'),
  $c$ $1->>'resultado' = 'no_encontrado' $c$);
SELECT pg_temp.rpc('146b movimiento: alta inexistente -> no_encontrado', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), '999999999', 'error', 'NULL', 'x'),
  $c$ $1->>'resultado' = 'no_encontrado' $c$);
SELECT pg_temp.verifica('146c el intento sobre la alta ajena no insertó nada en su bitácora',
  $$SELECT count(*) = 0 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = (SELECT v::bigint FROM _ens WHERE k = 'tu21')$$);
SELECT pg_temp.caso('147 movimiento: tipo asignado no permitido -> SCJ11', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'asignado', 'NULL', NULL), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('147b movimiento: tipo baja_solicitada no permitido -> SCJ11', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'baja_solicitada', 'NULL', NULL), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('147c movimiento: tipo NULL -> SCJ11', 'service_role',
  format('SELECT tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, NULL::text, NULL::integer, NULL::text)',
         (SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11')), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('148 movimiento: huellas 0 -> 22023 huellas_invalidas', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'huella_capturada', '0', NULL), '22023', NULL, 'huellas_invalidas');
SELECT pg_temp.caso('148b movimiento: huellas 11 -> 22023', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'huella_capturada', '11', NULL), '22023', NULL, 'huellas_invalidas');
SELECT pg_temp.caso('148c movimiento: huellas NULL -> 22023', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'huella_capturada', 'NULL', NULL), '22023', NULL, 'huellas_invalidas');
SELECT pg_temp.rpc('149 movimiento: error sin detalle -> registrado, error_detalle fijo', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'error', 'NULL', NULL),
  $c$ $1->>'resultado' = 'registrado' $c$);
SELECT pg_temp.verifica('149b error_detalle = ''error sin detalle'' y el estado no cambió',
  $$SELECT error_detalle = 'error sin detalle' AND estado = 'activo' FROM tiempo.terminal_usuario WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'tu11')$$);
SELECT pg_temp.rpc('149c movimiento: detalle de 600 caracteres se trunca a 500', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'error', 'NULL', repeat('x', 600)),
  $c$ $1->>'resultado' = 'registrado' $c$);
SELECT pg_temp.verifica('149d error_detalle quedó en 500 caracteres',
  $$SELECT char_length(error_detalle) = 500 FROM tiempo.terminal_usuario WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'tu11')$$);
SELECT pg_temp.rpc('149e movimiento: saltos de línea y tabuladores se colapsan a espacio', 'service_role',
  pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu11'), 'error', 'NULL', E'a\nb\tc'),
  $c$ $1->>'resultado' = 'registrado' $c$);
SELECT pg_temp.verifica('149f error_detalle = ''a b c''',
  $$SELECT error_detalle = 'a b c' FROM tiempo.terminal_usuario WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'tu11')$$);
SELECT pg_temp.caso('150 movimiento: error sobre una alta ya en baja -> SCJ11', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu13'), 'error', 'NULL', 'x'), 'SCJ11', NULL, 'transicion_invalida');
SELECT pg_temp.caso('150b movimiento: baja_confirmada sobre una alta activa -> SCJ11', 'service_role',
  'SELECT ' || pg_temp.mov_rpc((SELECT v FROM _ens WHERE k='rpc1'), (SELECT v FROM _ens WHERE k='tu12'), 'baja_confirmada', 'NULL', NULL), 'SCJ11', NULL, 'transicion_invalida');

-- ---------- fn_terminal_latido ----------
SELECT pg_temp.rpc('160 latido: guarda el estado y devuelve hora, desfase y última secuencia', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, %L::timestamptz, true, true, %L::text, -5)',
         (SELECT v FROM _ens WHERE k='rpc1'), (clock_timestamp() + interval '120 seconds')::text, 'v-0123456789abcdefXYZ'),
  $c$ ($1->>'desfase_reloj_seg')::integer BETWEEN 115 AND 125 AND ($1->>'hora_servidor') IS NOT NULL
      AND ($1->>'ultima_secuencia_recibida')::bigint = (SELECT max(secuencia_local) FROM tiempo.marca WHERE terminal_id = 'ENSAYO-RPC' AND origen = 'terminal') $c$);
SELECT pg_temp.verifica('160b latido: version_pi truncada a 16, marcas_pendientes negativas -> 0, alcanzable, desfase',
  $$SELECT version_pi = 'v-0123456789abcd' AND marcas_pendientes = 0 AND terminal_alcanzable AND reloj_desfase_seg BETWEEN 115 AND 125
    FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC'$$);
SELECT pg_temp.rpc('161 latido: sin hora_terminal -> desfase null y NO dispara SCJ13 con altas vigentes', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, NULL::timestamptz, false, NULL::boolean, NULL::text, NULL::integer)',
         (SELECT v FROM _ens WHERE k='rpc1')),
  $c$ jsonb_typeof($1->'desfase_reloj_seg') = 'null' $c$);
SELECT pg_temp.caso('162 latido: terminal inactiva -> SCJ12', 'service_role',
  format('SELECT tiempo.fn_terminal_latido(%s::bigint, NULL::timestamptz, true, true, NULL::text, 0)', (SELECT v FROM _ens WHERE k='terminal_inactiva')),
  'SCJ12', NULL, 'terminal_no_valida');
SELECT pg_temp.caso('162b latido: terminal inexistente -> SCJ12', 'service_role',
  'SELECT tiempo.fn_terminal_latido(999999999::bigint, NULL::timestamptz, true, true, NULL::text, 0)', 'SCJ12', NULL, 'terminal_no_valida');
SELECT pg_temp.rpc('163 B8: latido con hora infinity -> desfase null (no rompe)', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, ''infinity''::timestamptz, true, true, NULL::text, 0)', (SELECT v FROM _ens WHERE k='rpc1')),
  $c$ jsonb_typeof($1->'desfase_reloj_seg') = 'null' $c$);
SELECT pg_temp.rpc('163b B8: latido con hora -infinity -> desfase null', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, ''-infinity''::timestamptz, true, true, NULL::text, 0)', (SELECT v FROM _ens WHERE k='rpc1')),
  $c$ jsonb_typeof($1->'desfase_reloj_seg') = 'null' $c$);
SELECT pg_temp.rpc('163c B8: latido con una hora absurda (año 4000) -> desfase acotado al máximo entero', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, %L::timestamptz, true, true, NULL::text, 0)', (SELECT v FROM _ens WHERE k='rpc1'), '4000-01-01T00:00:00Z'),
  $c$ ($1->>'desfase_reloj_seg')::bigint = 2147483647 $c$);
SELECT pg_temp.rpc('163d B7: version_pi sin caracteres de control', 'service_role',
  format('tiempo.fn_terminal_latido(%s::bigint, NULL::timestamptz, true, true, %L::text, 0)', (SELECT v FROM _ens WHERE k='rpc1'), E'v1\n\t2'),
  $c$ $1 IS NOT NULL $c$);
SELECT pg_temp.verifica('163e version_pi = ''v12''',
  $$SELECT version_pi = 'v12' FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC'$$);

-- ---------- trigger SCJ13 ----------
SELECT pg_temp.caso('170 desactivar una terminal con altas vigentes como service_role -> SCJ13', 'service_role',
  $$UPDATE tiempo.terminal SET activa = false WHERE terminal_id = 'ENSAYO-RPC'$$, 'SCJ13', NULL, 'terminal_con_altas_vigentes');
SELECT pg_temp.caso('170b ... y como dueño también -> SCJ13', current_user::text,
  $$UPDATE tiempo.terminal SET activa = false WHERE terminal_id = 'ENSAYO-RPC'$$, 'SCJ13', NULL, 'terminal_con_altas_vigentes');
SELECT pg_temp.verifica('170c la terminal sigue activa tras el rechazo', $$SELECT activa FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-RPC'$$);
SELECT pg_temp.caso('171 desactivar una terminal sólo con altas en baja -> ok', 'service_role',
  $$UPDATE tiempo.terminal SET activa = false WHERE terminal_id = 'ENSAYO-BAJA'$$, 'ok');
SELECT pg_temp.caso('171b reactivarla (false -> true) no dispara el trigger', 'service_role',
  $$UPDATE tiempo.terminal SET activa = true WHERE terminal_id = 'ENSAYO-BAJA'$$, 'ok');
SELECT pg_temp.caso('172 desactivar una terminal sin altas -> ok', 'service_role',
  $$UPDATE tiempo.terminal SET activa = false WHERE terminal_id = 'ENSAYO-VACIA'$$, 'ok');
SELECT pg_temp.caso('173 cambiar otra columna de una terminal con altas -> ok (el trigger no se dispara)', 'service_role',
  $$UPDATE tiempo.terminal SET nombre = 'renombrada' WHERE terminal_id = 'ENSAYO-RPC'$$, 'ok');
SELECT pg_temp.caso('173b activa = activa (sin cambio) con altas -> ok', 'service_role',
  $$UPDATE tiempo.terminal SET activa = true WHERE terminal_id = 'ENSAYO-RPC'$$, 'ok');

-- ---------- topes de tasa (inserciones masivas como dueño, con el trigger de revisión activo) ----------
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'persona_id'), 'ENSAYO-TOPE', g, now(), '-06:00', 'sincronizado', 'ens', 'terminal'
FROM generate_series(1, 11) g;
SELECT pg_temp.rpc('180 tope por persona (más de 10 en 1 h): sólo alarma, se confirma', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='tope'), jsonb_build_array(pg_temp.ev(31, 12))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'persona_id'), 'ENSAYO-TOPE', g, now(), '-06:00', 'sincronizado', 'ens', 'terminal'
FROM generate_series(13, 1002) g;
SELECT pg_temp.rpc('180b tope de alarma por terminal (>= 1 000 en 1 h): se confirma', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='tope'), jsonb_build_array(pg_temp.ev(31, 1003))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'persona_id'), 'ENSAYO-TOPE', g, now(), '-06:00', 'sincronizado', 'ens', 'terminal'
FROM generate_series(1004, 5003) g;
SELECT pg_temp.rpc('181 tope de rechazo por terminal (>= 5 000 en 1 h) -> rechazo_transitorio/tope_terminal', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='tope'), jsonb_build_array(pg_temp.ev(31, 5004, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000181"}'))),
  $c$ $1->'resultados'->0->>'estado' = 'rechazo_transitorio' AND $1->'resultados'->0->>'codigo' = 'tope_terminal' $c$);
SELECT pg_temp.verifica('181b el rechazo transitorio no insertó marca ni evidencia (el Pi reintenta)',
  $$SELECT (SELECT count(*) FROM tiempo.marca WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000181') = 0
      AND (SELECT count(*) FROM tiempo.marca_rechazada WHERE evento_id = '11111111-aaaa-4aaa-8aaa-000000000181') = 0$$);

-- ---------- marca_rechazada: tope diario, purga y privilegios ----------
INSERT INTO tiempo.marca_rechazada (terminal_id, codigo, creada_en)
SELECT (SELECT v::bigint FROM _ens WHERE k = 'baja'), 'no_enrolado', now() FROM generate_series(1, 5000);
SELECT pg_temp.rpc('190 tope de 5 000 filas por terminal/día: el rechazo se responde pero no se guarda', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='baja'), jsonb_build_array(pg_temp.ev(999, 1, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000190"}'))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$);
SELECT pg_temp.verifica('190b la tabla no creció (sigue en 5 000 filas de esa terminal)',
  $$SELECT count(*) = 5000 FROM tiempo.marca_rechazada WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k = 'baja')$$);

INSERT INTO tiempo.marca_rechazada (terminal_id, codigo, creada_en)
SELECT (SELECT v::bigint FROM _ens WHERE k = 'vacia'), 'no_enrolado', now() - (d || ' days')::interval FROM (VALUES (100), (100), (10)) x(d);
SELECT pg_temp.rpc('191 purga por defecto (90 días) -> borra lo viejo y devuelve la cuenta', 'service_role',
  'to_jsonb(tiempo.fn_marca_rechazada_purgar())', $c$ ($1 #>> '{}')::integer >= 2 $c$);
SELECT pg_temp.verifica('191b quedó sólo la fila de 10 días de esa terminal',
  $$SELECT count(*) = 1 FROM tiempo.marca_rechazada WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k = 'vacia')$$);
SELECT pg_temp.caso('191c purga con menos de 7 días -> 22023 retencion_invalida', 'service_role',
  'SELECT tiempo.fn_marca_rechazada_purgar(3)', '22023', NULL, 'retencion_invalida');
SELECT pg_temp.caso('191d purga con NULL -> 22023', 'service_role',
  'SELECT tiempo.fn_marca_rechazada_purgar(NULL)', '22023', NULL, 'retencion_invalida');
SELECT pg_temp.caso('192 service_role no puede DELETE directo en marca_rechazada', 'service_role', $$DELETE FROM tiempo.marca_rechazada$$, '42501');
SELECT pg_temp.caso('192b service_role no puede UPDATE en marca_rechazada', 'service_role', $$UPDATE tiempo.marca_rechazada SET codigo = 'no_enrolado'$$, '42501');
SELECT pg_temp.caso('192c service_role no puede TRUNCATE marca_rechazada', 'service_role', $$TRUNCATE tiempo.marca_rechazada$$, '42501');
SELECT pg_temp.caso('192d authenticated no puede INSERT en marca_rechazada', 'authenticated',
  format($f$INSERT INTO tiempo.marca_rechazada (terminal_id, codigo) VALUES (%L::bigint, 'no_enrolado')$f$, (SELECT v FROM _ens WHERE k='vacia')), '42501');
SELECT pg_temp.caso('192e anon no lee marca_rechazada', 'anon', $$SELECT 1 FROM tiempo.marca_rechazada LIMIT 1$$, '42501');
SELECT pg_temp.caso('192f CHECK de código: código fuera de la lista cerrada falla', current_user::text,
  format($f$INSERT INTO tiempo.marca_rechazada (terminal_id, codigo) VALUES (%L::bigint, 'otro')$f$, (SELECT v FROM _ens WHERE k='vacia')), '23514');
SELECT pg_temp.caso('192g authenticated con permiso lee marca_rechazada', 'authenticated',
  $q$DO $b$ BEGIN IF (SELECT count(*) FROM tiempo.marca_rechazada) = 0 THEN RAISE EXCEPTION 'sin filas' USING ERRCODE='XX999'; END IF; END $b$$q$, 'ok');
SELECT pg_temp.caso('192h authenticated sin permiso ve 0 filas de marca_rechazada', 'authenticated',
  $q$DO $b$ BEGIN IF (SELECT count(*) FROM tiempo.marca_rechazada) <> 0 THEN RAISE EXCEPTION 'vio filas' USING ERRCODE='XX999'; END IF; END $b$$q$,
  'ok', '11111111-1111-1111-1111-111111111111');

-- ---------- terminal_credencial: privilegios, CHECK y unicidad del hash ----------
SELECT pg_temp.caso('195 authenticated no lee terminal_credencial', 'authenticated', $$SELECT 1 FROM tiempo.terminal_credencial LIMIT 1$$, '42501');
SELECT pg_temp.caso('195b anon no lee terminal_credencial', 'anon', $$SELECT 1 FROM tiempo.terminal_credencial LIMIT 1$$, '42501');
SELECT pg_temp.caso('195c service_role no puede cambiar el hash', 'service_role', $$UPDATE tiempo.terminal_credencial SET hash = repeat('a', 64)$$, '42501');
SELECT pg_temp.caso('195d service_role no puede cambiar ultima_ip (sólo fn_terminal_autenticar)', 'service_role', $$UPDATE tiempo.terminal_credencial SET ultima_ip = '1.1.1.1'$$, '42501');
SELECT pg_temp.caso('195e service_role sí puede revocar (revocada_en)', 'service_role', $$UPDATE tiempo.terminal_credencial SET revocada_en = now() WHERE etiqueta = 'valida'$$, 'ok');
SELECT pg_temp.caso('195f service_role no puede borrar credenciales', 'service_role', $$DELETE FROM tiempo.terminal_credencial$$, '42501');
SELECT pg_temp.rpc('195g tras revocar, la llave válida deja de autenticar (revocación inmediata)', 'service_role',
  pg_temp.auth(pg_temp.h('valida'), '10.0.0.1'), $c$ $1 IS NULL $c$);
SELECT pg_temp.caso('196 INSERT con hash en mayúsculas -> CHECK 23514', 'service_role',
  format($f$INSERT INTO tiempo.terminal_credencial (terminal_id, hash) VALUES (%L::bigint, %L)$f$, (SELECT v FROM _ens WHERE k='rpc1'), repeat('A', 64)), '23514');
SELECT pg_temp.caso('196b INSERT con hash de 63 caracteres -> CHECK 23514', 'service_role',
  format($f$INSERT INTO tiempo.terminal_credencial (terminal_id, hash) VALUES (%L::bigint, %L)$f$, (SELECT v FROM _ens WHERE k='rpc1'), repeat('a', 63)), '23514');
SELECT pg_temp.caso('196c INSERT con hash repetido -> UNIQUE 23505', 'service_role',
  format($f$INSERT INTO tiempo.terminal_credencial (terminal_id, hash) VALUES (%L::bigint, %L)$f$, (SELECT v FROM _ens WHERE k='rpc1'), pg_temp.h('expirada')), '23505');
SELECT pg_temp.caso('196d INSERT válido como service_role funciona con la secuencia identity revocada', 'service_role',
  format($f$INSERT INTO tiempo.terminal_credencial (terminal_id, hash, etiqueta) VALUES (%L::bigint, %L, 'rotacion')$f$, (SELECT v FROM _ens WHERE k='rpc1'), pg_temp.h('rotacion')), 'ok');
SELECT pg_temp.rpc('196e traslape de rotación: la llave nueva autentica mientras la otra sigue vigente', 'service_role',
  pg_temp.auth(pg_temp.h('rotacion'), '10.0.0.9'), $c$ $1->>'serie' = 'ENSAYO-RPC' $c$);

-- ---------- revisión de security: M3 (revocación inmutable), B4 (tope de errores), B5, privilegios de columna ----------
SELECT pg_temp.caso('197 M3: poner revocada_en en NULL en una credencial ya revocada -> SCJ14', 'service_role',
  $$UPDATE tiempo.terminal_credencial SET revocada_en = NULL WHERE etiqueta = 'revocada'$$, 'SCJ14', NULL, 'credencial_revocada_inmutable');
SELECT pg_temp.caso('197b M3: cambiar revocada_en a otro instante -> SCJ14', 'service_role',
  $$UPDATE tiempo.terminal_credencial SET revocada_en = now() WHERE etiqueta = 'revocada'$$, 'SCJ14', NULL, 'credencial_revocada_inmutable');
SELECT pg_temp.caso('197c M3: la llave que se revocó en este ensayo tampoco se reactiva, ni siquiera como dueño -> SCJ14', current_user::text,
  $$UPDATE tiempo.terminal_credencial SET revocada_en = NULL WHERE etiqueta = 'valida'$$, 'SCJ14', NULL, 'credencial_revocada_inmutable');
SELECT pg_temp.caso('197d M3: un UPDATE que deja revocada_en igual no se bloquea', 'service_role',
  $$UPDATE tiempo.terminal_credencial SET revocada_en = revocada_en WHERE etiqueta = 'revocada'$$, 'ok');
SELECT pg_temp.verifica('197e las credenciales revocadas siguen revocadas',
  $$SELECT count(*) = 2 FROM tiempo.terminal_credencial WHERE etiqueta IN ('revocada', 'valida') AND revocada_en IS NOT NULL$$);
SELECT pg_temp.caso('197f M3: revocar una llave vigente (NULL -> valor) sí se permite', 'service_role',
  $$UPDATE tiempo.terminal_credencial SET revocada_en = now() WHERE etiqueta = 'rotacion'$$, 'ok');

SELECT pg_temp.verifica('198 B4: de 25 errores sobre una alta en 1 h se registran 20 y el resto devuelve limitado',
  format($f$SELECT count(*) FILTER (WHERE r->>'resultado' = 'registrado') = 20
                AND count(*) FILTER (WHERE r->>'resultado' = 'limitado') = 5
            FROM (SELECT tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, 'error', NULL, 'e' || g) AS r
                  FROM generate_series(1, 25) g) s$f$,
         (SELECT v FROM _ens WHERE k = 'rpc2'), (SELECT v FROM _ens WHERE k = 'tu21')));
SELECT pg_temp.verifica('198b B4: sólo 20 filas de error en la bitácora de esa alta',
  $$SELECT count(*) = 20 FROM tiempo.bitacora_movimiento_terminal_usuario
    WHERE terminal_usuario_id = (SELECT v::bigint FROM _ens WHERE k = 'tu21') AND tipo_movimiento = 'error'$$);

SELECT pg_temp.caso('199 B5: service_role ya no puede INSERT directo en marca_rechazada (sólo la función interna)', 'service_role',
  format($f$INSERT INTO tiempo.marca_rechazada (terminal_id, codigo) VALUES (%L::bigint, 'no_enrolado')$f$, (SELECT v FROM _ens WHERE k='vacia')), '42501');
SELECT pg_temp.verifica('199b has_column_privilege: service_role sin UPDATE de hash/ultima_ip y sí de revocada_en; anon/authenticated sin SELECT de hash; nadie con INSERT en marca_rechazada',
  $$SELECT NOT has_column_privilege('service_role', 'tiempo.terminal_credencial', 'hash', 'UPDATE')
       AND NOT has_column_privilege('service_role', 'tiempo.terminal_credencial', 'ultima_ip', 'UPDATE')
       AND has_column_privilege('service_role', 'tiempo.terminal_credencial', 'revocada_en', 'UPDATE')
       AND NOT has_column_privilege('anon', 'tiempo.terminal_credencial', 'hash', 'SELECT')
       AND NOT has_column_privilege('authenticated', 'tiempo.terminal_credencial', 'hash', 'SELECT')
       AND NOT has_column_privilege('service_role', 'tiempo.marca_rechazada', 'codigo', 'INSERT')
       AND NOT has_column_privilege('authenticated', 'tiempo.marca_rechazada', 'codigo', 'UPDATE')$$);

-- ---------- EXECUTE: nadie de la API fuera de service_role ----------
SELECT pg_temp.caso(format('200 %s sin EXECUTE: %s', r.rol, v.fn), r.rol, 'SELECT tiempo.' || v.fn || '(' || v.args || ')', '42501')
FROM (VALUES
  ('fn_terminal_autenticar',                 $$'x'::text, 'y'::text$$),
  ('fn_terminal_mapa',                       $$1::bigint$$),
  ('fn_terminal_movimiento_registrar',       $$1::bigint, 1::bigint, 'error'::text, NULL::integer, NULL::text$$),
  ('fn_terminal_latido',                     $$1::bigint, NULL::timestamptz, NULL::boolean, NULL::boolean, NULL::text, NULL::integer$$),
  ('fn_marca_terminal_registrar',            $$1::bigint, '[]'::jsonb$$),
  ('fn_terminal_baja_por_persona_inactiva',  $$NULL::uuid$$),
  ('fn_marca_rechazada_purgar',              $$90$$),
  ('fn_terminal_rechazo_registrar',          $$1::bigint, '{}'::jsonb, 'x'::text$$)
) AS v(fn, args)
CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rol);
SELECT pg_temp.caso('201 service_role sin EXECUTE sobre la función interna fn_terminal_rechazo_registrar', 'service_role',
  $$SELECT tiempo.fn_terminal_rechazo_registrar(1::bigint, '{}'::jsonb, 'x'::text)$$, '42501');

-- ---------- fn_terminal_baja_por_persona_inactiva (E3: con la persona SINTÉTICA S; el usuario base real
-- nunca se suspende) ----------
CREATE FUNCTION pg_temp.baja_p(p_persona text) RETURNS text AS $$
  SELECT format('to_jsonb(tiempo.fn_terminal_baja_por_persona_inactiva(%L::uuid))', p_persona);
$$ LANGUAGE sql;

SELECT pg_temp.rpc('210 baja por persona: persona ACTIVA -> 0 (no se puede usar contra personas activas)', 'service_role',
  pg_temp.baja_p((SELECT v FROM _ens WHERE k='persona_s')), $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.verifica('210b no se emitió ninguna baja automática',
  $$SELECT count(*) = 0 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE detalle LIKE 'baja automática%'$$);
SELECT pg_temp.rpc('210c persona inexistente y sin altas -> 0', 'service_role',
  pg_temp.baja_p('00000000-0000-0000-0000-0000000000ff'), $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.rpc('211 persona que no existe en personas, con alta por dar de baja y sin autor derivable -> -1 (B9: queda -1 para siempre)', 'service_role',
  pg_temp.baja_p('00000000-0000-0000-0000-000000000002'), $c$ ($1 #>> '{}')::integer = -1 $c$);
SELECT pg_temp.rpc('211b persona con todas sus altas ya en baja -> 0', 'service_role',
  pg_temp.baja_p('00000000-0000-0000-0000-000000000001'), $c$ ($1 #>> '{}')::integer = 0 $c$);

-- Suspensión de la persona SINTÉTICA (como dueño; el trigger de personas sincroniza persona.estado). El autor
-- es el admin real sólo porque registrado_por es una FK a personas.usuario: no se toca nada de él.
INSERT INTO _ens SELECT 'n_altas_s', count(*)::text FROM tiempo.terminal_usuario
  WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_s') AND estado NOT IN ('pendiente_baja', 'baja');
INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, registrado_por)
SELECT v::uuid, 'suspension', (SELECT v::uuid FROM _ens WHERE k = 'auth_uid') FROM _ens WHERE k = 'persona_s';
SELECT pg_temp.verifica('212 la persona sintética quedó en suspension y la real sigue activa',
  $$SELECT (SELECT estado FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'persona_s')) = 'suspension'
      AND (SELECT estado FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'persona_id')) = 'activo'$$);
SELECT pg_temp.rpc('213 baja por persona suspendida: una baja_solicitada por cada alta que no esté ya en baja (2)', 'service_role',
  pg_temp.baja_p((SELECT v FROM _ens WHERE k='persona_s')),
  $c$ ($1 #>> '{}')::integer = (SELECT v::integer FROM _ens WHERE k = 'n_altas_s') AND ($1 #>> '{}')::integer = 2 $c$);
SELECT pg_temp.verifica('213b ninguna alta de la persona sintética quedó fuera de pendiente_baja/baja',
  $$SELECT count(*) = 0 FROM tiempo.terminal_usuario
    WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_s') AND estado NOT IN ('pendiente_baja', 'baja')$$);
SELECT pg_temp.verifica('213c las bajas llevan origen web, el autor de la suspensión y el detalle fijo',
  $$SELECT count(*) = 2 FROM tiempo.bitacora_movimiento_terminal_usuario b
    WHERE b.tipo_movimiento = 'baja_solicitada' AND b.origen = 'web'
      AND b.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_s')
      AND b.registrado_por = (SELECT v::uuid FROM _ens WHERE k = 'auth_uid')
      AND b.detalle = 'baja automática: la persona pasó a suspension'$$);
SELECT pg_temp.rpc('214 baja por persona: segunda corrida -> 0 (idempotente)', 'service_role',
  pg_temp.baja_p((SELECT v FROM _ens WHERE k='persona_s')), $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.verifica('214b la persona REAL no recibió ninguna baja automática',
  $$SELECT count(*) = 0 FROM tiempo.bitacora_movimiento_terminal_usuario
    WHERE detalle LIKE 'baja automática%' AND persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_id')$$);

-- La marca de una persona NO activa se inserta igual y el trigger existente la señala.
SELECT pg_temp.rpc('215 marca de la persona suspendida (alta ya en pendiente_baja) -> confirmado', 'service_role',
  pg_temp.lote((SELECT v FROM _ens WHERE k='rpc1'), jsonb_build_array(pg_temp.ev(17, 60, '{"evento_id":"11111111-aaaa-4aaa-8aaa-000000000060"}'))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$);
SELECT pg_temp.verifica('215b el trigger existente creó la excepción persona_inactiva',
  $$SELECT count(*) = 1 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE m.evento_id = '11111111-aaaa-4aaa-8aaa-000000000060' AND e.motivo_revision = 'persona_inactiva'$$);

-- Conteos informativos para el bootstrap (dentro de la transacción simulada)
SELECT (SELECT count(*) FROM personas.permiso) AS total_permisos,
       (SELECT count(*) FROM personas.puesto_permiso pp JOIN personas.puesto p ON p.id = pp.puesto_id
        WHERE p.es_administrador_generico AND pp.activo) AS permisos_admin_generico;
\ir /tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/verificar_terminal.sql
-- ---------- resultado ----------
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;

ROLLBACK;
