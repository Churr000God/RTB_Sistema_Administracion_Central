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
-- SEGUNDA PARTE (hallazgo F1 de security sobre la primera versión, db12baa): con el trigger DEFINER la policy movimiento_de_saldo_insert_manual (68_) —que solo exige activo +
-- movimiento_de_saldo_edicion + tipo IN (arrastrar, descontar, condonar) + autor_id propio, sin limitar monto, banco ni creado_en— ya no sería inocua: un INSERT directo por PostgREST con ese permiso
-- movería el saldo (aumentar deuda ajena, saldo a favor arbitrario, monto 0, un solo lado del par, creado_en en el pasado que distorsiona vivo_desde y el FIFO). Las validaciones (SCJ01–SCJ04) y el
-- par −/+ de «arrastrar» viven solo en el RPC. Por eso, EN LA MISMA TRANSACCIÓN:
--   5) DROP POLICY movimiento_de_saldo_insert_manual y REVOKE INSERT ON tiempo.movimiento_de_saldo FROM authenticated. Quien escribe movimientos es el batch (service_role, conserva su INSERT) y el RPC.
--      Ninguna otra policy ni grant dependía de ellas (la policy de SELECT movimiento_de_saldo_select_requiere_permiso se conserva). El backend (routers/banco_de_horas.py) solo inserta por RPC.
--   6) fn_movimiento_de_saldo_manual_registrar pasa a SECURITY DEFINER con SET search_path = tiempo, personas, pg_temp (se repiten TODOS los atributos y su GRANT/REVOKE exactos de 68_ y de la base viva:
--      EXECUTE solo para authenticated). La autorización que hacía la policy pasa al principio del cuerpo: personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion'),
--      si no => ERRCODE 42501 (mensaje sin identidad). autor_id sale SIEMPRE de auth.uid(); creado_en no se acepta del cliente (default now() del servidor); SCJ01–SCJ04 y el par −/+ intactos.
--      Además se agrega FOR UPDATE al SELECT del banco: bajo DEFINER la comprobación «monto <= saldo» (SCJ04) es check-then-act; el candado serializa dos descuentos concurrentes sobre el mismo banco.
--      Cambio de comportamiento deliberado: quien tenga movimiento_de_saldo_edicion YA NO necesita banco_de_horas_lectura (el RPC corre como dueño y no depende de la RLS de lectura); sin edición, 42501.
--
-- LO QUE NO HACE: no toca la policy de SELECT, ni el trigger (CREATE OR REPLACE conserva el trigger y sus dependientes), ni datos, ni el resto de privilegios.
--
-- Inventario de RLS: sin cambios. SQLSTATE: SCJ18 es nuevo (grep: SCJ01–SCJ17 están en uso; SCJ18 libre).
-- Cuerpo vigente (02_tiempo.sql:783-806, md5 del cuerpo daf9b15c011ceeb36af47c9df019647b, igual al de la base real): copia en db/ensayos/vigente_104_banco_actualiza_02.sql; diff literal en
-- db/ensayos/diff_104_banco_actualiza.diff.
-- REVERSA (en una transacción, y en ESTE orden): (1) CREATE OR REPLACE de fn_movimiento_de_saldo_actualiza_banco con el cuerpo de db/ensayos/vigente_104_banco_actualiza_02.sql (INVOKER por omisión, sin
-- search_path) + GRANT EXECUTE ... TO PUBLIC; (2) CREATE OR REPLACE de fn_movimiento_de_saldo_manual_registrar con el cuerpo de db/ensayos/vigente_104_manual_registrar_68.sql (INVOKER, sin search_path) y
-- REVOKE EXECUTE FROM PUBLIC; GRANT EXECUTE TO authenticated; (3) GRANT INSERT ON tiempo.movimiento_de_saldo TO authenticated; y volver a crear la policy con la definición de 68_ (copiada en
-- db/ensayos/vigente_104_policy_68.sql). Después de revertir, el defecto original vuelve (el saldo no se actualiza para authenticated) y la vía directa se reabre.

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

-- ============================================================================
-- 5) Cerrar la vía directa: sin policy de INSERT ni privilegio INSERT para authenticated
-- ============================================================================

DROP POLICY movimiento_de_saldo_insert_manual ON tiempo.movimiento_de_saldo;
REVOKE INSERT ON TABLE tiempo.movimiento_de_saldo FROM authenticated;

-- ============================================================================
-- 6) El RPC manual pasa a SECURITY DEFINER y autoriza él mismo (lo que hacía la policy)
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(
  p_persona_id  uuid,
  p_tipo        varchar(20),
  p_monto       numeric,
  p_motivo      text
) RETURNS SETOF tiempo.movimiento_de_saldo
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_banco_id      bigint;
  v_monto_actual  numeric;
  v_autor_id      uuid;
BEGIN
  -- Autorización (antes lo hacía la policy movimiento_de_saldo_insert_manual): persona activa con el permiso de edición.
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para registrar movimientos de saldo.' USING ERRCODE = '42501';
  END IF;

  -- autor_id SIEMPRE desde la sesión (nunca del cliente).
  SELECT u.persona_id INTO v_autor_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid();
  IF v_autor_id IS NULL THEN
    RAISE EXCEPTION 'No tienes permiso para registrar movimientos de saldo.' USING ERRCODE = '42501';
  END IF;

  IF p_tipo NOT IN ('arrastrar', 'descontar', 'condonar') THEN
    RAISE EXCEPTION 'Tipo de movimiento no permitido por esta vía.' USING ERRCODE = 'SCJ01';
  END IF;
  IF p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero.' USING ERRCODE = 'SCJ02';
  END IF;

  -- FOR UPDATE: serializa dos movimientos concurrentes sobre el mismo banco (la comprobación de saldo es check-then-act).
  SELECT id, monto INTO v_banco_id, v_monto_actual
  FROM tiempo.banco_de_horas WHERE persona_id = p_persona_id FOR UPDATE;
  IF v_banco_id IS NULL THEN
    RAISE EXCEPTION 'Esta persona no tiene saldo que gestionar.' USING ERRCODE = 'SCJ03';
  END IF;
  IF p_monto > v_monto_actual THEN
    RAISE EXCEPTION 'El monto excede el saldo adeudado.' USING ERRCODE = 'SCJ04';
  END IF;

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
$$;

-- CREATE OR REPLACE conserva la ACL, pero se repite explícita (igual a 68_ y a la base viva: EXECUTE solo para authenticated).
REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) IS
  'RPC de registro manual de movimiento_de_saldo (SCJ-DEC-02): arrastrar inserta 2 filas (-monto/+monto, mismo motivo, mismo creado_en) para renovar antigüedad sin cambiar el saldo total; '
  'descontar/condonar insertan 1 sola fila (-monto). SECURITY DEFINER con search_path = tiempo, personas, pg_temp (104_): ya NO existe la policy de INSERT ni el privilegio INSERT de authenticated; '
  'este RPC autoriza (persona activa con movimiento_de_saldo_edicion, si no 42501), toma autor_id de auth.uid() y deja creado_en al servidor. SCJ01 (tipo no permitido), SCJ02 (monto <= 0), '
  'SCJ03 (persona sin banco_de_horas), SCJ04 (monto excede el saldo adeudado). Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER, SET search_path y el GRANT/REVOKE.';
