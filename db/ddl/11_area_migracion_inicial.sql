-- 11_area_migracion_inicial.sql
-- Seed de personas.area con las 5 áreas reales de la empresa, ya anonimizadas: nombres genéricos
-- de industria que no identifican a Distribuidora Central, S.A. de C.V. — no violan SCJ-ANO-01.
-- Fuente: organigrama externo no versionado (no entra al repo). Sólo se tomaron los 5 nombres de
-- área — nada de personas, departamentos, puestos, ni razón social.
-- Depende de: 10_personas_area.sql

INSERT INTO personas.area (nombre_area) VALUES
  ('Comercial'),
  ('Operaciones'),
  ('Administración y Finanzas'),
  ('Recursos Humanos'),
  ('Tecnologías de la Información')
ON CONFLICT (nombre_area) DO NOTHING;
