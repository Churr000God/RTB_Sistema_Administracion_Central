-- Ensayo de 86_tiempo_excepcion_protege_dia_cerrado_v2.sql (cierre del hallazgo de 78_, security 2026-10-07).
-- NO CORRIDO. Requiere OK explícito del usuario y la revisión de security. NO es DDL versionado.
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <este archivo>   (SIN -1; puerto 5432, no el pooler 6543)
-- BEGIN … ROLLBACK. Aplica 86_ ENCIMA de lo ya aplicado (78_ incluido) y corre los casos de comportamiento.
-- Requisitos: existe un usuario activo asignado hoy al puesto es_administrador_generico (con todos los permisos, incluido
-- el nuevo excepcion_dia_cerrado_descarte que 86_ otorga a ese puesto); personas y marcas de fixture son SINTÉTICAS.
-- IMPORTANTE sobre "misma transacción": el script entero es UNA transacción, así que now() es el mismo en todos los
-- casos. Para emular "una revisión/descarte de otra transacción" se usan filas de fixture con revisado_en / creado_en
-- anteriores (insertadas como dueño). El constraint trigger es DEFERRABLE INITIALLY DEFERRED (se comprueba al COMMIT,
-- que aquí nunca llega): cada caso fuerza la comprobación con SET CONSTRAINTS ALL IMMEDIATE dentro del mismo bloque.
-- Tras cada operación legítima se vuelve a hacer SET CONSTRAINTS ALL IMMEDIATE para vaciar los eventos diferidos
-- pendientes antes de manipular fixtures.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/86_tiempo_excepcion_protege_dia_cerrado_v2.sql

-- ---------- helpers y fixtures (como dueño) ----------
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
INSERT INTO _ens SELECT 'admin_persona', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_uid');

CREATE FUNCTION pg_temp.caso(p_caso text, p_rol text, p_sql text, p_esperado text, p_sub text DEFAULT NULL, p_hint text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_estado text := 'ok'; v_msg text := ''; v_hint text := NULL;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', COALESCE(p_sub, (SELECT v FROM _ens WHERE k='auth_uid')), 'role', p_rol)::text, true);
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_estado := SQLSTATE; v_msg := SQLERRM;
    GET STACKED DIAGNOSTICS v_hint = PG_EXCEPTION_HINT;
  END;
  RESET ROLE;
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

-- Llama una función que devuelve jsonb como p_rol (con claims del admin real o de p_sub) y evalúa p_check ($1 = resultado).
CREATE FUNCTION pg_temp.rpc(p_caso text, p_rol text, p_llamada text, p_check text, p_sub text DEFAULT NULL) RETURNS void AS $$
DECLARE v_res jsonb; v_ok boolean := false; v_det text := '';
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', COALESCE(p_sub, (SELECT v FROM _ens WHERE k='auth_uid')), 'role', p_rol)::text, true);
  BEGIN
    EXECUTE 'SELECT ' || p_llamada INTO v_res;
  EXCEPTION WHEN OTHERS THEN
    v_det := 'EXC ' || SQLSTATE || ' ' || left(SQLERRM, 100); v_res := NULL;
  END;
  RESET ROLE;
  IF v_det = '' THEN
    EXECUTE 'SELECT COALESCE(' || p_check || ', false)' INTO v_ok USING v_res;
  END IF;
  INSERT INTO _res (caso, ok, detalle) VALUES (p_caso, v_ok, v_det || ' ' || left(COALESCE(v_res::text, 'null'), 300));
END;
$$ LANGUAGE plpgsql;

-- Marca de fixture (persona, fecha, hora UTC; desfase +00:00 => fecha local = fecha UTC). Devuelve el id.
CREATE FUNCTION pg_temp.mk(p_persona uuid, p_fecha date, p_hora numeric, p_seq integer, p_reloj text DEFAULT 'sincronizado')
RETURNS bigint AS $$
  INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (p_persona, 'ENS86', p_seq, (p_fecha::timestamp + p_hora * interval '1 hour') AT TIME ZONE 'UTC', '+00:00', p_reloj, 'ens', 'terminal')
  RETURNING id;
$$ LANGUAGE sql;
CREATE FUNCTION pg_temp.ex(p_marca bigint) RETURNS bigint AS $$
  SELECT id FROM tiempo.excepcion WHERE marca_id = p_marca ORDER BY id LIMIT 1;
$$ LANGUAGE sql;

-- Personas sintéticas D y E (activas).
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso) VALUES
  ('XEXX010101HNEXXXD2', 'XEXX010101D2', '99999999994', 'SinteticaD', 'Ensayo86', '2000-01-01', CURRENT_DATE),
  ('XEXX010101HNEXXXE2', 'XEXX010101E2', '99999999995', 'SinteticaE', 'Ensayo86', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'pD', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXD2';
INSERT INTO _ens SELECT 'pE', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXE2';
INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso) VALUES
  ('XEXX010101HNEXXXF2', 'XEXX010101F2', '99999999996', 'SinteticaF', 'Ensayo86', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'pF', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXF2';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k IN ('pD', 'pE', 'pF') ON CONFLICT DO NOTHING;
INSERT INTO _ens VALUES ('f1', (CURRENT_DATE - 5)::text), ('f2', (CURRENT_DATE - 4)::text), ('f3', (CURRENT_DATE - 3)::text);

-- D1: día CERRADO de D (f1); sus marcas llegan DESPUÉS => excepciones dia_cerrado pendientes (a1, a2).
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
SELECT v::uuid, (SELECT v::date FROM _ens WHERE k='f1'), 'cerrado', 0 FROM _ens WHERE k = 'pD';
INSERT INTO _ens SELECT 'D1', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pD') AND fecha = (SELECT v::date FROM _ens WHERE k='f1');
INSERT INTO _ens VALUES
  ('a1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f1'), 10, 1)::text),
  ('a2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f1'), 14, 2)::text);

-- D2: día de D (f2) ya REVISADO "ayer" (revisado_en hace 2 h), con su tramo legítimo (b1-b2). Las marcas b1/b2 se
-- insertan ANTES del día (sin excepción dia_cerrado). Después llegan marcas tardías c1..c8 => excepciones dia_cerrado.
INSERT INTO _ens VALUES
  ('b1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f2'), 10, 3)::text),
  ('b2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f2'), 14, 4)::text);
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, revisado_por, revisado_en)
SELECT v::uuid, (SELECT v::date FROM _ens WHERE k='f2'), 'revisado', 4, v::uuid, now() - interval '2 hours' FROM _ens WHERE k = 'pD';
INSERT INTO _ens SELECT 'D2', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pD') AND fecha = (SELECT v::date FROM _ens WHERE k='f2');
INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
SELECT (SELECT v::bigint FROM _ens WHERE k='D2'), (SELECT v::bigint FROM _ens WHERE k='b1'), (SELECT v::bigint FROM _ens WHERE k='b2'),
       (SELECT momento_dispositivo FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k='b1')),
       (SELECT momento_dispositivo FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k='b2')), 240;
INSERT INTO _ens SELECT 'c' || g, pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f2'), 14 + g, 10 + g)::text
FROM generate_series(1, 8) g;

-- E: persona distinta con su propio día revisado (f2) y marcas e1/e2 (para los casos de tramo de otra persona).
INSERT INTO _ens VALUES
  ('e1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f2'), 10, 20)::text),
  ('e2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f2'), 14, 21)::text);

-- Marcas con OTROS motivos (día sin fila => sin dia_cerrado): reloj_no_sincronizado (estado_reloj deriva) en f3.
INSERT INTO _ens SELECT 'r' || g, pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::date FROM _ens WHERE k='f3'), 8 + g, 30 + g, 'deriva')::text
FROM generate_series(1, 5) g;

-- Fixtures a mano (como dueño, INSERT directo: no dispara los triggers de UPDATE):
-- (i) una excepción dia_cerrado pendiente sobre b1, que YA está en el tramo del día revisado "ayer" (ALTO-2 con tramo legítimo);
INSERT INTO tiempo.excepcion (marca_id, motivo_revision) SELECT v::bigint, 'dia_cerrado' FROM _ens WHERE k = 'b1';
-- (ii) c5: excepción dia_cerrado ya 'resuelto' con sufijo de descarte de OTRA transacción (descarte viejo), para probar reapertura;
INSERT INTO tiempo.excepcion (marca_id, motivo_revision, estado) SELECT v::bigint, 'dia_cerrado — descartada por x: viejo', 'resuelto' FROM _ens WHERE k = 'c5';
-- (iii) c8: excepción dia_cerrado 'resuelto' SIN descarte registrado (resuelta "por otra vía").
DELETE FROM tiempo.excepcion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='c8') AND estado = 'pendiente';
INSERT INTO tiempo.excepcion (marca_id, motivo_revision, estado) SELECT v::bigint, 'dia_cerrado', 'resuelto' FROM _ens WHERE k = 'c8';
-- (iv) c5: borrar la excepción pendiente que creó el trigger y dejar sólo la resuelta de (ii)
DELETE FROM tiempo.excepcion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='c5') AND estado = 'pendiente';
INSERT INTO tiempo.excepcion_descarte (excepcion_id, dia_id, persona_id, motivo, creado_en)
SELECT pg_temp.ex(c5.v::bigint), (SELECT v::bigint FROM _ens WHERE k='D2'), (SELECT v::uuid FROM _ens WHERE k='admin_persona'), 'viejo', now() - interval '3 days'
FROM _ens c5 WHERE c5.k = 'c5';


-- ---------- fixtures de la 2ª revisión de security (M1, B1, B2) ----------
INSERT INTO _ens VALUES ('f4', (CURRENT_DATE - 6)::text), ('f5', (CURRENT_DATE - 7)::text), ('f6', (CURRENT_DATE - 8)::text), ('f7', (CURRENT_DATE - 9)::text);

-- (b) ausencia REAL: dos días BLOQUEADOS de E (f3 y f6) con una excepción de DÍA pendiente (motivo paridad_impar) cada uno.
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
SELECT (SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k = f.k), 'bloqueado', 0 FROM (VALUES ('f3'), ('f6')) AS f(k);
INSERT INTO _ens SELECT 'Ef3', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pE') AND fecha = (SELECT v::date FROM _ens WHERE k='f3');
INSERT INTO _ens SELECT 'Ef6', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pE') AND fecha = (SELECT v::date FROM _ens WHERE k='f6');
INSERT INTO tiempo.excepcion (dia_id, motivo_revision) SELECT v::bigint, 'paridad_impar' FROM _ens WHERE k IN ('Ef3', 'Ef6');

-- (c) tramo como lo arma cierre_dia.py (service_role): marcas k1/k2 de E del día f4 (insertadas ANTES del día => sin dia_cerrado);
-- m1 (cruda en f7 10:00) corregida a f4 00:30 + m2 (f4 01:00): su fecha EFECTIVA es f4. Día f7 y f4 de E, bloqueados.
INSERT INTO _ens VALUES
  ('k1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f4'), 10, 50)::text),
  ('k2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f4'), 14, 51)::text),
  ('m1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f7'), 10, 52)::text),
  ('m2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k='f4'), 1, 53)::text);
INSERT INTO tiempo.excepcion (marca_id, motivo_revision) SELECT v::bigint, 'reloj_no_sincronizado' FROM _ens WHERE k = 'm1';  -- fn_correccion_valida exige una excepción asociada
INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id)
SELECT (SELECT v::bigint FROM _ens WHERE k='m1'), ((SELECT v::date FROM _ens WHERE k='f4')::timestamp + interval '30 minutes') AT TIME ZONE 'UTC', 'ensayo86 cruza de fecha', (SELECT v::uuid FROM _ens WHERE k='admin_persona');
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
SELECT (SELECT v::uuid FROM _ens WHERE k='pE'), (SELECT v::date FROM _ens WHERE k = f.k), 'bloqueado', 0 FROM (VALUES ('f4'), ('f7')) AS f(k);
INSERT INTO _ens SELECT 'Ef4', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pE') AND fecha = (SELECT v::date FROM _ens WHERE k='f4');
INSERT INTO _ens SELECT 'Ef7', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pE') AND fecha = (SELECT v::date FROM _ens WHERE k='f7');

-- (d) día CERRADO de F (f5; persona aparte: una corrección sólo puede moverse entre sus marcas vecinas) con una marca tardía h2 (cruda f5) y otra h1 (cruda f6 00:30, corregida a f5 20:00). La corrección va ANTES
-- de la excepción manual de h1 (si no, el trigger de corrección la resolvería y quedaría un evento diferido en cola).
INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
SELECT (SELECT v::uuid FROM _ens WHERE k='pF'), (SELECT v::date FROM _ens WHERE k='f5'), 'cerrado', 0;
INSERT INTO _ens SELECT 'Ef5', id::text FROM tiempo.dia WHERE persona_id = (SELECT v::uuid FROM _ens WHERE k='pF') AND fecha = (SELECT v::date FROM _ens WHERE k='f5');
INSERT INTO _ens VALUES
  ('h1', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pF'), (SELECT v::date FROM _ens WHERE k='f6'), 0.5, 60)::text);
INSERT INTO tiempo.excepcion (marca_id, motivo_revision) SELECT v::bigint, 'reloj_no_sincronizado' FROM _ens WHERE k = 'h1';
INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id)
SELECT (SELECT v::bigint FROM _ens WHERE k='h1'), ((SELECT v::date FROM _ens WHERE k='f5')::timestamp + interval '20 hours') AT TIME ZONE 'UTC', 'ensayo86 marca tardía corregida', (SELECT v::uuid FROM _ens WHERE k='admin_persona');
INSERT INTO _ens VALUES
  ('h2', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pF'), (SELECT v::date FROM _ens WHERE k='f5'), 14, 61)::text);
INSERT INTO tiempo.excepcion (marca_id, motivo_revision) SELECT v::bigint, 'dia_cerrado' FROM _ens WHERE k = 'h1';

-- (f) usuario SINTÉTICO (auth.users + personas.usuario) de la persona D, asignado a un puesto sintético superior de otro que tiene
-- excepcion_edicion: lo hereda por jerarquía pero NO el permiso de acción excepcion_dia_cerrado_descarte (heredable=false).
-- Si esta inserción falla por triggers de auth.users o de asignacion (plazas), el script aborta: es un defecto del fixture.
-- Ningún puesto real que herede excepcion_edicion carece del permiso de acción (el padre de RH es el Gerente General, que lo tiene),
-- así que se crea una jerarquía SINTÉTICA: puesto superior (sin permisos propios) con un subordinado que tiene excepcion_edicion.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT p.departamento_id, 'ENS86 superior', 'gerencia', p.reporta_a_id FROM personas.puesto p WHERE p.nombre_puesto = 'Responsable de Recursos Humanos';
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT sup.departamento_id, 'ENS86 subordinado', 'mando_medio', sup.id FROM personas.puesto sup WHERE sup.nombre_puesto = 'ENS86 superior';
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT id, 'excepcion_edicion', 'otorgado' FROM personas.puesto WHERE nombre_puesto = 'ENS86 subordinado';
INSERT INTO _ens SELECT 'puesto_sup', id::text FROM personas.puesto WHERE nombre_puesto = 'ENS86 superior';
INSERT INTO _ens VALUES ('auth_sup', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', 'ensayo86@invalid.test' FROM _ens WHERE k = 'auth_sup';
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario)
SELECT (SELECT v::uuid FROM _ens WHERE k='auth_sup'), (SELECT v::uuid FROM _ens WHERE k='pD'), 'ensayo86';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='pD'), (SELECT v::uuid FROM _ens WHERE k='puesto_sup'), CURRENT_DATE;

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND EXISTS (SELECT 1 FROM _ens WHERE k='admin_persona')$$);
SELECT pg_temp.verifica('01 fixture: a1,a2 (día cerrado) y c1..c4,c6,c7 tienen excepción dia_cerrado pendiente; r1..r5 reloj_no_sincronizado',
  $$SELECT (SELECT count(*) FROM tiempo.excepcion e JOIN _ens x ON x.v::bigint = e.marca_id WHERE x.k IN ('a1','a2','c1','c2','c3','c4','c6','c7') AND e.motivo_revision = 'dia_cerrado' AND e.estado = 'pendiente') = 8
      AND (SELECT count(*) FROM tiempo.excepcion e JOIN _ens x ON x.v::bigint = e.marca_id WHERE x.k LIKE 'r_' AND e.motivo_revision = 'reloj_no_sincronizado' AND e.estado = 'pendiente') = 5$$);
SELECT pg_temp.verifica('01b fixture: la persona D tiene permiso (admin) y el permiso nuevo existe, no heredable, otorgado a los 3 puestos',
  $$SELECT EXISTS (SELECT 1 FROM personas.permiso WHERE codigo = 'excepcion_dia_cerrado_descarte' AND heredable = false)
      AND (SELECT count(DISTINCT pp.puesto_id) FROM personas.puesto_permiso pp WHERE pp.codigo = 'excepcion_dia_cerrado_descarte' AND pp.activo) = 3$$);

-- A. Protección de columnas (ALTO-1)
SELECT pg_temp.caso('10 cambiar marca_id de una excepción -> SCJ15 excepcion_columna_inmutable', current_user::text,
  $$UPDATE tiempo.excepcion SET marca_id = (SELECT v::bigint FROM _ens WHERE k='a2') WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_columna_inmutable');
SELECT pg_temp.caso('10b cambiar dia_id (y limpiar marca_id) -> SCJ15 excepcion_columna_inmutable', current_user::text,
  $$UPDATE tiempo.excepcion SET marca_id = NULL, dia_id = (SELECT v::bigint FROM _ens WHERE k='D1') WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_columna_inmutable');
SELECT pg_temp.caso('10c cambiar creado_en -> SCJ15 excepcion_columna_inmutable', current_user::text,
  $$UPDATE tiempo.excepcion SET creado_en = now() + interval '1 day' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_columna_inmutable');
SELECT pg_temp.caso('11 reemplazar el motivo sin resolver (paso 1 de ALTO-1) -> SCJ15 excepcion_motivo_inmutable', 'authenticated',
  $$UPDATE tiempo.excepcion SET motivo_revision = 'otro_motivo' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_motivo_inmutable');
SELECT pg_temp.caso('11b reemplazar el motivo Y resolver en el mismo UPDATE -> SCJ15 excepcion_motivo_inmutable', 'authenticated',
  $$UPDATE tiempo.excepcion SET motivo_revision = 'otro_motivo', estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_motivo_inmutable');
SELECT pg_temp.caso('11c agregar un sufijo sin resolver -> SCJ15 excepcion_motivo_inmutable', 'authenticated',
  $$UPDATE tiempo.excepcion SET motivo_revision = motivo_revision || ' — algo' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$, 'SCJ15', NULL, 'excepcion_motivo_inmutable');
SELECT pg_temp.caso('11d agregar un sufijo Y resolver (la evasión de dos pasos con prefijo conservado) -> el constraint trigger la rechaza', 'authenticated',
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto', motivo_revision = motivo_revision || ' — resuelto por ausencia autorizada, carga tardía'
        WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.verifica('11e ninguna de esas operaciones dejó resuelta ni alterada la excepción de a1',
  $$SELECT estado = 'pendiente' AND motivo_revision = 'dia_cerrado' FROM tiempo.excepcion WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'))$$);

-- B. Otros motivos intactos (el WHEN sólo mira dia_cerrado) y el sufijo legítimo de ausencia
SELECT pg_temp.caso('12 resolver a mano una excepción reloj_no_sincronizado (estado solamente) -> ok', 'authenticated',
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='r2'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'ok');
SELECT pg_temp.caso('12b resolver otra con el sufijo que agrega fn_ausencia_resuelve_excepcion -> ok', 'authenticated',
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto', motivo_revision = motivo_revision || ' — resuelto por ausencia autorizada, carga tardía'
        WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='r3'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'ok');
SELECT pg_temp.caso('12c ... pero reemplazando el motivo en vez de agregar sufijo -> SCJ15', 'authenticated',
  $$UPDATE tiempo.excepcion SET estado = 'resuelto', motivo_revision = 'otro' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='r4'))$$, 'SCJ15', NULL, 'excepcion_motivo_inmutable');

-- C. Resolución directa (ALTO-1 original y ALTO-2 con tramo legítimo de un día revisado ANTES)
SELECT pg_temp.caso('20 UPDATE directo pendiente -> resuelto de dia_cerrado, como dueño -> SCJ15 dia_cerrado_requiere_revision', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c1'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('20b ... como el admin real por PostgREST (authenticated) -> SCJ15 dia_cerrado_requiere_revision', 'authenticated',
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c1'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('20c el UPDATE en sí no falla (es diferido): falla al forzar SET CONSTRAINTS; sin forzarlo, el error llegaría al COMMIT', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c1'));
       -- hasta aquí sin error
       PERFORM 1;
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15');
SELECT pg_temp.verifica('20d c1 sigue pendiente', $$SELECT estado = 'pendiente' FROM tiempo.excepcion WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c1'))$$);
SELECT pg_temp.caso('21 excepción de una marca YA en el tramo legítimo de un día revisado hace 2 h (b1): resolverla directo -> SCJ15 (la revisión no es de esta transacción)', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='b1'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('22 reapertura + nueva resolución directa de una dia_cerrado que tenía un descarte VIEJO (otra transacción) -> SCJ15', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'pendiente' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c5'));
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c5'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('23 SET CONSTRAINTS no es un bypass: aun con el trigger diferido, forzarlo antes del COMMIT sólo lo adelanta (c1 sigue rechazada)', current_user::text,
  $q$DO $b$ BEGIN
       SET CONSTRAINTS ALL IMMEDIATE;
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c1'));
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');

-- D. Tramos (ALTO-2: origen del tramo falso)
SELECT pg_temp.caso('30 tramo de OTRA persona (marca e1 de E en un día de D) como el admin real -> SCJ15 tramo_incoherente', 'authenticated',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='e1'), (SELECT v FROM _ens WHERE k='e2')), 'SCJ15', NULL, 'tramo_incoherente');
SELECT pg_temp.caso('30b tramo con una marca de OTRO día de la misma persona (a1, f1) en el día D2 (f2) -> SCJ15 tramo_incoherente', 'authenticated',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='a1'), (SELECT v FROM _ens WHERE k='a2')), 'SCJ15', NULL, 'tramo_incoherente');
SELECT pg_temp.caso('30c apertura legítima (c3) con cierre de otra persona (e2) -> SCJ15 tramo_incoherente (se revisa también el cierre)', 'authenticated',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='c3'), (SELECT v FROM _ens WHERE k='e2')), 'SCJ15', NULL, 'tramo_incoherente');
SELECT pg_temp.caso('30d tramo COHERENTE (c3-c4, mismo día y persona) por la vía de escritura de tramo -> ok (es la capacidad legítima de dia_revision_edicion)', 'authenticated',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='c3'), (SELECT v FROM _ens WHERE k='c4')), 'ok');
SELECT pg_temp.caso('30e ... pero ese tramo coherente-falso NO basta para resolver la excepción de c3 (el día se revisó hace 2 h, no en esta transacción) -> SCJ15', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c3'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('30f UPDATE de un tramo que cambia su marca de cierre a una de otra persona -> SCJ15 tramo_incoherente', current_user::text,
  format($f$UPDATE tiempo.tramo SET marca_cierre_id = %L::bigint WHERE marca_apertura_id = %L::bigint$f$,
         (SELECT v FROM _ens WHERE k='e2'), (SELECT v FROM _ens WHERE k='c3')), 'SCJ15', NULL, 'tramo_incoherente');
SELECT pg_temp.caso('30g UPDATE de inicio/fin de un tramo (lo que hace una corrección) no se revisa -> ok', current_user::text,
  format($f$UPDATE tiempo.tramo SET fin = fin + interval '1 minute', minutos_trabajados = 61 WHERE marca_apertura_id = %L::bigint$f$,
         (SELECT v FROM _ens WHERE k='c3')), 'ok');

-- E. Corrección sobre marcas con dia_cerrado vs. con otros motivos (decisión 3 del usuario)
SELECT pg_temp.caso('40 corregir una marca con excepción dia_cerrado pendiente (c6) -> la corrección resuelve la excepción y el constraint trigger la rechaza (SCJ15)', 'authenticated',
  format($q$DO $b$ BEGIN
       INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id)
       VALUES (%L::bigint, (SELECT momento_dispositivo + interval '5 minutes' FROM tiempo.marca WHERE id = %L::bigint), 'ensayo', %L::uuid);
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, (SELECT v FROM _ens WHERE k='c6'), (SELECT v FROM _ens WHERE k='c6'), (SELECT v FROM _ens WHERE k='admin_persona')),
  'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('40b corregir una marca con excepción reloj_no_sincronizado (r1) -> ok', 'authenticated',
  format($q$DO $b$ BEGIN
       INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id)
       VALUES (%L::bigint, (SELECT momento_dispositivo + interval '5 minutes' FROM tiempo.marca WHERE id = %L::bigint), 'ensayo', %L::uuid);
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, (SELECT v FROM _ens WHERE k='r1'), (SELECT v FROM _ens WHERE k='r1'), (SELECT v FROM _ens WHERE k='admin_persona')), 'ok');
SELECT pg_temp.verifica('40c la corrección sobre r1 resolvió su excepción; la de c6 sigue pendiente',
  $$SELECT (SELECT estado FROM tiempo.excepcion WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='r1'))) = 'resuelto'
      AND (SELECT estado FROM tiempo.excepcion WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c6'))) = 'pendiente'$$);

-- F. DELETE / INSERT directos (no hay policy de escritura para ellos)
SELECT pg_temp.caso('50 INSERT directo en tiempo.excepcion como authenticated -> 42501 (RLS)', 'authenticated',
  format($f$INSERT INTO tiempo.excepcion (marca_id, motivo_revision, estado) VALUES (%L::bigint, 'dia_cerrado', 'resuelto')$f$, (SELECT v FROM _ens WHERE k='c7')), '42501');
SELECT pg_temp.caso('50b DELETE directo como authenticated no borra nada (RLS lo filtra a 0 filas)', 'authenticated',
  $$DELETE FROM tiempo.excepcion$$, 'ok');
SELECT pg_temp.verifica('50c ... la excepción de c7 sigue ahí', $$SELECT count(*) = 1 FROM tiempo.excepcion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='c7')$$);

-- G. RPC de descarte
SELECT pg_temp.caso('60 descartar sin permiso o sin usuario (claims de un auth_uid inexistente) -> 42501 sin_permiso', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), 'motivo'),
  '42501', '11111111-1111-1111-1111-111111111111', 'sin_permiso');
SELECT pg_temp.caso('60c el día no está revisado (a1, día cerrado de D1) -> SCJ15 dia_no_revisado', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1')), 'motivo'),
  'SCJ15', NULL, 'dia_no_revisado');
SELECT pg_temp.caso('60d excepción que no es dia_cerrado (r5, reloj_no_sincronizado) -> SCJ15 excepcion_no_descartable', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='r5')), 'motivo'),
  'SCJ15', NULL, 'excepcion_no_descartable');
SELECT pg_temp.caso('60e dia_cerrado ya resuelta por otra vía, sin descarte registrado (c8) -> SCJ15 excepcion_no_descartable', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c8')), 'motivo'),
  'SCJ15', NULL, 'excepcion_no_descartable');
SELECT pg_temp.caso('60f motivo vacío o sólo espacios -> 22023 motivo_invalido', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), E'  \t '),
  '22023', NULL, 'motivo_invalido');
SELECT pg_temp.rpc('60g excepción inexistente -> no_encontrada', 'authenticated',
  'tiempo.fn_excepcion_dia_cerrado_descartar(999999999::bigint, ''x'')', $c$ $1->>'resultado' = 'no_encontrada' $c$);
SELECT pg_temp.rpc('61 día revisado: el admin real descarta c2 (motivo de 600 caracteres con control) -> descartada', 'authenticated',
  format('tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), repeat('x', 300) || E'\n\t' || repeat('y', 300)),
  $c$ $1->>'resultado' = 'descartada' AND ($1->>'dia_id') = (SELECT v FROM _ens WHERE k = 'D2') $c$);
SELECT pg_temp.caso('61b el constraint trigger acepta el descarte hecho en esta transacción (SET CONSTRAINTS ALL IMMEDIATE)', current_user::text,
  'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('61c quedó auditado: actor = el admin real, motivo de 500 caracteres sin control, y la excepción resuelta con el sufijo',
  $$SELECT d.persona_id = (SELECT v::uuid FROM _ens WHERE k='admin_persona')
      AND char_length(d.motivo) = 500 AND d.motivo !~ '[[:cntrl:]]'
      AND d.dia_id = (SELECT v::bigint FROM _ens WHERE k='D2') AND d.creado_en = now()
      AND e.estado = 'resuelto'
      AND e.motivo_revision LIKE 'dia\_cerrado — descartada por ' || (SELECT v FROM _ens WHERE k='admin_persona') || ': %'
    FROM tiempo.excepcion_descarte d JOIN tiempo.excepcion e ON e.id = d.excepcion_id
    WHERE e.marca_id = (SELECT v::bigint FROM _ens WHERE k='c2')$$);
SELECT pg_temp.rpc('62 doble descarte -> ya_descartada (idempotente, sin segunda fila de auditoría)', 'authenticated',
  format('tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), 'otra vez'),
  $c$ $1->>'resultado' = 'ya_descartada' $c$);
SELECT pg_temp.verifica('62b sigue habiendo una sola fila de auditoría para esa excepción',
  $$SELECT count(*) = 1 FROM tiempo.excepcion_descarte WHERE excepcion_id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2'))$$);
-- M1: reapertura (excepcion_reapertura) y descarte otra vez => segunda fila de auditoría, sin UNIQUE que lo impida.
SELECT pg_temp.caso('62c reabrir la excepción descartada de c2 (resuelto -> pendiente; motivo sin cambio) -> ok', current_user::text,
  $$UPDATE tiempo.excepcion SET estado = 'pendiente' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2'))$$, 'ok');
SELECT pg_temp.rpc('62d descartar otra vez la reabierta -> descartada (el RPC no confunde "ya tuvo un descarte" con "ya está resuelta")', 'authenticated',
  format('tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), 'segundo descarte'),
  $c$ $1->>'resultado' = 'descartada' $c$);
SELECT pg_temp.caso('62e el constraint trigger acepta el segundo descarte (creado_en = now() de ESTA transacción)', current_user::text,
  'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('62f ahora hay 2 filas de auditoría para esa excepción y está resuelta',
  $$SELECT count(*) = 2 AND bool_and(e.estado = 'resuelto')
    FROM tiempo.excepcion_descarte d JOIN tiempo.excepcion e ON e.id = d.excepcion_id
    WHERE d.excepcion_id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2'))$$);
SELECT pg_temp.rpc('62g descartar una tercera vez, sin reabrir -> ya_descartada y SIGUEN siendo 2 filas', 'authenticated',
  format('tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2')), 'tercero'),
  $c$ $1->>'resultado' = 'ya_descartada' AND (SELECT count(*) FROM tiempo.excepcion_descarte WHERE excepcion_id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c2'))) = 2 $c$);
SELECT pg_temp.verifica('62h el índice sobre excepcion_id existe y NO es único (M1)',
  $$SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='tiempo' AND tablename='excepcion_descarte' AND indexdef LIKE '%(excepcion_id)%' AND indexdef NOT LIKE '%UNIQUE%')
      AND NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='tiempo' AND tablename='excepcion_descarte' AND indexdef LIKE 'CREATE UNIQUE INDEX%(excepcion_id)%')$$);
SELECT pg_temp.caso('63 el descarte NO se puede imitar escribiendo el sufijo a mano: otro UPDATE directo con ' || '''descartada por'' (c7) -> SCJ15', 'authenticated',
  $q$DO $b$ BEGIN
       UPDATE tiempo.excepcion SET estado = 'resuelto', motivo_revision = motivo_revision || ' — descartada por alguien: lo dije yo'
        WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c7'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('63b la API no puede insertar su propio descarte (authenticated) -> 42501', 'authenticated',
  format($f$INSERT INTO tiempo.excepcion_descarte (excepcion_id, dia_id, persona_id, motivo) VALUES (%L::bigint, %L::bigint, %L::uuid, 'falso')$f$,
         pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c7')), (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='admin_persona')), '42501');
SELECT pg_temp.caso('63c ni service_role (INSERT/UPDATE/DELETE sobre la auditoría) -> 42501', 'service_role',
  $$UPDATE tiempo.excepcion_descarte SET motivo = 'x'$$, '42501');
SELECT pg_temp.caso('63d la auditoría es inmutable incluso para el dueño (UPDATE) -> excepción del trigger', current_user::text,
  $$UPDATE tiempo.excepcion_descarte SET motivo = 'x'$$, 'P0001');
SELECT pg_temp.caso('63e ... (TRUNCATE)', current_user::text, $$TRUNCATE tiempo.excepcion_descarte$$, 'P0001');
SELECT pg_temp.caso('64 EXECUTE del RPC: anon -> 42501', 'anon', 'SELECT tiempo.fn_excepcion_dia_cerrado_descartar(1::bigint, ''x'')', '42501');
SELECT pg_temp.caso('64b EXECUTE del RPC: service_role -> 42501 (no tiene identidad de usuario)', 'service_role', 'SELECT tiempo.fn_excepcion_dia_cerrado_descartar(1::bigint, ''x'')', '42501');
SELECT pg_temp.caso(format('65 función interna/de trigger sin EXECUTE: %s como %s', v.fn, r.rol), r.rol, 'SELECT ' || v.llamada, '42501')
FROM (VALUES
  ('fn_marca_fecha_local',            'tiempo.fn_marca_fecha_local(1::bigint)'),
  ('fn_excepcion_protege_columnas',   'tiempo.fn_excepcion_protege_columnas()'),
  ('fn_excepcion_protege_dia_cerrado','tiempo.fn_excepcion_protege_dia_cerrado()'),
  ('fn_tramo_valida_coherencia',      'tiempo.fn_tramo_valida_coherencia()'),
  ('fn_excepcion_descarte_inmutable', 'tiempo.fn_excepcion_descarte_inmutable()'),
  ('fn_excepcion_descarte_truncate',  'tiempo.fn_excepcion_descarte_truncate()')
) AS v(fn, llamada)
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rol);

-- H. Revisión legítima del día (fn_dia_revisar sigue funcionando) -- AL FINAL, porque cambia a D1
SELECT pg_temp.caso('69 restaurar el modo diferido (un SET CONSTRAINTS ALL IMMEDIATE exitoso queda activo el resto de la transacción)', current_user::text, 'SET CONSTRAINTS ALL DEFERRED', 'ok');
SELECT pg_temp.caso('70 fn_dia_revisar sobre el día cerrado D1 (a1-a2) como el admin real -> ok', 'authenticated',
  format('SELECT tiempo.fn_dia_revisar(%L::bigint, 4)', (SELECT v FROM _ens WHERE k='D1')), 'ok');
SELECT pg_temp.caso('70b ... y el constraint trigger acepta la revisión de esta transacción (SET CONSTRAINTS ALL IMMEDIATE)', current_user::text,
  'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('70c D1 revisado con revisado_en = now(), 1 tramo (a1-a2) coherente, y las 2 excepciones resueltas',
  $$SELECT (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='D1')) = 'revisado'
      AND (SELECT revisado_en FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='D1')) = now()
      AND (SELECT count(*) FROM tiempo.tramo WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k='D1')) = 1
      AND (SELECT count(*) FROM tiempo.excepcion e JOIN _ens x ON x.v::bigint = e.marca_id WHERE x.k IN ('a1','a2') AND e.estado = 'resuelto') = 2$$);
SELECT pg_temp.caso('70d emular "otra transacción": la revisión de D1 pasa a hace 1 h y se reabre a1 -> resolverla directo ya no vale -> SCJ15', current_user::text,
  $q$DO $b$ BEGIN
       UPDATE tiempo.dia SET revisado_en = now() - interval '1 hour' WHERE id = (SELECT v::bigint FROM _ens WHERE k='D1');
       UPDATE tiempo.excepcion SET estado = 'pendiente' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'));
       UPDATE tiempo.excepcion SET estado = 'resuelto' WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='a1'));
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, 'SCJ15', NULL, 'dia_cerrado_requiere_revision');

-- I. Casos de la 2ª revisión de security (B1/B2/M1: ausencia real, service_role como cierre_dia, fecha efectiva, motivo largo, permiso heredado)
SELECT pg_temp.caso('80 fn_ausencia_resuelve_excepcion REAL: ausencia AUTORIZADA sobre el día f3 de E (excepción de día pendiente) -> ok', current_user::text,
  format($f$INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion)
            VALUES (%L::uuid, 'vacaciones', %L::date, %L::date, 'autorizada')$f$,
         (SELECT v FROM _ens WHERE k='pE'), (SELECT v FROM _ens WHERE k='f3'), (SELECT v FROM _ens WHERE k='f3')), 'ok');
SELECT pg_temp.verifica('80b ... resolvió la excepción de día con el sufijo exacto (guion largo U+2014), que el trigger de columnas no bloqueó',
  $$SELECT estado = 'resuelto' AND motivo_revision = 'paridad_impar' || E' — resuelto por ausencia autorizada, carga tardía'
    FROM tiempo.excepcion WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k='Ef3')$$);
SELECT pg_temp.caso('80c ausencia RECHAZADA (falta) sobre el día f6 de E -> ok', current_user::text,
  format($f$INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion)
            VALUES (%L::uuid, 'falta', %L::date, %L::date, 'rechazada')$f$,
         (SELECT v FROM _ens WHERE k='pE'), (SELECT v FROM _ens WHERE k='f6'), (SELECT v FROM _ens WHERE k='f6')), 'ok');
SELECT pg_temp.verifica('80d ... sufijo de rechazo aplicado y excepción resuelta',
  $$SELECT estado = 'resuelto' AND motivo_revision = 'paridad_impar' || E' — resuelto por ausencia rechazada (falta injustificada)'
    FROM tiempo.excepcion WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k='Ef6')$$);

SELECT pg_temp.caso('81 tramo como cierre_dia.py (service_role): marcas k1-k2 de E, día f4 de E, fechas efectivas = fecha del día -> ok', 'service_role',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            SELECT %L::bigint, %L::bigint, %L::bigint, ka.momento_dispositivo, kc.momento_dispositivo, 240
            FROM tiempo.marca ka, tiempo.marca kc WHERE ka.id = %L::bigint AND kc.id = %L::bigint$f$,
         (SELECT v FROM _ens WHERE k='Ef4'), (SELECT v FROM _ens WHERE k='k1'), (SELECT v FROM _ens WHERE k='k2'),
         (SELECT v FROM _ens WHERE k='k1'), (SELECT v FROM _ens WHERE k='k2')), 'ok');
SELECT pg_temp.caso('81b service_role: marca m1 (corregida de f7 a f4) + m2 en el día f4 de E -> ok (se usa la fecha EFECTIVA)', 'service_role',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, %L::timestamptz, %L::timestamptz, 60)$f$,
         (SELECT v FROM _ens WHERE k='Ef4'), (SELECT v FROM _ens WHERE k='m1'), (SELECT v FROM _ens WHERE k='m2'),
         ((SELECT v::date FROM _ens WHERE k='f4')::timestamp + interval '30 minutes') AT TIME ZONE 'UTC',
         ((SELECT v::date FROM _ens WHERE k='f4')::timestamp + interval '1 hour') AT TIME ZONE 'UTC'), 'ok');
SELECT pg_temp.caso('81c service_role: la MISMA m1+m2 en el día f7 de E (su fecha cruda) -> SCJ15 tramo_incoherente (la corrección cambió la fecha local)', 'service_role',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='Ef7'), (SELECT v FROM _ens WHERE k='m1'), (SELECT v FROM _ens WHERE k='m2')), 'SCJ15', NULL, 'tramo_incoherente');
SELECT pg_temp.caso('81d service_role: tramo con marcas de OTRA persona (e1,e2 de E en un día de D) -> SCJ15 tramo_incoherente (service_role no está exento)', 'service_role',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            VALUES (%L::bigint, %L::bigint, %L::bigint, now() - interval '2 hours', now() - interval '1 hour', 60)$f$,
         (SELECT v FROM _ens WHERE k='D2'), (SELECT v FROM _ens WHERE k='e1'), (SELECT v FROM _ens WHERE k='e2')), 'SCJ15', NULL, 'tramo_incoherente');

SELECT pg_temp.caso('81e restaurar el modo diferido', current_user::text, 'SET CONSTRAINTS ALL DEFERRED', 'ok');
SELECT pg_temp.caso('82 fn_dia_revisar sobre el día cerrado f5 de E, con una marca tardía corregida (cruda f7, efectiva f5) -> ok', 'authenticated',
  format('SELECT tiempo.fn_dia_revisar(%L::bigint, 4)', (SELECT v FROM _ens WHERE k='Ef5')), 'ok');
SELECT pg_temp.caso('82b el constraint trigger acepta esa revisión (fecha efectiva de h1 = f5)', current_user::text, 'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('82c el día quedó revisado, con un tramo que contiene h1 y h2, y sus dos excepciones resueltas',
  $$SELECT (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='Ef5')) = 'revisado'
      AND (SELECT count(*) FROM tiempo.tramo WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k='Ef5')
             AND (marca_apertura_id IN ((SELECT v::bigint FROM _ens WHERE k='h1'), (SELECT v::bigint FROM _ens WHERE k='h2'))
                  OR marca_cierre_id IN ((SELECT v::bigint FROM _ens WHERE k='h1'), (SELECT v::bigint FROM _ens WHERE k='h2')))) >= 1
      AND NOT EXISTS (SELECT 1 FROM tiempo.excepcion e JOIN _ens x ON x.v::bigint = e.marca_id WHERE x.k IN ('h1','h2') AND e.estado = 'pendiente')
      AND (SELECT count(DISTINCT e.marca_id) FROM tiempo.excepcion e JOIN _ens x ON x.v::bigint = e.marca_id WHERE x.k IN ('h1','h2') AND e.estado = 'resuelto') = 2$$);

SELECT pg_temp.rpc('83 motivo de >500 caracteres con '' — '', comillas dobles y simples (c4, día revisado) -> descartada, motivo guardado a 500', 'authenticated',
  format('tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c4')), repeat('ñ — "a" ''b'' ', 60)),
  $c$ $1->>'resultado' = 'descartada' $c$);
SELECT pg_temp.caso('83b el constraint trigger acepta el descarte con motivo largo', current_user::text, 'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.verifica('83c auditoría de 500 caracteres exactos con el guion largo y las comillas; el motivo_revision empieza con "dia_cerrado — descartada por" y termina con el motivo',
  $$SELECT char_length(d.motivo) = 500 AND position(E' — ' IN d.motivo) > 0 AND position('"' IN d.motivo) > 0 AND position('''' IN d.motivo) > 0
      AND e.estado = 'resuelto' AND e.motivo_revision LIKE 'dia\_cerrado' || E' — ' || 'descartada por %' AND right(e.motivo_revision, 500) = d.motivo
    FROM tiempo.excepcion_descarte d JOIN tiempo.excepcion e ON e.id = d.excepcion_id
    WHERE d.excepcion_id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c4'))$$);

SELECT pg_temp.caso('84 fixture: el usuario sintético (superior de RH) SÍ tiene un permiso heredado por jerarquía (excepcion_edicion)', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('excepcion_edicion') THEN 1 ELSE 0 END)$$,
  'ok', (SELECT v FROM _ens WHERE k='auth_sup'));
SELECT pg_temp.caso('84b ... y NO tiene el permiso de acción excepcion_dia_cerrado_descarte (no heredable)', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('excepcion_dia_cerrado_descarte') THEN 0 ELSE 1 END)$$,
  'ok', (SELECT v FROM _ens WHERE k='auth_sup'));
SELECT pg_temp.caso('84c descartar con ese usuario (permiso heredado pero sin el de acción) -> 42501 sin_permiso', 'authenticated',
  format('SELECT tiempo.fn_excepcion_dia_cerrado_descartar(%L::bigint, %L)', pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c7')), 'intento'),
  '42501', (SELECT v FROM _ens WHERE k='auth_sup'), 'sin_permiso');
SELECT pg_temp.verifica('84d ... y no dejó nada: c7 sigue pendiente', $$SELECT estado = 'pendiente' FROM tiempo.excepcion WHERE id = pg_temp.ex((SELECT v::bigint FROM _ens WHERE k='c7'))$$);

-- Verificación de verificar_ddl.sql (secciones 11-44; 82-85 y 78 ya están aplicados)
\ir /tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/verificar_86.sql

-- ---------- resultado ----------
SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;

ROLLBACK;
