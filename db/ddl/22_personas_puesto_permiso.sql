-- 22_personas_puesto_permiso.sql
-- Vínculo puesto-permiso: qué permiso tiene otorgado (o revocado) cada puesto, hoy.
-- Depende de: 14_personas_puesto.sql, 21_personas_permiso.sql
-- Justificación: SCJ-PRO-05 §III-VI

CREATE TABLE personas.puesto_permiso (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  puesto_id       uuid NOT NULL REFERENCES personas.puesto(id),
  codigo          varchar(50) NOT NULL REFERENCES personas.permiso(codigo),
  activo          boolean NOT NULL DEFAULT true,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_puesto_permiso_puesto_codigo UNIQUE (puesto_id, codigo)
);

COMMENT ON TABLE personas.puesto_permiso IS
  'Estado vigente de "qué permiso tiene cada puesto" — snapshot derivado y mantenido por '
  'trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) a partir de '
  'bitacora_movimiento_puesto_permiso, la fuente de verdad real. No se escribe directo desde la '
  'API salvo por el bootstrap/seed (SQL directo, fuera del flujo normal).';
COMMENT ON COLUMN personas.puesto_permiso.codigo IS
  'uq_puesto_permiso_puesto_codigo (puesto_id, codigo) es literal de SCJ-PRO-05 §VI: sin ella, '
  'otorgar el mismo permiso dos veces al mismo puesto crearía dos filas y el trigger no sabría '
  'cuál actualizar al revocar.';

ALTER TABLE personas.puesto_permiso ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.puesto_permiso
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.puesto_permiso TO anon, authenticated, service_role;
