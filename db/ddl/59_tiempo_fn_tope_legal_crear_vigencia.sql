-- 59_tiempo_fn_tope_legal_crear_vigencia.sql
-- RPC transaccional de "crear vigencia de tope legal" (pantalla "Tope legal", módulo Parámetros de
-- Tiempo). Mismo patrón que tiempo.fn_jornada_asignar_renovar (40_*.sql): cerrar la vigencia
-- activa (si la hay y se confirma) + insertar la nueva, en una sola transacción -- sin esto, un
-- fallo entre el UPDATE de cierre y el INSERT dejaría la tabla sin ninguna fila vigente
-- (vigente_hasta IS NULL). tope_legal no tiene tabla hija (a diferencia de jornada_asignada +
-- patron_semanal), así que no hace falta jsonb_to_recordset() acá.
--
-- SECURITY INVOKER (default, no se escribe SECURITY DEFINER): mismo razonamiento que
-- tiempo.fn_corte_quincenal_aplicar_persona (57_*.sql) -- sólo la invoca el backend con
-- get_service_client (service_role, BYPASSRLS), nunca un humano autenticado directo, así que no
-- hace falta escalar privilegios con DEFINER.
--
-- Señal de conflicto (vigencia activa sin confirmar): RAISE EXCEPTION con ERRCODE 'SCJ01' -- mismo
-- código que fn_jornada_asignar_renovar usa para el mismo tipo de conflicto de vigencia (traslape
-- se valida en la aplicación, SCJ-DEC-04 Opción A); backend mapea SCJ01 a 409 igual que ya hace
-- para jornada_asignada.
--
-- GRANT sólo a service_role (no a authenticated): a diferencia de fn_jornada_asignar_renovar, este
-- RPC no lo invoca un usuario autenticado vía frontend -- backend/app/routers/... para Tope legal
-- usa get_service_client, mismo criterio que fn_corte_quincenal_aplicar_persona. REVOKE de PUBLIC
-- en el mismo archivo desde el arranque.
-- Depende de: 02_tiempo.sql
-- Justificación: pantalla "Tope legal", módulo Parámetros de Tiempo

CREATE FUNCTION tiempo.fn_tope_legal_crear_vigencia(
  p_vigente_desde             date,
  p_maximo_semanal            numeric,
  p_maximo_extra              numeric,
  p_confirma_cierre_vigente   boolean DEFAULT false
) RETURNS tiempo.tope_legal AS $$
DECLARE
  v_vigente_id bigint;
  v_nueva      tiempo.tope_legal;
BEGIN
  SELECT id INTO v_vigente_id
  FROM tiempo.tope_legal
  WHERE vigente_hasta IS NULL;

  IF v_vigente_id IS NOT NULL AND NOT p_confirma_cierre_vigente THEN
    RAISE EXCEPTION
      'Ya hay una vigencia de tope legal activa (id %) -- confirma_cierre_vigente debe ser true '
      'para cerrarla y crear la nueva', v_vigente_id
      USING ERRCODE = 'SCJ01';
  END IF;

  IF v_vigente_id IS NOT NULL THEN
    UPDATE tiempo.tope_legal
    SET vigente_hasta = p_vigente_desde - 1
    WHERE id = v_vigente_id;
  END IF;

  INSERT INTO tiempo.tope_legal (
    vigente_desde, vigente_hasta, maximo_semanal, maximo_extra
  ) VALUES (
    p_vigente_desde, NULL, p_maximo_semanal, p_maximo_extra
  )
  RETURNING * INTO v_nueva;

  RETURN v_nueva;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_tope_legal_crear_vigencia(date, numeric, numeric, boolean) IS
  'RPC transaccional de "crear vigencia de tope legal": si hay vigencia activa sin '
  'confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... USING ERRCODE = ''SCJ01'' '
  '(backend lo mapea a 409); si confirmada o no hay vigencia previa, cierra la anterior '
  '(vigente_hasta = nueva.vigente_desde - 1 día) e inserta la vigencia nueva, en una sola '
  'transacción.';

GRANT EXECUTE ON FUNCTION tiempo.fn_tope_legal_crear_vigencia(date, numeric, numeric, boolean)
  TO service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_tope_legal_crear_vigencia(date, numeric, numeric, boolean)
  FROM PUBLIC;
