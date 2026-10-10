-- Ensayo de 98_tiempo_marca_respeta_interruptor_huella.sql (97_, que 98_ necesita, ya está aplicado en la base real). Regresión completa de ensayo_95 con el interruptor ENCENDIDO + casos con el interruptor apagado/inválido. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión que lo
-- corre) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_98.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 98_ ENCIMA de lo ya aplicado (88_-97_: 94_, 95_, 96_ y 97_ están aplicados en la base real). Terminal, personas, usuarios, altas y marcas SINTÉTICOS; el admin real
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

\ir ../ddl/98_tiempo_marca_respeta_interruptor_huella.sql

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

-- ---------- ayudantes de 95_ ----------
CREATE FUNCTION pg_temp.baja(p_k text) RETURNS void AS $$
  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, detalle)
  VALUES (pg_temp.tu(p_k), (SELECT v::bigint FROM _ens WHERE k='terminal'), (SELECT v::uuid FROM _ens WHERE k = p_k), 'baja_solicitada', 'web',
          (SELECT v::uuid FROM _ens WHERE k='auth_uid'), 'ensayo');
$$ LANGUAGE sql;
-- Evento del Pi para la persona p_k. p_modo: jsonb del campo modo_verificacion (NULL = el campo no viaja). p_momento: momento_dispositivo.
CREATE FUNCTION pg_temp.ev(p_k text, p_seq bigint, p_momento timestamptz DEFAULT now(), p_modo jsonb DEFAULT NULL, p_eid uuid DEFAULT gen_random_uuid()) RETURNS jsonb AS $$
  SELECT jsonb_build_object('evento_id', p_eid, 'employee_no', (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = pg_temp.tu(p_k)),
           'secuencia_local', p_seq, 'momento_dispositivo', to_char(p_momento AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'desfase_local', '-06:00', 'estado_reloj', 'sincronizado', 'version_software', 'ens95')
         || CASE WHEN p_modo IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('modo_verificacion', p_modo) END;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.marcar(p_eventos jsonb) RETURNS text AS $$
  SELECT format('tiempo.fn_marca_terminal_registrar(%s::bigint, %L::jsonb)', (SELECT v FROM _ens WHERE k='terminal'), p_eventos::text);
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.n_inf(p_k text) RETURNS bigint AS $$
  SELECT count(*) FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = pg_temp.tu(p_k) AND tipo_movimiento = 'huella_inferida';
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.est(p_k text) RETURNS text AS $$
  SELECT estado FROM tiempo.terminal_usuario WHERE id = pg_temp.tu(p_k);
$$ LANGUAGE sql;

-- ---------- fixture ----------
INSERT INTO tiempo.terminal (terminal_id, nombre, modelo) VALUES ('ENSAYO-94', 'Terminal de ensayo 95', 'DS-K1A8503EF-B');
INSERT INTO _ens SELECT 'terminal', id::text FROM tiempo.terminal WHERE terminal_id = 'ENSAYO-94';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXW' || lpad(i::text, 2, '0'), 'XEXW010101' || lpad(i::text, 2, '0'), '9999996' || lpad(i::text, 4, '0'), 'SinteticaW' || i, 'Ensayo95', DATE '2000-01-01', CURRENT_DATE
FROM generate_series(1, 22) i;
INSERT INTO _ens SELECT 'A' || i, p.id::text FROM generate_series(1, 22) i JOIN personas.persona p ON p.curp = 'XEXX010101HNEXXW' || lpad(i::text, 2, '0');
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k ~ '^A[0-9]+$' ON CONFLICT DO NOTHING;
-- A1 feliz; A2 lote con 2 marcas; A3..A8 modos que NO activan; A9 pendiente_baja; A10 usuario_creado en el futuro (+1 h); A11 duplicado repara;
-- A12 activación que falla (trigger de ensayo) y A13 que sí activa en el mismo lote; A14 caducidad ganó; A15 pendiente_alta; A16 regresión de códigos.
SELECT pg_temp.alta('A' || i, (SELECT v FROM _ens WHERE k='auth_uid')) FROM generate_series(1, 8) i;
SELECT pg_temp.alta('A9', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.baja('A9');
SELECT pg_temp.alta('A10', (SELECT v FROM _ens WHERE k='auth_uid'), interval '-1 hour');
SELECT pg_temp.alta('A11', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('A12', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('A13', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.alta('A14', (SELECT v FROM _ens WHERE k='auth_uid'), interval '30 hours');
DO $do$ BEGIN EXECUTE pg_temp.asignar_como((SELECT v FROM _ens WHERE k='A15'), (SELECT v FROM _ens WHERE k='auth_uid')); END $do$;
SELECT pg_temp.alta('A16', (SELECT v FROM _ens WHERE k='auth_uid'));
SELECT pg_temp.verifica('00 fixture: admin, terminal y altas en los estados esperados',
  $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND pg_temp.est('A1') = 'esperando_huella' AND pg_temp.est('A9') = 'pendiente_baja'
      AND pg_temp.est('A15') = 'pendiente_alta' AND pg_temp.est('A16') = 'esperando_huella'$$);

-- ---------- ayudantes y estado de 98_ ----------
CREATE FUNCTION pg_temp.hoy_utc() RETURNS date AS $$ SELECT (now() AT TIME ZONE 'UTC')::date $$ LANGUAGE sql;
CREATE FUNCTION pg_temp.iso(p_ts timestamptz) RETURNS text AS $$ SELECT to_char(p_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') $$ LANGUAGE sql;
-- Deja EXACTAMENTE una vigencia abierta por clave (desde 2026-01-01) con los valores pedidos (escritura directa del dueño; el trigger la audita).
CREATE FUNCTION pg_temp.set_int(p_valor text, p_hasta text) RETURNS void AS $$
BEGIN
  DELETE FROM tiempo.parametro WHERE clave IN ('terminal_inferir_huella_activa', 'terminal_inferir_huella_hasta');
  INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES
    ('terminal_inferir_huella_activa', p_valor, DATE '2026-01-01', NULL, NULL),
    ('terminal_inferir_huella_hasta',  p_hasta, DATE '2026-01-01', NULL, NULL);
END;
$$ LANGUAGE plpgsql;
-- Ejecuta una sentencia SELECT que devuelve jsonb COMO el administrador real (rol authenticated, con su sub): la única forma legítima de ENCENDER (R1: el lector exige el respaldo de la función).
CREATE FUNCTION pg_temp.como_admin(p_sql text) RETURNS void AS $$
DECLARE v_j jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT v FROM _ens WHERE k = 'auth_uid'), 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql INTO v_j;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;
-- Encendido LEGÍTIMO: filas limpias (escritura directa del dueño, auditada) y después la función dedicada (nota, vencimiento a 2 días, consentimiento y terminal activa).
CREATE FUNCTION pg_temp.encendido() RETURNS void AS $$
BEGIN
  PERFORM pg_temp.set_int('0', '1970-01-01T00:00:00Z');
  PERFORM pg_temp.como_admin($q$SELECT tiempo.fn_terminal_inferir_huella_cambiar(true, 'Encendido de ensayo 98 para la regresión', now() + interval '2 days')$q$);
END;
$$ LANGUAGE plpgsql;
SELECT pg_temp.alta('A' || i, (SELECT v FROM _ens WHERE k='auth_uid')) FROM generate_series(17, 19) i;   -- A17: «no activa»; A18, A19: activaciones
SELECT pg_temp.como_admin($q$SELECT tiempo.fn_terminal_consentimiento_publicar('Texto de ensayo 98 del aviso de privacidad y consentimiento biométrico', false, 'ensayo 98')$q$);
SELECT pg_temp.encendido();
SELECT pg_temp.rpc('E00 con el interruptor ENCENDIDO (válido, 2 días) el estado efectivo es activo', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()', $c$ ($1->>'activo')::boolean $c$, '-');

-- ---------- A. B feliz ----------
SELECT pg_temp.rpc('10 marca de A1 con modo_verificacion = huella -> confirmada', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A1', 95001, now(), '"huella"'::jsonb))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('10b ... A1 quedó activa por inferencia (huellas 0), con huella_inferida origen terminal, sin autor, detalle fijo y marca_id = su marca',
  $$SELECT tu.estado = 'activo' AND tu.huellas_capturadas = 0 AND tu.huella_evidencia = 'inferida' AND pg_temp.n_inf('A1') = 1
      AND b.origen = 'terminal' AND b.registrado_por IS NULL AND b.detalle = 'primera marca verificada por huella'
      AND b.marca_id = (SELECT id FROM tiempo.marca WHERE terminal_id = 'ENSAYO-94' AND secuencia_local = 95001)
    FROM tiempo.terminal_usuario tu JOIN tiempo.bitacora_movimiento_terminal_usuario b ON b.terminal_usuario_id = tu.id AND b.tipo_movimiento = 'huella_inferida'
    WHERE tu.id = pg_temp.tu('A1')$$);
SELECT pg_temp.verifica('10c lock_timeout quedó restaurado a su valor previo (3s del ensayo)', $$SELECT current_setting('lock_timeout') = '3s'$$);
SELECT pg_temp.rpc('11 lote con DOS marcas de A2 por huella -> ambas confirmadas', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A2', 95002, now(), '"huella"'::jsonb), pg_temp.ev('A2', 95003, now(), '"huella"'::jsonb))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' AND $1->'resultados'->1->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('11b ... y hay UN solo movimiento huella_inferida para A2', $$SELECT pg_temp.n_inf('A2') = 1 AND pg_temp.est('A2') = 'activo'$$);

-- ---------- B. lo que NO activa ----------
SELECT pg_temp.rpc('20 modos que no activan (ausente, HUELLA, "huella ", tarjeta, número 1, null JSON, arreglo): todas confirmadas', 'service_role',
  pg_temp.marcar(jsonb_build_array(
    pg_temp.ev('A3', 95010),
    pg_temp.ev('A4', 95011, now(), '"HUELLA"'::jsonb),
    pg_temp.ev('A5', 95012, now(), '"huella "'::jsonb),
    pg_temp.ev('A6', 95013, now(), '"tarjeta"'::jsonb),
    pg_temp.ev('A7', 95014, now(), '1'::jsonb),
    pg_temp.ev('A8', 95015, now(), 'null'::jsonb),
    pg_temp.ev('A16', 95016, now(), '["huella"]'::jsonb))),
  $c$ (SELECT bool_and(r->>'estado' = 'confirmado') FROM jsonb_array_elements($1->'resultados') r) $c$, '-');
SELECT pg_temp.verifica('20b ... y ninguna de esas altas se activó',
  $$SELECT pg_temp.est('A3') = 'esperando_huella' AND pg_temp.est('A4') = 'esperando_huella' AND pg_temp.est('A5') = 'esperando_huella'
      AND pg_temp.est('A6') = 'esperando_huella' AND pg_temp.est('A7') = 'esperando_huella' AND pg_temp.est('A8') = 'esperando_huella'
      AND pg_temp.est('A16') = 'esperando_huella'
      AND (SELECT count(*) FROM tiempo.bitacora_movimiento_terminal_usuario WHERE tipo_movimiento = 'huella_inferida'
           AND terminal_usuario_id IN (pg_temp.tu('A3'), pg_temp.tu('A4'), pg_temp.tu('A5'), pg_temp.tu('A6'), pg_temp.tu('A7'), pg_temp.tu('A8'), pg_temp.tu('A16'))) = 0$$);
SELECT pg_temp.rpc('21 alta ya activa (A1) con modo huella -> confirmada, sin segundo movimiento', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A1', 95020, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('21b ... A1 sigue con UN solo movimiento', $$SELECT pg_temp.n_inf('A1') = 1$$);
SELECT pg_temp.rpc('22 alta en pendiente_baja (A9) con modo huella -> confirmada, no activa, no falla', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A9', 95021, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('22b ... A9 sigue en pendiente_baja', $$SELECT pg_temp.est('A9') = 'pendiente_baja' AND pg_temp.n_inf('A9') = 0$$);
-- A10: usuario_creado_en = ahora + 1 h.
SELECT pg_temp.rpc('23 momento_dispositivo anterior a usuario_creado_en - 5 min (A10) -> confirmada, no activa', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A10', 95022, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('23b ... A10 sigue esperando_huella', $$SELECT pg_temp.est('A10') = 'esperando_huella' AND pg_temp.n_inf('A10') = 0$$);
SELECT pg_temp.rpc('24 reloj del aparato adelantado: momento_dispositivo OK (posterior a usuario_creado) pero RECIBIDA antes de usuario_creado_en -> no activa', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A10', 95023, now() + interval '2 hours', '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('24b ... A10 sigue esperando_huella (la recepción no se falsea desde el aparato)', $$SELECT pg_temp.est('A10') = 'esperando_huella' AND pg_temp.n_inf('A10') = 0$$);

-- ---------- C. duplicado repara; fallo de activación; caducidad ----------
SELECT pg_temp.rpc('30 A11: primero la marca SIN modo (confirmada, no activa)', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A11', 95030, now(), NULL, '11111111-1111-4111-8111-111111111111'::uuid))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.rpc('30b ... el MISMO evento reenviado CON modo huella -> duplicado y ACTIVA la alta', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A11', 95030, now(), '"huella"'::jsonb, '11111111-1111-4111-8111-111111111111'::uuid))),
  $c$ $1->'resultados'->0->>'estado' = 'duplicado' $c$, '-');
SELECT pg_temp.verifica('30c ... A11 quedó activa por inferencia con la marca del evento original',
  $$SELECT pg_temp.est('A11') = 'activo' AND pg_temp.n_inf('A11') = 1
      AND (SELECT marca_id FROM tiempo.bitacora_movimiento_terminal_usuario WHERE terminal_usuario_id = pg_temp.tu('A11') AND tipo_movimiento = 'huella_inferida')
          = (SELECT id FROM tiempo.marca WHERE evento_id = '11111111-1111-4111-8111-111111111111')$$);
-- Falla forzada SÓLO para A12 (trigger temporal de ensayo): la marca de A12 se confirma, la de A13 activa, el lote no se cae.
CREATE FUNCTION tiempo.fn_ensayo95_falla() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF NEW.tipo_movimiento = 'huella_inferida' AND NEW.persona_id = (SELECT v::uuid FROM _ens WHERE k = 'A12') THEN
    RAISE EXCEPTION 'falla forzada del ensayo' USING ERRCODE = 'XX000';
  END IF;
  RETURN NEW;
END
$f$;
CREATE TRIGGER trg_ensayo95_falla BEFORE INSERT ON tiempo.bitacora_movimiento_terminal_usuario FOR EACH ROW EXECUTE FUNCTION tiempo.fn_ensayo95_falla();
SELECT pg_temp.rpc('31 una activación que FALLA (A12) no rechaza su marca ni tumba el lote: A12 confirmada y A13 confirmada', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A12', 95031, now(), '"huella"'::jsonb), pg_temp.ev('A13', 95032, now(), '"huella"'::jsonb))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' AND $1->'resultados'->1->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('31b ... A12 sigue esperando_huella (su marca existe), A13 se activó',
  $$SELECT pg_temp.est('A12') = 'esperando_huella' AND pg_temp.est('A13') = 'activo'
      AND EXISTS (SELECT 1 FROM tiempo.marca WHERE terminal_id = 'ENSAYO-94' AND secuencia_local = 95031)$$);
SELECT pg_temp.verifica('31c lock_timeout también quedó restaurado tras la activación fallida', $$SELECT current_setting('lock_timeout') = '3s'$$);
DROP TRIGGER trg_ensayo95_falla ON tiempo.bitacora_movimiento_terminal_usuario;
SELECT pg_temp.rpc('32 caducidad (24 h) da de baja a A14 (esperaba hace 30 h)', 'service_role', 'to_jsonb(tiempo.fn_terminal_baja_por_caducidad(24))', $c$ ($1 #>> '{}')::int >= 1 $c$, '-');
SELECT pg_temp.rpc('32b ... después llega su marca por huella: confirmada y NO activa (la caducidad ganó)', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A14', 95033, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('32c ... A14 sigue en pendiente_baja', $$SELECT pg_temp.est('A14') = 'pendiente_baja' AND pg_temp.n_inf('A14') = 0$$);

-- ---------- D. regresión de TODOS los códigos de retorno de fn_marca_terminal_registrar ----------
SELECT pg_temp.rpc('40 forma_invalida: employee_no no numérico', 'service_role',
  pg_temp.marcar(jsonb_build_array(jsonb_set(pg_temp.ev('A16', 95040), '{employee_no}', '"abc"'))), $c$ $1->'resultados'->0->>'codigo' = 'forma_invalida' $c$, '-');
SELECT pg_temp.rpc('40b forma_invalida: momento_dispositivo ilegible', 'service_role',
  pg_temp.marcar(jsonb_build_array(jsonb_set(pg_temp.ev('A16', 95041), '{momento_dispositivo}', '"ayer"'))), $c$ $1->'resultados'->0->>'codigo' = 'forma_invalida' $c$, '-');
SELECT pg_temp.rpc('40c forma_invalida: estado_reloj fuera de vocabulario', 'service_role',
  pg_temp.marcar(jsonb_build_array(jsonb_set(pg_temp.ev('A16', 95042), '{estado_reloj}', '"raro"'))), $c$ $1->'resultados'->0->>'codigo' = 'forma_invalida' $c$, '-');
SELECT pg_temp.rpc('40d forma_invalida: un elemento que no es objeto conserva su índice', 'service_role',
  pg_temp.marcar('[7]'::jsonb), $c$ $1->'resultados'->0->>'codigo' = 'forma_invalida' AND ($1->'resultados'->0->>'indice')::int = 0 $c$, '-');
SELECT pg_temp.rpc('41 no_enrolado: employee_no sin alta', 'service_role',
  pg_temp.marcar(jsonb_build_array(jsonb_set(pg_temp.ev('A16', 95043), '{employee_no}', '98765432'))), $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$, '-');
SELECT pg_temp.rpc('41b no_enrolado: alta en pendiente_alta (A15)', 'service_role',
  pg_temp.marcar(jsonb_build_array(jsonb_build_object('evento_id', gen_random_uuid(), 'employee_no', (SELECT employee_no FROM tiempo.terminal_usuario WHERE id = pg_temp.tu('A15')),
    'secuencia_local', 95044, 'momento_dispositivo', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'desfase_local', '-06:00', 'estado_reloj', 'sincronizado', 'version_software', 'ens95'))),
  $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$, '-');
SELECT pg_temp.rpc('41c no_enrolado: marca anterior a la creación de la alta (> 1 h antes)', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 95045, now() - interval '3 hours'))), $c$ $1->'resultados'->0->>'codigo' = 'no_enrolado' $c$, '-');
SELECT pg_temp.rpc('42 secuencia_fuera_de_rango', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 99999999999))), $c$ $1->'resultados'->0->>'codigo' = 'secuencia_fuera_de_rango' $c$, '-');
SELECT pg_temp.rpc('43 secuencia_duplicada: misma secuencia con otro evento_id', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 95001))), $c$ $1->'resultados'->0->>'codigo' = 'secuencia_duplicada' $c$, '-');
SELECT pg_temp.rpc('44 conflicto_evento: mismo evento_id con otro contenido', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 95046, now(), NULL, '11111111-1111-4111-8111-111111111111'::uuid))), $c$ $1->'resultados'->0->>'codigo' = 'conflicto_evento' $c$, '-');
SELECT pg_temp.rpc('45 duplicado: reenvío idéntico', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 95047, now(), NULL, '22222222-2222-4222-8222-222222222222'::uuid), pg_temp.ev('A16', 95047, now(), NULL, '22222222-2222-4222-8222-222222222222'::uuid))),
  $c$ $1->'resultados'->0->>'estado' = 'confirmado' AND $1->'resultados'->1->>'estado' = 'duplicado' $c$, '-');
SELECT pg_temp.rpc('46 degradación del reloj: sincronizado con momento a +2 h guarda deriva', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A16', 95048, now() + interval '2 hours'))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('46b ... estado_reloj = deriva', $$SELECT estado_reloj = 'deriva' FROM tiempo.marca WHERE terminal_id = 'ENSAYO-94' AND secuencia_local = 95048$$);
SELECT pg_temp.verifica('47 los rechazos definitivos dejaron evidencia en marca_rechazada', $$SELECT count(*) >= 5 FROM tiempo.marca_rechazada$$);
SELECT pg_temp.caso('48 terminal inexistente -> SCJ12 terminal_no_valida', 'service_role', 'SELECT tiempo.fn_marca_terminal_registrar(999999999::bigint, ''[]''::jsonb)', 'SCJ12', '-', 'terminal_no_valida');
SELECT pg_temp.caso('48b lote vacío -> 22023 lote_invalido', 'service_role', format('SELECT tiempo.fn_marca_terminal_registrar(%s::bigint, ''[]''::jsonb)', (SELECT v FROM _ens WHERE k='terminal')), '22023', '-', 'lote_invalido');
SELECT pg_temp.caso('48c más de 200 eventos -> 22023 lote_invalido', 'service_role',
  format('SELECT tiempo.fn_marca_terminal_registrar(%s::bigint, (SELECT jsonb_agg(7) FROM generate_series(1, 201)))', (SELECT v FROM _ens WHERE k='terminal')), '22023', '-', 'lote_invalido');
SELECT pg_temp.caso('49 authenticated no ejecuta el RPC de marcas', 'authenticated', 'SELECT ' || pg_temp.marcar('[7]'::jsonb), '42501');
SELECT pg_temp.caso('49b anon tampoco', 'anon', 'SELECT ' || pg_temp.marcar('[7]'::jsonb), '42501', '-');


-- ---------- E. el interruptor (98_): apagado, vencido, solapado, ausente (no destructivo) ----------
SELECT pg_temp.set_int('0', pg_temp.iso(now() + interval '2 days'));
SELECT pg_temp.rpc('E10 interruptor en 0 (con vencimiento vigente): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98010, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E10b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('1', pg_temp.iso(now() - interval '1 hour'));
SELECT pg_temp.rpc('E11 interruptor en 1 pero HASTA VENCIDO: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98011, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E11b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('1', pg_temp.iso(now() + interval '31 days'));
SELECT pg_temp.rpc('E12 interruptor en 1 con hasta a más de 30 días (el tope se aplica al leer): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98012, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E12b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('1', '1970-01-01T00:00:00Z');
SELECT pg_temp.rpc('E13 interruptor en 1 con el centinela como hasta: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98013, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E13b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.encendido();
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES ('terminal_inferir_huella_activa', '1', pg_temp.hoy_utc() - 1, pg_temp.hoy_utc() + 5, NULL);
SELECT pg_temp.rpc('E16 DOS vigencias solapadas del interruptor: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98019, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E16b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('0', pg_temp.iso(now() + interval '2 days'));
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES ('terminal_inferir_huella_activa', '1', pg_temp.hoy_utc() + 1, NULL, NULL);
SELECT pg_temp.rpc('E17 fila de MAÑANA con 1 (hoy rige la de 0): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98020, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E17b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
DELETE FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa';
SELECT pg_temp.rpc('E18 parámetro AUSENTE (cero vigencias del interruptor): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98021, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E18b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.encendido();
UPDATE tiempo.parametro SET vigente_hasta = pg_temp.hoy_utc() - 1 WHERE clave = 'terminal_inferir_huella_activa';
SELECT pg_temp.rpc('E19 vigencia del interruptor ya cerrada (vencida por fecha): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98022, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E19b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.encendido();
ALTER TABLE tiempo.parametro RENAME TO parametro_ens98;
SELECT pg_temp.rpc('E20 lectura FALLIDA (tiempo.parametro renombrada dentro de la transacción): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98023, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E20b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
ALTER TABLE tiempo.parametro_ens98 RENAME TO parametro;

-- Medianoche UTC / zona de la sesión: las vigencias usan la fecha UTC explícita, no la de la sesión.
SELECT pg_temp.encendido();
SET LOCAL timezone = 'America/Mexico_City';
SELECT pg_temp.rpc('E22 con TimeZone = America/Mexico_City el interruptor encendido sigue ACTIVO (lectura por fecha UTC explícita)', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()', $c$ ($1->>'activo')::boolean $c$, '-');
SET LOCAL timezone = 'UTC';
-- Cruce de la medianoche UTC (18:00 de México): encendido «ayer» (17:59, fecha UTC anterior) y apagado «hoy» -> rige el último valor.
DELETE FROM tiempo.parametro WHERE clave IN ('terminal_inferir_huella_activa', 'terminal_inferir_huella_hasta');
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES
  ('terminal_inferir_huella_activa', '1', DATE '2026-01-01', pg_temp.hoy_utc() - 1, NULL),
  ('terminal_inferir_huella_activa', '0', pg_temp.hoy_utc(), NULL, NULL),
  ('terminal_inferir_huella_hasta',  pg_temp.iso(now() + interval '2 days'), DATE '2026-01-01', NULL, NULL);
SELECT pg_temp.rpc('E23 encendido hasta AYER (UTC) y apagado HOY: el RPC lee el último valor (apagado)', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()',
  $c$ NOT ($1->>'activo')::boolean AND $1->>'motivo' = 'apagado' $c$, '-');
DELETE FROM tiempo.parametro WHERE clave = 'terminal_inferir_huella_activa';
INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por) VALUES
  ('terminal_inferir_huella_activa', '0', DATE '2026-01-01', pg_temp.hoy_utc() - 1, NULL),
  ('terminal_inferir_huella_activa', '1', pg_temp.hoy_utc(), NULL, NULL);
SELECT pg_temp.rpc('E23b apagado hasta AYER (UTC) y encendido HOY (después de la medianoche UTC) escrito DIRECTO: el lector toma el último valor (1; el motivo NO es «apagado») pero sin respaldo de la función => APAGADO', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()',
  $c$ NOT ($1->>'activo')::boolean AND $1->>'motivo' = 'sin_respaldo_de_la_funcion' AND $1->>'valor' = '1' $c$, '-');

-- R1: escritura directa => el lote NO activa; la función dedicada (renovar) lo restablece.
SELECT pg_temp.encendido();
SELECT pg_temp.rpc('E24 encendido por la función: el estado es activo', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()', $c$ ($1->>'activo')::boolean $c$, '-');
UPDATE tiempo.parametro SET valor = pg_temp.iso(now() + interval '3 days') WHERE clave = 'terminal_inferir_huella_hasta' AND vigente_hasta IS NULL;
SELECT pg_temp.rpc('E24b UPDATE DIRECTO del vencimiento a otra fecha válida (R1: sin respaldo de la función): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98050, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E24bb ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.como_admin($q$SELECT tiempo.fn_terminal_inferir_huella_cambiar(true, 'Renovación por la función, ensayo 98', now() + interval '4 days')$q$);
SELECT pg_temp.rpc('E24c la función renueva => vuelve a estar activo', 'service_role', 'tiempo.fn_terminal_inferir_huella_estado()', $c$ ($1->>'activo')::boolean $c$, '-');
SELECT pg_temp.rpc('E24d ... y la marca por huella de A19 se confirma', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A19', 98051, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('E24e ... y A19 SÍ se activó por inferencia', $$SELECT pg_temp.est('A19') = 'activo' AND pg_temp.n_inf('A19') = 1$$);

-- ---------- F. integración con la función dedicada de 97_: encender y apagar el mismo día ----------
SELECT pg_temp.set_int('0', '1970-01-01T00:00:00Z');
SELECT pg_temp.rpc('F10 el administrador publica un consentimiento definitivo (requisito P4)', 'authenticated',
  $$tiempo.fn_terminal_consentimiento_publicar('Texto de ensayo 98 del aviso de privacidad y consentimiento biométrico', false, 'ensayo 98')$$, $c$ $1->>'resultado' IN ('publicada', 'sin_cambio') $c$);
SELECT pg_temp.rpc('F11 el administrador ENCIENDE con la función dedicada', 'authenticated',
  'tiempo.fn_terminal_inferir_huella_cambiar(true, ''Primera alta real supervisada, ensayo 98'', now() + interval ''2 days'')', $c$ ($1->'estado'->>'activo')::boolean $c$);
SELECT pg_temp.rpc('F12 con el interruptor encendido por la función, la marca por huella de A18 se confirma', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A18', 98030, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('F12b ... y A18 quedó ACTIVA por inferencia', $$SELECT pg_temp.est('A18') = 'activo' AND pg_temp.n_inf('A18') = 1$$);
SELECT pg_temp.rpc('F13 el mismo día el administrador APAGA', 'authenticated', 'tiempo.fn_terminal_inferir_huella_cambiar(false, NULL, NULL)', $c$ NOT ($1->'estado'->>'activo')::boolean $c$);
SELECT pg_temp.rpc('F14 apagado: la marca por huella de A17 se confirma', 'service_role',
  pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98031, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('F14b ... y A17 NO se activó', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
-- Estado limpio (como el real) para correr verificar_ddl.sql completo antes de las pruebas destructivas.
SELECT pg_temp.set_int('0', '1970-01-01T00:00:00Z');

\ir ../verificar_ddl.sql

-- ---------- G. filas inválidas simuladas (DESTRUCTIVO dentro de la transacción: se sueltan los CHECK y se reemplaza el lector; va después del verificador) ----------
ALTER TABLE tiempo.parametro DROP CONSTRAINT ck_parametro_inferir_huella_hasta, DROP CONSTRAINT ck_parametro_inferir_huella_activa;
SELECT pg_temp.set_int('1', 'mañana');
SELECT pg_temp.rpc('G10 hasta con formato inválido: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98040, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G10b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('1', '2030-01-01T00:00:00');
SELECT pg_temp.rpc('G11 hasta SIN zona: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98041, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G11b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('7', pg_temp.iso(now() + interval '2 days'));
SELECT pg_temp.rpc('G12 valor corrupto 7 (el lector tolerante lo habría leído como 1): la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98042, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G12b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('1 ', pg_temp.iso(now() + interval '2 days'));
SELECT pg_temp.rpc('G13 valor corrupto "1 " con espacio: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98043, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G13b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.set_int('', pg_temp.iso(now() + interval '2 days'));
SELECT pg_temp.rpc('G14 valor vacío: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98044, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G14b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.encendido();
CREATE OR REPLACE FUNCTION tiempo.fn_terminal_inferir_huella_estado() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = tiempo, pg_temp
AS $f$ BEGIN RAISE EXCEPTION 'falla forzada del ensayo'; END $f$;   -- el lector LANZA: el RPC debe leerlo como apagado (rama EXCEPTION)
SELECT pg_temp.rpc('G20 el lector de estado LANZA una excepción: la marca por huella se CONFIRMA', 'service_role', pg_temp.marcar(jsonb_build_array(pg_temp.ev('A17', 98045, now(), '"huella"'::jsonb))), $c$ $1->'resultados'->0->>'estado' = 'confirmado' $c$, '-');
SELECT pg_temp.verifica('G20b ... y NO activa (A17 sigue esperando_huella, sin huella_inferida)', $$SELECT pg_temp.est('A17') = 'esperando_huella' AND pg_temp.n_inf('A17') = 0$$);
SELECT pg_temp.verifica('G20c el lote no se rechazó y lock_timeout sigue restaurado', $$SELECT current_setting('lock_timeout') = '3s'$$);


SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
