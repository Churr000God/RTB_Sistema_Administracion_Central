-- 03_parametros_ejemplo.sql
-- Parámetros del sistema con VALORES DE EJEMPLO.
-- Depende de: 02_tiempo.sql
-- Justificación: SCJ-ESP-01 §VI.9
--
-- IMPORTANTE: ninguno de estos valores es un valor de operación. Las políticas
-- reales se cargan como parámetros en el despliegue y no forman parte del
-- alcance de este proyecto. Ver SCJ-ANO-01.

INSERT INTO tiempo.parametro (clave, valor, vigente_desde) VALUES
  ('tolerancia_retardo_min', '10', '2026-01-01'),
  ('hora_corte_dia', '00:00', '2026-01-01'),
  ('ventana_banco_meses', '6', '2026-01-01'),
  ('umbral_aviso_pct', '100', '2026-01-01'),
  ('umbral_escalamiento_pct', '200', '2026-01-01'),
  ('descuento_pausa_no_registrada_min', '60', '2026-01-01'),
  ('dias_habiles_correccion_marca', '30', '2026-01-01'),
  ('hora_corrida_cierre_dia', '03:00', '2026-01-01');

COMMENT ON TABLE tiempo.parametro IS
  'Valor de regla de negocio, configurable. Ver comentario completo en 02_tiempo.sql — este '
  'archivo sólo carga valores de ejemplo, nunca los reales de operación.';
