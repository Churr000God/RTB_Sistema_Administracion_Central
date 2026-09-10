-- 34_puesto_permiso_tiempo_mapeo_inicial.sql
-- Mapeo real de los permisos de Tiempo (33_*.sql), confirmado con el usuario 2026-09-05, sobre
-- "Responsable de Recursos Humanos" y "Gerente General" — mismo patrón que
-- 27_puesto_permiso_mapeo_inicial.sql. "Gerente o Encargado de TI" no aparece aquí: ya recibió
-- estos 27 códigos completos en 33_*.sql, vía el mismo catch-up del bootstrap genérico.
--
-- 16 códigos otorgados a cada uno de los 2 puestos = 32 filas. tiempo_persona_edicion queda
-- deliberadamente fuera — sólo lo tiene TI, tabla interna de cálculo del sistema.
-- Depende de: 16_puesto_migracion_inicial.sql, 24_puesto_permiso_trigger.sql, 33_*.sql

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, m.codigo, 'otorgado'
FROM (VALUES
  -- Vista del módulo — explícito en ambos, mismo patrón que ver_modulo_1/ver_modulo_2.
  ('Responsable de Recursos Humanos', 'ver_modulo_3'),
  ('Gerente General',                 'ver_modulo_3'),
  -- No heredables, sólo edición.
  ('Responsable de Recursos Humanos', 'tope_legal_edicion'),
  ('Gerente General',                 'tope_legal_edicion'),
  ('Responsable de Recursos Humanos', 'dia_festivo_edicion'),
  ('Gerente General',                 'dia_festivo_edicion'),
  ('Responsable de Recursos Humanos', 'parametro_edicion'),
  ('Gerente General',                 'parametro_edicion'),
  ('Responsable de Recursos Humanos', 'captura_manual_edicion'),
  ('Gerente General',                 'captura_manual_edicion'),
  -- Heredables, sólo edición.
  ('Responsable de Recursos Humanos', 'movimiento_de_saldo_edicion'),
  ('Gerente General',                 'movimiento_de_saldo_edicion'),
  ('Responsable de Recursos Humanos', 'jornada_asignada_edicion'),
  ('Gerente General',                 'jornada_asignada_edicion'),
  ('Responsable de Recursos Humanos', 'patron_semanal_edicion'),
  ('Gerente General',                 'patron_semanal_edicion'),
  ('Responsable de Recursos Humanos', 'ausencia_edicion'),
  ('Gerente General',                 'ausencia_edicion'),
  ('Responsable de Recursos Humanos', 'excepcion_edicion'),
  ('Gerente General',                 'excepcion_edicion'),
  ('Responsable de Recursos Humanos', 'aprobacion_ausencia_edicion'),
  ('Gerente General',                 'aprobacion_ausencia_edicion'),
  -- Sólo lectura, calculadas por el sistema.
  ('Responsable de Recursos Humanos', 'marca_lectura'),
  ('Gerente General',                 'marca_lectura'),
  ('Responsable de Recursos Humanos', 'tramo_lectura'),
  ('Gerente General',                 'tramo_lectura'),
  ('Responsable de Recursos Humanos', 'clasificacion_de_tiempo_lectura'),
  ('Gerente General',                 'clasificacion_de_tiempo_lectura'),
  ('Responsable de Recursos Humanos', 'dia_lectura'),
  ('Gerente General',                 'dia_lectura'),
  ('Responsable de Recursos Humanos', 'banco_de_horas_lectura'),
  ('Gerente General',                 'banco_de_horas_lectura')
) AS m(nombre_puesto, codigo)
JOIN personas.puesto p ON p.nombre_puesto = m.nombre_puesto
WHERE NOT EXISTS (
  SELECT 1 FROM personas.puesto_permiso pp
  WHERE pp.puesto_id = p.id AND pp.codigo = m.codigo AND pp.activo
);
