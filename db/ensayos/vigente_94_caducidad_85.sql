CREATE FUNCTION tiempo.fn_terminal_baja_por_caducidad(p_horas integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_horas_minimas  constant integer := 4;   -- piso: nunca caducar con menos de 4 horas (ver cabecera)
  c_tope_bajas     constant integer := 50;  -- máximo de bajas por llamada; el resto queda para la siguiente corrida
  v_n              integer := 0;
  rec              record;
BEGIN
  IF p_horas IS NULL OR p_horas < c_horas_minimas THEN
    RAISE EXCEPTION 'las horas de caducidad deben ser al menos %', c_horas_minimas
      USING ERRCODE = '22023', HINT = 'horas_invalidas';
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no,
           (SELECT a.registrado_por
              FROM tiempo.bitacora_movimiento_terminal_usuario a
             WHERE a.terminal_usuario_id = tu.id AND a.tipo_movimiento = 'asignado'
             ORDER BY a.id
             LIMIT 1) AS autor
    FROM tiempo.terminal_usuario tu
    WHERE tu.estado = 'esperando_huella'
      AND NOT EXISTS (
        SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario h
        WHERE h.terminal_usuario_id = tu.id AND h.tipo_movimiento = 'huella_capturada')
      AND (SELECT max(c.creado_en)
             FROM tiempo.bitacora_movimiento_terminal_usuario c
            WHERE c.terminal_usuario_id = tu.id AND c.tipo_movimiento = 'usuario_creado')
          < clock_timestamp() - make_interval(hours => p_horas)
    ORDER BY tu.id
  LOOP
    IF v_n >= c_tope_bajas THEN
      RAISE WARNING 'tope de bajas por corrida alcanzado';
      EXIT;
    END IF;

    IF rec.autor IS NULL THEN
      RAISE WARNING 'fn_terminal_baja_por_caducidad: sin autor derivable para la alta %', rec.id;
      CONTINUE;
    END IF;

    -- Carrera con huella_capturada (ver cabecera): se re-lee la alta FOR UPDATE exigiendo que siga en
    -- esperando_huella; si el Pi ya la pasó a activo, no se le da de baja.
    PERFORM 1 FROM tiempo.terminal_usuario t WHERE t.id = rec.id AND t.estado = 'esperando_huella' FOR UPDATE;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    BEGIN
      INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
        (terminal_usuario_id, terminal_id, persona_id, employee_no,
         tipo_movimiento, detalle, origen, registrado_por)
      VALUES
        (rec.id, rec.terminal_id, rec.persona_id, rec.employee_no,
         'baja_solicitada', 'baja automática: sin huella tras ' || p_horas || ' horas', 'web', rec.autor);
      v_n := v_n + 1;
    EXCEPTION WHEN SQLSTATE 'SCJ11' OR SQLSTATE 'SCJ12' THEN
      NULL;  -- carrera con otro job o con el Pi, o ya hecha: idempotente
    END;
  END LOOP;

  RETURN v_n;
END;
$$;
