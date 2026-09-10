-- 10_personas_area.sql
-- Catálogo raíz del módulo Estructura Organizacional: area, sin dependencias aguas arriba.
-- Depende de: 00_esquemas.sql, 06_personas_rls.sql
-- Justificación: SCJ-PRO-03 §III-IV, SCJ-PRO-06 §III-IV

CREATE TABLE personas.area (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre_area     varchar(100) NOT NULL,
  activo          boolean NOT NULL DEFAULT true,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_area_nombre UNIQUE (nombre_area)
);

-- Único insensible a mayúsculas: uq_area_nombre pelado deja pasar "Comercial" y "comercial" como
-- áreas distintas, duplicado real en un catálogo de 5 filas. SCJ-PRO-03 A1 sólo pide "nombre
-- único"; este índice es más estricto que el documento a propósito.
CREATE UNIQUE INDEX ux_area_nombre_insensible ON personas.area (lower(nombre_area));

COMMENT ON TABLE personas.area IS
  'Catálogo raíz del módulo Estructura Organizacional (SCJ-PRO-03). Sólo 5 columnas — tipo_area '
  '(línea/apoyo) del organigrama no entra, sin respaldo documental. actualizado_en lo setea el '
  'backend en el PATCH, no hay trigger de auto-refresco (ningún trigger genérico de ese tipo '
  'existe en el proyecto). TODO SCJ-PRO-06 DA1: falta la guarda que impida desactivar un area con '
  'departamento activo — no se puede escribir hasta que exista personas.departamento.';
COMMENT ON COLUMN personas.area.nombre_area IS
  'Único por uq_area_nombre (exacto) y ux_area_nombre_insensible (lower()) — evita duplicados '
  'tipo "Comercial"/"comercial".';
COMMENT ON COLUMN personas.area.activo IS
  'Interruptor de SCJ-PRO-06 (desactivar/reactivar). No hay guarda todavía contra departamento '
  'hijo activo — ver TODO SCJ-PRO-06 DA1 en el comentario de tabla.';

ALTER TABLE personas.area ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.area
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.area TO anon, authenticated, service_role;
