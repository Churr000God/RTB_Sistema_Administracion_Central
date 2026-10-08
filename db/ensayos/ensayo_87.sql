-- Ensayo de 87_tiempo_correccion_bloquea_marca_en_tramo.sql. NO CORRIDO hasta tener OK del usuario y revisión de security.
--   psql "$DATABASE_URL(5432)" -X -v ON_ERROR_STOP=1 -f <este archivo>    (SIN -1; puerto 5432)
-- BEGIN … ROLLBACK, personas/marcas/días SINTÉTICOS; el admin real solo es caller (claims). Aplica 87_ ENCIMA de 86_ ya aplicado.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '180s';
SET LOCAL idle_in_transaction_session_timeout = '300s';
\ir /home/diego/Proyectos/RTB-CRM-APP/db/ddl/87_tiempo_correccion_bloquea_marca_en_tramo.sql

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

-- p_sub: NULL = el admin real; '-' = claims SIN sub (como service_role real); otro = ese auth uid.
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
  INSERT INTO _res (caso, ok, detalle) VALUES (
    p_caso,
    (CASE WHEN p_esperado = 'error' THEN v_estado <> 'ok'
          WHEN left(p_esperado, 1) = '!' THEN v_estado <> 'ok' AND v_estado <> substr(p_esperado, 2)
          ELSE v_estado = p_esperado END)
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

CREATE FUNCTION pg_temp.mk(p_persona uuid, p_fecha date, p_hora numeric, p_seq integer) RETURNS bigint AS $$
  INSERT INTO tiempo.marca (persona_id, terminal_id, secuencia_local, momento_dispositivo, desfase_local, estado_reloj, version_software, origen)
  VALUES (p_persona, 'ENS87', p_seq, (p_fecha::timestamp + p_hora * interval '1 hour') AT TIME ZONE 'UTC', '+00:00', 'sincronizado', 'ens', 'terminal')
  RETURNING id;
$$ LANGUAGE sql;

-- SQL de una corrección de +p_min minutos sobre la marca (clave de _ens), como texto listo para pasar a caso().
CREATE FUNCTION pg_temp.corr(p_k text, p_min int) RETURNS text AS $$
  SELECT format($f$INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (%L::bigint, %L::timestamptz, 'ensayo87', %L::uuid)$f$,
                x.v, (SELECT m.momento_dispositivo + p_min * interval '1 minute' FROM tiempo.marca m WHERE m.id = x.v::bigint),
                (SELECT v FROM _ens WHERE k='admin_persona'))
  FROM _ens x WHERE x.k = p_k;
$$ LANGUAGE sql;

INSERT INTO _ens SELECT 'n_corr_previas', count(*)::text FROM tiempo.correccion;

INSERT INTO personas.persona (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES ('XEXX010101HNEXXXH2', 'XEXX010101H2', '99999999998', 'SinteticaH', 'Ensayo87', '2000-01-01', CURRENT_DATE);
INSERT INTO _ens SELECT 'pH', id::text FROM personas.persona WHERE curp = 'XEXX010101HNEXXXH2';
INSERT INTO tiempo.persona (id) SELECT v::uuid FROM _ens WHERE k = 'pH' ON CONFLICT DO NOTHING;

-- Un escenario por día (fechas ascendentes: una corrección de +30 min nunca cruza con las marcas del día siguiente).
--  1 cerrado + tramo cerrado | 2 revisado (horas manuales 7.00) + tramo cerrado | 3 cerrado + tramo ABIERTO (una marca)
--  4 bloqueado, marca sin tramo | 5 bloqueado, 2 marcas huérfanas (corregir, luego revisar, luego corregir otra vez)
--  6 cerrado + tramo cerrado + excepción dia_cerrado manual pendiente en la marca de cierre | 7 cerrado, marcas SIN tramo, dia_cerrado pendiente
--  8 cerrado + tramo cerrado (para dueño/service_role) | 9 bloqueado con excepción de DÍA (para ausencia real)
DO $do$
DECLARE
  h uuid := (SELECT v::uuid FROM _ens WHERE k='pH'); i int; v_a bigint; v_b bigint; v_dia bigint; v_estado text; v_horas numeric; v_f date;
BEGIN
  FOR i IN 1..9 LOOP
    v_f := CURRENT_DATE - 40 + i * 2;
    IF i = 9 THEN
      INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES (h, v_f, 'bloqueado', 0) RETURNING id INTO v_dia;
      INSERT INTO tiempo.excepcion (dia_id, motivo_revision) VALUES (v_dia, 'paridad_impar');
      INSERT INTO _ens VALUES ('dia9', v_dia::text), ('fecha9', v_f::text);
      CONTINUE;
    END IF;
    v_a := pg_temp.mk(h, v_f, 10, 200 + i * 2);
    IF i NOT IN (3, 4) THEN v_b := pg_temp.mk(h, v_f, 14, 201 + i * 2); ELSE v_b := NULL; END IF;
    v_estado := CASE i WHEN 1 THEN 'cerrado' WHEN 2 THEN 'revisado' WHEN 3 THEN 'cerrado' WHEN 4 THEN 'bloqueado' WHEN 5 THEN 'bloqueado' ELSE 'cerrado' END;
    v_horas  := CASE i WHEN 1 THEN 3.00 WHEN 2 THEN 7.00 WHEN 8 THEN 3.00 WHEN 6 THEN 3.00 ELSE NULL END;
    IF v_estado = 'revisado' THEN
      INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, revisado_por, revisado_en)
      VALUES (h, v_f, v_estado, v_horas, h, now() - interval '1 day') RETURNING id INTO v_dia;
    ELSE
      INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales) VALUES (h, v_f, v_estado, v_horas) RETURNING id INTO v_dia;
    END IF;
    IF i IN (1, 2, 3, 6, 8) THEN
      INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
      SELECT v_dia, v_a, v_b, ma.momento_dispositivo, mb.momento_dispositivo, CASE WHEN v_b IS NULL THEN NULL ELSE 240 END
      FROM tiempo.marca ma LEFT JOIN tiempo.marca mb ON mb.id = v_b WHERE ma.id = v_a;
    END IF;
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision)
    VALUES (COALESCE(v_b, v_a), CASE WHEN i IN (6, 7) THEN 'dia_cerrado' ELSE 'reloj_no_sincronizado' END);
    INSERT INTO _ens VALUES ('dia' || i, v_dia::text), ('a' || i, v_a::text), ('m' || i, COALESCE(v_b, v_a)::text), ('fecha' || i, v_f::text);
  END LOOP;
END
$do$;

-- Marca LIBRE (sin tramo) con excepción pendiente, para el INSERT de varias filas.
INSERT INTO _ens VALUES ('libre', pg_temp.mk((SELECT v::uuid FROM _ens WHERE k='pH'), (SELECT v::date FROM _ens WHERE k='fecha4'), 12, 300)::text);
INSERT INTO tiempo.excepcion (marca_id, motivo_revision) SELECT v::bigint, 'reloj_no_sincronizado' FROM _ens WHERE k='libre';

-- Usuario SINTÉTICO sin correccion_edicion (puesto subordinado del Gerente General, sin permisos propios).
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT departamento_id, 'ENS87 sin permisos', 'operativo', id FROM personas.puesto WHERE nombre_puesto = 'Gerente General';
INSERT INTO _ens VALUES ('auth_sin', gen_random_uuid()::text);
INSERT INTO auth.users (id, aud, role, email) SELECT v::uuid, 'authenticated', 'authenticated', 'ensayo87@invalid.test' FROM _ens WHERE k = 'auth_sin';
INSERT INTO personas.usuario (auth_user_id, persona_id, nombre_usuario)
SELECT (SELECT v::uuid FROM _ens WHERE k='auth_sin'), (SELECT v::uuid FROM _ens WHERE k='pH'), 'ensayo87';
INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT (SELECT v::uuid FROM _ens WHERE k='pH'), id, CURRENT_DATE FROM personas.puesto WHERE nombre_puesto = 'ENS87 sin permisos';

-- Copia del bloque §45 de db/verificar_ddl.sql como función (cuenta sus filas); se regenera si cambia el verificador.
CREATE FUNCTION pg_temp.v45() RETURNS bigint AS $v45$ SELECT count(*) FROM (
SELECT 'falta o mal el trigger' AS problema, NULL::text AS detalle
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'tiempo.correccion'::regclass AND t.tgname = 'trg_correccion_bloquea_marca_en_tramo'
                    AND NOT t.tgisinternal AND t.tgenabled = 'O' AND t.tgtype = 7)
UNION ALL
SELECT 'hay otro trigger BEFORE INSERT por fila que corre antes que el de 87_', t.tgname::text
FROM pg_trigger t
WHERE t.tgrelid = 'tiempo.correccion'::regclass AND NOT t.tgisinternal
  AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 AND (t.tgtype & 4) <> 0
  AND t.tgname::text COLLATE "C" < 'trg_correccion_bloquea_marca_en_tramo' COLLATE "C"
UNION ALL
SELECT 'trg_correccion_valida falta, no es BEFORE INSERT por fila, o corre antes que el de 87_', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'tiempo.correccion'::regclass AND t.tgname = 'trg_correccion_valida' AND NOT t.tgisinternal
                    AND (t.tgtype & 1) <> 0 AND (t.tgtype & 2) <> 0 AND (t.tgtype & 4) <> 0
                    AND t.tgname::text COLLATE "C" > 'trg_correccion_bloquea_marca_en_tramo' COLLATE "C")
UNION ALL
SELECT 'falta la función', NULL
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo')
UNION ALL
SELECT 'función distinta de la esperada', 'secdef=' || p.prosecdef || ' config=' || COALESCE(p.proconfig::text, 'NULL')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND (NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=tiempo, personas, pg_temp'])
UNION ALL
SELECT 'EXECUTE a PUBLIC', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND EXISTS (SELECT 1 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
              WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
UNION ALL
SELECT 'EXECUTE inesperado para ' || r.rol, NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('terminal_checador')) AS r(rol)
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND has_function_privilege(r.rol, p.oid, 'EXECUTE')
UNION ALL
SELECT 'dueño distinto del de tiempo.marca', NULL
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
  AND p.proowner <> (SELECT relowner FROM pg_class WHERE oid = 'tiempo.marca'::regclass)
UNION ALL
SELECT 'el cuerpo no contiene: ' || c.fragmento, NULL
FROM (VALUES ('marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id'), ('SCJ15'), ('marca_en_tramo'),
             ('auth.role() = ''anon'''), ('correccion_edicion'), ('auth.uid() IS NOT NULL'), ('fn_caller_activo'),
             ('RETURN NEW')) AS c(fragmento)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'tiempo' AND p.proname = 'fn_correccion_bloquea_marca_en_tramo'
                    AND strpos(p.prosrc, c.fragmento) > 0)
) q $v45$ LANGUAGE sql;

-- ---------- casos ----------
SELECT pg_temp.verifica('00 fixture: existe el caller admin', $$SELECT EXISTS (SELECT 1 FROM _ens WHERE k='auth_uid') AND EXISTS (SELECT 1 FROM _ens WHERE k='admin_persona')$$);
SELECT pg_temp.caso('00c fixture: el sintético no tiene correccion_edicion', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('correccion_edicion') THEN 0 ELSE 1 END)$$, 'ok', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('00d fixture: el admin sí tiene correccion_edicion', 'authenticated',
  $$SELECT 1 / (CASE WHEN personas.fn_caller_tiene_permiso('correccion_edicion') THEN 1 ELSE 0 END)$$, 'ok');

-- A. Marca en tramo -> SCJ15 / marca_en_tramo
SELECT pg_temp.caso('10 marca de un tramo CERRADO de un día cerrado, como el admin real -> SCJ15 marca_en_tramo', 'authenticated', pg_temp.corr('m1', 30), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('10b ... también por la marca de APERTURA del tramo -> SCJ15 marca_en_tramo', 'authenticated', pg_temp.corr('a1', 5), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('11 marca de un tramo cerrado de un día REVISADO (horas manuales) -> SCJ15 marca_en_tramo', 'authenticated', pg_temp.corr('m2', 30), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('12 marca de un tramo ABIERTO -> SCJ15 marca_en_tramo (antes: 42501 de RLS)', 'authenticated', pg_temp.corr('m3', 10), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.verifica('12b nada cambió: ninguna corrección nueva sobre esas marcas y las horas siguen igual',
  $$SELECT NOT EXISTS (SELECT 1 FROM tiempo.correccion c JOIN _ens x ON x.v::bigint = c.marca_id WHERE x.k IN ('m1','a1','m2','m3'))
      AND (SELECT horas_totales FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='dia1')) = 3.00
      AND (SELECT horas_totales FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='dia2')) = 7.00$$);

-- B. Dueño y service_role también (no hay RLS que los frene; ahí SÍ pisaban las horas)
SELECT pg_temp.caso('13 como DUEÑO, marca en tramo cerrado de día cerrado -> SCJ15 marca_en_tramo', current_user::text, pg_temp.corr('m8', 30), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('13b como DUEÑO, marca en tramo de día revisado -> SCJ15 marca_en_tramo', current_user::text, pg_temp.corr('m2', 30), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('13c como service_role (claims sin sub), marca en tramo -> SCJ15 marca_en_tramo', 'service_role', pg_temp.corr('m8', 30), 'SCJ15', '-', 'marca_en_tramo');
SELECT pg_temp.verifica('13d las horas manuales de RH y las de cierre_dia siguen intactas',
  $$SELECT (SELECT horas_totales FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='dia2')) = 7.00
      AND (SELECT horas_totales FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='dia8')) = 3.00$$);

-- C. Quien no puede corregir NO recibe SCJ15 (el trigger de 87_ lo deja pasar) y recibe el MISMO error esté o no la marca en un tramo.
-- Ojo: trg_correccion_valida (INVOKER) corre antes que la RLS y, sin permiso de lectura sobre excepcion, no ve la excepción y levanta
-- P0001; por eso para un usuario sin permiso el error observable es ese (o 42501 si ni siquiera tiene SELECT), idéntico en los tres casos.
SELECT pg_temp.caso('14 usuario sin correccion_edicion, marca en tramo -> 42501 (RLS), NO SCJ15', 'authenticated', pg_temp.corr('m1', 30), '!SCJ15', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('14b usuario sin correccion_edicion, marca SIN tramo -> el mismo 42501 (sin diferencia observable)', 'authenticated', pg_temp.corr('m4', 10), '!SCJ15', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('14c rol anon, marca en tramo -> 42501 (no SCJ15)', 'anon', pg_temp.corr('m1', 30), '!SCJ15', '-');
SELECT pg_temp.caso('14d rol anon, marca SIN tramo -> el mismo 42501', 'anon', pg_temp.corr('m4', 10), '!SCJ15', '-');
SELECT pg_temp.verifica('14f sin permiso: el MISMO SQLSTATE con marca en tramo, marca libre e inexistente (sin sondeo)', $$SELECT count(DISTINCT substring(detalle from 'obtenido=([^ ]+)')) = 1 FROM _res WHERE caso LIKE '14 %' OR caso LIKE '14b %' OR caso LIKE '60 %'$$);
SELECT pg_temp.caso('14e INSERT directo como authenticated con permiso (sin pasar por FastAPI) sobre marca en tramo -> SCJ15 gana a la RLS', 'authenticated', pg_temp.corr('m1', 30), 'SCJ15', NULL, 'marca_en_tramo');

-- D. Marca sin tramo: sigue funcionando; después de armar el tramo, la siguiente corrección se bloquea
SELECT pg_temp.caso('20 marca SIN tramo (día bloqueado) -> ok', 'authenticated', pg_temp.corr('m4', 10), 'ok');
SELECT pg_temp.verifica('20b la excepción de esa marca quedó resuelta por fn_correccion_recalcula_tramo (flujo intacto)',
  $$SELECT estado = 'resuelto' FROM tiempo.excepcion WHERE marca_id = (SELECT v::bigint FROM _ens WHERE k='m4')$$);
SELECT pg_temp.caso('21 día 5, marca huérfana m5 SIN tramo: corrección previa +10 min -> ok', 'authenticated', pg_temp.corr('m5', 10), 'ok');
SELECT pg_temp.caso('21b fn_dia_revisar arma el tramo con el valor EFECTIVO (a5 10:00 - m5 14:10) -> ok', 'authenticated',
  format('SELECT tiempo.fn_dia_revisar(%L::bigint, 4)', (SELECT v FROM _ens WHERE k='dia5')), 'ok');
SELECT pg_temp.verifica('21c el tramo armado termina a las 14:10 (hora corregida) y el día quedó revisado',
  $$SELECT (SELECT estado FROM tiempo.dia WHERE id = (SELECT v::bigint FROM _ens WHERE k='dia5')) = 'revisado'
      AND EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.dia_id = (SELECT v::bigint FROM _ens WHERE k='dia5')
                    AND to_char(t.fin AT TIME ZONE 'UTC', 'HH24:MI') = '14:10')$$);
SELECT pg_temp.caso('21d ahora que la marca ESTÁ en un tramo, la siguiente corrección -> SCJ15 marca_en_tramo', 'authenticated', pg_temp.corr('m5', 5), 'SCJ15', NULL, 'marca_en_tramo');

-- E. Relación con el constraint trigger dia_cerrado de 86_ (un solo error por intento)
SELECT pg_temp.caso('30 marca en tramo CON excepción dia_cerrado pendiente: SCJ15 marca_en_tramo al instante', 'authenticated', pg_temp.corr('m6', 30), 'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.caso('30b ... y no quedó ningún evento diferido en cola (SET CONSTRAINTS ALL IMMEDIATE no falla)', current_user::text, 'SET CONSTRAINTS ALL IMMEDIATE', 'ok');
SELECT pg_temp.caso('30c restaurar el modo diferido', current_user::text, 'SET CONSTRAINTS ALL DEFERRED', 'ok');
SELECT pg_temp.caso('31 marca con dia_cerrado pendiente que NO está en ningún tramo: sigue valiendo 86_ -> SCJ15 dia_cerrado_requiere_revision al forzar', 'authenticated',
  replace($q$DO $b$ BEGIN
       @@
       SET CONSTRAINTS ALL IMMEDIATE;
     END $b$$q$, '@@', pg_temp.corr('m7', 10) || ';'), 'SCJ15', NULL, 'dia_cerrado_requiere_revision');
SELECT pg_temp.caso('31b restaurar el modo diferido', current_user::text, 'SET CONSTRAINTS ALL DEFERRED', 'ok');

-- F. Flujos legítimos intactos
SELECT pg_temp.caso('40 ausencia REAL autorizada sobre el día 9 (excepción de día) -> ok', current_user::text,
  format($f$INSERT INTO tiempo.ausencia (persona_id, tipo_de_ausencia, fecha_inicio, fecha_fin, estado_autorizacion)
            VALUES (%L::uuid, 'vacaciones', %L::date, %L::date, 'autorizada')$f$,
         (SELECT v FROM _ens WHERE k='pH'), (SELECT v FROM _ens WHERE k='fecha9'), (SELECT v FROM _ens WHERE k='fecha9')), 'ok');
SELECT pg_temp.verifica('40b ... resolvió la excepción de día con su sufijo',
  $$SELECT estado = 'resuelto' AND motivo_revision LIKE 'paridad\_impar %' FROM tiempo.excepcion WHERE dia_id = (SELECT v::bigint FROM _ens WHERE k='dia9')$$);
SELECT pg_temp.caso('41 tramo insertado como service_role (como cierre_dia.py) sobre un día nuevo: no lo afecta este trigger -> ok', 'service_role',
  format($f$INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
            SELECT %L::bigint, %L::bigint, %L::bigint, ma.momento_dispositivo, mb.momento_dispositivo, 240
            FROM tiempo.marca ma, tiempo.marca mb WHERE ma.id = %L::bigint AND mb.id = %L::bigint$f$,
         (SELECT v FROM _ens WHERE k='dia7'), (SELECT v FROM _ens WHERE k='a7'), (SELECT v FROM _ens WHERE k='m7'),
         (SELECT v FROM _ens WHERE k='a7'), (SELECT v FROM _ens WHERE k='m7')), 'ok', '-');
SELECT pg_temp.verifica('42 las correcciones existentes antes del ensayo siguen ahí, sin cambios',
  $$SELECT (SELECT count(*) FROM tiempo.correccion c WHERE c.motivo <> 'ensayo87') = (SELECT v::bigint FROM _ens WHERE k='n_corr_previas')$$);

-- G. Privilegios y orden
SELECT pg_temp.caso('50 la función de trigger no es ejecutable por anon', 'anon', 'SELECT tiempo.fn_correccion_bloquea_marca_en_tramo()', '42501', '-');
SELECT pg_temp.caso('50b ... ni por authenticated', 'authenticated', 'SELECT tiempo.fn_correccion_bloquea_marca_en_tramo()', '42501');
SELECT pg_temp.caso('50c ... ni por service_role', 'service_role', 'SELECT tiempo.fn_correccion_bloquea_marca_en_tramo()', '42501', '-');
SELECT pg_temp.verifica('51 el trigger corre antes que trg_correccion_valida',
  $$SELECT (SELECT array_agg(tgname::text ORDER BY tgname COLLATE "C") FROM pg_trigger WHERE tgrelid = 'tiempo.correccion'::regclass AND NOT tgisinternal AND (tgtype & 2) = 2)
           = ARRAY['trg_correccion_bloquea_marca_en_tramo', 'trg_correccion_valida']$$);

-- H. Ajustes de la revisión de security
SELECT pg_temp.caso('60 SIN permiso sobre una marca INEXISTENTE -> el mismo error que sobre una marca en tramo, NO SCJ15 (sin sondeo por existencia)', 'authenticated',
  format($f$INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (999999999, now(), 'x', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='admin_persona')),
  '!SCJ15', (SELECT v FROM _ens WHERE k='auth_sin'));
SELECT pg_temp.caso('60b CON permiso sobre una marca INEXISTENTE -> error de validación/FK, NO SCJ15', 'authenticated',
  format($f$INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES (999999999, now(), 'x', %L::uuid)$f$, (SELECT v FROM _ens WHERE k='admin_persona')),
  'P0001');
SELECT pg_temp.caso('61 claims role=authenticated SIN sub (no es una persona), marca en tramo -> SCJ15 (auth.uid() nulo = se trata como service_role/dueño)', 'authenticated',
  pg_temp.corr('m1', 30), 'SCJ15', '-', 'marca_en_tramo');
SELECT pg_temp.caso('62 INSERT de VARIAS filas en una sola sentencia (una libre y una en tramo) -> falla todo', 'authenticated',
  format($f$INSERT INTO tiempo.correccion (marca_id, valor_corregido, motivo, autor_id) VALUES
            (%L::bigint, %L::timestamptz, 'multi', %L::uuid), (%L::bigint, %L::timestamptz, 'multi', %L::uuid)$f$,
         (SELECT v FROM _ens WHERE k='libre'), (SELECT momento_dispositivo + interval '5 minutes' FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k='libre')), (SELECT v FROM _ens WHERE k='admin_persona'),
         (SELECT v FROM _ens WHERE k='m1'),    (SELECT momento_dispositivo + interval '5 minutes' FROM tiempo.marca WHERE id = (SELECT v::bigint FROM _ens WHERE k='m1')),    (SELECT v FROM _ens WHERE k='admin_persona')),
  'SCJ15', NULL, 'marca_en_tramo');
SELECT pg_temp.verifica('62b ... y ninguna de las dos filas quedó (ni la libre)',
  $$SELECT NOT EXISTS (SELECT 1 FROM tiempo.correccion WHERE motivo = 'multi')$$);
SELECT pg_temp.caso('63 rol terminal_checador (sólo INSERT en marca) -> 42501 antes de llegar al trigger', 'terminal_checador', pg_temp.corr('m1', 30), '!SCJ15', '-');
SELECT pg_temp.verifica('64 el verificador §45 da 0 filas con todo en orden', $$SELECT pg_temp.v45() = 0$$);
CREATE TRIGGER trg_correccion_aaa_ensayo BEFORE INSERT ON tiempo.correccion FOR EACH ROW EXECUTE FUNCTION tiempo.fn_correccion_valida();
SELECT pg_temp.verifica('64b con OTRO BEFORE INSERT que ordena antes (trg_correccion_aaa_ensayo), el verificador lo detecta', $$SELECT pg_temp.v45() >= 1$$);
DROP TRIGGER trg_correccion_aaa_ensayo ON tiempo.correccion;
ALTER TRIGGER trg_correccion_bloquea_marca_en_tramo ON tiempo.correccion RENAME TO trg_correccion_zzz_ensayo;
SELECT pg_temp.verifica('64c con el trigger renombrado (ya no existe con su nombre, y valida pasa a ordenar antes), el verificador lo detecta', $$SELECT pg_temp.v45() >= 1$$);
ALTER TRIGGER trg_correccion_zzz_ensayo ON tiempo.correccion RENAME TO trg_correccion_bloquea_marca_en_tramo;
SELECT pg_temp.verifica('64d restaurado, vuelve a 0 filas', $$SELECT pg_temp.v45() = 0$$);

\ir /tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/verificar_87.sql

SELECT n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado, caso, detalle FROM _res ORDER BY n;
SELECT count(*) FILTER (WHERE NOT ok) AS fallas, count(*) AS total FROM _res;
ROLLBACK;
