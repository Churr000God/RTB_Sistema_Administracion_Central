-- 42_tiempo_rls_persona_lectura_y_excepcion_sin_rls.sql
-- Fix de 2 problemas encontrados por security en 41_tiempo_rls_deny_default.sql (ya aplicado
-- contra Supabase real -- se corrige hacia adelante, no se reescribe esa migración, mismo criterio
-- que el resto del proyecto: 31_*.sql corrigió a 06_*.sql sin tocarlo, 28_*.sql corrigió a 23_*.sql
-- sin tocarlo).
--
-- 1) BLOQUEANTE: tiempo.persona (el stub de la frontera, SCJ-FRO-01) quedó con RLS habilitada sin
--    ninguna policy en 41_*.sql -- deny-by-default también bloqueaba el único SELECT legítimo que
--    ya existe: backend/app/routers/jornada_asignada.py::_validar_persona_existe lee tiempo.persona
--    con get_caller_client (rol authenticated, sujeto a RLS), y sin policy ese SELECT siempre
--    devolvía vacío -- CUALQUIER persona_id válida tiraba 422 "La persona no existe". Fix: policy
--    de SELECT con sólo fn_caller_activo(), sin permiso específico -- tiempo.persona no tiene
--    ningún dato sensible (sólo id uuid, el ancla opaca de la frontera), cualquier caller humano
--    activo puede confirmar que un persona_id existe. Sin INSERT/UPDATE/DELETE: nadie humano debe
--    tocar esta tabla -- la puebla el generador de datos sintéticos (service_role, bypassa RLS).
--
-- 2) tiempo.excepcion NO debía llevar ENABLE ROW LEVEL SECURITY en 41_*.sql -- el comentario de
--    ese mismo archivo (líneas 27-29) ya decía "no se toca a propósito, tiene UPDATE legítimo" pero
--    la sección ALTER TABLE la habilitó de todos modos (inconsistencia entre el comentario y el
--    código -- error de quien escribió 41_, no una decisión). fn_correccion_recalcula_tramo
--    (02_tiempo.sql) y fn_ausencia_resuelve_excepcion (02_tiempo.sql) hacen UPDATE real sobre
--    tiempo.excepcion, ninguna es SECURITY DEFINER (verificado) -- corren con los privilegios de
--    quien disparó el trigger, y con RLS habilitada sin policy esos UPDATE se silencian (0 filas
--    afectadas, sin error) en vez de fallar ruidosamente. Se revierte con DISABLE ROW LEVEL
--    SECURITY -- vuelve exactamente al estado que el comentario original de 41_*.sql pedía.
-- Depende de: 41_tiempo_rls_deny_default.sql

CREATE POLICY persona_select_caller_activo ON tiempo.persona
  FOR SELECT USING (personas.fn_caller_activo());

ALTER TABLE tiempo.excepcion DISABLE ROW LEVEL SECURITY;
