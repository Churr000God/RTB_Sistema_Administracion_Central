-- 57_tiempo_fn_corte_quincenal_aplicar_persona.sql
-- RPC transaccional de "aplicar corte quincenal a una persona" (SCJ-PRO-13). Hallazgo de security:
-- corte_quincenal.py escribía tiempo.clasificacion_de_tiempo + tiempo.movimiento_de_saldo por
-- tramo con inserts independientes, sin transacción real -- un fallo a mitad podía dejar a una
-- persona con clasificación parcial sin su movimiento correspondiente, y el criterio de
-- idempotencia (UNIQUE(tramo_id) en clasificacion_de_tiempo) la dejaba atascada sin reintento
-- limpio. Backend ya separó el cálculo (Python, probado) de la escritura (este RPC) -- mismo
-- patrón que tiempo.fn_jornada_asignar_renovar/tiempo.fn_ausencia_resolver: una función, una sola
-- transacción.
--
-- SECURITY INVOKER (default): sólo lo llama el batch con service_role (bypassa RLS por completo,
-- y ya tiene GRANT INSERT en las 3 tablas -- verificado en information_schema.role_table_grants
-- antes de escribir este archivo, sólo UPDATE/DELETE de movimiento_de_saldo siguen restringidos,
-- 38_tiempo_permisos.sql). No hace falta SECURITY DEFINER -- a diferencia de fn_ausencia_
-- resuelve_excepcion, acá nunca hay un humano autenticado invocando la cadena.
--
-- p_clasificaciones/p_movimientos como jsonb -- mismo criterio que p_patron_semanal de
-- fn_jornada_asignar_renovar: el batch en Python ya arma listas de dicts, jsonb_to_recordset()
-- las desempaqueta a filas tipadas sin fricción por PostgREST.
--
-- Mapa tramo_id -> clasificacion_de_tiempo.id: se arma en una variable jsonb local mientras se
-- insertan las clasificaciones (los ids son GENERATED ALWAYS AS IDENTITY, no se conocen hasta el
-- INSERT) -- p_movimientos referencia tramos por tramo_id, nunca por clasificacion_de_tiempo_id
-- directo, porque ese id todavía no existe cuando Python arma el payload.
--
-- get-or-create de banco_de_horas dentro del RPC (no en Python aparte, menos ida y vuelta, pedido
-- explícito de backend): UNIQUE(persona_id) hace que el flujo sea seguro incluso si dos corridas
-- coincidieran en crear el banco de la misma persona -- en la práctica no debería pasar porque
-- todo esto corre dentro de la misma transacción por persona, pero el UNIQUE es la red de
-- seguridad real, no esta función.
--
-- fn_movimiento_de_saldo_actualiza_banco recalcula banco_de_horas.monto/vivo_desde solo, como ya
-- hace -- no se toca ese trigger ni se duplica su lógica acá.
--
-- Señal de error propia: ERRCODE 'SCJ05' si un movimiento referencia un tramo_id que no vino en
-- p_clasificaciones -- no pedido explícitamente, pero el mapa sólo puede resolver lo que él mismo
-- insertó; dejarlo pasar en silencio con clasificacion_de_tiempo_id=NULL escondería un error de
-- programación en el cálculo de Python (matching_incompleto) en vez de fallar ruidosamente.
-- Cualquier otro fallo (23505 real del UNIQUE(tramo_id) por carrera cron+manual, CHECK de tipo
-- inválido, FK de tramo_id inexistente) revienta natural y aborta TODA la transacción -- rollback
-- completo, nada queda escrito para esa persona, exactamente lo pedido.
-- Depende de: 02_tiempo.sql, 38_tiempo_permisos.sql
-- Justificación: SCJ-PRO-13 §III/§IV/§V

CREATE FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(
  p_persona_id       uuid,
  p_clasificaciones  jsonb,
  p_movimientos      jsonb DEFAULT '[]'::jsonb,
  p_motivo           text DEFAULT NULL
) RETURNS void AS $$
DECLARE
  v_clas          record;
  v_mov           record;
  v_clas_id       bigint;
  v_banco_id      bigint;
  v_mapa_tramos   jsonb := '{}'::jsonb;
BEGIN
  FOR v_clas IN
    SELECT * FROM jsonb_to_recordset(p_clasificaciones) AS x(tramo_id bigint, tipo varchar(20))
  LOOP
    INSERT INTO tiempo.clasificacion_de_tiempo (tramo_id, tipo)
    VALUES (v_clas.tramo_id, v_clas.tipo)
    RETURNING id INTO v_clas_id;

    v_mapa_tramos := v_mapa_tramos || jsonb_build_object(v_clas.tramo_id::text, v_clas_id);
  END LOOP;

  SELECT id INTO v_banco_id FROM tiempo.banco_de_horas WHERE persona_id = p_persona_id;

  IF v_banco_id IS NULL THEN
    INSERT INTO tiempo.banco_de_horas (persona_id) VALUES (p_persona_id)
    RETURNING id INTO v_banco_id;
  END IF;

  FOR v_mov IN
    SELECT * FROM jsonb_to_recordset(p_movimientos)
      AS x(tramo_id bigint, tipo varchar(20), monto numeric(8,2))
  LOOP
    IF v_mov.tramo_id IS NOT NULL AND NOT (v_mapa_tramos ? v_mov.tramo_id::text) THEN
      RAISE EXCEPTION
        'El movimiento tipo % referencia tramo_id % que no viene en p_clasificaciones -- no se '
        'puede resolver su clasificacion_de_tiempo_id', v_mov.tipo, v_mov.tramo_id
        USING ERRCODE = 'SCJ05';
    END IF;

    INSERT INTO tiempo.movimiento_de_saldo (
      banco_de_horas_id, clasificacion_de_tiempo_id, tipo, monto, motivo
    ) VALUES (
      v_banco_id,
      CASE WHEN v_mov.tramo_id IS NULL THEN NULL
           ELSE (v_mapa_tramos ->> v_mov.tramo_id::text)::bigint
      END,
      v_mov.tipo,
      v_mov.monto,
      p_motivo
    );
  END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, jsonb, jsonb, text) IS
  'RPC transaccional de "aplicar corte quincenal a una persona" (SCJ-PRO-13): inserta todas las '
  'clasificaciones del periodo, resuelve/crea banco_de_horas, e inserta todos los movimientos de '
  'saldo correspondientes -- todo en una sola transacción. p_movimientos.tramo_id=null es el caso '
  'generado_quincena (a nivel persona, sin tramo). ERRCODE SCJ05 si un movimiento referencia un '
  'tramo_id ausente de p_clasificaciones -- ver cabecera de '
  '57_tiempo_fn_corte_quincenal_aplicar_persona.sql. Cualquier otro fallo (23505 del UNIQUE '
  '(tramo_id) por carrera, CHECK, FK) aborta toda la transacción -- nada queda escrito para esa '
  'persona.';

GRANT EXECUTE ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, jsonb, jsonb, text) TO service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, jsonb, jsonb, text) FROM PUBLIC;
