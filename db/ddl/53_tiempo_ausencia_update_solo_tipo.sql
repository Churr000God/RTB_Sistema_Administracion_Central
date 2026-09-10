-- 53_tiempo_ausencia_update_solo_tipo.sql
-- Corrige 52_tiempo_ausencia_bloquea_update_directo_estado.sql: REVOKE UPDATE (columna) no angosta
-- un GRANT de tabla completa en Postgres -- el GRANT ALL ON ALL TABLES de 38_tiempo_permisos.sql
-- ya incluía UPDATE a nivel de tabla (cubre todas las columnas implícitamente); un REVOKE de
-- columna sólo quita un privilegio de columna que hubiera sido otorgado por separado, y acá nunca
-- existió uno -- verificado en información_schema.column_privileges después de aplicar 52_*.sql:
-- authenticated seguía con UPDATE en estado_autorizacion, sin ningún cambio real. El fix real es
-- REVOKE del privilegio de tabla completo y volver a otorgar UPDATE sólo en la columna que sí debe
-- ser editable directo (tipo_de_ausencia, para la reclasificación de tiempo.fn_ausencia_resolver).
--
-- Efecto adicional, correcto y no pedido explícitamente pero alineado con el mismo criterio de
-- seguridad: persona_id/fecha_inicio/fecha_fin/documento_ref/id tampoco quedan editables directo
-- para ningún humano -- ninguno de los procesos documentados (SCJ-PRO-08) los edita nunca, y
-- reducir a "sólo lo que un flujo real necesita" es el mismo espíritu del hallazgo de security.
-- Depende de: 38_tiempo_permisos.sql, 49_tiempo_rls_ausencia_aprobacion.sql,
--   52_tiempo_ausencia_bloquea_update_directo_estado.sql

REVOKE UPDATE ON tiempo.ausencia FROM authenticated;
GRANT UPDATE (tipo_de_ausencia) ON tiempo.ausencia TO authenticated;
