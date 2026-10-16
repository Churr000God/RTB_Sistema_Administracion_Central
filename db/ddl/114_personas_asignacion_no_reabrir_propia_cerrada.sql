-- 114_personas_asignacion_no_reabrir_propia_cerrada.sql
-- Cierra el hueco de REABRIR una asignación PROPIA ya cerrada (security, pre-existente a 113_). 113_ rechaza autoasignarse, pero su trigger no se disparaba con UPDATE OF vigente_hasta, y nada protegía la
-- transición `vigente_hasta NOT NULL -> NULL`: una persona con asignacion_edicion que tuvo antes un puesto mayor y fue movida podía ponerse `vigente_hasta = NULL` en esa fila propia y recuperarlo, saltando la
-- plaza y la decisión de terminarla. (32_ solo protege la dirección contraria y solo para el puesto administrador.)
--
-- REQUIERE 113_ aplicada (reemplaza su función y su trigger). APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 114_*.sql`.
--
-- CAMBIOS (los dos sobre lo de 113_, y solo esos):
--  1. trg_asignacion_valida_reglas: la lista de columnas pasa a `UPDATE OF persona_id, puesto_id, vigente_desde, vigente_hasta` (se recrea el trigger).
--  2. personas.fn_asignacion_valida_reglas() (CREATE OR REPLACE, REPITE INVOKER, search_path y el REVOKE: lección de CLAUDE.md):
--     a) NUEVA regla: UPDATE que reabre (OLD.vigente_hasta IS NOT NULL y NEW.vigente_hasta IS NULL) una fila cuyo NEW.persona_id es el caller => ERRCODE SCJ19, mismo HINT 'autoasignacion_no_permitida' (el mapeo
--        del backend ya lo cubre). Reabrir filas AJENAS sigue permitido (la plaza la cuida 115_).
--     b) AJUSTE NECESARIO: como `vigente_hasta` ya está en la lista OF, la regla genérica «NEW.persona_id = caller» ya no puede dispararse por cualquier UPDATE de la fila propia (cerrar la propia, NULL -> fecha,
--        debe seguir permitido, y cambiar vigente_hasta de una fecha a otra también). Para los UPDATE la regla genérica y la de fecha futura pasan a evaluarse sobre el CAMBIO REAL: persona_id, puesto_id o
--        vigente_desde distintos de OLD. Efecto: un `SET puesto_id = <el mismo>` sin cambio ya no se rechaza (no hace nada); todo cambio efectivo de persona/puesto/inicio sobre la fila propia sigue
--        rechazado igual que en 113_. Los INSERT se evalúan siempre.
--     c) Se conserva la excepción de auth.uid() nulo (bootstrap, migraciones, service_role): no hace nada.
--
-- Inventario de RLS: sin cambios. Verificador: sección 79 (solo violaciones). 70(d) no cambia (función de trigger sin EXECUTE).
-- REVERSA (en una transacción; archivo en el scratchpad de la sesión, generado desde 113_): DROP TRIGGER, CREATE OR REPLACE con el cuerpo de 113_ y CREATE TRIGGER con `UPDATE OF persona_id, puesto_id,
-- vigente_desde`. Probada dentro de ensayo_114.

CREATE OR REPLACE FUNCTION personas.fn_asignacion_valida_reglas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_cambia_ubicacion boolean;
BEGIN
  -- Caminos internos sin sesión (migraciones, bootstrap del usuario base con service_role/dueño): no son un vector de escalamiento por la API.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- En INSERT todo es nuevo; en UPDATE solo importa lo que REALMENTE cambia de persona, puesto o inicio.
  v_cambia_ubicacion := TG_OP = 'INSERT'
    OR NEW.persona_id IS DISTINCT FROM OLD.persona_id
    OR NEW.puesto_id IS DISTINCT FROM OLD.puesto_id
    OR NEW.vigente_desde IS DISTINCT FROM OLD.vigente_desde;

  IF v_cambia_ubicacion AND NEW.persona_id = personas.fn_caller_persona_id() THEN
    RAISE EXCEPTION 'No puede asignarse ni recolocarse a sí mismo en un puesto.'
      USING ERRCODE = 'SCJ19', HINT = 'autoasignacion_no_permitida';
  END IF;

  -- Reabrir una asignación PROPIA ya cerrada (vigente_hasta: fecha -> NULL) es recuperar un puesto por mano propia.
  IF TG_OP = 'UPDATE' AND OLD.vigente_hasta IS NOT NULL AND NEW.vigente_hasta IS NULL
     AND NEW.persona_id = personas.fn_caller_persona_id() THEN
    RAISE EXCEPTION 'No puede reabrir una asignación propia ya cerrada.'
      USING ERRCODE = 'SCJ19', HINT = 'autoasignacion_no_permitida';
  END IF;

  IF (TG_OP = 'INSERT' OR NEW.vigente_desde IS DISTINCT FROM OLD.vigente_desde)
     AND NEW.vigente_desde > personas.fn_hoy_mexico(now()) THEN
    RAISE EXCEPTION 'La asignación no puede tener una fecha de inicio futura.'
      USING ERRCODE = 'SCJ20', HINT = 'vigencia_futura_no_permitida';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_asignacion_valida_reglas() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION personas.fn_asignacion_valida_reglas() IS
  'Trigger de personas.asignacion (113_/114_): rechaza autoasignación y REAPERTURA de la propia asignación cerrada (SCJ19, hint autoasignacion_no_permitida) y vigente_desde posterior a hoy en México (SCJ20, hint vigencia_futura_no_permitida). Sin efecto si auth.uid() es nulo (bootstrap). Sin EXECUTE para nadie.';

DROP TRIGGER trg_asignacion_valida_reglas ON personas.asignacion;
CREATE TRIGGER trg_asignacion_valida_reglas
  BEFORE INSERT OR UPDATE OF persona_id, puesto_id, vigente_desde, vigente_hasta ON personas.asignacion
  FOR EACH ROW EXECUTE FUNCTION personas.fn_asignacion_valida_reglas();
