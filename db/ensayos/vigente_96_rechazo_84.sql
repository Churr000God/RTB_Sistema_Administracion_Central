CREATE OR REPLACE FUNCTION tiempo.fn_terminal_rechazo_registrar(p_terminal_id bigint, p_evento jsonb, p_codigo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_tope_filas_dia  constant integer := 5000;   -- valor inicial ajustable (SCJ-DEC-12 Q13)
  v_eid   uuid;
  v_emp   integer;
  v_seq   bigint;
  v_mom   timestamptz;
  v_des   text;
  v_rel   text;
  v_txt   text;
  v_n     bigint;
BEGIN
  RAISE WARNING 'marca_rechazada terminal_id=% codigo=% evento_id=% employee_no=%',
    p_terminal_id,
    left(COALESCE(p_codigo, '-'), 30),
    left(regexp_replace(COALESCE(p_evento->>'evento_id', '-'), '[^0-9a-fA-F-]', '?', 'g'), 40),
    left(regexp_replace(COALESCE(p_evento->>'employee_no', '-'), '[^0-9]', '?', 'g'), 12);

  IF p_codigo IS NULL OR p_codigo NOT IN ('forma_invalida', 'no_enrolado', 'secuencia_duplicada',
                                          'secuencia_fuera_de_rango', 'conflicto_evento') THEN
    RAISE WARNING 'marca_rechazada: código no reconocido, no se guarda';
    RETURN;
  END IF;

  BEGIN
    v_eid := (p_evento->>'evento_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_eid := NULL;
  END;

  v_txt := p_evento->>'employee_no';
  IF v_txt ~ '^[0-9]{1,8}$' THEN v_emp := v_txt::integer; END IF;

  v_txt := p_evento->>'secuencia_local';
  IF v_txt ~ '^[0-9]{1,18}$' THEN v_seq := v_txt::bigint; END IF;

  -- M2 (security): sólo ISO 8601 anclado (fecha, hora y zona); nada de formatos locales ni infinity.
  v_txt := p_evento->>'momento_dispositivo';
  IF v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' THEN
    BEGIN
      v_mom := v_txt::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      v_mom := NULL;
    END;
  END IF;

  v_des := p_evento->>'desfase_local';
  IF v_des IS NULL OR v_des !~ '^[+-][0-9]{2}:[0-9]{2}$' THEN v_des := NULL; END IF;

  v_rel := p_evento->>'estado_reloj';
  IF v_rel IS NULL OR v_rel NOT IN ('sincronizado', 'deriva', 'sin_sincronizar') THEN v_rel := NULL; END IF;

  SELECT count(*) INTO v_n FROM tiempo.marca_rechazada r
  WHERE r.terminal_id = p_terminal_id AND r.creada_en > now() - interval '1 day';
  IF v_n >= c_tope_filas_dia THEN
    RAISE WARNING 'marca_rechazada_tope terminal_id=% filas_ultimas_24h=%: no se guarda la fila',
      p_terminal_id, v_n;
    RETURN;
  END IF;

  INSERT INTO tiempo.marca_rechazada
    (terminal_id, evento_id, employee_no, secuencia_local, momento_dispositivo,
     desfase_local, estado_reloj, codigo)
  VALUES
    (p_terminal_id, v_eid, v_emp, v_seq, v_mom, v_des, v_rel, p_codigo)
  ON CONFLICT (terminal_id, evento_id) DO NOTHING;
END;
$$;
