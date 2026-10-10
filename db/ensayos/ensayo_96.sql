-- Ensayo de 96_tiempo_logs_sin_identidad_y_endurece_anon.sql (SOLO la parte A: logs sin identidad; la parte B de anon no está escrita). NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo
-- corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_96.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 96_ ENCIMA de lo ya aplicado (88_-95_: 94_ y 95_ están aplicados en la base real desde el 9-oct-2026). Terminal, personas, usuarios, altas y marcas SINTÉTICOS; el admin real
-- sólo es caller (y, en un caso, persona de una alta sintética); todo se revierte (las secuencias identity avanzan igual).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
GRANT ALL ON _ens, _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

\ir ../ddl/96_tiempo_logs_sin_identidad_y_endurece_anon.sql

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
  PERFORM set_config('request.jwt.claims', '', true);
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
CREATE FUNCTION pg_temp.tu(p_k text) RETURNS bigint AS $$
  SELECT id FROM tiempo.terminal_usuario WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = p_k) ORDER BY id DESC LIMIT 1;
$$ LANGUAGE sql;
-- 'asignado' por un autor explícito.
CREATE FUNCTION pg_temp.asignar_como(p_persona text, p_autor text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid, %s)$f$,
    (SELECT v FROM _ens WHERE k='terminal'), p_persona, p_autor, pg_temp.vig());
$$ LANGUAGE sql;
-- Movimiento del Pi vía RPC.
CREATE FUNCTION pg_temp.mov_rpc(p_k text, p_tipo text, p_huellas integer) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_movimiento_registrar(%s::bigint, %s::bigint, %L::text, %s, NULL::text)',
                (SELECT v FROM _ens WHERE k='terminal'), pg_temp.tu(p_k), p_tipo, COALESCE(p_huellas::text, 'NULL::integer'));
$$ LANGUAGE sql;
-- INSERT web de huella_confirmada_manual.
CREATE FUNCTION pg_temp.confirmar(p_k text, p_autor text, p_nota text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle)
    VALUES (%s, %L::bigint, %L::uuid, 'huella_confirmada_manual', 'web', %L::uuid, %L)$f$,
    pg_temp.tu(p_k), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k = p_k), p_autor, p_nota);
$$ LANGUAGE sql;
-- Marca sintética de la persona p_k en la terminal de ensayo; guarda su id en _ens como 'M'||p_nombre. p_recepcion = momento_recepcion.
CREATE FUNCTION pg_temp.marca(p_nombre text, p_k text, p_seq bigint, p_recepcion timestamptz DEFAULT now(), p_origen text DEFAULT 'terminal',
                              p_serie text DEFAULT 'ENSAYO-94') RETURNS void AS $$
BEGIN
  WITH ins AS (
    INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen, momento_recepcion)
    VALUES ((SELECT v::uuid FROM _ens WHERE k = p_k), p_serie, CASE WHEN p_origen = 'terminal' THEN p_seq END,
            p_recepcion, '-06:00', 'sincronizado', 'ens94', p_origen, p_recepcion)
    RETURNING id)
  INSERT INTO _ens SELECT 'M' || p_nombre, id::text FROM ins;
END;
$$ LANGUAGE plpgsql;
-- INSERT de huella_inferida (lo hace el RPC de marcas como dueño/service_role). p_extra_cols/p_extra_vals permiten romper CHECKs a propósito.
CREATE FUNCTION pg_temp.inferir(p_k text, p_marca text, p_autor text DEFAULT NULL, p_huellas integer DEFAULT NULL, p_origen text DEFAULT 'terminal') RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, detalle, origen, registrado_por, huellas_capturadas, marca_id)
    VALUES (%s, %L::bigint, %L::uuid, (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = %s), 'huella_inferida', 'x', %L, %s, %s, %s)$f$,
    pg_temp.tu(p_k), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k = p_k), pg_temp.tu(p_k), p_origen,
    COALESCE(quote_literal(p_autor) || '::uuid', 'NULL'), COALESCE(p_huellas::text, 'NULL'), COALESCE((SELECT v FROM _ens WHERE k = p_marca), 'NULL'));
$$ LANGUAGE sql;
-- Alta completa hasta esperando_huella: asignado (autor p_autor) + usuario_creado del Pi. p_antiguedad = hace cuánto se creó el usuario en el aparato.
CREATE FUNCTION pg_temp.alta(p_k text, p_autor text, p_antiguedad interval DEFAULT '0') RETURNS void AS $$
BEGIN
  EXECUTE pg_temp.asignar_como((SELECT v FROM _ens WHERE k = p_k), p_autor);
  IF p_antiguedad = interval '0' THEN
    PERFORM tiempo.fn_terminal_movimiento_registrar((SELECT v::bigint FROM _ens WHERE k='terminal'), pg_temp.tu(p_k), 'usuario_creado', NULL, NULL);
  ELSE
    INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, origen, creado_en)
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no, 'usuario_creado', 'terminal', now() - p_antiguedad
    FROM tiempo.terminal_usuario tu WHERE tu.id = pg_temp.tu(p_k);
  END IF;
END;
$$ LANGUAGE plpgsql;

-- ---------- ayudantes de 96_ ----------
CREATE FUNCTION pg_temp.est(p_k text) RETURNS text AS $$ SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu(p_k) $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.n_rech() RETURNS bigint AS $$ SELECT count(*) FROM tiempo.marca_rechazada WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k='terminal') $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.rechazar(p_evento jsonb, p_codigo text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_rechazo_registrar(%s::bigint, %L::jsonb, %L::text)', (SELECT v FROM _ens WHERE k='terminal'), p_evento::text, p_codigo);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.baja_por(p_k text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_baja_por_persona_inactiva(%L::uuid)', (SELECT v FROM _ens WHERE k = p_k));
$$ LANGUAGE sql;
-- Réplica EXACTA de la lógica de la sección 59 de verificar_ddl.sql, sobre un texto de función.
CREATE FUNCTION pg_temp.flag59(p_src text) RETURNS boolean AS $$
  WITH s AS (SELECT string_to_array(regexp_replace(p_src, '--[^\n]*', '', 'g'), '''') AS partes),
       t AS (SELECT (SELECT string_agg(CASE WHEN u.o % 2 = 0 THEN replace(u.e, ';', ',') ELSE u.e END, '''' ORDER BY u.o) FROM unnest(partes) WITH ORDINALITY AS u(e, o)) AS s1,
                    (SELECT string_agg(CASE WHEN u.o % 2 = 0 THEN '' ELSE u.e END, '''' ORDER BY u.o) FROM unnest(partes) WITH ORDINALITY AS u(e, o)) AS s2 FROM s)
  SELECT s1 ~* 'RAISE\s+(WARNING|NOTICE|LOG|INFO)[^;]*(employee_no|persona_id|persona %)'
      OR s2 ~* 'RAISE\s+(WARNING|NOTICE|LOG|INFO)[^;]*(\mv_emp\M|\mv_persona\M|\mp_persona\M|\mp_persona_id\M|\mrec\.(persona_id|employee_no)\M|NEW\.employee_no|NEW\.persona_id)'
  FROM t;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.suspender(p_k text) RETURNS void AS $$
  INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por)
  VALUES ((SELECT v::uuid FROM _ens WHERE k = p_k), 'suspension', now(), 'ensayo96', (SELECT v::uuid FROM _ens WHERE k='auth_uid'));
$$ LANGUAGE sql;

-- ---------- fixture ----------
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-96', 'Terminal de ensayo 96', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-96';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXV' || lpad(i::text, 2, '0'), 'XEXV010101' || lpad(i::text, 2, '0'), '9999997' || lpad(i::text, 4, '0'), 'SinteticaV' || i, 'Ensayo96', DATE '2000-01-01', CURRENT_DATE
FROM generate_series(1, 4) i;
INSERT INTO _ens SELECT 'B' || i, p.id::text FROM generate_series(1, 4) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXV' || lpad(i::text, 2, '0');
-- Altas (esperando_huella) de B1..B3; B4 queda activa y sin alta.
SELECT pg_temp.alta('B' || i, (SELECT v FROM _ens WHERE k='auth_uid')) FROM generate_series(1, 3) i;
SELECT pg_temp.verifica('00 fixture: caller admin, terminal y 3 altas en esperando_huella',
  $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND (SELECT count(*) FROM tiempo.terminal_usuario WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k='terminal') AND estado = 'esperando_huella') = 3$$);

-- ---------- A. fn_terminal_rechazo_registrar ----------
SELECT pg_temp.verifica('10 firma sin cambio: (bigint, jsonb, text) -> void', $$SELECT pg_get_function_identity_arguments(p.oid) = 'p_terminal_id bigint, p_evento jsonb, p_codigo text' AND p.prorettype = 'void'::regtype
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_rechazo_registrar'$$);
SELECT pg_temp.verifica('11 atributos: SECURITY DEFINER, search_path = tiempo, personas, pg_temp y EXECUTE para nadie (ni PUBLIC, anon, authenticated, service_role, terminal_checador)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_rechazo_registrar'$$);
SELECT pg_temp.caso('11b authenticated NO la ejecuta (42501)', 'authenticated', 'SELECT ' || pg_temp.rechazar('{}'::jsonb, 'no_enrolado'), '42501');
SELECT pg_temp.caso('11c anon NO la ejecuta (42501)', 'anon', 'SELECT ' || pg_temp.rechazar('{}'::jsonb, 'no_enrolado'), '42501', '-');
SELECT pg_temp.caso('11d service_role NO la ejecuta (42501)', 'service_role', 'SELECT ' || pg_temp.rechazar('{}'::jsonb, 'no_enrolado'), '42501', '-');
-- 12) Inserta la evidencia con todos los campos defendidos.
SELECT pg_temp.caso('12 rechazo definitivo no_enrolado: se registra (como dueño, la vía del RPC DEFINER)', current_user::text,
  'SELECT ' || pg_temp.rechazar(jsonb_build_object('evento_id', '33333333-3333-4333-8333-333333333333', 'employee_no', 7, 'secuencia_local', 5, 'momento_dispositivo', '2026-10-09T12:00:00Z', 'desfase_local', '-06:00', 'estado_reloj', 'sincronizado'), 'no_enrolado'), 'ok', '-');
SELECT pg_temp.verifica('12b ... y la fila trae terminal, evento_id, employee_no 7, secuencia 5, desfase, reloj y código (el dato de evidencia sigue guardándose; solo el LOG no lleva identidad)',
  $$SELECT count(*) = 1 FROM tiempo.marca_rechazada WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k='terminal') AND evento_id = '33333333-3333-4333-8333-333333333333'
      AND employee_no = 7 AND secuencia_local = 5 AND desfase_local = '-06:00' AND estado_reloj = 'sincronizado' AND codigo = 'no_enrolado'$$);
SELECT pg_temp.caso('12c el mismo evento otra vez: ON CONFLICT DO NOTHING (no duplica)', current_user::text,
  'SELECT ' || pg_temp.rechazar(jsonb_build_object('evento_id', '33333333-3333-4333-8333-333333333333', 'employee_no', 7), 'no_enrolado'), 'ok', '-');
SELECT pg_temp.verifica('12d ... sigue habiendo una sola fila de ese evento', $$SELECT count(*) = 1 FROM tiempo.marca_rechazada WHERE evento_id = '33333333-3333-4333-8333-333333333333'$$);
-- 13) evento_id con basura: el LOG lo sanea a [0-9a-fA-F-] (se comprueba en la salida del script) y la fila queda con evento_id NULL.
SELECT pg_temp.caso('13 evento_id con basura (AB<x>-12): no revienta y el evento_id guardado es NULL', current_user::text,
  'SELECT ' || pg_temp.rechazar(jsonb_build_object('evento_id', 'AB<x>-12', 'employee_no', 8), 'forma_invalida'), 'ok', '-');
SELECT pg_temp.verifica('13b ... la fila existe con codigo forma_invalida y evento_id NULL', $$SELECT count(*) = 1 FROM tiempo.marca_rechazada WHERE terminal_id = (SELECT v::bigint FROM _ens WHERE k='terminal') AND codigo = 'forma_invalida' AND evento_id IS NULL AND employee_no = 8$$);
-- 14) código no reconocido: no se guarda.
SELECT pg_temp.verifica('14 snapshot del conteo antes del código desconocido', $$SELECT pg_temp.n_rech() = 2$$);
SELECT pg_temp.caso('14b código no reconocido: la función no falla', current_user::text, 'SELECT ' || pg_temp.rechazar(jsonb_build_object('evento_id', '44444444-4444-4444-8444-444444444444'), 'inventado'), 'ok', '-');
SELECT pg_temp.caso('14c código NULL: no falla', current_user::text, format('SELECT tiempo.fn_terminal_rechazo_registrar(%s::bigint, ''{}''::jsonb, NULL)', (SELECT v FROM _ens WHERE k='terminal')), 'ok', '-');
SELECT pg_temp.verifica('14d ... y no se guardó nada (siguen 2 filas)', $$SELECT pg_temp.n_rech() = 2$$);
-- 15) llamador de 95_: un lote del RPC de marcas con un empleado sin alta pasa por el rechazo y deja su evidencia.
SELECT pg_temp.rpc('15 llamador intacto: fn_marca_terminal_registrar rechaza como no_enrolado y registra la evidencia', 'service_role',
  format('tiempo.fn_marca_terminal_registrar(%s::bigint, %L::jsonb)', (SELECT v FROM _ens WHERE k='terminal'),
    jsonb_build_array(jsonb_build_object('evento_id', gen_random_uuid(), 'employee_no', 98765431, 'secuencia_local', 96001, 'momento_dispositivo', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'desfase_local', '-06:00', 'estado_reloj', 'sincronizado', 'version_software', 'ens96'))::text),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$, '-');
SELECT pg_temp.verifica('15b ... y quedó una fila nueva en marca_rechazada (3 en total)', $$SELECT pg_temp.n_rech() = 3$$);
-- 16) tope diario: con 5000 filas en 24 h ya no se guarda (WARNING marca_rechazada_tope en la salida).
INSERT INTO tiempo.marca_rechazada (terminal_id, evento_id, employee_no, codigo)
SELECT (SELECT v::bigint FROM _ens WHERE k='terminal'), NULL, 1, 'forma_invalida' FROM generate_series(1, 4997);
SELECT pg_temp.verifica('16 fixture del tope: 5000 filas en la ventana', $$SELECT pg_temp.n_rech() = 5000$$);
SELECT pg_temp.caso('16b con el tope alcanzado la función no falla', current_user::text, 'SELECT ' || pg_temp.rechazar(jsonb_build_object('evento_id', '55555555-5555-4555-8555-555555555555', 'employee_no', 9), 'no_enrolado'), 'ok', '-');
SELECT pg_temp.verifica('16c ... y no guardó la fila (siguen 5000)', $$SELECT pg_temp.n_rech() = 5000$$);

-- ---------- B. fn_terminal_baja_por_persona_inactiva ----------
SELECT pg_temp.verifica('20 atributos: SECURITY DEFINER, search_path = tiempo, personas, pg_temp, EXECUTE solo service_role (no PUBLIC, anon, authenticated, terminal_checador)',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=tiempo, personas, pg_temp']
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('terminal_checador', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
      AND pg_get_function_identity_arguments(p.oid) = 'p_persona_id uuid' AND p.prorettype = 'integer'::regtype
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'tiempo' AND p.proname = 'fn_terminal_baja_por_persona_inactiva'$$);
SELECT pg_temp.caso('20b authenticated NO la ejecuta (42501)', 'authenticated', 'SELECT ' || pg_temp.baja_por('B4'), '42501');
SELECT pg_temp.caso('20c anon NO la ejecuta (42501)', 'anon', 'SELECT ' || pg_temp.baja_por('B4'), '42501', '-');
SELECT pg_temp.rpc('21 persona ACTIVA con alta (B1): devuelve 0 y no emite nada', 'service_role', 'to_jsonb(' || pg_temp.baja_por('B1') || ')', $c$ $1 = '0'::jsonb $c$, '-');
SELECT pg_temp.verifica('21b ... B1 sigue en esperando_huella', $$SELECT pg_temp.est('B1') = 'esperando_huella'$$);
SELECT pg_temp.suspender('B2');
SELECT pg_temp.rpc('22 persona SUSPENDIDA con alta y autor derivable (B2): emite 1 baja', 'service_role', 'to_jsonb(' || pg_temp.baja_por('B2') || ')', $c$ $1 = '1'::jsonb $c$, '-');
SELECT pg_temp.verifica('22b ... B2 quedó en pendiente_baja y la baja trae como autor al administrador y detalle fijo',
  $$SELECT pg_temp.est('B2') = 'pendiente_baja' AND EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = pg_temp.tu('B2') AND tipo_movimiento = 'baja_solicitada'
      AND registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_uid'))$$);
SELECT pg_temp.rpc('22c segunda llamada: idempotente, 0', 'service_role', 'to_jsonb(' || pg_temp.baja_por('B2') || ')', $c$ $1 = '0'::jsonb $c$, '-');
-- B3: suspendida a mano en la fila de persona SIN movimiento en la bitácora => sin autor derivable => -1 (WARNING sin persona_id en la salida).
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k='B3');
SELECT pg_temp.rpc('23 persona inactiva SIN autor derivable (B3): devuelve -1', 'service_role', 'to_jsonb(' || pg_temp.baja_por('B3') || ')', $c$ $1 = '-1'::jsonb $c$, '-');
SELECT pg_temp.verifica('23b ... y B3 NO se dio de baja (sigue en esperando_huella)', $$SELECT pg_temp.est('B3') = 'esperando_huella'$$);
SELECT pg_temp.rpc('24 persona inexistente: 0', 'service_role', format('to_jsonb(tiempo.fn_terminal_baja_por_persona_inactiva(%L::uuid))', gen_random_uuid()), $c$ $1 = '0'::jsonb $c$, '-');

-- ---------- C. la consulta estática 59 (probada con casos positivos y negativos antes de aplicarla a la base) ----------
SELECT pg_temp.verifica('30 59 detecta: palabra employee_no en el mensaje', $$SELECT pg_temp.flag59($t$RAISE WARNING 'x employee_no=%', a;$t$)$$);
SELECT pg_temp.verifica('30b 59 detecta: "persona %" con p_persona_id', $$SELECT pg_temp.flag59($t$RAISE NOTICE 'sin autor para la persona %', p_persona_id;$t$)$$);
SELECT pg_temp.verifica('30c 59 detecta: variable v_emp tras un mensaje con ";" (el hueco del punto y coma)', $$SELECT pg_temp.flag59($t$RAISE WARNING 'aviso; sin nombre %', v_emp;$t$)$$);
SELECT pg_temp.verifica('30d 59 detecta: v_persona en varias líneas', $$SELECT pg_temp.flag59($t$RAISE LOG 'x %',
   v_persona;$t$)$$);
SELECT pg_temp.verifica('30e 59 detecta: rec.persona_id, rec.employee_no, NEW.employee_no y NEW.persona_id',
  $$SELECT pg_temp.flag59($t$RAISE WARNING 'a %', rec.persona_id;$t$) AND pg_temp.flag59($t$RAISE WARNING 'a %', rec.employee_no;$t$)
      AND pg_temp.flag59($t$RAISE INFO 'a %', NEW.employee_no;$t$) AND pg_temp.flag59($t$RAISE WARNING 'a %', NEW.persona_id;$t$)$$);
SELECT pg_temp.verifica('30f 59 detecta: la clave employee_no extraída del evento dentro del RAISE', $$SELECT pg_temp.flag59($t$RAISE WARNING 'x %', left(p_evento->>'employee_no', 12);$t$)$$);
SELECT pg_temp.verifica('30g 59 detecta: p_persona (variable de entrada)', $$SELECT pg_temp.flag59($t$RAISE WARNING 'x %', p_persona;$t$)$$);
SELECT pg_temp.verifica('31 59 NO marca: solo terminal_id y evento_id', $$SELECT NOT pg_temp.flag59($t$RAISE WARNING 'ok terminal_id=% evento_id=%', p_terminal_id, v_eid;$t$)$$);
SELECT pg_temp.verifica('31b 59 NO marca: RAISE EXCEPTION (no es log)', $$SELECT NOT pg_temp.flag59($t$RAISE EXCEPTION 'persona_id %', v_persona;$t$)$$);
SELECT pg_temp.verifica('31c 59 NO marca: la palabra en un COMENTARIO antes del RAISE', $$SELECT NOT pg_temp.flag59($t$-- sin employee_no ni persona_id
RAISE WARNING 'x terminal_id=%', t;$t$)$$);
SELECT pg_temp.verifica('31d 59 NO marca: rec.id (alta, no persona)', $$SELECT NOT pg_temp.flag59($t$RAISE WARNING 'sin autor derivable para la alta %', rec.id;$t$)$$);
SELECT pg_temp.verifica('31e 59 NO marca: SQLSTATE y terminal_id', $$SELECT NOT pg_temp.flag59($t$RAISE WARNING 'activación no aplicada sqlstate=% terminal_id=%', SQLSTATE, p_terminal_id;$t$)$$);

SELECT pg_temp.verifica('31f 59 NO marca: el RAISE termina en ";" y DESPUÉS hay código que lee employee_no (el defecto que encontró el primer ensayo_96)',
  $$SELECT NOT pg_temp.flag59($t$RAISE WARNING 'marca_rechazada terminal_id=% codigo=%', p_terminal_id, p_codigo;
  IF p_codigo IS NULL THEN RETURN; END IF;
  v_txt := p_evento->>'employee_no';
  IF v_txt ~ '^[0-9]{1,8}$' THEN v_emp := v_txt::integer; END IF;$t$)$$);
SELECT pg_temp.verifica('31g 59 NO marca: dos literales con ";" en funciones sin identidad en el log',
  $$SELECT NOT pg_temp.flag59($t$v_a := 'x; y'; RAISE WARNING 'ok; terminal_id=%', p_terminal_id; v_b := p_evento->>'employee_no'; v_c := 'z; w';$t$)$$);
SELECT pg_temp.verifica('31h 59 detecta: el mensaje con ";" y la variable de identidad después', $$SELECT pg_temp.flag59($t$v_a := 'x; y'; RAISE WARNING 'ok; terminal_id=% %', p_terminal_id, v_persona; v_b := 'z';$t$)$$);
SELECT pg_temp.verifica('31i 59 detecta: employee_no dentro de un mensaje con apóstrofe doble escapado', $$SELECT pg_temp.flag59($t$RAISE WARNING 'it''s employee_no=%', x;$t$)$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
