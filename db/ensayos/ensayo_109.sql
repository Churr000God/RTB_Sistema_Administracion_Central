-- Ensayo de 109_personas_select_bitacoras_por_permiso.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_109.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 109_ (sin 108_). Personas, expedientes, usuarios, puestos y permisos SINTÉTICOS creados en la transacción y revertidos (incluye filas en bitácoras inmutables, que el
-- ROLLBACK descarta). El administrador real solo es caller. Cada rol se mide con SET ROLE authenticated + claims con su auth uid: cuántas filas VE de persona, expediente, usuario y asignacion.
-- Mide cuántas filas ve cada rol en las 2 bitácoras (movimientos de persona y movimientos de permisos de puesto).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _vis (fase text, quien text, bp bigint, bpp bigint, pp bigint);
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

CREATE FUNCTION pg_temp.mide(p_fase text, p_quien text, p_rol text, p_sub text) RETURNS void AS $$
DECLARE a bigint; b bigint; c bigint;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_rol)::text, true);
  SELECT count(*) INTO a FROM personas.bitacora_movimiento_persona;
  SELECT count(*) INTO b FROM personas.bitacora_movimiento_puesto_permiso;
  SELECT count(*) INTO c FROM personas.puesto_permiso;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _vis VALUES (p_fase, p_quien, a, b, c);
END;
$$ LANGUAGE plpgsql;

-- ---------- fixture ----------
CREATE FUNCTION pg_temp.mk_persona(p_k text, p_n int, p_puesto text, p_permiso text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXW' || p_n, 'XEXW0101' || lpad(p_n::text, 4, '0'), '999998' || lpad(p_n::text, 5, '0'), 'Sintetica109' || p_k, 'Ensayo109', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXW' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens109' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens109' || lower(p_k));
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

SELECT pg_temp.mk_persona('S1', 1, NULL, NULL);                                             -- sin puesto
SELECT pg_temp.mk_persona('S2', 2, 'ENS109 sin permisos', NULL);                            -- puesto sin permisos
SELECT pg_temp.mk_persona('S3', 3, 'ENS109 tiempo', 'ausencia_lectura');                    -- solo Tiempo
SELECT pg_temp.mk_persona('S4', 4, 'ENS109 modulo1', 'ver_modulo_1');
SELECT pg_temp.mk_persona('S5', 5, 'ENS109 cambio estado', 'cambio_estado_persona');
SELECT pg_temp.mk_persona('S6', 6, 'ENS109 edicion', 'persona_edicion');
SELECT pg_temp.mk_persona('S7', 7, 'ENS109 alta', 'alta_personas_usuarios');
SELECT pg_temp.mk_persona('S8', 8, 'ENS109 modulo2', 'ver_modulo_2');
SELECT pg_temp.mk_persona('S9', 9, 'ENS109 permiso lectura', 'permiso_lectura');
SELECT pg_temp.mk_persona('S10', 10, 'ENS109 puesto permiso edicion', 'puesto_permiso_edicion');
SELECT pg_temp.mk_persona('S11', 11, 'ENS109 modulo1 suspendida', 'ver_modulo_1');
UPDATE personas.persona SET estado = 'suspension' WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'S11');
-- Objetivo (sin usuario) y puesto objetivo para las escrituras
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXW20', 'XEXW01010020', '99999800020', 'Objetivo109', 'Ensayo109', DATE '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'OBJ', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXW20';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS109 puesto objetivo', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';

-- Rama: S12 ocupa un puesto con permiso heredable (ausencia_lectura) y S13 ocupa un puesto hijo SIN permisos; S2 ('sin permisos') es hoja ajena.
SELECT pg_temp.mk_persona('S12', 14, 'ENS109 jefe rama', 'ausencia_lectura');
SELECT pg_temp.mk_persona('S13', 15, NULL, NULL);
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS109 subordinado rama', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'ENS109 jefe rama';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k = 'S13'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS109 subordinado rama';
INSERT INTO _ens SELECT 'tot_pp', count(*)::text FROM personas.puesto_permiso;
INSERT INTO _ens SELECT 'tot_bp', count(*)::text FROM personas.bitacora_movimiento_persona;
INSERT INTO _ens SELECT 'tot_bpp', count(*)::text FROM personas.bitacora_movimiento_puesto_permiso;

-- ---------- ANTES de 109_: el hueco ----------
SELECT pg_temp.mide('antes', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.verifica('A0 (documenta el hueco) ANTES de 109_: una persona SIN puesto ve TODO el historial de movimientos y de permisos',
  $$SELECT bp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bp') AND bpp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bpp') AND bp > 0 AND bpp > 0 FROM _vis WHERE fase = 'antes'$$);

\ir ../ddl/109_personas_select_bitacoras_por_permiso.sql

-- ============================================================================
-- A) Estructura
-- ============================================================================
SELECT pg_temp.verifica('A1 la policy de bitácora de persona exige permiso (fn_caller_tiene_permiso, una vez por consulta con SELECT)',
  $$SELECT count(*) = 1 AND bool_and(qual LIKE '%fn_caller_tiene_permiso%' AND qual LIKE '%SELECT personas.fn_caller_tiene_permiso%')
    FROM pg_policies WHERE schemaname = 'personas' AND cmd = 'SELECT' AND policyname = 'bitacora_select_caller_activo'$$);
SELECT pg_temp.verifica('A1b las 2 funciones nuevas: SECURITY DEFINER, STABLE, search_path = personas, pg_temp, EXECUTE solo authenticated y service_role; y puesto_permiso + bitácora de permisos las usan',
  $$SELECT count(*) = 2 AND bool_and(p.prosecdef AND p.provolatile = 's' AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND NOT p.proleakproof
        AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
        AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))
      AND (SELECT count(*) FROM pg_policies WHERE schemaname = 'personas' AND tablename IN ('puesto_permiso', 'bitacora_movimiento_puesto_permiso') AND cmd = 'SELECT' AND qual LIKE '%fn_caller_puestos_en_rama%' AND qual LIKE '%fn_caller_ve_estructura_permisos%') = 2
    FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname IN ('fn_caller_ve_estructura_permisos', 'fn_caller_puestos_en_rama')$$);
SELECT pg_temp.verifica('A2 109_ no cambia el número total de policies (76)',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 76$$);

-- ============================================================================
-- B) Visibilidad por rol (filas que VE en las 2 bitácoras)
-- ============================================================================
SELECT pg_temp.mide('despues', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.mide('despues', 'S2 puesto sin permisos', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S2'));
SELECT pg_temp.mide('despues', 'S3 solo Tiempo (ausencia_lectura)', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S3'));
SELECT pg_temp.mide('despues', 'S4 ver_modulo_1', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S4'));
SELECT pg_temp.mide('despues', 'S5 cambio_estado_persona', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.mide('despues', 'S6 persona_edicion', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S6'));
SELECT pg_temp.mide('despues', 'S7 alta_personas_usuarios', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S7'));
SELECT pg_temp.mide('despues', 'S8 ver_modulo_2', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S8'));
SELECT pg_temp.mide('despues', 'S9 permiso_lectura', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S9'));
SELECT pg_temp.mide('despues', 'S10 puesto_permiso_edicion', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S10'));
SELECT pg_temp.mide('despues', 'S11 suspendida con ver_modulo_1', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S11'));
SELECT pg_temp.mide('despues', 'admin real', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_admin'));
SELECT pg_temp.mide('despues', 'service_role', 'service_role', (SELECT v FROM _ens WHERE k = 'auth_admin'));

SELECT pg_temp.mide('despues', 'S12 jefe de rama (ausencia_lectura)', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S12'));
SELECT pg_temp.mide('despues', 'S13 subordinado sin permisos', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S13'));
SELECT pg_temp.verifica('B0 puesto_permiso: sin puesto y puesto sin permisos 0 filas propias; S2 ve solo los de su rama (0 porque su puesto no tiene permisos); estructura ve todo; subordinado sin permisos NO ve los del jefe; el jefe ve los suyos y los de su rama',
  $$SELECT (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S1 %') = 0
      AND (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S2 %') = 0
      AND (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S8 %') = (SELECT v::bigint FROM _ens WHERE k = 'tot_pp')
      AND (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S9 %') = (SELECT v::bigint FROM _ens WHERE k = 'tot_pp')
      AND (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S13 %') = 0
      AND (SELECT pp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S12 %') = 1$$);
SELECT pg_temp.verifica('B0b bitácora de permisos: el jefe de rama ve solo SU fila de otorgamiento (1), el subordinado 0',
  $$SELECT (SELECT bpp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S12 %') = 1 AND (SELECT bpp FROM _vis WHERE fase = 'despues' AND quien LIKE 'S13 %') = 0$$);
SELECT pg_temp.caso('B0c herencia con la RLS cerrada: el jefe (ausencia_lectura heredable) => true; el subordinado => false (el permiso se hereda hacia ARRIBA)', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('ausencia_lectura') THEN 1 ELSE 0 END)$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S12'));
SELECT pg_temp.caso('B0d el subordinado NO tiene ausencia_lectura (division por cero si lo tuviera)', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('ausencia_lectura') THEN 0 ELSE 1 END)$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S13'));
SELECT pg_temp.verifica('B1 sin puesto y puesto sin permisos: 0 movimientos y 0 permisos; solo Tiempo (S3): 0 movimientos de persona y SOLO la fila de otorgamiento de su propio puesto (1)',
  $$SELECT (SELECT count(*) FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S1 %' OR quien LIKE 'S2 %') AND bp = 0 AND bpp = 0) = 2
      AND (SELECT count(*) FROM _vis WHERE fase = 'despues' AND quien LIKE 'S3 %' AND bp = 0 AND bpp = 1) = 1$$);
SELECT pg_temp.verifica('B2 ver_modulo_1, cambio_estado_persona, persona_edicion y alta_personas_usuarios: ven TODOS los movimientos de persona y solo la fila de otorgamiento de su propio puesto (1) en la de permisos',
  $$SELECT count(*) = 4 AND bool_and(bp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bp') AND bpp = 1)
    FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S4 %' OR quien LIKE 'S5 %' OR quien LIKE 'S6 %' OR quien LIKE 'S7 %')$$);
SELECT pg_temp.verifica('B3 ver_modulo_2, permiso_lectura y puesto_permiso_edicion: ven TODOS los movimientos de permisos y 0 de persona',
  $$SELECT count(*) = 3 AND bool_and(bp = 0 AND bpp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bpp'))
    FROM _vis WHERE fase = 'despues' AND (quien LIKE 'S8 %' OR quien LIKE 'S9 %' OR quien LIKE 'S10 %')$$);
SELECT pg_temp.verifica('B4 persona SUSPENDIDA con ver_modulo_1: no ve nada',
  $$SELECT bp = 0 AND bpp = 0 FROM _vis WHERE fase = 'despues' AND quien LIKE 'S11 %'$$);
SELECT pg_temp.verifica('B5 admin real y service_role (RLS bypass) ven todo en las dos',
  $$SELECT count(*) = 2 AND bool_and(bp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bp') AND bpp = (SELECT v::bigint FROM _ens WHERE k = 'tot_bpp')) FROM _vis WHERE fase = 'despues' AND quien IN ('admin real', 'service_role')$$);
SELECT pg_temp.caso('B6 anon => 42501', 'anon', $$SELECT count(*) FROM personas.bitacora_movimiento_persona$$, '42501');

-- ============================================================================
-- C) Lo que NO debe romperse: INSERT … RETURNING y triggers
-- ============================================================================
SELECT pg_temp.caso('C1 cambio_estado_persona (S5) registra un movimiento y VE la fila (INSERT … RETURNING, como routers/movimientos.py)', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'suspension', now(), 'ens109', %L::uuid) RETURNING id$f$,
         (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S5')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.verifica('C1b ... y el trigger sincronizó el estado de la persona objetivo', $$SELECT estado = 'suspension' FROM personas.persona WHERE id = (SELECT v::uuid FROM _ens WHERE k = 'OBJ')$$);
SELECT pg_temp.caso('C2 sin cambio_estado_persona (S1) el INSERT del movimiento => 42501', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L::uuid, 'reactivacion', now(), 'ens109', %L::uuid) RETURNING id$f$,
         (SELECT v FROM _ens WHERE k = 'OBJ'), (SELECT v FROM _ens WHERE k = 'auth_S1')), '42501', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.caso('C3 puesto_permiso_edicion (S10) otorga un permiso a un puesto no administrador y VE la fila (INSERT … RETURNING, como routers/permisos.py)', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento, registrado_por) SELECT id, 'ausencia_lectura', 'otorgado', %L::uuid FROM personas.puesto WHERE nombre_puesto = 'ENS109 puesto objetivo' RETURNING id$f$,
         (SELECT v FROM _ens WHERE k = 'auth_S10')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S10'));
SELECT pg_temp.verifica('C3b ... y el trigger fn_puesto_permiso_sincroniza dejó el permiso activo en el puesto objetivo',
  $$SELECT EXISTS (SELECT 1 FROM personas.puesto_permiso pp JOIN personas.puesto p ON p.id = pp.puesto_id WHERE p.nombre_puesto = 'ENS109 puesto objetivo' AND pp.codigo = 'ausencia_lectura' AND pp.activo)$$);
SELECT pg_temp.caso('C4 sin puesto_permiso_edicion (S5) el INSERT de permiso => 42501', 'authenticated',
  format($f$INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento, registrado_por) SELECT id, 'marca_lectura', 'otorgado', %L::uuid FROM personas.puesto WHERE nombre_puesto = 'ENS109 puesto objetivo'$f$,
         (SELECT v FROM _ens WHERE k = 'auth_S5')), '42501', (SELECT v FROM _ens WHERE k = 'auth_S5'));
SELECT pg_temp.caso('C5 la ficha de una persona sin puesto: GET de sus movimientos devuelve lista vacía SIN error (SELECT … WHERE persona_id = propia)', 'authenticated',
  format($f$SELECT * FROM personas.bitacora_movimiento_persona WHERE persona_id = %L::uuid ORDER BY fecha_efectiva DESC$f$, (SELECT v FROM _ens WHERE k = 'S1')), 'ok', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.caso('C6 fn_caller_tiene_permiso sigue leyendo sus filas con la bitácora cerrada (S5 cambio_estado_persona)', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('cambio_estado_persona') THEN 1 ELSE 0 END)$$, 'ok', (SELECT v FROM _ens WHERE k = 'auth_S5'));

-- ============================================================================
-- E) Estado final con 108_ Y 109_ juntas + equivalencia de permisos.py (tiene_permiso lee puesto_permiso por código con el cliente del caller y resuelve la herencia en Python)
-- ============================================================================
\ir ../ddl/108_personas_select_padron_por_permiso.sql
CREATE FUNCTION pg_temp.codigos_derivados() RETURNS text AS $$
  -- Réplica en SQL de backend/app/permisos.py::tiene_permiso para TODOS los códigos: puestos vigentes del caller (asignacion), poseedores = filas activas de puesto_permiso VISIBLES,
  -- permiso heredable => también los descendientes de los puestos vigentes (árbol de puesto, abierto). Devuelve el conjunto ordenado de códigos.
  WITH RECURSIVE me AS (SELECT personas.fn_caller_persona_id() AS id),
  vig AS (SELECT a.puesto_id AS id FROM personas.asignacion a JOIN me ON me.id = a.persona_id WHERE a.vigente_hasta IS NULL),
  rama AS (SELECT id FROM vig UNION SELECT pu.id FROM personas.puesto pu JOIN rama r ON pu.reporta_a_id = r.id)
  SELECT COALESCE(string_agg(DISTINCT pp.codigo, ',' ORDER BY pp.codigo), '')
  FROM personas.puesto_permiso pp
  JOIN personas.permiso pe ON pe.codigo = pp.codigo
  WHERE pp.activo AND (pp.puesto_id IN (SELECT id FROM vig) OR (pe.heredable AND pp.puesto_id IN (SELECT id FROM rama)));
$$ LANGUAGE sql STABLE;
GRANT EXECUTE ON FUNCTION pg_temp.codigos_derivados() TO PUBLIC;
DO $$
DECLARE r record; v_vis text; v_todas text; v_n int := 0; v_igual int := 0; v_malos text := ''; v_noempty int := 0;
BEGIN
  FOR r IN SELECT k, v FROM _ens WHERE k LIKE 'auth\_%' ESCAPE '\' ORDER BY k LOOP
    -- todas las filas: como dueño (sin RLS) pero con la identidad del caller en los claims (fn_caller_persona_id usa auth.uid())
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.v, 'role', 'authenticated')::text, true);
    v_todas := pg_temp.codigos_derivados();
    SET LOCAL ROLE authenticated;
    v_vis := pg_temp.codigos_derivados();
    RESET ROLE;
    v_n := v_n + 1;
    IF r.k = 'auth_S11' THEN
      -- persona SUSPENDIDA: fn_caller_activo() es false, no ve ninguna fila (igual que antes de 109_; el backend ya la corta en /api/sesion): se espera el conjunto vacío
      IF v_vis = '' THEN v_igual := v_igual + 1; ELSE v_malos := v_malos || r.k || ' '; END IF;
    ELSIF v_vis = v_todas THEN v_igual := v_igual + 1;
    ELSE v_malos := v_malos || r.k || ' ';
    END IF;
    IF v_todas <> '' THEN v_noempty := v_noempty + 1; END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle)
  VALUES ('E1 conjunto de códigos derivado de las filas VISIBLES de puesto_permiso == derivado de TODAS, por persona sintética (con 108_ y 109_ aplicadas); la suspendida debe derivar el conjunto vacío',
          v_n >= 13 AND v_igual = v_n AND v_malos = '', format('personas=%s iguales=%s distintas=[%s] con_algun_permiso=%s', v_n, v_igual, v_malos, v_noempty));
END $$;
SELECT pg_temp.verifica('E2 con 108_ y 109_ juntas, el total de policies sigue en 76 y las 3 funciones de las dos migraciones existen con EXECUTE solo authenticated/service_role',
  $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 76
      AND (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'personas'::regnamespace AND p.proname IN ('fn_caller_ve_padron', 'fn_caller_ve_estructura_permisos', 'fn_caller_puestos_en_rama')
             AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')) = 3$$);

-- ============================================================================
-- D) Reversa documentada
-- ============================================================================
DROP POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona;
CREATE POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona FOR SELECT USING (personas.fn_caller_activo());
DROP POLICY bitacora_puesto_permiso_select_caller_activo ON personas.bitacora_movimiento_puesto_permiso;
CREATE POLICY bitacora_puesto_permiso_select_caller_activo ON personas.bitacora_movimiento_puesto_permiso FOR SELECT USING (personas.fn_caller_activo());
DROP POLICY puesto_permiso_select_caller_activo ON personas.puesto_permiso;
CREATE POLICY puesto_permiso_select_caller_activo ON personas.puesto_permiso FOR SELECT USING (personas.fn_caller_activo());
DROP FUNCTION personas.fn_caller_ve_estructura_permisos();
DROP FUNCTION personas.fn_caller_puestos_en_rama();
SELECT pg_temp.mide('reversa', 'S1 sin puesto', 'authenticated', (SELECT v FROM _ens WHERE k = 'auth_S1'));
SELECT pg_temp.verifica('D1 tras la reversa S1 vuelve a ver todo (estado de antes)', $$SELECT bp > 0 AND bpp > 0 FROM _vis WHERE fase = 'reversa'$$);
\ir ../ddl/109_personas_select_bitacoras_por_permiso.sql
SELECT pg_temp.verifica('D2 109_ reaplicable tras la reversa', $$SELECT count(*) = 3 FROM pg_policies WHERE schemaname = 'personas' AND policyname IN ('bitacora_select_caller_activo', 'bitacora_puesto_permiso_select_caller_activo', 'puesto_permiso_select_caller_activo') AND (qual LIKE '%fn_caller_tiene_permiso%' OR qual LIKE '%fn_caller_ve_estructura_permisos%')$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT quien, bp AS movimientos_persona, bpp AS movimientos_permisos, fase FROM _vis ORDER BY fase DESC, quien;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
