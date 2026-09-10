-- 24_puesto_permiso_trigger.sql
-- Deriva personas.puesto_permiso a partir de cada fila insertada en
-- personas.bitacora_movimiento_puesto_permiso — mismo patrón que
-- personas.fn_bitacora_sincroniza_persona (05_personas_estructura.sql) para persona.estado.
-- Depende de: 22_personas_puesto_permiso.sql, 23_personas_bitacora_puesto_permiso.sql
-- Justificación: SCJ-PRO-05 §VI, G8

CREATE FUNCTION personas.fn_puesto_permiso_sincroniza()
RETURNS trigger AS $$
BEGIN
  IF NEW.tipo_movimiento = 'otorgado' THEN
    INSERT INTO personas.puesto_permiso (puesto_id, codigo, activo)
    VALUES (NEW.puesto_id, NEW.codigo, true)
    ON CONFLICT (puesto_id, codigo) DO UPDATE SET activo = true, actualizado_en = now();
  ELSIF NEW.tipo_movimiento = 'revocado' THEN
    UPDATE personas.puesto_permiso
    SET activo = false, actualizado_en = now()
    WHERE puesto_id = NEW.puesto_id AND codigo = NEW.codigo;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_puesto_permiso_sincroniza
  AFTER INSERT ON personas.bitacora_movimiento_puesto_permiso
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_puesto_permiso_sincroniza();

COMMENT ON FUNCTION personas.fn_puesto_permiso_sincroniza() IS
  'Implementa SCJ-PRO-05 G8 ("crea o reactiva la fila"): ON CONFLICT (puesto_id, codigo) DO UPDATE '
  'resuelve en una sola sentencia el caso de otorgar un permiso ya revocado antes, apoyado en '
  'uq_puesto_permiso_puesto_codigo (22_personas_puesto_permiso.sql). puesto_permiso.activo es '
  '[CALCULADO] — nunca se actualiza con UPDATE directo, sólo insertando en la bitácora.';
