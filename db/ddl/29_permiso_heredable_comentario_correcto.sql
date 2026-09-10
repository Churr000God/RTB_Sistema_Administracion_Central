-- 29_permiso_heredable_comentario_correcto.sql
-- Fix de documentación (no toca datos): el COMMENT ON COLUMN de 21_personas_permiso.sql describía
-- la dirección de la herencia al revés. La dirección real (confirmada por la lógica de
-- otorgar_permiso en backend/app/routers/permisos.py y por RTB-ESP-01 §III.4): el JEFE hereda los
-- permisos que ya tiene el SUBORDINADO, no al revés ("el Encargado de Almacén hereda todo lo del
-- Auxiliar de Almacén y añade lo suyo").
-- Depende de: 21_personas_permiso.sql

COMMENT ON COLUMN personas.permiso.heredable IS
  'true = sube por reporta_a_id (SCJ-PRO-05 §IV): si un puesto lo tiene, todo puesto AL QUE ESE '
  'PUESTO REPORTA (su jefe, directo o transitivo, subiendo por reporta_a_id) lo tiene también, '
  'sin fila propia en puesto_permiso — el jefe hereda lo del subordinado, no al revés.';
