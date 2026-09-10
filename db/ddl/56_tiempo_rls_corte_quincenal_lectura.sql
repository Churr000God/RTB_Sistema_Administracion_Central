-- 56_tiempo_rls_corte_quincenal_lectura.sql
-- RLS de lectura humana para SCJ-PRO-13 (corte quincenal). Sin cambios de esquema -- sólo RLS, el
-- batch corre con service_role (bypassa RLS por completo, mismo criterio que de_confianza/cierre
-- de día). Las 3 tablas ya tenían RLS habilitada sin policy desde 41_tiempo_rls_deny_default.sql.
--
-- tiempo.clasificacion_de_tiempo: confirmado en el catálogo -- sólo clasificacion_de_tiempo_
-- lectura, sin edición (mismo criterio que tramo/dia, tabla calculada por el sistema). SELECT sin
-- OR-con-edición, no hay nada que OR-ear.
--
-- tiempo.movimiento_de_saldo: confirmado en el catálogo -- sí tiene movimiento_de_saldo_edicion
-- Y movimiento_de_saldo_lectura, a diferencia de tramo/dia/clasificacion_de_tiempo. SELECT con
-- lectura OR edición, mismo patrón que 39_/46_/48_*.sql. Sin INSERT/UPDATE/DELETE humano --
-- confirmado que UPDATE/DELETE ya siguen revocados de los 3 roles desde 38_tiempo_permisos.sql
-- (verificado en information_schema.role_table_grants antes de escribir este archivo, sin filas).
--
-- tiempo.banco_de_horas: confirmado en el catálogo -- sólo banco_de_horas_lectura, ningún código
-- de edición. SELECT sin OR. Sin ningún tipo de escritura humana -- sólo fn_movimiento_de_saldo_
-- actualiza_banco la toca, disparada por el INSERT de movimiento_de_saldo que hace el batch con
-- service_role (bypassa RLS igual, sea o no la función SECURITY DEFINER -- a diferencia del caso
-- de fn_ausencia_resuelve_excepcion, acá el escritor real nunca es un humano autenticado).
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql, 41_tiempo_rls_deny_default.sql

CREATE POLICY clasificacion_de_tiempo_select_requiere_permiso ON tiempo.clasificacion_de_tiempo
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('clasificacion_de_tiempo_lectura')
  );

CREATE POLICY movimiento_de_saldo_select_requiere_permiso ON tiempo.movimiento_de_saldo
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('movimiento_de_saldo_lectura')
      OR personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion')
    )
  );

CREATE POLICY banco_de_horas_select_requiere_permiso ON tiempo.banco_de_horas
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('banco_de_horas_lectura')
  );
