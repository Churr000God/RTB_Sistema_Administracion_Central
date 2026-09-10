-- 36_puesto_permiso_correccion_mapeo_inicial.sql
-- Mapeo real de correccion_edicion, confirmado con el usuario 2026-09-05, sobre "Responsable de
-- Recursos Humanos" y "Gerente General" — mismo patrón que 27_*.sql y 34_*.sql. "Gerente o
-- Encargado de TI" no aparece aquí: ya recibió correccion_edicion/lectura completo en 35_*.sql,
-- vía el mismo catch-up del bootstrap genérico.
--
-- excepcion_reapertura NO se otorga aquí a propósito — es exclusivo de TI, ni RH ni Gerente
-- General lo tienen. correccion_lectura tampoco se otorga — creado en catálogo, sin asignar,
-- mismo criterio que el resto de los pares _lectura de este módulo.
-- Depende de: 16_puesto_migracion_inicial.sql, 24_puesto_permiso_trigger.sql, 35_*.sql

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, m.codigo, 'otorgado'
FROM (VALUES
  ('Responsable de Recursos Humanos', 'correccion_edicion'),
  ('Gerente General',                 'correccion_edicion')
) AS m(nombre_puesto, codigo)
JOIN personas.puesto p ON p.nombre_puesto = m.nombre_puesto
WHERE NOT EXISTS (
  SELECT 1 FROM personas.puesto_permiso pp
  WHERE pp.puesto_id = p.id AND pp.codigo = m.codigo AND pp.activo
);
