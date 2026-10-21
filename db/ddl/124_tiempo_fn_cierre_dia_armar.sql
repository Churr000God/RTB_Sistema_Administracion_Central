-- 124_tiempo_fn_cierre_dia_armar.sql
-- RPC transaccional del cierre de día: crea el día, TODOS sus tramos y, si hace falta, la excepción de paridad, en UNA transacción (SCJ-PRO-12).
--
-- PROBLEMA. backend/app/batches/cierre_dia.py (_armar_dia_par / _armar_dia_impar / _crear_tramo) inserta el día y DESPUÉS cada tramo (y la excepción de paridad) con llamadas sueltas de PostgREST. Si un tramo falla a medias —por ejemplo
-- porque 123_ rechaza un tramo incoherente (SCJ15), por una carrera o por un fallo de red— el día YA existe sin (todos) sus tramos, y `_dia_ya_resuelto` lo salta para siempre en las corridas siguientes: horas, tramos y corte quedan mal
-- sin que nadie lo vea. Mismo patrón que fn_jornada_asignar_renovar, fn_ausencia_resolver y fn_corte_quincenal_aplicar_persona (CLAUDE.md: «un endpoint/batch que escribe en más de una tabla relacionada necesita un RPC transaccional»).
--
-- FIRMA (backend debe llamar con argumentos NOMBRADOS; devuelve el id del día creado):
--   tiempo.fn_cierre_dia_armar(
--     p_persona_id uuid, p_fecha date, p_estado varchar,            -- 'cerrado' (paridad par) o 'bloqueado' (impar)
--     p_horas_totales numeric,                                      -- cerrado: obligatorio (ya con el descuento de pausa que calcula el batch); bloqueado: NULL
--     p_tramos jsonb,                                               -- arreglo ORDENADO de {marca_apertura_id, marca_cierre_id|null, inicio, fin|null, minutos_trabajados|null}
--     p_motivo_excepcion_dia text DEFAULT NULL)                     -- bloqueado: obligatorio (hoy 'paridad_impar'); cerrado: NULL
--   RETURNS bigint
-- QUÉ HACE, en una sola transacción: valida el payload; INSERT del día (estado, horas_totales); INSERT de cada tramo en el orden recibido; y, para un día bloqueado, INSERT de la excepción de día (marca_id NULL, dia_id, motivo).
--   Cualquier fallo (de esta función o de un trigger sobre dia, tramo o excepcion: 86_ trg_tramo_valida_coherencia, 123_ trg_tramo_valida_tiempos, FK, UNIQUE) revierte TODO: no queda un día sin tramos.
-- ERRORES propios: ERRCODE SCJ27 con HINT estable (siempre un literal fijo, nunca dinámico) y mensaje fijo: 'dia_ya_existe' (ya hay día de esa persona y fecha; backend lo trata como «ya resuelto»), 'estado_invalido' (no es cerrado ni bloqueado),
--   'horas_fuera_de_rango' (p_horas_totales fuera de 0 a 24, el mismo rango que fn_dia_revisar), 'tramos_inconsistentes' (cerrado con un tramo abierto o sin horas; bloqueado sin exactamente UN tramo abierto y ese el último, con horas o sin motivo de excepción; payload vacío o mal formado). Los de los triggers salen tal cual (SCJ15 con sus HINT, 23503, 23505).
--
-- LO QUE NO HACE: no calcula nada (ni horas, ni descuento de pausa, ni minutos): el batch sigue decidiendo y esta función solo escribe, como las demás RPC. NO duplica la validación de tiempos: la hacen los triggers (123_ cuando está aplicada).
--   No toca marcas, correcciones, ausencias ni el día abierto: el batch decide antes si hay día que armar (`_dia_ya_resuelto`, festivos, ausencias sin marcas).
--
-- SEGURIDAD. SECURITY DEFINER con search_path = tiempo, pg_temp (la mandó el diseño; el batch ya es service_role y tiene INSERT en las tablas, pero así el cierre no depende de grants de tabla), REVOKE EXECUTE de PUBLIC, anon,
--   authenticated y service_role y GRANT EXECUTE SOLO a service_role. Es el batch, no una persona: la lista cerrada de la sección 70(d) (EXECUTE para authenticated) NO cambia. Dueño postgres, no LEAKPROOF.
--   Los datos que escribe vienen del cálculo del batch con service_role; no hay autorización de persona que repetir dentro (como fn_corte_quincenal_aplicar_persona).
-- INTERACCIÓN CON LOS TRIGGERS EXISTENTES (verificado leyéndolos): sobre tiempo.dia no hay triggers; sobre tiempo.tramo, trg_tramo_valida_coherencia (86_: marcas de la persona y del día; DEFINER) y, si está aplicado, trg_tramo_valida_tiempos
--   (123_: inicio/fin/minutos = momentos efectivos; DEFINER); sobre tiempo.excepcion solo hay triggers de UPDATE (86_). Esta función no depende de 123_: convive con él en CUALQUIER orden de aplicación (sin 123_ no hay validación de tiempos, con él
--   un tramo incoherente aborta el cierre de ESE día completo en lugar de dejarlo a medias).
-- ORDEN: ninguno obligatorio. Recomendado: aplicar 124_ y desplegar el backend que la usa ANTES de aplicar 123_, para que el rechazo de un tramo no pueda dejar días a medias (el motivo de esta migración).
-- INVENTARIO DE RLS/GRANT: sin tablas nuevas ni policies; solo una función con EXECUTE para service_role.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 124_*.sql`.
-- REVERSA (en una transacción): DROP FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text); el backend debe volver a la versión con llamadas sueltas. Texto exacto en db/ensayos/ensayo_124.sql.
-- Depende de: 02_tiempo.sql, 86_*.sql (opcionalmente 123_*.sql)
-- Justificación: SCJ-PRO-12, CLAUDE.md (RPC transaccional para escrituras relacionadas)

CREATE FUNCTION tiempo.fn_cierre_dia_armar(
  p_persona_id              uuid,
  p_fecha                   date,
  p_estado                  varchar,
  p_horas_totales           numeric,
  p_tramos                  jsonb,
  p_motivo_excepcion_dia    text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_dia_id     bigint;
  v_t          record;
  v_n          integer;
  v_abiertos   integer;
  v_abierto_es_ultimo boolean;
BEGIN
  IF p_estado IS NULL OR p_estado NOT IN ('cerrado', 'bloqueado') THEN
    RAISE EXCEPTION 'El estado del día debe ser cerrado o bloqueado.' USING ERRCODE = 'SCJ27', HINT = 'estado_invalido';
  END IF;

  IF p_tramos IS NULL OR jsonb_typeof(p_tramos) <> 'array' OR jsonb_array_length(p_tramos) = 0 THEN
    RAISE EXCEPTION 'El cierre del día necesita al menos un tramo.' USING ERRCODE = 'SCJ27', HINT = 'tramos_inconsistentes';
  END IF;

  v_n := jsonb_array_length(p_tramos);
  SELECT count(*) FILTER (WHERE x.marca_cierre_id IS NULL), COALESCE(bool_and(x.marca_cierre_id IS NOT NULL OR x.ord = v_n), true)
    INTO v_abiertos, v_abierto_es_ultimo
  FROM ROWS FROM (jsonb_to_recordset(p_tramos) AS (marca_apertura_id bigint, marca_cierre_id bigint, inicio timestamptz, fin timestamptz, minutos_trabajados numeric))
         WITH ORDINALITY AS x(marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados, ord);

  IF p_estado = 'cerrado' THEN
    IF v_abiertos <> 0 OR p_horas_totales IS NULL OR p_motivo_excepcion_dia IS NOT NULL THEN
      RAISE EXCEPTION 'Un día cerrado necesita todos sus tramos cerrados y sus horas, y no lleva excepción de día.' USING ERRCODE = 'SCJ27', HINT = 'tramos_inconsistentes';
    END IF;
    IF p_horas_totales < 0 OR p_horas_totales > 24 THEN
      RAISE EXCEPTION 'Las horas del día deben estar entre 0 y 24.' USING ERRCODE = 'SCJ27', HINT = 'horas_fuera_de_rango';
    END IF;
  ELSE
    IF v_abiertos <> 1 OR NOT v_abierto_es_ultimo OR p_horas_totales IS NOT NULL
       OR p_motivo_excepcion_dia IS NULL OR length(btrim(p_motivo_excepcion_dia)) = 0 THEN
      RAISE EXCEPTION 'Un día bloqueado necesita exactamente un tramo abierto (el último), sin horas y con el motivo de la excepción de día.' USING ERRCODE = 'SCJ27', HINT = 'tramos_inconsistentes';
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM tiempo.dia d WHERE d.persona_id = p_persona_id AND d.fecha = p_fecha) THEN
    RAISE EXCEPTION 'Ya existe el día de esta persona y fecha.' USING ERRCODE = 'SCJ27', HINT = 'dia_ya_existe';
  END IF;

  INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales)
  VALUES (p_persona_id, p_fecha, p_estado, p_horas_totales)
  RETURNING id INTO v_dia_id;

  FOR v_t IN
    SELECT * FROM ROWS FROM (jsonb_to_recordset(p_tramos) AS (marca_apertura_id bigint, marca_cierre_id bigint, inicio timestamptz, fin timestamptz, minutos_trabajados numeric))
      WITH ORDINALITY AS x(marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados, ord)
    ORDER BY x.ord
  LOOP
    INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
    VALUES (v_dia_id, v_t.marca_apertura_id, v_t.marca_cierre_id, v_t.inicio, v_t.fin, v_t.minutos_trabajados);
  END LOOP;

  IF p_estado = 'bloqueado' THEN
    INSERT INTO tiempo.excepcion (dia_id, marca_id, motivo_revision)
    VALUES (v_dia_id, NULL, btrim(p_motivo_excepcion_dia));
  END IF;

  RETURN v_dia_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text) TO service_role;

COMMENT ON FUNCTION tiempo.fn_cierre_dia_armar(uuid, date, varchar, numeric, jsonb, text) IS
  'RPC transaccional del cierre de día (124_, SCJ-PRO-12): crea tiempo.dia, todos sus tramos (en el orden de p_tramos) y, si el día es bloqueado, la excepción de día, en UNA transacción: un fallo de cualquier trigger o de la propia '
  'validación revierte todo y no deja un día sin tramos. SCJ27 con HINT dia_ya_existe / estado_invalido / horas_fuera_de_rango / tramos_inconsistentes. No calcula nada (horas y minutos los manda el batch). SECURITY DEFINER con search_path fijo; EXECUTE solo '
  'service_role. Convive con 123_ en cualquier orden.';
