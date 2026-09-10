-- 11_area_migracion_inicial.sql
-- Seed de personas.area con las 5 áreas reales de Refacciones Tomás Badillo, S.A. de C.V.
-- Fuente: RTB-ORG-01 §II/§III (organigrama y catálogo de puestos, Nextcloud/Sistemas/
-- 04-Organizacion-RH/RTB-ORG/). Los mismos 5 nombres ya se usaban en el proyecto académico
-- (que los tomó de este organigrama, anonimizando sólo personas y razón social) — no hace falta
-- reescribir la estructura, sólo esta cabecera.
-- Depende de: 10_personas_area.sql

INSERT INTO personas.area (nombre_area) VALUES
  ('Comercial'),
  ('Operaciones'),
  ('Administración y Finanzas'),
  ('Recursos Humanos'),
  ('Tecnologías de la Información')
ON CONFLICT (nombre_area) DO NOTHING;
