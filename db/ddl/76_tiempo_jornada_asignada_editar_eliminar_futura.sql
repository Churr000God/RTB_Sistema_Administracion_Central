-- 76_tiempo_jornada_asignada_editar_eliminar_futura.sql
-- Feature nueva (2026-09-11, aprobada por el usuario): 3 RPCs para editar/eliminar jornadas
-- FUTURAS de tiempo.jornada_asignada y mover el límite de la jornada EN CURSO. Depende de las
-- protecciones de 75_tiempo_jornada_asignada_proteccion_vigencias.sql -- los 3 RPCs escriben
-- directo sobre las tablas (no service_role, SECURITY INVOKER como fn_jornada_asignar_renovar),
-- así que los triggers de esa migración corren igual sobre cada UPDATE/DELETE que hacen; el
-- pre-chequeo explícito de cada RPC es UX (mensaje ERRCODE local mapeable a un status HTTP
-- concreto), no la única defensa -- si un RPC tuviera un bug, el trigger sigue ahí.
--
-- Permisos: jornada_asignada_edicion + patron_semanal_edicion (mismo AND que ya exige el POST
-- existente, fn_jornada_asignar_renovar) -- sin permiso nuevo, RLS de 39_*.sql sigue siendo la
-- autorización real.
--
-- Grep previo: fn_jornada_futura_eliminar/fn_jornada_futura_actualizar/
-- fn_jornada_en_curso_mover_limite no existían -- funciones enteramente nuevas, sin ALTER
-- FUNCTION que repetir.
--
-- Convención de ERRCODE: cada RPC numera SCJ01.. por su cuenta (mismo criterio ya establecido en
-- 67_*.sql -- los códigos son locales a la función que los levanta, backend los interpreta en el
-- contexto del RPC específico que llamó, no como espacio de nombres global).
--
-- Depende de: 02_tiempo.sql, 39_tiempo_rls_jornada_patron.sql, 40_tiempo_fn_asignar_renovar_
--   jornada.sql, 67_tiempo_jornada_asignada_valida_vigencia.sql,
--   75_tiempo_jornada_asignada_proteccion_vigencias.sql
-- Justificación: feature "editar/eliminar jornada futura" aprobada 2026-09-11

-- ============================================================================
-- 1) fn_jornada_futura_eliminar -- elimina una jornada futura que sea la última de la cadena y
-- reabre la predecesora (si existe) dejándola sin vigente_hasta.
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_futura_eliminar(p_jornada_id bigint) RETURNS void AS $$
DECLARE
  v_jornada        tiempo.jornada_asignada;
  v_predecesora_id bigint;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF v_jornada.vigente_desde <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar una jornada que todavía no empezó (id %, vigente_desde %)',
      p_jornada_id, v_jornada.vigente_desde USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = v_jornada.persona_id AND j.id <> v_jornada.id
                  AND j.vigente_desde >= v_jornada.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar la última jornada de la cadena (id %)', p_jornada_id
      USING ERRCODE = 'SCJ03';
  END IF;

  SELECT id INTO v_predecesora_id
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde < v_jornada.vigente_desde
  ORDER BY vigente_desde DESC LIMIT 1;

  DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = p_jornada_id;
  DELETE FROM tiempo.jornada_asignada WHERE id = p_jornada_id;

  IF v_predecesora_id IS NOT NULL THEN
    UPDATE tiempo.jornada_asignada SET vigente_hasta = NULL WHERE id = v_predecesora_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) IS
  'RPC transaccional de "eliminar jornada futura": borra el patron_semanal y la fila de '
  'jornada_asignada, y si existe una predecesora la reabre (vigente_hasta = NULL). Sólo aplica a '
  'una jornada con vigente_desde futura que además sea la última de la cadena de esa persona '
  '(sin vigente_hasta, sin otra fila con vigente_desde posterior o igual). SECURITY INVOKER -- '
  'RLS de jornada_asignada/patron_semanal (39_tiempo_rls_jornada_patron.sql) es la autorización '
  'real, jornada_asignada_edicion + patron_semanal_edicion. Los triggers de '
  '75_tiempo_jornada_asignada_proteccion_vigencias.sql corren igual sobre cada DELETE/UPDATE que '
  'hace este RPC -- éste es sólo el que da el mensaje/ERRCODE específico. Señales de conflicto: '
  'SCJ01 la jornada no existe (backend mapea a 404), SCJ02 ya empezó (422), SCJ03 no es la '
  'última de la cadena (422).';

-- ============================================================================
-- 2) fn_jornada_futura_actualizar -- reemplazo TOTAL (no parcial) de tipo/fecha/patrón de una
-- jornada futura que sea la última de la cadena. Si mueve vigente_desde, ajusta la predecesora
-- (vigente_hasta = nueva.vigente_desde - 1), mismo cálculo que fn_jornada_asignar_renovar.
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_futura_actualizar(
  p_jornada_id                    bigint,
  p_tipo_jornada                  varchar(20),
  p_vigente_desde                 date,
  p_patron_semanal                jsonb,
  p_descuento_comida_fija         boolean DEFAULT false,
  p_minutos_descuento_comida_fija int DEFAULT NULL
) RETURNS tiempo.jornada_asignada AS $$
DECLARE
  v_jornada           tiempo.jornada_asignada;
  v_predecesora_id    bigint;
  v_predecesora_desde date;
  v_actualizada       tiempo.jornada_asignada;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF v_jornada.vigente_desde <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'Sólo se puede editar una jornada que todavía no empezó (id %, vigente_desde %)',
      p_jornada_id, v_jornada.vigente_desde USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = v_jornada.persona_id AND j.id <> v_jornada.id
                  AND j.vigente_desde >= v_jornada.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede editar la última jornada de la cadena (id %)', p_jornada_id
      USING ERRCODE = 'SCJ03';
  END IF;

  IF p_vigente_desde <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'La jornada debe seguir empezando en una fecha futura (intento %)', p_vigente_desde
      USING ERRCODE = 'SCJ04';
  END IF;

  IF p_patron_semanal IS NULL OR jsonb_array_length(p_patron_semanal) = 0 THEN
    RAISE EXCEPTION 'El patrón semanal debe tener al menos un día' USING ERRCODE = 'SCJ06';
  END IF;

  SELECT id, vigente_desde INTO v_predecesora_id, v_predecesora_desde
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde < v_jornada.vigente_desde
  ORDER BY vigente_desde DESC LIMIT 1;

  IF v_predecesora_id IS NOT NULL AND p_vigente_desde <= v_predecesora_desde THEN
    RAISE EXCEPTION
      'La jornada no puede empezar antes ni el mismo día que la anterior (anterior empezó %)',
      v_predecesora_desde USING ERRCODE = 'SCJ05';
  END IF;

  UPDATE tiempo.jornada_asignada
  SET tipo_jornada = p_tipo_jornada, vigente_desde = p_vigente_desde,
      descuento_comida_fija = p_descuento_comida_fija,
      minutos_descuento_comida_fija = p_minutos_descuento_comida_fija,
      genera_alerta_horario = (p_tipo_jornada = 'normal')
  WHERE id = p_jornada_id
  RETURNING * INTO v_actualizada;

  IF v_predecesora_id IS NOT NULL THEN
    UPDATE tiempo.jornada_asignada SET vigente_hasta = p_vigente_desde - 1 WHERE id = v_predecesora_id;
  END IF;

  DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = p_jornada_id;
  INSERT INTO tiempo.patron_semanal (jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida)
  SELECT p_jornada_id, x.dia_semana, x.hora_entrada, x.hora_salida, COALESCE(x.minutos_comida, 0)
  FROM jsonb_to_recordset(p_patron_semanal) AS x(
    dia_semana varchar(10), hora_entrada time, hora_salida time, minutos_comida int
  );

  RETURN v_actualizada;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_futura_actualizar(
  bigint, varchar, date, jsonb, boolean, int
) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_futura_actualizar(
  bigint, varchar, date, jsonb, boolean, int
) FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_futura_actualizar(
  bigint, varchar, date, jsonb, boolean, int
) IS
  'RPC transaccional de "editar jornada futura": reemplazo TOTAL (no parcial) de tipo_jornada, '
  'vigente_desde, descuento de comida y patrón semanal completo, en una sola transacción. Sólo '
  'aplica a una jornada con vigente_desde futura que además sea la última de la cadena. Si mueve '
  'vigente_desde, ajusta vigente_hasta de la predecesora (nueva.vigente_desde - 1 día, mismo '
  'cálculo que fn_jornada_asignar_renovar/40_*.sql) -- incluye el caso de borde aprobado donde la '
  'nueva fecha es hoy + 1, forzando a la predecesora en curso a cerrar hoy mismo. '
  'genera_alerta_horario se deriva aquí de tipo_jornada, igual que fn_jornada_asignar_renovar. '
  'SECURITY INVOKER -- RLS es la autorización real, jornada_asignada_edicion + '
  'patron_semanal_edicion. Señales de conflicto: SCJ01 la jornada no existe (404), SCJ02 ya '
  'empezó (422), SCJ03 no es la última de la cadena (422), SCJ04 la nueva fecha no es futura '
  '(422), SCJ05 la nueva fecha no deja pasar a la predecesora (422), SCJ06 patrón semanal vacío '
  '(422).';

-- ============================================================================
-- 3) fn_jornada_en_curso_mover_limite -- mueve vigente_hasta de la jornada vigente HOY a una
-- fecha estrictamente futura, siempre que la única jornada siguiente en la cadena sea la última
-- (sin su propio vigente_hasta) -- ajusta el vigente_desde de esa siguiente para que la cadena
-- quede sin hueco ni traslape.
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_en_curso_mover_limite(
  p_jornada_id bigint, p_vigente_hasta date
) RETURNS tiempo.jornada_asignada AS $$
DECLARE
  v_jornada   tiempo.jornada_asignada;
  v_siguiente tiempo.jornada_asignada;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF NOT (v_jornada.vigente_desde <= CURRENT_DATE
          AND (v_jornada.vigente_hasta IS NULL OR v_jornada.vigente_hasta >= CURRENT_DATE)) THEN
    RAISE EXCEPTION
      'Sólo se puede mover la fecha de término de la jornada vigente hoy (id %)', p_jornada_id
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NULL THEN
    RAISE EXCEPTION
      'Esta jornada no tiene fecha de término ni un tramo planeado después -- para terminarla, '
      'asigná la jornada siguiente (id %)', p_jornada_id USING ERRCODE = 'SCJ03';
  END IF;

  IF p_vigente_hasta <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'La fecha de término debe ser posterior a hoy (intento %)', p_vigente_hasta
      USING ERRCODE = 'SCJ04';
  END IF;

  SELECT * INTO v_siguiente
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde > v_jornada.vigente_desde
  ORDER BY vigente_desde ASC LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Cadena inconsistente: la jornada % está cerrada pero no tiene tramo siguiente', p_jornada_id
      USING ERRCODE = 'SCJ06';
  END IF;

  IF v_siguiente.vigente_hasta IS NOT NULL THEN
    RAISE EXCEPTION
      'Hay más de un tramo planeado después -- eliminá los tramos futuros desde el final antes de '
      'mover esta fecha (id %)', p_jornada_id USING ERRCODE = 'SCJ05';
  END IF;

  UPDATE tiempo.jornada_asignada SET vigente_hasta = p_vigente_hasta
  WHERE id = p_jornada_id RETURNING * INTO v_jornada;

  UPDATE tiempo.jornada_asignada SET vigente_desde = p_vigente_hasta + 1 WHERE id = v_siguiente.id;

  RETURN v_jornada;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) IS
  'RPC transaccional de "mover el límite de la jornada en curso": cambia vigente_hasta de la '
  'jornada vigente hoy a una fecha estrictamente futura, y desplaza vigente_desde de la única '
  'jornada siguiente para que la cadena quede sin hueco ni traslape. Sólo aplica si la jornada en '
  'curso ya tiene una fecha de término planeada (vigente_hasta NOT NULL) y esa siguiente jornada '
  'es a su vez la última de la cadena (sin su propio vigente_hasta) -- con más de un tramo '
  'planeado después, hay que eliminar los futuros desde el final primero '
  '(fn_jornada_futura_eliminar). La nueva fecha exige estrictamente futura sin el carve-out del '
  'caso de borde de fn_jornada_futura_actualizar (ese carve-out sólo aplica cuando el cierre de '
  'la predecesora es un EFECTO de mover la fecha de inicio de la sucesora, no cuando se mueve '
  'directo con este RPC). SECURITY INVOKER -- RLS es la autorización real, '
  'jornada_asignada_edicion. Señales de conflicto: SCJ01 la jornada no existe (404), SCJ02 no es '
  'la vigente hoy (422), SCJ03 es la fila abierta sin fecha de término ni sucesora (422), SCJ04 '
  'la nueva fecha no es estrictamente futura (422), SCJ05 la sucesora no es la última de la '
  'cadena (422), SCJ06 cadena inconsistente -- cerrada sin sucesora (422, debería ser '
  'inalcanzable si el resto de las protecciones de 75_*.sql se mantiene).';
