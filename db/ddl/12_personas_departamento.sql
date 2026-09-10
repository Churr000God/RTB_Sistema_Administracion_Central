-- 12_personas_departamento.sql
-- Segundo corte del módulo Estructura Organizacional: departamento, hijo de area.
-- Depende de: 10_personas_area.sql
-- Justificación: SCJ-PRO-03 §III-V, SCJ-PRO-06 §III-IV

CREATE TABLE personas.departamento (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id               uuid NOT NULL REFERENCES personas.area(id),
  nombre_departamento   varchar(100) NOT NULL,
  activo                boolean NOT NULL DEFAULT true,
  creado_en             timestamptz NOT NULL DEFAULT now(),
  actualizado_en        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_departamento_nombre UNIQUE (nombre_departamento)
);

-- Único insensible a mayúsculas, mismo criterio que 10_personas_area.sql.
CREATE UNIQUE INDEX ux_departamento_nombre_insensible ON personas.departamento (lower(nombre_departamento));

COMMENT ON TABLE personas.departamento IS
  'Segundo nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.area. '
  'actualizado_en lo setea el backend en el PATCH, no hay trigger de auto-refresco. No hay '
  'trigger que impida crear un departamento con area inactiva — esa validación va en el backend, '
  'no en DDL. TODO SCJ-PRO-06 DD1: falta la guarda que impida desactivar un departamento con '
  'puesto activo — no se puede escribir hasta que exista personas.puesto.';
COMMENT ON COLUMN personas.departamento.nombre_departamento IS
  'Único GLOBAL, no por área (SCJ-PRO-03 §V explícito) — uq_departamento_nombre no lleva area_id. '
  'ux_departamento_nombre_insensible cubre el mismo caso vía lower().';
COMMENT ON COLUMN personas.departamento.activo IS
  'Interruptor de SCJ-PRO-06. No hay guarda todavía contra puesto hijo activo — ver TODO '
  'SCJ-PRO-06 DD1 en el comentario de tabla.';

ALTER TABLE personas.departamento ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.departamento
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.departamento TO anon, authenticated, service_role;
