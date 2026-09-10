-- 32_puesto_administrador_generico_proteccion.sql
-- Pedido de seguridad del usuario (2026-09-05): el puesto administrador de bootstrap (el que crea
-- 26_puesto_permiso_bootstrap_admin_generico.sql, hoy "Gerente o Encargado de TI" con los 16
-- permisos completos y la única asignación real que existe) no debe poder quedar sin acceso por
-- acción de nadie -- ni de otro puesto (RH y Gerente General también tienen puesto_permiso_
-- edicion), ni de sí mismo. Cubre tres vectores, aprobados en dos rondas por el usuario:
-- revocarle un permiso (bloques 1-4), cortarle la asignación (bloque 5) y desactivar el puesto
-- (bloque 6). Diseñado en conjunto con "security" antes de escribir una sola línea (ver hilo de
-- coordinación db<->security, 2026-09-05).
--
-- Por qué NO identificar el puesto por nombre_puesto: es editable vía PATCH /api/puestos/{id}
-- (backend/app/routers/puestos.py, requiere sólo puesto_edicion) y el nombre exacto podría ni
-- existir en otro despliegue -- exactamente la misma clase de fragilidad que ya se evitó en otras
-- partes del proyecto. Se agrega una columna booleana dedicada.
--
-- Depende de: 14_personas_puesto.sql, 17_personas_asignacion.sql,
--   19_asignacion_fn_cambiar_puesto.sql, 26_puesto_permiso_bootstrap_admin_generico.sql,
--   31_personas_rls_permiso_especifico.sql

-- ============================================================================
-- 1) Columna nueva + backfill (por nombre, UNA sola vez, antes de que exista el trigger de abajo)
--    + índice único parcial (a lo sumo un puesto administrador genérico, mismo idioma que
--    ux_puesto_tope_unico en 14_personas_puesto.sql).
-- ============================================================================

ALTER TABLE personas.puesto
  ADD COLUMN es_administrador_generico boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN personas.puesto.es_administrador_generico IS
  'true sólo en el puesto de bootstrap que siembra 26_puesto_permiso_bootstrap_admin_generico.sql.
  Inmutable después del backfill inicial (ver trigger trg_puesto_administrador_generico_inmutable
  más abajo, en este mismo archivo) -- ni la app ni un UPDATE directo por PostgREST ni service_role
  pueden cambiarla después de sembrada. Existe para identificar el puesto administrador sin
  depender de nombre_puesto (editable, frágil) en las policies RLS que lo protegen de
  auto-bloqueo (ver bloques 3 y 4 de este archivo).';

-- Backfill por nombre: único momento en que este archivo usa nombre_puesto -- de acá en adelante
-- toda la lógica (RLS incluida) lee sólo la columna, nunca el nombre. Funciona igual en un
-- despliegue nuevo (26_ crea la fila con el default false; este UPDATE la marca true después) que
-- en el Supabase actual (26_ ya corrió, esta fila ya existe).
UPDATE personas.puesto
SET es_administrador_generico = true
WHERE nombre_puesto = 'Gerente o Encargado de TI'
  AND NOT es_administrador_generico;

-- A lo sumo un puesto marcado -- mismo idioma que ux_puesto_tope_unico (14_personas_puesto.sql):
-- índice único sobre una expresión constante, acotado por el predicado parcial.
CREATE UNIQUE INDEX ux_puesto_administrador_generico_unico
  ON personas.puesto ((true))
  WHERE es_administrador_generico;

-- ============================================================================
-- 2) Inmutabilidad de la columna: BEFORE UPDATE aborta cualquier cambio, incluido service_role.
--    Mismo patrón que fn_bitacora_inmutable (09_personas_bitacora_inmutable.sql). Se crea DESPUÉS
--    del backfill de arriba a propósito -- si no, el propio backfill se bloquearía a sí mismo.
--    Sin esto, cualquiera con puesto_edicion podría apagarle el flag al puesto protegido (y
--    después revocarle todo tranquilo, esquivando las policies de los bloques 3 y 4) o
--    prendérselo a su propio puesto para volverse intocable -- RLS por sí sola (puesto_update_
--    requiere_permiso, 31_) no distingue qué columna cambia, sólo si el caller tiene el permiso.
-- ============================================================================

CREATE FUNCTION personas.fn_puesto_administrador_generico_inmutable()
RETURNS trigger AS $$
BEGIN
  IF NEW.es_administrador_generico IS DISTINCT FROM OLD.es_administrador_generico THEN
    RAISE EXCEPTION
      'personas.puesto.es_administrador_generico es inmutable después del backfill inicial '
      '(fila %)', OLD.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_puesto_administrador_generico_inmutable
  BEFORE UPDATE ON personas.puesto
  FOR EACH ROW
  WHEN (OLD.es_administrador_generico IS DISTINCT FROM NEW.es_administrador_generico)
  EXECUTE FUNCTION personas.fn_puesto_administrador_generico_inmutable();

COMMENT ON FUNCTION personas.fn_puesto_administrador_generico_inmutable() IS
  'Aborta cualquier UPDATE que cambie es_administrador_generico, incluido service_role. Si algún '
  'día hace falta re-designar el puesto administrador, es DDL directo (DROP/CREATE de este '
  'trigger a propósito), nunca un camino vivo de la aplicación.';

REVOKE EXECUTE ON FUNCTION personas.fn_puesto_administrador_generico_inmutable() FROM PUBLIC;

-- ============================================================================
-- 3) personas.bitacora_movimiento_puesto_permiso -- cierra el vector real (mismo del hallazgo
--    crítico anterior): INSERT directo por PostgREST con tipo_movimiento='revocado' apuntando al
--    puesto protegido. Se reemplaza la policy de INSERT de 31_*.sql (DROP + CREATE, mismo patrón
--    ya usado ahí, no se edita ese archivo).
-- ============================================================================

DROP POLICY IF EXISTS bitacora_puesto_permiso_insert_requiere_permiso ON personas.bitacora_movimiento_puesto_permiso;

CREATE POLICY bitacora_puesto_permiso_insert_requiere_permiso ON personas.bitacora_movimiento_puesto_permiso
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
    AND NOT (
      tipo_movimiento = 'revocado'
      AND EXISTS (
        SELECT 1 FROM personas.puesto pu
        WHERE pu.id = puesto_id AND pu.es_administrador_generico
      )
    )
  );

-- ============================================================================
-- 4) personas.puesto_permiso -- defensa en profundidad, por si algo escribe directo sin pasar por
--    la bitácora (no es el flujo normal de la app, pero nada en GRANT/RLS lo impide por sí solo,
--    ver 22_personas_puesto_permiso.sql). UPDATE: se deja pasar activo=true (otorgar/reactivar, sin
--    riesgo) y se rechaza específicamente la transición a activo=false para el puesto protegido.
--    DELETE: se rechaza completo -- borrar la fila también "revoca" en la práctica, no hay caso de
--    "borrar es agregar". Se reemplazan las policies de 31_*.sql (mismo patrón DROP + CREATE).
-- ============================================================================

DROP POLICY IF EXISTS puesto_permiso_update_requiere_permiso ON personas.puesto_permiso;

CREATE POLICY puesto_permiso_update_requiere_permiso ON personas.puesto_permiso
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
    AND NOT (
      activo = false
      AND EXISTS (
        SELECT 1 FROM personas.puesto pu
        WHERE pu.id = puesto_id AND pu.es_administrador_generico
      )
    )
  );

DROP POLICY IF EXISTS puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso;

CREATE POLICY puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso
  FOR DELETE USING (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
    AND NOT EXISTS (
      SELECT 1 FROM personas.puesto pu
      WHERE pu.id = puesto_id AND pu.es_administrador_generico
    )
  );

-- ============================================================================
-- 5) Extensión 2026-09-05 (usuario aprobó cerrar los dos vectores adyacentes señalados arriba):
--    personas.asignacion -- PATCH /api/asignaciones/{id}/terminar hace un UPDATE plano
--    (SET vigente_hasta = ...) sobre la fila vigente. Se rechaza específicamente esa transición
--    (vigente_hasta NULL -> no NULL) cuando el puesto_id de la fila es el puesto marcado --  deja
--    pasar cualquier otro UPDATE (ej. actualizado_en) sin tocar vigente_hasta.
--
--    fn_asignacion_cambiar_puesto (19_asignacion_fn_cambiar_puesto.sql) NO es un vector aparte:
--    es SECURITY INVOKER a propósito (comentario propio del archivo: "para que la RLS de
--    personas.asignacion siga aplicando igual que cualquier otro INSERT/UPDATE directo") y hace
--    exactamente el mismo UPDATE (SET vigente_hasta = p_fecha WHERE id = p_asignacion_id) como
--    primer paso de su transacción -- esta policy lo alcanza igual, sin necesidad de tocar el RPC.
--    Si esa UPDATE es rechazada por RLS, la función aborta con excepción y el INSERT de la nueva
--    asignación (paso 2) nunca llega a correr -- la persona queda donde estaba, no a medio mover.
-- ============================================================================

DROP POLICY IF EXISTS asignacion_update_requiere_permiso ON personas.asignacion;

CREATE POLICY asignacion_update_requiere_permiso ON personas.asignacion
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'))
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('asignacion_edicion')
    AND NOT (
      vigente_hasta IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM personas.puesto pu
        WHERE pu.id = puesto_id AND pu.es_administrador_generico
      )
    )
  );

-- ============================================================================
-- 6) Extensión 2026-09-05: personas.puesto -- PATCH /api/puestos/{id}/estado con activo=false ya
--    está bloqueado a nivel app por DP1/DP3 (backend/app/routers/puestos.py: no desactiva si hay
--    asignación vigente o puesto_permiso activo, y el puesto marcado siempre tiene ambos) -- pero
--    ese chequeo es Python, no RLS, y un UPDATE directo por PostgREST a personas.puesto lo esquiva
--    igual que ya esquivaba el hallazgo crítico original. Mismo patrón que el bloque 4
--    (puesto_permiso): se deja pasar activo=true (reactivar, sin riesgo) y se rechaza
--    específicamente la transición a activo=false para el puesto marcado.
-- ============================================================================

DROP POLICY IF EXISTS puesto_update_requiere_permiso ON personas.puesto;

CREATE POLICY puesto_update_requiere_permiso ON personas.puesto
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'))
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('puesto_edicion')
    AND NOT (activo = false AND es_administrador_generico)
  );

-- ============================================================================
-- Fuera de alcance de este archivo, señalado para que quede el rastro (no se toca acá):
--   - DELETE físico de la fila del puesto administrador ya es imposible sin cambios nuevos: tiene
--     FK activas (asignacion, puesto_permiso, bitacora_movimiento_puesto_permiso) sin ON DELETE
--     CASCADE -- cualquier DELETE falla por violación de FK antes de llegar siquiera a RLS.
-- ============================================================================
