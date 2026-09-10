-- 47_tiempo_excepcion_revoca_anon.sql
-- Fix interino de seguridad (hallazgo de security, 2026-09-06): tiempo.excepcion quedó sin RLS
-- desde 42_tiempo_rls_persona_lectura_y_excepcion_sin_rls.sql (necesario ahí porque
-- fn_correccion_recalcula_tramo y fn_ausencia_resuelve_excepcion, ninguna SECURITY DEFINER, hacen
-- UPDATE real sobre esta tabla y RLS los habría silenciado) pero nunca tuvo ningún REVOKE del
-- GRANT ALL schema-wide de 38_tiempo_permisos.sql -- a diferencia de tiempo.marca/correccion/
-- movimiento_de_saldo, que sí se endurecieron ahí y en 41_*.sql. Con backend/app/routers/
-- marcas.py ya leyendo tiempo.excepcion en producción (SCJ-PRO-07), el hueco es real: anon sin
-- login puede hoy INSERT/SELECT/UPDATE/DELETE directo por PostgREST -- incluido poder borrar una
-- excepcion pendiente y hacer desaparecer la señal de revisión.
--
-- REVOKE ALL de anon únicamente -- authenticated se deja intacto a propósito: los triggers de
-- correccion/ausencia siguen sin SECURITY DEFINER y corren con los privilegios de ese caller
-- humano (get_caller_client) hasta que Fase 3 diseñe la RLS real de excepcion junto con
-- correccion/ausencia (36_*.sql/46_*.sql dejaron esto pendiente a propósito, ver comentario de
-- 46_tiempo_rls_marca_excepcion_humano.sql). Revocarle a authenticated ahora rompería esos
-- UPDATE sin ninguna policy que los reemplace -- interino real, no la solución final.
-- Depende de: 38_tiempo_permisos.sql, 42_tiempo_rls_persona_lectura_y_excepcion_sin_rls.sql

REVOKE ALL ON tiempo.excepcion FROM anon;
