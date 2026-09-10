-- 01_persona_stub.sql
-- Stub de la frontera entre subsistemas.
-- Depende de: 00_esquemas.sql
-- Justificación: SCJ-FRO-01 §I y §II

CREATE TABLE tiempo.persona (
  id uuid PRIMARY KEY
);

COMMENT ON TABLE tiempo.persona IS
  'Stub. Identificador opaco. Ningún atributo de identidad vive aquí: ni nombre, ni CURP, ni RFC, '
  'ni NSS, ni salario. Si un requisito parece necesitarlos, el requisito está mal planteado. '
  'Ver SCJ-FRO-01.';
COMMENT ON COLUMN tiempo.persona.id IS
  'Identificador opaco, mismo valor que personas.persona.id (uuid). En operación se sincroniza '
  'desde personas.persona; en este proyecto lo puebla el generador de datos sintéticos.';
