-- Ensayo de 129_personas_baja_exige_asignacion_edicion.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_129.sql     (SIN -1; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Personas, usuarios de auth, puestos, permisos, asignaciones y movimientos de bitácora SINTÉTICOS creados en la transacción.
-- El administrador real es caller y, en D6, persona objetivo (la baja aborta y el caso se revierte). Si 128_ todavía no está aplicada, el ensayo la aplica
-- primero dentro de la transacción (129_ va DESPUÉS de 128_). Luego: fase A (antes de 129_: reproduce R1), reversa probada (R), D (después) y F (catálogo).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
SET LOCAL TimeZone = 'UTC';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (polname text PRIMARY KEY, polcmd "char", polpermissive boolean, polroles text, qual text, wc text, comentario text);
GRANT ALL ON _ens, _res, _foto TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

CREATE FUNCTION pg_temp.k(p text) RETURNS text AS $$ SELECT v FROM _ens WHERE k = p $$ LANGUAGE sql STABLE;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- p_quien: NULL = dueño; 'adm' | 'ce' | 'ceae' | 'ae' = authenticated con los claims de ese caller; 'svc' = service_role.
-- ok = SQLSTATE = p_state, HINT vacío si p_sin_hint, y p_check (como dueño) verdadero si pasó. Siempre revierte el caso.
CREATE FUNCTION pg_temp.caso(p_caso text, p_quien text, p_sql text, p_state text, p_check text DEFAULT NULL, p_sin_hint boolean DEFAULT false) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := ''; v_hint text := ''; v_ok boolean := NULL;
BEGIN
  IF p_quien IN ('adm', 'ce', 'ceae', 'ae') THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', pg_temp.k('auth_' || p_quien), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
  ELSIF p_quien = 'svc' THEN
    PERFORM set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
    SET LOCAL ROLE service_role;
  END IF;
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
    IF p_check IS NOT NULL THEN EXECUTE p_check INTO v_ok; END IF;
    RAISE EXCEPTION 'rollback del caso' USING ERRCODE = 'SCJZZ';
  EXCEPTION
    WHEN SQLSTATE 'SCJZZ' THEN NULL;
    WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_hint = PG_EXCEPTION_HINT; v_state := SQLSTATE;
  END;
  RESET ROLE; PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle)
  VALUES (p_caso, v_state = p_state AND (NOT p_sin_hint OR COALESCE(v_hint, '') = '') AND (p_check IS NULL OR v_state <> 'ok' OR COALESCE(v_ok, false)),
          format('obtenido=%s hint=%s check=%s %s', v_state, v_hint, v_ok, left(v_msg, 100)));
END;
$$ LANGUAGE plpgsql;

-- Movimiento p_tipo de la persona p_persona registrado por p_quien (registrado_por = su auth uid; 'svc' = NULL), con fecha_efectiva p_instante (NULL = now()).
CREATE FUNCTION pg_temp.mov(p_persona text, p_tipo text, p_quien text, p_instante text DEFAULT NULL, p_registrado_por text DEFAULT NULL) RETURNS text AS $$
  SELECT format('INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento, fecha_efectiva, motivo, registrado_por) VALUES (%L, %L, COALESCE(%L::timestamptz, now()), %L, %s)',
                p_persona, p_tipo, p_instante, 'ensayo 129',
                CASE WHEN p_registrado_por IS NOT NULL THEN quote_literal(p_registrado_por) || '::uuid'
                     WHEN p_quien = 'svc' THEN 'NULL' ELSE quote_literal(pg_temp.k('auth_' || p_quien)) || '::uuid' END);
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pg_temp.chk(p_estado text, p_fecha_baja text, p_hasta text) RETURNS text AS $$
  SELECT format($q$SELECT (SELECT estado = %1$L AND fecha_baja IS NOT DISTINCT FROM %2$L::date FROM personas.persona WHERE id = %4$L)
                     AND (SELECT vigente_hasta IS NOT DISTINCT FROM %3$L::date FROM personas.asignacion WHERE id = %5$L)$q$,
                p_estado, p_fecha_baja, p_hasta, pg_temp.k('BJ'), pg_temp.k('ASG_BJ'));
$$ LANGUAGE sql STABLE;

-- Crea persona sintética p_k (con usuario y asignación a un puesto sintético nuevo que tiene los permisos p_permisos), devuelve nada; guarda p_k y auth_p_k.
CREATE FUNCTION pg_temp.mk(p_k text, p_n int, p_permisos text[]) RETURNS void AS $$
DECLARE v_puesto text := 'ENS129 ' || p_k; c text;
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXW' || p_n, 'XEXW0101' || lpad(p_n::text, 4, '0'), '999998' || lpad(p_n::text, 5, '0'), 'Sintetica129' || p_k, 'Ensayo129', DATE '2000-01-01', DATE '2020-01-01');
  INSERT INTO _ens SELECT p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXW' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES (pg_temp.k('auth_' || p_k)::uuid, 'authenticated', 'authenticated', 'ens129' || lower(p_k) || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES (pg_temp.k('auth_' || p_k)::uuid, pg_temp.k(p_k)::uuid, 'ens129' || lower(p_k));
  INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
  SELECT departamento_id, v_puesto, 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
  FOREACH c IN ARRAY p_permisos LOOP
    INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
    SELECT id, c, 'otorgado' FROM personas.puesto WHERE nombre_puesto = v_puesto;
  END LOOP;
  INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
  SELECT pg_temp.k(p_k)::uuid, id, DATE '2026-01-01' FROM personas.puesto WHERE nombre_puesto = v_puesto;
END;
$$ LANGUAGE plpgsql;

-- ---------- 128_ primero ----------
SELECT NOT (prosrc LIKE '%personas.fn_hoy_mexico(NEW.fecha_efectiva)%') AS falta_128 FROM pg_proc WHERE oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure \gset
\if :falta_128
  \echo '--- 128_ no está aplicada: se aplica dentro de la transacción ---'
  \ir ../ddl/128_personas_baja_fecha_de_mexico.sql
\endif

-- ---------- datos base ----------
INSERT INTO _ens VALUES ('hoy', personas.fn_hoy_mexico()::text), ('ayer', (personas.fn_hoy_mexico() - 1)::text);
INSERT INTO _ens
SELECT 'auth_adm', u.auth_user_id::text FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'ADM', persona_id::text FROM personas.usuario WHERE auth_user_id = pg_temp.k('auth_adm')::uuid;
SELECT pg_temp.mk('ce', 1, ARRAY['cambio_estado_persona']);                         -- solo cambio de estado
SELECT pg_temp.mk('ceae', 2, ARRAY['cambio_estado_persona', 'asignacion_edicion']);  -- RH completo
SELECT pg_temp.mk('ae', 3, ARRAY['asignacion_edicion']);                            -- sin cambio de estado
SELECT pg_temp.mk('BJ', 4, ARRAY[]::text[]);                                        -- objetivo de las bajas
INSERT INTO _ens SELECT 'ASG_BJ', a.id::text FROM personas.asignacion a WHERE a.persona_id = pg_temp.k('BJ')::uuid;
SELECT pg_temp.verifica('P1 admin con cambio_estado_persona y asignacion_edicion',
  $$SELECT count(*) = 2 FROM personas.puesto_permiso pp JOIN personas.puesto pu ON pu.id = pp.puesto_id AND pu.es_administrador_generico
    WHERE pp.activo AND pp.codigo IN ('cambio_estado_persona', 'asignacion_edicion')$$);
SELECT pg_temp.verifica('P2 128_ vigente en la transacción', $$SELECT prosrc LIKE '%personas.fn_hoy_mexico(NEW.fecha_efectiva)%' FROM pg_proc WHERE oid = 'personas.fn_bitacora_sincroniza_persona()'::regprocedure$$);

-- Foto de TODAS las policies de personas y tiempo antes de 129_.
INSERT INTO _foto
SELECT n.nspname || '.' || c.relname || '.' || po.polname, po.polcmd, po.polpermissive, po.polroles::text,
       pg_get_expr(po.polqual, po.polrelid), pg_get_expr(po.polwithcheck, po.polrelid), obj_description(po.oid, 'pg_policy')
FROM pg_policy po JOIN pg_class c ON c.oid = po.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('personas', 'tiempo');

-- ---------- A: ANTES de 129_ (reproduce el residual R1) ----------
SELECT pg_temp.caso('A1 [residual] baja por quien solo tiene cambio_estado_persona => pasa y deja la asignación ABIERTA', 'ce',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'ce'), 'ok', pg_temp.chk('baja_definitiva', pg_temp.k('hoy'), NULL));

-- ---------- aplica 129_, prueba la reversa y la vuelve a aplicar ----------
\ir ../ddl/129_personas_baja_exige_asignacion_edicion.sql
\ir vigente_129_bitacora_insert_policy.sql
SELECT pg_temp.verifica('R1 la reversa deja la policy idéntica a la foto (WITH CHECK, comando, roles, comentario)',
  $$SELECT EXISTS (SELECT 1 FROM _foto f JOIN pg_policy po ON po.polrelid = 'personas.bitacora_movimiento_persona'::regclass AND po.polname = 'bitacora_insert_requiere_permiso'
      WHERE f.polname = 'personas.bitacora_movimiento_persona.bitacora_insert_requiere_permiso'
        AND f.wc = pg_get_expr(po.polwithcheck, po.polrelid) AND f.polcmd = po.polcmd AND f.polroles = po.polroles::text
        AND f.qual IS NOT DISTINCT FROM pg_get_expr(po.polqual, po.polrelid) AND f.comentario IS NOT DISTINCT FROM obj_description(po.oid, 'pg_policy'))$$);
\ir ../ddl/129_personas_baja_exige_asignacion_edicion.sql

-- ---------- D: DESPUÉS de 129_ ----------
SELECT pg_temp.caso('D1 baja por quien solo tiene cambio_estado_persona => 42501 sin HINT', 'ce',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'ce'), '42501', NULL, true);
SELECT pg_temp.verifica('D1b no quedó ningún movimiento de BJ ni cambió su estado',
  format($q$SELECT NOT EXISTS (SELECT 1 FROM personas.bitacora_movimiento_persona WHERE persona_id = %1$L AND tipo_movimiento <> 'alta')
            AND (SELECT estado = 'activo' AND fecha_baja IS NULL FROM personas.persona WHERE id = %1$L)
            AND (SELECT vigente_hasta IS NULL FROM personas.asignacion WHERE id = %2$L)$q$, pg_temp.k('BJ'), pg_temp.k('ASG_BJ')));
SELECT pg_temp.caso('D2 suspensión por quien solo tiene cambio_estado_persona => pasa', 'ce',
  pg_temp.mov(pg_temp.k('BJ'), 'suspension', 'ce'), 'ok', pg_temp.chk('suspension', NULL, NULL));
SELECT pg_temp.caso('D3 suspensión y reactivación por quien solo tiene cambio_estado_persona => pasan', 'ce',
  pg_temp.mov(pg_temp.k('BJ'), 'suspension', 'ce') || '; ' || pg_temp.mov(pg_temp.k('BJ'), 'reactivacion', 'ce'), 'ok', pg_temp.chk('activo', NULL, NULL));
SELECT pg_temp.caso('D4 baja ayer 20:30 CDMX por RH con los dos permisos => pasa y cierra con fecha de México (ayer)', 'ceae',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'ceae', ((personas.fn_hoy_mexico() - 1 + TIME '20:30') AT TIME ZONE 'America/Mexico_City')::text), 'ok',
  pg_temp.chk('baja_definitiva', pg_temp.k('ayer'), pg_temp.k('ayer')));
SELECT pg_temp.caso('D5 baja por el admin => pasa y cierra hoy', 'adm',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'adm'), 'ok', pg_temp.chk('baja_definitiva', pg_temp.k('hoy'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D6 baja del ocupante del puesto administrador por RH con los dos permisos => 42501 (WITH CHECK de 32_)', 'ceae',
  pg_temp.mov(pg_temp.k('ADM'), 'baja_definitiva', 'ceae'), '42501');
SELECT pg_temp.caso('D7 baja del administrador por quien solo tiene cambio_estado_persona => 42501 (ahora lo para la policy de la bitácora)', 'ce',
  pg_temp.mov(pg_temp.k('ADM'), 'baja_definitiva', 'ce'), '42501', NULL, true);
SELECT pg_temp.caso('D8 baja por service_role => sin cambio: pasa y cierra hoy', 'svc',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'svc'), 'ok', pg_temp.chk('baja_definitiva', pg_temp.k('hoy'), pg_temp.k('hoy')));
SELECT pg_temp.caso('D9 baja por quien solo tiene asignacion_edicion => 42501 (sin cambio_estado_persona)', 'ae',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'ae'), '42501');
SELECT pg_temp.caso('D10 alta por la API => 42501 (sin cambio)', 'ceae',
  pg_temp.mov(pg_temp.k('BJ'), 'alta', 'ceae'), '42501');
SELECT pg_temp.caso('D11 baja con registrado_por ajeno => 42501 (sin cambio)', 'ceae',
  pg_temp.mov(pg_temp.k('BJ'), 'baja_definitiva', 'ceae', NULL, pg_temp.k('auth_adm')), '42501');

-- ---------- F: catálogo ----------
SELECT pg_temp.verifica('F1 la policy sigue de INSERT, PERMISSIVE, PUBLIC, sin USING; WITH CHECK distinto de la foto y con el CASE de la baja',
  $$SELECT EXISTS (SELECT 1 FROM _foto f JOIN pg_policy po ON po.polrelid = 'personas.bitacora_movimiento_persona'::regclass AND po.polname = 'bitacora_insert_requiere_permiso'
      WHERE f.polname = 'personas.bitacora_movimiento_persona.bitacora_insert_requiere_permiso'
        AND f.polcmd = po.polcmd AND f.polpermissive = po.polpermissive AND f.polroles = po.polroles::text AND po.polqual IS NULL
        AND f.wc <> pg_get_expr(po.polwithcheck, po.polrelid)
        AND strpos(pg_get_expr(po.polwithcheck, po.polrelid), 'fn_caller_tiene_permiso(''asignacion_edicion''') > 0)$$);
SELECT pg_temp.verifica('F2 ninguna otra policy de personas/tiempo cambió, no se agregó ni quitó ninguna',
  $$SELECT (SELECT count(*) FROM pg_policy po JOIN pg_class c ON c.oid = po.polrelid WHERE c.relnamespace IN ('personas'::regnamespace, 'tiempo'::regnamespace)) = (SELECT count(*) FROM _foto)
       AND NOT EXISTS (
         SELECT 1 FROM _foto f
         LEFT JOIN (pg_policy po JOIN pg_class c ON c.oid = po.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace)
           ON n.nspname || '.' || c.relname || '.' || po.polname = f.polname
         WHERE f.polname <> 'personas.bitacora_movimiento_persona.bitacora_insert_requiere_permiso'
           AND (po.oid IS NULL OR f.polcmd <> po.polcmd OR f.polpermissive <> po.polpermissive OR f.polroles <> po.polroles::text
                OR f.qual IS DISTINCT FROM pg_get_expr(po.polqual, po.polrelid) OR f.wc IS DISTINCT FROM pg_get_expr(po.polwithcheck, po.polrelid)))$$);
SELECT pg_temp.verifica('F3 el COMMENT de la policy menciona 129_', $$SELECT obj_description(oid, 'pg_policy') LIKE '%129_%' FROM pg_policy WHERE polrelid = 'personas.bitacora_movimiento_persona'::regclass AND polname = 'bitacora_insert_requiere_permiso'$$);

\echo '--- WITH CHECK de la policy tras 129_ (texto de pg_get_expr) ---'
SELECT pg_get_expr(polwithcheck, polrelid) FROM pg_policy WHERE polrelid = 'personas.bitacora_movimiento_persona'::regclass AND polname = 'bitacora_insert_requiere_permiso';
\echo '--- secciones 55 y 91 (esperado: 0 filas cada una) y 92 informativa (puestos sintéticos ENS129 ce/ae aparecen aquí; ningún puesto real) ---'
\ir verificar_129.sql

SELECT n, caso, ok, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE ok) || '/' || count(*) AS resultado FROM _res;

ROLLBACK;
