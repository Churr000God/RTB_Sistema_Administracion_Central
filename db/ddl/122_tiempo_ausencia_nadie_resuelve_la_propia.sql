-- 122_tiempo_ausencia_nadie_resuelve_la_propia.sql
-- Hallazgo MEDIO de security (aprobado por el usuario): nadie resuelve su propia ausencia, y la aprobación queda atada a quien la hace.
--
-- POR QUÉ. La policy de INSERT de tiempo.aprobacion_ausencia (49_) solo exige persona activa y aprobacion_ausencia_edicion: quien tiene ese permiso puede aprobarse a sí mismo una ausencia (el corte quincenal ahora cuenta
-- una ausencia con goce autorizada como jornada trabajada), y como aprobador_id llega en la fila, por PostgREST directo podía además registrar la aprobación a nombre de OTRA persona.
--
-- QUÉ HACE (tres capas)
--  1. Policy de INSERT de tiempo.aprobacion_ausencia recreada (mismo nombre, comando y rol): además de persona activa y aprobacion_ausencia_edicion, exige
--       aprobador_id = personas.fn_caller_persona_id()     -- la aprobación queda a nombre de quien la hace (la persona sale de auth.uid(), nunca del cliente)
--       AND NOT EXISTS (SELECT 1 FROM tiempo.ausencia a WHERE a.id = tiempo.aprobacion_ausencia.ausencia_id AND a.persona_id = tiempo.aprobacion_ausencia.aprobador_id)
--     Las columnas de la fila nueva se CALIFICAN con el nombre de la tabla dentro de la subconsulta (lección de 117_: un nombre sin calificar se resuelve a la columna del alias más cercano, p. ej.
--     `a.persona_id = aprobador_id` compararía la columna consigo misma, y la condición quedaría siempre verdadera). Ojo: esta subconsulta lee tiempo.ausencia con la RLS del caller; si el caller no pudiera ver la ausencia, la capa 3 es la que cierra el caso.
--  2. tiempo.fn_ausencia_resolver (50_, SECURITY INVOKER): error legible ANTES de escribir nada si la ausencia es del propio caller, con ERRCODE SCJ26 y HINT 'ausencia_propia' (mensaje fijo). Va después de SCJ02 (no existe) y
--     SCJ03 (ya resuelta) y antes del UPDATE del tipo y del INSERT del paso. Resto del cuerpo idéntico a 50_.
--  3. Trigger BEFORE INSERT tiempo.fn_aprobacion_ausencia_bloquea_propia() en tiempo.aprobacion_ausencia: si aprobador_id es la persona dueña de la ausencia, SCJ26 / ausencia_propia, SEA CUAL SEA el rol (también
--     service_role y el dueño, que la policy no alcanza) y aunque el caller no vea la ausencia por RLS. SECURITY DEFINER con search_path fijo para leer tiempo.ausencia sin depender de la RLS del caller; sin EXECUTE para nadie.
--     Se evaluó si hacía falta y se incluye: la policy sola no cubre service_role ni el dueño, y el costo es una lectura por índice (PK de ausencia) por INSERT, que ocurre una vez por resolución. Es el mismo patrón de 121_/86_.
--
--  4. (BAJO 1 de security) Policy de UPDATE de tiempo.ausencia (ausencia_update_requiere_permiso, la que recrea 121_) recreada partiendo del texto de 121_: además de persona activa, ausencia_edicion y
--     estado_autorizacion = 'pendiente', exige `persona_id <> (SELECT personas.fn_caller_persona_id())` en USING y en WITH CHECK, para que nadie edite el tipo de SU PROPIA ausencia pendiente (con el tipo
--     se decidiría qué se autoriza). Si el caller no tiene persona (NULL), la comparación no es verdadera y no edita nada. 122_ incluye el filtro de pendiente de 121_: aplicada sola es un superconjunto;
--     aplicada después de 121_ solo añade la condición nueva. NO se agrega trigger para esto: el trigger de 121_ ya cubre el cambio de tipo de una ausencia NO pendiente por cualquier rol, y la edición del
--     tipo en una pendiente por service_role o el dueño es el camino legítimo del sistema (no hay caller humano).
--
-- QUÉ NO CAMBIA. aprobador_id sigue saliendo de personas.usuario por auth.uid() dentro de fn_ausencia_resolver; el flujo de un paso, el SCJ02/SCJ03/SCJ04, la firma, el ACL (GRANT a authenticated, nada a PUBLIC),
--  el trigger de 52_ que recalcula el estado y el de 02_ que materializa los días. La resolución de la ausencia de OTRA persona (con reclasificación y materialización del día) funciona igual.
-- Gotcha de CREATE OR REPLACE (CLAUDE.md): se buscó fn_ausencia_resolver en todo db/ddl; no tiene ALTER FUNCTION posterior a 50_ (el único cambio de ACL es el GRANT/REVOKE de 50_). Es SECURITY INVOKER; a
--  diferencia de 50_ se le fija SET search_path = tiempo, personas, pg_temp (endurecimiento; su cuerpo califica todo con esquema). CREATE OR REPLACE conserva el ACL; se repite igual el GRANT/REVOKE por claridad.
-- INVENTARIO DE RLS: 1 policy de INSERT reemplazada (tiempo.aprobacion_ausencia) y 1 de UPDATE (tiempo.ausencia, mismo nombre, comando y rol); sin tablas nuevas; sin GRANT nuevo.
-- Backend debe mapear SCJ26 / 'ausencia_propia' (hoy cae al 422 genérico o al 500 si no se mapea).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 122_*.sql`.
-- REVERSA (en una transacción): recrear ausencia_update_requiere_permiso con el texto de 121_ (o de 49_ si 121_ no está aplicada); DROP TRIGGER trg_aprobacion_ausencia_bloquea_propia; DROP FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia(); DROP POLICY y recrearla con el texto de 49_; DROP FUNCTION
--  tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) y volver a correr 50_ (CREATE FUNCTION). Texto exacto en db/ensayos/ensayo_122.sql, bloque reversa.
-- Depende de: 02_tiempo.sql, 49_*.sql, 50_*.sql, 52_*.sql, 88_*.sql (fn_caller_persona_id), 105_*.sql
-- Justificación: SCJ-PRO-08

-- 1) policy
DROP POLICY aprobacion_ausencia_insert_requiere_permiso ON tiempo.aprobacion_ausencia;
CREATE POLICY aprobacion_ausencia_insert_requiere_permiso ON tiempo.aprobacion_ausencia
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion')
    AND aprobador_id = (SELECT personas.fn_caller_persona_id())
    AND NOT EXISTS (
      SELECT 1 FROM tiempo.ausencia a
      WHERE a.id = tiempo.aprobacion_ausencia.ausencia_id
        AND a.persona_id = tiempo.aprobacion_ausencia.aprobador_id
    )
  );

-- 4) policy de UPDATE de ausencia: nadie edita el tipo de su propia ausencia pendiente
DROP POLICY ausencia_update_requiere_permiso ON tiempo.ausencia;
CREATE POLICY ausencia_update_requiere_permiso ON tiempo.ausencia
  FOR UPDATE
  TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
    AND estado_autorizacion = 'pendiente'
    AND persona_id <> (SELECT personas.fn_caller_persona_id())
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')
    AND estado_autorizacion = 'pendiente'
    AND persona_id <> (SELECT personas.fn_caller_persona_id())
  );

-- 3) trigger (se crea antes de reemplazar el RPC; el orden entre 2 y 3 es indiferente)
CREATE FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tiempo.ausencia a WHERE a.id = NEW.ausencia_id AND a.persona_id = NEW.aprobador_id) THEN
    RAISE EXCEPTION 'No puedes resolver tu propia ausencia.' USING ERRCODE = 'SCJ26', HINT = 'ausencia_propia';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia() IS
  'Trigger BEFORE INSERT de tiempo.aprobacion_ausencia (122_): nadie aprueba ni rechaza su propia ausencia (SCJ26 / ausencia_propia), sea cual sea el rol, incluso service_role y el dueño. SECURITY DEFINER con search_path '
  'fijo (lee tiempo.ausencia sin depender de la RLS del caller); sin EXECUTE para nadie.';

CREATE TRIGGER trg_aprobacion_ausencia_bloquea_propia
  BEFORE INSERT ON tiempo.aprobacion_ausencia
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_aprobacion_ausencia_bloquea_propia();

-- 2) RPC
CREATE OR REPLACE FUNCTION tiempo.fn_ausencia_resolver(
  p_ausencia_id       bigint,
  p_decision          varchar(20),
  p_tipo_de_ausencia  varchar(30) DEFAULT NULL,
  p_motivo            text DEFAULT NULL
) RETURNS tiempo.ausencia
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_estado_actual  varchar(20);
  v_persona_aus    uuid;
  v_aprobador_id   uuid;
  v_resultado      tiempo.ausencia;
BEGIN
  SELECT estado_autorizacion, persona_id INTO v_estado_actual, v_persona_aus
  FROM tiempo.ausencia
  WHERE id = p_ausencia_id;

  IF v_estado_actual IS NULL THEN
    RAISE EXCEPTION 'La ausencia % no existe', p_ausencia_id USING ERRCODE = 'SCJ02';
  END IF;

  IF v_estado_actual <> 'pendiente' THEN
    RAISE EXCEPTION
      'La ausencia % ya fue resuelta (estado_autorizacion=%) -- alguien más se adelantó',
      p_ausencia_id, v_estado_actual
      USING ERRCODE = 'SCJ03';
  END IF;

  SELECT u.persona_id INTO v_aprobador_id
  FROM personas.usuario u
  WHERE u.auth_user_id = auth.uid();

  -- 122_: nadie resuelve su propia ausencia; se rechaza ANTES de escribir nada.
  IF v_aprobador_id IS NOT NULL AND v_aprobador_id = v_persona_aus THEN
    RAISE EXCEPTION 'No puedes resolver tu propia ausencia.' USING ERRCODE = 'SCJ26', HINT = 'ausencia_propia';
  END IF;

  IF p_decision = 'autorizada'
     AND (p_tipo_de_ausencia IS NULL
          OR p_tipo_de_ausencia NOT IN ('vacaciones', 'permiso_con_goce', 'permiso_sin_goce', 'incapacidad'))
  THEN
    RAISE EXCEPTION
      'tipo_de_ausencia es obligatorio al autorizar y debe ser uno de: vacaciones, '
      'permiso_con_goce, permiso_sin_goce, incapacidad (recibido: %)', p_tipo_de_ausencia
      USING ERRCODE = 'SCJ04';
  END IF;

  IF p_decision = 'autorizada' THEN
    UPDATE tiempo.ausencia
    SET tipo_de_ausencia = p_tipo_de_ausencia
    WHERE id = p_ausencia_id;
  END IF;

  INSERT INTO tiempo.aprobacion_ausencia (
    ausencia_id, numero_paso, aprobador_id, decision, motivo, decidido_en
  ) VALUES (
    p_ausencia_id, 1, v_aprobador_id, p_decision, p_motivo, now()
  );

  SELECT * INTO v_resultado FROM tiempo.ausencia WHERE id = p_ausencia_id;

  RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) IS
  'RPC transaccional de "resolver ausencia" (SCJ-PRO-08): si decision=autorizada, reclasifica tipo_de_ausencia; siempre inserta el paso 1 de aprobacion_ausencia con el resultado -- ambas escrituras en una sola '
  'transacción. trg_aprobacion_ausencia_actualiza_ausencia recalcula estado_autorizacion solo. Señales de conflicto: ERRCODE SCJ02 (ausencia no existe/no visible), SCJ03 (ya resuelta), SCJ04 (tipo_de_ausencia '
  'inválido/faltante para autorizada), SCJ26 / HINT ausencia_propia (122_: la ausencia es de quien la resuelve) -- ver cabecera de 50_ y de 122_ para el mapeo que debe hacer backend. SECURITY INVOKER con search_path fijo.';

GRANT EXECUTE ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) FROM PUBLIC;
