-- Ensayo de 89_tiempo_terminal_config_parametros.sql (con 88_, de la que depende por el permiso terminal_config_edicion): 5 claves
-- terminal_* en tiempo.parametro, RPC de edición con lista blanca, rangos y regla cruzada traslape*2 <= antigüedad_meses*30, lector
-- tolerante y guard SCJ17 en fn_parametro_actualizar_valor. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la
-- sesión que lo corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_89.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 88_ y 89_ ENCIMA de lo ya aplicado (87_). Usuarios sintéticos; el administrador real sólo es
-- caller. 88_ exige terminal_usuario y la bitácora vacías.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
\ir ../ddl/88_tiempo_terminal_consentimiento.sql
\ir ../ddl/89_tiempo_terminal_config_parametros.sql

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


-- Usuarios sintéticos: PR (RH: terminal_usuario_edicion, NO terminal_config_edicion) y PS (sin permisos).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXB1', 'XEXX010101B1', '99999990011', 'SinteticaB1', 'Ensayo89', DATE '2000-01-01', CURRENT_DATE),
       ('XEXX010101HNEXXXB2', 'XEXX010101B2', '99999990012', 'SinteticaB2', 'Ensayo89', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'PR', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXB1';
INSERT INTO _ens SELECT 'PS', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXB2';
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text), ('auth_sin', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email)
SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_rh', 'auth_sin');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='auth_rh'),  (SELECT v::uuid FROM _ens WHERE k='PR'), 'ens89rh'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_sin'), (SELECT v::uuid FROM _ens WHERE k='PS'), 'ens89sin');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='PR'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS89 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='PS'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS89 sin permisos';

-- Valor ACTIVO de una clave.
CREATE FUNCTION pg_temp.act(p_clave text) RETURNS text AS $$
  SELECT valor FROM tiempo.parametro WHERE clave = p_clave AND vigente_hasta IS NULL;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.cfg(p_clave text, p_valor text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_terminal_config_actualizar(%L, %L)', p_clave, p_valor);
$$ LANGUAGE sql;

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid')$$);
SELECT pg_temp.verifica('01 las 5 claves quedaron sembradas con UNA vigencia activa y su valor inicial (24, 12, 7, 7, 90)',
  $$SELECT pg_temp.act('terminal_caducidad_alta_horas') = '24' AND pg_temp.act('terminal_llave_max_meses') = '12'
      AND pg_temp.act('terminal_traslape_llave_max_dias') = '7' AND pg_temp.act('terminal_anomalias_ventana_dias') = '7'
      AND pg_temp.act('terminal_retencion_rechazos_dias') = '90'
      AND (SELECT count(*) FROM tiempo.parametro WHERE clave LIKE 'terminal\_%' AND vigente_hasta IS NULL) = 5$$);
SELECT pg_temp.verifica('01b las 8 claves anteriores siguen intactas', $$SELECT count(*) = 8 FROM tiempo.parametro WHERE clave NOT LIKE 'terminal\_%' AND vigente_hasta IS NULL$$);

-- A. Lector tolerante (service_role)
SELECT pg_temp.rpc('10 lector: valores vigentes', 'service_role',
  $$jsonb_build_array(tiempo.fn_terminal_config_valor('terminal_caducidad_alta_horas'), tiempo.fn_terminal_config_valor('terminal_llave_max_meses'),
                      tiempo.fn_terminal_config_valor('terminal_traslape_llave_max_dias'), tiempo.fn_terminal_config_valor('terminal_anomalias_ventana_dias'),
                      tiempo.fn_terminal_config_valor('terminal_retencion_rechazos_dias'))$$,
  $c$ $1 = '[24, 12, 7, 7, 90]'::jsonb $c$, '-');
SELECT pg_temp.rpc('10b lector: clave fuera del catálogo -> NULL (se muestra como -1 con COALESCE)', 'service_role', $$to_jsonb(COALESCE(tiempo.fn_terminal_config_valor('tolerancia_retardo_min'), -1))$$, $c$ $1 = '-1'::jsonb $c$, '-');
UPDATE tiempo.parametro SET valor = 'abc' WHERE clave = 'terminal_caducidad_alta_horas' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('10c lector: valor mal formado en la base -> devuelve el valor por defecto (24), no falla', 'service_role', $$to_jsonb(tiempo.fn_terminal_config_valor('terminal_caducidad_alta_horas'))$$, $c$ $1 = '24'::jsonb $c$, '-');
UPDATE tiempo.parametro SET valor = '9999' WHERE clave = 'terminal_caducidad_alta_horas' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('10d lector: valor fuera de rango (9999) -> se acota al máximo (168)', 'service_role', $$to_jsonb(tiempo.fn_terminal_config_valor('terminal_caducidad_alta_horas'))$$, $c$ $1 = '168'::jsonb $c$, '-');
UPDATE tiempo.parametro SET valor = '1' WHERE clave = 'terminal_caducidad_alta_horas' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('10e lector: valor por debajo del piso (1) -> se acota al mínimo (4)', 'service_role', $$to_jsonb(tiempo.fn_terminal_config_valor('terminal_caducidad_alta_horas'))$$, $c$ $1 = '4'::jsonb $c$, '-');
DELETE FROM tiempo.parametro WHERE clave = 'terminal_caducidad_alta_horas';
SELECT pg_temp.rpc('10f lector: sin ninguna vigencia -> el valor por defecto (24)', 'service_role', $$to_jsonb(tiempo.fn_terminal_config_valor('terminal_caducidad_alta_horas'))$$, $c$ $1 = '24'::jsonb $c$, '-');
INSERT INTO tiempo.parametro (clave, valor, vigente_desde) VALUES ('terminal_caducidad_alta_horas', '24', DATE '2026-01-01');
SELECT pg_temp.caso('10g el lector no es ejecutable por authenticated', 'authenticated', $$SELECT tiempo.fn_terminal_config_valor('terminal_llave_max_meses')$$, '42501');
SELECT pg_temp.caso('10h ... ni por anon', 'anon', $$SELECT tiempo.fn_terminal_config_valor('terminal_llave_max_meses')$$, '42501', '-');
SELECT pg_temp.caso('10i el catálogo (rangos) sí lo lee authenticated', 'authenticated', $$SELECT count(*) FROM tiempo.fn_terminal_config_catalogo()$$, 'ok');

-- B. Editar: permisos
SELECT pg_temp.caso('20 RH (terminal_usuario_edicion, SIN terminal_config_edicion) -> 42501 sin_permiso', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '48'), '42501', (SELECT v FROM _ens WHERE k='auth_rh'), 'sin_permiso');
SELECT pg_temp.caso('20b usuario sin permisos -> 42501 sin_permiso', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '48'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'), 'sin_permiso');
SELECT pg_temp.caso('20c anon -> 42501 (sin EXECUTE)', 'anon', pg_temp.cfg('terminal_caducidad_alta_horas', '48'), '42501', '-');
SELECT pg_temp.caso('20d service_role -> 42501 (sin EXECUTE; la edición pasa por el cliente del caller)', 'service_role', pg_temp.cfg('terminal_caducidad_alta_horas', '48'), '42501', '-');
SELECT pg_temp.verifica('20e ninguna de esas llamadas cambió el valor', $$SELECT pg_temp.act('terminal_caducidad_alta_horas') = '24'$$);
SELECT pg_temp.caso('20f RH no puede escribir tiempo.parametro directo (sin privilegio de UPDATE ni policy): el UPDATE falla', 'authenticated',
  $$UPDATE tiempo.parametro SET valor = '1' WHERE clave LIKE 'terminal\_%'$$, 'error', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('20g ... y los valores siguen intactos', $$SELECT pg_temp.act('terminal_caducidad_alta_horas') = '24' AND pg_temp.act('terminal_retencion_rechazos_dias') = '90'$$);

-- C. Validación de clave y valor
SELECT pg_temp.caso('30 clave fuera de la lista blanca (tolerancia_retardo_min) -> 22023 clave_no_editable', 'authenticated', pg_temp.cfg('tolerancia_retardo_min', '11'), '22023', NULL, 'clave_no_editable');
SELECT pg_temp.caso('30b clave inexistente -> 22023 clave_no_editable', 'authenticated', pg_temp.cfg('terminal_inventada', '5'), '22023', NULL, 'clave_no_editable');
SELECT pg_temp.caso('31 valor no entero (abc) -> 22023 valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', 'abc'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31b valor decimal (1.5) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '1.5'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31c valor negativo (-3) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '-3'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31d valor vacío -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', ''), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31e valor NULL -> valor_invalido', 'authenticated', $$SELECT tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', NULL)$$, '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31f caducidad 3 (bajo el piso 4) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '3'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31g caducidad 169 (sobre 168) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_caducidad_alta_horas', '169'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31h llave 2 meses (bajo 3) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_llave_max_meses', '2'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31i llave 37 meses (sobre 36) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_llave_max_meses', '37'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31j retención 29 días (bajo 30) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_retencion_rechazos_dias', '29'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31k retención 366 días (sobre 365) -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_retencion_rechazos_dias', '366'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31l ventana de anomalías 0 -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_anomalias_ventana_dias', '0'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31m ventana de anomalías 91 -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_anomalias_ventana_dias', '91'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31n traslape 0 -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_traslape_llave_max_dias', '0'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.caso('31o traslape 91 -> valor_invalido', 'authenticated', pg_temp.cfg('terminal_traslape_llave_max_dias', '91'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.verifica('31p ningún rechazo cambió valores', $$SELECT pg_temp.act('terminal_caducidad_alta_horas') = '24' AND pg_temp.act('terminal_llave_max_meses') = '12' AND pg_temp.act('terminal_anomalias_ventana_dias') = '7'$$);

-- D. Editar: éxito y versionado
SELECT pg_temp.rpc('40 caducidad a 48 como TI/admin -> actualizada', 'authenticated', format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_caducidad_alta_horas', '48'),
  $c$ $1->>'resultado' = 'actualizada' AND $1->>'valor' = '48' $c$);
SELECT pg_temp.verifica('40b nueva vigencia: la anterior (2026-01-01) se cerró con vigente_hasta = hoy - 1, la nueva empieza hoy, autor = el auth_user_id del admin',
  $$SELECT (SELECT vigente_hasta FROM tiempo.parametro WHERE clave='terminal_caducidad_alta_horas' AND valor='24') = CURRENT_DATE - 1
      AND (SELECT vigente_desde FROM tiempo.parametro WHERE clave='terminal_caducidad_alta_horas' AND vigente_hasta IS NULL) = CURRENT_DATE
      AND (SELECT registrado_por FROM tiempo.parametro WHERE clave='terminal_caducidad_alta_horas' AND vigente_hasta IS NULL) = (SELECT v::uuid FROM _ens WHERE k='auth_uid')
      AND (SELECT count(*) FROM tiempo.parametro WHERE clave='terminal_caducidad_alta_horas') = 2$$);
SELECT pg_temp.rpc('41 mismo valor otra vez -> sin_cambio (no crea vigencia)', 'authenticated', format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_caducidad_alta_horas', '48'),
  $c$ $1->>'resultado' = 'sin_cambio' $c$);
SELECT pg_temp.rpc('42 segundo cambio el MISMO día (a 72) -> corrige la vigencia en sitio', 'authenticated', format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_caducidad_alta_horas', '72'),
  $c$ $1->>'resultado' = 'actualizada' AND $1->>'valor' = '72' $c$);
SELECT pg_temp.verifica('42b siguen siendo 2 filas (no se creó una tercera) y la activa vale 72', $$SELECT (SELECT count(*) FROM tiempo.parametro WHERE clave='terminal_caducidad_alta_horas') = 2 AND pg_temp.act('terminal_caducidad_alta_horas') = '72'$$);
SELECT pg_temp.rpc('43 límites exactos aceptados: caducidad 4 y 168', 'authenticated',
  $$jsonb_build_array(tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '4')->>'valor', tiempo.fn_terminal_config_actualizar('terminal_caducidad_alta_horas', '168')->>'valor')$$,
  $c$ $1 = '["4", "168"]'::jsonb $c$);
SELECT pg_temp.rpc('43b retención 30 y 365; ventana 1 y 90', 'authenticated',
  $$jsonb_build_array(tiempo.fn_terminal_config_actualizar('terminal_retencion_rechazos_dias', '30')->>'valor', tiempo.fn_terminal_config_actualizar('terminal_retencion_rechazos_dias', '365')->>'valor',
                      tiempo.fn_terminal_config_actualizar('terminal_anomalias_ventana_dias', '1')->>'valor', tiempo.fn_terminal_config_actualizar('terminal_anomalias_ventana_dias', '90')->>'valor')$$,
  $c$ $1 = '["30", "365", "1", "90"]'::jsonb $c$);
SELECT pg_temp.rpc('43c valor con espacios y ceros a la izquierda (" 012 ") se normaliza a 12', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_llave_max_meses', ' 012 '), $c$ $1->>'resultado' = 'sin_cambio' AND $1->>'valor' = '12' $c$);

-- E. Regla cruzada: traslape * 2 <= antigüedad_meses * 30
SELECT pg_temp.rpc('50 bajar la antigüedad a 3 meses (límite de traslape 45 días; traslape vigente 7) -> actualizada', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_llave_max_meses', '3'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.caso('50b traslape 46 con antigüedad de 3 meses (92 > 90) -> 22023 valor_invalido', 'authenticated', pg_temp.cfg('terminal_traslape_llave_max_dias', '46'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.rpc('50c traslape 45 con antigüedad de 3 meses (90 <= 90) -> actualizada', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_traslape_llave_max_dias', '45'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.rpc('50d subir la antigüedad a 6 meses (límite de traslape 90) -> actualizada', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_llave_max_meses', '6'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.rpc('50d2 y ahora el traslape a 90 (180 <= 180) -> actualizada', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_traslape_llave_max_dias', '90'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.caso('50e SIMÉTRICO: bajar la antigüedad a 5 meses con traslape 90 (180 > 150) -> 22023 valor_invalido', 'authenticated', pg_temp.cfg('terminal_llave_max_meses', '5'), '22023', NULL, 'valor_invalido');
SELECT pg_temp.rpc('50f la antigüedad en 6 otra vez -> sin_cambio', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_llave_max_meses', '6'), $c$ $1->>'resultado' = 'sin_cambio' $c$);
SELECT pg_temp.rpc('50f2 y a 7 meses -> actualizada', 'authenticated',
  format('tiempo.fn_terminal_config_actualizar(%L, %L)', 'terminal_llave_max_meses', '7'), $c$ $1->>'resultado' = 'actualizada' $c$);
SELECT pg_temp.verifica('50g el estado final cumple la regla (90 * 2 <= 7 * 30)', $$SELECT pg_temp.act('terminal_traslape_llave_max_dias')::int * 2 <= pg_temp.act('terminal_llave_max_meses')::int * 30$$);
-- Restaurar valores iniciales para el verificador (como dueño).
UPDATE tiempo.parametro SET valor = '24' WHERE clave = 'terminal_caducidad_alta_horas' AND vigente_hasta IS NULL;
UPDATE tiempo.parametro SET valor = '12' WHERE clave = 'terminal_llave_max_meses' AND vigente_hasta IS NULL;
UPDATE tiempo.parametro SET valor = '7'  WHERE clave = 'terminal_traslape_llave_max_dias' AND vigente_hasta IS NULL;
UPDATE tiempo.parametro SET valor = '7'  WHERE clave = 'terminal_anomalias_ventana_dias' AND vigente_hasta IS NULL;
UPDATE tiempo.parametro SET valor = '90' WHERE clave = 'terminal_retencion_rechazos_dias' AND vigente_hasta IS NULL;

-- F. Guard en la pantalla genérica de Parámetros
SELECT pg_temp.caso('60 fn_parametro_actualizar_valor con una clave terminal_% (service_role, como la usa el backend) -> SCJ17 clave_reservada', 'service_role',
  $$SELECT tiempo.fn_parametro_actualizar_valor('terminal_llave_max_meses', '5', NULL)$$, 'SCJ17', '-', 'clave_reservada');
SELECT pg_temp.caso('60b ... también la caducidad -> SCJ17', 'service_role', $$SELECT tiempo.fn_parametro_actualizar_valor('terminal_caducidad_alta_horas', '5', NULL)$$, 'SCJ17', '-', 'clave_reservada');
SELECT pg_temp.caso('60c una clave normal sigue funcionando (tolerancia_retardo_min a 11)', 'service_role', $$SELECT tiempo.fn_parametro_actualizar_valor('tolerancia_retardo_min', '11', NULL)$$, 'ok', '-');
SELECT pg_temp.caso('60d una clave inexistente sigue dando SCJ02', 'service_role', $$SELECT tiempo.fn_parametro_actualizar_valor('no_existe', '1', NULL)$$, 'SCJ02', '-');
SELECT pg_temp.caso('60e authenticated sigue sin EXECUTE de fn_parametro_actualizar_valor', 'authenticated', $$SELECT tiempo.fn_parametro_actualizar_valor('tolerancia_retardo_min', '12', NULL)$$, '42501');
SELECT pg_temp.verifica('60f el guard no tocó las claves terminal_%', $$SELECT pg_temp.act('terminal_llave_max_meses') = '12' AND pg_temp.act('terminal_caducidad_alta_horas') = '24'$$);

-- G. Verificador acumulado hasta 89_ (extracto de db/verificar_ddl.sql: secciones 41 a 52, sin la 53 de 90_). Todas deben dar 0 filas.
\ir verificar_89.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
