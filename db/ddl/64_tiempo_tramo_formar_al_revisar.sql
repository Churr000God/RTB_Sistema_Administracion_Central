-- 64_tiempo_tramo_formar_al_revisar.sql
-- El usuario probó el flujo completo (corregir 4 marcas de "Administrador del Sistema" el 7 de
-- sep, revisar el día) y esperaba 2 tramos completos -- sólo hay 1, abierto para siempre. No es un
-- bug: SCJ-DEC-06 dice literal "ningún proceso reabre un día bloqueado automáticamente", y
-- fn_correccion_recalcula_tramo sólo ajusta inicio/fin de un tramo al que la marca YA pertenece --
-- nunca la asigna a uno nuevo (02_tiempo.sql:471-474). Las marcas que llegaron después de que el
-- día ya estaba bloqueado nunca entraron a ningún tramo -- corregir su valor no cambia eso. Este
-- archivo arma, dentro del mismo clic de "revisar", los tramos que faltan con las marcas huérfanas
-- del día.
--
-- Abre -- deliberadamente, mismo criterio que ya se usó para tiempo.dia en 62_*.sql -- el primer
-- camino de escritura humana sobre tiempo.tramo, que hoy tiene CERO policies de escritura
-- (54_tiempo_rls_tramo_lectura.sql: "ni siquiera el botón manual"). Verificado que tramo no tiene
-- REVOKE (a diferencia de marca/correccion) -- sólo faltaba la policy, no el GRANT. Verificado
-- también que los 3 puestos con dia_revision_edicion (62_*.sql) ya tienen tramo_lectura,
-- marca_lectura, correccion_edicion/lectura y excepcion_edicion -- todo lo que el cuerpo nuevo de
-- fn_dia_revisar necesita leer/escribir además de tiempo.dia/tiempo.tramo. Ningún permiso nuevo.
--
-- Un solo archivo: las policies de tramo y la extensión de fn_dia_revisar son un cambio atómico
-- (la función necesita las policies para poder escribir, corre SECURITY INVOKER).
-- Depende de: 02_tiempo.sql, 54_tiempo_rls_tramo_lectura.sql, 62_tiempo_dia_revision.sql,
--   63_tiempo_dia_revisar_horas.sql
-- Justificación: SCJ-DEC-06, SCJ-DEC-01 (paridad apertura/cierre de tramo)

-- ============================================================================
-- 1) Policies de tiempo.tramo -- reusan dia_revision_edicion (misma acción humana, no una tabla
-- distinta con su propio código).
-- ============================================================================

-- NOTA para orchestrator/usuario: el WITH CHECK del INSERT que traía el plan exigía
-- `fin IS NOT NULL AND fin > inicio` sin excepción -- eso bloquearía el propio paso 5 del
-- algoritmo (marca huérfana impar sin pareja: INSERT con marca_cierre_id/fin en NULL, "mismo
-- patrón que ya existe para paridad impar"). Lo ajusté para admitir las dos formas válidas de una
-- fila de tramo (abierta o cerrada), simétrico con ck_tramo_fin_posterior_a_inicio
-- (`fin IS NULL OR fin > inicio`) -- nunca permite un estado a medias (cierre sin fin o viceversa).
CREATE POLICY tramo_insert_revision ON tiempo.tramo
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND (
      (marca_cierre_id IS NOT NULL AND fin IS NOT NULL AND fin > inicio)
      OR (marca_cierre_id IS NULL AND fin IS NULL)
    )
  );

-- USING (marca_cierre_id IS NULL): sólo se puede tocar un tramo que hoy está abierto (nunca
-- reabrir uno ya cerrado). Mismo nivel de rigor que dia_update_revision -- no valida columna por
-- columna que dia_id/marca_apertura_id/inicio no cambien; ese control lo da el propio RPC, que es
-- el único camino real.
CREATE POLICY tramo_update_revision ON tiempo.tramo
  FOR UPDATE TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND marca_cierre_id IS NULL
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND marca_cierre_id IS NOT NULL AND fin IS NOT NULL AND fin > inicio
  );

-- ============================================================================
-- 2) Extensión de fn_dia_revisar -- misma firma (bigint, numeric), CREATE OR REPLACE (no cambia
-- de parámetros, así que no hace falta DROP -- a diferencia de 63_*.sql -- y el GRANT/REVOKE de
-- 63_*.sql sigue vigente sin tocarlo). horas_totales sigue siendo exactamente lo que RH escribe a
-- mano (p_horas_totales) -- el armado de tramos es un efecto aparte, no lo recalcula ni lo pisa.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)
RETURNS tiempo.dia AS $$
DECLARE
  v_estado_actual    varchar(20);
  v_persona_id       uuid;
  v_fecha            date;
  v_revisor_id       uuid;
  v_filas            integer;
  v_resultado        tiempo.dia;

  -- Marcas huérfanas del día (efectivo = corrección más reciente o momento_dispositivo),
  -- ordenadas ascendente. Arrays paralelos + bandera de consumo en vez de tabla temporal --
  -- alcance de una sola invocación, sin efectos entre llamadas concurrentes.
  v_huerfanas_id     bigint[];
  v_huerfanas_ef     timestamptz[];
  v_huerfanas_usada  boolean[];
  v_n                integer;
  v_i                integer;

  v_tramo            record;
  v_marca_cierre_id  bigint;
  v_efectivo_cierre  timestamptz;

  v_rest_id          bigint[];
  v_rest_ef          timestamptz[];
  v_m                integer;
  v_j                integer;
BEGIN
  IF p_horas_totales IS NULL OR p_horas_totales < 0 OR p_horas_totales > 24 THEN
    RAISE EXCEPTION 'Horas trabajadas inválidas: % (debe estar entre 0 y 24)', p_horas_totales
      USING ERRCODE = 'SCJ08';
  END IF;

  SELECT estado, persona_id, fecha INTO v_estado_actual, v_persona_id, v_fecha
  FROM tiempo.dia
  WHERE id = p_dia_id;

  IF v_estado_actual IS NULL THEN
    RAISE EXCEPTION 'El día % no existe', p_dia_id USING ERRCODE = 'SCJ06';
  END IF;

  IF v_estado_actual <> 'bloqueado' THEN
    RAISE EXCEPTION
      'El día % no está bloqueado (estado=%) -- alguien más se adelantó o nunca requirió revisión',
      p_dia_id, v_estado_actual
      USING ERRCODE = 'SCJ07';
  END IF;

  -- Marcas candidatas del día: mismo criterio de "día local" que fn_marca_valida_revision
  -- (momento AT TIME ZONE 'UTC' + desfase_local), pero aplicado al valor EFECTIVO (corregido si
  -- existe, igual que fn_correccion_valida), y sólo las que todavía no pertenecen a ningún tramo.
  -- Ventana ±1 día en momento_dispositivo crudo para no perder marcas cuyo efectivo cruza
  -- medianoche; el filtro real de "es de este día" es el de fecha local efectiva.
  SELECT array_agg(candidatas.marca_id ORDER BY candidatas.efectivo),
         array_agg(candidatas.efectivo ORDER BY candidatas.efectivo)
    INTO v_huerfanas_id, v_huerfanas_ef
  FROM (
    SELECT m.id AS marca_id,
           COALESCE(
             (SELECT c.valor_corregido FROM tiempo.correccion c
                WHERE c.marca_id = m.id ORDER BY c.creado_en DESC LIMIT 1),
             m.momento_dispositivo
           ) AS efectivo,
           m.desfase_local AS desfase_local
    FROM tiempo.marca m
    WHERE m.persona_id = v_persona_id
      AND m.momento_dispositivo::date BETWEEN v_fecha - 1 AND v_fecha + 1
  ) candidatas
  WHERE ((candidatas.efectivo AT TIME ZONE 'UTC') + candidatas.desfase_local::interval)::date = v_fecha
    AND NOT EXISTS (
      SELECT 1 FROM tiempo.tramo t
      WHERE t.marca_apertura_id = candidatas.marca_id OR t.marca_cierre_id = candidatas.marca_id
    );

  v_huerfanas_id := COALESCE(v_huerfanas_id, ARRAY[]::bigint[]);
  v_huerfanas_ef := COALESCE(v_huerfanas_ef, ARRAY[]::timestamptz[]);
  v_n := COALESCE(array_length(v_huerfanas_id, 1), 0);
  v_huerfanas_usada := array_fill(false, ARRAY[v_n]);

  -- Cerrar tramos abiertos existentes del día con la huérfana disponible más temprana que
  -- califique (efectivo > inicio del tramo). Si ninguna califica, se deja abierto y se sigue.
  FOR v_tramo IN
    SELECT id, marca_apertura_id, inicio
    FROM tiempo.tramo
    WHERE dia_id = p_dia_id AND marca_cierre_id IS NULL
    ORDER BY inicio
  LOOP
    v_marca_cierre_id := NULL;
    v_efectivo_cierre := NULL;

    FOR v_i IN 1..v_n LOOP
      IF NOT v_huerfanas_usada[v_i] AND v_huerfanas_ef[v_i] > v_tramo.inicio THEN
        v_marca_cierre_id := v_huerfanas_id[v_i];
        v_efectivo_cierre := v_huerfanas_ef[v_i];
        v_huerfanas_usada[v_i] := true;
        EXIT;
      END IF;
    END LOOP;

    IF v_marca_cierre_id IS NOT NULL THEN
      UPDATE tiempo.tramo
      SET marca_cierre_id = v_marca_cierre_id,
          fin = v_efectivo_cierre,
          minutos_trabajados = EXTRACT(EPOCH FROM (v_efectivo_cierre - v_tramo.inicio)) / 60.0
      WHERE id = v_tramo.id;

      UPDATE tiempo.excepcion
      SET estado = 'resuelto'
      WHERE marca_id IN (v_tramo.marca_apertura_id, v_marca_cierre_id) AND estado = 'pendiente';
    END IF;
  END LOOP;

  -- Formar tramos nuevos con las huérfanas que sobran, de a pares consecutivos por efectivo
  -- ascendente. Si sobra una sin pareja, se inserta un tramo abierto (mismo patrón que ya existe
  -- para paridad impar) -- esa huérfana no resuelve su excepción, sigue sin saberse su cierre real.
  SELECT array_agg(v_huerfanas_id[gs.i] ORDER BY gs.i),
         array_agg(v_huerfanas_ef[gs.i] ORDER BY gs.i)
    INTO v_rest_id, v_rest_ef
  FROM generate_series(1, v_n) AS gs(i)
  WHERE NOT v_huerfanas_usada[gs.i];

  v_rest_id := COALESCE(v_rest_id, ARRAY[]::bigint[]);
  v_rest_ef := COALESCE(v_rest_ef, ARRAY[]::timestamptz[]);
  v_m := COALESCE(array_length(v_rest_id, 1), 0);

  v_j := 1;
  WHILE v_j <= v_m LOOP
    IF v_j + 1 <= v_m THEN
      INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
      VALUES (
        p_dia_id, v_rest_id[v_j], v_rest_id[v_j + 1], v_rest_ef[v_j], v_rest_ef[v_j + 1],
        EXTRACT(EPOCH FROM (v_rest_ef[v_j + 1] - v_rest_ef[v_j])) / 60.0
      );

      UPDATE tiempo.excepcion
      SET estado = 'resuelto'
      WHERE marca_id IN (v_rest_id[v_j], v_rest_id[v_j + 1]) AND estado = 'pendiente';

      v_j := v_j + 2;
    ELSE
      INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
      VALUES (p_dia_id, v_rest_id[v_j], NULL, v_rest_ef[v_j], NULL, NULL);

      v_j := v_j + 1;
    END IF;
  END LOOP;

  SELECT u.persona_id INTO v_revisor_id
  FROM personas.usuario u
  WHERE u.auth_user_id = auth.uid();

  UPDATE tiempo.dia
  SET estado = 'revisado', revisado_por = v_revisor_id, revisado_en = now(),
      horas_totales = p_horas_totales
  WHERE id = p_dia_id AND estado = 'bloqueado';

  GET DIAGNOSTICS v_filas = ROW_COUNT;
  IF v_filas = 0 THEN
    RAISE EXCEPTION
      'El día % dejó de estar bloqueado entre la verificación y la actualización', p_dia_id
      USING ERRCODE = 'SCJ07';
  END IF;

  SELECT * INTO v_resultado FROM tiempo.dia WHERE id = p_dia_id;

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_dia_revisar(bigint, numeric) IS
  'RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH '
  'y armado automático de los tramos que quedaron sin cerrar (marcas huérfanas llegadas después '
  'del bloqueo) -- cierra tramos abiertos existentes con la huérfana más temprana que califique y '
  'arma tramos nuevos de a pares con lo que sobra, resolviendo las excepciones pendientes de las '
  'marcas emparejadas. horas_totales del día sigue siendo exactamente lo que RH escribió, el '
  'armado de tramos no lo recalcula. Única transición bloqueado -> revisado alcanzable por un '
  'humano. SECURITY INVOKER -- dia_update_revision/tramo_insert_revision/tramo_update_revision '
  'son la autorización real. Señales de conflicto: ERRCODE SCJ06 (día no existe/no visible), '
  'SCJ07 (ya no está bloqueado, incluida la carrera de dos revisiones simultáneas), SCJ08 '
  '(horas_totales fuera de [0, 24] o NULL) -- ver cabecera de 64_tiempo_tramo_formar_al_revisar.sql '
  'para el mapeo exacto que debe hacer backend. GRANT/REVOKE de 63_tiempo_dia_revisar_horas.sql '
  'siguen vigentes -- misma firma, sin DROP.';
