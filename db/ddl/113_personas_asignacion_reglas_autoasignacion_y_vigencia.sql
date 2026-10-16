-- 113_personas_asignacion_reglas_autoasignacion_y_vigencia.sql
-- Cierra dos huecos de personas.asignacion que la RLS no puede expresar (hallazgo de testing, verificado por security):
--  (1) AUTOASIGNACIÓN. La policy de INSERT/UPDATE solo exige asignacion_edicion; quien la tiene (p. ej. Responsable de RH) podía terminar la asignación ajena de un puesto con más permisos, asignarse a sí mismo
--      a ese puesto y heredar todo, sin pasar por otorgar_permiso. Y la policy se usa por PostgREST directo: un chequeo en Python no basta.
--  (2) VIGENCIA FUTURA. «vigente_hasta IS NULL» significa «vigente» en todo el sistema (fn_caller_tiene_permiso, permisos.py, vistas); una asignación con vigente_desde FUTURO daba permisos YA.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 113_*.sql`.
--
-- CONTENIDO (una función de apoyo, un trigger):
--  1. personas.fn_hoy_mexico(p_ahora timestamptz DEFAULT now()) RETURNS date — STABLE, INVOKER, search_path fijo: la fecha de HOY en hora de México, (p_ahora AT TIME ZONE 'America/Mexico_City')::date.
--     NO se usa CURRENT_DATE: esta base corre en UTC y de 18:00 a 24:00 hora de México ya es «mañana» (gotcha de CLAUDE.md). El parámetro existe para poder ensayar la franja 18:00–24:00 con
--     instantes explícitos; el trigger la llama siempre con now(). EXECUTE authenticated y service_role (el trigger es INVOKER y la ejecuta el caller).
--  2. personas.fn_asignacion_valida_reglas() — función de TRIGGER, SECURITY INVOKER, search_path = personas, pg_temp, sin EXECUTE para nadie (regla de 105_).
--     trg_asignacion_valida_reglas: BEFORE INSERT OR UPDATE OF persona_id, puesto_id, vigente_desde ON personas.asignacion, FOR EACH ROW.
--       a) Si auth.uid() es NULL (bootstrap/migraciones con el dueño o service_role: así nace el usuario base) => no hace nada. Un humano que llega por la API SIEMPRE tiene auth.uid(); estos caminos
--          internos no son un vector de escalamiento y no se rompen. (La regla de fecha también se salta ahí a propósito: 26_ siembra con CURRENT_DATE, que en UTC de 18:00 a 24:00 hora de México es
--          «mañana», y reconstruir la base en esa franja fallaría. Alternativa si security prefiere aplicarla a todos: cambiar 26_ a fn_hoy_mexico(); ver el mensaje de entrega.)
--       b) NEW.persona_id = personas.fn_caller_persona_id() => ERRCODE SCJ19, HINT 'autoasignacion_no_permitida' (autoasignarse, recolocarse a sí mismo o mover a sí mismo una fila
--          ajena por UPDATE de persona_id/puesto_id). No hay excepción para el puesto administrador: el usuario base nace por service_role.
--       c) NEW.vigente_desde > fn_hoy_mexico() => ERRCODE SCJ20, HINT 'vigencia_futura_no_permitida'. Ninguna asignación puede quedar con fecha futura; el pasado y hoy se aceptan.
--     No intercepta UPDATE de vigente_hasta/actualizado_en (terminar una asignación, baja definitiva, fn_asignacion_cambiar_puesto sobre la fila vieja): la lista OF solo incluye las 3 columnas de la regla.
--     Mensajes fijos, sin identificadores.
--
-- IMPACTO PARA OTRAS CAPAS (avisar a backend/frontend):
--  - POST /api/asignaciones y fn_asignacion_cambiar_puesto(p_fecha): una fecha futura (permitida hasta hoy) ahora falla con SCJ20; hay que mapear SCJ19 y SCJ20 a 422 con mensaje fijo y limitar el campo de fecha
--    a hoy (México) en la pantalla. Quien cambia SU PROPIO puesto o se asigna a sí mismo recibe SCJ19 (422/403).
--  - Las filas existentes no se tocan (verificado: ninguna con vigente_desde futuro).
--
-- Inventario de RLS: sin policies nuevas ni cambiadas. Un trigger y dos funciones nuevas. Verificador: sección 78 (solo violaciones), 70(d) suma fn_hoy_mexico.
-- REVERSA (en una transacción; copia en el scratchpad de la sesión): DROP TRIGGER trg_asignacion_valida_reglas ON personas.asignacion; DROP FUNCTION personas.fn_asignacion_valida_reglas();
-- DROP FUNCTION personas.fn_hoy_mexico(timestamptz). Probada dentro de ensayo_113.

CREATE FUNCTION personas.fn_hoy_mexico(p_ahora timestamptz DEFAULT now())
RETURNS date
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
  SELECT (p_ahora AT TIME ZONE 'America/Mexico_City')::date;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_hoy_mexico(timestamptz) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_hoy_mexico(timestamptz) TO authenticated, service_role;
COMMENT ON FUNCTION personas.fn_hoy_mexico(timestamptz) IS
  'Fecha de HOY en hora de México (America/Mexico_City), no la de UTC (113_). El parámetro permite ensayar instantes concretos; el trigger de asignación la llama con now().';

CREATE FUNCTION personas.fn_asignacion_valida_reglas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
BEGIN
  -- Caminos internos sin sesión (migraciones, bootstrap del usuario base con service_role/dueño): no son un vector de escalamiento por la API.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.persona_id = personas.fn_caller_persona_id() THEN
    RAISE EXCEPTION 'No puede asignarse ni recolocarse a sí mismo en un puesto.'
      USING ERRCODE = 'SCJ19', HINT = 'autoasignacion_no_permitida';
  END IF;

  IF NEW.vigente_desde > personas.fn_hoy_mexico(now()) THEN
    RAISE EXCEPTION 'La asignación no puede tener una fecha de inicio futura.'
      USING ERRCODE = 'SCJ20', HINT = 'vigencia_futura_no_permitida';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_asignacion_valida_reglas() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION personas.fn_asignacion_valida_reglas() IS
  'Trigger de personas.asignacion (113_): rechaza autoasignación (SCJ19, hint autoasignacion_no_permitida) y vigente_desde posterior a hoy en México (SCJ20, hint vigencia_futura_no_permitida). Sin efecto si auth.uid() es nulo (bootstrap). Sin EXECUTE para nadie.';

CREATE TRIGGER trg_asignacion_valida_reglas
  BEFORE INSERT OR UPDATE OF persona_id, puesto_id, vigente_desde ON personas.asignacion
  FOR EACH ROW EXECUTE FUNCTION personas.fn_asignacion_valida_reglas();
