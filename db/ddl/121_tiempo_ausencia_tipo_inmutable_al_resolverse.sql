-- 121_tiempo_ausencia_tipo_inmutable_al_resolverse.sql
-- Hallazgo ALTO A1b de security: bloquear el cambio de tipo_de_ausencia de una ausencia que ya NO está pendiente.
--
-- POR QUÉ. El corte quincenal ahora confía en tiempo.ausencia (118_/119_): tipo con goce + estado 'autorizada' cuenta la jornada esperada como trabajada. Hoy cualquiera con ausencia_edicion puede cambiar
-- tipo_de_ausencia por PostgREST en una ausencia YA resuelta: la policy ausencia_update_requiere_permiso de 49_ solo exige persona activa y el permiso, y 53_ dejó GRANT UPDATE (tipo_de_ausencia) a authenticated.
-- Pasar un permiso_sin_goce autorizado a permiso_con_goce borraría deuda sin aprobación nueva ni rastro. (Los días ya materializados no se reescriben solos, pero el corte lee el tipo de la ausencia.)
--
-- QUÉ HACE (dos capas, patrón de 70_ y 86_)
--  1. La policy ausencia_update_requiere_permiso exige además estado_autorizacion = 'pendiente' en USING (la fila vieja) y en WITH CHECK (la nueva). Cierra la vía de authenticated por PostgREST.
--  2. Trigger BEFORE UPDATE OF tipo_de_ausencia, WHEN (OLD.estado_autorizacion <> 'pendiente'), que levanta ERRCODE SCJ25 con HINT 'ausencia_resuelta_tipo_inmutable' y mensaje fijo si el tipo realmente cambia.
--     Cubre cualquier camino, también service_role y el dueño: la policy no los alcanza. Un SET al mismo valor (sin cambio) pasa.
--
-- NO ROMPE LA RECLASIFICACIÓN LEGÍTIMA. fn_ausencia_resolver (50_, SECURITY INVOKER) hace el UPDATE del tipo MIENTRAS la ausencia sigue pendiente y solo DESPUÉS inserta el paso en aprobacion_ausencia, cuyo trigger
--  (fn_aprobacion_ausencia_actualiza_ausencia, 52_) recalcula estado_autorizacion; ese trigger toca solo estado_autorizacion, no tipo_de_ausencia, así que no dispara este. Verificado leyendo 50_ y 52_ y en el ensayo.
--  CONSECUENCIA DE PRODUCTO (léase antes de aplicar): una ausencia ya resuelta NO se puede corregir por ningún camino de la aplicación ni de la API. Si se autorizó o rechazó con el tipo equivocado, solo se arregla
--  con acceso de SUPERUSUARIO: ALTER TABLE tiempo.ausencia DISABLE TRIGGER trg_ausencia_bloquea_cambio_tipo_resuelta dentro de UNA transacción, el UPDATE puntual y ENABLE TRIGGER, dejando registro de quién y por qué
--  (misma lección de 75_: un trigger que protege una fila impide también corregirla, sin excepción de rol). Un RECHAZO no se puede re-autorizar. «Registrar otra ausencia» no lo hace una persona desde la UI:
--  lo hace solo el sistema (el batch de cierre de día crea las ausencias nuevas con service_role, backend/app/batches/cierre_dia.py), y esa nueva ausencia exige su propia aprobación.
--
-- NO CAMBIA funciones existentes (no hay CREATE OR REPLACE de funciones ya vivas). Función nueva tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta(): trigger, SECURITY INVOKER, search_path fijo, SIN EXECUTE para nadie de la
--  API (REVOKE de 105_); al ser función de trigger no entra en la lista cerrada de la sección 70(d), que solo lista funciones con EXECUTE para authenticated.
-- INVENTARIO DE RLS: 1 policy de UPDATE reemplazada (tiempo.ausencia, mismo nombre, mismo comando y mismos roles). Sin tablas nuevas, sin GRANT nuevo.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 121_*.sql`.
-- REVERSA (en una transacción): DROP TRIGGER trg_ausencia_bloquea_cambio_tipo_resuelta; DROP FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta(); DROP POLICY y recrear con el texto de 49_ (sin el filtro de estado).
--  Texto exacto en db/ensayos/ensayo_121.sql, bloque reversa.
-- Depende de: 02_tiempo.sql, 49_*.sql, 50_*.sql, 52_*.sql, 53_*.sql, 105_*.sql
-- Justificación: SCJ-PRO-08, SCJ-PRO-13

-- 1) policy: solo se edita una ausencia pendiente
DROP POLICY ausencia_update_requiere_permiso ON tiempo.ausencia;
CREATE POLICY ausencia_update_requiere_permiso ON tiempo.ausencia
  FOR UPDATE
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
    AND estado_autorizacion = 'pendiente'
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
    AND estado_autorizacion = 'pendiente'
  );

-- 2) trigger: ningún camino cambia el tipo de una ausencia ya resuelta
CREATE FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  IF NEW.tipo_de_ausencia IS DISTINCT FROM OLD.tipo_de_ausencia THEN
    RAISE EXCEPTION 'No se puede cambiar el tipo de una ausencia que ya no está pendiente.'
      USING ERRCODE = 'SCJ25', HINT = 'ausencia_resuelta_tipo_inmutable';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta() IS
  'Trigger BEFORE UPDATE OF tipo_de_ausencia de tiempo.ausencia (121_): si la ausencia ya no está pendiente, cambiar su tipo levanta SCJ25 / ausencia_resuelta_tipo_inmutable, también para service_role y el dueño. '
  'La reclasificación legítima ocurre en fn_ausencia_resolver mientras sigue pendiente. Una ausencia resuelta con el tipo equivocado NO se puede corregir sin superusuario (ALTER TABLE … DISABLE TRIGGER en una transacción, con registro): ni siquiera service_role; un rechazo no se re-autoriza. INVOKER con search_path fijo; sin EXECUTE para nadie.';

CREATE TRIGGER trg_ausencia_bloquea_cambio_tipo_resuelta
  BEFORE UPDATE OF tipo_de_ausencia ON tiempo.ausencia
  FOR EACH ROW
  WHEN (OLD.estado_autorizacion <> 'pendiente')
  EXECUTE FUNCTION tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta();
