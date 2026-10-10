-- Ensayo de 94_tiempo_terminal_huella_evidencia.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo
-- corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_94.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica 94_ ENCIMA de lo ya aplicado (88_-93_). Terminal, personas, usuarios, altas y marcas SINTÉTICOS; el admin real
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

\ir ../ddl/94_tiempo_terminal_huella_evidencia.sql

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

-- ---------- fixture ----------
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-94', 'Terminal de ensayo 94', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-94';
-- P1..P12 + Q1..Q2 (antigüedad) + X1..X6 (exceso de inferidas).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXY' || lpad(i::text, 2, '0'), 'XEXY010101' || lpad(i::text, 2, '0'), '9999994' || lpad(i::text, 4, '0'),
       'Sintetica' || i, 'Ensayo94', DATE '2000-01-01', CURRENT_DATE
FROM generate_series(1, 22) i;
INSERT INTO _ens
SELECT CASE WHEN i <= 12 THEN 'P' || i WHEN i <= 14 THEN 'Q' || (i - 12) ELSE 'X' || (i - 14) END, p.id::text
FROM generate_series(1, 22) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXY' || lpad(i::text, 2, '0');
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k ~ '^[PQX][0-9]+$' ON CONFLICT DO NOTHING;
-- Usuarios: RH (P5), sin permisos (P6), Gerente General (P7). El admin real es el caller 'auth_uid'.
INSERT INTO _ens VALUES ('auth_rh', gen_random_uuid()::text), ('auth_sin', gen_random_uuid()::text), ('auth_gg', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', k || '@invalid.test' FROM _ens WHERE k IN ('auth_rh', 'auth_sin', 'auth_gg');
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES
  ((SELECT v::uuid FROM _ens WHERE k='auth_rh'),  (SELECT v::uuid FROM _ens WHERE k='P5'), 'ens94rh'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_sin'), (SELECT v::uuid FROM _ens WHERE k='P6'), 'ens94sin'),
  ((SELECT v::uuid FROM _ens WHERE k='auth_gg'),  (SELECT v::uuid FROM _ens WHERE k='P7'), 'ens94gg');
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P5'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P7'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS94 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='P6'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS94 sin permisos';

-- Altas (Pi: usuario_creado). Autor del asignado: admin salvo donde se indica.
SELECT pg_temp.alta('P1', (SELECT v FROM _ens WHERE k='auth_uid'));                        -- manual feliz (RH confirma)
SELECT pg_temp.alta('P5', (SELECT v FROM _ens WHERE k='auth_uid'));                        -- RH: su propia alta
SELECT pg_temp.alta('P7', (SELECT v FROM _ens WHERE k='auth_uid'));                        -- Gerente General: su propia alta
SELECT pg_temp.alta('P8', (SELECT v FROM _ens WHERE k='auth_rh'));                         -- la asigna RH y la confirma RH (D2 apagado)
SELECT pg_temp.alta('P9', (SELECT v FROM _ens WHERE k='auth_uid'));                        -- inferida feliz
SELECT pg_temp.alta('P10', (SELECT v FROM _ens WHERE k='auth_uid'));                       -- inferidas con marcas inválidas
SELECT pg_temp.alta('P11', (SELECT v FROM _ens WHERE k='auth_uid'));                       -- activada, para SCJ11 de inferida
-- P2 = pendiente_alta; P3 = pendiente_baja; P4 = baja.
-- Estados especiales: P2 pendiente_alta; P3 pendiente_baja; P4 baja; AD = alta del admin real (su propia persona, para la excepción del admin genérico).
DO $do$
BEGIN
  EXECUTE pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P2'), (SELECT v FROM _ens WHERE k='auth_uid'));
END
$do$;
SELECT pg_temp.alta('P3', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('P4', (SELECT v FROM _ens WHERE k='auth_uid'));
CREATE FUNCTION pg_temp.baja(p_k text) RETURNS void AS $$
  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle)
  VALUES (pg_temp.tu(p_k), (SELECT v::bigint FROM _ens WHERE k='terminal'), (SELECT v::uuid FROM _ens WHERE k = p_k), 'baja_solicitada', 'web',
          (SELECT v::uuid FROM _ens WHERE k='auth_uid'), 'ensayo');
$$ LANGUAGE sql;
SELECT pg_temp.baja('P3');
SELECT pg_temp.baja('P4');
SELECT pg_temp.rpc('P4 baja_confirmada del Pi', 'service_role', pg_temp.mov_rpc('P4', 'baja_confirmada', NULL), $c$ $1->>'estado' = 'baja' $c$, '-');
INSERT INTO _ens VALUES ('AD', (SELECT v FROM _ens WHERE k='admin_persona'));
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k='AD' ON CONFLICT DO NOTHING;
SELECT pg_temp.alta('AD', (SELECT v FROM _ens WHERE k='auth_rh'));   -- la asigna RH (no es auto-asignación), la confirma el propio admin

SELECT pg_temp.verifica('00 fixture: caller admin, terminal y altas en los estados esperados',
  $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid')
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')) = 'esperando_huella'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P2')) = 'pendiente_alta'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P3')) = 'pendiente_baja'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P4')) = 'baja'$$);

-- ---------- A. esquema y privilegios ----------
SELECT pg_temp.verifica('01 huella_evidencia: NULL en todas las altas sin evidencia; el backfill no inventó nada',
  $$SELECT count(*) = 0 FROM tiempo.terminal_usuario WHERE huella_evidencia IS NOT NULL AND huellas_capturadas = 0$$);
SELECT pg_temp.caso('02 service_role NO puede UPDATE huella_evidencia (42501)', 'service_role', 'UPDATE tiempo.terminal_usuario SET huella_evidencia = ''manual''', '42501', '-');
SELECT pg_temp.caso('02b authenticated NO puede UPDATE huella_evidencia (42501)', 'authenticated', 'UPDATE tiempo.terminal_usuario SET huella_evidencia = ''manual''', '42501');
SELECT pg_temp.caso('02c anon NO puede UPDATE huella_evidencia (42501)', 'anon', 'UPDATE tiempo.terminal_usuario SET huella_evidencia = ''manual''', '42501', '-');
SELECT pg_temp.caso('02d service_role NO puede INSERT en terminal_usuario (42501)', 'service_role',
  'INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado, huella_evidencia) SELECT terminal_id, persona_id, 99999999, ''activo'', ''manual'' FROM tiempo.terminal_usuario LIMIT 1', '42501', '-');

-- ---------- B. C: confirmación manual ----------
SELECT pg_temp.caso('10 RH (terminal_usuario_edicion) confirma la huella de P1 con nota suficiente -> ok', 'authenticated',
  pg_temp.confirmar('P1', (SELECT v FROM _ens WHERE k='auth_rh'), 'Enrolada en el menú del aparato con RH presente'), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('10b P1 quedó activo, huellas 0, evidencia manual, y la bitácora trae origen web, autor RH, detalle = nota y marca_id NULL',
  $$SELECT tu.estado = 'activo' AND tu.huellas_capturadas = 0 AND tu.huella_evidencia = 'manual'
      AND b.origen = 'web' AND b.registrado_por = (SELECT v::uuid FROM _ens WHERE k='auth_rh')
      AND b.detalle = 'Enrolada en el menú del aparato con RH presente' AND b.marca_id IS NULL AND b.huellas_capturadas IS NULL AND b.consentimiento_id IS NULL
    FROM tiempo.terminal_usuario tu JOIN tiempo.bitacora_movimiento_terminal_usuario b ON b.terminal_usuario_id = tu.id AND b.tipo_movimiento = 'huella_confirmada_manual'
    WHERE tu.id = pg_temp.tu('P1')$$);
SELECT pg_temp.verifica('10c el consentimiento de la alta NO cambió (sigue el de asignado)',
  $$SELECT tu.consentimiento_id = (SELECT consentimiento_id FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = tu.id AND tipo_movimiento = 'asignado')
    FROM tiempo.terminal_usuario tu WHERE tu.id = pg_temp.tu('P1')$$);
SELECT pg_temp.caso('11 volver a confirmar una alta ya activa -> SCJ11 transicion_invalida', 'authenticated',
  pg_temp.confirmar('P1', (SELECT v FROM _ens WHERE k='auth_rh'), 'Segunda confirmación de ensayo'), 'SCJ11', (SELECT v FROM _ens WHERE k='auth_rh'), 'transicion_invalida');
SELECT pg_temp.caso('12 confirmar una alta en pendiente_alta -> SCJ11', 'authenticated',
  pg_temp.confirmar('P2', (SELECT v FROM _ens WHERE k='auth_rh'), 'Alta que aún no existe en el aparato'), 'SCJ11', (SELECT v FROM _ens WHERE k='auth_rh'), 'transicion_invalida');
SELECT pg_temp.caso('13 confirmar una alta en pendiente_baja -> SCJ11', 'authenticated',
  pg_temp.confirmar('P3', (SELECT v FROM _ens WHERE k='auth_rh'), 'Alta con baja solicitada de ensayo'), 'SCJ11', (SELECT v FROM _ens WHERE k='auth_rh'), 'transicion_invalida');
SELECT pg_temp.caso('14 confirmar una alta en baja -> SCJ11', 'authenticated',
  pg_temp.confirmar('P4', (SELECT v FROM _ens WHERE k='auth_rh'), 'Alta dada de baja de ensayo'), 'SCJ11', (SELECT v FROM _ens WHERE k='auth_rh'), 'transicion_invalida');
SELECT pg_temp.caso('15 RH confirma la huella de SU PROPIA alta (P5) -> SCJ12 auto_confirmacion_huella_prohibida', 'authenticated',
  pg_temp.confirmar('P5', (SELECT v FROM _ens WHERE k='auth_rh'), 'Intento de auto-confirmación de ensayo'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'auto_confirmacion_huella_prohibida');
SELECT pg_temp.caso('16 Gerente General (no admin genérico) confirma su PROPIA alta (P7) -> SCJ12 auto_confirmacion_huella_prohibida', 'authenticated',
  pg_temp.confirmar('P7', (SELECT v FROM _ens WHERE k='auth_gg'), 'Intento de auto-confirmación de ensayo'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_gg'), 'auto_confirmacion_huella_prohibida');
SELECT pg_temp.caso('17 el administrador genérico SÍ puede confirmar su propia alta (excepción de la regla)', 'authenticated',
  pg_temp.confirmar('AD', (SELECT v FROM _ens WHERE k='auth_uid'), 'Alta propia del administrador, ensayo'), 'ok');
SELECT pg_temp.caso('18 sin permiso (auth_sin) -> 42501', 'authenticated',
  pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_sin'), 'Sin permiso de edición, ensayo'), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('18b anon -> 42501', 'anon', pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_rh'), 'Anon, ensayo largo'), '42501', '-');
SELECT pg_temp.caso('18c autor suplantado (registrado_por distinto del caller) -> 42501', 'authenticated',
  pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_uid'), 'Suplantación de autor, ensayo'), '42501', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('19 nota corta (3 caracteres) -> SCJ12 nota_requerida', 'authenticated',
  pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_rh'), 'ok.'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'nota_requerida');
SELECT pg_temp.caso('19b nota NULL -> nota_requerida', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
    VALUES (%s, %L::bigint, %L::uuid, 'huella_confirmada_manual', 'web', %L::uuid)$f$, pg_temp.tu('P9'), (SELECT v FROM _ens WHERE k='terminal'),
    (SELECT v FROM _ens WHERE k='P9'), (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'nota_requerida');
SELECT pg_temp.caso('19c nota de sólo espacios e invisibles -> nota_requerida (el trigger a0_ de 92_ los quita antes)', 'authenticated',
  pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_rh'), E'     ​‮​        '), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'nota_requerida');
SELECT pg_temp.caso('20 nota con invisibles de relleno: 9 letras + invisibles NO alcanzan 10 -> nota_requerida', 'authenticated',
  pg_temp.confirmar('P9', (SELECT v FROM _ens WHERE k='auth_rh'), E'abcdefghi​​​​'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'nota_requerida');
SELECT pg_temp.caso('21 huellas no NULL en huella_confirmada_manual -> 23514 (ck_..._huellas)', current_user::text,
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle, huellas_capturadas)
    VALUES (%s, %L::bigint, %L::uuid, 'huella_confirmada_manual', 'web', %L::uuid, 'nota de ensayo larga', 3)$f$, pg_temp.tu('P9'), (SELECT v FROM _ens WHERE k='terminal'),
    (SELECT v FROM _ens WHERE k='P9'), (SELECT v FROM _ens WHERE k='auth_rh')), '23514', '-');
SELECT pg_temp.caso('22 origen terminal con tipo huella_confirmada_manual -> 23514 (origen_tipo)', current_user::text,
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, detalle)
    VALUES (%s, %L::bigint, %L::uuid, 'huella_confirmada_manual', 'terminal', 'nota de ensayo larga')$f$, pg_temp.tu('P9'), (SELECT v FROM _ens WHERE k='terminal'),
    (SELECT v FROM _ens WHERE k='P9')), '23514', '-');
-- D2 apagado: la alta de P8 la asignó RH y RH la confirma sin problema (el cuatro-ojos se activa cambiando c_cuatro_ojos).
SELECT pg_temp.caso('23 D2 apagado por omisión: RH confirma una alta que él mismo asignó (P8) -> ok', 'authenticated',
  pg_temp.confirmar('P8', (SELECT v FROM _ens WHERE k='auth_rh'), 'Confirmación de quien asignó, ensayo'), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));

-- ---------- C. B: huella_inferida (lo escribe el RPC de marcas; aquí se prueba el trigger con la marca real) ----------
SELECT pg_temp.marca('P9', 'P9', 94001);
SELECT pg_temp.caso('30 inferida de P9 con su marca (misma terminal, misma persona, recibida después de usuario_creado) -> ok', 'service_role',
  pg_temp.inferir('P9', 'MP9'), 'ok', '-');
SELECT pg_temp.verifica('30b P9 quedó activo, huellas 0, evidencia inferida; la bitácora trae origen terminal, sin autor y marca_id = la marca; detalle fijo',
  $$SELECT tu.estado = 'activo' AND tu.huellas_capturadas = 0 AND tu.huella_evidencia = 'inferida'
      AND b.origen = 'terminal' AND b.registrado_por IS NULL AND b.marca_id = (SELECT v::bigint FROM _ens WHERE k='MP9') AND b.detalle = 'primera marca verificada por huella'
    FROM tiempo.terminal_usuario tu JOIN tiempo.bitacora_movimiento_terminal_usuario b ON b.terminal_usuario_id = tu.id AND b.tipo_movimiento = 'huella_inferida'
    WHERE tu.id = pg_temp.tu('P9')$$);
SELECT pg_temp.caso('31 la misma marca no puede servir otra vez (índice único / marca_no_corresponde)', 'service_role', pg_temp.inferir('P10', 'MP9'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.marca('P1b', 'P1', 94002);   -- marca de OTRA persona (P1) -> no corresponde a P10
SELECT pg_temp.caso('32 marca de OTRA persona -> SCJ12 marca_no_corresponde', 'service_role', pg_temp.inferir('P10', 'MP1b'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.marca('P10x', 'P10', 94003, now(), 'terminal', 'OTRA-SERIE');
SELECT pg_temp.caso('33 marca de OTRA terminal -> SCJ12 marca_no_corresponde', 'service_role', pg_temp.inferir('P10', 'MP10x'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.marca('P10m', 'P10', NULL, now(), 'captura_manual');
SELECT pg_temp.caso('34 marca de captura_manual -> SCJ12 marca_no_corresponde', 'service_role', pg_temp.inferir('P10', 'MP10m'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.marca('P10v', 'P10', 94004, now() - interval '2 days');
SELECT pg_temp.caso('35 marca RECIBIDA antes de usuario_creado_en -> SCJ12 marca_no_corresponde', 'service_role', pg_temp.inferir('P10', 'MP10v'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.caso('36 marca_id NULL -> SCJ12 marca_no_corresponde (lo atrapa el trigger antes que el CHECK)', 'service_role',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, detalle, origen)
    VALUES (%s, %L::bigint, %L::uuid, (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = %s), 'huella_inferida', 'x', 'terminal')$f$,
    pg_temp.tu('P10'), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P10'), pg_temp.tu('P10')), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.marca('P11', 'P11', 94005);
SELECT pg_temp.rpc('37 P11 pasa a activo por conteo del Pi (huella_capturada 2)', 'service_role', pg_temp.mov_rpc('P11', 'huella_capturada', 2), $c$ $1->>'estado' = 'activo' $c$, '-');
SELECT pg_temp.caso('37b inferida sobre una alta ya activa -> SCJ11 transicion_invalida', 'service_role', pg_temp.inferir('P11', 'MP11'), 'SCJ11', '-', 'transicion_invalida');
SELECT pg_temp.marca('P10ok', 'P10', 94006);
SELECT pg_temp.caso('38 authenticated (con edición) NO puede insertar huella_inferida (origen terminal -> 42501)', 'authenticated', pg_temp.inferir('P10', 'MP10ok'), '42501', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.caso('38b anon -> 42501', 'anon', pg_temp.inferir('P10', 'MP10ok'), '42501', '-');
-- R2: un humano CON terminal_usuario_edicion que declara origen 'web' y tipo huella_inferida con una marca VÁLIDA sobre una alta en esperando_huella:
-- recibe SIEMPRE el mismo rechazo (sin revelar el estado de la alta) y la alta no cambia.
SELECT pg_temp.caso('38c authenticated con edición inserta huella_inferida origen web con marca válida -> SCJ12 marca_no_corresponde', 'authenticated',
  pg_temp.inferir('P10', 'MP10ok', (SELECT v FROM _ens WHERE k='auth_rh'), NULL, 'web'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'marca_no_corresponde');
SELECT pg_temp.caso('38d ... y lo mismo sobre una alta que NO está en esperando_huella (P11 activa): el mismo error, sin distinguir estados (no es oráculo)', 'authenticated',
  pg_temp.inferir('P11', 'MP11', (SELECT v FROM _ens WHERE k='auth_rh'), NULL, 'web'), 'SCJ12', (SELECT v FROM _ens WHERE k='auth_rh'), 'marca_no_corresponde');
SELECT pg_temp.verifica('38e ... P10 sigue en esperando_huella y sin movimientos huella_inferida', $$SELECT estado = 'esperando_huella' AND huella_evidencia IS NULL
  AND NOT EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = pg_temp.tu('P10') AND tipo_movimiento = 'huella_inferida')
  FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P10')$$);
SELECT pg_temp.caso('39 huella_inferida con autor (registrado_por no NULL) -> SCJ12 marca_no_corresponde (R2: rechazo previo, antes que el CHECK)', current_user::text, pg_temp.inferir('P10', 'MP10ok', (SELECT v FROM _ens WHERE k='auth_rh')), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.caso('40 huella_inferida con conteo -> 23514 (ck_..._huellas)', current_user::text, pg_temp.inferir('P10', 'MP10ok', NULL, 3), '23514', '-');
SELECT pg_temp.caso('41 huella_inferida con origen web (como dueño) -> SCJ12 marca_no_corresponde (R2)', current_user::text, pg_temp.inferir('P10', 'MP10ok', (SELECT v FROM _ens WHERE k='auth_rh'), NULL, 'web'), 'SCJ12', '-', 'marca_no_corresponde');
SELECT pg_temp.caso('42 borrar la marca de P9 (evidencia de una inferida) -> error (FK sin cascada o inmutabilidad de marca)', current_user::text,
  format('DELETE FROM tiempo.marca WHERE id = %s', (SELECT v FROM _ens WHERE k='MP9')), 'error', '-');

-- ---------- D. conteo tardío sobre altas manual / inferida (91_ intacto) ----------
SELECT pg_temp.rpc('50 Pi: huella_capturada (3) sobre P1 (activo por confirmación manual) -> registrado, activo', 'service_role', pg_temp.mov_rpc('P1', 'huella_capturada', 3),
  $c$ $1->>'resultado' = 'registrado' AND $1->>'estado' = 'activo' $c$, '-');
SELECT pg_temp.verifica('50b ... y P1 pasó a evidencia conteo con 3 huellas (la evidencia sólo sube)',
  $$SELECT huella_evidencia = 'conteo' AND huellas_capturadas = 3 FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P1')$$);
SELECT pg_temp.rpc('51 Pi: huella_capturada (2) sobre P9 (activo por inferencia) -> conteo', 'service_role', pg_temp.mov_rpc('P9', 'huella_capturada', 2),
  $c$ $1->>'resultado' = 'registrado' $c$, '-');
SELECT pg_temp.verifica('51b ... P9 quedó en conteo con 2 huellas', $$SELECT huella_evidencia = 'conteo' AND huellas_capturadas = 2 FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P9')$$);
SELECT pg_temp.rpc('52 Pi: repetir la misma huella_capturada (2) -> ya_aplicado', 'service_role', pg_temp.mov_rpc('P9', 'huella_capturada', 2),
  $c$ $1->>'resultado' = 'ya_aplicado' $c$, '-');
SELECT pg_temp.caso('53 CHECK de coherencia: evidencia conteo con 0 huellas -> 23514', current_user::text,
  format('UPDATE tiempo.terminal_usuario SET huella_evidencia = ''conteo'' WHERE id = %s', pg_temp.tu('P8')), '23514', '-');
SELECT pg_temp.caso('53b CHECK de coherencia: 2 huellas con evidencia manual -> 23514', current_user::text,
  format('UPDATE tiempo.terminal_usuario SET huellas_capturadas = 2 WHERE id = %s', pg_temp.tu('P8')), '23514', '-');

-- ---------- E. caducidad ----------
-- Altas con usuario_creado hace 30 h: C1 sin evidencia (caduca), C2 con inferida, C3 con manual, C4 recién creada (no caduca). C1..C4 = X1..X4.
INSERT INTO _ens SELECT 'C' || substr(k, 2), v FROM _ens WHERE k IN ('X1', 'X2', 'X3', 'X4');
SELECT pg_temp.alta('C1', (SELECT v FROM _ens WHERE k='auth_uid'), interval '30 hours');
SELECT pg_temp.alta('C2', (SELECT v FROM _ens WHERE k='auth_uid'), interval '30 hours');
SELECT pg_temp.alta('C3', (SELECT v FROM _ens WHERE k='auth_uid'), interval '30 hours');
SELECT pg_temp.alta('C4', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.marca('C2', 'C2', 94010);
SELECT pg_temp.caso('60 C2 queda activa por inferencia', 'service_role', pg_temp.inferir('C2', 'MC2'), 'ok', '-');
SELECT pg_temp.caso('60b C3 queda activa por confirmación manual', 'authenticated',
  pg_temp.confirmar('C3', (SELECT v FROM _ens WHERE k='auth_rh'), 'Confirmada a mano antes de caducar, ensayo'), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
-- (>= 1 y no = 1: si la base real tuviera altas reales vencidas, la función también las vería dentro de esta transacción, que se revierte.)
SELECT pg_temp.rpc('61 caducidad (24 h) como service_role: se da de baja al menos C1', 'service_role', 'to_jsonb(tiempo.fn_terminal_baja_por_caducidad(24))', $c$ ($1 #>> '{}')::int >= 1 $c$, '-');
SELECT pg_temp.verifica('61b C1 -> pendiente_baja; C2 y C3 siguen activas; C4 sigue esperando_huella',
  $$SELECT (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('C1')) = 'pendiente_baja'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('C2')) = 'activo'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('C3')) = 'activo'
      AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('C4')) = 'esperando_huella'$$);
SELECT pg_temp.rpc('61c segunda corrida: 0 (idempotente)', 'service_role', 'to_jsonb(tiempo.fn_terminal_baja_por_caducidad(24))', $c$ $1 = '0'::jsonb $c$, '-');
SELECT pg_temp.caso('62 authenticated y anon no ejecutan la caducidad', 'authenticated', 'SELECT tiempo.fn_terminal_baja_por_caducidad(24)', '42501');
SELECT pg_temp.caso('62b piso de 4 horas intacto (22023 horas_invalidas)', 'service_role', 'SELECT tiempo.fn_terminal_baja_por_caducidad(3)', '22023', '-', 'horas_invalidas');

-- ---------- F. anomalías ----------
-- F1) huellas_inferidas_exceso: P9, C2 y las 5 de abajo = 7 inferidas en el mismo día local (> 5).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXZ' || lpad(i::text, 2, '0'), 'XEXZ010101' || lpad(i::text, 2, '0'), '9999995' || lpad(i::text, 4, '0'), 'SinteticaZ' || i, 'Ensayo94', DATE '2000-01-01', CURRENT_DATE
FROM generate_series(1, 3) i;
INSERT INTO _ens SELECT 'Z' || i, p.id::text FROM generate_series(1, 3) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXZ' || lpad(i::text, 2, '0');
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k LIKE 'Z_' ON CONFLICT DO NOTHING;
SELECT pg_temp.alta('Z1', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('Z2', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('Z3', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('X5', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('X6', (SELECT v FROM _ens WHERE k='auth_uid'));
DO $do$
DECLARE k text; n bigint := 94100;
BEGIN
  FOREACH k IN ARRAY ARRAY['X5','X6','Z1','Z2','Z3'] LOOP
    n := n + 1;
    PERFORM pg_temp.marca('A' || k, k, n);
    EXECUTE pg_temp.inferir(k, 'MA' || k);
  END LOOP;
END
$do$;
SELECT pg_temp.rpc('70 huellas_inferidas_exceso: 7 inferidas hoy (> 5) -> total >= 1 y el primer día reporta >= 6 inferidas', 'service_role',
  format('tiempo.fn_terminal_anomalias(%s::bigint, ''huellas_inferidas_exceso'', now() - interval ''2 days'', now() + interval ''1 day'', 10, 0)', (SELECT v FROM _ens WHERE k='terminal')),
  $c$ ($1->>'total')::int >= 1 AND ($1->'items'->0->>'inferidas')::int >= 6 $c$, '-');

-- F2) inferida_sin_marcas: Q1 y Q2 se activaron por inferencia hace 10 días (usuario_creado hace 12); Q1 no marcó más; Q2 marcó 3 días después.
SELECT pg_temp.alta('Q1', (SELECT v FROM _ens WHERE k='auth_uid'), interval '12 days');
SELECT pg_temp.alta('Q2', (SELECT v FROM _ens WHERE k='auth_uid'), interval '12 days');
SELECT pg_temp.marca('Q1', 'Q1', 94201, now() - interval '11 days');
SELECT pg_temp.marca('Q2', 'Q2', 94202, now() - interval '11 days');
SELECT pg_temp.marca('Q2b', 'Q2', 94203, now() - interval '7 days');
CREATE FUNCTION pg_temp.inferir_en(p_k text, p_marca text, p_hace interval) RETURNS void AS $$
  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, detalle, origen, marca_id, creado_en)
  SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no, 'huella_inferida', 'x', 'terminal', (SELECT v::bigint FROM _ens WHERE k = p_marca), now() - p_hace
  FROM tiempo.terminal_usuario tu WHERE tu.id = pg_temp.tu(p_k);
$$ LANGUAGE sql;
SELECT pg_temp.inferir_en('Q1', 'MQ1', interval '10 days');
SELECT pg_temp.inferir_en('Q2', 'MQ2', interval '10 days');
SELECT pg_temp.rpc('71 inferida_sin_marcas: Q1 sí (sin marcas en 7 días), Q2 no (marcó a los 3 días)', 'service_role',
  format('tiempo.fn_terminal_anomalias(%s::bigint, ''inferida_sin_marcas'', now() - interval ''30 days'', now() + interval ''1 day'', 50, 0)', (SELECT v FROM _ens WHERE k='terminal')),
  format($c$ EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->>'persona_id' = %L)
             AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements($1->'items') i WHERE i->>'persona_id' = %L) $c$,
         (SELECT v FROM _ens WHERE k='Q1'), (SELECT v FROM _ens WHERE k='Q2')), '-');

-- F3) asignador_confirmador: P8 (la asignó y la confirmó RH) sí; P1 (asignó el admin, confirmó RH) no; AD (asignó RH, confirmó el admin) no.
SELECT pg_temp.rpc('72 asignador_confirmador: sólo P8', 'service_role',
  format('tiempo.fn_terminal_anomalias(%s::bigint, ''asignador_confirmador'', now() - interval ''2 days'', now() + interval ''1 day'', 50, 0)', (SELECT v FROM _ens WHERE k='terminal')),
  format($c$ ($1->>'total')::int = 1 AND $1->'items'->0->>'persona_id' = %L $c$, (SELECT v FROM _ens WHERE k='P8')), '-');
SELECT pg_temp.caso('73 categoría desconocida -> 22023 categoria_invalida', 'service_role',
  format('SELECT tiempo.fn_terminal_anomalias(%s::bigint, ''nada'', now() - interval ''1 day'', now(), 3, 0)', (SELECT v FROM _ens WHERE k='terminal')), '22023', '-', 'categoria_invalida');
SELECT pg_temp.caso('73b authenticated no ejecuta las anomalías (EXECUTE sólo service_role)', 'authenticated',
  format('SELECT tiempo.fn_terminal_anomalias(%s::bigint, ''asignador_confirmador'', now() - interval ''1 day'', now(), 3, 0)', (SELECT v FROM _ens WHERE k='terminal')), '42501');

-- ---------- G. regresión de 81_/88_/91_ y conteos ----------
SELECT pg_temp.caso('80 la bitácora sigue inmutable: UPDATE -> error', current_user::text,
  'UPDATE tiempo.bitacora_movimiento_terminal_usuario SET detalle = ''x'' WHERE id = (SELECT min(id) FROM tiempo.bitacora_movimiento_terminal_usuario)', 'error', '-');
SELECT pg_temp.caso('80b ... DELETE -> error', current_user::text, 'DELETE FROM tiempo.bitacora_movimiento_terminal_usuario WHERE id = (SELECT min(id) FROM tiempo.bitacora_movimiento_terminal_usuario)', 'error', '-');
SELECT pg_temp.caso('81 asignado sin consentimiento sigue rechazado (SCJ16)', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_id, persona_id, tipo_movimiento, origen, registrado_por)
    VALUES (%L::bigint, %L::uuid, 'asignado', 'web', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P12'), (SELECT v FROM _ens WHERE k='auth_rh')),
  'SCJ16', (SELECT v FROM _ens WHERE k='auth_rh'), 'consentimiento_requerido');
SELECT pg_temp.caso('82 Pi: huella_capturada con conteo 11 -> 22023 huellas_invalidas (rango 1-10 intacto)', 'service_role', 'SELECT ' || pg_temp.mov_rpc('P8', 'huella_capturada', 11), '22023', '-', 'huellas_invalidas');
SELECT pg_temp.verifica('82b ... P8 sigue activa con evidencia manual', $$SELECT estado = 'activo' AND huella_evidencia = 'manual' FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P8')$$);
SELECT pg_temp.verifica('83 el número de policies de personas+tiempo sigue siendo 76 (se reemplazó una, no se agregó)',
  $$SELECT count(*) = 76 FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')$$);
SELECT pg_temp.verifica('84 el catálogo de permisos sigue en 53 (D1: se reusa terminal_usuario_edicion)', $$SELECT count(*) = 53 FROM personas.permiso$$);

-- ---------- H. 94_ no rompe a 88_: lo que hace un HUMANO con permiso, lo que NO debe pasar y que no hay dependencias nuevas ----------
SELECT pg_temp.caso('90 RH (terminal_usuario_edicion) asigna a P12 con la versión vigente -> ok (regresión de 88_)', 'authenticated',
  pg_temp.asignar_como((SELECT v FROM _ens WHERE k='P12'), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.rpc('90b el Pi crea el usuario de P12 (usuario_creado)', 'service_role', pg_temp.mov_rpc('P12', 'usuario_creado', NULL), $c$ $1->>'estado' = 'esperando_huella' $c$, '-');
SELECT pg_temp.caso('91 RH solicita la baja de P12 -> ok (regresión de 88_)', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle)
    VALUES (%s, %L::bigint, %L::uuid, 'baja_solicitada', 'web', %L::uuid, 'baja de ensayo')$f$, pg_temp.tu('P12'), (SELECT v FROM _ens WHERE k='terminal'),
    (SELECT v FROM _ens WHERE k='P12'), (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('91b ... P12 quedó en pendiente_baja', $$SELECT pg_temp.tu('P12') IS NOT NULL AND (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P12')) = 'pendiente_baja'$$);
SELECT pg_temp.caso('92 un tipo web NO listado (usuario_creado con origen web, como RH) sigue dando 42501', 'authenticated',
  format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, origen, registrado_por)
    VALUES (%s, %L::bigint, %L::uuid, (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = %s), 'usuario_creado', 'web', %L::uuid)$f$,
    pg_temp.tu('P2'), (SELECT v FROM _ens WHERE k='terminal'), (SELECT v FROM _ens WHERE k='P2'), pg_temp.tu('P2'), (SELECT v FROM _ens WHERE k='auth_rh')),
  '42501', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('92b ... y P2 sigue en pendiente_alta', $$SELECT (SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('P2')) = 'pendiente_alta'$$);
-- Reconsentimiento: el administrador publica la versión 2 y RH reconsiente a P8 (activa, con la versión 1).
SELECT pg_temp.rpc('93 el administrador publica la versión 2 del texto', 'authenticated',
  $$tiempo.fn_terminal_consentimiento_publicar('Texto de ensayo 94, versión dos, con cambio material', false, 'ensayo')$$, $c$ $1->>'resultado' = 'publicada' AND ($1->>'version')::int = 2 $c$);
CREATE FUNCTION pg_temp.reconsent94(p_k text, p_uid text) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id, detalle)
    VALUES (%s, %L::bigint, %L::uuid, 'reconsentido', 'web', %L::uuid, %s, 'prueba')$f$, pg_temp.tu(p_k), (SELECT v FROM _ens WHERE k='terminal'),
    (SELECT v FROM _ens WHERE k = p_k), p_uid, pg_temp.vig());
$$ LANGUAGE sql;
SELECT pg_temp.caso('93b usuario sin permisos intenta reconsentir a P8 -> 42501', 'authenticated', pg_temp.reconsent94('P8', (SELECT v FROM _ens WHERE k='auth_sin')), '42501', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('93c RH registra el reconsentimiento de P8 con la versión vigente (2) -> ok (regresión de 88_)', 'authenticated',
  pg_temp.reconsent94('P8', (SELECT v FROM _ens WHERE k='auth_rh')), 'ok', (SELECT v FROM _ens WHERE k='auth_rh'));
SELECT pg_temp.verifica('93d ... P8 sigue activa con evidencia manual y 0 huellas; sólo cambió su consentimiento_id a la versión 2',
  $$SELECT tu.estado = 'activo' AND tu.huella_evidencia = 'manual' AND tu.huellas_capturadas = 0
      AND tu.consentimiento_id = (SELECT id FROM tiempo.terminal_consentimiento WHERE version = 2)
    FROM tiempo.terminal_usuario tu WHERE tu.id = pg_temp.tu('P8')$$);
-- Sin dependencias nuevas por el cambio de tipo y la policy recreada.
SELECT pg_temp.verifica('94 tipo_movimiento: character_maximum_length >= 24 tras aplicar 94_',
  $$SELECT character_maximum_length >= 24 FROM information_schema.columns WHERE table_schema = 'tiempo' AND table_name = 'bitacora_movimiento_terminal_usuario' AND column_name = 'tipo_movimiento'$$);
SELECT pg_temp.verifica('94b ninguna vista depende de la bitácora',
  $$SELECT count(*) = 0 FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid JOIN pg_class v ON v.oid = r.ev_class
    WHERE d.refobjid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND d.classid = 'pg_rewrite'::regclass AND v.relkind IN ('v', 'm')$$);
SELECT pg_temp.verifica('94c ningún índice usa tipo_movimiento ni existen índices fuera de PK, el de marca_id y los previos',
  $$SELECT count(*) = 0 FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
    WHERE i.indrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND a.attname = 'tipo_movimiento'$$);
SELECT pg_temp.verifica('94d la única policy de la bitácora que menciona tipo_movimiento es insert_web (idéntica salvo el tipo nuevo), y el total de policies de la tabla sigue en 2',
  $$SELECT count(*) = 2 AND count(*) FILTER (WHERE coalesce(qual, '') || coalesce(with_check, '') LIKE '%tipo_movimiento%') = 1
      AND bool_or(policyname = 'bitacora_terminal_usuario_insert_web' AND with_check LIKE '%huella_confirmada_manual%')
    FROM pg_policies WHERE schemaname = 'tiempo' AND tablename = 'bitacora_movimiento_terminal_usuario'$$);
SELECT pg_temp.verifica('94e las constraints que dependen de tipo_movimiento son exactamente 6: tipo, origen_tipo, huellas, error_detalle, consentimiento y marca',
  $$SELECT count(*) = 6 FROM pg_constraint WHERE conrelid = 'tiempo.bitacora_movimiento_terminal_usuario'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%tipo_movimiento%'$$);

\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
