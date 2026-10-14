-- Ensayo de 103_privilegios_update_delete_inmutables_y_humo_anon.sql. NO es DDL versionado. NO correr sin OK explícito del usuario (en el chat de la sesión de orchestrator) ni antes de la revisión de security.
--   psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/ensayos/ensayo_103.sql     (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. Aplica SOLO 103_ ENCIMA de lo ya aplicado (88_-102_). No inserta filas en ninguna bitácora ni en ninguna tabla real: solo catálogo de privilegios e intentos de
-- acceso con WHERE false o que deben fallar por privilegio (antes de tocar filas). Qué prueba: (A) foto de privilegios de personas y tiempo antes/después: 103_ no agrega nada y quita EXACTAMENTE la
-- lista prevista (conjunto igual, ni más ni menos); (B) comportamiento con SET ROLE; (C) lo que se CONSERVA (UPDATE de las funciones INVOKER, banco_de_horas, parametro UPDATE, etc.); (D) reversa
-- exacta e idempotencia; (E) verificar_ddl.sql completo (sección 67 en 0 filas).
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _res (n serial, caso text, ok boolean, detalle text);
CREATE TEMP TABLE _foto (fase text, rol text, rel text, priv text, nivel text);
CREATE TEMP TABLE _reversa (n serial, sentencia text);
-- Lo que 103_ debe quitar, EXACTAMENTE (rol, relación, privilegio de tabla).
CREATE TEMP TABLE _esperado (rol text, rel text, priv text);
INSERT INTO _esperado VALUES
  ('anon', 'personas.permiso', 'SELECT'),
  ('service_role', 'personas.bitacora_movimiento_persona', 'UPDATE'), ('service_role', 'personas.bitacora_movimiento_persona', 'DELETE'),
  ('authenticated', 'tiempo.aprobacion_ausencia', 'UPDATE'), ('authenticated', 'tiempo.aprobacion_ausencia', 'DELETE'),
  ('authenticated', 'tiempo.clasificacion_de_tiempo', 'UPDATE'), ('authenticated', 'tiempo.clasificacion_de_tiempo', 'DELETE'),
  ('authenticated', 'tiempo.corrida_batch', 'UPDATE'), ('authenticated', 'tiempo.corrida_batch', 'DELETE'),
  ('authenticated', 'tiempo.dia_festivo', 'UPDATE'), ('authenticated', 'tiempo.dia_festivo', 'DELETE'),
  ('authenticated', 'tiempo.tope_legal', 'UPDATE'), ('authenticated', 'tiempo.tope_legal', 'DELETE'),
  ('authenticated', 'tiempo.persona', 'UPDATE'), ('authenticated', 'tiempo.persona', 'DELETE'),
  ('authenticated', 'tiempo.ausencia', 'DELETE'), ('authenticated', 'tiempo.dia', 'DELETE'),
  ('authenticated', 'tiempo.excepcion', 'DELETE'), ('authenticated', 'tiempo.tramo', 'DELETE'),
  ('service_role', 'tiempo.parametro', 'DELETE');
GRANT ALL ON _res TO PUBLIC;
GRANT USAGE ON SEQUENCE _res_n_seq TO PUBLIC;

CREATE FUNCTION pg_temp.foto(p_fase text) RETURNS void AS $$
BEGIN
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'tabla'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN unnest(CASE WHEN current_setting('server_version_num')::integer >= 170000
                         THEN ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']
                         ELSE ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] END) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_table_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'columna'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND has_any_column_privilege(r.rol, c.oid, p.priv);
  INSERT INTO _foto
  SELECT p_fase, r.rol, n.nspname || '.' || c.relname::text, p.priv, 'secuencia'
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) r(rol)
  CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) p(priv)
  WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind = 'S' AND has_sequence_privilege(r.rol, c.oid, p.priv);
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), left(p_sql, 150));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text) RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_estado = p_esperado, 'obtenido=' || v_estado || ' ' || left(v_msg, 90));
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Foto previa y reversa (la consulta de la reversa de 103_, para los dos esquemas)
-- ============================================================================
SELECT pg_temp.foto('antes');
INSERT INTO _reversa (sentencia)
SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
              CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
WHERE n.nspname IN ('personas', 'tiempo') AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
GROUP BY c.oid, c.relkind, r.rolname;
INSERT INTO _res (caso, ok, detalle) SELECT 'P0 la foto previa y la reversa tienen contenido', (SELECT count(*) FROM _foto WHERE fase = 'antes') > 0 AND (SELECT count(*) FROM _reversa) > 0,
  'filas foto=' || (SELECT count(*) FROM _foto WHERE fase = 'antes') || ' sentencias reversa=' || (SELECT count(*) FROM _reversa);
SELECT pg_temp.verifica('P1 precondición: TODO lo esperado existía antes (si no, 103_ ya estaba aplicada o la base difiere)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _esperado e WHERE NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.nivel = 'tabla' AND (a.rol, a.rel, a.priv) = (e.rol, e.rel, e.priv)))$$);

\ir ../ddl/103_privilegios_update_delete_inmutables_y_humo_anon.sql

SELECT pg_temp.foto('despues');

-- ============================================================================
-- A) Diferencia de privilegios: EXACTAMENTE la lista esperada
-- ============================================================================
SELECT pg_temp.verifica('A1 103_ NO agrega ningún privilegio',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (d.rol, d.rel, d.priv, d.nivel)))$$);
SELECT pg_temp.verifica('A2 lo que quita (nivel tabla) es EXACTAMENTE la lista esperada: nada de más (conjunto quitado ⊆ esperado)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.nivel = 'tabla'
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel))
        AND NOT EXISTS (SELECT 1 FROM _esperado e WHERE (e.rol, e.rel, e.priv) = (a.rol, a.rel, a.priv)))$$);
SELECT pg_temp.verifica('A3 ... y nada de lo esperado queda: cada privilegio esperado desapareció (esperado ⊆ quitado)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _esperado e WHERE EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND d.nivel = 'tabla' AND (d.rol, d.rel, d.priv) = (e.rol, e.rel, e.priv)))$$);
SELECT pg_temp.verifica('A4 lo que se quita a nivel COLUMNA es solo consecuencia de lo anterior (UPDATE/SELECT de las tablas listadas)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.nivel = 'columna'
        AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel))
        AND NOT EXISTS (SELECT 1 FROM _esperado e WHERE (e.rol, e.rel) = (a.rol, a.rel) AND e.priv = a.priv))$$);
SELECT pg_temp.verifica('A5 las secuencias no cambian', $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND a.nivel = 'secuencia' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel)))$$);
INSERT INTO _res (caso, ok, detalle)
SELECT 'A6 (informativo) privilegios quitados por rol', true,
  'anon=' || count(*) FILTER (WHERE a.rol = 'anon') || ' authenticated=' || count(*) FILTER (WHERE a.rol = 'authenticated') || ' service_role=' || count(*) FILTER (WHERE a.rol = 'service_role')
FROM _foto a WHERE a.fase = 'antes' AND a.nivel = 'tabla' AND NOT EXISTS (SELECT 1 FROM _foto d WHERE d.fase = 'despues' AND (d.rol, d.rel, d.priv, d.nivel) = (a.rol, a.rel, a.priv, a.nivel));

-- ============================================================================
-- B) Comportamiento (sin tocar filas: privilegio denegado antes, o WHERE false)
-- ============================================================================
SELECT pg_temp.caso('B1 anon SELECT personas.permiso => 42501 (el humo del Data API ahora espera 401)', 'anon', $$SELECT 1 FROM personas.permiso LIMIT 1$$, '42501');
SELECT pg_temp.caso('B2 service_role DELETE personas.bitacora_movimiento_persona => 42501 (antes lo frenaba solo el trigger)', 'service_role', $$DELETE FROM personas.bitacora_movimiento_persona WHERE false$$, '42501');
SELECT pg_temp.caso('B3 service_role SELECT personas.bitacora_movimiento_persona sigue ok', 'service_role', $$SELECT 1 FROM personas.bitacora_movimiento_persona LIMIT 1$$, 'ok');
SELECT pg_temp.caso('B4 authenticated DELETE tiempo.tramo => 42501', 'authenticated', $$DELETE FROM tiempo.tramo WHERE false$$, '42501');
SELECT pg_temp.caso('B5 authenticated DELETE tiempo.dia_festivo => 42501', 'authenticated', $$DELETE FROM tiempo.dia_festivo WHERE false$$, '42501');
SELECT pg_temp.caso('B6 authenticated UPDATE tiempo.tope_legal => 42501', 'authenticated', $$UPDATE tiempo.tope_legal SET maximo_semanal = maximo_semanal WHERE false$$, '42501');
SELECT pg_temp.caso('B7 service_role DELETE tiempo.parametro => 42501', 'service_role', $$DELETE FROM tiempo.parametro WHERE false$$, '42501');
SELECT pg_temp.caso('B8 service_role UPDATE tiempo.parametro SIGUE ok (lo usa fn_parametro_actualizar_valor)', 'service_role', $$UPDATE tiempo.parametro SET valor = valor WHERE false$$, 'ok');
SELECT pg_temp.caso('B9 service_role DELETE tiempo.dia_festivo SIGUE ok (backend/app/routers/dias_festivos.py:98)', 'service_role', $$DELETE FROM tiempo.dia_festivo WHERE false$$, 'ok');
SELECT pg_temp.caso('B10 service_role UPDATE tiempo.dia SIGUE ok (backend/app/batches/cierre_dia.py:270)', 'service_role', $$UPDATE tiempo.dia SET horas_totales = horas_totales WHERE false$$, 'ok');
SELECT pg_temp.caso('B11 service_role UPDATE tiempo.corrida_batch SIGUE ok (backend/app/batches/_orquestacion.py)', 'service_role', $$UPDATE tiempo.corrida_batch SET estado = estado WHERE false$$, 'ok');
SELECT pg_temp.caso('B12 authenticated UPDATE tiempo.banco_de_horas SIGUE ok (trigger INVOKER fn_movimiento_de_saldo_actualiza_banco; ver «fuera de alcance»)', 'authenticated', $$UPDATE tiempo.banco_de_horas SET monto = monto WHERE false$$, 'ok');

-- ============================================================================
-- C) Lo que se conserva para las funciones INVOKER que ejecuta authenticated
-- ============================================================================
SELECT pg_temp.verifica('C1 authenticated conserva UPDATE (tabla o columna) en ausencia, dia, excepcion, tramo, jornada_asignada, patron_semanal y personas.persona',
  $$SELECT bool_and(has_any_column_privilege('authenticated', t, 'UPDATE')) FROM unnest(ARRAY['tiempo.ausencia','tiempo.dia','tiempo.excepcion','tiempo.tramo','tiempo.jornada_asignada','tiempo.patron_semanal','personas.persona']) t$$);
SELECT pg_temp.verifica('C2 authenticated conserva DELETE en jornada_asignada y patron_semanal (fn_jornada_futura_eliminar)',
  $$SELECT has_table_privilege('authenticated', 'tiempo.jornada_asignada', 'DELETE') AND has_table_privilege('authenticated', 'tiempo.patron_semanal', 'DELETE')$$);
SELECT pg_temp.verifica('C3 las 11 tablas de personas: authenticated y service_role conservan SELECT; service_role conserva INSERT en bitacora_movimiento_persona',
  $$SELECT bool_and(has_table_privilege(r, t, 'SELECT')) AND has_table_privilege('service_role', 'personas.bitacora_movimiento_persona', 'INSERT')
    FROM unnest(ARRAY['authenticated','service_role']) r CROSS JOIN (SELECT n.nspname || '.' || c.relname AS t FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'personas' AND c.relkind = 'r') x$$);
SELECT pg_temp.verifica('C4 policies: 77 en total (103_ no crea ni cambia policies)', $$SELECT (SELECT count(*) FROM pg_policies WHERE schemaname IN ('personas', 'tiempo')) = 77$$);
SELECT pg_temp.verifica('C5 los triggers de inmutabilidad siguen habilitados',
  $$SELECT count(*) >= 6 AND bool_and(t.tgenabled = 'O') FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgname LIKE '%inmutable%' AND t.tgrelid::regclass::text ~ '^(personas|tiempo)\.'$$);

-- ============================================================================
-- D) Reversa exacta e idempotencia
-- ============================================================================
SELECT pg_temp.foto('tras_103');
DO $$
DECLARE s record;
BEGIN
  FOR s IN SELECT sentencia FROM _reversa ORDER BY n LOOP EXECUTE s.sentencia; END LOOP;
END
$$;
SELECT pg_temp.foto('reversa');
SELECT pg_temp.verifica('D1 la reversa documentada deja los privilegios IDÉNTICOS a la foto previa (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reversa' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'antes' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);
\ir ../ddl/103_privilegios_update_delete_inmutables_y_humo_anon.sql
SELECT pg_temp.foto('reaplicada');
SELECT pg_temp.verifica('D2 103_ es idempotente: reaplicarla tras la reversa deja la misma foto (en ambos sentidos)',
  $$SELECT NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_103' AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND (b.rol, b.rel, b.priv, b.nivel) = (a.rol, a.rel, a.priv, a.nivel)))
        AND NOT EXISTS (SELECT 1 FROM _foto b WHERE b.fase = 'reaplicada' AND NOT EXISTS (SELECT 1 FROM _foto a WHERE a.fase = 'tras_103' AND (a.rol, a.rel, a.priv, a.nivel) = (b.rol, b.rel, b.priv, b.nivel)))$$);

-- ============================================================================
-- E) verificar_ddl.sql completo con 103_ aplicada: sección 67 en 0 filas
-- ============================================================================
\ir ../verificar_ddl.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
