-- 49_tiempo_rls_ausencia_aprobacion.sql
-- RLS de tiempo.ausencia y tiempo.aprobacion_ausencia para el flujo humano (SCJ-PRO-08, detección
-- y resolución de falta). Ambas tablas con RLS habilitada sin policy desde 41_tiempo_rls_deny_
-- default.sql.
--
-- ============================================================================
-- tiempo.ausencia
-- ============================================================================
--
-- SELECT: fn_caller_activo() + (ausencia_lectura OR ausencia_edicion) -- para listar pendientes.
--
-- UPDATE: fn_caller_activo() + ausencia_edicion -- cubre dos escritores distintos con el mismo
-- permiso, por diseño del propio proceso:
--   1) El humano reclasificando tipo_de_ausencia (UPDATE directo, SCJ-PRO-08 §III D1/E1) --
--      necesita ausencia_edicion por sí mismo.
--   2) trg_aprobacion_ausencia_actualiza_ausencia (UPDATE ausencia.estado_autorizacion, disparado
--      por el INSERT en tiempo.aprobacion_ausencia, NO es SECURITY DEFINER) -- corre con los
--      privilegios de ESE MISMO humano, porque SCJ-PRO-08 §V es explícito: "reclasificar el tipo
--      es parte de la misma transacción que aprobar" (UPDATE ausencia.tipo_de_ausencia + INSERT
--      aprobacion_ausencia no pueden quedar separados). Como ya necesita ausencia_edicion para el
--      paso 1 de esa misma transacción, no hace falta ningún permiso adicional para que el
--      trigger del paso 2 tampoco falle -- a diferencia de excepcion/correccion (48_*.sql), acá
--      NO hay un caso de "otro actor con otro permiso" que se cuele por esta UPDATE.
--
-- Sin INSERT: tiempo.ausencia la crea el sistema (batch de cierre de día, aún sin construir, va a
-- correr con service_role -- bypassa RLS por completo). SCJ-PRO-08 §V: "el sistema crea la
-- ausencia, nadie la solicita" -- no existe ningún flujo humano de alta todavía (ver nota de
-- alcance del documento: la solicitud manual de vacaciones/permiso/incapacidad por la propia
-- persona queda fuera, pendiente de implementación real).
--
-- Sin DELETE: ningún flujo lo pide.

CREATE POLICY ausencia_select_requiere_permiso ON tiempo.ausencia
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('ausencia_lectura')
      OR personas.fn_caller_tiene_permiso('ausencia_edicion')
    )
  );

CREATE POLICY ausencia_update_requiere_permiso ON tiempo.ausencia
  FOR UPDATE
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
  );

-- ============================================================================
-- tiempo.aprobacion_ausencia
-- ============================================================================
--
-- INSERT: fn_caller_activo() + aprobacion_ausencia_edicion -- la fila se crea directo con la
-- decisión ya tomada (SCJ-PRO-08 §V: "no hay fila pendiente pre-creada"), nunca se actualiza
-- después -- por eso no hace falta policy de UPDATE.
--
-- SELECT: fn_caller_activo() + (aprobacion_ausencia_lectura OR aprobacion_ausencia_edicion).
--
-- Sin UPDATE/DELETE: el modelo es insertar un paso nuevo por decisión, nunca editar uno existente
-- -- uq_aprobacion_ausencia_paso (ausencia_id, numero_paso) es la garantía de que dos personas
-- resolviendo a la vez no pisan al primero (SCJ-PRO-08 §III H1-H2), no algo que RLS deba reforzar
-- aparte.

CREATE POLICY aprobacion_ausencia_insert_requiere_permiso ON tiempo.aprobacion_ausencia
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion')
  );

CREATE POLICY aprobacion_ausencia_select_requiere_permiso ON tiempo.aprobacion_ausencia
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('aprobacion_ausencia_lectura')
      OR personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion')
    )
  );
