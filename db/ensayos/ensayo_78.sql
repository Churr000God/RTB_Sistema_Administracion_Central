-- PROPUESTA de ensayo de comportamiento de 78_tiempo_excepcion_protege_dia_cerrado.sql (ya aplicado en la base
-- real el 2026-10-07). NO CORRIDO. Requiere OK explícito del usuario. NO es DDL versionado.
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <este archivo>   (SIN -1; puerto 5432, no el pooler 6543)
-- Todo dentro de BEGIN … ROLLBACK. NO aplica ningún DDL: sólo prueba el comportamiento del trigger YA aplicado.
-- Qué prueba: (a) una resolución directa (UPDATE pendiente -> resuelto) de una excepción de motivo dia_cerrado es
-- RECHAZADA con 42501; (b) fn_dia_revisar sigue resolviéndola (y arma el tramo, deja el día revisado) sin que el
-- trigger la bloquee; (c) otros motivos de excepción no se ven afectados; (d) una marca tardía posterior a la
-- revisión (sin tramo) tampoco se puede resolver a mano; (e) la función de trigger no es ejecutable por la API.
-- Detalle técnico: el trigger es DEFERRABLE INITIALLY DEFERRED, así que se dispara al COMMIT, que aquí nunca llega;
-- cada caso fuerza la comprobación con SET CONSTRAINTS ALL IMMEDIATE dentro del mismo bloque.
-- Requisitos: existe un usuario activo asignado hoy al puesto es_administrador_generico (caller de fn_dia_revisar,
-- con todos los permisos). Las excepciones de fixture no tocan datos reales: persona SINTÉTICA, terminal ENS78.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

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

CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', COALESCE(p_sub, (SELECT v FROM _ens WHERE k='auth_uid')), 'role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
  END;
  RESET ROLE;
  INSERT INTO _res (caso, ok, detalle) VALUES (
    p_caso,
    CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok' ELSE v_estado = p_esperado END,
    'obtenido=' || v_estado || ' ' || left(v_msg, 120));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.verifica(p_caso text, p_sql text) RETURNS void AS $$
DECLARE v boolean;
BEGIN
  EXECUTE p_sql INTO v;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, COALESCE(v, false), p_sql);
END;
$$ LANGUAGE plpgsql;

-- ---------- fixtures (como dueño) ----------
-- Persona sintética activa, un día CERRADO (hace 3 días) y 2 marcas tardías que forman un par (10:00 y 14:00 locales):
-- el trigger existente trg_marca_valida_revision crea una excepción 'dia_cerrado' pendiente por cada marca.
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXD1', 'XEXX010101D1', '99999999993', 'Sintetica', 'Dia Cerrado', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'persona_d', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXD1';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'persona_d' ON CONFLICT DO NOTHING;
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
SELECT v::uuid, CURRENT_DATE - 3, 'cerrado', 0 FROM _ens WHERE k = 'persona_d';
INSERT INTO _ens SELECT 'dia', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k = 'persona_d');
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT v::uuid, 'ENS78', g.n, ((CURRENT_DATE - 3)::timestamp + g.h * interval '1 hour') AT TIME ZONE 'UTC', '-06:00', 'sincronizado', 'ens', 'terminal'
FROM _ens, (VALUES (1, 16), (2, 20)) AS g(n, h) WHERE k = 'persona_d';

-- ---------- casos ----------
SELECT pg_temp.verifica('10 fixture: 2 excepciones dia_cerrado pendientes sobre las marcas del día cerrado',
  $$SELECT count(*) = 2 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE m.terminal_id = 'ENS78' AND e.motivo_revision LIKE 'dia_cerrado%' AND e.estado = 'pendiente'$$);

-- (a) resolución directa: rechazada
SELECT pg_temp.caso('11 UPDATE directo pendiente -> resuelto de una excepción dia_cerrado, como dueño -> 42501', current_user::text,
  $q$DO $b$ BEGIN
       SET CONSTRAINTS ALL IMMEDIATE;
       UPDATE tiempo.excepcion e SET estado = 'resuelto'
        WHERE e.id = (SELECT e2.id FROM tiempo.excepcion e2 JOIN tiempo.marca m ON m.id = e2.marca_id
                      WHERE m.terminal_id = 'ENS78' AND e2.motivo_revision LIKE 'dia_cerrado%' ORDER BY e2.id LIMIT 1);
     END $b$$q$, '42501');
SELECT pg_temp.verifica('11b la excepción sigue pendiente tras el rechazo',
  $$SELECT count(*) = 2 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE m.terminal_id = 'ENS78' AND e.motivo_revision LIKE 'dia_cerrado%' AND e.estado = 'pendiente'$$);
SELECT pg_temp.caso('11c el mismo UPDATE por PostgREST como el admin real (authenticated): rechazado (42501) o 0 filas por RLS', 'authenticated',
  $q$DO $b$ BEGIN
       SET CONSTRAINTS ALL IMMEDIATE;
       UPDATE tiempo.excepcion e SET estado = 'resuelto'
        WHERE e.id IN (SELECT e2.id FROM tiempo.excepcion e2 JOIN tiempo.marca m ON m.id = e2.marca_id
                       WHERE m.terminal_id = 'ENS78' AND e2.motivo_revision LIKE 'dia_cerrado%');
     END $b$$q$, 'error');
SELECT pg_temp.verifica('11d ... y en ningún caso quedó resuelta',
  $$SELECT count(*) = 2 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE m.terminal_id = 'ENS78' AND e.motivo_revision LIKE 'dia_cerrado%' AND e.estado = 'pendiente'$$);
-- NOTA: 11c puede dar 'ok' si RLS filtra el UPDATE a 0 filas (no hay error); en ese caso el resultado esperado de este
-- caso es FAIL "obtenido=ok" y la verificación 11d es la que cuenta. Se deja 'error' para forzar a mirar el detalle.

-- (c) otros motivos no se ven afectados (el WHEN del trigger sólo mira dia_cerrado)
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT v::uuid, 'ENS78', 3, now(), '-06:00', 'deriva', 'ens', 'terminal' FROM _ens WHERE k = 'persona_d';
SELECT pg_temp.caso('12 resolver a mano una excepción reloj_no_sincronizado (otro motivo) no se bloquea', current_user::text,
  $q$DO $b$ BEGIN
       SET CONSTRAINTS ALL IMMEDIATE;
       UPDATE tiempo.excepcion e SET estado = 'resuelto'
        WHERE e.id = (SELECT e2.id FROM tiempo.excepcion e2 JOIN tiempo.marca m ON m.id = e2.marca_id
                      WHERE m.terminal_id = 'ENS78' AND m.secuencia_local = 3 AND e2.motivo_revision = 'reloj_no_sincronizado');
     END $b$$q$, 'ok');

-- (b) fn_dia_revisar sigue resolviéndola
SELECT pg_temp.caso('20 fn_dia_revisar sobre el día cerrado, como el admin real: arma el tramo y resuelve ambas excepciones', 'authenticated',
  format('SELECT tiempo.fn_dia_revisar(%L::bigint, 4)', (SELECT v FROM _ens WHERE k = 'dia')), 'ok');
SELECT pg_temp.caso('20b ... y el trigger diferido no la bloquea al comprobarse (SET CONSTRAINTS ALL IMMEDIATE)', current_user::text,
  'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('20c el día quedó revisado, con un tramo que usa las dos marcas, y las 2 excepciones dia_cerrado resueltas',
  $$SELECT (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k = 'dia')) = 'revisado'
      AND (SELECT count(*) FROM tiempo.tramo WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k = 'dia')) = 1
      AND (SELECT count(*) FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
           WHERE m.terminal_id = 'ENS78' AND m.secuencia_local IN (1, 2) AND e.motivo_revision LIKE 'dia_cerrado%' AND e.estado = 'resuelto') = 2$$);

-- (d) una marca tardía posterior a la revisión, sin tramo: no se puede resolver a mano
INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
SELECT v::uuid, 'ENS78', 4, ((CURRENT_DATE - 3)::timestamp + interval '23 hours') AT TIME ZONE 'UTC', '-06:00', 'sincronizado', 'ens', 'terminal' FROM _ens WHERE k = 'persona_d';
SELECT pg_temp.verifica('30 fixture: la marca tardía sobre el día ya revisado generó una excepción dia_cerrado pendiente',
  $$SELECT count(*) = 1 FROM tiempo.excepcion e JOIN tiempo.marca m ON m.id = e.marca_id
    WHERE m.terminal_id = 'ENS78' AND m.secuencia_local = 4 AND e.motivo_revision LIKE 'dia_cerrado%' AND e.estado = 'pendiente'$$);
SELECT pg_temp.caso('30b resolverla a mano (la marca no pertenece a ningún tramo del día revisado) -> 42501', current_user::text,
  $q$DO $b$ BEGIN
       SET CONSTRAINTS ALL IMMEDIATE;
       UPDATE tiempo.excepcion e SET estado = 'resuelto'
        WHERE e.id = (SELECT e2.id FROM tiempo.excepcion e2 JOIN tiempo.marca m ON m.id = e2.marca_id
                      WHERE m.terminal_id = 'ENS78' AND m.secuencia_local = 4 AND e2.motivo_revision LIKE 'dia_cerrado%');
     END $b$$q$, '42501');

-- (e) la función de trigger no es ejecutable por la API
SELECT pg_temp.caso('40 anon no ejecuta la función del trigger', 'anon', 'SELECT tiempo.fn_excepcion_protege_dia_cerrado()', '42501');
SELECT pg_temp.caso('40b authenticated no ejecuta la función del trigger', 'authenticated', 'SELECT tiempo.fn_excepcion_protege_dia_cerrado()', '42501');
SELECT pg_temp.caso('40c service_role no ejecuta la función del trigger', 'service_role', 'SELECT tiempo.fn_excepcion_protege_dia_cerrado()', '42501');

-- ---------- resultado ----------
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;

ROLLBACK;
