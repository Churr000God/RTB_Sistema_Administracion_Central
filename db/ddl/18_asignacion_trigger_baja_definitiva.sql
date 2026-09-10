-- 18_asignacion_trigger_baja_definitiva.sql
-- Primer CREATE OR REPLACE FUNCTION del proyecto: reemplaza personas.fn_bitacora_sincroniza_persona()
-- (creada originalmente en 05_personas_estructura.sql) para que, además de sincronizar
-- persona.estado/fecha_baja, cierre las asignaciones vigentes de la persona cuando el movimiento
-- es baja_definitiva — SCJ-PRO-04 §VI: "al dar de baja definitiva a una persona, sus asignaciones
-- vigentes se cierran con vigente_hasta = fecha_efectiva de la baja".
--
-- La convención del proyecto de "archivo nuevo, nunca tocar uno ya aplicado" sigue intacta: este
-- es un archivo .sql nuevo y versionado. Lo que cambia es el CONTENIDO de una función ya
-- existente — CREATE OR REPLACE reemplaza el cuerpo completo (no admite diff), así que se repite
-- entero, con el bloque nuevo agregado antes del RETURN NEW final.
--
-- No hace falta recrear trg_bitacora_sincroniza_persona (05_personas_estructura.sql): el trigger
-- sigue apuntando a la misma función por nombre, sólo cambia lo que esa función hace.
-- Depende de: 05_personas_estructura.sql, 17_personas_asignacion.sql (la tabla asignacion debe
-- existir antes de que la función la referencie)

CREATE OR REPLACE FUNCTION personas.fn_bitacora_sincroniza_persona()
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

  IF NEW.tipo_movimiento = 'baja_definitiva' THEN
    UPDATE personas.asignacion
    SET vigente_hasta = NEW.fecha_efectiva::date,
        actualizado_en = now()
    WHERE persona_id = NEW.persona_id
      AND vigente_hasta IS NULL;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION personas.fn_bitacora_sincroniza_persona() IS
  'Implementa SCJ-PRO-02 (sincroniza persona.estado/fecha_baja) y, desde este archivo, además '
  'SCJ-PRO-04 §VI: en baja_definitiva cierra todas las asignaciones vigentes de la persona con '
  'vigente_hasta = fecha_efectiva de la baja. persona.estado/fecha_baja siguen [CALCULADO] — '
  'nunca se actualizan con UPDATE directo a personas.persona.';
