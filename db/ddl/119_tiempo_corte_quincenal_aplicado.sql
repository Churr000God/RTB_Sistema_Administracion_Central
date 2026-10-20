-- 119_tiempo_corte_quincenal_aplicado.sql
-- Idempotencia del corte quincenal garantizada en la BASE, por persona + periodo (SCJ-PRO-13).
--
-- PROBLEMA. La idempotencia del corte (backend/app/batches/corte_quincenal.py::_tramos_ya_clasificados) se basa en que los tramos del periodo ya tengan una fila en clasificacion_de_tiempo
-- (UNIQUE(tramo_id)). Un periodo SIN tramos (todo ausencias, o nadie trabajó) no deja ninguna fila de clasificación, así que se podía aplicar dos veces y DUPLICAR la deuda (generado_quincena).
--
-- QUÉ HACE
--  1. Tabla tiempo.corte_quincenal_aplicado: un registro por persona y periodo aplicado, con UNIQUE (persona_id, periodo_desde). Columnas: persona_id, periodo_desde, periodo_hasta, aplicado_en,
--     horas_esperadas, horas_trabajadas y resultado_horas (deuda generada por el corte = suma de los movimientos generado_quincena que vinieron en la llamada; 0 si el periodo no generó deuda).
--     Un periodo con resultado 0 TAMBIÉN se registra: es justo el caso sin tramos.
--  2. tiempo.fn_corte_quincenal_aplicar_persona cambia de firma (ver abajo): recibe el periodo y las horas, inserta el registro en la MISMA transacción que las clasificaciones y los movimientos, y
--     rechaza un periodo ya aplicado con ERRCODE SCJ23, HINT 'periodo_ya_aplicado', mensaje fijo. Acepta p_clasificaciones y p_movimientos vacíos. La firma vieja (uuid, jsonb, jsonb, text) se ELIMINA:
--     dejarla viva permitiría aplicar un corte sin pasar por el registro (la misma vía por la que se duplicó).
--
-- FIRMA NUEVA (backend la necesita; llamar con argumentos NOMBRADOS):
--   tiempo.fn_corte_quincenal_aplicar_persona(
--     p_persona_id uuid, p_periodo_desde date, p_periodo_hasta date, p_horas_esperadas numeric, p_horas_trabajadas numeric,
--     p_clasificaciones jsonb DEFAULT '[]', p_movimientos jsonb DEFAULT '[]', p_motivo text DEFAULT NULL) RETURNS bigint   -- id del registro en corte_quincenal_aplicado
--   Errores: SCJ23/periodo_ya_aplicado (ya existe el periodo para esa persona); SCJ05 (movimiento con tramo_id fuera de p_clasificaciones, como antes); 23505 de UNIQUE(tramo_id) (carrera, como antes);
--   23514 (periodo_hasta < periodo_desde, horas negativas). Todo aborta la transacción completa: nada queda escrito para esa persona.
--
-- ORDEN DE DESPLIEGUE (IMPORTANTE). Esta migración ELIMINA la firma vieja, y el backend nuevo ya lee compensa_movimiento_id (120_). Orden: (1) aplicar 118_, 119_ y 120_, con la sección 83 de verificar_ddl.sql en solo lectura tras cada una;
-- (2) desplegar backend y frontend en la MISMA ventana; (3) el script de db/correcciones/ (primero en seco, luego con v_aplicar = true). Todo fuera del día de corte (1 y 16 de cada mes). Entre el paso 1 y el 2 el backend viejo no puede
-- aplicar cortes: el corte programado fallaría con «function … does not exist» (PGRST202) y el job lo reintenta; no deja datos a medias.
--
-- PRIVILEGIOS E INVENTARIO DE RLS (regla de CLAUDE.md «todo GRANT nuevo trae inventario»):
--   - tiempo.corte_quincenal_aplicado: RLS HABILITADA y CERO policies a propósito (deny-by-default para anon/authenticated); la escribe y lee solo service_role (el batch). REVOKE ALL a los tres roles y
--     GRANT SELECT, INSERT a service_role. Sin UPDATE, DELETE, TRUNCATE, REFERENCES ni TRIGGER para nadie: el registro es append-only por privilegios. NO lleva trigger de inmutabilidad: si un periodo
--     se registró por error, el dueño (postgres) puede borrarlo desde el SQL Editor; un trigger que bloquee incluso al dueño lo haría irreparable (lección de 75_).
--   - La secuencia de la identidad: REVOKE ALL a los tres roles (el INSERT de una identidad GENERATED ALWAYS no necesita USAGE de la secuencia).
--   - fn_corte_quincenal_aplicar_persona: SECURITY INVOKER (solo la llama el batch con service_role, que tiene INSERT en las tablas), search_path fijo; EXECUTE solo para service_role (REVOKE a los
--     cuatro roles y GRANT explícito). Sin EXECUTE para authenticated: no entra en la lista cerrada de la sección 70(d).
--
-- RESULTADO = DEUDA GENERADA, no el saldo neto: es lo que el corte calculó en ese momento. Una compensación posterior (120_) no reescribe este registro.
-- LO QUE NO HACE: no rellena periodos pasados (los cortes anteriores a esta migración no tienen registro; su idempotencia sigue siendo la de los tramos clasificados).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 119_*.sql`.
-- REVERSA (en una transacción): recrear la función con el cuerpo de 57_ (firma vieja, con su GRANT a service_role), DROP FUNCTION de la nueva y DROP TABLE tiempo.corte_quincenal_aplicado. Texto exacto en
-- db/ensayos/ensayo_119.sql, bloque reversa.
-- Depende de: 02_tiempo.sql, 38_tiempo_permisos.sql, 57_*.sql, 100_*.sql
-- Justificación: SCJ-PRO-13 §III/§IV/§V

CREATE TABLE tiempo.corte_quincenal_aplicado (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  persona_id        uuid NOT NULL REFERENCES tiempo.persona (id),
  periodo_desde     date NOT NULL,
  periodo_hasta     date NOT NULL,
  aplicado_en       timestamptz NOT NULL DEFAULT now(),
  horas_esperadas   numeric(8,2) NOT NULL,
  horas_trabajadas  numeric(8,2) NOT NULL,
  resultado_horas   numeric(8,2) NOT NULL,
  CONSTRAINT uq_corte_quincenal_aplicado_persona_periodo UNIQUE (persona_id, periodo_desde),
  CONSTRAINT ck_corte_quincenal_aplicado_periodo CHECK (periodo_hasta >= periodo_desde),
  CONSTRAINT ck_corte_quincenal_aplicado_horas CHECK (horas_esperadas >= 0 AND horas_trabajadas >= 0 AND resultado_horas >= 0)
);

COMMENT ON TABLE tiempo.corte_quincenal_aplicado IS
  'Un registro por persona y periodo al que ya se aplicó el corte quincenal (119_). UNIQUE (persona_id, periodo_desde) es la idempotencia real del corte: un periodo sin tramos también queda registrado '
  '(resultado_horas = 0). Append-only por privilegios; solo service_role lo escribe, dentro de fn_corte_quincenal_aplicar_persona.';
COMMENT ON COLUMN tiempo.corte_quincenal_aplicado.resultado_horas IS
  'Deuda generada por el corte en ese momento (suma de los movimientos generado_quincena de la llamada); 0 si no generó deuda. No se reescribe al compensar (120_).';

ALTER TABLE tiempo.corte_quincenal_aplicado ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tiempo.corte_quincenal_aplicado FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON tiempo.corte_quincenal_aplicado TO service_role;
REVOKE ALL ON SEQUENCE tiempo.corte_quincenal_aplicado_id_seq FROM PUBLIC, anon, authenticated, service_role;

-- La firma vieja desaparece (ver «ORDEN DE DESPLIEGUE»).
DROP FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, jsonb, jsonb, text);

CREATE FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(
  p_persona_id        uuid,
  p_periodo_desde     date,
  p_periodo_hasta     date,
  p_horas_esperadas   numeric,
  p_horas_trabajadas  numeric,
  p_clasificaciones   jsonb DEFAULT '[]'::jsonb,
  p_movimientos       jsonb DEFAULT '[]'::jsonb,
  p_motivo            text  DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_clas          record;
  v_mov           record;
  v_clas_id       bigint;
  v_banco_id      bigint;
  v_registro_id   bigint;
  v_resultado     numeric(8,2);
  v_mapa_tramos   jsonb := '{}'::jsonb;
BEGIN
  -- Deuda generada por este corte: la suma de los generado_quincena que vienen en la llamada (0 si no hay).
  SELECT COALESCE(SUM(x.monto), 0)
    INTO v_resultado
  FROM jsonb_to_recordset(COALESCE(p_movimientos, '[]'::jsonb)) AS x(tipo varchar(20), monto numeric(8,2))
  WHERE x.tipo = 'generado_quincena';

  -- Primero el registro del periodo: si ya existe, falla rápido y sin escribir nada más. ON CONFLICT DO NOTHING
  -- (y no capturar 23505) evita un subtransaction y, bajo concurrencia, la segunda llamada espera a la primera
  -- y ve su fila: nunca se aplican dos veces.
  INSERT INTO tiempo.corte_quincenal_aplicado
    (persona_id, periodo_desde, periodo_hasta, horas_esperadas, horas_trabajadas, resultado_horas)
  VALUES
    (p_persona_id, p_periodo_desde, p_periodo_hasta, p_horas_esperadas, p_horas_trabajadas, v_resultado)
  ON CONFLICT ON CONSTRAINT uq_corte_quincenal_aplicado_persona_periodo DO NOTHING
  RETURNING id INTO v_registro_id;

  IF v_registro_id IS NULL THEN
    RAISE EXCEPTION 'El corte quincenal de este periodo ya se aplicó a esta persona.'
      USING ERRCODE = 'SCJ23', HINT = 'periodo_ya_aplicado';
  END IF;

  FOR v_clas IN
    SELECT * FROM jsonb_to_recordset(COALESCE(p_clasificaciones, '[]'::jsonb)) AS x(tramo_id bigint, tipo varchar(20))
  LOOP
    INSERT INTO tiempo.clasificacion_de_tiempo (tramo_id, tipo)
    VALUES (v_clas.tramo_id, v_clas.tipo)
    RETURNING id INTO v_clas_id;

    v_mapa_tramos := v_mapa_tramos || jsonb_build_object(v_clas.tramo_id::text, v_clas_id);
  END LOOP;

  -- Sin movimientos no hace falta banco (un periodo con resultado 0 no debe crear banco_de_horas vacío).
  IF jsonb_array_length(COALESCE(p_movimientos, '[]'::jsonb)) > 0 THEN
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
  END IF;

  RETURN v_registro_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, date, date, numeric, numeric, jsonb, jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, date, date, numeric, numeric, jsonb, jsonb, text)
  TO service_role;

COMMENT ON FUNCTION tiempo.fn_corte_quincenal_aplicar_persona(uuid, date, date, numeric, numeric, jsonb, jsonb, text) IS
  'RPC transaccional de «aplicar corte quincenal a una persona» (SCJ-PRO-13, 119_): registra el periodo en corte_quincenal_aplicado (UNIQUE persona+periodo; SCJ23/periodo_ya_aplicado si ya existe), '
  'inserta las clasificaciones y los movimientos de saldo y crea banco_de_horas solo si hay movimientos, todo en una transacción. Acepta clasificaciones y movimientos vacíos (un periodo con '
  'resultado 0 también se registra). Devuelve el id del registro. SCJ05 si un movimiento referencia un tramo_id ausente de p_clasificaciones. SECURITY INVOKER: solo service_role.';
