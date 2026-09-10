-- 41_tiempo_rls_deny_default.sql
-- Fix de seguridad URGENTE (hallazgo crítico de security, 2026-09-06): 38_tiempo_permisos.sql dio
-- GRANT ALL schema-wide a anon Y authenticated sobre TODAS las tablas de tiempo, pero para esta
-- fecha sólo tiempo.marca/jornada_asignada/patron_semanal tenían RLS habilitada. Las otras 14
-- tablas quedaron con el candado de Postgres abierto y sin ningún candado de fila detrás --
-- cualquiera con la anon key (sin login, sin sesión, sin persona activa) podía INSERT/UPDATE/
-- DELETE/SELECT directo por PostgREST contra tope_legal, dia_festivo, parametro, tiempo.persona
-- (el stub de la frontera), dia, tramo, clasificacion_de_tiempo, banco_de_horas,
-- movimiento_de_saldo, correccion, ausencia, aprobacion_ausencia, excepcion y corrida_batch.
-- Explotable en producción tal como estaba: exposición completa del subsistema de Tiempo a
-- cualquiera con la anon key pública, sin necesitar cuenta ni permiso.
--
-- Fix: ENABLE ROW LEVEL SECURITY sin ninguna policy en las 14 tablas -- Postgres deniega TODO a
-- anon/authenticated por default cuando RLS está habilitada y no hay una policy permissive que
-- aplique (mismo mecanismo, a la inversa, de por qué 37_/39_*.sql necesitaron policies explícitas
-- para PERMITIR algo). service_role sigue con BYPASSRLS (ver pg_roles) -- backend con
-- get_service_client y los futuros batches de Fase 4 no se ven afectados. Deny-by-default es
-- intencional y temporal: cada fase agrega la RLS real de sus tablas cuando le toca (dia/tramo en
-- Fase 4, correccion/ausencia en Fase 3, etc. -- ver PLAN_IMPLEMENTACION_TIEMPO.md), mismo criterio
-- que ya usa el proyecto de ir habilitando RLS tabla por tabla en vez de todas de un saque.
--
-- REVOKE UPDATE, DELETE en correccion/movimiento_de_saldo: mismo hallazgo que ya se corrigió en
-- tiempo.marca (38_tiempo_permisos.sql) -- son append-only por diseño (correccion es un registro
-- histórico de correcciones, nunca se edita una corrección ya hecha; movimiento_de_saldo es el
-- ledger del banco de horas, nunca se edita un movimiento ya aplicado) pero, a diferencia de las
-- bitácoras de personas, no tienen trigger que lo respalde -- y el ALTER DEFAULT PRIVILEGES de
-- 38_*.sql les da UPDATE/DELETE a service_role igual (que ignora RLS). tiempo.excepcion NO se
-- toca a propósito -- sí tiene UPDATE legítimo (fn_ausencia_resuelve_excepcion y el flujo humano de
-- resolución de excepciones, SCJ-PRO-08/10, hacen UPDATE real sobre esa tabla).
-- Depende de: 02_tiempo.sql, 38_tiempo_permisos.sql

ALTER TABLE tiempo.tope_legal              ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.dia_festivo             ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.parametro               ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.persona                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.dia                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.tramo                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.clasificacion_de_tiempo ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.banco_de_horas          ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.movimiento_de_saldo     ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.correccion              ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.ausencia                ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.aprobacion_ausencia     ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.excepcion               ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.corrida_batch           ENABLE ROW LEVEL SECURITY;

REVOKE UPDATE, DELETE ON tiempo.correccion FROM anon, authenticated, service_role;
REVOKE UPDATE, DELETE ON tiempo.movimiento_de_saldo FROM anon, authenticated, service_role;
