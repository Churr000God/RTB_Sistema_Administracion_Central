-- 126_tiempo_comment_parametro.sql
-- Corrige el COMMENT ON TABLE de tiempo.parametro (P-091, sub-tarea de J3.1 · congelamiento del esquema).
--
-- PROBLEMA. 02_tiempo.sql:67 pone el comentario real de la tabla; 03_parametros_ejemplo.sql:20 lo SOBRESCRIBE con un texto
-- pensado para el archivo de semillas («este archivo sólo carga valores de ejemplo, nunca los reales de operación»). Como 03_ corre
-- después de 02_, la base real quedó con el texto del archivo de semillas, que no describe la tabla. Además, la lista de claves del
-- comentario de 02_ ya no está completa (después se agregaron, entre otras, dias_habiles_correccion_marca y hora_corrida_cierre_dia).
--
-- QUÉ HACE. Solo COMMENT ON TABLE. Sin ALTER, sin columnas, sin datos, sin permisos. El texto no enumera claves: remite al diccionario,
-- que es la referencia viva, para no volver a desfasarse.
--
-- tiempo.persona (la otra mitad de P-091): su comentario actual en la base («Stub. Identificador opaco...») es correcto y no menciona
-- el proyecto escolar; verificado el 23-oct-2026 contra pg_description. No se toca.
--
-- Idempotente: COMMENT ON reemplaza el texto; correrlo dos veces deja el mismo resultado.
-- Depende de: 02_tiempo.sql, 03_parametros_ejemplo.sql, 60_tiempo_parametro_vigencia_y_autor.sql

COMMENT ON TABLE tiempo.parametro IS
  'Valor de regla de negocio, configurable y versionado por vigencias (vigente_desde / vigente_hasta, borde inclusivo, mismo '
  'criterio que tiempo.tope_legal). Se cambia con fn_parametro_actualizar_valor, nunca editando la fila. Catálogo de claves '
  'conocidas: SCJ-DIC-01 §IV y SCJ-ESP-01 §VI.9.';
