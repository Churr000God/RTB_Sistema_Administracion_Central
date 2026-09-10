-- 25_permiso_migracion_inicial.sql
-- Seed de los 16 permisos de SCJ-PRO-05: catálogo completo provisto directo por el usuario
-- (fuente de verdad — ni el repo ni RTB-ESP-01, que sólo describe el modelo, traían una lista
-- plana; RTB-ESP-01 además contiene PII real y no entra a este repo bajo ninguna forma). 4
-- heredables (suben por reporta_a_id) + 12 no heredables (6 pares edición/lectura). Cuadra con el
-- "14 a 16" de SCJ-PRO-04 §VI: sin el par de asignación son 14.
-- Depende de: 21_personas_permiso.sql

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('alta_personas_usuarios', true),
  ('cambio_estado_persona', true),
  ('ver_modulo_1', true),
  ('ver_modulo_2', true),
  ('area_edicion', false), ('area_lectura', false),
  ('departamento_edicion', false), ('departamento_lectura', false),
  ('puesto_edicion', false), ('puesto_lectura', false),
  ('permiso_edicion', false), ('permiso_lectura', false),
  ('puesto_permiso_edicion', false), ('puesto_permiso_lectura', false),
  ('asignacion_edicion', false), ('asignacion_lectura', false)
ON CONFLICT (codigo) DO NOTHING;
