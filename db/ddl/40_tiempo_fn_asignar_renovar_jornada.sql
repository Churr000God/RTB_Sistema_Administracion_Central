-- 40_tiempo_fn_asignar_renovar_jornada.sql
-- RPC transaccional de "asignar/renovar jornada" (SCJ-PRO-09), pedido por backend/orchestrator:
-- el endpoint hoy hace 3 llamadas REST separadas (cerrar vigencia anterior + insertar
-- jornada_asignada + insertar patron_semanal, ver backend/app/routers/jornada_asignada.py) sin
-- transacción real -- un fallo entre la segunda y la tercera deja a la persona sin patrón semanal
-- para su jornada nueva (o, peor, sin ninguna jornada vigente si falla entre cerrar y abrir). Mismo
-- motivo y mismo patrón que personas.fn_asignacion_cambiar_puesto
-- (19_asignacion_fn_cambiar_puesto.sql): una sola función, una sola transacción.
--
-- SECURITY INVOKER (default, no se escribe SECURITY DEFINER): corre con los permisos del caller
-- para que la RLS de tiempo.jornada_asignada/tiempo.patron_semanal (39_tiempo_rls_jornada_
-- patron.sql) siga aplicando igual que un INSERT/UPDATE directo -- el caller sigue necesitando
-- jornada_asignada_edicion (para el UPDATE de cierre + INSERT de jornada_asignada) y
-- patron_semanal_edicion (para el INSERT de patron_semanal); esta función no los sustituye, sólo
-- los ejecuta atómicamente. backend sigue gateando además con requiere_todos_los_permisos(...)
-- para el 403 legible -- la RLS es la autorización real, este RPC no cambia eso.
--
-- p_patron_semanal llega como jsonb (array de objetos {dia_semana, hora_entrada, hora_salida,
-- minutos_comida}) en vez de un array de un CREATE TYPE propio -- supabase-py/PostgREST serializan
-- una lista de dicts de Python a jsonb sin fricción vía rpc(), y el proyecto ya evita CREATE TYPE
-- ENUM por convención (ver comentario de 14_personas_puesto.sql); jsonb_to_recordset() desempaqueta
-- el array a filas tipadas para el INSERT ... SELECT.
--
-- Señal de conflicto (vigencia activa sin confirmar): RAISE EXCEPTION con ERRCODE propio 'SCJ01'
-- -- NO se reutiliza 23505 (unique_violation) porque no lo es de verdad (no hay UNIQUE de por
-- medio, el traslape se valida en la aplicación por decisión de SCJ-DEC-04 Opción A) ni el 'P0001'
-- por omisión de fn_asignacion_cambiar_puesto (ahí sólo hay un caso de error, acá hace falta
-- distinguir "conflicto, pedile confirmación al usuario" de cualquier otro fallo). Primer uso de
-- ERRCODE explícito en el proyecto -- backend debe atrapar postgrest.exceptions.APIError y mapear
-- error.code == 'SCJ01' a 409 con MENSAJE_VIGENCIA_ACTIVA_SIN_CONFIRMAR (ya existe en
-- backend/app/routers/jornada_asignada.py); cualquier otro código (tope legal vía CONSTRAINT
-- TRIGGER, CHECK de patron_semanal, FK de persona_id) sigue el criterio de siempre: 422 con el
-- mensaje crudo de Postgres.
--
-- genera_alerta_horario se calcula aquí (tipo_jornada = 'normal'), no en Python -- mueve la regla
-- de negocio "en un campo" (SCJ-PRO-09 §V) a donde ahora vive la escritura atómica; el backend deja
-- de fijarlo a mano.
-- Depende de: 02_tiempo.sql, 39_tiempo_rls_jornada_patron.sql
-- Justificación: SCJ-PRO-09 §VII (asignar/renovar jornada)

CREATE FUNCTION tiempo.fn_jornada_asignar_renovar(
  p_persona_id                     uuid,
  p_tipo_jornada                   varchar(20),
  p_vigente_desde                  date,
  p_patron_semanal                 jsonb,
  p_descuento_comida_fija          boolean DEFAULT false,
  p_minutos_descuento_comida_fija  int DEFAULT NULL,
  p_confirma_cierre_vigente        boolean DEFAULT false
) RETURNS tiempo.jornada_asignada AS $$
DECLARE
  v_vigente_id bigint;
  v_nueva      tiempo.jornada_asignada;
BEGIN
  SELECT id INTO v_vigente_id
  FROM tiempo.jornada_asignada
  WHERE persona_id = p_persona_id AND vigente_hasta IS NULL;

  IF v_vigente_id IS NOT NULL AND NOT p_confirma_cierre_vigente THEN
    RAISE EXCEPTION
      'La persona % ya tiene una jornada vigente (id %) -- confirma_cierre_vigente debe ser '
      'true para cerrarla y asignar la nueva', p_persona_id, v_vigente_id
      USING ERRCODE = 'SCJ01';
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
  '(backend lo mapea a 409); si confirmada o no hay vigencia previa, cierra la anterior '
  '(vigente_hasta = nueva.vigente_desde - 1 día) e inserta la jornada nueva + su patron_semanal '
  'completo en una sola transacción. genera_alerta_horario se deriva aquí de tipo_jornada. El '
  'CONSTRAINT TRIGGER de tope legal (trg_patron_semanal_valida_tope_legal, DEFERRABLE INITIALLY '
  'DEFERRED) sigue corriendo al final de esta misma transacción -- no hace falta invocarlo aparte.';

-- Las funciones no heredan el GRANT ALL de tablas -- hace falta GRANT EXECUTE explícito. REVOKE
-- de PUBLIC en el mismo archivo desde el arranque (19_/20_asignacion_fn_cambiar_puesto.sql lo
-- hicieron en dos pasos, corrigiendo un hallazgo de auditoría después -- no repetir esa secuencia).
GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_asignar_renovar(
  uuid, varchar, date, jsonb, boolean, int, boolean
) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_asignar_renovar(
  uuid, varchar, date, jsonb, boolean, int, boolean
) FROM PUBLIC;
