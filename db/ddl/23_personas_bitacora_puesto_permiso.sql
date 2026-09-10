-- 23_personas_bitacora_puesto_permiso.sql
-- Bitácora de otorgar/revocar permiso a puesto (SCJ-PRO-05): fuente de verdad, mismo diseño que
-- personas.bitacora_movimiento_persona (05_personas_estructura.sql). Tabla de sólo inserción — el
-- trigger de 24_puesto_permiso_trigger.sql deriva de acá el estado de puesto_permiso.activo.
--
-- Decisión de inmutabilidad: a diferencia de bitacora_movimiento_persona (que nació sin este
-- candado y necesitó 09_personas_bitacora_inmutable.sql como parche posterior), esta tabla se crea
-- inmutable desde el arranque, en el mismo archivo — no hay motivo para repetir la ventana de
-- "falsa inmutabilidad" ya detectada y corregida en el corte de personas. Mismas tres capas de
-- 09_personas_bitacora_inmutable.sql: REVOKE de UPDATE/DELETE, policies SELECT+INSERT explícitas
-- (sin UPDATE/DELETE, RLS las niega por default), y trigger BEFORE UPDATE OR DELETE que aborta —
-- esta última es la única capa que también alcanza a service_role.
-- Depende de: 14_personas_puesto.sql, 21_personas_permiso.sql
-- Justificación: SCJ-PRO-05 §III-VI

CREATE TABLE personas.bitacora_movimiento_puesto_permiso (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  puesto_id       uuid NOT NULL REFERENCES personas.puesto(id),
  codigo          varchar(50) NOT NULL REFERENCES personas.permiso(codigo),
  tipo_movimiento varchar(20) NOT NULL,
  fecha_efectiva  timestamptz NOT NULL DEFAULT now(),
  motivo          text,
  registrado_por  uuid REFERENCES personas.usuario(auth_user_id),
  creado_en       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bitacora_puesto_permiso_tipo CHECK (tipo_movimiento IN ('otorgado', 'revocado'))
);

COMMENT ON TABLE personas.bitacora_movimiento_puesto_permiso IS
  'Fuente de verdad de puesto_permiso.activo (SCJ-PRO-05). Sólo inserción — inmutable desde el '
  'arranque, ver comentario de cabecera del archivo. trg_puesto_permiso_sincroniza '
  '(24_puesto_permiso_trigger.sql) deriva puesto_permiso a partir de cada fila insertada acá.';

ALTER TABLE personas.bitacora_movimiento_puesto_permiso ENABLE ROW LEVEL SECURITY;

-- Policies SELECT+INSERT explícitas, sin FOR ALL: sin policy de UPDATE/DELETE, RLS las niega por
-- default para anon/authenticated (capa 2 de 09_personas_bitacora_inmutable.sql).
CREATE POLICY bitacora_puesto_permiso_select_caller_activo ON personas.bitacora_movimiento_puesto_permiso
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY bitacora_puesto_permiso_insert_caller_activo ON personas.bitacora_movimiento_puesto_permiso
  FOR INSERT WITH CHECK (personas.fn_caller_activo());

-- GRANT explícito sin UPDATE/DELETE (capa 1: nunca se otorgan, no hace falta REVOKE porque nunca
-- se concedieron) — a diferencia de 08_personas_permisos.sql, que sí otorga ALL por default.
GRANT SELECT, INSERT ON personas.bitacora_movimiento_puesto_permiso TO anon, authenticated, service_role;

-- Trigger que también alcanza a service_role (RLS no lo frena, y este GRANT nunca incluyó
-- UPDATE/DELETE) — capa 3, la que hace "inmutable" cierto sin excepción de rol.
CREATE FUNCTION personas.fn_bitacora_puesto_permiso_inmutable()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION
    'personas.bitacora_movimiento_puesto_permiso es de solo inserción: % no está permitido (fila %)',
    TG_OP, OLD.id;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_puesto_permiso_inmutable
  BEFORE UPDATE OR DELETE ON personas.bitacora_movimiento_puesto_permiso
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_puesto_permiso_inmutable();

COMMENT ON FUNCTION personas.fn_bitacora_puesto_permiso_inmutable() IS
  'Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role. Mismo patrón que '
  'personas.fn_bitacora_inmutable() (09_personas_bitacora_inmutable.sql), aplicado desde el '
  'arranque en vez de como parche posterior.';
