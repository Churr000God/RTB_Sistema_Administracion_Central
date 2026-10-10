CREATE OR REPLACE FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica()
RETURNS trigger AS $$
DECLARE
  v_vivo         tiempo.terminal_usuario;
  v_id           bigint;
  v_employee_no  integer;
  v_estado       varchar(20);
  v_huellas      smallint;
  v_error        text;
  v_consent      bigint;
  v_vigente_id   bigint;
  v_vigente_ver  integer;
  v_usuario_creado_en timestamptz;
BEGIN
  -- ---- Filtro de autorización (88_, M1 de security) ---------------------------------------
  -- Este trigger es SECURITY DEFINER y corre ANTES del WITH CHECK de la RLS de INSERT. Un llamador de la API (rol anon/authenticated)
  -- que NO sea una persona activa con terminal_usuario_edicion, o cuyo movimiento no sea web, o sin sub, no debe obtener de aquí errores
  -- ni efectos (oráculo de altas/personas/terminales/versiones, nextval, fila viva, locks): se devuelve NEW sin hacer nada y la RLS
  -- responde 42501. El Pi (service_role) y el dueño no pasan por aquí (auth.role() distinto).
  IF auth.role() IN ('anon', 'authenticated')
     AND (auth.uid() IS NULL
          OR NEW.origen IS DISTINCT FROM 'web'
          OR NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))) THEN
    RETURN NEW;
  END IF;

  -- ---- asignado: crea la fila viva -------------------------------------------------------
  IF NEW.tipo_movimiento = 'asignado' THEN
    IF NEW.terminal_usuario_id IS NOT NULL OR NEW.employee_no IS NOT NULL THEN
      RAISE EXCEPTION
        'En "asignado" terminal_usuario_id y employee_no los asigna el servidor; deben llegar NULL'
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;

    -- Auto-asignación prohibida salvo el administrador genérico (decisión del usuario 2026-10-06; antes sólo la aplicaba el backend).
    -- Antes de cualquier efecto. Sólo para llamadores de la API (con sub): el dueño y service_role no tienen "propia persona".
    -- El actor sale de NEW.registrado_por (la policy lo ata a auth.uid()), no del contexto de la sesión.
    IF NEW.registrado_por IS NOT NULL
       AND NEW.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes asignarte a ti mismo a la terminal; la asigna otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_asignacion_prohibida';
    END IF;

    -- Antes del nextval: una asignación rechazada no debe quemar un employee_no. FOR SHARE (83_*.sql):
    -- bloquea la fila de la terminal frente a una desactivación concurrente (trigger SCJ13).
    PERFORM 1 FROM tiempo.terminal t WHERE t.id = NEW.terminal_id AND t.activa FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La terminal % no existe o no está activa; no se puede asignar',
        NEW.terminal_id USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM personas.persona p WHERE p.id = NEW.persona_id AND p.estado = 'activo'
    ) THEN
      RAISE EXCEPTION 'La persona % no existe o no está activa; no se puede asignar a la terminal',
        NEW.persona_id USING ERRCODE = 'SCJ12', HINT = 'persona_no_activa';
    END IF;

    IF EXISTS (
      SELECT 1 FROM tiempo.terminal_usuario tu
      WHERE tu.terminal_id = NEW.terminal_id AND tu.persona_id = NEW.persona_id
        AND tu.estado <> 'baja'
    ) THEN
      RAISE EXCEPTION 'La persona % ya tiene un alta vigente en la terminal %',
        NEW.persona_id, NEW.terminal_id USING ERRCODE = 'SCJ12', HINT = 'alta_duplicada';
    END IF;

    -- Consentimiento (88_): debe ser la versión VIGENTE. LOCK ROW EXCLUSIVE (compatible entre asignaciones) choca con el
    -- SHARE ROW EXCLUSIVE de fn_terminal_consentimiento_publicar: si hay una publicación en curso esta asignación espera a
    -- que termine y entonces lee la versión nueva (el lock va ANTES del SELECT). Un FOR SHARE de fila no bastaría: no choca con
    -- un INSERT de versión nueva. Antes del nextval.
    IF NEW.consentimiento_id IS NULL THEN
      RAISE EXCEPTION 'La asignación exige la versión del texto de consentimiento'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_requerido';
    END IF;
    LOCK TABLE tiempo.terminal_consentimiento IN ROW EXCLUSIVE MODE;
    SELECT c.id, c.version INTO v_vigente_id, v_vigente_ver
    FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
    IF v_vigente_id IS DISTINCT FROM NEW.consentimiento_id THEN
      RAISE EXCEPTION 'El texto de consentimiento cambió: la versión enviada ya no es la vigente'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_desactualizado';
    END IF;
    -- Evidencia fija: el detalle del 'asignado' lo pone SIEMPRE la base (nunca NULL ni texto del cliente).
    NEW.detalle := 'consentimiento y aviso de privacidad recabados: versión ' || v_vigente_ver;

    INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado, consentimiento_id)
    VALUES (NEW.terminal_id, NEW.persona_id, nextval('tiempo.seq_terminal_employee_no'),
            'pendiente_alta', NEW.consentimiento_id)
    RETURNING id, employee_no INTO v_id, v_employee_no;

    NEW.terminal_usuario_id := v_id;
    NEW.employee_no := v_employee_no;
    RETURN NEW;
  END IF;

  -- ---- resto: actúan sobre una fila viva existente ---------------------------------------
  IF NEW.terminal_usuario_id IS NULL THEN
    RAISE EXCEPTION 'El movimiento "%" requiere terminal_usuario_id', NEW.tipo_movimiento
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  -- FOR UPDATE serializa dos movimientos concurrentes sobre la misma alta.
  SELECT * INTO v_vivo FROM tiempo.terminal_usuario WHERE id = NEW.terminal_usuario_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'terminal_usuario % no existe', NEW.terminal_usuario_id
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  IF NEW.terminal_id IS DISTINCT FROM v_vivo.terminal_id
     OR NEW.persona_id IS DISTINCT FROM v_vivo.persona_id THEN
    RAISE EXCEPTION 'terminal_id/persona_id no coinciden con la alta % (terminal %, persona %)',
      v_vivo.id, v_vivo.terminal_id, v_vivo.persona_id
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  IF NEW.employee_no IS NULL THEN
    NEW.employee_no := v_vivo.employee_no;
  ELSIF NEW.employee_no IS DISTINCT FROM v_vivo.employee_no THEN
    RAISE EXCEPTION 'employee_no % no coincide con el de la alta % (%)',
      NEW.employee_no, v_vivo.id, v_vivo.employee_no
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  v_estado  := v_vivo.estado;
  v_huellas := v_vivo.huellas_capturadas;
  v_error   := NULL;  -- todo movimiento válido distinto de 'error' y de 'reconsentido' limpia el último error
  v_consent := v_vivo.consentimiento_id;
  v_usuario_creado_en := v_vivo.usuario_creado_en;

  IF NEW.tipo_movimiento = 'usuario_creado' THEN
    IF v_vivo.estado IS DISTINCT FROM 'pendiente_alta' THEN
      RAISE EXCEPTION 'usuario_creado exige estado pendiente_alta (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'esperando_huella';
    v_usuario_creado_en := NEW.creado_en;   -- 88_: cuándo se creó el usuario en el aparato (plazo de caducidad)

  ELSIF NEW.tipo_movimiento = 'huella_capturada' THEN
    IF v_vivo.estado NOT IN ('esperando_huella', 'activo') THEN
      RAISE EXCEPTION 'huella_capturada exige estado esperando_huella o activo (estado actual: %)',
        v_vivo.estado USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado  := 'activo';
    v_huellas := NEW.huellas_capturadas;

  ELSIF NEW.tipo_movimiento = 'baja_solicitada' THEN
    IF v_vivo.estado IN ('pendiente_baja', 'baja') THEN
      RAISE EXCEPTION 'baja_solicitada no aplica en estado % (ya está en baja o por darse de baja)',
        v_vivo.estado USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'pendiente_baja';

  ELSIF NEW.tipo_movimiento = 'baja_confirmada' THEN
    IF v_vivo.estado IS DISTINCT FROM 'pendiente_baja' THEN
      RAISE EXCEPTION 'baja_confirmada exige estado pendiente_baja (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'baja';

  ELSIF NEW.tipo_movimiento = 'error' THEN
    IF v_vivo.estado = 'baja' THEN
      RAISE EXCEPTION 'error no aplica sobre una alta ya dada de baja'
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_error := NEW.detalle;  -- sin cambio de estado

  ELSIF NEW.tipo_movimiento = 'reconsentido' THEN
    -- 88_: RH registra que la persona aceptó la versión vigente. No cambia estado ni huellas, no reenrola nada y NO limpia
    -- el último error (se conserva error_detalle). Estados donde aplica: los mismos del reconsentimiento pendiente.
    -- Nadie registra el reconsentimiento de su PROPIA alta, salvo el administrador genérico (misma regla y excepción que la
    -- auto-asignación; decisión del usuario 2026-10-08). Pedir la propia baja sigue permitido (no pasa por aquí).
    IF NEW.registrado_por IS NOT NULL
       AND v_vivo.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes registrar tu propio reconsentimiento; lo registra otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_reconsentimiento_prohibido';
    END IF;
    IF v_vivo.estado NOT IN ('pendiente_alta', 'esperando_huella', 'activo') THEN
      RAISE EXCEPTION 'reconsentido no aplica en estado % (la alta ya se está retirando)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    IF NEW.consentimiento_id IS NULL THEN
      RAISE EXCEPTION 'El reconsentimiento exige la versión del texto de consentimiento'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_requerido';
    END IF;
    LOCK TABLE tiempo.terminal_consentimiento IN ROW EXCLUSIVE MODE;
    SELECT c.id, c.version INTO v_vigente_id, v_vigente_ver
    FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
    IF v_vigente_id IS DISTINCT FROM NEW.consentimiento_id THEN
      RAISE EXCEPTION 'El texto de consentimiento cambió: la versión enviada ya no es la vigente'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_desactualizado';
    END IF;
    NEW.detalle := 'reconsentimiento recabado: versión ' || v_vigente_ver;
    IF v_vivo.consentimiento_id = NEW.consentimiento_id THEN
      RAISE EXCEPTION 'La alta % ya tiene aceptada esa versión del texto', v_vivo.id
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_consent := NEW.consentimiento_id;
    v_error   := v_vivo.error_detalle;
  END IF;

  UPDATE tiempo.terminal_usuario
  SET estado = v_estado,
      huellas_capturadas = v_huellas,
      error_detalle = v_error,
      consentimiento_id = v_consent,
      usuario_creado_en = v_usuario_creado_en,
      actualizado_en = now()
  WHERE id = v_vivo.id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = tiempo, personas, pg_temp;
