-- 19_asignacion_fn_cambiar_puesto.sql
-- Primer RPC del proyecto: cerrar la asignación vigente y abrir la nueva en una sola transacción
-- de Postgres (evita que un fallo entre el UPDATE de cierre y el INSERT de apertura deje a la
-- persona sin asignación vigente).
-- Depende de: 17_personas_asignacion.sql
-- Justificación: SCJ-PRO-04 §VII (cambio de puesto)

-- SECURITY INVOKER (default, no se escribe SECURITY DEFINER): debe correr con los permisos del
-- caller para que la RLS de personas.asignacion siga aplicando igual que cualquier otro
-- INSERT/UPDATE directo del esquema.
CREATE FUNCTION personas.fn_asignacion_cambiar_puesto(
  p_asignacion_id uuid,
  p_puesto_nuevo_id uuid,
  p_fecha date
) RETURNS personas.asignacion AS $$
DECLARE
  v_persona_id uuid;
  v_nueva personas.asignacion;
BEGIN
  SELECT persona_id INTO v_persona_id
  FROM personas.asignacion
  WHERE id = p_asignacion_id AND vigente_hasta IS NULL;

  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'Asignación no encontrada o ya cerrada';
  END IF;

  UPDATE personas.asignacion
  SET vigente_hasta = p_fecha, actualizado_en = now()
  WHERE id = p_asignacion_id;

  INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
  VALUES (v_persona_id, p_puesto_nuevo_id, p_fecha)
  RETURNING * INTO v_nueva;

  RETURN v_nueva;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION personas.fn_asignacion_cambiar_puesto(uuid, uuid, date) IS
  'RPC transaccional de "cambiar de puesto" (SCJ-PRO-04 §VII): cierra la asignación vigente '
  'p_asignacion_id y abre una nueva para el mismo persona_id en p_puesto_nuevo_id, ambas '
  'escrituras en una sola transacción. Las validaciones de negocio (puesto nuevo existe/activo, '
  'plazas libres) las hace el backend ANTES de invocar este RPC — esta función sólo garantiza '
  'atomicidad entre cerrar y abrir. Queda una ventana teórica de carrera entre esa validación en '
  'Python y la ejecución del RPC (dos requests separados); riesgo aceptado de bajo impacto dado '
  'el tamaño real de la empresa, mismo criterio que SCJ-PRO-05 §VII.';

-- Las funciones no heredan el GRANT ALL de tablas — hace falta GRANT EXECUTE explícito.
GRANT EXECUTE ON FUNCTION personas.fn_asignacion_cambiar_puesto(uuid, uuid, date) TO authenticated;
