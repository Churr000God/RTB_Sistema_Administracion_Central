-- Ensayo de 90_tiempo_terminal_anomalias.sql (con 88_, de la que depende por usuario_creado_en y por el flujo de altas). NO es DDL
-- versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_90.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 88_ y 90_ ENCIMA de lo ya aplicado (87_). Terminales, personas y marcas SINTÉTICAS; el admin real
-- sólo es caller. Las marcas se insertan como dueño (las de la terminal real no se tocan). 88_ exige terminal_usuario y la bitácora vacías.
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
\ir ../ddl/88_tiempo_terminal_consentimiento.sql
\ir ../ddl/90_tiempo_terminal_anomalias.sql

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
CREATE FUNCTION pg_temp.asignar(p_persona text, p_term text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$, p_term, p_persona, (SELECT v FROM _ens WHERE k='auth_uid'), pg_temp.vig());
$$ LANGUAGE sql;
-- Movimiento del Pi como dueño (equivale a service_role): usuario_creado / baja_confirmada de la alta VIGENTE de la persona.
CREATE FUNCTION pg_temp.mov(p_tipo text, p_persona text, p_term text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen)
    SELECT tu.id, tu.terminal_id, tu.persona_id, %L, 'terminal' FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = %L::uuid AND tu.terminal_id = %L::bigint AND tu.estado <> 'baja' ORDER BY tu.id DESC LIMIT 1$f$, p_tipo, p_persona, p_term);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.baja(p_persona text, p_term text) RETURNS void AS $$
BEGIN
  EXECUTE format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
    SELECT tu.id, tu.terminal_id, tu.persona_id, 'baja_solicitada', 'web', %L::uuid FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = %L::uuid AND tu.terminal_id = %L::bigint AND tu.estado <> 'baja' ORDER BY tu.id DESC LIMIT 1$f$, (SELECT v FROM _ens WHERE k='auth_uid'), p_persona, p_term);
  EXECUTE pg_temp.mov('baja_confirmada', p_persona, p_term);
END;
$$ LANGUAGE plpgsql;
-- Marca sintética de una terminal (serie): momento = now() + p_min minutos.
CREATE FUNCTION pg_temp.mk(p_persona text, p_serie text, p_seq bigint, p_min numeric) RETURNS void AS $$
  INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (p_persona::uuid, p_serie, p_seq, now() + p_min * interval '1 minute', '+00:00', 'sincronizado', 'ens', 'terminal');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.mkt(p_persona text, p_serie text, p_seq bigint, p_ts timestamptz) RETURNS void AS $$
  INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (p_persona::uuid, p_serie, p_seq, p_ts, '+00:00', 'sincronizado', 'ens', 'terminal');
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.anom(p_term text, p_cat text, p_extra text DEFAULT '') RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_anomalias(%s::bigint, %L, now() - interval ''1 day'', now() + interval ''2 days'' %s)', p_term, p_cat, p_extra);
$$ LANGUAGE sql;

-- Terminales sintéticas A y B; personas P1..P5.
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-90A', 'Terminal A', 'DS-K1A8503EF-B'), ('ENSAYO-90B', 'Terminal B', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'tA', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-90A';
INSERT INTO _ens SELECT 'tB', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-90B';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXXC' || i, 'XEXX010101C' || i, '9999990' || lpad((20 + i)::text, 4, '0'), 'SinteticaC' || i, 'Ensayo90', DATE '2000-01-01', CURRENT_DATE FROM generate_series(1, 5) i;
INSERT INTO _ens SELECT 'P' || i, id::text FROM generate_series(1, 5) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXXC' || i;
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k LIKE 'P_' ON CONFLICT DO NOTHING;
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', 'rh90@invalid.test' FROM _ens WHERE k = 'auth_rh';

-- Altas en A: P1 (alta -> baja confirmada), P2 (alta viva), P3 (alta -> baja -> NUEVA alta creada en el aparato), P4 (alta viva, sólo picos).
SELECT pg_temp.verifica('00 fixture: existe el caller admin y las terminales', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND EXISTS (SELECT 1 FROM _ens WHERE k='tA') AND EXISTS (SELECT 1 FROM _ens WHERE k='tB')$$);
DO $do$
DECLARE tA text := (SELECT v FROM _ens WHERE k='tA'); p text;
BEGIN
  FOREACH p IN ARRAY ARRAY['P1','P2','P3','P4'] LOOP
    EXECUTE pg_temp.asignar((SELECT v FROM _ens WHERE k = p), tA);
    EXECUTE pg_temp.mov('usuario_creado', (SELECT v FROM _ens WHERE k = p), tA);
  END LOOP;
  PERFORM pg_temp.baja((SELECT v FROM _ens WHERE k='P1'), tA);
  PERFORM pg_temp.baja((SELECT v FROM _ens WHERE k='P3'), tA);
  -- P3 vuelve: nueva alta creada en el aparato
  EXECUTE pg_temp.asignar((SELECT v FROM _ens WHERE k='P3'), tA);
  EXECUTE pg_temp.mov('usuario_creado', (SELECT v FROM _ens WHERE k='P3'), tA);
END
$do$;

-- Marcas (seq contiguas 1..9, salto 10..13 (4 faltan), 14..15, salto 20..29 (10 faltan), 30), todas en A salvo las de B.
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P1'), 'ENSAYO-90A', 1, 60);   -- P1 posterior a su baja -> anomalía
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P1'), 'ENSAYO-90A', 2, -120); -- P1 ANTERIOR a su baja -> no (la baja es now())
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 3, 60);   -- P2 alta viva -> no
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P3'), 'ENSAYO-90A', 4, 60);   -- P3 con alta NUEVA ya creada -> no
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P5'), 'ENSAYO-90A', 5, 60);   -- P5 sin alta: no es de esta categoría
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P1'), 'ENSAYO-90B', 1, 60);   -- P1 en la OTRA terminal (B): jamás en el tablero de A
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 6, 61);
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 7, 62);
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 8, 63);
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 9, 64);
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 14, 65);  -- salto 10..13 (faltan 4)
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 15, 66);
SELECT pg_temp.mk((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 30, 67);  -- salto 16..29 (faltan 14)
-- Picos (horas enteras alineadas con date_trunc para que cada grupo caiga en UNA sola hora): P4 con 12 marcas (>10), P2 con exactamente 10 (no es pico) y 1 001 marcas de P5 en otra hora (terminal > 1 000/h).
SELECT pg_temp.mkt((SELECT v FROM _ens WHERE k='P4'), 'ENSAYO-90A', 100 + g, date_trunc('hour', now()) + interval '10 hours 10 minutes' + g * interval '10 seconds') FROM generate_series(1, 12) g;
SELECT pg_temp.mkt((SELECT v FROM _ens WHERE k='P2'), 'ENSAYO-90A', 200 + g, date_trunc('hour', now()) + interval '20 hours 10 minutes' + g * interval '10 seconds') FROM generate_series(1, 10) g;
SELECT pg_temp.mkt((SELECT v FROM _ens WHERE k='P5'), 'ENSAYO-90A', 1000 + g, date_trunc('hour', now()) + interval '30 hours 10 minutes' + g * interval '1 second') FROM generate_series(1, 1001) g;

-- ---------- casos ----------
-- A. Marcas posteriores a la baja
SELECT pg_temp.rpc('10 marcas_posteriores_a_baja: sólo la marca 1 de P1 (la posterior a su baja); no P2, no P3 (alta nueva ya creada), no P5, no la de B', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'marcas_posteriores_a_baja', ', 50'),
  $c$ ($1->>'total')::int = 1 AND $1->'items'->0->>'persona_id' = (SELECT v FROM _ens WHERE k='P1') AND ($1->'items'->0->>'marca_en') IS NOT NULL AND ($1->'items'->0->>'baja_confirmada_en') IS NOT NULL $c$, '-');
SELECT pg_temp.rpc('10b la misma categoría en la terminal B: 0 (no hay altas ahí)', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tB'), 'marcas_posteriores_a_baja', ', 50'), $c$ ($1->>'total')::int = 0 AND jsonb_array_length($1->'items') = 0 $c$, '-');

-- B. Picos de tasa
SELECT pg_temp.rpc('20 picos_de_tasa: P4 (12 en una hora) y la terminal (1 001 en una hora) y, por esas 1 001, también P5; P2 con exactamente 10 NO', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ', 50'),
  $c$ ($1->>'total')::int = 3
      AND EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->>'persona_id' = (SELECT v FROM _ens WHERE k='P4') AND (i->>'marcas')::int = 12 AND (i->>'limite')::int = 10)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->>'persona_id' = (SELECT v FROM _ens WHERE k='P5') AND (i->>'marcas')::int = 1001)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->'persona_id' = 'null'::jsonb AND (i->>'marcas')::int = 1001 AND (i->>'limite')::int = 1000)
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->>'persona_id' = (SELECT v FROM _ens WHERE k='P2')) $c$, '-');

-- C. Huecos de secuencia
SELECT pg_temp.rpc('30 huecos_de_secuencia: dos saltos en A (faltan 4: 10..13; y faltan 14: 16..29); el salto grande hacia 100 y 200 también cuenta; ordenados por desde descendente', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'huecos_de_secuencia', ', 50'),
  $c$ EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE (i->>'desde')::int = 10 AND (i->>'hasta')::int = 13 AND (i->>'faltan')::int = 4)
      AND EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE (i->>'desde')::int = 16 AND (i->>'hasta')::int = 29 AND (i->>'faltan')::int = 14)
      AND (SELECT array_agg((i->>'desde')::bigint) FROM jsonb_array_elements($1->'items') i) = (SELECT array_agg(d ORDER BY d DESC) FROM (SELECT (i->>'desde')::bigint d FROM jsonb_array_elements($1->'items') i) s) $c$, '-');
SELECT pg_temp.rpc('30b en la terminal B (una sola marca) no hay huecos', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tB'), 'huecos_de_secuencia', ', 50'), $c$ ($1->>'total')::int = 0 $c$, '-');

-- D. Paginación y validaciones
SELECT pg_temp.rpc('40 paginación: límite 1 -> 1 item pero el total completo', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'huecos_de_secuencia', ', 1'), $c$ jsonb_array_length($1->'items') = 1 AND ($1->>'total')::int >= 2 $c$, '-');
SELECT pg_temp.rpc('40b desplazamiento mayor que el total -> items vacío, total intacto', 'service_role',
  pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'huecos_de_secuencia', ', 5, 1000'), $c$ jsonb_array_length($1->'items') = 0 AND ($1->>'total')::int >= 2 $c$, '-');
SELECT pg_temp.caso('41 terminal inexistente -> 22023 terminal_invalida', 'service_role', 'SELECT ' || pg_temp.anom('999999999', 'picos_de_tasa', ''), '22023', '-', 'terminal_invalida');
SELECT pg_temp.caso('41b categoría desconocida -> 22023 categoria_invalida', 'service_role', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'otra', ''), '22023', '-', 'categoria_invalida');
SELECT pg_temp.caso('41c ventana de más de 90 días -> 22023 ventana_invalida', 'service_role',
  format('SELECT tiempo.fn_terminal_anomalias(%s::bigint, %L, now() - interval ''91 days'', now())', (SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa'), '22023', '-', 'ventana_invalida');
SELECT pg_temp.caso('41d hasta anterior a desde -> ventana_invalida', 'service_role',
  format('SELECT tiempo.fn_terminal_anomalias(%s::bigint, %L, now(), now() - interval ''1 day'')', (SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa'), '22023', '-', 'ventana_invalida');
SELECT pg_temp.caso('41e ventana con NULL -> ventana_invalida', 'service_role',
  format('SELECT tiempo.fn_terminal_anomalias(%s::bigint, %L, NULL, now())', (SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa'), '22023', '-', 'ventana_invalida');
SELECT pg_temp.caso('41f límite 0 y 201 -> paginacion_invalida', 'service_role', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ', 0'), '22023', '-', 'paginacion_invalida');
SELECT pg_temp.caso('41g límite 201 -> paginacion_invalida', 'service_role', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ', 201'), '22023', '-', 'paginacion_invalida');
SELECT pg_temp.caso('41h desplazamiento negativo -> paginacion_invalida', 'service_role', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ', 5, -1'), '22023', '-', 'paginacion_invalida');
SELECT pg_temp.rpc('41i ventana de la terminal sin hallazgos (el pasado lejano) -> total 0', 'service_role',
  format('tiempo.fn_terminal_anomalias(%s::bigint, %L, now() - interval ''60 days'', now() - interval ''30 days'')', (SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa'), $c$ ($1->>'total')::int = 0 $c$, '-');

-- E. Privilegios
SELECT pg_temp.caso('50 authenticated (incluido el admin con todos los permisos) NO puede ejecutarla -> 42501', 'authenticated', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ''), '42501');
SELECT pg_temp.caso('50b anon -> 42501', 'anon', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ''), '42501', '-');
SELECT pg_temp.caso('50c terminal_checador -> 42501', 'terminal_checador', 'SELECT ' || pg_temp.anom((SELECT v FROM _ens WHERE k='tA'), 'picos_de_tasa', ''), '42501', '-');
SELECT pg_temp.verifica('51 la función no modificó nada (es de sólo lectura): mismas marcas que las insertadas',
  $$SELECT count(*) = 1036 FROM tiempo.marca WHERE terminal_id IN ('ENSAYO-90A', 'ENSAYO-90B')$$);

\ir verificar_90.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
