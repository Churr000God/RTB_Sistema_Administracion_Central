-- 04_personas.sql
-- Tabla persona del esquema personas — implementación real, no stub.
-- Depende de: 00_esquemas.sql
-- Justificación: SCJ-MOD-01 §III · decisión de sesión 2026-08-31 (ver bitácora)
--
-- Nota de alcance: el pacto original (SCJ-FRO-01) trataba a personas como subsistema externo,
-- representado en tiempo sólo por el stub de 01_persona_stub.sql. Esta tabla es la
-- implementación real de personas.persona dentro de este mismo proyecto — decisión de sesión,
-- no una obligación de la frontera. tiempo.persona.id sigue siendo un identificador opaco
-- sincronizado, no una referencia declarada con FOREIGN KEY entre esquemas.

CREATE TABLE personas.persona (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actualizado_en     timestamptz NOT NULL DEFAULT now(),
  curp               varchar(18) NOT NULL,
  rfc                varchar(13) NOT NULL,
  nss                varchar(11) NOT NULL,
  primer_nombre      varchar(100) NOT NULL,
  segundo_nombre     varchar(100),
  apellido_paterno   varchar(100) NOT NULL,
  apellido_materno   varchar(100),
  fecha_nacimiento   date NOT NULL,
  fecha_ingreso      date NOT NULL,
  fecha_baja         date,
  estado             varchar(20) NOT NULL DEFAULT 'activo',
  CONSTRAINT uq_persona_curp UNIQUE (curp),
  CONSTRAINT uq_persona_rfc UNIQUE (rfc),
  CONSTRAINT uq_persona_nss UNIQUE (nss),
  CONSTRAINT ck_persona_estado CHECK (estado IN ('activo', 'baja_definitiva', 'suspension')),
  CONSTRAINT ck_persona_baja_consistente
    CHECK ((estado = 'baja_definitiva') = (fecha_baja IS NOT NULL))
);

COMMENT ON TABLE personas.persona IS
  'Identidad civil de la persona física. id (uuid) es el mismo valor que tiempo.persona.id — '
  'ver SCJ-FRO-01. actualizado_en marca la versión: el registro vigente es el de mayor valor. '
  'curp, rfc y nss no se validan por formato aquí — se deja a la capa de aplicación.';
COMMENT ON COLUMN personas.persona.actualizado_en IS
  'Marca de versión del registro, no historial completo: esta tabla guarda una fila por persona '
  '(mutable), no una fila por corrección. Se actualiza en cada UPDATE.';
COMMENT ON COLUMN personas.persona.estado IS
  'activo / baja_definitiva / suspension. Sin "incapacidad": se decidió no distinguirla como '
  'estado propio de persona (sesión 2026-08-31).';
COMMENT ON COLUMN personas.persona.fecha_baja IS
  'Se sincroniza con estado por trg_persona_sincroniza_baja: no puede haber fecha_baja con '
  'estado activo o suspension, ni estado baja_definitiva sin fecha_baja.';

-- Regla funcional (no sólo de validación): al pasar estado a baja_definitiva sin fecha_baja
-- explícita, se autocompleta con la fecha actual; al fijar fecha_baja sin cambiar estado, se
-- autocompleta estado a baja_definitiva. ck_persona_baja_consistente es la red de seguridad que
-- garantiza la invariante incluso si este trigger se deshabilita o se salta.
CREATE FUNCTION personas.fn_persona_sincroniza_baja()
RETURNS trigger AS $$
BEGIN
  IF NEW.estado = 'baja_definitiva' AND NEW.fecha_baja IS NULL THEN
    NEW.fecha_baja := CURRENT_DATE;
  ELSIF NEW.fecha_baja IS NOT NULL AND NEW.estado <> 'baja_definitiva' THEN
    NEW.estado := 'baja_definitiva';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_persona_sincroniza_baja
  BEFORE INSERT OR UPDATE ON personas.persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_persona_sincroniza_baja();

COMMENT ON FUNCTION personas.fn_persona_sincroniza_baja() IS
  'Sincroniza estado y fecha_baja en ambos sentidos. Ver SCJ-MOD-01 §III y decisión de sesión '
  '2026-08-31.';
