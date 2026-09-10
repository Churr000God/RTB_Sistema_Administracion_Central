-- 43_personas_tiempo_sincroniza_alta.sql
-- Sincronización personas.persona -> tiempo.persona (SCJ-FRO-01: persona_id es el único dato que
-- cruza la frontera). Hallazgo de testing en el checkpoint de Fase 1: tiempo.persona estaba vacía
-- -- ningún flujo real la poblaba, testing tuvo que insertar una fila puente a mano para probar
-- SCJ-PRO-09 en vivo. Bloquea cualquier proceso de Tiempo que referencie una persona real desde
-- Fase 2 en adelante.
--
-- Nota sobre 01_persona_stub.sql: su comentario original decía "en operación se sincroniza desde
-- personas.persona; en este proyecto lo puebla el generador de datos sintéticos" -- esa era la
-- intención cuando personas era sólo un stub externo. Ya no aplica tal cual: personas.persona es
-- implementación real de este mismo proyecto desde 2026-08-31 (04_personas.sql), y
-- tools/generador/ (SCJ-GEN-01) sigue vacío sin fecha cierta. Un trigger en la propia base es más
-- confiable que depender de un generador aún no construido -- no se edita el comentario de 01_
-- (no se reescriben migraciones ya aplicadas, mismo criterio que el resto del proyecto), se deja
-- esta nota acá como registro de la decisión.
--
-- Sólo alta, no baja/reactivación: personas.persona no tiene DELETE físico -- baja_definitiva sólo
-- cambia estado/fecha_baja (trg_persona_sincroniza_baja, 04_personas.sql), la fila y el id
-- persisten para siempre. tiempo.persona no tiene columna estado que reflejar (sigue siendo sólo
-- el ancla uuid, 01_persona_stub.sql) -- no hay ningún evento de baja/reactivación que propagar.
-- AFTER INSERT alcanza.
--
-- SECURITY DEFINER: alta_persona (backend/app/routers/personas.py) inserta en personas.persona vía
-- get_caller_client (RLS, requiere alta_personas_usuarios) -- ese caller no tiene por qué tener
-- INSERT en tiempo.persona (que además no tiene ninguna policy de INSERT, sólo la de SELECT de
-- 42_*.sql). Mismo motivo que personas.fn_caller_activo(): sin SECURITY DEFINER, el trigger
-- fallaría por RLS en vez de sincronizar. search_path fijo por la misma razón que cualquier
-- SECURITY DEFINER del proyecto.
-- Depende de: 01_persona_stub.sql, 04_personas.sql

CREATE FUNCTION personas.fn_persona_sincroniza_tiempo()
RETURNS trigger AS $$
BEGIN
  INSERT INTO tiempo.persona (id) VALUES (NEW.id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = personas, tiempo, pg_temp;

CREATE TRIGGER trg_persona_sincroniza_tiempo
  AFTER INSERT ON personas.persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_persona_sincroniza_tiempo();

COMMENT ON FUNCTION personas.fn_persona_sincroniza_tiempo() IS
  'Crea el ancla tiempo.persona(id) al dar de alta una personas.persona -- sólo el id, ningún '
  'atributo de identidad cruza la frontera (SCJ-FRO-01). ON CONFLICT DO NOTHING: idempotente '
  'frente al backfill de este mismo archivo y frente a cualquier fila puente insertada a mano '
  'antes de que este trigger existiera. SECURITY DEFINER: el caller de alta_persona no tiene '
  'INSERT en tiempo.persona por RLS -- ver cabecera de 43_personas_tiempo_sincroniza_alta.sql.';

-- Backfill de una sola vez: toda personas.persona que no tenga todavía su ancla en tiempo.persona
-- (incluida la fila puente que testing insertó a mano -- ON CONFLICT DO NOTHING no la duplica ni
-- la pisa, LEFT JOIN ... WHERE NULL tampoco la vuelve a tocar si ya existe).
INSERT INTO tiempo.persona (id)
SELECT p.id
FROM personas.persona p
LEFT JOIN tiempo.persona t ON t.id = p.id
WHERE t.id IS NULL
ON CONFLICT DO NOTHING;
