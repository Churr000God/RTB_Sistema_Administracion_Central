-- 79_tiempo_fn_dia_calcular_armado_tramos_grant_service_role.sql
-- Bloqueador real encontrado por backend (2026-09-15): GET /api/dias suma el flag
-- tiene_marcas_por_armar llamando tiempo.fn_dia_calcular_armado_tramos por cada día 'cerrado' de
-- la página, vía get_service_client (mismo criterio que el resto de ese endpoint de
-- enriquecimiento, que ya usa service_role para saltarse RLS de marca/correccion). La función sólo
-- tenía GRANT EXECUTE ... TO authenticated (65_*.sql:181-182) -- service_role no es miembro de
-- authenticated en Supabase, así que la llamada tiraba "permission denied for function".
--
-- Sin riesgo nuevo: fn_dia_calcular_armado_tramos es STABLE, cero escritura (65_*.sql), SECURITY
-- INVOKER -- sin ALTER FUNCTION posterior (verificado por grep, cero resultados) -- este GRANT
-- sólo destraba la ejecución de una consulta de sólo lectura para un rol que ya bypassea RLS a
-- nivel de rol. No cambia superficie de escritura ni de autorización real (dia_revision_edicion
-- sigue siendo la que gatea fn_dia_revisar, la única que escribe).
--
-- Depende de: 65_tiempo_tramo_previsualizar.sql
-- Justificación: ninguna nueva, extiende el GRANT ya existente a un segundo rol lector.

GRANT EXECUTE ON FUNCTION tiempo.fn_dia_calcular_armado_tramos(bigint) TO service_role;
