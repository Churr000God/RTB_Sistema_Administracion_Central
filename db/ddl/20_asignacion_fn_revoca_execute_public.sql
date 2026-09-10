-- 20_asignacion_fn_revoca_execute_public.sql
-- Fix de seguridad (hallazgo de auditoría, severidad baja): 19_asignacion_fn_cambiar_puesto.sql
-- otorgó EXECUTE a authenticated pero no revocó el default de Postgres que otorga EXECUTE a
-- PUBLIC en todo CREATE FUNCTION. No explotable hoy (RLS bloquea igual), pero rompe la
-- disciplina de grants explícitos del proyecto y sienta mal precedente para próximos RPCs.
-- Depende de: 19_asignacion_fn_cambiar_puesto.sql

REVOKE EXECUTE ON FUNCTION personas.fn_asignacion_cambiar_puesto(uuid, uuid, date) FROM PUBLIC;
