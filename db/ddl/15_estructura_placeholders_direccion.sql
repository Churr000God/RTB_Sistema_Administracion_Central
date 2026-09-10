-- 15_estructura_placeholders_direccion.sql
-- Placeholders de Dirección: el organigrama real no tiene un departamento propio para el Gerente
-- de cada área (reportan directo al Gerente General) ni para el puesto tope en sí, pero
-- personas.puesto.departamento_id es NOT NULL. Se agrega una 6ª área "Dirección General" y un
-- departamento placeholder por cada una de las 5 áreas (las 4 reales + la nueva), sólo para que
-- esos 5 puestos de dirección tengan dónde colgar sin violar la FK. Decisión de modelado aceptada
-- explícitamente por el usuario — estos departamentos NO son estructura real del organigrama, no
-- confundirlos con los sembrados en 13_departamento_migracion_inicial.sql.
--
-- Tecnologías de la Información es la excepción, a propósito: no tiene placeholder acá (ver
-- corrección 2026-09-05, fusión de "Encargado de TI"/"Gerente o Encargado de TI" documentada en
-- 16_puesto_migracion_inicial.sql y 26_puesto_permiso_bootstrap_admin_generico.sql) -- su puesto de
-- dirección cuelga de "Gerencia de Tecnologías de la Información" (departamento real que crea
-- 26_*.sql), no de un placeholder de este archivo.
-- No modifica 11_area_migracion_inicial.sql (ya aplicado) — este es un apéndice nuevo, mismo
-- criterio de ON CONFLICT DO NOTHING para que reejecutarlo sea inocuo.
-- Depende de: 11_area_migracion_inicial.sql, 12_personas_departamento.sql

INSERT INTO personas.area (nombre_area) VALUES
  ('Dirección General')
ON CONFLICT (nombre_area) DO NOTHING;

INSERT INTO personas.departamento (area_id, nombre_departamento)
SELECT a.id, d.nombre_departamento
FROM (VALUES
  ('Comercial', 'Dirección Comercial'),
  ('Operaciones', 'Dirección de Operaciones'),
  ('Administración y Finanzas', 'Dirección de Administración y Finanzas'),
  ('Recursos Humanos', 'Dirección de Recursos Humanos'),
  ('Dirección General', 'Dirección General')
) AS d(nombre_area, nombre_departamento)
JOIN personas.area a ON a.nombre_area = d.nombre_area
ON CONFLICT (nombre_departamento) DO NOTHING;
