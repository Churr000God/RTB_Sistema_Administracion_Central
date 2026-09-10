-- 50_tiempo_fn_ausencia_resolver.sql
-- RPC transaccional de "resolver ausencia" (SCJ-PRO-08 §V: "reclasificar el tipo es parte de la
-- misma transacción que aprobar -- UPDATE tiempo.ausencia.tipo_de_ausencia + INSERT tiempo.
-- aprobacion_ausencia no pueden quedar separados"). backend/app/routers/ausencias.py lo hacía en
-- 2 llamadas REST separadas -- un fallo entre el UPDATE y el INSERT deja la ausencia reclasificada
-- sin aprobación real. Mismo motivo y mismo patrón que tiempo.fn_jornada_asignar_renovar (Fase 1).
--
-- SECURITY INVOKER (default, no se escribe SECURITY DEFINER): corre con los permisos del caller
-- para que la RLS de tiempo.ausencia/tiempo.aprobacion_ausencia (49_tiempo_rls_ausencia_
-- aprobacion.sql) siga aplicando igual que un UPDATE/INSERT directo -- el caller sigue
-- necesitando ausencia_edicion (para el UPDATE de reclasificación) y aprobacion_ausencia_edicion
-- (para el INSERT del paso). backend sigue gateando además con requiere_todos_los_permisos(...)
-- para el 403 legible -- la RLS es la autorización real, este RPC no cambia eso.
--
-- aprobador_id se resuelve DENTRO de la función (misma CTE que personas.fn_caller_tiene_permiso:
-- personas.usuario por auth.uid()) en vez de recibirlo como parámetro -- backend ya no necesita
-- resolver_persona_id() antes de llamar, una fuente menos de inconsistencia entre quién autentica
-- y quién queda registrado como aprobador.
--
-- numero_paso=1 fijo -- flujo de un solo paso, sin jerarquía (SCJ-PRO-08 §V, "no hay cadena
-- RH-Dirección para este flujo").
--
-- Señales de conflicto, 3 ERRCODE propios (mismo patrón que 'SCJ01' de fn_jornada_asignar_
-- renovar -- cada caso con su propio código porque cada uno mapea a un status HTTP distinto en
-- backend, a diferencia de SCJ01 que sólo tenía un caso):
--   'SCJ02' ausencia_id no existe (o no es visible por RLS -- mismo criterio de siempre, sin
--     distinguir "no existe" de "no la puedo ver") -> backend mapea a 404, mismo mensaje que ya
--     usa MENSAJE_AUSENCIA_NO_ENCONTRADA.
--   'SCJ03' la ausencia ya no está pendiente -> backend mapea a 409, mismo mensaje que ya usa
--     MENSAJE_AUSENCIA_YA_RESUELTA. La carrera de dos personas resolviendo a la vez (SCJ-PRO-08
--     §III H1-H2) sigue cubierta por uq_aprobacion_ausencia_paso -- ese caso llega como 23505 real
--     (no este código), backend ya lo atrapa así.
--   'SCJ04' decision='autorizada' sin p_tipo_de_ausencia válido -- backend mapea a 422, mismo
--     mensaje que ya usa el validador de Pydantic (ResolverAusenciaCreate). decision inválida
--     (ni 'autorizada' ni 'rechazada') no tiene código propio -- la atrapa
--     ck_aprobacion_ausencia_decision con un 23514 genérico, backend ya cae al 422 con
--     error.message crudo para eso, no hace falta duplicarlo.
-- Depende de: 02_tiempo.sql, 49_tiempo_rls_ausencia_aprobacion.sql
-- Justificación: SCJ-PRO-08 §V

CREATE FUNCTION tiempo.fn_ausencia_resolver(
  p_ausencia_id       bigint,
  p_decision          varchar(20),
  p_tipo_de_ausencia  varchar(30) DEFAULT NULL,
  p_motivo            text DEFAULT NULL
) RETURNS tiempo.ausencia AS $$
DECLARE
  v_estado_actual  varchar(20);
  v_aprobador_id   uuid;
  v_resultado      tiempo.ausencia;
BEGIN
  SELECT estado_autorizacion INTO v_estado_actual
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

  IF p_decision = 'autorizada'
     AND (p_tipo_de_ausencia IS NULL
          OR p_tipo_de_ausencia NOT IN ('vacaciones', 'permiso_con_goce', 'permiso_sin_goce', 'incapacidad'))
  THEN
    RAISE EXCEPTION
      'tipo_de_ausencia es obligatorio al autorizar y debe ser uno de: vacaciones, '
      'permiso_con_goce, permiso_sin_goce, incapacidad (recibido: %)', p_tipo_de_ausencia
      USING ERRCODE = 'SCJ04';
  END IF;

  SELECT u.persona_id INTO v_aprobador_id
  FROM personas.usuario u
  WHERE u.auth_user_id = auth.uid();

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
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) IS
  'RPC transaccional de "resolver ausencia" (SCJ-PRO-08): si decision=autorizada, reclasifica '
  'tipo_de_ausencia; siempre inserta el paso 1 de aprobacion_ausencia con el resultado -- ambas '
  'escrituras en una sola transacción. trg_aprobacion_ausencia_actualiza_ausencia recalcula '
  'estado_autorizacion solo. Señales de conflicto: ERRCODE SCJ02 (ausencia no existe/no visible), '
  'SCJ03 (ya resuelta), SCJ04 (tipo_de_ausencia inválido/faltante para autorizada) -- ver cabecera '
  'de 50_tiempo_fn_ausencia_resolver.sql para el mapeo exacto que debe hacer backend.';

GRANT EXECUTE ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_ausencia_resolver(bigint, varchar, varchar, text) FROM PUBLIC;
