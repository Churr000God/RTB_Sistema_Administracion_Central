-- WITH CHECK VIGENTE de personas.bitacora_insert_requiere_permiso antes de 129_ (la policy no tenía COMMENT). Misma forma de fuente que 92_: pg_get_expr da
-- exactamente el texto de la base real del 28-oct-2026 (comprobado en ensayo_129, caso R1).
-- REVERSA de 129_, EJECUTABLE: psql --single-transaction -v ON_ERROR_STOP=1 -f db/ensayos/vigente_129_bitacora_insert_policy.sql
ALTER POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
    AND registrado_por = auth.uid()
    AND tipo_movimiento IN ('suspension', 'reactivacion', 'baja_definitiva')
  );
COMMENT ON POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona IS NULL;
