-- 71_expediente_documento_ref_formato_rh_eit.sql
-- Corrige ck_expediente_documento_ref_formato (05_personas_estructura.sql) al formato real del
-- folio de expediente de RTB: RTB-RH-EIT-<año vigente>-<número de expediente>, no el genérico
-- RTB-XX-XX que traía el proyecto académico. "RH-EIT" es fijo (Recursos Humanos, Expediente
-- Individual de Trabajador) -- no varía por área ni por persona. Encontrado en QA en vivo contra
-- Supabase productivo el 2026-09-10 (500 al editar el expediente de una persona con un folio de
-- prueba que no matcheaba el patrón viejo).
-- Depende de: 05_personas_estructura.sql

ALTER TABLE personas.expediente
  DROP CONSTRAINT ck_expediente_documento_ref_formato;

ALTER TABLE personas.expediente
  ADD CONSTRAINT ck_expediente_documento_ref_formato
    CHECK (documento_ref ~ '^RTB-RH-EIT-[0-9]{4}-[0-9]+$');

COMMENT ON COLUMN personas.expediente.documento_ref IS
  'Folio formato RTB-RH-EIT-<año vigente>-<número de expediente>, ej. RTB-RH-EIT-2026-06. Único '
  'por persona (uq_expediente_persona: una persona, un expediente). Ver 71_*.sql.';
