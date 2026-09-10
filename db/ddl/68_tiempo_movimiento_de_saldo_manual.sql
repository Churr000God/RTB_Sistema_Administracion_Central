-- 68_tiempo_movimiento_de_saldo_manual.sql
-- Primera vía de escritura humana sobre tiempo.movimiento_de_saldo (hoy sólo tiene policy de
-- SELECT, 56_tiempo_rls_corte_quincenal_lectura.sql -- cero INSERT/UPDATE/DELETE humano). UPDATE/
-- DELETE siguen bloqueados (ledger append-only, REVOKE ya existente desde
-- 41_tiempo_rls_deny_default.sql:48, incluso para service_role -- no se toca). El permiso
-- movimiento_de_saldo_edicion ya existe y ya está mapeado a RH/Gerente General/TI desde
-- 33_*.sql/34_*.sql, nunca usado para escribir hasta ahora -- confirmado contra la BD real antes
-- de escribir este archivo.
--
-- Semántica de negocio (confirmada con el usuario):
-- - arrastrar = "renovar antigüedad": no reduce el saldo total -- cierra la deuda vieja y
--   reabre inmediatamente la misma cantidad fechada hoy. 2 INSERT en la misma transacción
--   (monto=-p_monto, luego monto=+p_monto, mismo motivo) -- now() es estable dentro de una
--   transacción Postgres, las 2 filas quedan con el mismo creado_en sin fijarlo a mano. Así el
--   FIFO de backend/app/banco_antiguedad.py::calcular_lotes procesa la renovación sin ningún
--   cambio en ese archivo: la fila negativa consume el lote viejo, la positiva abre uno nuevo
--   fechado hoy.
-- - descontar/condonar = reducción real: 1 solo INSERT (monto=-p_monto).
-- tipo IN ('arrastrar','descontar','condonar') excluye a propósito cubrir/generado_quincena --
-- esos dos quedan exclusivos del batch de corte quincenal (fn_corte_quincenal_aplicar_persona,
-- corre con service_role y bypassa RLS, esta policy no lo afecta).
--
-- 2 correcciones de estilo al SQL propuesto, antes de aplicar contra Supabase real:
-- 1. La policy usaba fn_caller_activo()/fn_caller_tiene_permiso(...) sin el prefijo de esquema.
--    El search_path por defecto del rol authenticated no incluye personas -- toda policy del
--    proyecto sin excepción llama personas.fn_caller_activo()/personas.fn_caller_tiene_permiso(...)
--    calificado (verificado con grep sobre las ~25 policies existentes, ninguna omite el
--    prefijo). Sin el prefijo, la policy habría fallado en el primer INSERT real con "function
--    fn_caller_activo() does not exist". Corregido abajo.
-- 2. El RPC escribía "LANGUAGE plpgsql SECURITY INVOKER" explícito -- SECURITY INVOKER es el
--    default de toda función plpgsql sin SECURITY DEFINER, y ninguna otra función del proyecto lo
--    escribe literal (fn_ausencia_resolver, fn_dia_revisar, fn_tope_legal_crear_vigencia, etc. lo
--    omiten). Se quita la palabra para no romper el patrón -- el comportamiento es idéntico.
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql,
--   34_puesto_permiso_tiempo_mapeo_inicial.sql, 41_tiempo_rls_deny_default.sql,
--   56_tiempo_rls_corte_quincenal_lectura.sql
-- Justificación: SCJ-DEC-02 (saldo del banco de horas)

-- ============================================================================
-- 1) Policy de INSERT -- autor_id atado al propio caller (anti-suplantación, mismo criterio que
-- dia_update_revision, 62_tiempo_dia_revision.sql:74-84): sin esto, alguien con el permiso podría
-- atribuirle el movimiento a otra persona pegándole directo a PostgREST.
-- ============================================================================

CREATE POLICY movimiento_de_saldo_insert_manual ON tiempo.movimiento_de_saldo
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion')
    AND tipo IN ('arrastrar', 'descontar', 'condonar')
    AND autor_id = (SELECT u.persona_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid())
  );

-- ============================================================================
-- 2) RPC tiempo.fn_movimiento_de_saldo_manual_registrar -- SECURITY INVOKER (default): la policy
-- de arriba es la autorización real, mismo criterio que fn_ausencia_resolver/fn_dia_revisar.
-- Validaciones acá son backstop grueso -- el tope fino contra sólo la porción de 6+ meses lo hace
-- backend en Python antes de llamar (no se reimplementa el FIFO en SQL).
-- ============================================================================

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

COMMENT ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) IS
  'RPC de registro manual de movimiento_de_saldo (SCJ-DEC-02): arrastrar inserta 2 filas '
  '(-monto/+monto, mismo motivo, mismo creado_en) para renovar antigüedad sin cambiar el saldo '
  'total -- descontar/condonar insertan 1 sola fila (-monto). ERRCODE SCJ01 (tipo no permitido por '
  'esta vía -- cubrir/generado_quincena son exclusivos del batch), SCJ02 (monto <= 0), SCJ03 '
  '(persona sin banco_de_horas), SCJ04 (monto excede el saldo adeudado) -- locales a este archivo, '
  'reutilizan valores ya usados en otras funciones del proyecto sin conflicto (cada router los '
  'interpreta en el contexto del RPC que llamó). SECURITY INVOKER -- '
  'movimiento_de_saldo_insert_manual es la autorización real.';

GRANT EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_manual_registrar(uuid, varchar, numeric, text) FROM PUBLIC;
