-- 106_personas_fn_caller_tiene_permiso_search_path.sql
-- search_path fijo para personas.fn_caller_tiene_permiso(text), la única función INVOKER de apoyo a RLS sin él. Es la que usan 63 policies y 9 funciones (varias SECURITY DEFINER): al ser INVOKER sin
-- proconfig, cuando se la invoca desde un contexto DEFINER resuelve nombres con el search_path de la SESIÓN (controlable por quien tenga una conexión SQL directa). Aprobado por security; el usuario
-- autorizó redactar y ensayar (la aplicación es con su OK).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 106_*.sql`. Solo ALTER FUNCTION … SET: NO es CREATE OR REPLACE (no reescribe el cuerpo ni resetea atributos). Idempotente.
--
-- ALCANCE (corrige mi inventario del 14-oct-2026): personas.fn_persona_de_usuario(uuid) y personas.fn_usuario_es_administrador_generico(uuid) YA TIENEN search_path = personas, pg_temp (proconfig
-- verificado en catálogo); solo fn_caller_tiene_permiso carecía de él. Revisión línea por línea de su cuerpo (SQL, STABLE, INVOKER): usa únicamente objetos CALIFICADOS (personas.usuario, personas.asignacion,
-- personas.puesto_permiso, personas.permiso, personas.puesto) y auth.uid() calificada; los operadores y COALESCE/EXISTS salen de pg_catalog (siempre en la ruta). Ningún nombre sin calificar fuera de
-- personas. No es inlineable (CTE recursiva + subconsultas), así que el SET no cambia el plan por inlining; el ensayo mide EXPLAIN (ANALYZE, BUFFERS) antes y después sobre consultas con RLS.
--
-- REVERSA: ALTER FUNCTION personas.fn_caller_tiene_permiso(text) RESET search_path;

ALTER FUNCTION personas.fn_caller_tiene_permiso(text) SET search_path = personas, pg_temp;
