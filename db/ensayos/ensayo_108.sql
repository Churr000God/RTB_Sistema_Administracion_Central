-- Ensayo de 108_personas_select_padron_por_permiso.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_108.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 108_. Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
-- ROLLBACK descarta). El administrador real solo es caller. Cada rol se mide con SET ROLE authenticated + claims con su auth uid: cuántas filas VE de persona, expediente, usuario y asignacion.
-- RESIDUAL ACEPTADO (ver cabecera de 108_): no hay RLS por columna; quien pasa la regla ve la fila completa de persona (CURP/RFC/NSS).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _vis (fase text, quien text, p bigint, e bigint, u bigint, a bigint);
GRANT ALL ON _ens, _res, _vis TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_admin', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

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
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 120));
END;
$$ LANGUAGE plpgsql;

-- Mide cuántas filas ve p_rol (authenticated/service_role) con claims p_sub en las 4 tablas.
CREATE FUNCTION pg_temp.mide(p_fase text, p_quien text, p_rol text, p_sub text) RETURNS void AS $$
DECLARE a bigint; b bigint; c bigint; d bigint;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_rol)::text, true);
  SELECT count(*) INTO a FROM personas.persona;
  SELECT count(*) INTO b FROM personas.expediente;
  SELECT count(*) INTO c FROM personas.usuario;
  SELECT count(*) INTO d FROM personas.asignacion;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _vis VALUES (p_fase, p_quien, a, b, c, d);
END;
$$ LANGUAGE plpgsql;

-- ---------- fixture ----------
CREATE FUNCTION pg_temp.mk_persona(p_k text, p_n int, p_puesto text, p_permiso text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXZ' || p_n, 'XEXZ0101' || lpad(p_n::text, 4, '0'), '999999' || lpad(p_n::text, 5, '0'), 'Sintetica108' || p_k, 'Ensayo108', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXZ' || p_n;
  INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
  VALUES ((SELECT v::uuid FROM _ens WHERE k = p_k), 'indefinido', 'RTB-RH-EIT-2026-' || (800 + p_n));
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens108' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens108' || lower(p_k));
  IF p_puesto IS NOT NULL THEN
    INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
    SELECT departamento_id, p_puesto, 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
    IF p_permiso IS NOT NULL THEN
      INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
      SELECT id, p_permiso, 'otorgado' FROM personas.puesto WHERE nombre_puesto = p_puesto;
    END IF;
    INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
    SELECT (SELECT v::uuid FROM _ens WHERE k = p_k), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = p_puesto;
  END IF;
END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.mk_persona('S1', 1, NULL, NULL);                                   -- sin puesto
SELECT pg_temp.mk_persona('S2', 2, 'ENS108 sin permisos', NULL);                  -- puesto sin permisos
SELECT pg_temp.mk_persona('S3', 3, 'ENS108 tiempo', 'marca_lectura');             -- solo Tiempo
SELECT pg_temp.mk_persona('S4', 4, 'ENS108 terminales', 'terminal_usuario_lectura');
SELECT pg_temp.mk_persona('S5', 5, 'ENS108 modulo1', 'ver_modulo_1');
SELECT pg_temp.mk_persona('S6', 6, 'ENS108 alta', 'alta_personas_usuarios');      -- solo alta
SELECT pg_temp.mk_persona('S7', 7, 'ENS108 cambio estado', 'cambio_estado_persona');
SELECT pg_temp.mk_persona('S8', 8, 'ENS108 modulo1 suspendida', 'ver_modulo_1');  -- se suspende abajo
SELECT pg_temp.mk_persona('S9', 9, 'ENS108 edicion', 'persona_edicion');
SELECT pg_temp.mk_persona('S10', 13, 'ENS108 puesto permiso lectura', 'puesto_permiso_lectura');
SELECT pg_temp.mk_persona('S11', 15, 'ENS108 jefe herencia', NULL);   -- sin permisos propios: hereda ausencia_lectura (heredable) del subordinado
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS108 subordinado herencia', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'ENS108 jefe herencia';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'ausencia_lectura', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS108 subordinado herencia';
SELECT pg_temp.mk_persona('S12', 14, NULL, NULL);
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'S12'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS108 subordinado herencia';
-- Objetivo sin usuario ni puesto para los casos de escritura
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXZ10', 'XEXZ01010010', '99999900010', 'Objetivo108', 'Ensayo108', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'OBJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXZ10';
INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'OBJ'), 'indefinido', 'RTB-RH-EIT-2026-810');
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'S8');

INSERT INTO _ens SELECT 'tot_p', count(*)::text FROM personas.persona;
INSERT INTO _ens SELECT 'tot_e', count(*)::text FROM personas.expediente;
INSERT INTO _ens SELECT 'tot_u', count(*)::text FROM personas.usuario;
INSERT INTO _ens SELECT 'tot_a', count(*)::text FROM personas.asignacion;

-- ---------- ANTES de 108_: el hueco ----------
SELECT pg_temp.mide('antes', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.mide('antes', 'S2 puesto sin permisos', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S2'));
SELECT pg_temp.verifica('A0 (documenta el hueco) ANTES de 108_: una persona SIN puesto ve TODO el padrón (persona, expediente, usuario)',
  $$SELECT p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND e = (SELECT v::bigint FROM _ens WHERE k = 'tot_e') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') AND p > 1 FROM _vis WHERE fase = 'antes' AND quien = 'S1 sin puesto'$$);

\ir ../ddl/108_personas_select_padron_por_permiso.sql

-- ============================================================================
-- A) Atributos de la función nueva
-- ============================================================================
SELECT pg_temp.verifica('A1 fn_caller_ve_padron: SECURITY DEFINER, STABLE, search_path = personas, pg_temp, dueño postgres, no LEAKPROOF, devuelve boolean',
  $$SELECT p.prosecdef AND p.provolatile = 's' AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres' AND NOT p.proleakproof AND pg_get_function_result(p.oid) = 'boolean'
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_caller_ve_padron'$$);
SELECT pg_temp.verifica('A2 EXECUTE solo authenticated y service_role (ni PUBLIC ni anon)',
  $$SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname = 'fn_caller_ve_padron'$$);
SELECT pg_temp.verifica('A3 las 4 policies de SELECT existen, son SELECT, y llaman a fn_caller_ve_padron (sin recursión: las de usuario y asignacion no llaman a fn_caller_tiene_permiso)',
  $$SELECT count(*) = 4 AND bool_and(qual LIKE '%fn_caller_ve_padron%') AND bool_and(CASE WHEN tablename IN ('usuario', 'asignacion') THEN qual NOT LIKE '%fn_caller_tiene_permiso%' ELSE true END)
    FROM pg_policies WHERE schemaname = 'personas' AND tablename IN ('persona', 'expediente', 'usuario', 'asignacion') AND policyname LIKE '%select_caller_activo' AND cmd = 'SELECT'$$);
SELECT pg_temp.verifica('A4 las policies de INSERT/UPDATE/DELETE de esas tablas NO cambiaron (la cantidad por tabla y comando es la de antes: 76 policies en total)',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 76$$);

-- ============================================================================
-- B) Visibilidad por rol (filas que VE en persona / expediente / usuario / asignacion)
-- ============================================================================
SELECT pg_temp.mide('despues', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.mide('despues', 'S2 puesto sin permisos', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S2'));
SELECT pg_temp.mide('despues', 'S3 solo Tiempo (marca_lectura)', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.mide('despues', 'S4 solo Terminales (terminal_usuario_lectura)', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S4'));
SELECT pg_temp.mide('despues', 'S5 ver_modulo_1', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.mide('despues', 'S6 solo alta_personas_usuarios', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S6'));
SELECT pg_temp.mide('despues', 'S7 solo cambio_estado_persona', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S7'));
SELECT pg_temp.mide('despues', 'S8 suspendida con ver_modulo_1', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S8'));
SELECT pg_temp.mide('despues', 'S9 solo persona_edicion', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S9'));
SELECT pg_temp.mide('despues', 'S10 solo puesto_permiso_lectura', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S10'));
SELECT pg_temp.mide('despues', 'admin real', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_admin'));
SELECT pg_temp.mide('despues', 'service_role', 'service_role', (SELECT v FROM _ens WHERE k = 'auth_admin'));

SELECT pg_temp.verifica('B1 persona SIN puesto: ve SOLO su fila en persona, expediente y usuario, y 0 asignaciones (no tiene)',
  $$SELECT p = 1 AND e = 1 AND u = 1 AND a = 0 FROM _vis WHERE fase = 'despues' AND quien = 'S1 sin puesto'$$);
SELECT pg_temp.verifica('B2 puesto SIN permisos: ve SOLO su fila en persona, expediente y usuario, y su propia asignación (1)',
  $$SELECT p = 1 AND e = 1 AND u = 1 AND a = 1 FROM _vis WHERE fase = 'despues' AND quien = 'S2 puesto sin permisos'$$);
SELECT pg_temp.verifica('B3 solo permisos de Tiempo (marca_lectura): ve todo el padrón (para no romper nombres; RESIDUAL aceptado: incluye CURP/RFC/NSS)',
  $$SELECT p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND e = (SELECT v::bigint FROM _ens WHERE k = 'tot_e') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') AND a = (SELECT v::bigint FROM _ens WHERE k = 'tot_a')
    FROM _vis WHERE fase = 'despues' AND quien LIKE 'S3 %'$$);
SELECT pg_temp.verifica('B4 solo permisos de Terminales: ve todo (nombres de altas y autores)',
  $$SELECT p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') AND a = (SELECT v::bigint FROM _ens WHERE k = 'tot_a') FROM _vis WHERE fase = 'despues' AND quien LIKE 'S4 %'$$);
SELECT pg_temp.verifica('B5 ver_modulo_1, alta_personas_usuarios, cambio_estado_persona, persona_edicion y puesto_permiso_lectura: cada uno ve todo (el último, para que routers/permisos.py resuelva autores)',
  $$SELECT count(*) = 5 AND bool_and(p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND e = (SELECT v::bigint FROM _ens WHERE k = 'tot_e') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') AND a = (SELECT v::bigint FROM _ens WHERE k = 'tot_a'))
    FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S5 %' OR quien LIKE 'S6 %' OR quien LIKE 'S7 %' OR quien LIKE 'S9 %' OR quien LIKE 'S10 %')$$);
SELECT pg_temp.verifica('B6 persona SUSPENDIDA con ver_modulo_1: no ve nada (ni su fila), como antes',
  $$SELECT p = 0 AND e = 0 AND u = 0 AND a = 0 FROM _vis WHERE fase = 'despues' AND quien LIKE 'S8 %'$$);
SELECT pg_temp.verifica('B7 el administrador real ve todo',
  $$SELECT p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND a = (SELECT v::bigint FROM _ens WHERE k = 'tot_a') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') FROM _vis WHERE fase = 'despues' AND quien = 'admin real'$$);
SELECT pg_temp.verifica('B8 service_role INTACTO: ve todo (bypassa RLS)',
  $$SELECT p = (SELECT v::bigint FROM _ens WHERE k = 'tot_p') AND e = (SELECT v::bigint FROM _ens WHERE k = 'tot_e') AND u = (SELECT v::bigint FROM _ens WHERE k = 'tot_u') AND a = (SELECT v::bigint FROM _ens WHERE k = 'tot_a') FROM _vis WHERE fase = 'despues' AND quien = 'service_role'$$);
SELECT pg_temp.caso('B9 anon: sin privilegio de tabla => 42501', 'anon', $$SELECT count(*) FROM personas.persona$$, '42501');
SELECT pg_temp.caso('B9b anon: usuario => 42501', 'anon', $$SELECT count(*) FROM personas.usuario$$, '42501');

-- ============================================================================
-- C) Lo que NO debe romperse
-- ============================================================================
SELECT pg_temp.caso('C1 fn_caller_tiene_permiso sigue leyendo SUS filas: persona sin puesto => false sin error', 'authenticated', $$SELECT personas.fn_caller_tiene_permiso('ver_modulo_1')$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S1'));
DO $$
DECLARE v1 boolean; v2 boolean; v3 boolean; v4 boolean;
BEGIN
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_S5'), 'role', 'authenticated')::text, true);
  v1 := personas.fn_caller_tiene_permiso('ver_modulo_1');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_S1'), 'role', 'authenticated')::text, true);
  v2 := personas.fn_caller_tiene_permiso('ver_modulo_1');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_S3'), 'role', 'authenticated')::text, true);
  v3 := personas.fn_caller_tiene_permiso('marca_lectura');
  v4 := personas.fn_caller_ve_padron();
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES ('C2 fn_caller_tiene_permiso con RLS cerrada: S5 ver_modulo_1 = true, S1 = false, S3 marca_lectura = true; fn_caller_ve_padron(S3) = true',
    v1 AND NOT v2 AND v3 AND v4, format('S5=%s S1=%s S3=%s ve_padron(S3)=%s', v1, v2, v3, v4));
END $$;
SELECT pg_temp.caso('C3 fn_persona_crear por S6 (solo alta_personas_usuarios): el INSERT … RETURNING VE la fila nueva y funciona', 'authenticated',
  $$SELECT personas.fn_persona_crear(p_primer_nombre => 'Alta108', p_apellido_paterno => 'Ensayo108', p_curp => 'XEXX010101HNEXXZ11', p_rfc => 'XEXZ01010011', p_nss => '99999900011',
      p_fecha_nacimiento => DATE '2000-01-01', p_fecha_ingreso => CURRENT_DATE, p_tipo_contrato => 'indefinido', p_documento_ref => 'RTB-RH-EIT-2026-811')$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S6'));
SELECT pg_temp.caso('C3b fn_persona_crear por S1 (sin permiso) => 42501', 'authenticated',
  $$SELECT personas.fn_persona_crear(p_primer_nombre => 'x', p_apellido_paterno => 'y', p_curp => 'XEXX010101HNEXXZ12', p_rfc => 'XEXZ01010012', p_nss => '99999900012',
      p_fecha_nacimiento => DATE '2000-01-01', p_fecha_ingreso => CURRENT_DATE, p_tipo_contrato => 'indefinido', p_documento_ref => 'RTB-RH-EIT-2026-812')$$, '42501', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.caso('C4 fn_persona_actualizar_datos por S9 (solo persona_edicion) sobre la persona objetivo', 'authenticated',
  format($f$SELECT personas.fn_persona_actualizar_datos(%L::uuid, p_primer_nombre => 'Editado108')$f$, (SELECT v FROM _ens WHERE k = 'OBJ')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S9'));
SELECT pg_temp.verifica('C4b ... y el cambio se aplicó', $$SELECT primer_nombre = 'Editado108' FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'OBJ')$$);
SELECT pg_temp.caso('C5 trigger fn_bitacora_sincroniza_persona: S7 (solo cambio_estado_persona) suspende a la persona objetivo por la bitácora', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens108', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S7')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S7'));
SELECT pg_temp.verifica('C5b ... y la persona objetivo quedó en suspensión (el UPDATE del trigger vio la fila)', $$SELECT estado = 'suspension' FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'OBJ')$$);
SELECT pg_temp.caso('C6 embed/JOIN persona + expediente como S1: solo su fila (lo que devolvería un embed de PostgREST); division por cero si no es 1', 'authenticated',
  $$SELECT 1 / (CASE WHEN (SELECT count(*) FROM personas.persona p LEFT JOIN personas.expediente e ON e.persona_id = p.id) = 1 THEN 1 ELSE 0 END)$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.caso('C7 lecturas de tiempo.persona SIN CAMBIO: S1 la sigue leyendo (solo id)', 'authenticated', $$SELECT count(*) FROM tiempo.persona$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.verifica('C8 el trigger de la frontera sigue creando el stub de tiempo.persona (fn_persona_sincroniza_tiempo): las personas de C3 existen en tiempo.persona',
  $$SELECT EXISTS (SELECT 1 FROM tiempo.persona t JOIN personas.persona p ON p.id = t.id WHERE p.curp = 'XEXX010101HNEXXZ11')$$);
SELECT pg_temp.caso('C9 permisos.py: S2 (puesto sin permisos) lee SU usuario y SUS puestos vigentes (los gates de todas las rutas); division por cero si no son 1 y 1', 'authenticated',
  format($f$SELECT 1 / (CASE WHEN (SELECT count(*) FROM personas.usuario WHERE auth_user_id = %L::uuid) = 1 AND (SELECT count(*) FROM personas.asignacion WHERE persona_id = %L::uuid AND vigente_hasta IS NULL) = 1 THEN 1 ELSE 0 END)$f$,
         (SELECT v FROM _ens WHERE k = 'auth_S2'), (SELECT v FROM _ens WHERE k = 'S2')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S2'));

-- Equivalencia: la función de UNA consulta == «alguno de los 27 con fn_caller_tiene_permiso» (la formulación original), para cada persona del fixture y el admin
DO $$
DECLARE r record; v_nuevo boolean; v_viejo boolean; v_malos text := ''; v_n int := 0;
BEGIN
  FOR r IN SELECT k, v FROM _ens WHERE k LIKE 'auth\_%' ESCAPE '\' LOOP
    SET LOCAL ROLE authenticated;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.v, 'role', 'authenticated')::text, true);
    v_nuevo := personas.fn_caller_ve_padron();
    v_viejo := personas.fn_caller_activo() AND EXISTS (SELECT 1 FROM unnest(ARRAY[
         'ver_modulo_1', 'ver_modulo_2', 'ver_modulo_3', 'alta_personas_usuarios', 'persona_edicion', 'cambio_estado_persona',
         'asignacion_lectura', 'asignacion_edicion', 'puesto_lectura', 'puesto_edicion', 'ausencia_lectura', 'ausencia_edicion', 'excepcion_lectura', 'excepcion_edicion',
         'marca_lectura', 'captura_manual_edicion', 'jornada_asignada_lectura', 'jornada_asignada_edicion', 'dia_revision_edicion', 'clasificacion_de_tiempo_lectura',
         'permiso_lectura', 'permiso_edicion', 'puesto_permiso_lectura', 'puesto_permiso_edicion', 'terminal_usuario_lectura', 'terminal_usuario_edicion', 'terminal_config_edicion'
       ]) AS c(codigo) WHERE personas.fn_caller_tiene_permiso(c.codigo));
    RESET ROLE;
    v_n := v_n + 1;
    IF v_nuevo IS DISTINCT FROM v_viejo THEN v_malos := v_malos || r.k || ' '; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES ('C10 fn_caller_ve_padron (una consulta) == alguno de los 27 con fn_caller_tiene_permiso, para cada persona del fixture y el admin (herencia incluida: S11 hereda de su subordinado)', v_n >= 12 AND v_malos = '', format('personas=%s discrepantes=[%s]', v_n, v_malos));
END $$;

-- ============================================================================
-- D) Reversa documentada
-- ============================================================================
DROP POLICY persona_select_caller_activo ON personas.persona;
CREATE POLICY persona_select_caller_activo ON personas.persona FOR SELECT USING (personas.fn_caller_activo());
DROP POLICY expediente_select_caller_activo ON personas.expediente;
CREATE POLICY expediente_select_caller_activo ON personas.expediente FOR SELECT USING (personas.fn_caller_activo());
DROP POLICY usuario_select_caller_activo ON personas.usuario;
CREATE POLICY usuario_select_caller_activo ON personas.usuario FOR SELECT USING (personas.fn_caller_activo());
DROP POLICY asignacion_select_caller_activo ON personas.asignacion;
CREATE POLICY asignacion_select_caller_activo ON personas.asignacion FOR SELECT USING (personas.fn_caller_activo());
DROP FUNCTION personas.fn_caller_ve_padron();
SELECT pg_temp.mide('reversa', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.verifica('D1 tras la reversa S1 vuelve a ver todo el padrón y la función no existe (estado de antes)',
  $$SELECT p > 1 AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_caller_ve_padron') FROM _vis WHERE fase = 'reversa'$$);
\ir ../ddl/108_personas_select_padron_por_permiso.sql
SELECT pg_temp.verifica('D2 108_ reaplicable tras la reversa', $$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'personas'::regnamespace AND proname = 'fn_caller_ve_padron')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT quien, p AS persona, e AS expediente, u AS usuario, a AS asignacion, fase FROM _vis ORDER BY fase DESC, quien;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
