CREATE FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco()
RETURNS trigger AS $$
DECLARE
  v_monto_antes numeric(8,2);
  v_monto_despues numeric(8,2);
BEGIN
  SELECT monto INTO v_monto_antes FROM tiempo.banco_de_horas WHERE id = NEW.banco_de_horas_id;
  v_monto_despues := v_monto_antes + NEW.monto;

  UPDATE tiempo.banco_de_horas
  SET monto = v_monto_despues,
      actualizado_en = NEW.creado_en,
      vivo_desde = CASE
        WHEN v_monto_antes = 0 AND v_monto_despues > 0 THEN NEW.creado_en
        WHEN v_monto_despues = 0 THEN NULL
        ELSE vivo_desde
      END
  WHERE id = NEW.banco_de_horas_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
