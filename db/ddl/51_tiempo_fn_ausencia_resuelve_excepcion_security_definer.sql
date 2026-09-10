-- 51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql
-- Fix de RLS real (hallazgo propio al probar 50_tiempo_fn_ausencia_resolver.sql): resolver una
-- ausencia dispara trg_aprobacion_ausencia_actualiza_ausencia -> UPDATE tiempo.ausencia.
-- estado_autorizacion -> trg_ausencia_resuelve_excepcion, que además de UPDATE tiempo.excepcion
-- (cubierto por excepcion_edicion, 48_*.sql) hace INSERT INTO tiempo.dia ... ON CONFLICT DO UPDATE
-- para materializar el día (SCJ-PRO-12/SCJ-PRA-01 #13). tiempo.dia sólo tiene policy de SELECT
-- (44_tiempo_rls_dia_corrida_batch_lectura.sql) -- a propósito, "sólo los batches (service_role)
-- escriben ahí" -- pero fn_ausencia_resuelve_excepcion no es SECURITY DEFINER, corre con los
-- privilegios del humano que resolvió la ausencia (get_caller_client), y ese humano nunca debe
-- tener INSERT/UPDATE directo en tiempo.dia. Sin este fix, CUALQUIER resolución de ausencia
-- (autorizada o rechazada, el loop corre para ambas) revienta con "new row violates row-level
-- security policy for table dia" -- habría roto igual al endpoint viejo de 2 llamadas REST, esto
-- no es un problema del RPC nuevo, sólo lo destapó su primera prueba funcional real.
--
-- SECURITY DEFINER + search_path fijo (tiempo, pg_temp -- no necesita personas, sólo toca tiempo.
-- excepcion/tiempo.dia/tiempo.jornada_asignada/tiempo.patron_semanal/tiempo.ausencia, todas del
-- mismo esquema), mismo criterio que fn_marca_valida_revision: la función necesita tocar más de lo
-- que el rol invocador debe tener directo, sin abrirle RLS de tiempo.dia a humanos en general --
-- sigue sin policy de INSERT/UPDATE para authenticated, sólo esta escritura puntual y legítima
-- corre con los privilegios de su dueño (postgres, bypassrls).
-- Depende de: 02_tiempo.sql, 44_tiempo_rls_dia_corrida_batch_lectura.sql,
--   48_tiempo_rls_correccion_excepcion.sql, 49_tiempo_rls_ausencia_aprobacion.sql

ALTER FUNCTION tiempo.fn_ausencia_resuelve_excepcion()
  SECURITY DEFINER
  SET search_path = tiempo, pg_temp;

COMMENT ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() IS
  'Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion '
  'por día sin checada, la resuelve sola -- RH no tiene que cerrarla a mano. Un rechazo también '
  'cuenta como resolución (ya hay una decisión humana, aunque haya sido negativa). Sólo pendiente '
  'no toca nada. Además materializa tiempo.dia para cada fecha del rango (SCJ-PRO-12, SCJ-PRA-01 '
  '#13) -- vacaciones/permiso_con_goce/incapacidad cuentan como jornada completa trabajada; '
  'permiso_sin_goce y falta rechazada, cero. SECURITY DEFINER (2026-09-06): necesita escribir '
  'tiempo.dia, que humanos nunca deben tocar por RLS directo -- ver '
  '51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql.';
