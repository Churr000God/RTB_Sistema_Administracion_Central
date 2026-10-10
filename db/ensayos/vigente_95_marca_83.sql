CREATE FUNCTION tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  -- Valores iniciales ajustables (SCJ-DEC-12 Q10-Q14). No son constantes mudas: se cambian aquí.
  c_tope_lote             constant integer     := 200;
  c_tope_persona_hora     constant integer     := 10;       -- más de esto en 1 h: alarma, se inserta
  c_alarma_terminal_hora  constant integer     := 1000;     -- más de esto en 1 h: alarma, se inserta
  c_tope_terminal_hora    constant integer     := 5000;     -- más de esto en 1 h: rechazo transitorio
  c_salto_secuencia       constant bigint      := 1000000;
  c_futuro_reloj          constant interval    := interval '5 minutes';
  c_pasado_reloj          constant interval    := interval '7 days';
  c_instante_minimo       constant timestamptz := timestamptz '2024-01-01 00:00:00+00';
  c_instante_max_futuro   constant interval    := interval '1 year';
  c_holgura_alta          constant interval    := interval '1 hour';      -- tolerancia del reloj frente a la vida de la alta

  v_serie          varchar(32);
  v_activa         boolean;
  v_resultados     jsonb := '[]'::jsonb;
  rec              record;
  v_evento         jsonb;
  v_idx            integer;
  v_estado         text;
  v_codigo         text;
  v_eid            uuid;
  v_emp            integer;
  v_seq            bigint;
  v_momento        timestamptz;
  v_desfase        text;
  v_reloj          text;
  v_reloj_ins      text;
  v_version        text;
  v_persona        uuid;
  v_estado_alta    varchar(20);
  v_max_seq        bigint;
  v_n              bigint;
  v_min            integer;
  v_alta_creada    timestamptz;
  v_alta_actualizada timestamptz;
  v_n_term         bigint;       -- marcas de la terminal en la última hora (se calcula UNA vez por lote)
  v_personas_hora  jsonb;        -- marcas por persona en la última hora (UNA vez por lote)
  v_max_lote       bigint;       -- max(secuencia_local) de la terminal (UNA vez por lote)
  v_exist          tiempo.marca;
  v_cons           text;
  v_carrera        boolean;
BEGIN
  SELECT t.terminal_id, t.activa INTO v_serie, v_activa
  FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND OR NOT v_activa THEN
    RAISE EXCEPTION 'La terminal % no existe o no está activa', p_terminal_id
      USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
  END IF;

  IF p_eventos IS NULL OR jsonb_typeof(p_eventos) <> 'array'
     OR jsonb_array_length(p_eventos) < 1 OR jsonb_array_length(p_eventos) > c_tope_lote THEN
    RAISE EXCEPTION 'lote inválido: se espera un arreglo de 1 a % eventos', c_tope_lote
      USING ERRCODE = '22023', HINT = 'lote_invalido';
  END IF;

  -- Un lote a la vez por terminal, aunque haya varios workers del backend.
  PERFORM pg_advisory_xact_lock(hashtext('fn_marca_terminal_registrar'),
                                (p_terminal_id % 2147483647)::integer);

  -- B1 (security): los conteos de tope y el max(secuencia_local) se calculan UNA vez y se actualizan
  -- conforme se inserta, en vez de dos o tres consultas por evento.
  SELECT COALESCE(max(m.secuencia_local), 0) INTO v_max_lote
  FROM tiempo.marca m WHERE m.terminal_id = v_serie AND m.origen = 'terminal';
  SELECT count(*) INTO v_n_term FROM tiempo.marca m
  WHERE m.terminal_id = v_serie AND m.origen = 'terminal' AND m.momento_recepcion > now() - interval '1 hour';
  SELECT COALESCE(jsonb_object_agg(s.persona_id::text, s.c), '{}'::jsonb) INTO v_personas_hora
  FROM (SELECT m.persona_id, count(*) AS c FROM tiempo.marca m
        WHERE m.momento_recepcion > now() - interval '1 hour'
          AND m.persona_id IN (SELECT tu.persona_id FROM tiempo.terminal_usuario tu WHERE tu.terminal_id = p_terminal_id)
        GROUP BY m.persona_id) s;

  -- En orden de secuencia_local (un evento sin secuencia válida va al final); el índice original se
  -- conserva en la respuesta.
  FOR rec IN
    SELECT (o.ord - 1)::integer AS idx,
           o.elem               AS ev,
           CASE WHEN jsonb_typeof(o.elem) = 'object' AND (o.elem->>'secuencia_local') ~ '^[0-9]{1,18}$'
                THEN (o.elem->>'secuencia_local')::bigint END AS orden_seq
    FROM jsonb_array_elements(p_eventos) WITH ORDINALITY AS o(elem, ord)
    ORDER BY orden_seq NULLS LAST, o.ord
  LOOP
    v_idx := rec.idx;
    v_evento := rec.ev;
    v_estado := NULL;
    v_codigo := NULL;
    v_eid := NULL;
    v_carrera := false;

    -- evento_id: se valida con regex en vez de un bloque con EXCEPTION (cada bloque con EXCEPTION es una
    -- subtransacción; ver B2 de la cabecera).
    IF jsonb_typeof(v_evento) = 'object'
       AND (v_evento->>'evento_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_eid := (v_evento->>'evento_id')::uuid;
    END IF;

    <<ev>>
    BEGIN
      -- 1. Forma. Todo cast y rango dentro de este sub-bloque: un error de clase 22 cae al handler.
      IF jsonb_typeof(v_evento) <> 'object' OR v_eid IS NULL THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      v_emp     := (v_evento->>'employee_no')::integer;
      v_seq     := (v_evento->>'secuencia_local')::bigint;
      v_desfase := v_evento->>'desfase_local';
      v_reloj   := v_evento->>'estado_reloj';
      v_version := v_evento->>'version_software';

      IF v_emp IS NULL OR v_emp NOT BETWEEN 1 AND 99999999
         OR v_seq IS NULL OR v_seq < 0
         OR (v_evento->>'momento_dispositivo') IS NULL
         -- M2 (security): ISO 8601 con fecha, hora y zona, anclada al inicio y al final. Descarta formatos
         -- locales ('06/10/2026 10:00:00Z'), palabras ('yesterday 10:00Z') e infinity/-infinity.
         OR (v_evento->>'momento_dispositivo') !~
            '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$'
         OR v_desfase IS NULL OR v_desfase !~ '^[+-][0-9]{2}:[0-9]{2}$'
         OR v_reloj IS NULL OR v_reloj NOT IN ('sincronizado', 'deriva', 'sin_sincronizar')
         OR v_version IS NULL OR char_length(v_version) NOT BETWEEN 1 AND 16 THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      v_momento := (v_evento->>'momento_dispositivo')::timestamptz;

      -- Rango real del desfase (validación nueva del RPC; el CHECK de marca sólo valida el formato):
      -- -12:00 .. +14:00, minutos 00-59.
      v_min := substr(v_desfase, 2, 2)::integer * 60 + substr(v_desfase, 5, 2)::integer;
      IF substr(v_desfase, 5, 2)::integer > 59
         OR (substr(v_desfase, 1, 1) = '-' AND v_min > 720)
         OR (substr(v_desfase, 1, 1) = '+' AND v_min > 840) THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      -- 2. Absurdos de fecha: el único rechazo por tiempo.
      IF NOT isfinite(v_momento) OR v_momento < c_instante_minimo OR v_momento > now() + c_instante_max_futuro THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      -- 3. secuencia_local acotada por la última recibida de esta terminal (calculada una vez por lote
      -- y actualizada al confirmar cada marca).
      IF v_seq > v_max_lote + c_salto_secuencia THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'secuencia_fuera_de_rango'; EXIT ev;
      END IF;

      -- 4. Resolución employee_no -> persona. UNIQUE (terminal_id, employee_no) sin condición de
      -- estado: resuelve también altas en 'baja' (una marca legítima encolada antes de la baja).
      -- Sin alta, o alta aún en pendiente_alta (el aparato no pudo crear ese usuario): no_enrolado.
      SELECT tu.persona_id, tu.estado, tu.creado_en, tu.actualizado_en
        INTO v_persona, v_estado_alta, v_alta_creada, v_alta_actualizada
      FROM tiempo.terminal_usuario tu
      WHERE tu.terminal_id = p_terminal_id AND tu.employee_no = v_emp;
      IF NOT FOUND OR v_estado_alta = 'pendiente_alta' THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'no_enrolado'; EXIT ev;
      END IF;

      -- M1 (security): el employee_no nunca se reutiliza y las altas en 'baja' siguen resolviendo (una marca
      -- legítima encolada antes de la baja), pero eso no debe servir para falsear marcas fuera de la vida de la
      -- alta: (a) una marca de una alta en 'baja' con momento posterior a su baja (+1 h de holgura de reloj)
      -- y (b) cualquier marca anterior a la creación de la alta (-1 h) se rechazan como no_enrolado. Para
      -- una alta en 'baja', actualizado_en es el momento de baja_confirmada (después no admite más
      -- movimientos).
      IF (v_estado_alta = 'baja' AND v_momento > v_alta_actualizada + c_holgura_alta)
         OR v_momento < v_alta_creada - c_holgura_alta THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'no_enrolado'; EXIT ev;
      END IF;

      -- 5. Degradación del reloj: sólo puede empeorarse, nunca mejorarse. No se rechaza.
      v_reloj_ins := v_reloj;
      IF v_reloj = 'sincronizado'
         AND (v_momento > now() + c_futuro_reloj OR v_momento < now() - c_pasado_reloj) THEN
        v_reloj_ins := 'deriva';
      END IF;

      -- 6. Topes de tasa (última hora, por momento_recepcion).
      -- Los conteos se calcularon UNA vez antes del bucle y se suman al confirmar (B1).
      IF v_n_term >= c_tope_terminal_hora THEN
        v_estado := 'rechazo_transitorio'; v_codigo := 'tope_terminal'; EXIT ev;
      END IF;
      IF v_n_term >= c_alarma_terminal_hora THEN
        RAISE WARNING 'alarma_tasa_terminal terminal_id=% marcas_ultima_hora=%', p_terminal_id, v_n_term;
      END IF;
      v_n := COALESCE((v_personas_hora ->> v_persona::text)::bigint, 0);
      IF v_n >= c_tope_persona_hora THEN
        RAISE WARNING 'alarma_tasa_persona terminal_id=% employee_no=% marcas_ultima_hora=%',
          p_terminal_id, v_emp, v_n;
      END IF;

      -- 7. Duplicado / conflicto por evento_id (idempotencia).
      SELECT m.* INTO v_exist FROM tiempo.marca m WHERE m.evento_id = v_eid;
      IF FOUND THEN
        IF v_exist.terminal_id = v_serie AND v_exist.persona_id = v_persona
           AND v_exist.momento_dispositivo = v_momento
           AND v_exist.secuencia_local IS NOT DISTINCT FROM v_seq THEN
          v_estado := 'duplicado';
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% employee_no=%', p_terminal_id, v_emp;
          v_estado := 'rechazo_definitivo'; v_codigo := 'conflicto_evento';
        END IF;
        EXIT ev;
      END IF;

      -- 8. INSERT. origen y requiere_revision los fija esta función, no el evento.
      BEGIN
        INSERT INTO tiempo.marca
          (evento_id, persona_id, terminal_id, secuencia_local, momento_dispositivo,
           desfase_local, estado_reloj, version_software, origen, requiere_revision)
        VALUES
          (v_eid, v_persona, v_serie, v_seq, v_momento,
           v_desfase, v_reloj_ins, v_version, 'terminal', false);
        v_estado := 'confirmado';
        -- Contadores del lote (B1): lo recién confirmado cuenta para los topes y el tope de secuencia.
        v_n_term := v_n_term + 1;
        v_personas_hora := jsonb_set(v_personas_hora, ARRAY[v_persona::text],
          to_jsonb(COALESCE((v_personas_hora ->> v_persona::text)::bigint, 0) + 1));
        v_max_lote := GREATEST(v_max_lote, v_seq);
      EXCEPTION
        WHEN unique_violation THEN
          GET STACKED DIAGNOSTICS v_cons = CONSTRAINT_NAME;
          IF v_cons = 'uq_marca_evento_id' THEN
            v_carrera := true;
          ELSIF v_cons = 'uq_marca_terminal_secuencia' THEN
            v_estado := 'rechazo_definitivo'; v_codigo := 'secuencia_duplicada';
          ELSE
            RAISE WARNING 'fn_marca_terminal_registrar: unicidad no prevista en terminal_id=%', p_terminal_id;
            v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
          END IF;
        -- B3 (security): sólo un CHECK propio de tiempo.marca (ck_marca_*) es un rechazo definitivo de forma.
        -- Cualquier otro 22/23502/23514 ocurrido dentro del INSERT (p. ej. de un trigger) es un error del
        -- servidor, no del evento: transitorio, el Pi reintenta.
        WHEN data_exception OR not_null_violation OR check_violation THEN
          GET STACKED DIAGNOSTICS v_cons = CONSTRAINT_NAME;
          IF v_cons LIKE 'ck\_marca\_%' THEN
            v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida';
          ELSE
            RAISE WARNING 'fn_marca_terminal_registrar: error de datos dentro del INSERT sqlstate=% terminal_id=%',
              SQLSTATE, p_terminal_id;
            v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
          END IF;
      END;

      -- Carrera por evento_id: otro lote insertó el mismo evento entre el SELECT y el INSERT.
      IF v_carrera THEN
        SELECT m.* INTO v_exist FROM tiempo.marca m WHERE m.evento_id = v_eid;
        IF FOUND AND v_exist.terminal_id = v_serie AND v_exist.persona_id = v_persona
           AND v_exist.momento_dispositivo = v_momento
           AND v_exist.secuencia_local IS NOT DISTINCT FROM v_seq THEN
          v_estado := 'duplicado';
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% employee_no=%', p_terminal_id, v_emp;
          v_estado := 'rechazo_definitivo'; v_codigo := 'conflicto_evento';
        END IF;
      END IF;
    EXCEPTION
      WHEN data_exception OR not_null_violation OR check_violation THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida';
      WHEN OTHERS THEN
        RAISE WARNING 'fn_marca_terminal_registrar: error no previsto sqlstate=% terminal_id=%',
          SQLSTATE, p_terminal_id;
        v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
    END;

    IF v_estado = 'rechazo_definitivo' THEN
      BEGIN
        PERFORM tiempo.fn_terminal_rechazo_registrar(p_terminal_id, v_evento, v_codigo);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_marca_terminal_registrar: no se pudo registrar el rechazo sqlstate=%', SQLSTATE;
      END;
    END IF;

    v_resultados := v_resultados || jsonb_build_array(
      jsonb_build_object('indice', v_idx, 'evento_id', v_eid, 'estado', v_estado)
      || CASE WHEN v_codigo IS NOT NULL THEN jsonb_build_object('codigo', v_codigo) ELSE '{}'::jsonb END);
  END LOOP;

  RETURN jsonb_build_object(
    'momento_recepcion', now(),
    'resultados', (SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'indice')::integer), '[]'::jsonb)
                   FROM jsonb_array_elements(v_resultados) AS r)
  );
END;
$$;
