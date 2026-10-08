-- Ensayo de 85_tiempo_terminal_baja_por_caducidad.sql (SCJ-DEC-12 §12.7). NO es DDL versionado. NO correr
-- hasta que 82_/83_/84_ estén APLICADOS en la base (este ensayo sólo aplica 85_ encima), y sólo con OK
-- explícito del usuario y revisión de security.
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <este archivo>   (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de una transacción que termina en ROLLBACK. Requisitos: existe un usuario activo asignado hoy
-- al puesto es_administrador_generico (sólo como autor de las asignaciones de fixture).
-- Las secuencias no son transaccionales: las asignaciones de fixture consumen employee_no reales (huecos
-- cosméticos); por eso el ensayo hace ALTER SEQUENCE ... RESTART WITH 1 al inicio SÓLO si aún no hay altas
-- (transaccional: el ROLLBACK restaura la secuencia real).
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
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/85_tiempo_terminal_baja_por_caducidad.sql

-- ---------- fixtures y helpers (como dueño) ----------
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

-- Ejecuta p_sql con el rol dado. p_esperado: 'ok' | 'error' | SQLSTATE exacto; p_hint opcional.
CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_hint text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
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

-- Llama una función que devuelve jsonb como p_rol y evalúa p_check (expresión sobre $1).
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

-- Persona SINTÉTICA activa (dentro de la transacción) y 6 terminales de fixture (una alta por terminal).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXC1', 'XEXX010101C1', '99999999992', 'Sintetica', 'Caducidad', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'persona_c', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXC1';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'persona_c' ON CONFLICT DO NOTHING;
INSERT INTO tiempo.terminal (terminal_id, nombre) VALUES
  ('ENS85-VENC', 'vencida'), ('ENS85-NOVENC', 'no vencida'), ('ENS85-PEND', 'pendiente_alta'),
  ('ENS85-ACT', 'activo'), ('ENS85-SINAUTOR', 'sin autor'), ('ENS85-ERR', 'vencida con error reciente');

-- Helpers de fixture: movimientos de bitácora con creado_en explícito, SIEMPRE por el trigger (como dueño), en
-- el orden lógico de cada alta.
CREATE FUNCTION pg_temp.asignar(p_serie text, p_hace interval) RETURNS void AS $$
  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, creado_en)
  SELECT t.id, (SELECT v::uuid FROM _ens WHERE k = 'persona_c'), 'asignado', 'web',
         (SELECT v::uuid FROM _ens WHERE k = 'auth_uid'), now() - p_hace
  FROM tiempo.terminal t WHERE t.terminal_id = p_serie;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.mover(p_serie text, p_tipo text, p_hace interval, p_huellas integer DEFAULT NULL, p_detalle text DEFAULT NULL)
RETURNS void AS $$
  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, huellas_capturadas, detalle, origen, creado_en)
  SELECT tu.id, tu.terminal_id, tu.persona_id, p_tipo, p_huellas::smallint, p_detalle, 'terminal', now() - p_hace
  FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id WHERE t.terminal_id = p_serie;
$$ LANGUAGE sql;

-- VENC: asignada hace 30 h, usuario_creado hace 25 h (> 24 h)             -> debe caducar con 24 h
SELECT pg_temp.asignar('ENS85-VENC', interval '30 hours');
SELECT pg_temp.mover('ENS85-VENC', 'usuario_creado', interval '25 hours');
-- NOVENC: asignada hace 30 h, usuario_creado hace 23 h (< 24 h)          -> NO caduca con 24 h, sí con 22 h
SELECT pg_temp.asignar('ENS85-NOVENC', interval '30 hours');
SELECT pg_temp.mover('ENS85-NOVENC', 'usuario_creado', interval '23 hours');
-- PEND: sólo asignada hace 30 h (pendiente_alta)                          -> intacta
SELECT pg_temp.asignar('ENS85-PEND', interval '30 hours');
-- ACT: asignada, usuario_creado hace 25 h y huella hace 24 h (activo)     -> intacta
SELECT pg_temp.asignar('ENS85-ACT', interval '30 hours');
SELECT pg_temp.mover('ENS85-ACT', 'usuario_creado', interval '25 hours');
SELECT pg_temp.mover('ENS85-ACT', 'huella_capturada', interval '24 hours', 2);
-- ERR: igual que VENC pero con un movimiento 'error' RECIENTE: actualizado_en queda en "ahora" y aun así
-- caduca (el plazo se mide con el usuario_creado de la bitácora, no con actualizado_en)
SELECT pg_temp.asignar('ENS85-ERR', interval '30 hours');
SELECT pg_temp.mover('ENS85-ERR', 'usuario_creado', interval '26 hours');
SELECT pg_temp.mover('ENS85-ERR', 'error', interval '1 minute', NULL, 'lector ocupado');
-- SINAUTOR: alta en esperando_huella SIN movimiento 'asignado' en la bitácora (fixture como dueño: la fila
-- viva se inserta directo en pendiente_alta y luego el trigger la mueve con usuario_creado hace 25 h)
INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado)
SELECT t.id, (SELECT v::uuid FROM _ens WHERE k = 'persona_c'), 999001, 'pendiente_alta'
FROM tiempo.terminal t WHERE t.terminal_id = 'ENS85-SINAUTOR';
SELECT pg_temp.mover('ENS85-SINAUTOR', 'usuario_creado', interval '25 hours');

CREATE FUNCTION pg_temp.estado_de(p_serie text) RETURNS text AS $$
  SELECT tu.estado FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id WHERE t.terminal_id = p_serie;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.n_bajas(p_serie text) RETURNS bigint AS $$
  SELECT count(*) FROM tiempo.bitacora_movimiento_terminal_usuario b JOIN tiempo.terminal t ON t.id = b.terminal_id
  WHERE t.terminal_id = p_serie AND b.tipo_movimiento = 'baja_solicitada';
$$ LANGUAGE sql;

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k = 'auth_uid')$$);
SELECT pg_temp.verifica('01 fixture: estados de partida',
  $$SELECT pg_temp.estado_de('ENS85-VENC') = 'esperando_huella' AND pg_temp.estado_de('ENS85-NOVENC') = 'esperando_huella'
      AND pg_temp.estado_de('ENS85-PEND') = 'pendiente_alta' AND pg_temp.estado_de('ENS85-ACT') = 'activo'
      AND pg_temp.estado_de('ENS85-ERR') = 'esperando_huella' AND pg_temp.estado_de('ENS85-SINAUTOR') = 'esperando_huella'$$);
SELECT pg_temp.verifica('01b fixture: la alta ERR tiene actualizado_en reciente (el error lo movió)',
  $$SELECT tu.actualizado_en > now() - interval '1 hour' FROM tiempo.terminal_usuario tu
    JOIN tiempo.terminal t ON t.id = tu.terminal_id WHERE t.terminal_id = 'ENS85-ERR'$$);

-- Piso y entrada inválida
SELECT pg_temp.caso('10 p_horas = 0 -> 22023 horas_invalidas', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(0)', '22023', 'horas_invalidas');
SELECT pg_temp.caso('10b p_horas negativo -> 22023', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(-5)', '22023', 'horas_invalidas');
SELECT pg_temp.caso('10c p_horas NULL -> 22023', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(NULL)', '22023', 'horas_invalidas');
SELECT pg_temp.caso('10e p_horas = 1 (debajo del piso de 4) -> 22023', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(1)', '22023', 'horas_invalidas');
SELECT pg_temp.caso('10f p_horas = 2 -> 22023', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(2)', '22023', 'horas_invalidas');
SELECT pg_temp.caso('10g p_horas = 3 -> 22023', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(3)', '22023', 'horas_invalidas');
SELECT pg_temp.verifica('10d las llamadas inválidas no emitieron nada',
  $$SELECT pg_temp.n_bajas('ENS85-VENC') = 0 AND pg_temp.n_bajas('ENS85-NOVENC') = 0 AND pg_temp.n_bajas('ENS85-ERR') = 0$$);

-- Corrida por defecto (24 h): caducan VENC y ERR (2); SINAUTOR no (sin autor); NOVENC/PEND/ACT intactas.
SELECT pg_temp.rpc('20 caducidad por defecto (24 h): emite 2 bajas (VENC y ERR)', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad())', $c$ ($1 #>> '{}')::integer = 2 $c$);
SELECT pg_temp.verifica('21 VENC y ERR quedaron en pendiente_baja',
  $$SELECT pg_temp.estado_de('ENS85-VENC') = 'pendiente_baja' AND pg_temp.estado_de('ENS85-ERR') = 'pendiente_baja'$$);
SELECT pg_temp.verifica('22 NOVENC (23 h), PEND (pendiente_alta) y ACT (activo) siguen intactas',
  $$SELECT pg_temp.estado_de('ENS85-NOVENC') = 'esperando_huella' AND pg_temp.estado_de('ENS85-PEND') = 'pendiente_alta'
      AND pg_temp.estado_de('ENS85-ACT') = 'activo'
      AND pg_temp.n_bajas('ENS85-NOVENC') = 0 AND pg_temp.n_bajas('ENS85-PEND') = 0 AND pg_temp.n_bajas('ENS85-ACT') = 0$$);
SELECT pg_temp.verifica('23 SINAUTOR no se tocó (sin movimiento asignado no hay autor derivable)',
  $$SELECT pg_temp.estado_de('ENS85-SINAUTOR') = 'esperando_huella' AND pg_temp.n_bajas('ENS85-SINAUTOR') = 0$$);
SELECT pg_temp.verifica('24 la baja de VENC: origen web, autor = el del movimiento asignado, detalle fijo, employee_no de la alta',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_movimiento_terminal_usuario b
    JOIN tiempo.terminal t ON t.id = b.terminal_id
    WHERE t.terminal_id = 'ENS85-VENC' AND b.tipo_movimiento = 'baja_solicitada' AND b.origen = 'web'
      AND b.registrado_por = (SELECT a.registrado_por FROM tiempo.bitacora_movimiento_terminal_usuario a
                               WHERE a.terminal_usuario_id = b.terminal_usuario_id AND a.tipo_movimiento = 'asignado')
      AND b.registrado_por = (SELECT v::uuid FROM _ens WHERE k = 'auth_uid')
      AND b.detalle = 'baja automática: sin huella tras 24 horas'
      AND b.employee_no = (SELECT tu.employee_no FROM tiempo.terminal_usuario tu WHERE tu.id = b.terminal_usuario_id)$$);
SELECT pg_temp.verifica('25 la baja de ERR existe aunque su error reciente movió actualizado_en (el plazo es el de la bitácora)',
  $$SELECT pg_temp.n_bajas('ENS85-ERR') = 1$$);

-- Idempotencia
SELECT pg_temp.rpc('30 segunda corrida seguida -> 0 (idempotente)', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad())', $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.verifica('30b no hay una segunda baja en VENC ni en ERR',
  $$SELECT pg_temp.n_bajas('ENS85-VENC') = 1 AND pg_temp.n_bajas('ENS85-ERR') = 1$$);

-- El parámetro cuenta: con 22 h la alta NOVENC (usuario_creado hace 23 h) también caduca; el piso de 4 h es válido y no mueve nada más.
SELECT pg_temp.rpc('31 p_horas = 22: caduca NOVENC (23 h) y nada más', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad(22))', $c$ ($1 #>> '{}')::integer = 1 $c$);
SELECT pg_temp.verifica('31b NOVENC en pendiente_baja con detalle de 22 horas; PEND y ACT intactas',
  $$SELECT pg_temp.estado_de('ENS85-NOVENC') = 'pendiente_baja'
      AND (SELECT b.detalle FROM tiempo.bitacora_movimiento_terminal_usuario b JOIN tiempo.terminal t ON t.id = b.terminal_id
           WHERE t.terminal_id = 'ENS85-NOVENC' AND b.tipo_movimiento = 'baja_solicitada') = 'baja automática: sin huella tras 22 horas'
      AND pg_temp.estado_de('ENS85-PEND') = 'pendiente_alta' AND pg_temp.estado_de('ENS85-ACT') = 'activo'$$);
SELECT pg_temp.rpc('31c p_horas = 4 (el piso) es válido y ya no queda nada que caducar -> 0', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad(4))', $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.verifica('31d SINAUTOR sigue sin tocarse (sin autor, incluso con el piso de 4 h)',
  $$SELECT pg_temp.estado_de('ENS85-SINAUTOR') = 'esperando_huella' AND pg_temp.n_bajas('ENS85-SINAUTOR') = 0$$);

-- Una alta que recibió huella antes de la corrida ya no está en esperando_huella: no se toca (cubierto por ACT);
-- y una alta ya en baja/pendiente_baja no se vuelve a pedir (cubierto por la idempotencia).

-- EXECUTE
SELECT pg_temp.caso('40 anon sin EXECUTE', 'anon', 'SELECT tiempo.fn_terminal_baja_por_caducidad(24)', '42501');
SELECT pg_temp.caso('40b authenticated sin EXECUTE', 'authenticated', 'SELECT tiempo.fn_terminal_baja_por_caducidad(24)', '42501');
SELECT pg_temp.caso('40c service_role sí puede', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(24)', 'ok');


-- Tope por corrida (security): 55 altas vencidas -> 50 en la primera corrida, 5 en la segunda, 0 en la tercera.
-- Las 55 terminales de fixture se crean aquí, al final, para no alterar las cuentas exactas de los casos anteriores.
INSERT INTO tiempo.terminal (terminal_id, nombre)
SELECT 'ENS85-T' || lpad(g::text, 3, '0'), 'tope ' || g FROM generate_series(1, 55) g;
SELECT pg_temp.asignar('ENS85-T' || lpad(g::text, 3, '0'), interval '30 hours') FROM generate_series(1, 55) g;
SELECT pg_temp.mover('ENS85-T' || lpad(g::text, 3, '0'), 'usuario_creado', interval '25 hours') FROM generate_series(1, 55) g;
SELECT pg_temp.verifica('50 fixture: 55 altas en esperando_huella con usuario_creado hace 25 h',
  $$SELECT count(*) = 55 FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id
    WHERE t.terminal_id LIKE 'ENS85-T0%' AND tu.estado = 'esperando_huella'$$);
SELECT pg_temp.rpc('51 tope por corrida: la primera llamada emite exactamente 50 bajas', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad())', $c$ ($1 #>> '{}')::integer = 50 $c$);
SELECT pg_temp.verifica('51b quedan 5 altas en esperando_huella entre las 55',
  $$SELECT count(*) = 5 FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id
    WHERE t.terminal_id LIKE 'ENS85-T0%' AND tu.estado = 'esperando_huella'$$);
SELECT pg_temp.rpc('52 la segunda llamada emite las 5 restantes', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad())', $c$ ($1 #>> '{}')::integer = 5 $c$);
SELECT pg_temp.rpc('53 la tercera llamada no emite nada', 'service_role',
  'to_jsonb(tiempo.fn_terminal_baja_por_caducidad())', $c$ ($1 #>> '{}')::integer = 0 $c$);
SELECT pg_temp.verifica('53b las 55 quedaron en pendiente_baja con una sola baja cada una',
  $$SELECT count(*) = 55 AND bool_and(pg_temp.n_bajas(t.terminal_id) = 1) FROM tiempo.terminal_usuario tu JOIN tiempo.terminal t ON t.id = tu.terminal_id
    WHERE t.terminal_id LIKE 'ENS85-T0%' AND tu.estado = 'pendiente_baja'$$);

-- RESIDUAL anotado (no se puede simular en un solo script): la carrera con huella_capturada. El 85_ re-lee cada
-- alta FOR UPDATE exigiendo estado = 'esperando_huella' antes de emitir; el caso de ACT ('activo' en el momento de la
-- corrida) comprueba que una alta que ya pasó a activo no se toca, pero la ventana entre el SELECT del cursor y el
-- INSERT sólo se cubre con dos sesiones concurrentes (revisión de security, 2026-10-06).
-- Verificación de verificar_ddl.sql (secciones nuevas de 85_: 29, 30, 36, 37 y 40; las demás se corrieron con 82-84)
\ir /tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/verificar_85.sql

-- ---------- resultado ----------
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;

ROLLBACK;
