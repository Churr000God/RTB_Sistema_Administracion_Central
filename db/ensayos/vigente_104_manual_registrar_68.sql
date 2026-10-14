CREATE FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(
  p_persona_id  uuid,
  p_tipo        varchar(20),
  p_monto       numeric,
  p_motivo      text
) RETURNS SETOF tiempo.movimiento_de_saldo AS $$
DECLARE
  v_banco_id      bigint;
  v_monto_actual  numeric;
  v_autor_id      uuid;
BEGIN
  IF p_tipo NOT IN ('arrastrar', 'descontar', 'condonar') THEN
    RAISE EXCEPTION 'Tipo de movimiento no permitido por esta vía.' USING ERRCODE = 'SCJ01';
  END IF;
  IF p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero.' USING ERRCODE = 'SCJ02';
  END IF;

  SELECT id, monto INTO v_banco_id, v_monto_actual
  FROM tiempo.banco_de_horas WHERE persona_id = p_persona_id;
  IF v_banco_id IS NULL THEN
    RAISE EXCEPTION 'Esta persona no tiene saldo que gestionar.' USING ERRCODE = 'SCJ03';
  END IF;
  IF p_monto > v_monto_actual THEN
    RAISE EXCEPTION 'El monto excede el saldo adeudado.' USING ERRCODE = 'SCJ04';
  END IF;

  SELECT u.persona_id INTO v_autor_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid();

  IF p_tipo = 'arrastrar' THEN
    RETURN QUERY INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id)
      VALUES (v_banco_id, 'arrastrar', -p_monto, p_motivo, v_autor_id) RETURNING *;
    RETURN QUERY INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id)
      VALUES (v_banco_id, 'arrastrar', p_monto, p_motivo, v_autor_id) RETURNING *;
  ELSE
    RETURN QUERY INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id)
      VALUES (v_banco_id, p_tipo, -p_monto, p_motivo, v_autor_id) RETURNING *;
  END IF;
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) FROM PUBLIC;
