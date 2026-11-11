-- Ensayo de 130_personas_puesto_permiso_regla_autootorgamiento.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión db).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_130.sql     (SIN -1; correr desde la raíz del repo)
-- Todo dentro de BEGIN … ROLLBACK. Personas, usuarios de auth, puestos, asignaciones y otorgamientos SINTÉTICOS creados en la transacción. El administrador real
-- solo actúa como caller en D18 (el caso se revierte). Si 130_ ya está aplicada, primero se aplica su reversa (vigente_130_reversa.sql) dentro de la transacción.
-- Fases: A (antes de 130_: reproduce los tres huecos), R (reversa exacta y el hueco vuelve), D (después), F (catálogo).
--
-- Organigrama sintético (todos bajo el puesto sin padre):
--   JEFE (caller 'ed', con puesto_permiso_edicion)  ->  HIJO (caller 'hi', con puesto_permiso_edicion)  ->  NIETO
--   AJENO (hermano de JEFE, fuera de su rama)          SIN (caller 'sp', sin ningún permiso)
-- Códigos: H (heredable), NH y NH2 (no heredables). NH2 está otorgado y luego revocado en JEFE (fila con activo = false, para probar el PATCH directo).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (polname text PRIMARY KEY, polcmd "char", polpermissive boolean, polroles text, qual text, wc text, comentario text);
CREATE TEMP TABLE _priv (rol text, priv text, tiene boolean, PRIMARY KEY (rol, priv));
GRANT ALL ON _ens, _res, _foto, _priv TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

CREATE FUNCTION pg_temp.k(p text) RETURNS text AS $$ SELECT v FROM _ens WHERE k = p $$ LANGUAGE sql STABLE;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

-- p_quien: NULL = dueño sin claims; 'ed' | 'hi' | 'sp' | 'adm' = authenticated con los claims de ese caller; 'svc' = service_role.
-- ok = SQLSTATE = p_state, HINT = p_hint (si se da), y p_check (como dueño, antes de revertir) verdadero. Siempre revierte el caso.
CREATE FUNCTION pg_temp.caso(p_caso text, p_quien text, p_sql text, p_state text, p_hint text DEFAULT NULL, p_check text DEFAULT NULL) RETURNS void AS $$
DECLARE v_state text := 'ok'; v_msg text := ''; v_hint text := ''; v_ok boolean := NULL;
BEGIN
  IF p_quien IN ('ed', 'hi', 'sp', 'adm') THEN
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
  IF v_state <> 'ok' AND p_check IS NOT NULL THEN EXECUTE p_check INTO v_ok; END IF;
  INSERT INTO _res (caso, ok, detalle)
  VALUES (p_caso, v_state = p_state AND (p_hint IS NULL OR COALESCE(v_hint, '') = p_hint) AND (p_check IS NULL OR COALESCE(v_ok, false)),
          format('obtenido=%s hint=%s check=%s %s', v_state, v_hint, v_ok, left(v_msg, 100)));
END;
$$ LANGUAGE plpgsql;

-- INSERT en la bitácora de permisos. registrado_por: p_autor si se da ('-' = NULL explícito; otra cosa = clave de _ens), si no el auth uid de p_quien (NULL para dueño/svc).
CREATE FUNCTION pg_temp.mov(p_puesto text, p_codigo text, p_tipo text, p_quien text, p_autor text DEFAULT NULL) RETURNS text AS $$
  SELECT format('INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento, motivo, registrado_por) VALUES (%L, %L, %L, %L, %s)',
                pg_temp.k(p_puesto), p_codigo, p_tipo, 'ensayo 130',
                CASE WHEN p_autor = '-' THEN 'NULL'
                     WHEN p_autor IS NOT NULL THEN quote_literal(pg_temp.k(p_autor)) || '::uuid'
                     WHEN p_quien IN ('ed', 'hi', 'sp', 'adm') THEN quote_literal(pg_temp.k('auth_' || p_quien)) || '::uuid'
                     ELSE 'NULL' END);
$$ LANGUAGE sql STABLE;

-- ¿puesto_permiso (p_puesto, p_codigo) está activo = p_activo? (NULL = no hay fila)
CREATE FUNCTION pg_temp.pp(p_puesto text, p_codigo text, p_activo boolean) RETURNS text AS $$
  SELECT format('SELECT (SELECT activo FROM personas.puesto_permiso WHERE puesto_id = %L AND codigo = %L) IS NOT DISTINCT FROM %L::boolean',
                pg_temp.k(p_puesto), p_codigo, p_activo);
$$ LANGUAGE sql STABLE;

-- Escrituras DIRECTAS sobre personas.puesto_permiso (sin bitácora).
CREATE FUNCTION pg_temp.pp_insert(p_puesto text, p_codigo text) RETURNS text AS $$
  SELECT format('INSERT INTO personas.puesto_permiso (puesto_id, codigo, activo) VALUES (%L, %L, true)', pg_temp.k(p_puesto), p_codigo);
$$ LANGUAGE sql STABLE;
CREATE FUNCTION pg_temp.pp_reactivar(p_puesto text, p_codigo text) RETURNS text AS $$
  SELECT format('UPDATE personas.puesto_permiso SET activo = true WHERE puesto_id = %L AND codigo = %L', pg_temp.k(p_puesto), p_codigo);
$$ LANGUAGE sql STABLE;
CREATE FUNCTION pg_temp.pp_borrar(p_puesto text, p_codigo text) RETURNS text AS $$
  SELECT format('DELETE FROM personas.puesto_permiso WHERE puesto_id = %L AND codigo = %L', pg_temp.k(p_puesto), p_codigo);
$$ LANGUAGE sql STABLE;

-- Puesto sintético p_k que reporta a p_padre (clave de _ens; NULL = el puesto sin padre).
CREATE FUNCTION pg_temp.puesto(p_k text, p_padre text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
  SELECT departamento_id, 'ENS130 ' || p_k, 'operativo', COALESCE(pg_temp.k(p_padre)::uuid, id)
  FROM personas.puesto WHERE reporta_a_id IS NULL ORDER BY creado_en, id LIMIT 1;
  INSERT INTO _ens SELECT p_k, id::text FROM personas.puesto WHERE nombre_puesto = 'ENS130 ' || p_k;
END;
$$ LANGUAGE plpgsql;

-- Persona sintética p_k con usuario y asignación vigente a p_puesto.
CREATE FUNCTION pg_temp.mk(p_k text, p_n int, p_puesto text) RETURNS void AS $$
BEGIN
  INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
  VALUES ('XEXX010101HNEXXV' || p_n, 'XEXV0101' || lpad(p_n::text, 4, '0'), '999997' || lpad(p_n::text, 5, '0'), 'Sintetica130' || p_k, 'Ensayo130', DATE '2000-01-01', DATE '2020-01-01');
  INSERT INTO _ens SELECT 'P_' || p_k, id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXV' || p_n;
  INSERT INTO _ens VALUES ('auth_' || p_k, gen_random_uuid()::text);
  INSERT INTO auth.users (id, aud, role, email) VALUES (pg_temp.k('auth_' || p_k)::uuid, 'authenticated', 'authenticated', 'ens130' || lower(p_k) || '@invalid.test');
  INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario) VALUES (pg_temp.k('auth_' || p_k)::uuid, pg_temp.k('P_' || p_k)::uuid, 'ens130' || lower(p_k));
  INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde) VALUES (pg_temp.k('P_' || p_k)::uuid, pg_temp.k(p_puesto)::uuid, DATE '2026-01-01');
END;
$$ LANGUAGE plpgsql;

-- Foto de policies de personas/tiempo y de privilegios de escritura sobre puesto_permiso.
CREATE FUNCTION pg_temp.foto() RETURNS void AS $$
BEGIN
  DELETE FROM _foto; DELETE FROM _priv;
  INSERT INTO _foto
  SELECT n.nspname || '.' || c.relname || '.' || po.polname, po.polcmd, po.polpermissive, po.polroles::text,
         pg_get_expr(po.polqual, po.polrelid), pg_get_expr(po.polwithcheck, po.polrelid), obj_description(po.oid, 'pg_policy')
  FROM pg_policy po JOIN pg_class c ON c.oid = po.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname IN ('personas', 'tiempo');
  INSERT INTO _priv
  SELECT r.rol, pr.priv, has_table_privilege(r.rol, 'personas.puesto_permiso', pr.priv)
  FROM (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol) CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS pr(priv);
END;
$$ LANGUAGE plpgsql;

-- ¿El estado actual coincide con la foto? p_sin: nombres de policy que deben FALTAR (y no estar en la cuenta).
CREATE FUNCTION pg_temp.igual_a_foto(p_sin text[]) RETURNS boolean AS $$
  SELECT (SELECT count(*) FROM pg_policy po JOIN pg_class c ON c.oid = po.polrelid WHERE c.relnamespace IN ('personas'::regnamespace, 'tiempo'::regnamespace))
           = (SELECT count(*) FROM _foto) - cardinality(p_sin)
     AND NOT EXISTS (
       SELECT 1 FROM _foto f
       LEFT JOIN (pg_policy po JOIN pg_class c ON c.oid = po.polrelid JOIN pg_namespace n ON n.oid = c.relnamespace)
         ON n.nspname || '.' || c.relname || '.' || po.polname = f.polname
       WHERE (f.polname = ANY (p_sin)) <> (po.oid IS NULL)
          OR (po.oid IS NOT NULL AND (f.polcmd <> po.polcmd OR f.polpermissive <> po.polpermissive OR f.polroles <> po.polroles::text
              OR f.qual IS DISTINCT FROM pg_get_expr(po.polqual, po.polrelid) OR f.wc IS DISTINCT FROM pg_get_expr(po.polwithcheck, po.polrelid)
              OR f.comentario IS DISTINCT FROM obj_description(po.oid, 'pg_policy'))));
$$ LANGUAGE sql STABLE;

-- ---------- si 130_ ya está aplicada: su reversa dentro de la transacción ----------
SELECT to_regprocedure('personas.fn_bitacora_puesto_permiso_regla_autootorgamiento()') IS NOT NULL AS ya_130 \gset
\if :ya_130
  \echo '--- 130_ ya está aplicada: se aplica su reversa dentro de la transacción para reproducir los huecos ---'
  \ir vigente_130_reversa.sql
\endif

-- ---------- datos base ----------
INSERT INTO _ens SELECT 'H',   codigo FROM personas.permiso WHERE heredable AND activo AND codigo <> 'puesto_permiso_edicion' ORDER BY codigo LIMIT 1;
INSERT INTO _ens SELECT 'NH',  codigo FROM personas.permiso WHERE NOT heredable AND activo AND codigo <> 'puesto_permiso_edicion' ORDER BY codigo LIMIT 1;
INSERT INTO _ens SELECT 'NH2', codigo FROM personas.permiso WHERE NOT heredable AND activo AND codigo <> 'puesto_permiso_edicion' ORDER BY codigo OFFSET 1 LIMIT 1;
SELECT pg_temp.puesto('JEFE', NULL);
SELECT pg_temp.puesto('HIJO', 'JEFE');
SELECT pg_temp.puesto('NIETO', 'HIJO');
SELECT pg_temp.puesto('AJENO', NULL);
SELECT pg_temp.puesto('SIN', NULL);
-- Semillas como dueño (sin auth.uid()), en este orden: ambas ramas editan permisos; NIETO tiene H; JEFE tuvo NH2 y se le revocó.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
VALUES (pg_temp.k('JEFE')::uuid, 'puesto_permiso_edicion', 'otorgado'),
       (pg_temp.k('HIJO')::uuid, 'puesto_permiso_edicion', 'otorgado'),
       (pg_temp.k('NIETO')::uuid, pg_temp.k('H'), 'otorgado'),
       (pg_temp.k('JEFE')::uuid, pg_temp.k('NH2'), 'otorgado');
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
VALUES (pg_temp.k('JEFE')::uuid, pg_temp.k('NH2'), 'revocado');
SELECT pg_temp.mk('ed', 1, 'JEFE');
SELECT pg_temp.mk('hi', 2, 'HIJO');
SELECT pg_temp.mk('sp', 3, 'SIN');
INSERT INTO _ens
SELECT 'auth_adm', u.auth_user_id::text FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'ADMP', pu.id::text FROM personas.puesto pu WHERE pu.es_administrador_generico LIMIT 1;

SELECT pg_temp.verifica('P1 hay un código heredable y dos no heredables para el ensayo', $$SELECT pg_temp.k('H') IS NOT NULL AND pg_temp.k('NH') IS NOT NULL AND pg_temp.k('NH2') IS NOT NULL$$);
SELECT pg_temp.verifica('P2 hay un administrador real activo y su puesto', $$SELECT pg_temp.k('auth_adm') IS NOT NULL AND pg_temp.k('ADMP') IS NOT NULL$$);
SELECT pg_temp.verifica('P3 la rama sintética JEFE > HIJO > NIETO quedó armada',
  $$SELECT (SELECT reporta_a_id::text FROM personas.puesto WHERE id = pg_temp.k('NIETO')::uuid) = pg_temp.k('HIJO')
       AND (SELECT reporta_a_id::text FROM personas.puesto WHERE id = pg_temp.k('HIJO')::uuid) = pg_temp.k('JEFE')$$);
SELECT pg_temp.verifica('P4 las semillas sincronizaron (NIETO.H activo, JEFE.NH2 revocado)',
  $$SELECT (SELECT activo FROM personas.puesto_permiso WHERE puesto_id = pg_temp.k('NIETO')::uuid AND codigo = pg_temp.k('H'))
       AND NOT (SELECT activo FROM personas.puesto_permiso WHERE puesto_id = pg_temp.k('JEFE')::uuid AND codigo = pg_temp.k('NH2'))$$);

SELECT pg_temp.foto();

-- ---------- A: ANTES de 130_ (reproduce los huecos) ----------
SELECT pg_temp.caso('A1 [hueco] ed se otorga un permiso NO heredable a su propio puesto por la bitácora => pasa', 'ed',
  pg_temp.mov('JEFE', pg_temp.k('NH'), 'otorgado', 'ed'), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('NH'), true));
SELECT pg_temp.caso('A2 [hueco] ed otorga un permiso heredable a su hijo (lo hereda) => pasa', 'ed',
  pg_temp.mov('HIJO', pg_temp.k('H'), 'otorgado', 'ed'), 'ok', NULL, pg_temp.pp('HIJO', pg_temp.k('H'), true));
SELECT pg_temp.caso('A3 [hueco crítico] ed INSERT directo en puesto_permiso a su propio puesto, sin bitácora => pasa', 'ed',
  pg_temp.pp_insert('JEFE', pg_temp.k('NH')), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('NH'), true));
SELECT pg_temp.caso('A4 [hueco crítico] ed PATCH activo=true sobre su fila revocada, sin bitácora => pasa', 'ed',
  pg_temp.pp_reactivar('JEFE', pg_temp.k('NH2')), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('NH2'), true));
SELECT pg_temp.caso('A5 [hueco] ed registra un otorgamiento a nombre de hi => pasa', 'ed',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'ed', 'auth_hi'), 'ok', NULL, pg_temp.pp('AJENO', pg_temp.k('NH'), true));

-- ---------- aplica 130_, prueba la reversa y la vuelve a aplicar ----------
\ir ../ddl/130_personas_puesto_permiso_regla_autootorgamiento.sql
\ir vigente_130_reversa.sql
SELECT pg_temp.verifica('R1 la reversa deja policies de personas/tiempo idénticas a la foto (texto, comando, roles, comentario)', $$SELECT pg_temp.igual_a_foto('{}')$$);
SELECT pg_temp.verifica('R2 la reversa deja los privilegios sobre puesto_permiso idénticos a la foto',
  $$SELECT NOT EXISTS (SELECT 1 FROM _priv p WHERE has_table_privilege(p.rol, 'personas.puesto_permiso', p.priv) <> p.tiene)$$);
SELECT pg_temp.verifica('R3 la reversa: sin trigger ni función nuevos; sincroniza otra vez INVOKER sin search_path',
  $$SELECT to_regprocedure('personas.fn_bitacora_puesto_permiso_regla_autootorgamiento()') IS NULL
       AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_bitacora_puesto_permiso_regla_autootorgamiento')
       AND (SELECT NOT prosecdef AND proconfig IS NULL FROM pg_proc WHERE oid = 'personas.fn_puesto_permiso_sincroniza()'::regprocedure)$$);
SELECT pg_temp.caso('R4 tras la reversa el hueco crítico vuelve (A3 otra vez pasa)', 'ed',
  pg_temp.pp_insert('JEFE', pg_temp.k('NH')), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('NH'), true));
\ir ../ddl/130_personas_puesto_permiso_regla_autootorgamiento.sql

-- ---------- D: DESPUÉS de 130_ ----------
-- Regla anti auto-otorgamiento por la bitácora
SELECT pg_temp.caso('D1 ed se otorga un permiso NO heredable a su propio puesto => SCJ29 autootorgamiento_directo, sin fila', 'ed',
  pg_temp.mov('JEFE', pg_temp.k('NH'), 'otorgado', 'ed'), 'SCJ29', 'autootorgamiento_directo', pg_temp.pp('JEFE', pg_temp.k('NH'), NULL));
SELECT pg_temp.caso('D2 ed se otorga un permiso heredable a su propio puesto => SCJ29 autootorgamiento_por_herencia (misma rama que Python)', 'ed',
  pg_temp.mov('JEFE', pg_temp.k('H'), 'otorgado', 'ed'), 'SCJ29', 'autootorgamiento_por_herencia', pg_temp.pp('JEFE', pg_temp.k('H'), NULL));
SELECT pg_temp.caso('D3 ed otorga un permiso heredable a su hijo => SCJ29 autootorgamiento_por_herencia', 'ed',
  pg_temp.mov('HIJO', pg_temp.k('H'), 'otorgado', 'ed'), 'SCJ29', 'autootorgamiento_por_herencia', pg_temp.pp('HIJO', pg_temp.k('H'), NULL));
SELECT pg_temp.caso('D4 ed revoca y vuelve a otorgar un permiso heredable a su NIETO => la revocación pasa; el otorgamiento, SCJ29 autootorgamiento_por_herencia', 'ed',
  pg_temp.mov('NIETO', pg_temp.k('H'), 'revocado', 'ed') || '; ' || pg_temp.mov('NIETO', pg_temp.k('H'), 'otorgado', 'ed'),
  'SCJ29', 'autootorgamiento_por_herencia');
SELECT pg_temp.caso('D5 ed otorga un permiso NO heredable a su nieto => pasa y sincroniza (no heredable: solo cuenta el propio puesto)', 'ed',
  pg_temp.mov('NIETO', pg_temp.k('NH'), 'otorgado', 'ed'), 'ok', NULL, pg_temp.pp('NIETO', pg_temp.k('NH'), true));
SELECT pg_temp.caso('D6 ed otorga un permiso heredable a un puesto AJENO fuera de su rama => pasa y sincroniza (fila nueva, trigger DEFINER)', 'ed',
  pg_temp.mov('AJENO', pg_temp.k('H'), 'otorgado', 'ed'), 'ok', NULL, pg_temp.pp('AJENO', pg_temp.k('H'), true));
SELECT pg_temp.caso('D7 ed otorga un permiso NO heredable a un puesto AJENO => pasa y sincroniza', 'ed',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'ed'), 'ok', NULL, pg_temp.pp('AJENO', pg_temp.k('NH'), true));
SELECT pg_temp.caso('D8 hi (subordinado) reactiva por la bitácora NH2 en su JEFE (ancestro, no heredable) => pasa y la fila revocada vuelve a activo (ON CONFLICT como DEFINER)', 'hi',
  pg_temp.mov('JEFE', pg_temp.k('NH2'), 'otorgado', 'hi'), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('NH2'), true));
SELECT pg_temp.caso('D9 hi se otorga un permiso NO heredable a sí mismo => SCJ29 autootorgamiento_directo', 'hi',
  pg_temp.mov('HIJO', pg_temp.k('NH'), 'otorgado', 'hi'), 'SCJ29', 'autootorgamiento_directo', pg_temp.pp('HIJO', pg_temp.k('NH'), NULL));
SELECT pg_temp.caso('D10 service_role otorga un permiso heredable al puesto de ed por la bitácora => pasa (sin auth.uid() no aplica)', 'svc',
  pg_temp.mov('JEFE', pg_temp.k('H'), 'otorgado', 'svc'), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('H'), true));
SELECT pg_temp.caso('D11 dueño sin claims (migración/semilla) otorga un permiso heredable al puesto de ed => pasa', NULL,
  pg_temp.mov('JEFE', pg_temp.k('H'), 'otorgado', NULL), 'ok', NULL, pg_temp.pp('JEFE', pg_temp.k('H'), true));
SELECT pg_temp.caso('D12 ed revoca un permiso heredable de su nieto => pasa y sincroniza activo=false (revocar no cambia)', 'ed',
  pg_temp.mov('NIETO', pg_temp.k('H'), 'revocado', 'ed'), 'ok', NULL, pg_temp.pp('NIETO', pg_temp.k('H'), false));
SELECT pg_temp.caso('D13 ed revoca puesto_permiso_edicion de su propio puesto => pasa (revocar no cambia)', 'ed',
  pg_temp.mov('JEFE', 'puesto_permiso_edicion', 'revocado', 'ed'), 'ok', NULL, pg_temp.pp('JEFE', 'puesto_permiso_edicion', false));
SELECT pg_temp.caso('D14 INSERT de dos filas (ajeno + propio) por ed => SCJ29 y no queda ninguna', 'ed',
  format('INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento, registrado_por) VALUES (%L, %L, ''otorgado'', %L), (%L, %L, ''otorgado'', %L)',
         pg_temp.k('AJENO'), pg_temp.k('NH'), pg_temp.k('auth_ed'), pg_temp.k('JEFE'), pg_temp.k('NH'), pg_temp.k('auth_ed')),
  'SCJ29', 'autootorgamiento_directo',
  format('SELECT NOT EXISTS (SELECT 1 FROM personas.bitacora_movimiento_puesto_permiso WHERE motivo IS NULL AND registrado_por = %L::uuid)', pg_temp.k('auth_ed')));
SELECT pg_temp.caso('D15 sp (sin puesto_permiso_edicion) otorga a un puesto ajeno => 42501 (policy sin cambio)', 'sp',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'sp'), '42501');
SELECT pg_temp.caso('D16 sp (sin permiso) intenta otorgarse a su propio puesto => SCJ29 (el BEFORE corre antes que la policy; tampoco queda fila)', 'sp',
  pg_temp.mov('SIN', pg_temp.k('NH'), 'otorgado', 'sp'), 'SCJ29', 'autootorgamiento_directo', pg_temp.pp('SIN', pg_temp.k('NH'), NULL));
SELECT pg_temp.caso('D17 ed otorga un código inexistente a un ajeno => 23503 (la FK decide, no el trigger)', 'ed',
  format('INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento, registrado_por) VALUES (%L, ''no_existe_ens130'', ''otorgado'', %L)',
         pg_temp.k('AJENO'), pg_temp.k('auth_ed')), '23503');
SELECT pg_temp.caso('D18 el administrador real se otorga un permiso heredable a su propio puesto => SCJ29 autootorgamiento_por_herencia (consecuencia ya vigente en Python)', 'adm',
  pg_temp.mov('ADMP', pg_temp.k('H'), 'otorgado', 'adm'), 'SCJ29', 'autootorgamiento_por_herencia');
SELECT pg_temp.caso('D19 revocarle un permiso al puesto administrador sigue en 42501 (policy de la bitácora, 32_)', 'ed',
  pg_temp.mov('ADMP', pg_temp.k('H'), 'revocado', 'ed'), '42501');
SELECT pg_temp.verifica('D20 los permisos del puesto administrador quedaron intactos (todos activos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM personas.puesto_permiso WHERE puesto_id = pg_temp.k('ADMP')::uuid AND NOT activo)$$);
-- Escritura directa sobre puesto_permiso (sin bitácora)
SELECT pg_temp.caso('D21 ed INSERT directo en puesto_permiso a su propio puesto => 42501, sin fila', 'ed',
  pg_temp.pp_insert('JEFE', pg_temp.k('NH')), '42501', NULL, pg_temp.pp('JEFE', pg_temp.k('NH'), NULL));
SELECT pg_temp.caso('D22 ed PATCH activo=true sobre su fila revocada => 42501, sigue revocada', 'ed',
  pg_temp.pp_reactivar('JEFE', pg_temp.k('NH2')), '42501', NULL, pg_temp.pp('JEFE', pg_temp.k('NH2'), false));
SELECT pg_temp.caso('D23 ed DELETE directo sobre puesto_permiso (NIETO.H) => 42501, la fila sigue', 'ed',
  pg_temp.pp_borrar('NIETO', pg_temp.k('H')), '42501', NULL, pg_temp.pp('NIETO', pg_temp.k('H'), true));
SELECT pg_temp.caso('D24 ed INSERT directo en puesto_permiso a un puesto AJENO => 42501 (tampoco lo ajeno sin bitácora)', 'ed',
  pg_temp.pp_insert('AJENO', pg_temp.k('NH')), '42501');
SELECT pg_temp.caso('D25 service_role INSERT directo en puesto_permiso => 42501 (su vía es la bitácora)', 'svc',
  pg_temp.pp_insert('AJENO', pg_temp.k('NH')), '42501');
SELECT pg_temp.caso('D26 service_role PATCH directo en puesto_permiso => 42501', 'svc',
  pg_temp.pp_reactivar('JEFE', pg_temp.k('NH2')), '42501');
SELECT pg_temp.caso('D27 ed sigue LEYENDO puesto_permiso de su rama (SELECT de 109_ intacto)', 'ed',
  format('DO $d$ BEGIN IF NOT EXISTS (SELECT 1 FROM personas.puesto_permiso WHERE puesto_id = %L) THEN RAISE EXCEPTION ''sin lectura'' USING ERRCODE = ''SCJYY''; END IF; END $d$', pg_temp.k('NIETO')),
  'ok');
SELECT pg_temp.caso('D28 dueño sin claims (migración) escribe directo en puesto_permiso => pasa', NULL,
  pg_temp.pp_insert('AJENO', pg_temp.k('NH')), 'ok', NULL, pg_temp.pp('AJENO', pg_temp.k('NH'), true));
-- Autoría
SELECT pg_temp.caso('D29 ed otorga a un ajeno registrado a nombre de hi => SCJ29 autor_distinto_del_caller, sin fila', 'ed',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'ed', 'auth_hi'), 'SCJ29', 'autor_distinto_del_caller', pg_temp.pp('AJENO', pg_temp.k('NH'), NULL));
SELECT pg_temp.caso('D30 ed otorga a un ajeno con registrado_por NULL => SCJ29 autor_distinto_del_caller', 'ed',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'ed', '-'), 'SCJ29', 'autor_distinto_del_caller');
SELECT pg_temp.caso('D31 ed revoca con registrado_por de hi => SCJ29 autor_distinto_del_caller, NIETO.H sigue activo', 'ed',
  pg_temp.mov('NIETO', pg_temp.k('H'), 'revocado', 'ed', 'auth_hi'), 'SCJ29', 'autor_distinto_del_caller', pg_temp.pp('NIETO', pg_temp.k('H'), true));
SELECT pg_temp.caso('D32 ed revoca con registrado_por NULL => SCJ29 autor_distinto_del_caller', 'ed',
  pg_temp.mov('NIETO', pg_temp.k('H'), 'revocado', 'ed', '-'), 'SCJ29', 'autor_distinto_del_caller');
SELECT pg_temp.caso('D33 service_role con registrado_por de ed => pasa (sin auth.uid() no se ata el autor; igual que hoy)', 'svc',
  pg_temp.mov('AJENO', pg_temp.k('NH'), 'otorgado', 'svc', 'auth_ed'), 'ok', NULL, pg_temp.pp('AJENO', pg_temp.k('NH'), true));

-- ---------- F: catálogo ----------
SELECT pg_temp.verifica('F1 policies: faltan exactamente las 3 de escritura de puesto_permiso; las demás de personas/tiempo idénticas a la foto',
  $$SELECT pg_temp.igual_a_foto(ARRAY['personas.puesto_permiso.puesto_permiso_insert_requiere_permiso', 'personas.puesto_permiso.puesto_permiso_update_requiere_permiso',
                                      'personas.puesto_permiso.puesto_permiso_delete_requiere_permiso'])$$);
SELECT pg_temp.verifica('F2 privilegios sobre puesto_permiso: SELECT igual a la foto; INSERT/UPDATE/DELETE en false para los 3 roles',
  $$SELECT NOT EXISTS (SELECT 1 FROM _priv p WHERE has_table_privilege(p.rol, 'personas.puesto_permiso', p.priv) <> (p.tiene AND p.priv = 'SELECT'))$$);
SELECT pg_temp.verifica('F3 la función nueva es DEFINER, search_path fijo, dueño postgres, sin EXECUTE para ningún rol de la API',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND pg_get_userbyid(p.proowner) = 'postgres'
       AND NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
       AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
       AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)
     FROM pg_proc p WHERE p.oid = 'personas.fn_bitacora_puesto_permiso_regla_autootorgamiento()'::regprocedure$$);
SELECT pg_temp.verifica('F4 fn_puesto_permiso_sincroniza: DEFINER, search_path fijo, mismo dueño que puesto_permiso, sin EXECUTE de la API; tabla sin FORCE RLS',
  $$SELECT p.prosecdef AND p.proconfig = ARRAY['search_path=personas, pg_temp'] AND p.proowner = c.relowner AND NOT c.relforcerowsecurity
       AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
       AND NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a WHERE a.grantee = 0)
     FROM pg_proc p, pg_class c WHERE p.oid = 'personas.fn_puesto_permiso_sincroniza()'::regprocedure AND c.oid = 'personas.puesto_permiso'::regclass$$);
SELECT pg_temp.verifica('F5 la bitácora tiene exactamente los triggers previos más el nuevo (inmutable, sincroniza y regla)',
  $$SELECT array_agg(tgname::text ORDER BY tgname) = ARRAY['trg_bitacora_puesto_permiso_inmutable', 'trg_bitacora_puesto_permiso_regla_autootorgamiento', 'trg_puesto_permiso_sincroniza']
     FROM pg_trigger WHERE tgrelid = 'personas.bitacora_movimiento_puesto_permiso'::regclass AND NOT tgisinternal$$);
SELECT pg_temp.verifica('F6 puesto_permiso conserva su RLS habilitada y solo la policy de SELECT',
  $$SELECT (SELECT relrowsecurity FROM pg_class WHERE oid = 'personas.puesto_permiso'::regclass)
       AND (SELECT array_agg(policyname::text || ':' || cmd) FROM pg_policies WHERE schemaname = 'personas' AND tablename = 'puesto_permiso') = ARRAY['puesto_permiso_select_caller_activo:SELECT']$$);

\echo '--- sección 93 (esperado: 0 filas) ---'
\ir verificar_130.sql

SELECT n, caso, ok, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE ok) || '/' || count(*) AS resultado FROM _res;

ROLLBACK;
