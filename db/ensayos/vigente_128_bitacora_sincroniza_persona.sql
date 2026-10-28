-- Cuerpo VIGENTE (pg_get_functiondef + obj_description) de personas.fn_bitacora_sincroniza_persona(), leído de la base real el 28-oct-2026 (solo lectura).
-- REVERSA de 128_: correr con psql --single-transaction (cuerpo y COMMENT previos; dueño y ACL no cambian).
CREATE OR REPLACE FUNCTION personas.fn_bitacora_sincroniza_persona()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$;


COMMENT ON FUNCTION personas.fn_bitacora_sincroniza_persona() IS $c$Implementa SCJ-PRO-02 (sincroniza persona.estado/fecha_baja) y, desde este archivo, además SCJ-PRO-04 §VI: en baja_definitiva cierra todas las asignaciones vigentes de la persona con vigente_hasta = fecha_efectiva de la baja. persona.estado/fecha_baja siguen [CALCULADO] — nunca se actualizan con UPDATE directo a personas.persona.$c$;
