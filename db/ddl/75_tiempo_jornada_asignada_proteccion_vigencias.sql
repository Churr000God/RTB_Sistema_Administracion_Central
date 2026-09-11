-- 75_tiempo_jornada_asignada_proteccion_vigencias.sql
-- Feature nueva (2026-09-11, aprobada por el usuario): editar/eliminar jornadas FUTURAS de
-- tiempo.jornada_asignada, y mover vigente_hasta de la jornada EN CURSO -- hoy la tabla sólo
-- permite INSERT (vía fn_jornada_asignar_renovar, 40_*.sql/67_*.sql). Este archivo es la capa de
-- protección (Fase 1, bloqueante para backend/frontend); los RPCs de escritura reales van en
-- 76_tiempo_jornada_asignada_editar_eliminar_futura.sql.
--
-- Por qué triggers y no sólo políticas RLS más estrictas (39_tiempo_rls_jornada_patron.sql hoy
-- permite UPDATE/DELETE a cualquiera con jornada_asignada_edicion, SIN restricción de fecha --
-- hueco real, ver 39_*.sql): no alcanza con endurecer sólo la policy porque (a) "no tocar
-- vigente_desde de una fila que ya empezó" compara contra OLD, y el WITH CHECK de una policy de
-- UPDATE sólo ve NEW (misma lección que trg_persona_protege_columnas_identidad, 70_*.sql -- ver
-- CLAUDE.md, gotcha de "un OR agregado a una policy de UPDATE"); (b) "es la última de la cadena"
-- necesita una subconsulta sobre la misma tabla dentro de su propia policy, lo que en RLS produce
-- recursión infinita. Un trigger que rechaza aborta la transacción entera; una policy que sólo
-- filtra deja 0 filas afectadas en silencio, sin señal de error.
--
-- Grep previo: fn_jornada_asignar_renovar/jornada_asignada/patron_semanal no tienen ningún ALTER
-- FUNCTION posterior en todo db/ddl/*.sql fuera de los propios CREATE OR REPLACE ya versionados
-- (40_*.sql -> 67_*.sql) -- no aplica al gotcha de todos modos, los 4 triggers/funciones de este
-- archivo son enteramente nuevos.
--
-- Auditoría previa (Paso 0, sólo lectura, 2026-09-11): CERO personas con distinto de una jornada
-- abierta, CERO huecos/traslapes entre vigencias consecutivas -- la cadena de jornada_asignada
-- está limpia en toda la BD real. El trigger #4 (trg_jornada_asignada_valida_cadena) SÍ se aplica
-- en este corte.
--
-- SHOW timezone da UTC en esta sesión de Supabase -- OJO: CURRENT_DATE en los triggers/RPCs de
-- este archivo y del 76 evalúa "hoy" en UTC, no en hora real de México (UTC-6). Hay una ventana de
-- hasta 6 horas cada día (de medianoche a 6am hora CDMX) donde CURRENT_DATE ya avanzó al día
-- siguiente en el servidor mientras en México todavía es "ayer" -- mismo tipo de discrepancia que
-- el bug de desfase_local de hoy (72_*.sql/73_*.sql), pero en la dirección de fecha del calendario
-- de vigencias, no de hora de marca. No se corrige en este archivo (fuera del alcance que pidió
-- orchestrator) -- señalado en el reporte para que el usuario decida si hace falta fijar
-- SET timezone/usar (now() AT TIME ZONE 'America/Mexico_City')::date en un corte aparte.
--
-- Depende de: 02_tiempo.sql, 39_tiempo_rls_jornada_patron.sql, 67_tiempo_jornada_asignada_valida_
--   vigencia.sql (ck_jornada_asignada_vigencia, con el que estos triggers deben ser compatibles)
-- Justificación: SCJ-DEC-04 (vigencias sin traslape), feature "editar/eliminar jornada futura"
--   aprobada 2026-09-11 (ver plan de sesión, orchestrator)

-- ============================================================================
-- 1) trg_jornada_asignada_protege_vigencias (BEFORE UPDATE) -- reglas de qué se puede tocar según
-- si la fila ya empezó o no. Sin SECURITY DEFINER (mismo criterio que
-- fn_persona_protege_columnas_identidad, 70_*.sql) -- corre con los privilegios del caller, RLS
-- sigue siendo la autorización de fondo, este trigger es la restricción fina por columna/fecha que
-- RLS no puede expresar. horas_semanales_calculadas queda libre a propósito -- columna derivada,
-- nadie la escribe hoy (comentario propio en 02_tiempo.sql:99-100).
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_asignada_protege_vigencias()
RETURNS trigger AS $$
DECLARE
  v_tiene_posterior boolean;
BEGIN
  IF OLD.persona_id IS DISTINCT FROM NEW.persona_id THEN
    RAISE EXCEPTION 'persona_id de una jornada asignada es inmutable (id %)', OLD.id
      USING ERRCODE = '23514';
  END IF;

  IF OLD.vigente_desde IS DISTINCT FROM NEW.vigente_desde THEN
    IF OLD.vigente_desde <= CURRENT_DATE THEN
      RAISE EXCEPTION
        'No se puede mover la fecha de inicio de una jornada que ya empezó (id %, vigente_desde %)',
        OLD.id, OLD.vigente_desde USING ERRCODE = '23514';
    END IF;
    IF NEW.vigente_desde <= CURRENT_DATE THEN
      RAISE EXCEPTION
        'Una jornada futura sólo puede moverse a otra fecha futura (id %, intento %)',
        OLD.id, NEW.vigente_desde USING ERRCODE = '23514';
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM tiempo.jornada_asignada j
      WHERE j.persona_id = OLD.persona_id AND j.id <> OLD.id
        AND j.vigente_desde >= OLD.vigente_desde
    ) INTO v_tiene_posterior;
    IF v_tiene_posterior THEN
      RAISE EXCEPTION
        'Sólo se puede mover la fecha de inicio de la última jornada de la cadena (id %)', OLD.id
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF OLD.vigente_desde <= CURRENT_DATE AND (
       OLD.tipo_jornada                  IS DISTINCT FROM NEW.tipo_jornada
    OR OLD.descuento_comida_fija         IS DISTINCT FROM NEW.descuento_comida_fija
    OR OLD.minutos_descuento_comida_fija IS DISTINCT FROM NEW.minutos_descuento_comida_fija
    OR OLD.genera_alerta_horario         IS DISTINCT FROM NEW.genera_alerta_horario
  ) THEN
    RAISE EXCEPTION
      'De una jornada ya vigente sólo se puede mover vigente_hasta (id %)', OLD.id
      USING ERRCODE = '23514';
  END IF;

  -- Carve-out deliberado: OLD.vigente_hasta IS NULL (cerrar la fila abierta) queda SIN
  -- restringir -- es lo que hace fn_jornada_asignar_renovar y fn_jornada_futura_actualizar
  -- (archivo 76), incluido el caso de borde donde el cierre cae en el día de hoy.
  IF OLD.vigente_hasta IS DISTINCT FROM NEW.vigente_hasta AND OLD.vigente_hasta IS NOT NULL THEN
    IF OLD.vigente_hasta < CURRENT_DATE THEN
      RAISE EXCEPTION
        'No se puede reabrir ni mover el cierre de una jornada que ya terminó (id %, vigente_hasta %)',
        OLD.id, OLD.vigente_hasta USING ERRCODE = '23514';
    END IF;
    IF NEW.vigente_hasta IS NOT NULL AND NEW.vigente_hasta < CURRENT_DATE THEN
      RAISE EXCEPTION
        'El cierre de una jornada no puede quedar en el pasado (id %, intento %)',
        OLD.id, NEW.vigente_hasta USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_jornada_asignada_protege_vigencias
  BEFORE UPDATE ON tiempo.jornada_asignada
  FOR EACH ROW EXECUTE FUNCTION tiempo.fn_jornada_asignada_protege_vigencias();

REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_asignada_protege_vigencias() FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_asignada_protege_vigencias() IS
  'BEFORE UPDATE en tiempo.jornada_asignada. persona_id inmutable siempre; vigente_desde sólo se '
  'puede mover si la fila todavía no empezó, a otra fecha futura, y sólo si es la última de la '
  'cadena; tipo/patrón/descuento de una fila ya vigente son inmutables (sólo vigente_hasta se '
  'puede tocar); vigente_hasta no se puede reabrir/mover si ya quedó en el pasado, ni movida a una '
  'fecha pasada. RAISE con ERRCODE 23514 (check_violation) -- no SCJxx, es red de último recurso, '
  'cae en el 422 genérico existente (jornada_asignada.py:163). RLS sigue siendo la autorización de '
  'quién puede intentar el UPDATE (39_tiempo_rls_jornada_patron.sql); este trigger decide qué se '
  'le permite cambiar una vez autorizado.';

-- ============================================================================
-- 2) trg_jornada_asignada_protege_borrado (BEFORE DELETE) -- sólo se puede eliminar una jornada
-- futura que además sea la última de la cadena.
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_asignada_protege_borrado()
RETURNS trigger AS $$
BEGIN
  IF OLD.vigente_desde <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar una jornada que todavía no empezó (id %, vigente_desde %)',
      OLD.id, OLD.vigente_desde USING ERRCODE = '23514';
  END IF;

  IF OLD.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = OLD.persona_id AND j.id <> OLD.id
                  AND j.vigente_desde >= OLD.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar la última jornada de la cadena -- borrá desde el final hacia atrás (id %)',
      OLD.id USING ERRCODE = '23514';
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_jornada_asignada_protege_borrado
  BEFORE DELETE ON tiempo.jornada_asignada
  FOR EACH ROW EXECUTE FUNCTION tiempo.fn_jornada_asignada_protege_borrado();

REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_asignada_protege_borrado() FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_asignada_protege_borrado() IS
  'BEFORE DELETE en tiempo.jornada_asignada. Sólo permite borrar una fila con vigente_desde '
  'futura Y que sea la última de la cadena de esa persona (sin vigente_hasta, sin ninguna otra '
  'fila con vigente_desde >= la suya). RAISE con ERRCODE 23514, red de último recurso -- la '
  'autorización real de quién puede intentar el DELETE sigue siendo RLS '
  '(39_tiempo_rls_jornada_patron.sql).';

-- ============================================================================
-- 3) trg_patron_semanal_solo_jornada_futura (BEFORE UPDATE OR DELETE) -- el patrón semanal de una
-- jornada que ya empezó no se puede modificar ni borrar. INSERT queda deliberadamente FUERA: no
-- rompe el POST existente que puede insertar patrón de una jornada retroactiva
-- (fn_jornada_asignar_renovar no valida que vigente_desde sea futura). Residual conocido y
-- aceptado, fuera de alcance de este corte: alguien con patron_semanal_edicion podría AGREGAR
-- (nunca modificar/borrar) un día de patrón a una jornada en curso vía PostgREST directo.
-- ============================================================================

CREATE FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura()
RETURNS trigger AS $$
DECLARE
  v_jornada_id    bigint;
  v_vigente_desde date;
BEGIN
  v_jornada_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.jornada_asignada_id ELSE NEW.jornada_asignada_id END;

  SELECT vigente_desde INTO v_vigente_desde
  FROM tiempo.jornada_asignada WHERE id = v_jornada_id;

  IF v_vigente_desde IS NOT NULL AND v_vigente_desde <= CURRENT_DATE THEN
    RAISE EXCEPTION
      'El patrón semanal de una jornada que ya empezó no se puede modificar ni borrar (jornada %)',
      v_jornada_id USING ERRCODE = '23514';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_patron_semanal_solo_jornada_futura
  BEFORE UPDATE OR DELETE ON tiempo.patron_semanal
  FOR EACH ROW EXECUTE FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura();

REVOKE EXECUTE ON FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura() FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura() IS
  'BEFORE UPDATE OR DELETE en tiempo.patron_semanal. Bloquea tocar/borrar una fila de patrón que '
  'cuelga de una jornada_asignada con vigente_desde <= hoy. INSERT deliberadamente sin este '
  'trigger -- residual conocido, ver cabecera de 75_*.sql.';

-- ============================================================================
-- 4) trg_jornada_asignada_valida_cadena -- CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED
-- (obligatorio, mismo mecanismo que trg_patron_semanal_valida_tope_legal, 02_tiempo.sql:176 --
-- los RPCs de 76_*.sql pasan por estados intermedios inválidos dentro de la misma transacción,
-- p.ej. cerrar la predecesora antes de insertar/actualizar la sucesora). Sólo se aplica porque la
-- auditoría del Paso 0 (ver cabecera) salió limpia en toda la BD real.
--
-- Aviso para backend/tests: con este trigger activo, fn_jornada_asignar_renovar con un
-- vigente_desde retroactivo que caiga dentro de una fila ya cerrada empezaría a fallar (hoy lo
-- corrompe en silencio) -- mejora real de integridad, pero cambia el comportamiento del POST
-- existente. No se toca fn_jornada_asignar_renovar en este archivo.
-- ============================================================================

CREATE FUNCTION tiempo.fn_jornada_asignada_valida_cadena()
RETURNS trigger AS $$
DECLARE
  v_persona_id uuid;
  v_total      int;
  v_abiertas   int;
  v_rotas      int;
BEGIN
  v_persona_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.persona_id ELSE NEW.persona_id END;

  SELECT count(*) INTO v_total FROM tiempo.jornada_asignada WHERE persona_id = v_persona_id;
  IF v_total = 0 THEN RETURN NULL; END IF;

  SELECT count(*) INTO v_abiertas
  FROM tiempo.jornada_asignada WHERE persona_id = v_persona_id AND vigente_hasta IS NULL;

  IF v_abiertas <> 1 THEN
    RAISE EXCEPTION
      'La persona % debe quedar con exactamente una jornada abierta (quedó con %)',
      v_persona_id, v_abiertas USING ERRCODE = '23514';
  END IF;

  SELECT count(*) INTO v_rotas FROM (
    SELECT j.vigente_hasta,
           lead(j.vigente_desde) OVER (ORDER BY j.vigente_desde) AS siguiente_desde
    FROM tiempo.jornada_asignada j WHERE j.persona_id = v_persona_id
  ) t
  WHERE (t.siguiente_desde IS NULL) <> (t.vigente_hasta IS NULL)
     OR (t.siguiente_desde IS NOT NULL AND t.vigente_hasta <> t.siguiente_desde - 1);

  IF v_rotas > 0 THEN
    RAISE EXCEPTION
      'La cadena de jornadas de la persona % quedaría con hueco o traslape', v_persona_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_jornada_asignada_valida_cadena
  AFTER INSERT OR UPDATE OR DELETE ON tiempo.jornada_asignada
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION tiempo.fn_jornada_asignada_valida_cadena();

REVOKE EXECUTE ON FUNCTION tiempo.fn_jornada_asignada_valida_cadena() FROM PUBLIC;

COMMENT ON FUNCTION tiempo.fn_jornada_asignada_valida_cadena() IS
  'CONSTRAINT TRIGGER (DEFERRABLE INITIALLY DEFERRED) sobre tiempo.jornada_asignada -- red de '
  'seguridad final al hacer COMMIT: cada persona con al menos una jornada debe quedar con '
  'exactamente una fila abierta (vigente_hasta NULL) y sin huecos/traslapes entre vigencias '
  'consecutivas. Diferido a fin de transacción porque los RPCs de '
  '76_tiempo_jornada_asignada_editar_eliminar_futura.sql pasan por estados intermedios inválidos '
  '(p.ej. cerrar una fila antes de insertar/actualizar la siguiente). Aplicado sólo porque la '
  'auditoría de 2026-09-11 confirmó cero personas con la cadena rota en la BD real -- si esto '
  'cambia, este trigger empezaría a rechazar renovaciones retroactivas que hoy pasan en silencio '
  '(ver aviso en la cabecera del archivo).';
