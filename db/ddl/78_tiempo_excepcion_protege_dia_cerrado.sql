-- 78_tiempo_excepcion_protege_dia_cerrado.sql
-- Fix de hallazgo de seguridad (security, 2026-09-15): tiempo.excepcion (RLS real desde
-- 48_tiempo_rls_correccion_excepcion.sql) permite a cualquiera con excepcion_edicion (RH, Gerente
-- General, herencia jerárquica) resolver CUALQUIER excepción pendiente vía PostgREST directo, sin
-- pasar por ningún trigger/RPC -- incluida motivo dia_cerrado, que por diseño nunca debería tener
-- vía de resolución humana directa (02_tiempo.sql:719/72_*.sql:50, "Nunca lo reabre, sólo se
-- señala"). Encontrado investigando las filas id=9/10 (dia_id=5, ver 77_*.sql sección "Alcance
-- explícitamente NO tocado") -- resueltas sin que exista ningún mecanismo del DDL que lo explique,
-- mismo patrón que el gotcha ya documentado en CLAUDE.md del 7 de septiembre (UPDATE/RPC directo
-- contra la BD real, no un flujo legítimo).
--
-- La única resolución legítima de una excepción dia_cerrado es efecto colateral de
-- fn_dia_revisar (74_*.sql/77_*.sql): cuando arma un tramo nuevo/existente con la marca tardía
-- como apertura o cierre, la UPDATE de tiempo.excepcion (líneas "marca_id IN
-- (v_accion.marca_apertura_id, v_accion.marca_cierre_id)") resuelve de paso la excepción de esa
-- marca -- el propio comentario de fn_dia_revisar (77_*.sql) ya lo documenta explícito ("incluido
-- motivo dia_cerrado"). El problema para distinguir origen: fn_dia_revisar es SECURITY INVOKER
-- (comentario propio, sin ALTER FUNCTION posterior -- verificado por grep, cero resultados) y
-- corre con los mismos privilegios que un UPDATE directo del mismo caller humano -- un trigger
-- BEFORE UPDATE convencional (mismo mecanismo de 70_personas_persona_update_columnas.sql) no
-- alcanza a distinguir "esto lo disparó fn_dia_revisar" de "esto lo tecleó alguien en PostgREST",
-- porque ambos casos comparten exactamente el mismo rol/permiso.
--
-- Lo que SÍ distingue los dos casos es el ESTADO RESULTANTE de la transacción: dentro de
-- fn_dia_revisar, la UPDATE de tiempo.excepcion sucede ANTES de la UPDATE final que pone
-- tiempo.dia.estado = 'revisado' (mismo cuerpo de función, misma transacción) -- así que un
-- trigger BEFORE UPDATE normal vería el día todavía en 'bloqueado'/'cerrado' incluso en el caso
-- legítimo, y no podría aprobarlo sin aprobar también el caso ilegítimo. La solución es un
-- CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED (AFTER UPDATE): Postgres pospone su
-- evaluación hasta el COMMIT de la transacción completa -- para entonces, si el UPDATE vino de
-- fn_dia_revisar, tiempo.dia.estado ya es 'revisado' en la misma transacción; si vino de un UPDATE
-- suelto de PostgREST (transacción propia, de una sola sentencia), tiempo.dia sigue exactamente
-- como estaba y el chequeo falla, revirtiendo también esa UPDATE ilegítima. Primer uso de
-- CONSTRAINT TRIGGER DEFERRABLE en el proyecto -- no hay mecanismo previo más simple que resuelva
-- correctamente el caso legítimo (chequear sólo el permiso dia_revision_edicion no alcanza: RH/
-- Gerente General/TI ya lo tienen igual que excepcion_edicion, no distingue nada).
--
-- SECURITY DEFINER (con SET search_path, mismo patrón que fn_ausencia_resuelve_excepcion,
-- 51_*.sql): la verificación no debe depender de que el caller tenga además dia_lectura/
-- tramo_lectura (44_*.sql/54_*.sql) -- ninguno de los 3 puestos con excepcion_edicion/
-- dia_revision_edicion tiene garantizado ninguno de esos dos hoy, y esta es una invariante de
-- seguridad, no una lectura de negocio que deba respetar RLS del caller.
--
-- Depende de: 02_tiempo.sql, 48_tiempo_rls_correccion_excepcion.sql,
--   51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql,
--   54_tiempo_rls_tramo_lectura.sql, 74_tiempo_fn_dia_revisar_resuelve_excepcion_de_dia.sql,
--   77_tiempo_dia_revision_admite_cerrado.sql

CREATE FUNCTION tiempo.fn_excepcion_protege_dia_cerrado()
RETURNS trigger
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM tiempo.tramo t
    JOIN tiempo.dia d ON d.id = t.dia_id
    WHERE (t.marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id)
      AND d.estado = 'revisado'
  ) THEN
    RAISE EXCEPTION
      'La excepción % (motivo dia_cerrado, marca %) no puede resolverse fuera de fn_dia_revisar -- '
      'el día correspondiente debe quedar revisado en la misma transacción', NEW.id, NEW.marca_id
      USING ERRCODE = '42501';
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_excepcion_protege_dia_cerrado() IS
  'Constraint trigger de sólo motivo dia_cerrado: bloquea (revirtiendo toda la transacción, por '
  'DEFERRABLE INITIALLY DEFERRED) cualquier pendiente -> resuelto que no sea efecto colateral real '
  'de fn_dia_revisar armando un tramo con esa marca sobre un día que terminó revisado en la misma '
  'transacción. SECURITY DEFINER a propósito -- ver cabecera de 78_*.sql.';

CREATE CONSTRAINT TRIGGER trg_excepcion_protege_dia_cerrado
  AFTER UPDATE ON tiempo.excepcion
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (
    OLD.motivo_revision = 'dia_cerrado'
    AND OLD.estado = 'pendiente'
    AND NEW.estado = 'resuelto'
  )
  EXECUTE FUNCTION tiempo.fn_excepcion_protege_dia_cerrado();

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_protege_dia_cerrado() FROM PUBLIC;
