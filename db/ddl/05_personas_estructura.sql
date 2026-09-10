-- 05_personas_estructura.sql
-- Completa el subsistema Personas para SCJ-PRO-01/02: expediente, usuario, bitácora de movimiento.
-- Depende de: 00_esquemas.sql, 04_personas.sql
-- Justificación: RTB-APP_DIAGRAMA_V2 (Lucid, subsistema Personas) ·
--   bitacora/2026-09-03_estructura_personas_usuario_bitacora.md

CREATE TABLE personas.expediente (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id       uuid NOT NULL REFERENCES personas.persona(id),
  tipo_contrato    varchar(30) NOT NULL,
  fecha_firma      timestamptz,
  documento_ref    varchar(50) NOT NULL,
  CONSTRAINT uq_expediente_persona UNIQUE (persona_id),
  CONSTRAINT uq_expediente_documento_ref UNIQUE (documento_ref),
  CONSTRAINT ck_expediente_tipo_contrato
    CHECK (tipo_contrato IN ('indefinido', 'prestacion_servicios', 'por_proyecto')),
  CONSTRAINT ck_expediente_documento_ref_formato
    CHECK (documento_ref ~ '^RTB-[A-Za-z0-9]+-[A-Za-z0-9]+$')
);

COMMENT ON TABLE personas.expediente IS
  'Referencia al expediente físico/digital de la persona. documento_ref es la única referencia '
  '(folio) — el archivo real vive en el bucket de Storage "expedientes", no en esta tabla.';
COMMENT ON COLUMN personas.expediente.documento_ref IS
  'Folio formato RTB-__-__. Único por persona (uq_expediente_persona: una persona, un expediente).';

CREATE TABLE personas.usuario (
  auth_user_id     uuid PRIMARY KEY REFERENCES auth.users(id),
  persona_id       uuid REFERENCES personas.persona(id),
  nombre_usuario   varchar(100) NOT NULL,
  estado           varchar(20) NOT NULL DEFAULT 'activo',
  creado_en        timestamptz NOT NULL DEFAULT now(),
  actualizado_en   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_usuario_persona UNIQUE (persona_id),
  CONSTRAINT ck_usuario_estado CHECK (estado IN ('activo', 'inactivo'))
);

COMMENT ON TABLE personas.usuario IS
  'Cuenta de acceso, ligada 1:1 a auth.users (Supabase Auth) y a lo más 1:1 a personas.persona. '
  'usuario.estado es un interruptor de la cuenta en sí (activo/inactivo), distinto de '
  'persona.estado (el candado real de acceso, ver SCJ-PRO-02) — no se usa para autorización.';

CREATE TABLE personas.bitacora_movimiento_persona (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id       uuid NOT NULL REFERENCES personas.persona(id),
  tipo_movimiento  varchar(20) NOT NULL,
  fecha_efectiva   timestamptz NOT NULL DEFAULT now(),
  motivo           text,
  documento_ref    varchar(50),
  registrado_por   uuid REFERENCES personas.usuario(auth_user_id),
  creado_en        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bitacora_tipo_movimiento
    CHECK (tipo_movimiento IN ('alta', 'suspension', 'reactivacion', 'baja_definitiva'))
);

COMMENT ON TABLE personas.bitacora_movimiento_persona IS
  'Fuente de verdad de persona.estado y fecha_baja (ver SCJ-PRO-02) y también registra el alta '
  '(tipo_movimiento = alta, disparado por trg_usuario_bitacora_alta). No registra cambios de '
  'puesto/área — eso es un módulo aparte (asignacion), todavía sin diseñar.';
COMMENT ON COLUMN personas.bitacora_movimiento_persona.registrado_por IS
  'FK a personas.usuario(auth_user_id), no a persona_id: el diagrama de Lucid lo anotaba contra '
  'persona_id, pero esa columna no es única en usuario — ver bitacora/2026-09-03_*.md.';

-- A3 de SCJ-PRO-01: registrar el alta en la bitácora automáticamente al crear el usuario.
CREATE FUNCTION personas.fn_usuario_bitacora_alta()
RETURNS trigger AS $$
BEGIN
  INSERT INTO personas.bitacora_movimiento_persona
    (persona_id, tipo_movimiento, fecha_efectiva, registrado_por)
  VALUES (NEW.persona_id, 'alta', now(), NEW.auth_user_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_usuario_bitacora_alta
  AFTER INSERT ON personas.usuario
  FOR EACH ROW
  WHEN (NEW.persona_id IS NOT NULL)
  EXECUTE FUNCTION personas.fn_usuario_bitacora_alta();

COMMENT ON FUNCTION personas.fn_usuario_bitacora_alta() IS
  'Implementa SCJ-PRO-01 paso A3. registrado_por = el propio usuario recién creado, porque en el '
  'alta todavía no hay "quién más" lo hizo — es un alta administrada por RH vía backend.';

-- A1 de SCJ-PRO-02: sincronizar persona.estado y fecha_baja desde el último movimiento.
CREATE FUNCTION personas.fn_bitacora_sincroniza_persona()
RETURNS trigger AS $$
BEGIN
  IF NEW.tipo_movimiento = 'alta' THEN
    RETURN NEW;
  END IF;

  UPDATE personas.persona
  SET estado = CASE NEW.tipo_movimiento
                 WHEN 'suspension' THEN 'suspension'
                 WHEN 'reactivacion' THEN 'activo'
                 WHEN 'baja_definitiva' THEN 'baja_definitiva'
               END,
      fecha_baja = CASE WHEN NEW.tipo_movimiento = 'baja_definitiva'
                         THEN NEW.fecha_efectiva::date
                         ELSE NULL
                    END
  WHERE id = NEW.persona_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_sincroniza_persona
  AFTER INSERT ON personas.bitacora_movimiento_persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_sincroniza_persona();

COMMENT ON FUNCTION personas.fn_bitacora_sincroniza_persona() IS
  'Implementa SCJ-PRO-02: la bitácora es la fuente de verdad, persona.estado/fecha_baja son '
  '[CALCULADO] — nunca se actualizan con UPDATE directo a personas.persona.';
