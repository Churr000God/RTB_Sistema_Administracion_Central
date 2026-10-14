-- 105_funciones_revoca_execute_triggers_y_helpers.sql
-- Inventario de EXECUTE por catálogo (14-oct-2026, solo lectura; ver db/ensayos/README.md): de las 81 funciones propias, estas nunca recibieron REVOKE y siguen ejecutables por PUBLIC (que incluye
-- anon). Ninguna es llamada por el backend con anon; las funciones de trigger no las llama nadie. Aprobado por security; el usuario autorizó redactar y ensayar (la aplicación es con su OK).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 105_*.sql`. Solo REVOKE/GRANT de EXECUTE: ningún cuerpo, ningún atributo, ninguna policy ni tabla cambia. Idempotente.
--
-- QUÉ HACE
--   (1) 13 funciones de TRIGGER: REVOKE EXECUTE FROM PUBLIC, anon, authenticated, service_role. Los triggers siguen disparando (PostgreSQL comprueba EXECUTE al CREATE TRIGGER, no al disparar;
--       las otras 31 funciones de trigger ya estaban así desde 88_/94_/97_/101_/104_ y siguen funcionando). Una llamada directa ya es imposible («trigger functions can only be called as triggers»).
--         personas: fn_bitacora_inmutable, fn_bitacora_puesto_permiso_inmutable, fn_bitacora_sincroniza_persona, fn_persona_sincroniza_baja, fn_persona_sincroniza_tiempo,
--                   fn_puesto_permiso_sincroniza, fn_usuario_bitacora_alta
--         tiempo:   fn_aprobacion_ausencia_actualiza_ausencia, fn_ausencia_resuelve_excepcion, fn_correccion_recalcula_tramo, fn_correccion_valida, fn_marca_valida_revision,
--                   fn_patron_semanal_valida_tope_legal
--   (2) personas.fn_caller_activo() y personas.fn_caller_tiene_permiso(text): REVOKE EXECUTE FROM PUBLIC, anon y GRANT EXECUTE TO authenticated, service_role EXPLÍCITO. OJO (lección): su ACL era NULL
--       (= solo PUBLIC), así que authenticated y service_role las tenían ÚNICAMENTE por PUBLIC; revocar PUBLIC sin el GRANT explícito las dejaría sin EXECUTE y rompería las 76 policies. Las usan
--       las policies de RLS y las funciones DEFINER/INVOKER; anon ya no puede tocar ninguna tabla (100_/102_/103_), así que nunca evalúa esas policies.
--   (3) tiempo.fn_terminal_config_catalogo(): REVOKE EXECUTE FROM authenticated, service_role (PUBLIC y anon ya estaban revocados por 89_; se repite para que el archivo sea autocontenido). Nadie la llama como RPC (grep de backend/ y frontend/: cero); solo la usan
--       fn_terminal_config_actualizar y fn_terminal_config_valor, ambas SECURITY DEFINER que corren como el dueño (el dueño conserva EXECUTE).
--
-- LO QUE NO HACE (con razón)
--   * tiempo.fn_dia_calcular_armado_tramos: se CONSERVA tal cual (authenticated y service_role): backend/app/routers/dias.py:167 la llama con service_role (db_servicio) y dias.py:359 con el caller.
--   * public.rls_auto_enable(): helper de Supabase (event trigger, search_path = pg_catalog, dueño postgres) ejecutable por PUBLIC; no es nuestro ni se llama por la API; no se prueba aquí que el event
--     trigger siga disparando sin EXECUTE de PUBLIC -> excepción documentada en la sección 70 del verificador.
--   * Los search_path de las INVOKER (fn_caller_tiene_permiso) van en 106_ (ALTER FUNCTION … SET), aparte y medido.
--   * ALTER DEFAULT PRIVILEGES ... ON FUNCTIONS: no se toca; un default por esquema no quita el EXECUTE de PUBLIC que PostgreSQL concede a toda función nueva (y hay defaults de supabase_admin y de
--     postgres en public/storage). La regla pasa a ser explícita por migración: toda migración que CREE una función hace su `REVOKE EXECUTE … FROM PUBLIC` y concede lo mínimo (README de ensayos y
--     sección 70 del verificador).
--
-- Inventario de RLS/tablas: sin cambios.
-- REVERSA EXACTA (estado previo de (1) y (2): ACL NULL, es decir EXECUTE para PUBLIC): `GRANT EXECUTE ON FUNCTION <cada una de las 15 de (1) y (2)> TO PUBLIC;` (los GRANT explícitos a
-- authenticated/service_role del punto (2) pueden quedarse: no cambian lo efectivo). De (3): `GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_catalogo() TO authenticated, service_role;`
-- (89_ ya había revocado PUBLIC y anon; NO volver a conceder PUBLIC).
-- db/ensayos/ensayo_105.sql ejecuta la reversa dentro de su transacción y comprueba que el estado EFECTIVO queda idéntico al previo.

-- (1) funciones de trigger
REVOKE EXECUTE ON FUNCTION personas.fn_bitacora_inmutable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_bitacora_puesto_permiso_inmutable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_bitacora_sincroniza_persona() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_sincroniza_baja() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_sincroniza_tiempo() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_puesto_permiso_sincroniza() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_usuario_bitacora_alta() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_correccion_recalcula_tramo() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_correccion_valida() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_valida_revision() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_patron_semanal_valida_tope_legal() FROM PUBLIC, anon, authenticated, service_role;

-- (2) ayudantes de RLS: PUBLIC y anon fuera; authenticated y service_role EXPLÍCITOS (antes solo por PUBLIC)
GRANT EXECUTE ON FUNCTION personas.fn_caller_activo() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_tiene_permiso(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_activo() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_tiene_permiso(text) FROM PUBLIC, anon;

-- (3) catálogo estático sin llamadores como RPC
REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_config_catalogo() FROM PUBLIC, anon, authenticated, service_role;
