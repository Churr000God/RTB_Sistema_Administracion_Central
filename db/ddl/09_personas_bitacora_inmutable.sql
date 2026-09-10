-- 09_personas_bitacora_inmutable.sql
-- Hace real la tarjeta "Registro inmutable" del mockup 14 (bitácora de movimientos): hoy es falsa,
-- la policy FOR ALL de 06_personas_rls.sql y el GRANT ALL de 08_personas_permisos.sql dejan pasar
-- UPDATE/DELETE sin ningún candado. Tres capas, cada una tapa un hueco distinto:
--   1) REVOKE de UPDATE/DELETE a anon/authenticated (hoy heredado del GRANT ALL de 08).
--   2) La policy FOR ALL se reemplaza por dos explícitas (SELECT, INSERT) — sin policy de
--      UPDATE/DELETE, RLS las niega por default para anon/authenticated.
--   3) Trigger BEFORE UPDATE OR DELETE que aborta con RAISE EXCEPTION — la única capa que también
--      alcanza a service_role, que salta RLS y conserva el GRANT hasta que se revoque explícitamente.
--      Sin esta capa, "inmutable" seguiría siendo falso para el backend admin.
-- Depende de: 06_personas_rls.sql, 08_personas_permisos.sql
-- Justificación: diseno_paginas/personas/14-bitacora-movimientos.png (tarjeta "Registro inmutable")
--   · QA de mockups de personas, sesión 2026-09-03 (bitacora/2026-09-0X_qa_personas_mockups.md)

-- 1) Revocar UPDATE/DELETE heredado del GRANT ALL de 08_personas_permisos.sql.
REVOKE UPDATE, DELETE ON personas.bitacora_movimiento_persona FROM anon, authenticated;

-- 2) Reemplazar la policy FOR ALL por SELECT + INSERT explícitas. Sin policy de UPDATE/DELETE,
--    esas operaciones quedan denegadas por default en RLS para anon/authenticated.
DROP POLICY IF EXISTS solo_caller_activo ON personas.bitacora_movimiento_persona;

CREATE POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY bitacora_insert_caller_activo ON personas.bitacora_movimiento_persona
  FOR INSERT WITH CHECK (personas.fn_caller_activo());

-- 3) Trigger que también alcanza a service_role (RLS no lo frena, el GRANT tampoco hasta que se
--    revoque). Es la única capa que hace "inmutable" cierto sin excepción de rol.
CREATE FUNCTION personas.fn_bitacora_inmutable()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION
    'personas.bitacora_movimiento_persona es de solo inserción: % no está permitido (fila %)',
    TG_OP, OLD.id;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_inmutable
  BEFORE UPDATE OR DELETE ON personas.bitacora_movimiento_persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_inmutable();

COMMENT ON FUNCTION personas.fn_bitacora_inmutable() IS
  'Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role (que salta RLS y '
  'conserva el GRANT de 08_personas_permisos.sql hasta que se revoque explícitamente). Las policies '
  'bitacora_select_caller_activo/bitacora_insert_caller_activo ya bloquean anon/authenticated; este '
  'trigger es la capa que falta para que "Registro inmutable" (mockup 14) sea cierto de verdad.';

-- Rollback de referencia, sólo si esta migración rompe algo (no ejecutar como parte del DDL):
--   DROP TRIGGER trg_bitacora_inmutable ON personas.bitacora_movimiento_persona;
--   DROP FUNCTION personas.fn_bitacora_inmutable();
--   DROP POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona;
--   DROP POLICY bitacora_insert_caller_activo ON personas.bitacora_movimiento_persona;
--   CREATE POLICY solo_caller_activo ON personas.bitacora_movimiento_persona
--     FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());
--   GRANT UPDATE, DELETE ON personas.bitacora_movimiento_persona TO anon, authenticated;
