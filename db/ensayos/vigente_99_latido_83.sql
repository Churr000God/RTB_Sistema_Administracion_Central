CREATE FUNCTION tiempo.fn_terminal_latido(
  p_terminal_id         bigint,
  p_hora_terminal       timestamptz,
  p_alcanzable          boolean,
  p_reloj_sincronizado  boolean,
  p_version_pi          text,
  p_marcas_pendientes   integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_serie     varchar(32);
  v_activa    boolean;
  v_ahora     timestamptz := clock_timestamp();
  v_desfase   integer;
  v_max_seq   bigint;
BEGIN
  SELECT t.terminal_id, t.activa INTO v_serie, v_activa
  FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND OR NOT v_activa THEN
    RAISE EXCEPTION 'La terminal % no existe o no está activa', p_terminal_id
      USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
  END IF;

  -- B8 (security): infinity/-infinity o una hora fuera de rango no deben romper el latido: el desfase queda NULL.
  IF p_hora_terminal IS NOT NULL AND isfinite(p_hora_terminal) THEN
    BEGIN
      v_desfase := LEAST(GREATEST(round(extract(epoch FROM (p_hora_terminal - v_ahora))),
                                  -2147483648), 2147483647)::integer;
    EXCEPTION WHEN data_exception THEN
      v_desfase := NULL;
    END;
  END IF;

  UPDATE tiempo.terminal t
  SET reloj_desfase_seg   = v_desfase,
      terminal_alcanzable = p_alcanzable,
      version_pi          = NULLIF(left(btrim(regexp_replace(COALESCE(p_version_pi, ''), '[[:cntrl:]]', '', 'g')), 16), ''),
      marcas_pendientes   = CASE WHEN p_marcas_pendientes IS NULL THEN NULL
                                 ELSE GREATEST(p_marcas_pendientes, 0) END,
      ultimo_contacto_en  = v_ahora
  WHERE t.id = p_terminal_id;

  SELECT COALESCE(max(m.secuencia_local), 0) INTO v_max_seq
  FROM tiempo.marca m WHERE m.terminal_id = v_serie AND m.origen = 'terminal';

  RETURN jsonb_build_object(
    'hora_servidor',             v_ahora,
    'desfase_reloj_seg',         v_desfase,
    'ultima_secuencia_recibida', v_max_seq
  );
END;
$$;
