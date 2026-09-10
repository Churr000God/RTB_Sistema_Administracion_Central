-- 21_personas_permiso.sql
-- Catálogo de permisos del módulo Estructura Organizacional: SCJ-PRO-05, quinto y último corte.
-- Depende de: 00_esquemas.sql, 06_personas_rls.sql
-- Justificación: SCJ-PRO-05 §I, §VI

CREATE TABLE personas.permiso (
  codigo          varchar(50) PRIMARY KEY,
  heredable       boolean NOT NULL DEFAULT false,
  activo          boolean NOT NULL DEFAULT true,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE personas.permiso IS
  'Catálogo de permisos (SCJ-PRO-05). Única tabla del módulo Estructura Organizacional sin uuid '
  'PRIMARY KEY — codigo es la clave, fiel a la redacción literal del documento ("UNIQUE(puesto_id, '
  'codigo)", "cuenta filas con ese código"): el propio proceso trata al código como identificador, '
  'no como un atributo más. El alta de permiso no es un proceso de usuario — se siembra por '
  'migración al integrar un módulo nuevo (SCJ-PRO-03 §I, SCJ-PRO-05 §I), nunca por la API. Sin '
  'columna nombre/label: codigo (ej. area_edicion) ya es el identificador legible, no se inventa '
  'un campo de UI adicional sin respaldo documental.';
COMMENT ON COLUMN personas.permiso.heredable IS
  'true = sube por reporta_a_id (SCJ-PRO-05 §IV): si un puesto lo tiene, todo puesto que le '
  'reporta (directa o transitivamente) lo tiene también, sin fila propia en puesto_permiso.';

ALTER TABLE personas.permiso ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.permiso
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.permiso TO anon, authenticated, service_role;
