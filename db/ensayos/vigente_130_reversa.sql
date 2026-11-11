-- Reversa EJECUTABLE de db/ddl/130_personas_puesto_permiso_regla_autootorgamiento.sql (estado previo, con el texto exacto de 22_/24_/31_/32_/102_/105_).
-- Correr SIEMPRE dentro de una transacción: psql --single-transaction -v ON_ERROR_STOP=1 -f db/ensayos/vigente_130_reversa.sql
-- La usa ensayo_130.sql (fase R y, si 130_ ya está aplicada, para volver al estado previo dentro del ensayo).

DROP TRIGGER trg_bitacora_puesto_permiso_regla_autootorgamiento ON personas.bitacora_movimiento_puesto_permiso;
DROP FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento();

ALTER FUNCTION personas.fn_puesto_permiso_sincroniza() SECURITY INVOKER RESET search_path;
COMMENT ON FUNCTION personas.fn_puesto_permiso_sincroniza() IS
  'Implementa SCJ-PRO-05 G8 ("crea o reactiva la fila"): ON CONFLICT (puesto_id, codigo) DO UPDATE '
  'resuelve en una sola sentencia el caso de otorgar un permiso ya revocado antes, apoyado en '
  'uq_puesto_permiso_puesto_codigo (22_personas_puesto_permiso.sql). puesto_permiso.activo es '
  '[CALCULADO] — nunca se actualiza con UPDATE directo, sólo insertando en la bitácora.';

GRANT INSERT, UPDATE, DELETE ON personas.puesto_permiso TO authenticated, service_role;

CREATE POLICY puesto_permiso_insert_requiere_permiso ON personas.puesto_permiso
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  );

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

CREATE POLICY puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso
  FOR DELETE USING (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
    AND NOT EXISTS (
      SELECT 1 FROM personas.puesto pu
      WHERE pu.id = puesto_id AND pu.es_administrador_generico
    )
  );
