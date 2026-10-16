-- 115_personas_asignacion_limite_de_plazas.sql
-- Límite de PLAZAS en la base (hoy solo lo valida Python: routers/asignaciones.py::_validar_puesto_con_plazas_libres, que es una lectura-y-después-escritura SIN bloqueo y que PostgREST directo se salta).
-- INDEPENDIENTE de 113_/114_ (solo usa auth.uid()). APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 115_*.sql`.
--
-- trg_asignacion_valida_plazas: BEFORE INSERT OR UPDATE OF puesto_id, vigente_hasta ON personas.asignacion, FOR EACH ROW -> personas.fn_asignacion_valida_plazas().
-- La fila RESULTANTE «ocupa plaza» si NEW.vigente_hasta IS NULL. Se comprueba solo cuando esa ocupación es NUEVA: INSERT de una vigente, UPDATE que la REABRE (OLD.vigente_hasta NOT NULL -> NULL) o UPDATE que
-- cambia puesto_id de una vigente. Se cuentan las OTRAS asignaciones vigentes del puesto destino (id <> NEW.id); si otras + 1 > plazas_totales => ERRCODE SCJ21, HINT 'plazas_llenas', mensaje fijo.
--  - Orden dentro de una transacción: fn_asignacion_cambiar_puesto primero CIERRA la fila vieja y luego INSERTA la nueva; el conteo ve la propia transacción, así que no cuenta la que acaba de cerrar. Cambiar
--    a un puesto con la plaza libre pasa; a uno lleno falla y la función revierte completa.
--  - Guarda de inicio: si el caller no está activo o no tiene asignacion_edicion, el trigger devuelve NEW sin hacer nada (no toma el candado ni puede revelar la ocupación de un puesto con un SCJ21); la RLS
--    de INSERT/UPDATE de asignacion lo rechaza con 42501.
--  - Carrera entre dos altas simultáneas: pg_advisory_xact_lock sobre el puesto destino serializa las comprobaciones concurrentes (la segunda espera a que la primera confirme o revierta y ve su fila). Se usa un
--    candado consultivo y no `SELECT … FOR UPDATE` sobre personas.puesto porque, como INVOKER, el FOR UPDATE respeta la RLS de UPDATE de puesto (puesto_edicion): para quien solo tiene asignacion_edicion
--    no tomaría el candado en silencio. El candado se libera solo al terminar la transacción. LA SERIALIZACIÓN DEPENDE DE READ COMMITTED (ver el comentario de la función): en REPEATABLE READ no valdría.
--  - La función es SECURITY DEFINER (search_path fijo, sin EXECUTE para nadie, regla de 105_): cuenta TODAS las vigentes del puesto sin depender de lo que la RLS de asignacion le deje ver al caller.
--    No devuelve datos: solo acepta o lanza el error fijo.
--  - Excepción auth.uid() nulo (dueño/service_role: bootstrap del usuario base, migraciones): no comprueba. DATO REAL: «Gerente o Encargado de TI» (puesto administrador) ya tiene 2 vigentes con
--    plazas_totales = 1; el trigger no toca filas existentes ni UPDATE de otras columnas, y un nuevo alta ahí por la API quedaría rechazada.
--  - NO cubre: reducir plazas_totales por debajo de lo ocupado (es un UPDATE de puesto, otro asunto), ni puestos inactivos (lo valida el backend).
--
-- Inventario de RLS: sin cambios. Un trigger y una función nuevos. Verificador: sección 80 (solo violaciones).
-- REVERSA: DROP TRIGGER trg_asignacion_valida_plazas ON personas.asignacion; DROP FUNCTION personas.fn_asignacion_valida_plazas(); (probada en ensayo_115.)

CREATE FUNCTION personas.fn_asignacion_valida_plazas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_plazas integer;
  v_otras  bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- Guarda de inicio (security): quien no puede escribir asignaciones no debe ejecutar nada de este trigger DEFINER (ni tomar el candado, ni que un SCJ21 revele cuánta ocupación hay): se devuelve NEW y la RLS
  -- de INSERT/UPDATE lo rechaza con 42501 como siempre.
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion')) THEN
    RETURN NEW;
  END IF;

  -- Solo importa si la fila RESULTANTE ocupa plaza y esa ocupación es nueva en este puesto.
  IF NEW.vigente_hasta IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.vigente_hasta IS NULL AND NEW.puesto_id IS NOT DISTINCT FROM OLD.puesto_id THEN
    RETURN NEW;
  END IF;

  -- Serializa las comprobaciones concurrentes sobre el mismo puesto (se libera al terminar la transacción). OJO: esto solo es correcto en READ COMMITTED (el nivel por defecto y el que usa PostgREST): la segunda
  -- transacción, al obtener el candado, ejecuta el conteo con una instantánea NUEVA y ve la fila de la primera; en REPEATABLE READ/SERIALIZABLE la instantánea se fijó antes del candado y NO valdría.
  PERFORM pg_advisory_xact_lock(hashtextextended('personas.asignacion.plazas:' || NEW.puesto_id::text, 0));

  SELECT p.plazas_totales INTO v_plazas FROM personas.puesto p WHERE p.id = NEW.puesto_id;
  IF v_plazas IS NULL THEN
    RETURN NEW;   -- puesto inexistente: lo rechaza la FK
  END IF;

  SELECT count(*) INTO v_otras
  FROM personas.asignacion a
  WHERE a.puesto_id = NEW.puesto_id AND a.vigente_hasta IS NULL AND a.id <> NEW.id;

  IF v_otras + 1 > v_plazas THEN
    RAISE EXCEPTION 'El puesto no tiene plazas libres.'
      USING ERRCODE = 'SCJ21', HINT = 'plazas_llenas';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_asignacion_valida_plazas() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION personas.fn_asignacion_valida_plazas() IS
  'Trigger de personas.asignacion (115_): una asignación vigente nueva, reabierta o movida de puesto no puede dejar el puesto por encima de plazas_totales (SCJ21, hint plazas_llenas). Candado consultivo por puesto (pg_advisory_xact_lock) contra altas simultáneas: la serialización depende de READ COMMITTED (en REPEATABLE READ/SERIALIZABLE no valdría). DEFINER con search_path fijo; sin EXECUTE para nadie; sin efecto si auth.uid() es nulo ni para quien no está activo con asignacion_edicion (la RLS lo rechaza).';

CREATE TRIGGER trg_asignacion_valida_plazas
  BEFORE INSERT OR UPDATE OF puesto_id, vigente_hasta ON personas.asignacion
  FOR EACH ROW EXECUTE FUNCTION personas.fn_asignacion_valida_plazas();
