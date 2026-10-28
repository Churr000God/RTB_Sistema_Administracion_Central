-- 128_personas_baja_fecha_de_mexico.sql
-- La baja por la bitácora toma la fecha de México, no la de la sesión (UTC). Complemento de 127_ (P-055/P-182), cambio sobre el esquema congelado
-- (SCJ-ACT-03 V1.1 §V) aprobado por Diego el 28-oct-2026 («Sí, sumarla»), después de aplicar 127_.
--
-- PROBLEMA. personas.fn_bitacora_sincroniza_persona() (trigger AFTER INSERT de personas.bitacora_movimiento_persona, el camino normal de una baja) hacía
-- fecha_baja = NEW.fecha_efectiva::date y cerraba las asignaciones vigentes con vigente_hasta = NEW.fecha_efectiva::date. fecha_efectiva es timestamptz y
-- timestamptz::date usa la zona de la SESIÓN (UTC en esta base): una baja registrada entre las 18:00 y las 24:00 de CDMX quedaba con fecha de MAÑANA y cerraba
-- las asignaciones mañana. 127_ no lo cubre: por este camino fecha_baja ya llega puesta y fn_persona_sincroniza_baja no la toca.
--
-- QUÉ HACE. CREATE OR REPLACE desde el cuerpo REAL de la base (copia en db/ensayos/vigente_128_bitacora_sincroniza_persona.sql) con UN solo cambio en las dos
-- líneas: NEW.fecha_efectiva::date => personas.fn_hoy_mexico(NEW.fecha_efectiva) (113_; (p_ahora AT TIME ZONE 'America/Mexico_City')::date). Es la fecha en
-- México del INSTANTE de la baja, que puede ser retroactivo (fn_bitacora_persona_fija_hora admite hasta 90 días atrás): no es «hoy», es el día de ese instante.
--
-- ATRIBUTOS (gotcha de CREATE OR REPLACE): la función es plpgsql VOLATILE, SECURITY INVOKER, sin search_path, dueño postgres, sin EXECUTE para nadie de la API
-- (105_); se conservan tal cual y se repiten explícitos dueño, REVOKE y COMMENT (texto vigente + una frase de 128_). Corre como el caller del INSERT en la
-- bitácora (authenticated por la policy bitacora_insert_requiere_permiso, o service_role), y fn_hoy_mexico ya tiene EXECUTE para los dos (113_): no hace
-- falta ningún GRANT. Sin ERRCODE ni HINT nuevos.
--
-- FUERA DE ALCANCE (reportado, no se cambia): el UPDATE de personas.asignacion corre como el caller (INVOKER) y lo filtra la policy
-- asignacion_update_requiere_permiso (exige asignacion_edicion). Quien tuviera cambio_estado_persona SIN asignacion_edicion daría de baja a la persona y
-- dejaría sus asignaciones abiertas sin error. Hoy los dos puestos con cambio_estado_persona también tienen asignacion_edicion; el ensayo lo documenta (caso R1).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 128_*.sql`. Sin precondición de datos: solo cambia bajas futuras; las ya registradas no se
-- recalculan. Se puede aplicar a cualquier hora (mejor fuera de 18:00–24:00 de CDMX para no tener bajas de esa franja con los dos criterios el mismo día).
-- REVERSA (en una transacción): psql --single-transaction -f db/ensayos/vigente_128_bitacora_sincroniza_persona.sql
-- Verificador: sección 90 de verificar_ddl.sql (ninguna función de tiempo/personas convierte fecha_efectiva con ::date; esta usa fn_hoy_mexico dos veces).
-- Depende de: 05_, 18_, 105_, 113_, 127_
-- Justificación: SCJ-PRO-02, SCJ-PRO-04 §VI, SCJ-ACT-03 §V

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
                         THEN personas.fn_hoy_mexico(NEW.fecha_efectiva)
                         ELSE NULL
                    END
  WHERE id = NEW.persona_id;

  IF NEW.tipo_movimiento = 'baja_definitiva' THEN
    UPDATE personas.asignacion
    SET vigente_hasta = personas.fn_hoy_mexico(NEW.fecha_efectiva),
        actualizado_en = now()
    WHERE persona_id = NEW.persona_id
      AND vigente_hasta IS NULL;
  END IF;

  RETURN NEW;
END;
$function$;


ALTER FUNCTION personas.fn_bitacora_sincroniza_persona() OWNER TO postgres;
REVOKE ALL ON FUNCTION personas.fn_bitacora_sincroniza_persona() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION personas.fn_bitacora_sincroniza_persona() IS $c$Implementa SCJ-PRO-02 (sincroniza persona.estado/fecha_baja) y, desde este archivo, además SCJ-PRO-04 §VI: en baja_definitiva cierra todas las asignaciones vigentes de la persona con vigente_hasta = fecha_efectiva de la baja. persona.estado/fecha_baja siguen [CALCULADO] — nunca se actualizan con UPDATE directo a personas.persona. 128_: fecha_baja y el cierre de asignaciones usan personas.fn_hoy_mexico(NEW.fecha_efectiva), la fecha en México del instante de la baja, no la de la sesión (UTC).$c$;
