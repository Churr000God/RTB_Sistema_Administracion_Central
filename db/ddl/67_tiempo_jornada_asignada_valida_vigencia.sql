-- 67_tiempo_jornada_asignada_valida_vigencia.sql
-- Bug real encontrado en vivo (reproducido del lado backend con log real, confirmado contra la BD
-- real): fn_jornada_asignar_renovar cierra la vigencia anterior con
-- `vigente_hasta = p_vigente_desde - 1` (db/ddl/40_*.sql:67), asumiendo que la nueva vigencia
-- siempre empieza DESPUÉS de que empezó la anterior. Si alguien renueva la jornada dos veces el
-- mismo día -- p_vigente_desde de la segunda llamada es igual al vigente_desde de la fila ya
-- vigente -- el cálculo da un vigente_hasta ANTERIOR al propio vigente_desde de esa fila:
-- intervalo invertido, guardado en silencio porque tiempo.jornada_asignada no tenía ningún CHECK
-- que validara el orden de sus propias fechas. Pasó de verdad con persona_id
-- 0a33e6a0-e1d0-47c2-bb55-fc3be2f12f02 (Administrador del Sistema, id=28: vigente_desde=2026-09-08,
-- terminó con vigente_hasta=2026-09-07).
--
-- Dos capas de defensa, en el mismo archivo porque la segunda depende de la primera existiendo
-- (mismo criterio que 45_*.sql/62_*.sql: cambio atómico con orden obligatorio):
-- 1) fn_jornada_asignar_renovar rechaza el caso ANTES de escribir nada -- RAISE EXCEPTION si la
--    nueva vigencia no es estrictamente posterior a la fecha en que empezó la vigente actual.
-- 2) CHECK a nivel tabla -- red de seguridad para cualquier otro camino de escritura futuro (o un
--    bug distinto en este mismo RPC) que intente guardar el mismo tipo de dato corrupto.
--
-- ERRCODE nuevo: SCJ02 (local a esta función). SCJ01 ya lo usa fn_jornada_asignar_renovar para su
-- propio primer caso (vigencia activa sin confirmar) -- no se puede reusar para un caso distinto
-- que backend necesita mapear a un status HTTP diferente (409 vs 422). SCJ02 ya existe en el
-- proyecto para OTROS casos no relacionados (fn_ausencia_resolver -- ausencia no existe --,
-- fn_parametro_actualizar_valor y fn_tope_legal_crear_vigencia -- vigencia no encontrada), pero
-- estos códigos son locales a cada función (mismo criterio ya establecido: SCJ01 también se
-- reusa entre fn_jornada_asignar_renovar y fn_tope_legal_crear_vigencia sin conflicto, porque
-- backend sólo interpreta el código en el contexto del RPC específico que llamó). No se introduce
-- un espacio de nombres global nuevo -- se sigue el patrón existente: el segundo código de esta
-- función es, naturalmente, SCJ02.
--
-- NOTA -- orden de aplicación: este archivo agrega un CHECK sobre datos que HOY tienen una fila
-- que lo viola (jornada_asignada id=28, vigente_hasta=2026-09-07 < vigente_desde=2026-09-08) --
-- el ALTER TABLE de abajo falla si esa fila (y su patron_semanal) no se corrigen/borran ANTES.
-- Esa corrección es un DELETE puntual de datos (fila 28 nunca estuvo vigente un día completo, la
-- 29 la reemplazó el mismo día -- aprobado por el usuario), no DDL versionado -- se ejecuta aparte,
-- fuera de este archivo, antes de aplicar esto.
-- Depende de: 02_tiempo.sql, 40_tiempo_fn_asignar_renovar_jornada.sql
-- Justificación: SCJ-DEC-04 (vigencias temporales sin traslape -- una vigencia con vigente_hasta
--   anterior a su propio vigente_desde no es una vigencia válida bajo ningún criterio del modelo)

-- ============================================================================
-- 1) fn_jornada_asignar_renovar -- misma firma (7 parámetros), sin DROP.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_jornada_asignar_renovar(
  p_persona_id                     uuid,
  p_tipo_jornada                   varchar(20),
  p_vigente_desde                  date,
  p_patron_semanal                 jsonb,
  p_descuento_comida_fija          boolean DEFAULT false,
  p_minutos_descuento_comida_fija  int DEFAULT NULL,
  p_confirma_cierre_vigente        boolean DEFAULT false
) RETURNS tiempo.jornada_asignada AS $$
DECLARE
  v_vigente_id            bigint;
  v_vigente_desde_actual  date;
  v_nueva                 tiempo.jornada_asignada;
BEGIN
  SELECT id, vigente_desde INTO v_vigente_id, v_vigente_desde_actual
  FROM tiempo.jornada_asignada
  WHERE persona_id = p_persona_id AND vigente_hasta IS NULL;

  IF v_vigente_id IS NOT NULL AND NOT p_confirma_cierre_vigente THEN
    RAISE EXCEPTION
      'La persona % ya tiene una jornada vigente (id %) -- confirma_cierre_vigente debe ser '
      'true para cerrarla y asignar la nueva', p_persona_id, v_vigente_id
      USING ERRCODE = 'SCJ01';
  END IF;

  -- Bug real (2026-09-08, ver cabecera): sin este chequeo, renovar dos veces el mismo día produce
  -- vigente_hasta = p_vigente_desde - 1 anterior al propio vigente_desde de la fila que se cierra.
  IF v_vigente_id IS NOT NULL AND p_vigente_desde <= v_vigente_desde_actual THEN
    RAISE EXCEPTION
      'La nueva vigencia (%) debe ser posterior a la fecha en que empezó la jornada vigente '
      'actual (%)', p_vigente_desde, v_vigente_desde_actual
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_vigente_id IS NOT NULL THEN
    UPDATE tiempo.jornada_asignada
    SET vigente_hasta = p_vigente_desde - 1
    WHERE id = v_vigente_id;
  END IF;

  INSERT INTO tiempo.jornada_asignada (
    persona_id, tipo_jornada, vigente_desde, vigente_hasta,
    descuento_comida_fija, minutos_descuento_comida_fija, genera_alerta_horario
  ) VALUES (
    p_persona_id, p_tipo_jornada, p_vigente_desde, NULL,
    p_descuento_comida_fija, p_minutos_descuento_comida_fija, p_tipo_jornada = 'normal'
  )
  RETURNING * INTO v_nueva;

  INSERT INTO tiempo.patron_semanal (
    jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida
  )
  SELECT v_nueva.id, x.dia_semana, x.hora_entrada, x.hora_salida, COALESCE(x.minutos_comida, 0)
  FROM jsonb_to_recordset(p_patron_semanal) AS x(
    dia_semana varchar(10), hora_entrada time, hora_salida time, minutos_comida int
  );

  RETURN v_nueva;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_jornada_asignar_renovar(
  uuid, varchar, date, jsonb, boolean, int, boolean
) IS
  'RPC transaccional de "asignar/renovar jornada" (SCJ-PRO-09): si hay vigencia activa sin '
  'confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... USING ERRCODE = ''SCJ01'' '
  '(backend lo mapea a 409); si la nueva vigencia no es posterior a la fecha en que empezó la '
  'vigente actual, señaliza con ERRCODE ''SCJ02'' (backend lo mapea a 422 -- '
  '67_tiempo_jornada_asignada_valida_vigencia.sql, evita el intervalo invertido que producía '
  'renovar dos veces el mismo día); si pasa ambos chequeos, cierra la anterior '
  '(vigente_hasta = nueva.vigente_desde - 1 día) e inserta la jornada nueva + su patron_semanal '
  'completo en una sola transacción. genera_alerta_horario se deriva aquí de tipo_jornada. El '
  'CONSTRAINT TRIGGER de tope legal (trg_patron_semanal_valida_tope_legal, DEFERRABLE INITIALLY '
  'DEFERRED) sigue corriendo al final de esta misma transacción -- no hace falta invocarlo aparte.';

-- ============================================================================
-- 2) CHECK a nivel tabla -- red de seguridad además del chequeo del RPC. Requiere que la fila 28
-- (y su patron_semanal) ya se hayan corregido/borrado ANTES de aplicar este archivo -- ver nota
-- de la cabecera.
-- ============================================================================

ALTER TABLE tiempo.jornada_asignada
  ADD CONSTRAINT ck_jornada_asignada_vigencia
  CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde);

COMMENT ON CONSTRAINT ck_jornada_asignada_vigencia ON tiempo.jornada_asignada IS
  'Ninguna vigencia puede terminar antes de empezar. Agregado tras el bug real de renovar dos '
  'veces el mismo día (67_tiempo_jornada_asignada_valida_vigencia.sql) -- fn_jornada_asignar_'
  'renovar ya lo rechaza antes (ERRCODE SCJ02), este CHECK es la red de seguridad a nivel base.';
