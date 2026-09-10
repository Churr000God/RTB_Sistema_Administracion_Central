-- 52_tiempo_ausencia_bloquea_update_directo_estado.sql
-- Fix de seguridad (hallazgo de security, 2026-09-06): la policy de UPDATE de tiempo.ausencia
-- (49_tiempo_rls_ausencia_aprobacion.sql) permite cambiar CUALQUIER columna con sólo
-- ausencia_edicion, incluido estado_autorizacion directo por PostgREST -- se salta las
-- validaciones SCJ03 (ya resuelta)/SCJ04 (tipo inválido) de tiempo.fn_ausencia_resolver
-- (50_*.sql) y no deja rastro en tiempo.aprobacion_ausencia, rompiendo el propio comentario de la
-- columna ("materializado de sólo lectura -- escrito únicamente por trigger", 02_tiempo.sql). Con
-- el SECURITY DEFINER agregado en 51_*.sql a fn_ausencia_resuelve_excepcion, ese UPDATE directo
-- ahora sí completaba la cadena de triggers hasta el final sin ningún tropiezo de RLS -- antes
-- estaba roto igual, pero por otro motivo (reventaba en tiempo.dia), lo que lo tapaba.
--
-- Fix, mismo patrón que ya usa este archivo (SECURITY DEFINER para triggers que necesitan tocar
-- más de lo que el rol invocador debe tener directo) + REVOKE de columna específica:
--
-- 1) fn_aprobacion_ausencia_actualiza_ausencia SECURITY DEFINER: sigue siendo el único camino real
--    para tocar estado_autorizacion, ahora corriendo con los privilegios de su dueño en vez de los
--    del humano que insertó la aprobación -- no cambia su lógica ni su disparo (sigue AFTER
--    INSERT OR UPDATE OF decision ON tiempo.aprobacion_ausencia), sólo su contexto de privilegio.
-- 2) REVOKE UPDATE (estado_autorizacion) ON tiempo.ausencia FROM authenticated: revoca sólo esa
--    columna del GRANT ALL de tabla completa que ya tenía (38_tiempo_permisos.sql) -- tipo_de_
--    ausencia sigue editable directo (lo sigue necesitando tiempo.fn_ausencia_resolver para la
--    reclasificación, que corre SECURITY INVOKER a propósito, respetando ausencia_edicion). Con
--    esto, ningún UPDATE humano -- ni por el RPC, ni por PostgREST directo -- puede tocar
--    estado_autorizacion; el único camino que queda es el trigger, ahora con privilegio propio.
-- Depende de: 02_tiempo.sql, 38_tiempo_permisos.sql, 49_tiempo_rls_ausencia_aprobacion.sql,
--   50_tiempo_fn_ausencia_resolver.sql, 51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql

ALTER FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia()
  SECURITY DEFINER
  SET search_path = tiempo, pg_temp;

COMMENT ON FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia() IS
  'Recalcula ausencia.estado_autorizacion desde su cadena de pasos: cualquier rechazo cierra en '
  '''rechazada''; todos los pasos en ''autorizada'' cierra en ''autorizada''; cualquier otro caso '
  'se queda ''pendiente''. SECURITY DEFINER (2026-09-06): es el único camino legítimo para tocar '
  'estado_autorizacion -- authenticated ya no tiene UPDATE de esa columna directo (ver '
  '52_tiempo_ausencia_bloquea_update_directo_estado.sql); sin SECURITY DEFINER, el propio trigger '
  'quedaría bloqueado por el mismo REVOKE que existe para cerrarle el paso a un humano.';

REVOKE UPDATE (estado_autorizacion) ON tiempo.ausencia FROM authenticated;
