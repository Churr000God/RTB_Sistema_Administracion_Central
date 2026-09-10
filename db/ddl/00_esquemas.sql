-- 00_esquemas.sql
-- Crea los dos esquemas y las extensiones requeridas.
-- Depende de: nada
-- Justificación: SCJ-FRO-01 §II · SCJ-MOD-03 §II

CREATE SCHEMA IF NOT EXISTS personas;
CREATE SCHEMA IF NOT EXISTS tiempo;

COMMENT ON SCHEMA personas IS
  'Subsistema de Personas. Identidad, expediente, puestos, usuarios, permisos.';
COMMENT ON SCHEMA tiempo IS
  'Subsistema de Tiempo. Marcas, jornadas, saldos, ausencias. Ningún atributo de identidad. Ver SCJ-FRO-01.';
