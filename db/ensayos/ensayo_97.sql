-- Ensayo de 97_tiempo_terminal_inferir_huella_interruptor.sql (interruptor de la activación por huella: siembra, CHECK, bitácora, trigger de auditoría, función dedicada y lector de estado). NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo
-- corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_97.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 97_ ENCIMA de lo ya aplicado (88_-96_: 94_, 95_ y 96_ están aplicados en la base real). Terminal, personas, usuarios, altas y marcas SINTÉTICOS; el admin real
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

\ir ../ddl/97_tiempo_terminal_inferir_huella_interruptor.sql

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

-- ---------- ayudantes de 97_ ----------
CREATE FUNCTION pg_temp.n_aud() RETURNS bigint AS $$ SELECT count(*) FROM tiempo.bitacora_config_terminal $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.est97() RETURNS jsonb AS $$ SELECT tiempo.fn_terminal_inferir_huella_estado() $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.cambiar(p_activa text, p_nota text, p_hasta text) RETURNS text AS $$
  SELECT format('tiempo.fn_terminal_inferir_huella_cambiar(%s, %L, %s)', p_activa, p_nota, p_hasta);
$$ LANGUAGE sql;
-- Filas vigentes (por fecha UTC) de una clave, para sembrar vigencias solapadas.
CREATE FUNCTION pg_temp.hoy_utc() RETURNS date AS $$ SELECT (now() AT TIME ZONE 'UTC')::date $$ LANGUAGE sql;

-- ---------- fixture ----------
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-97', 'Terminal de ensayo 97', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-97';
CREATE TEMP TABLE _term_activas AS SELECT id FROM tiempo.terminal WHERE activa;
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXU' || lpad(i::text, 2, '0'), 'XEXU010101' || lpad(i::text, 2, '0'), '9999998' || lpad(i::text, 4, '0'), 'SinteticaU' || i, 'Ensayo97', DATE '2000-01-01', CURRENT_DATE
FROM generate_series(5, 8) i;
INSERT INTO _ens SELECT 'P' || i, p.id::text FROM generate_series(5, 8) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXU' || lpad(i::text, 2, '0');
-- Usuarios: RH (P5, con parametro_edicion pero SIN terminal_config_edicion), sin permisos (P6), Gerente General (P7, CON terminal_config_edicion), persona inactiva (P8).
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text), ('auth_sin', gen_random_uuid()::text), ('auth_gg', gen_random_uuid()::text), ('auth_inact', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_rh', 'auth_sin', 'auth_gg', 'auth_inact');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='auth_rh'),    (SELECT v::uuid FROM _ens WHERE k='P5'), 'ens97rh'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_sin'),   (SELECT v::uuid FROM _ens WHERE k='P6'), 'ens97sin'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_gg'),    (SELECT v::uuid FROM _ens WHERE k='P7'), 'ens97gg'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_inact'), (SELECT v::uuid FROM _ens WHERE k='P8'), 'ens97inact');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P5'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P7'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS97 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P6'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS97 sin permisos';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P8'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k='P8');   -- la persona inactiva conserva el puesto: fn_caller_activo debe rechazarla

SELECT pg_temp.verifica('00 fixture: caller admin y 4 usuarios sintéticos', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND (SELECT count(*) FROM personas.usuario WHERE nombre_usuario LIKE 'ens97%') = 4$$);

-- ---------- A. siembra y catálogo ----------
SELECT pg_temp.verifica('10 siembra: una sola vigencia activa por clave, interruptor en 0, vencimiento centinela vencido, registrado_por NULL',
  $$SELECT (SELECT count(*) FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL) = 1
      AND (SELECT count(*) FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL) = 1
      AND (SELECT valor FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL) = '0'
      AND (SELECT valor FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL) = '1970-01-01T00:00:00Z'
      AND (SELECT count(*) FROM tiempo.parametro WHERE clave LIKE 'terminal\_inferir\_huella\_%' AND registrado_por IS NOT NULL) = 0$$);
SELECT pg_temp.verifica('11 las dos claves están FUERA del catálogo y el catálogo sigue con las 5 de 89_',
  $$SELECT (SELECT count(*) FROM tiempo.fn_terminal_config_catalogo()) = 5 AND (SELECT count(*) FROM tiempo.fn_terminal_config_catalogo() WHERE clave LIKE 'terminal\_inferir\_huella\_%') = 0$$);
SELECT pg_temp.rpc('11b el lector tolerante devuelve NULL para ellas (= apagado por construcción)', 'service_role',
  $$to_jsonb(tiempo.fn_terminal_config_valor('terminal_inferir_huella_activa'))$$, $c$ $1 IS NULL $c$, '-');
SELECT pg_temp.verifica('12 las 5 claves de 89_ siguen con UNA vigencia activa cada una', $$SELECT count(*) = 5 FROM (SELECT clave FROM tiempo.parametro WHERE clave LIKE 'terminal\_%' AND clave NOT LIKE 'terminal\_inferir\_huella\_%' AND vigente_hasta IS NULL GROUP BY clave HAVING count(*) = 1) t$$);
SELECT pg_temp.rpc('13 estado efectivo inicial: APAGADO (motivo apagado), no vencido', 'service_role', 'pg_temp.est97()',
  $c$ $1->>'activo' = 'false' AND $1->>'motivo' = 'apagado' AND $1->>'vencido' = 'false' AND $1->>'valor' = '0' $c$, '-');
SELECT pg_temp.verifica('14 la bitácora de configuración nace vacía y la siembra no dejó filas (el trigger se creó después)', $$SELECT pg_temp.n_aud() = 0$$);

-- ---------- B. quién puede y quién no (nada cambia, nada se audita) ----------
SELECT pg_temp.caso('20 RH (parametro_edicion pero SIN terminal_config_edicion) -> 42501 sin_permiso', 'authenticated',
  'SELECT ' || pg_temp.cambiar('true', 'Intento de RH sin permiso, ensayo', $$now() + interval '2 days'$$), '42501', (SELECT v FROM _ens WHERE k='auth_rh'), 'sin_permiso');
SELECT pg_temp.caso('20b usuario sin permisos -> 42501', 'authenticated',
  'SELECT ' || pg_temp.cambiar('true', 'Intento sin permisos, ensayo', $$now() + interval '2 days'$$), '42501', (SELECT v FROM _ens WHERE k='auth_sin'), 'sin_permiso');
SELECT pg_temp.caso('20c persona INACTIVA con el puesto correcto -> 42501', 'authenticated',
  'SELECT ' || pg_temp.cambiar('true', 'Intento de persona inactiva, ensayo', $$now() + interval '2 days'$$), '42501', (SELECT v FROM _ens WHERE k='auth_inact'), 'sin_permiso');
SELECT pg_temp.caso('20d anon -> 42501 (sin EXECUTE)', 'anon', 'SELECT ' || pg_temp.cambiar('true', 'Intento anon, ensayo largo', $$now() + interval '2 days'$$), '42501', '-');
SELECT pg_temp.caso('20e service_role NO la ejecuta (sin EXECUTE) -> 42501', 'service_role', 'SELECT ' || pg_temp.cambiar('true', 'Intento service_role, ensayo', $$now() + interval '2 days'$$), '42501', '-');
SELECT pg_temp.caso('20f p_activa NULL -> 22023 parametros_invalidos (con permiso)', 'authenticated', 'SELECT ' || pg_temp.cambiar('NULL::boolean', 'Nota de ensayo suficiente', 'NULL'), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'parametros_invalidos');
SELECT pg_temp.verifica('20g ... nada cambió ni se auditó', $$SELECT pg_temp.n_aud() = 0 AND pg_temp.est97()->>'motivo' = 'apagado'$$);

-- ---------- C. encender: validaciones ----------
SELECT pg_temp.caso('30 nota NULL -> 22023 nota_requerida', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', NULL, $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'nota_requerida');
SELECT pg_temp.caso('30b nota corta (9 letras) -> nota_requerida', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', 'abcdefghi', $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'nota_requerida');
SELECT pg_temp.caso('30c nota de solo espacios e invisibles -> nota_requerida', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', E'   ​‮​      ', $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'nota_requerida');
SELECT pg_temp.caso('30d 9 letras + invisibles NO alcanzan 10 -> nota_requerida', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', E'abcdefghi​​​​', $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'nota_requerida');
SELECT pg_temp.caso('30e nota de 501 caracteres -> nota_requerida', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', repeat('n', 501), $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'nota_requerida');
SELECT pg_temp.caso('31 hasta NULL -> 22023 hasta_invalido', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', 'Nota suficiente de ensayo', 'NULL::timestamptz'), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'hasta_invalido');
SELECT pg_temp.caso('31b hasta en el pasado -> hasta_invalido', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', 'Nota suficiente de ensayo', $$now() - interval '1 hour'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'hasta_invalido');
SELECT pg_temp.caso('31c hasta a más de 30 días -> hasta_invalido', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', 'Nota suficiente de ensayo', $$now() + interval '31 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'hasta_invalido');
SELECT pg_temp.verifica('31d ... ninguna de esas llamadas cambió ni auditó nada', $$SELECT pg_temp.n_aud() = 0 AND pg_temp.est97()->>'motivo' = 'apagado'$$);
-- P4: consentimiento. Si la última versión es la semilla provisional, encender se rechaza; si ya hay una publicada, el caso no aplica.
DO $do$
DECLARE v_prov boolean;
BEGIN
  SELECT c.provisional INTO v_prov FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
  IF v_prov THEN
    PERFORM pg_temp.caso('32 P4: solo existe el consentimiento PROVISIONAL -> SCJ16 sin_consentimiento_vigente', 'authenticated',
      'SELECT ' || pg_temp.cambiar('true', 'Nota suficiente de ensayo', $q$now() + interval '2 days'$q$), 'SCJ16', (SELECT v FROM _ens WHERE k='auth_uid'), 'sin_consentimiento_vigente');
  ELSE
    INSERT INTO _res (caso, ok, detalle) VALUES ('32 P4: ya hay un consentimiento publicado en la base real; el caso del texto provisional no aplica', true, 'n/a');
  END IF;
END
$do$;
SELECT pg_temp.rpc('32b el administrador publica un consentimiento (versión definitiva de ensayo)', 'authenticated',
  $$tiempo.fn_terminal_consentimiento_publicar('Texto de ensayo 97 del aviso de privacidad y consentimiento biométrico', false, 'ensayo 97')$$,
  $c$ $1->>'resultado' IN ('publicada', 'sin_cambio') $c$);
UPDATE tiempo.terminal SET activa = false WHERE activa;
SELECT pg_temp.caso('33 P4: ninguna terminal activa -> 22023 terminal_no_activa', 'authenticated', 'SELECT ' || pg_temp.cambiar('true', 'Nota suficiente de ensayo', $$now() + interval '2 days'$$), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'terminal_no_activa');
UPDATE tiempo.terminal SET activa = true WHERE id IN (SELECT id FROM _term_activas);
UPDATE tiempo.terminal SET activa = true WHERE terminal_id = 'ENSAYO-97';

-- ---------- D. encender / renovar / apagar ----------
SELECT pg_temp.rpc('40 el administrador ENCIENDE con nota válida y vencimiento a 2 días', 'authenticated',
  pg_temp.cambiar('true', 'Primera alta real supervisada, ensayo 97', $$now() + interval '2 days'$$),
  $c$ $1->>'resultado' = 'actualizada' AND ($1->'estado'->>'activo')::boolean AND NOT ($1->'estado'->>'vencido')::boolean $c$);
SELECT pg_temp.verifica('40b ... quedaron 2 filas de bitácora (activa 0->1 y hasta centinela->nuevo), con la nota, el autor, el rol del JWT, via_funcion verdadero y el MISMO txid',
  $$SELECT count(*) = 2 AND count(DISTINCT txid) = 1 AND bool_and(via_funcion) AND bool_and(rol_jwt = 'authenticated')
      AND bool_and(nota = 'Primera alta real supervisada, ensayo 97') AND bool_and(registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_uid'))
      AND bool_and(operacion IN ('INSERT', 'UPDATE'))
      AND bool_or(clave = 'terminal_inferir_huella_activa' AND valor_anterior = '0' AND valor_nuevo = '1')
      AND bool_or(clave = 'terminal_inferir_huella_hasta' AND valor_anterior = '1970-01-01T00:00:00Z' AND valor_nuevo ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$')
    FROM tiempo.bitacora_config_terminal$$);
SELECT pg_temp.verifica('40c ... las dos claves tienen UNA vigencia abierta con vigente_desde = hoy UTC y registrado_por = el administrador',
  $$SELECT count(*) = 2 AND bool_and(vigente_desde = pg_temp.hoy_utc()) AND bool_and(registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_uid'))
    FROM tiempo.parametro WHERE clave LIKE 'terminal\_inferir\_huella\_%' AND vigente_hasta IS NULL$$);
SELECT pg_temp.verifica('40d ... las variables de transacción quedaron limpias', $$SELECT COALESCE(current_setting('scj.txid_interruptor', true), '') = '' AND COALESCE(current_setting('scj.nota_interruptor', true), '') = ''$$);
SELECT pg_temp.rpc('41 el lector (service_role): activo, no vencido, con encendido_por = el administrador y hasta con formato ISO', 'service_role', 'pg_temp.est97()',
  $c$ ($1->>'activo')::boolean AND $1->>'motivo' IS NULL AND ($1->>'encendido_por')::uuid IS NOT NULL AND $1->>'hasta' ~ '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' $c$, '-');
SELECT pg_temp.rpc('42 mismo valor y mismo vencimiento -> sin_cambio y SIN filas nuevas', 'authenticated',
  pg_temp.cambiar('true', 'Misma nota, mismo vencimiento ensayo', $$now() + interval '2 days'$$), $c$ $1->>'resultado' = 'sin_cambio' $c$);
SELECT pg_temp.verifica('42b ... siguen 2 filas de bitácora', $$SELECT pg_temp.n_aud() = 2$$);
SELECT pg_temp.rpc('43 RENOVAR con otra fecha y nota nueva -> actualizada (solo cambia el vencimiento)', 'authenticated',
  pg_temp.cambiar('true', 'Renovación por supervisión, ensayo', $$now() + interval '5 days'$$), $c$ $1->>'resultado' = 'actualizada' AND ($1->'estado'->>'activo')::boolean $c$);
SELECT pg_temp.verifica('43b ... una fila de bitácora más (clave hasta), con la nota nueva', $$SELECT pg_temp.n_aud() = 3 AND (SELECT count(*) FROM tiempo.bitacora_config_terminal WHERE clave = 'terminal_inferir_huella_hasta' AND nota = 'Renovación por supervisión, ensayo') = 1$$);
SELECT pg_temp.rpc('44 APAGAR sin nota -> actualizada y estado apagado', 'authenticated', pg_temp.cambiar('false', NULL, 'NULL'),
  $c$ $1->>'resultado' = 'actualizada' AND NOT ($1->'estado'->>'activo')::boolean AND $1->'estado'->>'motivo' = 'apagado' $c$);
SELECT pg_temp.verifica('44b ... 2 filas más (activa 1->0 y hasta devuelto al centinela), sin nota, via_funcion verdadero',
  $$SELECT pg_temp.n_aud() = 5 AND (SELECT count(*) FROM tiempo.bitacora_config_terminal WHERE valor_nuevo IN ('0', '1970-01-01T00:00:00Z') AND nota IS NULL AND via_funcion) = 2$$);
SELECT pg_temp.rpc('44c apagar de nuevo -> sin_cambio', 'authenticated', pg_temp.cambiar('false', NULL, 'NULL'), $c$ $1->>'resultado' = 'sin_cambio' $c$);
-- Encender y apagar el MISMO día UTC: la vigencia se corrige en sitio pero la bitácora conserva cada transición.
SELECT pg_temp.rpc('45 encender de nuevo el mismo día', 'authenticated', pg_temp.cambiar('true', 'Segundo encendido del mismo día, ensayo', $$now() + interval '1 day'$$), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.rpc('45b y apagar otra vez', 'authenticated', pg_temp.cambiar('false', NULL, 'NULL'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.verifica('45c ... 4 filas más (9 en total) y cada clave sigue con UNA vigencia abierta de hoy', $$SELECT pg_temp.n_aud() = 9
  AND (SELECT count(*) FROM tiempo.parametro WHERE clave LIKE 'terminal\_inferir\_huella\_%' AND vigente_hasta IS NULL AND vigente_desde = pg_temp.hoy_utc()) = 2$$);

-- ---------- E. rutas genéricas ----------
SELECT pg_temp.caso('50 fn_terminal_config_actualizar con la clave del interruptor (con permiso) -> 22023 clave_no_editable', 'authenticated',
  $$SELECT tiempo.fn_terminal_config_actualizar('terminal_inferir_huella_activa', '1')$$, '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'clave_no_editable');
SELECT pg_temp.caso('50b ... y con la clave de vencimiento', 'authenticated',
  $$SELECT tiempo.fn_terminal_config_actualizar('terminal_inferir_huella_hasta', '2030-01-01T00:00:00Z')$$, '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'clave_no_editable');
SELECT pg_temp.caso('50c ... sin permiso el gate va primero (42501 sin_permiso)', 'authenticated',
  $$SELECT tiempo.fn_terminal_config_actualizar('terminal_inferir_huella_activa', '1')$$, '42501', (SELECT v FROM _ens WHERE k='auth_rh'), 'sin_permiso');
SELECT pg_temp.caso('51 fn_parametro_actualizar_valor (pantalla genérica) -> SCJ17 clave_reservada', 'service_role',
  format($f$SELECT tiempo.fn_parametro_actualizar_valor('terminal_inferir_huella_activa', '1', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='auth_uid')), 'SCJ17', '-', 'clave_reservada');
SELECT pg_temp.verifica('51b ... y nada cambió ni se auditó (siguen 9 filas)', $$SELECT pg_temp.n_aud() = 9$$);

-- ---------- F. regresión de las otras terminal_* (ahora con mensajes fijos) ----------
SELECT pg_temp.rpc('60 caducidad dentro de rango (48 h) -> actualizada', 'authenticated', $$tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '48')$$,
  $c$ $1->>'resultado' IN ('actualizada', 'sin_cambio') AND $1->>'valor' = '48' $c$, (SELECT v FROM _ens WHERE k='auth_gg'));
SELECT pg_temp.caso('60b caducidad fuera de rango (3 y 169) -> 22023 valor_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '3')$$, '22023', (SELECT v FROM _ens WHERE k='auth_gg'), 'valor_invalido');
SELECT pg_temp.caso('60c ... 169', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '169')$$, '22023', (SELECT v FROM _ens WHERE k='auth_gg'), 'valor_invalido');
SELECT pg_temp.caso('60d valor no numérico y NULL -> valor_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', 'abc')$$, '22023', (SELECT v FROM _ens WHERE k='auth_gg'), 'valor_invalido');
SELECT pg_temp.caso('60e clave desconocida -> clave_no_editable', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_inventada', '1')$$, '22023', (SELECT v FROM _ens WHERE k='auth_gg'), 'clave_no_editable');
SELECT pg_temp.rpc('60f regla cruzada de llaves: subir el traslape a 90 días es válido con 12 meses de antigüedad máxima (180 <= 360)', 'authenticated',
  $$tiempo.fn_terminal_config_actualizar('terminal_traslape_llave_max_dias', '90')$$, $c$ $1->>'valor' = '90' $c$, (SELECT v FROM _ens WHERE k='auth_gg'));
SELECT pg_temp.caso('60f2 ... y entonces bajar la antigüedad a 3 meses rompe la regla (180 > 90) -> valor_invalido', 'authenticated',
  $$SELECT tiempo.fn_terminal_config_actualizar('terminal_llave_max_meses', '3')$$, '22023', (SELECT v FROM _ens WHERE k='auth_gg'), 'valor_invalido');
SELECT pg_temp.caso('60g RH sin terminal_config_edicion sigue en 42501 en las demás claves', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '24')$$, '42501', (SELECT v FROM _ens WHERE k='auth_rh'), 'sin_permiso');
SELECT pg_temp.verifica('60h el interruptor y su bitácora no se movieron con esas ediciones (9 filas)', $$SELECT pg_temp.n_aud() = 9$$);

-- ---------- G. CHECK (valores inválidos, escritos como dueño) ----------
SELECT pg_temp.caso('70 interruptor = ''7'' -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '7' WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('70b interruptor = ''1 '' (espacio) -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '1 ' WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('70c interruptor = ''true'' -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = 'true' WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('70d interruptor vacío -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '' WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('70e interruptor NULL -> error (NOT NULL)', current_user::text, $$UPDATE tiempo.parametro SET valor = NULL WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, 'error', '-');
SELECT pg_temp.caso('71 vencimiento con espacio en vez de T -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '2026-10-20 12:00:00Z' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('71b vencimiento sin zona -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '2026-10-20T12:00:00' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('71c vencimiento con mes 13 -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = '2026-13-01T00:00:00Z' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('71d vencimiento en texto libre y vacío -> 23514', current_user::text, $$UPDATE tiempo.parametro SET valor = 'mañana' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL$$, '23514', '-');
SELECT pg_temp.caso('71e vencimiento con zona +05:30 y fracción -> aceptado', current_user::text, $$UPDATE tiempo.parametro SET valor = '2026-10-20T12:00:00.123456+05:30' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL$$, 'ok', '-');
SELECT pg_temp.verifica('72 las otras claves terminal_* no se ven afectadas por los CHECK', $$SELECT count(*) = 5 FROM tiempo.parametro WHERE clave IN ('terminal_caducidad_alta_horas', 'terminal_llave_max_meses', 'terminal_traslape_llave_max_dias', 'terminal_anomalias_ventana_dias', 'terminal_retencion_rechazos_dias') AND vigente_hasta IS NULL$$);

-- ---------- H. auditoría de escrituras DIRECTAS (A2) ----------
-- Estado de partida: interruptor en '0' y vencimiento reescrito arriba (71e); se deja el interruptor en '0' y el vencimiento en el centinela con una escritura directa (también auditada).
UPDATE tiempo.parametro SET valor = '1970-01-01T00:00:00Z' WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL;
SELECT pg_temp.verifica('80 partida: bitácora con 10 filas (71e y su restauración quedaron auditadas) y la anomalía «sin nota» vacía',
  $$SELECT pg_temp.n_aud() = 11 AND (SELECT count(*) FROM tiempo.bitacora_config_terminal WHERE clave = 'terminal_inferir_huella_activa' AND valor_nuevo = '1' AND (nota IS NULL OR char_length(nota) < 10)) = 0$$);
SELECT pg_temp.caso('81 UPDATE DIRECTO de service_role del interruptor a ''1'' (permitido a service_role, pero queda rastro)', 'service_role',
  $$UPDATE tiempo.parametro SET valor = '1' WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, 'ok', '-');
SELECT pg_temp.verifica('81b ... dejó UNA fila: operación UPDATE, 0->1, nota NULL, via_funcion falso, rol_jwt service_role, session_user del ensayo',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_config_terminal WHERE id = (SELECT max(id) FROM tiempo.bitacora_config_terminal)
      AND operacion = 'UPDATE' AND clave = 'terminal_inferir_huella_activa' AND valor_anterior = '0' AND valor_nuevo = '1' AND nota IS NULL AND NOT via_funcion
      AND rol_jwt = 'service_role' AND usuario_sesion = session_user::text$$);
SELECT pg_temp.verifica('81c ... y la consulta de la anomalía «cambio sin nota» la devuelve', $$SELECT count(*) = 1 FROM tiempo.bitacora_config_terminal WHERE clave = 'terminal_inferir_huella_activa' AND valor_nuevo = '1' AND (nota IS NULL OR char_length(nota) < 10)$$);
SELECT pg_temp.rpc('81d valor ''1'' con el vencimiento centinela vencido -> APAGADO efectivo, mostrado como vencido', 'service_role', 'pg_temp.est97()',
  $c$ NOT ($1->>'activo')::boolean AND ($1->>'vencido')::boolean AND $1->>'motivo' = 'vencido' $c$, '-');
-- Un 'hasta' directo a más de 30 días (formato válido) NO crea un interruptor de vida larga: el lector aplica el tope también al LEER.
UPDATE tiempo.parametro SET valor = to_char((now() + interval '40 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('82 hasta directo a 40 días -> APAGADO (hasta_excede_tope), no activo', 'service_role', 'pg_temp.est97()',
  $c$ NOT ($1->>'activo')::boolean AND $1->>'motivo' = 'hasta_excede_tope' $c$, '-');
UPDATE tiempo.parametro SET valor = to_char((now() + interval '3 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('82b hasta directo a 3 días con el interruptor en 1 -> ACTIVO (la escritura directa no se impide, queda auditada y sin nota)', 'service_role', 'pg_temp.est97()',
  $c$ ($1->>'activo')::boolean $c$, '-');
-- Vigencias solapadas -> apagado.
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
VALUES ('terminal_inferir_huella_activa', '1', pg_temp.hoy_utc() - 1, pg_temp.hoy_utc() + 5, NULL);
SELECT pg_temp.rpc('83 DOS filas vigentes del interruptor (vigencias solapadas) -> APAGADO (vigencias_inconsistentes)', 'service_role', 'pg_temp.est97()',
  $c$ NOT ($1->>'activo')::boolean AND $1->>'motivo' = 'vigencias_inconsistentes' $c$, '-');
SELECT pg_temp.verifica('83b ... el INSERT directo también dejó fila (operación INSERT, valor anterior = el de la vigencia previa)',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_config_terminal WHERE operacion = 'INSERT' AND clave = 'terminal_inferir_huella_activa' AND valor_nuevo = '1' AND nota IS NULL AND NOT via_funcion$$);
SELECT pg_temp.caso('83c la función dedicada se niega a escribir con vigencias inconsistentes (22023 vigencias_inconsistentes)', 'authenticated',
  'SELECT ' || pg_temp.cambiar('false', NULL, 'NULL'), '22023', (SELECT v FROM _ens WHERE k='auth_uid'), 'vigencias_inconsistentes');
DELETE FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta = pg_temp.hoy_utc() + 5;
-- DELETE directo de la fila vigente por service_role: auditoría y apagado.
SELECT pg_temp.caso('84 DELETE DIRECTO de la fila vigente del interruptor por service_role', 'service_role',
  $$DELETE FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa' AND vigente_hasta IS NULL$$, 'ok', '-');
SELECT pg_temp.verifica('84b ... dejó fila (operación DELETE, valor anterior, valor nuevo NULL, nota NULL, rol_jwt service_role)',
  $$SELECT count(*) = 1 FROM tiempo.bitacora_config_terminal WHERE operacion = 'DELETE' AND clave = 'terminal_inferir_huella_activa' AND valor_nuevo IS NULL AND valor_anterior IS NOT NULL AND nota IS NULL AND rol_jwt = 'service_role'$$);
SELECT pg_temp.rpc('84c ... y el lector lo lee como APAGADO (sin vigencia del interruptor)', 'service_role', 'pg_temp.est97()',
  $c$ NOT ($1->>'activo')::boolean AND $1->>'motivo' = 'vigencias_inconsistentes' $c$, '-');
-- El UPDATE que solo cierra vigente_hasta (sin cambiar el valor) NO deja fila.
SELECT pg_temp.verifica('85 snapshot de la bitácora antes de cerrar una vigencia de la otra clave', $$SELECT pg_temp.n_aud() >= 14$$);
CREATE TEMP TABLE _aud_antes AS SELECT count(*) AS n FROM tiempo.bitacora_config_terminal;
UPDATE tiempo.parametro SET vigente_hasta = pg_temp.hoy_utc() + 9 WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL;
SELECT pg_temp.verifica('85b el UPDATE que solo cierra la vigencia no dejó fila', $$SELECT pg_temp.n_aud() = (SELECT n FROM _aud_antes)$$);
-- Una variable de nota fijada en OTRA transacción (otro txid) no se acepta.
SELECT set_config('scj.nota_interruptor', 'Nota falsificada de ensayo para el trigger', true), set_config('scj.txid_interruptor', '1', true);
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES ('terminal_inferir_huella_hasta', '2030-01-01T00:00:00Z', pg_temp.hoy_utc() + 10, NULL, NULL);
SELECT pg_temp.verifica('86 una nota con txid ajeno NO se acepta: la fila queda con nota NULL y via_funcion falso',
  $$SELECT nota IS NULL AND NOT via_funcion FROM tiempo.bitacora_config_terminal WHERE id = (SELECT max(id) FROM tiempo.bitacora_config_terminal)$$);
SELECT set_config('scj.nota_interruptor', '', true), set_config('scj.txid_interruptor', '', true);

-- ---------- I. la bitácora ----------
SELECT pg_temp.caso('90 UPDATE sobre la bitácora (incluso el dueño) -> error', current_user::text, $$UPDATE tiempo.bitacora_config_terminal SET nota = 'x'$$, 'error', '-');
SELECT pg_temp.caso('90b DELETE -> error', current_user::text, $$DELETE FROM tiempo.bitacora_config_terminal$$, 'error', '-');
SELECT pg_temp.caso('90c TRUNCATE -> error', current_user::text, $$TRUNCATE tiempo.bitacora_config_terminal$$, 'error', '-');
SELECT pg_temp.caso('90d INSERT directo de service_role -> 42501', 'service_role',
  $$INSERT INTO tiempo.bitacora_config_terminal (clave, operacion, usuario_sesion, via_funcion, txid) VALUES ('terminal_inferir_huella_activa', 'UPDATE', 'x', false, 1)$$, '42501', '-');
SELECT pg_temp.caso('90e INSERT directo de authenticated -> 42501', 'authenticated',
  $$INSERT INTO tiempo.bitacora_config_terminal (clave, operacion, usuario_sesion, via_funcion, txid) VALUES ('terminal_inferir_huella_activa', 'UPDATE', 'x', false, 1)$$, '42501');
SELECT pg_temp.caso('90f anon no lee la bitácora (42501)', 'anon', 'SELECT count(*) FROM tiempo.bitacora_config_terminal', '42501', '-');
SELECT pg_temp.rpc('90g el administrador (authenticated con permiso) SÍ la lee', 'authenticated', $$to_jsonb((SELECT count(*) FROM tiempo.bitacora_config_terminal))$$, $c$ ($1 #>> '{}')::int > 0 $c$);
SELECT pg_temp.rpc('90h el usuario SIN permisos lee 0 filas (la policy exige permiso)', 'authenticated', $$to_jsonb((SELECT count(*) FROM tiempo.bitacora_config_terminal))$$, $c$ ($1 #>> '{}')::int = 0 $c$, (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.rpc('90i service_role la lee', 'service_role', $$to_jsonb((SELECT count(*) FROM tiempo.bitacora_config_terminal))$$, $c$ ($1 #>> '{}')::int > 0 $c$, '-');
SELECT pg_temp.verifica('90j has_table_privilege por rol: nadie con INSERT/UPDATE/DELETE/TRUNCATE; authenticated y service_role solo SELECT; anon y terminal_checador nada',
  $$SELECT NOT EXISTS (SELECT 1 FROM (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) r(rol) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
        WHERE has_table_privilege(r.rol, 'tiempo.bitacora_config_terminal', p.priv))
      AND has_table_privilege('authenticated', 'tiempo.bitacora_config_terminal', 'SELECT') AND has_table_privilege('service_role', 'tiempo.bitacora_config_terminal', 'SELECT')
      AND NOT has_table_privilege('anon', 'tiempo.bitacora_config_terminal', 'SELECT') AND NOT has_table_privilege('terminal_checador', 'tiempo.bitacora_config_terminal', 'SELECT')$$);
SELECT pg_temp.verifica('90k los tres mensajes de la bitácora son fijos: sin interpolar valores',
  $$SELECT (SELECT prosrc FROM pg_proc WHERE proname = 'fn_bitacora_config_terminal_inmutable') NOT LIKE '%TG_OP%' AND (SELECT prosrc FROM pg_proc WHERE proname = 'fn_bitacora_config_terminal_truncate') NOT LIKE '%OLD.%'$$);

-- TRUNCATE de tiempo.parametro bloqueado (incluido service_role, que lo tiene concedido).
SELECT pg_temp.caso('95 TRUNCATE de tiempo.parametro como el dueño -> error (trigger BEFORE TRUNCATE)', current_user::text, 'TRUNCATE tiempo.parametro', 'P0001', '-', 'parametro_truncate_bloqueado');
SELECT pg_temp.caso('95b TRUNCATE de tiempo.parametro como service_role -> bloqueado (por el trigger si tiene el privilegio; en cualquier caso, error)', 'service_role', 'TRUNCATE tiempo.parametro', 'error', '-');
SELECT pg_temp.verifica('95b2 ... y si service_role tiene TRUNCATE concedido (GRANT ALL de 38_), el bloqueo es del trigger y no del permiso', $$SELECT NOT has_table_privilege('service_role', 'tiempo.parametro', 'TRUNCATE') OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'tiempo.parametro'::regclass AND tgname = 'trg_parametro_truncate_bloqueado' AND tgenabled = 'O')$$);
SELECT pg_temp.caso('95c TRUNCATE ... CASCADE y RESTART IDENTITY también bloqueados', current_user::text, 'TRUNCATE tiempo.parametro RESTART IDENTITY CASCADE', 'P0001', '-', 'parametro_truncate_bloqueado');
SELECT pg_temp.caso('95d authenticated tampoco puede (sin privilegio o por el trigger: cualquier error)', 'authenticated', 'TRUNCATE tiempo.parametro', 'error');
SELECT pg_temp.caso('95d2 anon tampoco puede', 'anon', 'TRUNCATE tiempo.parametro', 'error', '-');
SELECT pg_temp.verifica('95e ... y tiempo.parametro conserva sus filas (las 5 claves de 89_ siguen con su vigencia abierta)',
  $$SELECT count(*) = 5 FROM tiempo.parametro WHERE clave IN ('terminal_caducidad_alta_horas', 'terminal_llave_max_meses', 'terminal_traslape_llave_max_dias', 'terminal_anomalias_ventana_dias', 'terminal_retencion_rechazos_dias') AND vigente_hasta IS NULL$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
