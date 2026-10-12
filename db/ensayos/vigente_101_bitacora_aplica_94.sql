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
  v_evidencia    varchar(10);
  v_marca        tiempo.marca%ROWTYPE;
  v_serie        varchar(32);
  v_asigno       uuid;
  v_nota         text;
  -- ======================= DECISIONES AJUSTABLES (94_) =======================
  -- D2 (cuatro ojos): si es true, quien confirma la huella a mano no puede ser quien hizo el 'asignado' de esa alta (salvo el
  -- administrador genérico). Por omisión false: la variante barata es la alerta de anomalías 'asignador_confirmador'.
  c_cuatro_ojos      constant boolean := false;
  -- D5 (nota): caracteres mínimos (ya saneados y sin espacios en los extremos) de la nota en 'huella_confirmada_manual'.
  -- 0 = nota opcional. En 'huella_inferida' no hay nota: el detalle es fijo.
  c_nota_min_manual  constant integer := 10;
  -- ===========================================================================
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

  -- ---- huella_inferida: rechazo PREVIO a leer la alta (R2 de security, cierra el oraculo minimo de SCJ11/SCJ12) --------------
  -- Solo fn_marca_terminal_registrar (95_), como dueno/service_role, origen terminal y sin autor, puede escribir este tipo. A un llamador de la API
  -- (anon/authenticated) o a cualquier otro origen se le contesta SIEMPRE lo mismo, sin tocar ni bloquear la alta y sin revelar su estado.
  IF NEW.tipo_movimiento = 'huella_inferida'
     AND (NEW.origen IS DISTINCT FROM 'terminal' OR NEW.registrado_por IS NOT NULL OR auth.role() IN ('anon', 'authenticated')) THEN
    RAISE EXCEPTION 'La marca no corresponde a esta alta o ya se usó como evidencia'
      USING ERRCODE = 'SCJ12', HINT = 'marca_no_corresponde';
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
  v_evidencia := v_vivo.huella_evidencia;   -- 94_: sólo sube (conteo > inferida > manual); ver cada rama

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
    v_evidencia := 'conteo';   -- 94_: el conteo del aparato es la evidencia más fuerte; sustituye a 'inferida'/'manual'

  ELSIF NEW.tipo_movimiento = 'huella_confirmada_manual' THEN
    -- 94_ (C): una persona con terminal_usuario_edicion declara que la huella quedó enrolada en el aparato. Sin conteo
    -- (huellas_capturadas no cambia) y sin tocar el consentimiento: el de 'asignado' sigue ligado a la alta (consentimiento_id).
    IF v_vivo.estado IS DISTINCT FROM 'esperando_huella' THEN
      RAISE EXCEPTION 'huella_confirmada_manual exige estado esperando_huella (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    -- Nadie confirma la huella de su PROPIA alta, salvo el administrador genérico (misma regla que auto-asignación y
    -- auto-reconsentimiento). El actor sale de NEW.registrado_por (la policy lo ata a auth.uid()).
    IF NEW.registrado_por IS NOT NULL
       AND v_vivo.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes confirmar tu propia huella; la confirma otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_confirmacion_huella_prohibida';
    END IF;
    -- [D2] Cuatro ojos (apagado por omisión, ver c_cuatro_ojos).
    IF c_cuatro_ojos AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      SELECT a.registrado_por INTO v_asigno
      FROM tiempo.bitacora_movimiento_terminal_usuario a
      WHERE a.terminal_usuario_id = v_vivo.id AND a.tipo_movimiento = 'asignado'
      ORDER BY a.id LIMIT 1;
      IF v_asigno IS NOT DISTINCT FROM NEW.registrado_por THEN
        RAISE EXCEPTION 'Quien asignó la alta no puede confirmar su huella; la confirma otra persona con permiso'
          USING ERRCODE = 'SCJ12', HINT = 'misma_persona_que_asigno';
      END IF;
    END IF;
    -- [D5] Nota. El detalle ya llega saneado (trigger a0_ de 92_: sin invisibles ni separadores de línea).
    v_nota := btrim(COALESCE(NEW.detalle, ''));
    IF char_length(v_nota) < c_nota_min_manual THEN
      RAISE EXCEPTION 'La confirmación manual exige una nota de al menos % caracteres', c_nota_min_manual
        USING ERRCODE = 'SCJ12', HINT = 'nota_requerida';
    END IF;
    NEW.detalle := NULLIF(v_nota, '');
    v_estado    := 'activo';
    v_evidencia := 'manual';

  ELSIF NEW.tipo_movimiento = 'huella_inferida' THEN
    -- 94_ (B): sólo la escribe fn_marca_terminal_registrar (95_) como dueño/service_role, nunca un humano (la policy no deja
    -- insertar este tipo). La evidencia es UNA marca de la propia terminal y de la propia persona, recibida después de que
    -- se creó el usuario en el aparato, y usada una sola vez.
    IF v_vivo.estado IS DISTINCT FROM 'esperando_huella' THEN
      RAISE EXCEPTION 'huella_inferida exige estado esperando_huella (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    SELECT t.terminal_id INTO v_serie FROM tiempo.terminal t WHERE t.id = v_vivo.terminal_id;
    SELECT m.* INTO v_marca FROM tiempo.marca m WHERE m.id = NEW.marca_id;
    IF NEW.marca_id IS NULL OR NOT FOUND
       OR v_marca.origen IS DISTINCT FROM 'terminal'
       OR v_marca.terminal_id IS DISTINCT FROM v_serie
       OR v_marca.persona_id IS DISTINCT FROM v_vivo.persona_id
       OR v_vivo.usuario_creado_en IS NULL
       OR v_marca.momento_recepcion < v_vivo.usuario_creado_en
       OR EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario u WHERE u.marca_id = NEW.marca_id) THEN
      RAISE EXCEPTION 'La marca no corresponde a esta alta o ya se usó como evidencia'
        USING ERRCODE = 'SCJ12', HINT = 'marca_no_corresponde';
    END IF;
    NEW.detalle := 'primera marca verificada por huella';   -- fijo: ningún texto del Pi
    v_estado    := 'activo';
    v_evidencia := 'inferida';

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
      huella_evidencia = v_evidencia,
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

REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica() IS
  'Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] desde cada fila de la bitácora (SCJ-DEC-11). '
  'SECURITY DEFINER SET search_path = tiempo, personas, pg_temp: único escritor de terminal_usuario. SCJ11 = transición inválida o fila viva '
  'incoherente; SCJ12 = alta duplicada, persona no elegible, terminal no válida, auto-asignación/auto-reconsentimiento/auto-confirmación, nota '
  'requerida o marca que no corresponde (94_); SCJ16 = versión del texto de consentimiento ausente o desactualizada (88_); cada raise trae HINT '
  'estable. huella_confirmada_manual y huella_inferida (94_) activan una alta en esperando_huella sin conteo y fijan huella_evidencia. En ''asignado'' '
  'la terminal se toma FOR SHARE y la tabla de versiones se bloquea en ROW EXCLUSIVE. ''reconsentido'' no cambia estado ni huellas. Al reescribirla '
  'con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';
