-- Ensayo de 106_personas_fn_caller_tiene_permiso_search_path.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator).
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_106.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 106_ (un ALTER FUNCTION … SET). No inserta filas: solo catálogo, consultas con RLS como authenticated con claims del admin real y EXPLAIN (ANALYZE, BUFFERS).
-- Qué prueba: (A) ALTER FUNCTION no cambia nada salvo proconfig de UNA función (ACL, SECURITY, volatilidad, lenguaje y cuerpo intactos; las otras dos «de apoyo» YA tenían search_path); (B) la función no es
-- inlineable antes ni después (el SET no cambia el plan por inlining); (C) EXPLAIN (ANALYZE, BUFFERS) de 6 consultas con RLS antes y después, 5 repeticiones cada una: mismas filas, buffers y tiempo sin regresión
-- (umbral generoso y las cifras quedan en el detalle); (D) resultado idéntico de la función para el admin y para un usuario sin permisos; (E) reversa (RESET search_path) exacta; (F) verificador (71 en 0).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _med (fase text, q text, filas bigint, ms numeric, buf bigint, inline_ok boolean);
CREATE TEMP TABLE _fn (fase text, nombre text, proacl text, secdef boolean, vol text, lang text, cfg text, md5src text);
GRANT ALL ON _ens, _res, _med, _fn TO PUBLIC;
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

CREATE FUNCTION pg_temp.foto(p_fase text) RETURNS void AS $$
  INSERT INTO _fn
  SELECT p_fase, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', COALESCE(p.proacl::text, 'NULL'), p.prosecdef, p.provolatile::text, l.lanname,
         COALESCE(array_to_string(p.proconfig, ';'), '-'), md5(p.prosrc)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'personas' AND p.proname IN ('fn_caller_tiene_permiso', 'fn_persona_de_usuario', 'fn_usuario_es_administrador_generico');
$$ LANGUAGE sql;

-- Mide una consulta con RLS como authenticated (claims del admin real): 5 repeticiones, se guarda la MEDIANA de tiempo, los buffers del plan y si el plan sigue llamando a la función (no inlineada).
CREATE FUNCTION pg_temp.mide(p_fase text, p_q text, p_sql text) RETURNS void AS $$
DECLARE j json; i int; tiempos numeric[] := '{}'; buf bigint; filas bigint; txt text;
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin'), 'role', 'authenticated')::text, true);
  EXECUTE p_sql;   -- calentamiento
  FOR i IN 1..5 LOOP
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO j;
    tiempos := tiempos || ((j->0->>'Execution Time')::numeric);
  END LOOP;
  buf := COALESCE((j->0->'Plan'->>'Shared Hit Blocks')::bigint, 0) + COALESCE((j->0->'Plan'->>'Shared Read Blocks')::bigint, 0);
  txt := j::text;
  filas := COALESCE((j->0->'Plan'->>'Actual Rows')::bigint, 0);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _med VALUES (p_fase, p_q, filas, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t) FROM unnest(tiempos) t), buf, txt NOT LIKE '%fn_caller_tiene_permiso%');
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.medir_todo(p_fase text) RETURNS void AS $$
BEGIN
  PERFORM pg_temp.mide(p_fase, 'Q1 tiempo.tramo (conteo)',            'SELECT count(*) FROM tiempo.tramo');
  PERFORM pg_temp.mide(p_fase, 'Q2 tiempo.dia (50 filas)',            'SELECT * FROM tiempo.dia ORDER BY fecha DESC LIMIT 50');
  PERFORM pg_temp.mide(p_fase, 'Q3 tiempo.ausencia (conteo)',         'SELECT count(*) FROM tiempo.ausencia');
  PERFORM pg_temp.mide(p_fase, 'Q4 personas.persona (conteo)',        'SELECT count(*) FROM personas.persona');
  PERFORM pg_temp.mide(p_fase, 'Q5 tiempo.banco_de_horas (conteo)',   'SELECT count(*) FROM tiempo.banco_de_horas');
  PERFORM pg_temp.mide(p_fase, 'Q6 personas.asignacion (conteo)',     'SELECT count(*) FROM personas.asignacion');
  PERFORM pg_temp.mide(p_fase, 'Q7 tiempo.marca (50 filas)',          'SELECT * FROM tiempo.marca ORDER BY id DESC LIMIT 50');
END;
$$ LANGUAGE plpgsql;

-- ---------- antes ----------
SELECT pg_temp.foto('antes');
SELECT pg_temp.medir_todo('antes');
CREATE TEMP TABLE _v (fase text, quien text, valor boolean);
GRANT ALL ON _v TO PUBLIC;
DO $$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin'), 'role', 'authenticated')::text, true);
  INSERT INTO _v SELECT 'antes', 'admin:' || c, personas.fn_caller_tiene_permiso(c) FROM unnest(ARRAY['banco_de_horas_lectura', 'movimiento_de_saldo_edicion', 'permiso_que_no_existe']) c;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  INSERT INTO _v SELECT 'antes', 'sinusuario:' || c, personas.fn_caller_tiene_permiso(c) FROM unnest(ARRAY['banco_de_horas_lectura', 'movimiento_de_saldo_edicion']) c;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

\ir ../ddl/106_personas_fn_caller_tiene_permiso_search_path.sql

-- ---------- después ----------
SELECT pg_temp.foto('despues');
SELECT pg_temp.medir_todo('despues');
DO $$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k = 'auth_admin'), 'role', 'authenticated')::text, true);
  INSERT INTO _v SELECT 'despues', 'admin:' || c, personas.fn_caller_tiene_permiso(c) FROM unnest(ARRAY['banco_de_horas_lectura', 'movimiento_de_saldo_edicion', 'permiso_que_no_existe']) c;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  INSERT INTO _v SELECT 'despues', 'sinusuario:' || c, personas.fn_caller_tiene_permiso(c) FROM unnest(ARRAY['banco_de_horas_lectura', 'movimiento_de_saldo_edicion']) c;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- ============================================================================
-- A) Solo cambia el proconfig de UNA función
-- ============================================================================
SELECT pg_temp.verifica('A1 las 3 funciones: ACL, SECURITY, volatilidad, lenguaje y CUERPO idénticos antes y después',
  $$SELECT NOT EXISTS (SELECT 1 FROM _fn a JOIN _fn d ON d.fase = 'despues' AND d.nombre = a.nombre WHERE a.fase = 'antes' AND (a.proacl <> d.proacl OR a.secdef <> d.secdef OR a.vol <> d.vol OR a.lang <> d.lang OR a.md5src <> d.md5src))
        AND (SELECT count(*) FROM _fn WHERE fase = 'antes') = 3$$);
SELECT pg_temp.verifica('A2 el único proconfig que cambia es el de fn_caller_tiene_permiso: de «-» a search_path=personas, pg_temp',
  $$SELECT (SELECT count(*) FROM _fn a JOIN _fn d ON d.fase = 'despues' AND d.nombre = a.nombre WHERE a.fase = 'antes' AND a.cfg <> d.cfg) = 1
        AND (SELECT d.cfg FROM _fn d WHERE d.fase = 'despues' AND d.nombre LIKE 'fn_caller_tiene_permiso%') = 'search_path=personas, pg_temp'
        AND (SELECT a.cfg FROM _fn a WHERE a.fase = 'antes' AND a.nombre LIKE 'fn_caller_tiene_permiso%') = '-'$$);
SELECT pg_temp.verifica('A3 fn_persona_de_usuario y fn_usuario_es_administrador_generico YA tenían search_path = personas, pg_temp (106_ no los toca)',
  $$SELECT bool_and(a.cfg = 'search_path=personas, pg_temp' AND d.cfg = a.cfg) AND count(*) = 2 FROM _fn a JOIN _fn d ON d.fase = 'despues' AND d.nombre = a.nombre WHERE a.fase = 'antes' AND a.nombre NOT LIKE 'fn_caller_tiene_permiso%'$$);
SELECT pg_temp.verifica('A4 la función es LANGUAGE sql, STABLE, INVOKER (no inlineable por tener CTE recursiva y subconsultas)',
  $$SELECT lang = 'sql' AND vol = 's' AND NOT secdef FROM _fn WHERE fase = 'despues' AND nombre LIKE 'fn_caller_tiene_permiso%'$$);

-- ============================================================================
-- B)–C) Planes: no inlineada antes ni después; mismas filas, buffers y tiempo sin regresión
-- ============================================================================
SELECT pg_temp.verifica('B1 la función NO estaba inlineada antes: al menos un plan con RLS muestra la llamada a fn_caller_tiene_permiso (el SET no puede cambiar el plan por inlining)',
  $$SELECT bool_or(NOT inline_ok) FROM _med WHERE fase = 'antes'$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'B2 (informativo) el plan sigue mostrando la llamada a fn_caller_tiene_permiso antes -> después por consulta', true,
       string_agg(a.q || ': ' || (NOT a.inline_ok)::text || '->' || (NOT d.inline_ok)::text, '; ' ORDER BY a.q)
FROM _med a JOIN _med d ON d.fase = 'despues' AND d.q = a.q WHERE a.fase = 'antes';
SELECT pg_temp.verifica('C1 mismas filas (Actual Rows del plan) antes y después en las 7 consultas',
  $$SELECT bool_and(a.filas = d.filas) AND count(*) = 7 FROM _med a JOIN _med d ON d.fase = 'despues' AND d.q = a.q WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('C2 buffers después <= 1.25 × antes + 10 en cada consulta',
  $$SELECT bool_and(d.buf <= a.buf * 1.25 + 10) FROM _med a JOIN _med d ON d.fase = 'despues' AND d.q = a.q WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('C3 tiempo (mediana de 5) después <= 2 × antes + 3 ms en cada consulta (umbral generoso: ruido de red/caché)',
  $$SELECT bool_and(d.ms <= a.ms * 2 + 3) FROM _med a JOIN _med d ON d.fase = 'despues' AND d.q = a.q WHERE a.fase = 'antes'$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'C4 (informativo) ms mediana y buffers antes -> después: ' || a.q, true,
       a.ms::numeric(10,3) || ' ms/' || a.buf || ' buf -> ' || d.ms::numeric(10,3) || ' ms/' || d.buf || ' buf (filas ' || a.filas || ')'
FROM _med a JOIN _med d ON d.fase = 'despues' AND d.q = a.q WHERE a.fase = 'antes' ORDER BY a.q;

-- ============================================================================
-- D) Mismo resultado de la función
-- ============================================================================
SELECT pg_temp.verifica('D1 la función devuelve lo MISMO antes y después para el admin (3 permisos) y para un usuario inexistente (2 permisos)',
  $$SELECT bool_and(a.valor = d.valor) AND count(*) = 5 FROM _v a JOIN _v d ON d.fase = 'despues' AND d.quien = a.quien WHERE a.fase = 'antes'$$);
SELECT pg_temp.verifica('D2 y el resultado es el esperado: admin con banco_de_horas_lectura y movimiento_de_saldo_edicion = true; permiso inexistente y usuario inexistente = false',
  $$SELECT bool_and(CASE WHEN quien IN ('admin:banco_de_horas_lectura', 'admin:movimiento_de_saldo_edicion') THEN valor ELSE NOT valor END) AND count(*) = 5 FROM _v WHERE fase = 'despues'$$);

-- ============================================================================
-- E) Reversa: RESET search_path deja el proconfig EXACTO
-- ============================================================================
ALTER FUNCTION personas.fn_caller_tiene_permiso(text) RESET search_path;
SELECT pg_temp.foto('reversa');
SELECT pg_temp.verifica('E1 tras RESET search_path, las 3 funciones quedan EXACTAMENTE como antes (proconfig, ACL, atributos y cuerpo)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _fn a JOIN _fn r ON r.fase = 'reversa' AND r.nombre = a.nombre WHERE a.fase = 'antes' AND (a.cfg <> r.cfg OR a.proacl <> r.proacl OR a.secdef <> r.secdef OR a.vol <> r.vol OR a.md5src <> r.md5src))$$);
\ir ../ddl/106_personas_fn_caller_tiene_permiso_search_path.sql
SELECT pg_temp.verifica('E2 106_ es idempotente: reaplicarla tras la reversa deja search_path = personas, pg_temp',
  $$SELECT proconfig = ARRAY['search_path=personas, pg_temp'] FROM pg_proc WHERE oid = 'personas.fn_caller_tiene_permiso(text)'::regprocedure$$);

-- ============================================================================
-- F) verificar_ddl.sql completo con 106_ aplicada: sección 71 en 0 filas
-- ============================================================================
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
