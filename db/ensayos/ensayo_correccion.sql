-- Ensayo de solo medición: qué hace una corrección sobre marcas de tramos cerrados/abiertos. BEGIN…ROLLBACK, personas/marcas SINTÉTICAS.
-- El admin real solo es caller (claims). No cambia nada del DDL.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';
SET LOCAL idle_in_transaction_session_timeout = '300s';

CREATE TEMP TABLE _ens (k text PRIMARY KEY, v text);
CREATE TEMP TABLE _snap (n serial, etapa text, dato text);
GRANT ALL ON _ens, _snap TO PUBLIC;
GRANT USAGE ON SEQUENCE _snap_n_seq TO PUBLIC;

INSERT INTO _ens
SELECT 'auth_uid', u.auth_user_id::text
FROM personas.usuario u
JOIN personas.persona p    ON p.id = u.persona_id AND p.estado = 'activo'
JOIN personas.asignacion a ON a.persona_id = p.id AND a.vigente_hasta IS NULL
JOIN personas.puesto pu    ON pu.id = a.puesto_id AND pu.es_administrador_generico
LIMIT 1;
INSERT INTO _ens SELECT 'admin_persona', u.persona_id::text FROM personas.usuario u WHERE u.auth_user_id::text = (SELECT v FROM _ens WHERE k = 'auth_uid');

CREATE FUNCTION pg_temp.mk(p_persona uuid, p_fecha date, p_hora numeric, p_seq integer) RETURNS bigint AS $$
  INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (p_persona, 'ENSC', p_seq, (p_fecha::timestamp + p_hora * interval '1 hour') AT TIME ZONE 'UTC', '+00:00', 'sincronizado', 'ens', 'terminal')
  RETURNING id;
$$ LANGUAGE sql;

-- Corrige como p_rol (claims del admin) y devuelve el resultado en texto.
CREATE FUNCTION pg_temp.corrige(p_rol text, p_marca bigint, p_mas_min int) RETURNS text AS $$
DECLARE v_res text := 'ok'; v_nuevo timestamptz;
BEGIN
  SELECT momento_dispositivo + p_mas_min * interval '1 minute' INTO v_nuevo FROM tiempo.marca WHERE id = p_marca;
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', (SELECT x.v FROM _ens x WHERE x.k='auth_uid'), 'role', p_rol)::text, true);
  BEGIN
    INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id)
    VALUES (p_marca, v_nuevo, 'ensayo correccion', (SELECT x.v::uuid FROM _ens x WHERE x.k='admin_persona'));
  EXCEPTION WHEN OTHERS THEN
    v_res := 'ERROR ' || SQLSTATE || ' ' || left(SQLERRM, 140);
  END;
  RESET ROLE;
  RETURN v_res;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.foto(p_etapa text, p_dia bigint) RETURNS void AS $$
  INSERT INTO _snap (etapa, dato)
  SELECT p_etapa, 'dia ' || d.estado || ' horas=' || COALESCE(d.horas_totales::text, 'NULL') || ' | tramos: ' ||
         COALESCE((SELECT string_agg(to_char(t.inicio AT TIME ZONE 'UTC','HH24:MI') || '-' || COALESCE(to_char(t.fin AT TIME ZONE 'UTC','HH24:MI'), 'abierto') || ' min=' || COALESCE(t.minutos_trabajados::text, 'NULL'), ' ; ' ORDER BY t.inicio)
                    FROM tiempo.tramo t WHERE t.dia_id = d.id), '(ninguno)')
  FROM tiempo.dia d WHERE d.id = p_dia;
$$ LANGUAGE sql;

INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXG2', 'XEXX010101G2', '99999999997', 'SinteticaG', 'EnsayoCorr', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'pG', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXG2';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'pG' ON CONFLICT DO NOTHING;

-- Un escenario por día (fechas ascendentes: la corrección de +30 min nunca cruza con las marcas del día siguiente).
-- c1: día cerrado, tramo cerrado (a,b) 240 min, horas 3.00 (240 min menos 60 de descuento de pausa como cierre_dia).
-- c2: día revisado, tramo cerrado, horas manuales de RH 7.00.
-- c3: día cerrado, tramo ABIERTO (una sola marca).
-- c4: día bloqueado, marca sin tramo.
-- c5: igual que c2 (revisado, horas manuales 7.00), para correr como dueño.
-- c6: igual que c1 (cerrado, 3.00), para correr como dueño.
DO $do$
DECLARE
  g uuid := (SELECT v::uuid FROM _ens WHERE k='pG'); i int; v_a bigint; v_b bigint; v_dia bigint; v_estado text; v_horas numeric; v_abierto boolean;
BEGIN
  FOR i IN 1..6 LOOP
    v_abierto := (i = 3);
    v_a := pg_temp.mk(g, CURRENT_DATE - 30 + i * 2, 10, 100 + i * 2);
    IF NOT v_abierto AND i <> 4 THEN v_b := pg_temp.mk(g, CURRENT_DATE - 30 + i * 2, 14, 101 + i * 2); ELSE v_b := NULL; END IF;
    v_estado := CASE i WHEN 1 THEN 'cerrado' WHEN 2 THEN 'revisado' WHEN 3 THEN 'cerrado' WHEN 4 THEN 'bloqueado' WHEN 5 THEN 'revisado' ELSE 'cerrado' END;
    v_horas := CASE i WHEN 1 THEN 3.00 WHEN 2 THEN 7.00 WHEN 3 THEN NULL WHEN 4 THEN NULL WHEN 5 THEN 7.00 ELSE 3.00 END;
    IF v_estado = 'revisado' THEN
      INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, revisado_por, revisado_en)
      VALUES (g, CURRENT_DATE - 30 + i * 2, v_estado, v_horas, g, now() - interval '1 day') RETURNING id INTO v_dia;
    ELSE
      INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES (g, CURRENT_DATE - 30 + i * 2, v_estado, v_horas) RETURNING id INTO v_dia;
    END IF;
    IF i <> 4 THEN
      INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
      SELECT v_dia, v_a, v_b, ma.momento_dispositivo, mb.momento_dispositivo, CASE WHEN v_b IS NULL THEN NULL ELSE 240 END
      FROM tiempo.marca ma LEFT JOIN tiempo.marca mb ON mb.id = v_b WHERE ma.id = v_a;
    END IF;
    -- excepción pendiente (no dia_cerrado) en la marca que se va a corregir: la de cierre, o la única marca
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (COALESCE(v_b, v_a), 'reloj_no_sincronizado');
    INSERT INTO _ens VALUES ('dia' || i, v_dia::text), ('marca' || i, COALESCE(v_b, v_a)::text);
  END LOOP;
END
$do$;

-- ---- medición ----
SELECT pg_temp.foto('c1 ANTES  (día cerrado, tramo cerrado)', (SELECT v::bigint FROM _ens WHERE k='dia1'));
INSERT INTO _snap (etapa, dato) SELECT 'c1 resultado como authenticated (admin real, +30 min a la marca de cierre)', pg_temp.corrige('authenticated', (SELECT v::bigint FROM _ens WHERE k='marca1'), 30);
SELECT pg_temp.foto('c1 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia1'));
INSERT INTO _snap (etapa, dato) SELECT 'c1 correcciones guardadas', count(*)::text FROM tiempo.correccion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='marca1');

SELECT pg_temp.foto('c2 ANTES  (día revisado, horas manuales RH)', (SELECT v::bigint FROM _ens WHERE k='dia2'));
INSERT INTO _snap (etapa, dato) SELECT 'c2 resultado como authenticated', pg_temp.corrige('authenticated', (SELECT v::bigint FROM _ens WHERE k='marca2'), 30);
SELECT pg_temp.foto('c2 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia2'));
INSERT INTO _snap (etapa, dato) SELECT 'c2 correcciones guardadas', count(*)::text FROM tiempo.correccion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='marca2');

SELECT pg_temp.foto('c3 ANTES  (tramo ABIERTO)', (SELECT v::bigint FROM _ens WHERE k='dia3'));
INSERT INTO _snap (etapa, dato) SELECT 'c3 resultado como authenticated', pg_temp.corrige('authenticated', (SELECT v::bigint FROM _ens WHERE k='marca3'), 10);
SELECT pg_temp.foto('c3 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia3'));
INSERT INTO _snap (etapa, dato) SELECT 'c3 correcciones guardadas', count(*)::text FROM tiempo.correccion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='marca3');

SELECT pg_temp.foto('c4 ANTES  (marca sin tramo, día bloqueado)', (SELECT v::bigint FROM _ens WHERE k='dia4'));
INSERT INTO _snap (etapa, dato) SELECT 'c4 resultado como authenticated', pg_temp.corrige('authenticated', (SELECT v::bigint FROM _ens WHERE k='marca4'), 10);
SELECT pg_temp.foto('c4 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia4'));
INSERT INTO _snap (etapa, dato) SELECT 'c4 correcciones guardadas', count(*)::text FROM tiempo.correccion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='marca4');

SELECT pg_temp.foto('c5 ANTES  (revisado, horas manuales; se corrige como DUEÑO)', (SELECT v::bigint FROM _ens WHERE k='dia5'));
INSERT INTO _snap (etapa, dato) SELECT 'c5 resultado como dueño (' || current_user || ')', pg_temp.corrige(current_user::text, (SELECT v::bigint FROM _ens WHERE k='marca5'), 30);
SELECT pg_temp.foto('c5 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia5'));

SELECT pg_temp.foto('c6 ANTES  (cerrado con descuento de pausa; se corrige como DUEÑO)', (SELECT v::bigint FROM _ens WHERE k='dia6'));
INSERT INTO _snap (etapa, dato) SELECT 'c6 resultado como dueño', pg_temp.corrige(current_user::text, (SELECT v::bigint FROM _ens WHERE k='marca6'), 30);
SELECT pg_temp.foto('c6 DESPUES', (SELECT v::bigint FROM _ens WHERE k='dia6'));

SELECT n, etapa, dato FROM _snap ORDER BY n;
ROLLBACK;
