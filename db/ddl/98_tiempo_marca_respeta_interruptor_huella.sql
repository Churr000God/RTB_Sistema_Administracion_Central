-- 98_tiempo_marca_respeta_interruptor_huella.sql
-- fn_marca_terminal_registrar respeta el interruptor de la activación por huella DENTRO de la base (97_): aunque el backend tenga un defecto o alguien llame el RPC
-- directo con la llave de service_role y modo_verificacion = 'huella', con el interruptor apagado la base no activa nada. Diseño: db/ensayos/DISENO_interruptor_inferir_huella.md.
--
-- Qué cambia respecto de 95_ (diff literal en db/ensayos/diff_98_marca.diff; fuera de estos hunks el cuerpo es idéntico a 95_):
--   - Declara v_inferir (boolean, APAGADO por omisión).
--   - Tras el advisory lock y antes del bucle, lee UNA vez por lote el estado EFECTIVO con tiempo.fn_terminal_inferir_huella_estado() (97_, la ÚNICA definición del estado) en
--     un sub-bloque con EXCEPTION: «activo» verdadero => v_inferir; cualquier otra cosa o error => apagado, con RAISE WARNING que lleva solo SQLSTATE y terminal_id.
--     NO usa fn_terminal_config_valor (el lector tolerante acota con LEAST/GREATEST: '7' se leería como 1).
--   - La condición de activación de 95_ suma AND v_inferir. Apagado => la marca se registra y se responde EXACTAMENTE igual (confirmado/duplicado); solo la activación
--     no ocurre; el lote nunca se rechaza ni cambia de resultado.
--   - Dos RAISE EXCEPTION que interpolaban valores (terminal_id, tope del lote) pasan a mensaje fijo + el mismo HINT estable (terminal_no_valida, lote_invalido).
-- El interruptor se lee al inicio del lote: un cambio concurrente se aplica desde el lote siguiente.
--
-- APLICAR después de 97_ con `psql --single-transaction -v ON_ERROR_STOP=1 -f 98_*.sql` (sin BEGIN/COMMIT). Sin tablas, columnas, policies ni permisos nuevos.
-- Inventario de RLS/privilegios: fn_marca_terminal_registrar sigue SECURITY DEFINER, SET search_path = tiempo, personas, pg_temp, REVOKE EXECUTE FROM PUBLIC, anon,
-- authenticated y GRANT EXECUTE solo a service_role (repetidos abajo; CREATE OR REPLACE no hereda nada).
--
-- REVERSA (sin riesgo de datos): CREATE OR REPLACE con el cuerpo de 95_ (copia literal en db/ensayos/vigente_98_marca_95.sql, repitiendo SECURITY DEFINER,
-- SET search_path = tiempo, personas, pg_temp y el REVOKE/GRANT de abajo). Las altas ya activadas permanecen (son filas de bitácora).

CREATE OR REPLACE FUNCTION tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)
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
  c_holgura_huella        constant interval    := interval '5 minutes';   -- 95_: tolerancia del reloj del aparato frente a usuario_creado_en
  c_espera_activacion     constant text        := '2s';                   -- 95_: lock_timeout de la activación por huella (M1 de security)

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
  v_modo           text;         -- 95_: 'huella' o NULL (único valor significativo de modo_verificacion)
  v_marca_id       bigint;       -- 95_: marca confirmada o ya existente del evento (evidencia de la activación)
  v_alta_id        bigint;       -- 95_: terminal_usuario.id de la alta resuelta
  v_alta_usuario_creado timestamptz;   -- 95_: terminal_usuario.usuario_creado_en
  v_recepcion      timestamptz;  -- 95_: momento_recepcion de la marca evidencia
  v_lock_previo    text;         -- 95_: lock_timeout vigente antes de la activación, para restaurarlo
  v_inferir        boolean := false;   -- 98_: interruptor de la activación por huella (APAGADO salvo lectura válida)
BEGIN
  SELECT t.terminal_id, t.activa INTO v_serie, v_activa
  FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND OR NOT v_activa THEN
    RAISE EXCEPTION 'La terminal no existe o no está activa'
      USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
  END IF;

  IF p_eventos IS NULL OR jsonb_typeof(p_eventos) <> 'array'
     OR jsonb_array_length(p_eventos) < 1 OR jsonb_array_length(p_eventos) > c_tope_lote THEN
    RAISE EXCEPTION 'Lote inválido: se espera un arreglo de 1 a 200 eventos'
      USING ERRCODE = '22023', HINT = 'lote_invalido';
  END IF;

  -- Un lote a la vez por terminal, aunque haya varios workers del backend.
  PERFORM pg_advisory_xact_lock(hashtext('fn_marca_terminal_registrar'),
                                (p_terminal_id % 2147483647)::integer);

  -- 98_: interruptor de la activación por huella, leído UNA vez por lote con la ÚNICA definición del estado efectivo (97_). Cualquier cosa que no sea
  -- «activo = verdadero» (interruptor en 0, vencido, vigencias inconsistentes, parámetro ausente, lectura fallida) es APAGADO: la marca se registra y se
  -- responde exactamente igual y solo la activación no ocurre; el lote nunca se rechaza. No se usa el lector tolerante de 89_ (acota el valor).
  BEGIN
    v_inferir := COALESCE((tiempo.fn_terminal_inferir_huella_estado() ->> 'activo')::boolean, false);
  EXCEPTION WHEN OTHERS THEN
    v_inferir := false;
    RAISE WARNING 'fn_marca_terminal_registrar: interruptor de inferencia ilegible sqlstate=% terminal_id=%', SQLSTATE, p_terminal_id;
  END;

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
    v_modo := NULL;
    v_marca_id := NULL;
    v_alta_id := NULL;
    v_alta_usuario_creado := NULL;

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
      -- 95_: modo de verificación. EXACTAMENTE la cadena 'huella'; cualquier otra cosa (ausente, otro tipo, otra cadena, mayúsculas) es NULL.
      -- Nunca vuelve forma_invalida a un evento: el campo es auxiliar y perder una marca legítima por él sería peor.
      v_modo := CASE WHEN jsonb_typeof(v_evento->'modo_verificacion') = 'string'
                          AND (v_evento->>'modo_verificacion') = 'huella' THEN 'huella' END;

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
      SELECT tu.persona_id, tu.estado, tu.creado_en, tu.actualizado_en, tu.id, tu.usuario_creado_en
        INTO v_persona, v_estado_alta, v_alta_creada, v_alta_actualizada, v_alta_id, v_alta_usuario_creado
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
        -- 95_: el log nunca lleva employee_no ni persona_id (regla de security); solo terminal_id y el contador.
        RAISE WARNING 'alarma_tasa_persona terminal_id=% marcas_ultima_hora=%',
          p_terminal_id, v_n;
      END IF;

      -- 7. Duplicado / conflicto por evento_id (idempotencia).
      SELECT m.* INTO v_exist FROM tiempo.marca m WHERE m.evento_id = v_eid;
      IF FOUND THEN
        IF v_exist.terminal_id = v_serie AND v_exist.persona_id = v_persona
           AND v_exist.momento_dispositivo = v_momento
           AND v_exist.secuencia_local IS NOT DISTINCT FROM v_seq THEN
          v_estado := 'duplicado'; v_marca_id := v_exist.id;
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% evento_id=%', p_terminal_id, v_eid;
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
           v_desfase, v_reloj_ins, v_version, 'terminal', false)
        RETURNING id INTO v_marca_id;
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
          v_estado := 'duplicado'; v_marca_id := v_exist.id;
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% evento_id=%', p_terminal_id, v_eid;
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

    -- 95_ (B de SCJ-DEC-12 / diseño huella): la PRIMERA marca verificada por huella de un empleado cuya alta sigue en esperando_huella la
    -- activa (movimiento 'huella_inferida'). Aplica a 'confirmado' y a 'duplicado' (un reenvío repara una activación que no ocurrió). La
    -- marca ya quedó registrada: nada de lo que pase aquí puede rechazarla ni tumbar el lote (sub-bloque propio con su EXCEPTION).
    -- Condiciones: modo exacto 'huella'; alta leída en esperando_huella; la marca ocurrió (momento_dispositivo) no antes de 5 min
    -- antes de que se creó el usuario en el aparato Y fue RECIBIDA después de ese instante (el reloj de fábrica del aparato puede
    -- ir horas adelantado: la recepción es la que no se puede falsear desde el aparato).
    IF v_estado IN ('confirmado', 'duplicado')
       AND v_inferir
       AND v_modo = 'huella'
       AND v_estado_alta = 'esperando_huella'
       AND v_marca_id IS NOT NULL AND v_alta_id IS NOT NULL
       AND v_alta_usuario_creado IS NOT NULL
       AND v_momento >= v_alta_usuario_creado - c_holgura_huella THEN
      BEGIN
        SELECT m.momento_recepcion INTO v_recepcion FROM tiempo.marca m WHERE m.id = v_marca_id;
        IF FOUND AND v_recepcion >= v_alta_usuario_creado THEN
          -- FOR UPDATE BLOQUEANTE con espera acotada (M1 de security): si se omitieran las filas bloqueadas y la caducidad ya tuviera la alta, esta marca la
          -- saltaría y la caducidad borraría la huella recién verificada. lock_timeout es LOCAL a la transacción: se restaura al terminar.
          v_lock_previo := current_setting('lock_timeout');
          PERFORM set_config('lock_timeout', c_espera_activacion, true);
          PERFORM 1 FROM tiempo.terminal_usuario tu2 WHERE tu2.id = v_alta_id AND tu2.estado = 'esperando_huella' FOR UPDATE;
          IF FOUND THEN   -- si la caducidad ganó (la alta ya no está en esperando_huella) no se activa nada
            INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
              (terminal_usuario_id, terminal_id, persona_id, employee_no, tipo_movimiento, detalle, origen, registrado_por, marca_id)
            VALUES
              (v_alta_id, p_terminal_id, v_persona, v_emp, 'huella_inferida', 'primera marca verificada por huella', 'terminal', NULL, v_marca_id);
          END IF;
          PERFORM set_config('lock_timeout', v_lock_previo, true);
        END IF;
      EXCEPTION
        WHEN SQLSTATE 'SCJ11' THEN
          NULL;   -- carrera con una baja u otro movimiento: la marca queda confirmada, la alta sigue su camino
        WHEN OTHERS THEN
          -- 55P03 (espera agotada), 40P01 (interbloqueo), SCJ12 (marca_no_corresponde)… sólo el SQLSTATE, nunca el texto del error ni datos de la persona.
          RAISE WARNING 'fn_marca_terminal_registrar: activación por huella no aplicada sqlstate=% terminal_id=%', SQLSTATE, p_terminal_id;
      END;
    END IF;

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

REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb) TO service_role;

COMMENT ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb) IS
  'SCJ-DEC-12 §3/§6. Ruta de marcas del puente: recibe un lote de eventos de UNA terminal (p_eventos jsonb) y devuelve '
  '{momento_recepcion, resultados:[{indice, evento_id, estado, codigo?}]}. Resuelve employee_no a persona_id en la base (nunca sale del servidor), '
  'fija origen=terminal, degrada estado_reloj, aplica topes de tasa y es idempotente por evento_id. 95_: si el evento trae modo_verificacion = '
  '''huella'' y su alta sigue en esperando_huella, la activa con un movimiento huella_inferida (FOR UPDATE con lock_timeout 2 s; un fallo de la '
  'activación nunca rechaza la marca ni tumba el lote). 98_: SOLO si el interruptor está efectivamente encendido (fn_terminal_inferir_huella_estado, leído una vez por '
  'lote; cualquier anomalía o error = apagado). SECURITY DEFINER, search_path = tiempo, personas, pg_temp, EXECUTE solo service_role. Al reescribirla repetir '
  'SECURITY DEFINER y SET search_path.';
