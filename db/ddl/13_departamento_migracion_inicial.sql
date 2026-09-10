-- 13_departamento_migracion_inicial.sql
-- Seed de personas.departamento con los 6 departamentos reales del organigrama de RTB.
-- Fuente: RTB-ORG-01 §III (Nextcloud/Sistemas/04-Organizacion-RH/RTB-ORG/). Estructura ya
-- correcta desde el proyecto académico, sólo se corrige esta cabecera.
-- Depende de: 11_area_migracion_inicial.sql, 12_personas_departamento.sql

INSERT INTO personas.departamento (area_id, nombre_departamento)
SELECT a.id, d.nombre_departamento
FROM (VALUES
  ('Operaciones', 'Compras y Abastecimiento'),
  ('Operaciones', 'Almacén'),
  ('Operaciones', 'Logística y Distribución'),
  ('Administración y Finanzas', 'Finanzas y Tesorería'),
  ('Administración y Finanzas', 'Facturación y Cobranza'),
  ('Administración y Finanzas', 'Administración')
) AS d(nombre_area, nombre_departamento)
JOIN personas.area a ON a.nombre_area = d.nombre_area
ON CONFLICT (nombre_departamento) DO NOTHING;
