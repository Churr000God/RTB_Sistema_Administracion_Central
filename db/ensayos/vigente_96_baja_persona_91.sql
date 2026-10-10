CREATE OR REPLACE FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_estado  varchar(20);
  v_autor   uuid;
  v_n       integer := 0;
  rec       record;
BEGIN
  SELECT p.estado INTO v_estado FROM personas.persona p WHERE p.id = p_persona_id;
  IF FOUND AND v_estado = 'activo' THEN
    RETURN 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = p_persona_id AND tu.estado NOT IN ('pendiente_baja', 'baja')
  ) THEN
    RETURN 0;
  END IF;

  -- 91_: el último acto es el último REGISTRADO (creado_en); fecha_efectiva (capturada por quien registra) sólo desempata.
  SELECT b.registrado_por INTO v_autor
  FROM personas.bitacora_movimiento_persona b
  WHERE b.persona_id = p_persona_id AND b.tipo_movimiento IN ('suspension', 'baja_definitiva')
  ORDER BY b.creado_en DESC, b.fecha_efectiva DESC, b.id DESC
  LIMIT 1;
  IF v_autor IS NULL THEN
    RAISE WARNING 'fn_terminal_baja_por_persona_inactiva: sin autor derivable para la persona %', p_persona_id;
    RETURN -1;
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no
    FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = p_persona_id AND tu.estado NOT IN ('pendiente_baja', 'baja')
    ORDER BY tu.id
  LOOP
    BEGIN
      INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
        (terminal_usuario_id, terminal_id, persona_id, employee_no,
         tipo_movimiento, detalle, origen, registrado_por)
      VALUES
        (rec.id, rec.terminal_id, rec.persona_id, rec.employee_no,
         'baja_solicitada',
         left('baja automática: la persona pasó a ' || COALESCE(v_estado, 'inexistente'), 500),
         'web', v_autor);
      v_n := v_n + 1;
    EXCEPTION WHEN SQLSTATE 'SCJ11' OR SQLSTATE 'SCJ12' THEN
      NULL;  -- carrera o ya hecha: idempotente
    END;
  END LOOP;

  RETURN v_n;
END;
$$;
