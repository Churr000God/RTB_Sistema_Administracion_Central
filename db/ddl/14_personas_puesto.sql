-- 14_personas_puesto.sql
-- Tercer corte del módulo Estructura Organizacional: puesto, hijo de departamento, con jerarquía
-- propia vía reporta_a_id (self-referencing).
-- Depende de: 12_personas_departamento.sql
-- Justificación: SCJ-PRO-03 §I, §III-V, SCJ-PRO-06 §III-IV

CREATE TABLE personas.puesto (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  departamento_id   uuid NOT NULL REFERENCES personas.departamento(id),
  nombre_puesto     varchar(150) NOT NULL,
  nivel             varchar(20) NOT NULL,
  plazas_totales    integer NOT NULL DEFAULT 1,
  reporta_a_id      uuid REFERENCES personas.puesto(id),
  activo            boolean NOT NULL DEFAULT true,
  creado_en         timestamptz NOT NULL DEFAULT now(),
  actualizado_en    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_puesto_nivel CHECK (nivel IN ('direccion', 'gerencia', 'mando_medio', 'operativo')),
  CONSTRAINT ck_puesto_plazas_positivas CHECK (plazas_totales > 0),
  CONSTRAINT ck_puesto_no_autoreferencia CHECK (id IS DISTINCT FROM reporta_a_id)
);

-- A lo sumo un puesto tope (reporta_a_id NULL) en todo el sistema.
CREATE UNIQUE INDEX ux_puesto_tope_unico ON personas.puesto ((reporta_a_id IS NULL))
  WHERE reporta_a_id IS NULL;

COMMENT ON TABLE personas.puesto IS
  'Tercer nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.departamento, '
  'con jerarquía propia vía reporta_a_id. nivel es varchar+CHECK, no CREATE TYPE ENUM — ningún '
  'enum Postgres existe en el proyecto, mismo criterio que persona.estado. Sin nombre_puesto '
  'UNIQUE: SCJ-PRO-03 nunca pide validación de nombre duplicado para puesto (a diferencia de '
  'area/departamento), no se inventa. Sin validación de ciclo/recorrido en DDL: SCJ-PRO-03 §I '
  'excluye la edición de reporta_a_id de este alcance, y en el alta (siempre elige un puesto ya '
  'existente) el ciclo es imposible por construcción — sería código muerto hasta que exista ese '
  'endpoint de edición. ck_puesto_no_autoreferencia sí se agrega: defensivo, gratis, cubre incluso '
  'un UPDATE directo por SQL. La guarda de SCJ-PRO-06 DP4 (no desactivar con puesto subordinado '
  'activo) sí es construible hoy y va en el backend (ya existen todas las filas que necesita '
  'consultar). TODO SCJ-PRO-06 DP1/DP3: asignación vigente y puesto_permiso activo, tablas '
  'inexistentes.';
COMMENT ON COLUMN personas.puesto.reporta_a_id IS
  'NULL-able en DDL — el único NULL real es el puesto tope (Gerente General), sembrado por '
  'migración vía SQL directo, fuera del flujo normal de alta. El backend exige este campo en el '
  'POST normal: la API nunca puede crear un segundo puesto sin padre. ux_puesto_tope_unico lo '
  'garantiza también a nivel de Postgres.';
COMMENT ON COLUMN personas.puesto.nivel IS
  'Catálogo cerrado de 4 valores (ck_puesto_nivel): direccion, gerencia, mando_medio, operativo — '
  'snake_case ASCII de Dirección/Gerencia/Mando medio/Operativo.';

ALTER TABLE personas.puesto ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.puesto
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

-- Explícito aunque 08_personas_permisos.sql tenga ALTER DEFAULT PRIVILEGES: ese default sólo
-- aplica a tablas creadas por el mismo rol que corrió el ALTER — no hay que depender de eso.
GRANT ALL ON personas.puesto TO anon, authenticated, service_role;
