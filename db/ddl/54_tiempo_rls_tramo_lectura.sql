-- 54_tiempo_rls_tramo_lectura.sql
-- RLS de lectura humana para tiempo.tramo (SCJ-PRO-12, cierre de día). RLS ya habilitada sin
-- policy desde 41_tiempo_rls_deny_default.sql.
--
-- Confirmado en el catálogo (personas.permiso): tramo sólo tiene tramo_lectura, sin ningún código
-- de edición -- coincide con lo documentado en 33_permiso_tiempo_migracion_inicial.sql ("marca/
-- tramo/clasificacion_de_tiempo/dia: sólo existe la versión lectura, el sistema las calcula
-- solo, nadie las edita a mano"). Mismo criterio ya aplicado a tiempo.dia en 44_tiempo_rls_dia_
-- corrida_batch_lectura.sql -- sin el OR-con-edición de 39_/46_/48_*.sql porque no hay nada que
-- OR-ear.
--
-- Sin INSERT/UPDATE/DELETE para humanos: el batch de cierre de día (SCJ-PRO-12, aún sin construir)
-- va a correr con service_role (bypassa RLS por completo, mismo criterio que el batch de_confianza
-- ya usa) -- ningún humano escribe tramo directo, ni siquiera el botón manual (ese sólo dispara el
-- mismo batch).
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql, 41_tiempo_rls_deny_default.sql

CREATE POLICY tramo_select_requiere_permiso ON tiempo.tramo
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('tramo_lectura')
  );
