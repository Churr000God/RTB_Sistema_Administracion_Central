-- Ensayo de 80_* y 81_* (SCJ-DEC-11). NO es DDL versionado, NO correr sin OK de orchestrator.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f <este archivo>
-- Todo dentro de una transacción real que termina en ROLLBACK (Prefer: tx=rollback no sirve acá).
-- Requisito: existe un usuario activo asignado hoy al puesto es_administrador_generico (el usuario
-- base de bootstrap). Ese caller recibe terminal_usuario_edicion/lectura por 80_*.sql.
-- Limitación: "persona inactiva" se prueba con una persona que no existe en personas.persona (no
-- hay otra persona suspendida fabricable sin ensuciar bitácora_movimiento_persona, inmutable aun
-- dentro de la transacción es inofensivo pero evita acoplar el ensayo a ese esquema).
\set ON_ERROR_STOP on
BEGIN;
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/80_tiempo_terminal_usuario.sql
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/81_tiempo_bitacora_movimiento_terminal_usuario.sql

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
SELECT pg_temp.caso('89 service_role desactiva la terminal (activa=false)', 'service_role',
  format($f$UPDATE tiempo.terminal SET activa = false WHERE id = %L::bigint$f$, (SELECT v FROM _ens WHERE k='terminal')), 'ok');
SELECT pg_temp.caso('90 asignado con terminal desactivada -> SCJ12 terminal_no_valida', 'authenticated', pg_temp.asignar('00000000-0000-0000-0000-00000000dead'), 'SCJ12', NULL, 'terminal_no_valida');
SELECT pg_temp.caso('91 baja_solicitada con terminal inactiva sigue funcionando', 'authenticated', pg_temp.mov('baja_solicitada'), 'ok');

-- Conteos informativos para el bootstrap (dentro de la transacción simulada)
SELECT (SELECT count(*) FROM personas.permiso) AS total_permisos,
       (SELECT count(*) FROM personas.puesto_permiso pp JOIN personas.puesto p ON p.id = pp.puesto_id
        WHERE p.es_administrador_generico AND pp.activo) AS permisos_admin_generico;
\ir /tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/verificar_terminal.sql
-- ---------- resultado ----------
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;

ROLLBACK;
