-- Ensayo de 125_tiempo_excepcion_horario_descartar.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_125.sql     (SIN -1; puerto 5432, no el pooler 6543; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Personas, marcas, días, tramos y excepciones SINTÉTICOS creados en la transacción. Aplica SOLO 125_.
-- ROLLBACK descarta). El administrador real solo es caller. Cada rol se mide con SET ROLE authenticated + claims con su auth uid: cuántas filas VE de persona, expediente, usuario y asignacion.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _vis (fase text, quien text, personas bigint, expedientes bigint);
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
DECLARE a bigint; b bigint;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_rol)::text, true);
  SELECT count(*) INTO a FROM personas.persona;
  SELECT count(*) INTO b FROM personas.expediente;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _vis VALUES (p_fase, p_quien, a, b);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.caso2(p_caso text, p_sub text, p_sql text, p_state text, p_hint text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_hint text := ''; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT, v_msg = MESSAGE_TEXT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR v_hint = p_hint), format('obtenido=%s hint=%s %s', v_state, v_hint, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- Ejecuta p_sql como el caller; si pasa, evalúa p_check (boolean, como dueño) sobre el estado resultante y revierte el caso.
CREATE FUNCTION pg_temp.exito(p_caso text, p_sub text, p_sql text, p_check text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := ''; v_ok boolean := false;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true); SET LOCAL ROLE authenticated;
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE p_check INTO v_ok;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = 'ok' AND COALESCE(v_ok, false), format('estado=%s verificacion=%s %s', v_state, v_ok, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

-- ---------- fixture ----------
CREATE FUNCTION pg_temp.mk_persona(p_k text, p_n int, p_puesto text, p_permiso text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica125' || p_k, 'Ensayo125', DATE '2000-01-01', CURRENT_DATE);
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), 'authenticated', 'authenticated', 'ens125' || p_k || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES ((SELECT v::uuid FROM _ens WHERE k = 'auth_' || p_k), (SELECT v::uuid FROM _ens WHERE k = p_k), 'ens125' || lower(p_k));
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

-- ---------- fixtures ----------
CREATE FUNCTION pg_temp.igual(p_caso text, p_obtenido text, p_esperado text) RETURNS void AS $$
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, p_obtenido = p_esperado, format('obtenido=%s esperado=%s', p_obtenido, p_esperado));
$$ LANGUAGE sql;
-- RH (con el permiso, descarta), SP (sin permiso), JF (jefe del puesto de RH: el permiso no es heredable), RH2 (con el permiso y DUEÑO de las marcas del caso «alerta propia»)
SELECT pg_temp.mk_persona('RH', 1, 'ENS125 descarta', 'excepcion_dia_cerrado_descarte');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento) SELECT id, 'correccion_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS125 descarta';   -- RH real también corrige marcas; así A1 llega al bloqueo de 87_ (que solo se revela a quien puede corregir)
SELECT pg_temp.mk_persona('SP', 2, 'ENS125 sin permiso', 'dia_lectura');
SELECT pg_temp.mk_persona('JF', 3, 'ENS125 jefe', NULL);
UPDATE personas.puesto SET reporta_a_id = (SELECT id FROM personas.puesto WHERE nombre_puesto = 'ENS125 jefe') WHERE nombre_puesto = 'ENS125 descarta';
SELECT pg_temp.mk_persona('RH2', 4, 'ENS125 descarta B', 'excepcion_dia_cerrado_descarte');

-- Caso sintético: persona (p_persona o nueva) con 4 marcas el 2026-10-22 (08:00, 09:00, 10:00, 11:00 hora de México), un día en p_estado con 2 tramos coherentes (la marca 4 es el CIERRE del tramo 2, como en el caso real) y una excepción
-- en la marca 4 con p_motivo. p_estado = NULL => no se crea el día (ni sus tramos). Guarda en _ens: E_<k> (excepción), D_<k> (día), P_<k> (persona).
CREATE FUNCTION pg_temp.mk_caso(p_k text, p_persona uuid, p_estado text, p_motivo text, p_marca_de_dia boolean DEFAULT false) RETURNS void AS $$
DECLARE v_p uuid := COALESCE(p_persona, gen_random_uuid()); v_m bigint[] := ARRAY[]::bigint[]; v_id bigint; v_dia bigint; i int; v_e bigint;
BEGIN
  IF p_persona IS NULL THEN INSERT INTO tiempo.persona (id) VALUES (v_p); END IF;
  INSERT INTO _ens VALUES ('P_' || p_k, v_p::text);
  FOR i IN 1..4 LOOP
    INSERT INTO tiempo.marca (persona_id, terminal_id, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
    VALUES (v_p, 'ENS125', TIMESTAMPTZ '2026-10-22 13:00:00+00' + make_interval(hours => i), '-06:00', 'sincronizado', 'ens125', 'captura_manual') RETURNING id INTO v_id;
    v_m := v_m || v_id;
  END LOOP;
  IF p_estado IS NOT NULL THEN
    INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES (v_p, DATE '2026-10-22', p_estado, 2) RETURNING id INTO v_dia;
    INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados) VALUES
      (v_dia, v_m[1], v_m[2], TIMESTAMPTZ '2026-10-22 14:00:00+00', TIMESTAMPTZ '2026-10-22 15:00:00+00', 60),
      (v_dia, v_m[3], v_m[4], TIMESTAMPTZ '2026-10-22 16:00:00+00', TIMESTAMPTZ '2026-10-22 17:00:00+00', 60);
    INSERT INTO _ens VALUES ('D_' || p_k, v_dia::text);
  END IF;
  IF p_marca_de_dia THEN
    INSERT INTO tiempo.excepcion (marca_id, dia_id, motivo_revision) VALUES (NULL, v_dia, p_motivo) RETURNING id INTO v_e;
  ELSE
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (v_m[4], p_motivo) RETURNING id INTO v_e;
  END IF;
  INSERT INTO _ens VALUES ('E_' || p_k, v_e::text);
END $$ LANGUAGE plpgsql;
-- ¡las marcas insertadas pueden generar sus propias excepciones por el trigger de revisión; se borran las que no son la de este caso para no contaminar
SELECT pg_temp.mk_caso('CER', NULL, 'cerrado', 'fuera_de_horario');                           -- el caso real: marca = cierre de tramo, día cerrado
SELECT pg_temp.mk_caso('REV', NULL, 'revisado', 'fuera_de_horario');
SELECT pg_temp.mk_caso('ABI', NULL, 'abierto', 'fuera_de_horario');
SELECT pg_temp.mk_caso('BLO', NULL, 'bloqueado', 'fuera_de_horario');
SELECT pg_temp.mk_caso('SIN', NULL, NULL, 'fuera_de_horario');                                 -- el día de la marca no existe
SELECT pg_temp.mk_caso('REL', NULL, 'cerrado', 'reloj_no_sincronizado');                       -- otro motivo
SELECT pg_temp.mk_caso('DCE', NULL, 'cerrado', 'dia_cerrado');                                 -- marca tardía: es del descarte de 86_
SELECT pg_temp.mk_caso('DIA', NULL, 'cerrado', 'paridad_impar', true);                         -- excepción DE DÍA (marca_id NULL)
SELECT pg_temp.mk_caso('RES', NULL, 'cerrado', 'fuera_de_horario');
UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'E_RES');   -- ya resuelta
SELECT pg_temp.mk_caso('PRO', (SELECT v::uuid FROM _ens WHERE k = 'RH2'), 'cerrado', 'fuera_de_horario');   -- la alerta es de una marca del propio RH2
SELECT pg_temp.mk_caso('MOT', NULL, 'cerrado', 'fuera_de_horario');                            -- pruebas de motivo
SELECT pg_temp.mk_caso('SUF', NULL, 'cerrado', 'fuera_de_horario');                            -- se persiste: auditoría
SELECT pg_temp.mk_caso('SU2', NULL, 'revisado', 'fuera_de_horario');
SELECT pg_temp.mk_caso('UNI', NULL, 'cerrado', 'fuera_de_horario');                            -- motivo con Unicode invisible (se persiste)
SELECT pg_temp.mk_caso('UN2', NULL, 'cerrado', 'fuera_de_horario');                            -- motivo con espacios colapsados (se persiste)

CREATE FUNCTION pg_temp.descarta(p_k text, p_motivo text) RETURNS text AS $$
  SELECT format('SELECT tiempo.fn_excepcion_horario_descartar(%s, %L)', (SELECT v FROM _ens WHERE k = 'E_' || p_k), p_motivo);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.persiste(p_sub text, p_sql text) RETURNS void AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.estado_exc(p_k text) RETURNS text AS $$
  SELECT estado || '|' || left(motivo_revision, 40) FROM tiempo.excepcion WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'E_' || p_k)
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.como_dueno(p_caso text, p_sql text, p_state text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := '';
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state, format('obtenido=%s %s', v_state, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;
CREATE FUNCTION pg_temp.caso_rol(p_caso text, p_rol text, p_sql text, p_state text) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN v_state := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_state = p_state, format('obtenido=%s %s', v_state, left(v_msg, 70)));
END $$ LANGUAGE plpgsql;

SELECT pg_temp.verifica('PRE los 15 casos sintéticos existen, con su excepción pendiente (salvo RES) y el día esperado',
  $$SELECT (SELECT count(*) FROM _ens WHERE k LIKE 'E\_%') = 15 AND (SELECT estado FROM tiempo.excepcion WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'E_CER')) = 'pendiente'
      AND (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'D_CER')) = 'cerrado'$$);

-- ---------- A) ANTES de 125_ (el caso real no tiene camino) ----------
SELECT pg_temp.caso2('A0 (defecto) el descarte de 86_ NO aplica a una alerta de horario => SCJ15 / excepcion_no_descartable', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%s, ''alerta de horario ya revisada por RH'')', (SELECT v FROM _ens WHERE k = 'E_CER')), 'SCJ15', 'excepcion_no_descartable');
SELECT pg_temp.caso2('A1 (defecto) corregir la marca (cierre de un tramo) está bloqueado por 87_ => SCJ15', (SELECT v FROM _ens WHERE k = 'auth_RH'),
  (SELECT format('INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (%s, %L::timestamptz, ''ensayo'', %L::uuid)', m.id, m.momento_dispositivo, m.persona_id) FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id WHERE e.id = (SELECT v::bigint FROM _ens WHERE k = 'E_CER')), 'SCJ15');

\ir ../ddl/125_tiempo_excepcion_horario_descartar.sql

-- ---------- B) casos felices ----------
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('CER', '  Alerta de horario revisada; el cierre del dia ya la incluyo.  '));
SELECT pg_temp.igual('B1 día CERRADO (el caso real): la excepción queda resuelta con el sufijo auditado', (SELECT split_part(pg_temp.estado_exc('CER'), '|', 1)), 'resuelto');
SELECT pg_temp.verifica('B1b el motivo conserva el prefijo y agrega « — descartada por <persona>: <motivo recortado>»',
  $$SELECT motivo_revision = 'fuera_de_horario — descartada por ' || (SELECT v FROM _ens WHERE k = 'RH') || ': Alerta de horario revisada; el cierre del dia ya la incluyo.' FROM tiempo.excepcion WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'E_CER')$$);
SELECT pg_temp.verifica('B1c la auditoría: una fila con la excepción, el día cerrado, el autor de la sesión (no un parámetro) y el motivo recortado',
  $$SELECT count(*) = 1 AND bool_and(d.excepcion_id = (SELECT v::bigint FROM _ens WHERE k = 'E_CER') AND d.dia_id = (SELECT v::bigint FROM _ens WHERE k = 'D_CER') AND d.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'RH')
        AND d.motivo = 'Alerta de horario revisada; el cierre del dia ya la incluyo.' AND d.creado_en IS NOT NULL) FROM tiempo.excepcion_descarte d WHERE d.excepcion_id = (SELECT v::bigint FROM _ens WHERE k = 'E_CER')$$);
SELECT pg_temp.verifica('B1d el día NO cambió (sigue cerrado, 2 tramos, mismas horas): el descarte no toca tramos ni horas',
  $$SELECT (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'D_CER')) = 'cerrado' AND (SELECT horas_totales FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'D_CER')) = 2
      AND (SELECT count(*) FROM tiempo.tramo WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k = 'D_CER')) = 2$$);
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('REV', 'Alerta aceptada tras revisar el dia completo.'));
SELECT pg_temp.igual('B2 día REVISADO: la excepción queda resuelta', (SELECT split_part(pg_temp.estado_exc('REV'), '|', 1)), 'resuelto');
SELECT pg_temp.caso2('B2b descartar otra vez la misma => SCJ28 / ya_resuelta', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('CER', 'Intento repetido de descartar la misma alerta.'), 'SCJ28', 'ya_resuelta');

-- ---------- C) rechazos ----------
SELECT pg_temp.caso2('C1 día ABIERTO => SCJ28 / dia_no_cerrado', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('ABI', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'dia_no_cerrado');
SELECT pg_temp.caso2('C2 día BLOQUEADO => SCJ28 / dia_no_cerrado', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('BLO', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'dia_no_cerrado');
SELECT pg_temp.caso2('C3 el día de la marca NO existe => SCJ28 / dia_no_cerrado', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('SIN', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'dia_no_cerrado');
SELECT pg_temp.caso2('C4 otro motivo (reloj_no_sincronizado) => SCJ28 / no_es_alerta_de_horario', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('REL', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'no_es_alerta_de_horario');
SELECT pg_temp.caso2('C5 una marca tardía dia_cerrado es del descarte de 86_, no de éste => SCJ28 / no_es_alerta_de_horario', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('DCE', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'no_es_alerta_de_horario');
SELECT pg_temp.caso2('C6 excepción DE DÍA (marca_id NULL) => SCJ28 / no_es_alerta_de_horario', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('DIA', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'no_es_alerta_de_horario');
SELECT pg_temp.caso2('C7 excepción ya resuelta (por otra vía) => SCJ28 / ya_resuelta', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('RES', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'ya_resuelta');
SELECT pg_temp.caso2('C8 excepción inexistente => SCJ28 / excepcion_inexistente', (SELECT v FROM _ens WHERE k = 'auth_RH'), 'SELECT tiempo.fn_excepcion_horario_descartar(999999999, ''Motivo de prueba suficientemente largo.'')', 'SCJ28', 'excepcion_inexistente');
SELECT pg_temp.caso2('C9 alerta PROPIA (la marca es de quien descarta) => SCJ28 / alerta_propia', (SELECT v FROM _ens WHERE k = 'auth_RH2'), pg_temp.descarta('PRO', 'Motivo de prueba suficientemente largo.'), 'SCJ28', 'alerta_propia');
SELECT pg_temp.caso2('C9b la misma alerta, descartada por OTRA persona con permiso (RH) => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('PRO', 'Motivo de prueba suficientemente largo.'), 'ok');
SELECT pg_temp.caso2('C10 sin el permiso (tiene otro) => 42501 / sin_permiso', (SELECT v FROM _ens WHERE k = 'auth_SP'), pg_temp.descarta('MOT', 'Motivo de prueba suficientemente largo.'), '42501', 'sin_permiso');
SELECT pg_temp.caso2('C11 el JEFE del puesto con el permiso NO lo hereda (no heredable) => 42501', (SELECT v FROM _ens WHERE k = 'auth_JF'), pg_temp.descarta('MOT', 'Motivo de prueba suficientemente largo.'), '42501', 'sin_permiso');
SELECT pg_temp.caso_rol('C12 anon NO puede ejecutar la función', 'anon', pg_temp.descarta('MOT', 'Motivo de prueba suficientemente largo.'), '42501');
SELECT pg_temp.caso_rol('C13 service_role NO puede ejecutar la función (es una vía humana: sin auth.uid() no hay autor)', 'service_role', pg_temp.descarta('MOT', 'Motivo de prueba suficientemente largo.'), '42501');
-- motivo
SELECT pg_temp.caso2('C14 motivo NULL => SCJ28 / motivo_obligatorio', (SELECT v FROM _ens WHERE k = 'auth_RH'), format('SELECT tiempo.fn_excepcion_horario_descartar(%s, NULL)', (SELECT v FROM _ens WHERE k = 'E_MOT')), 'SCJ28', 'motivo_obligatorio');
SELECT pg_temp.caso2('C15 motivo en blanco / solo caracteres de control => SCJ28 / motivo_obligatorio', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', '   ' || chr(10) || chr(9) || '  '), 'SCJ28', 'motivo_obligatorio');
SELECT pg_temp.caso2('C16 motivo de 9 caracteres => SCJ28 / motivo_corto', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', 'abcdefghi'), 'SCJ28', 'motivo_corto');
SELECT pg_temp.caso2('C17 motivo de exactamente 10 caracteres => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', 'abcdefghij'), 'ok');
SELECT pg_temp.caso2('C18 motivo de 501 caracteres => SCJ28 / motivo_largo (se rechaza, no se trunca)', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', repeat('x', 501)), 'SCJ28', 'motivo_largo');
SELECT pg_temp.caso2('C19 motivo de exactamente 500 caracteres => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', repeat('x', 500)), 'ok');
SELECT pg_temp.caso2('C20 espacios alrededor que se recortan hasta 500 => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', '  ' || repeat('x', 500) || '  '), 'ok');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('SUF', 'Salto de linea' || chr(10) || 'y tab' || chr(9) || 'normalizados.'));
SELECT pg_temp.verifica('C21 los caracteres de control del motivo se normalizan a espacios en la auditoría y en el sufijo',
  $$SELECT d.motivo = 'Salto de linea y tab normalizados.' AND e.motivo_revision LIKE '%: Salto de linea y tab normalizados.' FROM tiempo.excepcion_descarte d JOIN tiempo.excepcion e ON e.id = d.excepcion_id WHERE d.excepcion_id = (SELECT v::bigint FROM _ens WHERE k = 'E_SUF')$$);

-- Unicode invisible y espacios colapsados (ajustes BAJOS de security)
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('UNI', 'abcde' || chr(8232) || 'fghij' || chr(8238) || 'klm' || chr(8203) || 'nop' || chr(65279) || chr(160) || 'qrs'));
SELECT pg_temp.verifica('C22 U+2028, U+202E (RLO), U+200B, U+FEFF y NBSP se normalizan a espacio y se colapsan: queda «abcde fghij klm nop qrs» en la auditoría y en el sufijo',
  $$SELECT d.motivo = 'abcde fghij klm nop qrs' AND e.motivo_revision LIKE '%: abcde fghij klm nop qrs' AND d.motivo !~ '[\u2028\u2029\u202A-\u202E\u200B-\u200F\u2060\uFEFF\u00A0]' FROM tiempo.excepcion_descarte d JOIN tiempo.excepcion e ON e.id = d.excepcion_id WHERE d.excepcion_id = (SELECT v::bigint FROM _ens WHERE k = 'E_UNI')$$);
SELECT pg_temp.caso2('C23 un motivo solo de invisibles y separadores Unicode equivale a vacío => SCJ28 / motivo_obligatorio', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', chr(8203) || chr(8232) || chr(65279) || chr(8238)), 'SCJ28', 'motivo_obligatorio');
SELECT pg_temp.caso2('C24 «a        b» (muchos espacios) mide 3 tras colapsar => SCJ28 / motivo_corto', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', 'a        b'), 'SCJ28', 'motivo_corto');
SELECT pg_temp.caso2('C25 invisibles de relleno no sirven para llegar al mínimo («abc» + 20 ZWSP + «def» = 7) => SCJ28 / motivo_corto', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', 'abc' || repeat(chr(8203), 20) || 'def'), 'SCJ28', 'motivo_corto');
SELECT pg_temp.caso2('C26 «ab   cd   ef» colapsa a 8 caracteres => SCJ28 / motivo_corto', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', 'ab   cd   ef'), 'SCJ28', 'motivo_corto');
SELECT pg_temp.persiste((SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('UN2', 'ab  cd  ef  g'));
SELECT pg_temp.verifica('C27 «ab  cd  ef  g» colapsa a exactamente 10 caracteres («ab cd ef g») => ok y se guarda colapsado',
  $$SELECT d.motivo = 'ab cd ef g' FROM tiempo.excepcion_descarte d WHERE d.excepcion_id = (SELECT v::bigint FROM _ens WHERE k = 'E_UN2')$$);
SELECT pg_temp.caso2('C28 el tope de 500 también se mide DESPUÉS de colapsar (250 + 1 + 249 con 6 espacios de por medio, 505 crudos) => ok', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', repeat('x', 250) || '      ' || repeat('x', 249)), 'ok');
SELECT pg_temp.caso2('C29 501 tras colapsar => SCJ28 / motivo_largo', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('MOT', repeat('x', 250) || '      ' || repeat('x', 250)), 'SCJ28', 'motivo_largo');

-- ---------- D) la auditoría es inmutable ----------
SELECT pg_temp.como_dueno('D1 UPDATE de la auditoría, incluso como dueño, es rechazado', 'UPDATE tiempo.excepcion_descarte SET motivo = ''otra cosa''', 'P0001');
SELECT pg_temp.como_dueno('D2 DELETE de la auditoría, incluso como dueño, es rechazado', 'DELETE FROM tiempo.excepcion_descarte', 'P0001');
SELECT pg_temp.como_dueno('D3 TRUNCATE de la auditoría, incluso como dueño, es rechazado', 'TRUNCATE tiempo.excepcion_descarte', 'P0001');
SELECT pg_temp.caso_rol('D4 service_role no puede UPDATE', 'service_role', 'UPDATE tiempo.excepcion_descarte SET motivo = ''x''', '42501');
SELECT pg_temp.caso_rol('D5 authenticated no puede INSERT directo en la auditoría', 'authenticated', 'INSERT INTO tiempo.excepcion_descarte (excepcion_id, dia_id, persona_id, motivo) SELECT excepcion_id, dia_id, persona_id, ''x'' FROM tiempo.excepcion_descarte LIMIT 1', '42501');
SELECT pg_temp.como_dueno('D6 la excepción descartada no se puede reabrir ni reescribir su motivo sin el prefijo (trigger de columnas inmutables de 86_)',
  format('UPDATE tiempo.excepcion SET motivo_revision = ''otra cosa'' WHERE id = %s', (SELECT v FROM _ens WHERE k = 'E_CER')), 'SCJ15');

-- ---------- E) estructura ----------
SELECT pg_temp.verifica('E1 una sola función de 2 argumentos: DEFINER con search_path fijo, dueño postgres, EXECUTE solo authenticated (ni PUBLIC, ni anon, ni service_role)',
  $$SELECT count(*) = 1 AND bool_and(pronargs = 2 AND prosecdef AND proconfig = ARRAY['search_path=tiempo, personas, pg_temp'] AND pg_get_userbyid(proowner) = 'postgres' AND NOT proleakproof
        AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE') AND NOT has_function_privilege('service_role', oid, 'EXECUTE') AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) x WHERE x.grantee = 0))
    FROM pg_proc WHERE pronamespace = 'tiempo'::regnamespace AND proname = 'fn_excepcion_horario_descartar'$$);
SELECT pg_temp.verifica('E2 el permiso reusado NO es heredable', $$SELECT NOT heredable FROM personas.permiso WHERE codigo = 'excepcion_dia_cerrado_descarte'$$);

-- ---------- F) reversa y reaplicación ----------
DROP FUNCTION tiempo.fn_excepcion_horario_descartar(bigint, text);
SELECT pg_temp.caso2('F1 tras la reversa la función ya no existe (42883)', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('SU2', 'Motivo de prueba suficientemente largo.'), '42883');
\ir ../ddl/125_tiempo_excepcion_horario_descartar.sql
SELECT pg_temp.caso2('F2 reaplicable: vuelve a funcionar', (SELECT v FROM _ens WHERE k = 'auth_RH'), pg_temp.descarta('SU2', 'Motivo de prueba suficientemente largo.'), 'ok');

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
