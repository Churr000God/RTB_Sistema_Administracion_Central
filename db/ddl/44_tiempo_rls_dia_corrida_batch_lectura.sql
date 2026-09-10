-- 44_tiempo_rls_dia_corrida_batch_lectura.sql
-- RLS de lectura humana para el panel de estado del batch de_confianza (SCJ-PRO-14) y de las dos
-- tablas que comparte con el resto de los batches (SCJ-PRO-12/13, aún no construidos). Ambas
-- tablas ya tenían RLS habilitada sin policy desde 41_tiempo_rls_deny_default.sql (deny-by-
-- default) -- este archivo agrega sólo SELECT. Sin INSERT/UPDATE/DELETE para humanos en ninguna
-- de las dos: quien escribe tiempo.dia/tiempo.corrida_batch es siempre el batch (service_role,
-- bypassa RLS por completo) -- ningún humano edita estas tablas a mano, mismo criterio que
-- marca/tramo/clasificacion_de_tiempo (33_permiso_tiempo_migracion_inicial.sql: "el sistema las
-- calcula solo, nadie las edita a mano").
--
-- tiempo.dia: SELECT con fn_caller_activo() + fn_caller_tiene_permiso('dia_lectura') -- SIN el OR
-- con un código de edición como en 39_tiempo_rls_jornada_patron.sql: confirmado en el catálogo
-- (personas.permiso) que dia_edicion no existe -- sólo dia_lectura, exactamente como documenta el
-- comentario de 33_*.sql citado arriba. No hay nada que OR-ear.
--
-- tiempo.corrida_batch: SELECT con sólo fn_caller_activo(), sin permiso específico -- confirmado
-- en el catálogo que no existe ningún código corrida_batch_lectura/edicion (ni falta hacerlo: es
-- un panel de estado operativo -- fecha/tipo_batch/estado/intentos de una corrida -- no un dato de
-- negocio sensible). Mismo criterio "gate débil a propósito" que ya documenta CLAUDE.md para
-- personas/usuarios/movimientos.
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql, 41_tiempo_rls_deny_default.sql

CREATE POLICY dia_select_requiere_permiso ON tiempo.dia
  FOR SELECT USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_lectura')
  );

CREATE POLICY corrida_batch_select_caller_activo ON tiempo.corrida_batch
  FOR SELECT USING (personas.fn_caller_activo());
