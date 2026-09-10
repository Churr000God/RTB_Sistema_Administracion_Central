-- 13_departamento_migracion_inicial.sql
-- Seed de personas.departamento con 6 departamentos reales del organigrama, ya anonimizados:
-- nombres genéricos de industria que no identifican a Distribuidora Central, S.A. de C.V. — no
-- violan SCJ-ANO-01.
-- Fuente: organigrama externo no versionado (no entra al repo). Sólo se tomaron los 6 nombres de
-- departamento y su área — nada de personas, puestos, ni razón social.
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
