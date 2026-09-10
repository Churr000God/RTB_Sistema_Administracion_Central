-- 17_personas_asignacion.sql
-- Cuarto corte del módulo Estructura Organizacional: asignacion, el vínculo persona-puesto con
-- vigencia. Esta tabla completa (filas abiertas y cerradas) ES la bitácora de movimientos de
-- puesto — no hay tabla aparte, ver SCJ-PRO-04 §V.
-- Depende de: 04_personas.sql, 14_personas_puesto.sql
-- Justificación: SCJ-PRO-04 §III-V

CREATE TABLE personas.asignacion (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id      uuid NOT NULL REFERENCES personas.persona(id),
  puesto_id       uuid NOT NULL REFERENCES personas.puesto(id),
  vigente_desde   date NOT NULL,
  vigente_hasta   date,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_asignacion_vigencia CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)
);

-- A lo sumo una asignación vigente por (persona, puesto) a la vez.
CREATE UNIQUE INDEX ux_asignacion_vigente_persona_puesto ON personas.asignacion (persona_id, puesto_id)
  WHERE vigente_hasta IS NULL;

COMMENT ON TABLE personas.asignacion IS
  'Vínculo persona-puesto con vigencia (SCJ-PRO-04). Esta tabla completa — filas abiertas '
  '(vigente_hasta NULL) y cerradas — ES la bitácora de movimientos de puesto, no hay tabla aparte '
  '(SCJ-PRO-04 §V). Sin creado_por/cerrado_por: el documento no pide rastrear quién ejecutó cada '
  'acción, no se inventa (mismo criterio de los tres cortes anteriores del módulo).';
COMMENT ON COLUMN personas.asignacion.vigente_desde IS
  'date, no timestamptz — fecha de vigencia de negocio, mismo criterio que '
  'fecha_nacimiento/fecha_ingreso/fecha_baja de personas.persona.';
COMMENT ON COLUMN personas.asignacion.vigente_hasta IS
  'NULL = asignación vigente hoy. Se cierra con una fecha real al terminar la asignación, ya sea '
  'por PATCH .../terminar, por fn_asignacion_cambiar_puesto(), o automáticamente por '
  'trg_bitacora_sincroniza_persona en baja_definitiva (ver 18_asignacion_trigger_baja_definitiva.sql). '
  'ux_asignacion_vigente_persona_puesto garantiza a lo sumo una fila vigente por (persona, puesto).';

ALTER TABLE personas.asignacion ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.asignacion
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.asignacion TO anon, authenticated, service_role;
