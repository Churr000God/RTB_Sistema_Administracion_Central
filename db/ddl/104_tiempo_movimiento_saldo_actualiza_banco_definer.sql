-- 104_tiempo_movimiento_saldo_actualiza_banco_definer.sql
-- Defecto de integridad (security, 14-oct-2026): tiempo.fn_movimiento_de_saldo_actualiza_banco (02_tiempo.sql, trigger AFTER INSERT sobre movimiento_de_saldo, «única vía de escritura de
-- banco_de_horas.monto y .vivo_desde», SCJ-DEC-02) es SECURITY INVOKER. Cuando la dispara el RPC manual fn_movimiento_de_saldo_manual_registrar (68_) con el caller (authenticated), su UPDATE sobre
-- banco_de_horas corre con los privilegios Y LA RLS del caller; banco_de_horas solo tiene policy de SELECT (56_), así que el UPDATE filtra 0 filas EN SILENCIO: el movimiento queda en el ledger y el saldo
-- NO cambia (renovar/descontar/condonar manual dejarían banco_de_horas.monto desalineado del ledger). Además el cuerpo leía el monto con un SELECT y luego hacía el UPDATE con el valor leído: dos
-- inserciones concurrentes sobre el mismo banco perdían una de las dos (actualización perdida). tiempo.movimiento_de_saldo tiene 0 filas en la base real: el defecto nunca se ejerció.
--
-- QUÉ HACE (una sola transacción; el archivo NO lleva BEGIN/COMMIT: `psql --single-transaction -v ON_ERROR_STOP=1 -f 104_*.sql`):
--   1) CREATE OR REPLACE de la función, repitiendo EXPLÍCITOS (CREATE OR REPLACE NO hereda atributos): SECURITY DEFINER, SET search_path = tiempo, pg_temp, dueño postgres (el que la crea).
--      Como DEFINER corre como el dueño y no depende de la RLS ni de los privilegios del caller: el saldo se actualiza igual para el batch (service_role) y para el RPC manual (authenticated).
--   2) Cuerpo en UNA sola sentencia atómica: UPDATE tiempo.banco_de_horas SET monto = monto + NEW.monto, vivo_desde = CASE …, actualizado_en = NEW.creado_en WHERE id = NEW.banco_de_horas_id.
--      Sin lectura previa: el UPDATE toma el candado de la fila y, bajo READ COMMITTED, una segunda sesión espera y re-evalúa «monto + NEW.monto» sobre la versión ya actualizada (no hay actualización
--      perdida). La semántica de vigencia es IDÉNTICA a la anterior: 0 -> positivo abre vivo_desde = NEW.creado_en; llegar a 0 lo pone NULL; en otro caso se conserva.
--   3) IF NOT FOUND THEN RAISE EXCEPTION … ERRCODE 'SCJ18', HINT 'banco_inexistente' (ruidoso, nunca un no-op; sin identidad en el mensaje). La FK movimiento_de_saldo.banco_de_horas_id hace casi
--      inalcanzable esa rama; es defensa en profundidad para que un saldo jamás deje de actualizarse sin error.
--   4) REVOKE EXECUTE … FROM PUBLIC, anon, authenticated, service_role (es función de trigger; nadie la llama). RETURN NEW igual.
--
-- LO QUE NO HACE: no toca la policy movimiento_de_saldo_insert_manual (68_), ni el RPC fn_movimiento_de_saldo_manual_registrar (INVOKER; la policy sigue siendo su autorización real), ni el trigger
-- (CREATE OR REPLACE conserva el trigger y sus dependientes), ni privilegios de tablas, ni datos.
--
-- Inventario de RLS: sin cambios. SQLSTATE: SCJ18 es nuevo (grep: SCJ01–SCJ17 están en uso; SCJ18 libre).
-- Cuerpo vigente (02_tiempo.sql:783-806, md5 del cuerpo daf9b15c011ceeb36af47c9df019647b, igual al de la base real): copia en db/ensayos/vigente_104_banco_actualiza_02.sql; diff literal en
-- db/ensayos/diff_104_banco_actualiza.diff.
-- REVERSA: CREATE OR REPLACE con el cuerpo de db/ensayos/vigente_104_banco_actualiza_02.sql, repitiendo `LANGUAGE plpgsql` (INVOKER por omisión, sin search_path) y el GRANT por omisión (PUBLIC EXECUTE);
-- en una transacción. Después de revertir, el defecto vuelve (el saldo no se actualiza para authenticated).

CREATE OR REPLACE FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  UPDATE tiempo.banco_de_horas
  SET monto = monto + NEW.monto,
      vivo_desde = CASE
        WHEN monto = 0 AND monto + NEW.monto > 0 THEN NEW.creado_en
        WHEN monto + NEW.monto = 0 THEN NULL
        ELSE vivo_desde
      END,
      actualizado_en = NEW.creado_en
  WHERE id = NEW.banco_de_horas_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El banco de horas del movimiento no existe'
      USING ERRCODE = 'SCJ18', HINT = 'banco_inexistente';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco() IS
  'Única vía de escritura de banco_de_horas.monto y .vivo_desde (SCJ-DEC-02). SECURITY DEFINER con search_path = tiempo, pg_temp (104_): el saldo se actualiza igual para el batch '
  '(service_role) y para el RPC manual (authenticated), sin depender de la RLS del caller. Una sola sentencia UPDATE atómica (sin lectura previa: sin actualización perdida bajo concurrencia); '
  'SCJ18 (HINT banco_inexistente) si no hay banco que actualizar. Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';
