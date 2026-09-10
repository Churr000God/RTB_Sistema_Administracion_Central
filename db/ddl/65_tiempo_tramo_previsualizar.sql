-- 65_tiempo_tramo_previsualizar.sql
-- Extrae el cálculo del armado de tramos de fn_dia_revisar (64_tiempo_tramo_formar_al_revisar.sql)
-- a una función de sólo lectura, para dos cosas nuevas: (1) previsualizar qué haría "revisar"
-- antes de comprometerse (frontend), y (2) bloquear la revisión completa si el algoritmo dejaría
-- una marca huérfana sin pareja -- antes ese caso se resolvía en silencio insertando un tramo
-- abierto; ahora es un error explícito, todo o nada (SCJ09), porque una marca sin pareja es una
-- marca real faltante (llegada tardía sin su par de entrada/salida) que debe corregirse a mano, no
-- una jornada legítimamente incompleta.
--
-- Consecuencia de este cambio para orchestrator/usuario, NO resuelta en este archivo: con SCJ09
-- bloqueando todo el revisar en cuanto hay una huérfana sin pareja, fn_dia_revisar YA NUNCA
-- ejecuta la rama "tramo abierto" del paso 5 de 64_*.sql -- todo INSERT que hace ahora es siempre
-- un par completo (marca_apertura_id + marca_cierre_id + fin, los tres presentes). La rama
-- `(marca_cierre_id IS NULL AND fin IS NULL)` de `tramo_insert_revision` (64_*.sql) queda sin
-- ningún llamador legítimo -- sigue viva en la policy y technically permite que cualquier
-- autenticado con dia_revision_edicion inserte un tramo abierto arbitrario directo por PostgREST,
-- sin pasar por el RPC ni por ninguna validación de huérfanas/paridad. No la toco en este archivo
-- porque no fue parte del pedido -- lo señalo para que orchestrator/usuario decidan si vale la
-- pena angostar esa policy (quitar la rama de tramo abierto) en un corte aparte.
-- Depende de: 02_tiempo.sql, 54_tiempo_rls_tramo_lectura.sql, 62_tiempo_dia_revision.sql,
--   63_tiempo_dia_revisar_horas.sql, 64_tiempo_tramo_formar_al_revisar.sql
-- Justificación: SCJ-DEC-06, SCJ-DEC-01 (paridad apertura/cierre de tramo)

-- ============================================================================
-- 1) tiempo.fn_dia_calcular_armado_tramos -- SECURITY INVOKER, STABLE (cero escritura, mismo
-- algoritmo de huérfanas/pares que fn_dia_revisar pero devolviendo las acciones en vez de
-- ejecutarlas). Sin RLS especial: sólo lee tiempo.dia/tiempo.marca/tiempo.correccion/tiempo.tramo,
-- cubierto por dia_lectura/marca_lectura/correccion_lectura-o-edicion/tramo_lectura, que los 3
-- puestos con dia_revision_edicion ya tienen (verificado en 62_/64_*.sql). Si tiempo.dia no existe
-- o no es visible, v_persona_id/v_fecha quedan NULL y la función devuelve cero filas en silencio
-- -- no es su responsabilidad señalar "el día no existe", eso lo sigue haciendo fn_dia_revisar
-- (SCJ06) cuando de verdad se intenta revisar.
-- ============================================================================

CREATE FUNCTION tiempo.fn_dia_calcular_armado_tramos(p_dia_id bigint)
RETURNS TABLE(
  accion              varchar,
  tramo_id            bigint,
  marca_apertura_id   bigint,
  marca_cierre_id     bigint,
  inicio              timestamptz,
  fin                 timestamptz,
  minutos_trabajados  numeric
) AS $$
DECLARE
  v_persona_id       uuid;
  v_fecha            date;

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
  SELECT persona_id, fecha INTO v_persona_id, v_fecha
  FROM tiempo.dia
  WHERE id = p_dia_id;

  -- Marcas candidatas del día: mismo criterio de "día local" que fn_marca_valida_revision
  -- (momento AT TIME ZONE 'UTC' + desfase_local) aplicado al valor EFECTIVO (corregido si existe,
  -- igual que fn_correccion_valida), sólo las que todavía no pertenecen a ningún tramo. Ventana
  -- ±1 día en momento_dispositivo crudo para no perder marcas cuyo efectivo cruza medianoche.
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

  -- accion='cerrar_existente': tramos abiertos del día que se cerrarían con la huérfana
  -- disponible más temprana que califique (efectivo > inicio del tramo).
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
      accion := 'cerrar_existente';
      tramo_id := v_tramo.id;
      marca_apertura_id := v_tramo.marca_apertura_id;
      marca_cierre_id := v_marca_cierre_id;
      inicio := v_tramo.inicio;
      fin := v_efectivo_cierre;
      minutos_trabajados := EXTRACT(EPOCH FROM (fin - inicio)) / 60.0;
      RETURN NEXT;
    END IF;
  END LOOP;

  -- accion='nuevo' / 'huerfana_sin_pareja': huérfanas restantes, de a pares consecutivos por
  -- efectivo ascendente; si sobra una, se señala sin pareja en vez de armar un tramo abierto.
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
      accion := 'nuevo';
      tramo_id := NULL;
      marca_apertura_id := v_rest_id[v_j];
      marca_cierre_id := v_rest_id[v_j + 1];
      inicio := v_rest_ef[v_j];
      fin := v_rest_ef[v_j + 1];
      minutos_trabajados := EXTRACT(EPOCH FROM (fin - inicio)) / 60.0;
      RETURN NEXT;

      v_j := v_j + 2;
    ELSE
      accion := 'huerfana_sin_pareja';
      tramo_id := NULL;
      marca_apertura_id := v_rest_id[v_j];
      marca_cierre_id := NULL;
      inicio := v_rest_ef[v_j];
      fin := NULL;
      minutos_trabajados := NULL;
      RETURN NEXT;

      v_j := v_j + 1;
    END IF;
  END LOOP;

  RETURN;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION tiempo.fn_dia_calcular_armado_tramos(bigint) IS
  'Calcula (sin escribir) qué haría fn_dia_revisar al armar los tramos faltantes de un día: una '
  'fila por acción -- cerrar_existente (cierra un tramo abierto con una huérfana), nuevo (arma un '
  'tramo nuevo con un par de huérfanas), huerfana_sin_pareja (marca que quedaría sin pareja -- '
  'fn_dia_revisar bloquea con SCJ09 si aparece alguna). Usada para previsualizar en el frontend y '
  'para la validación previa al revisar real. STABLE, SECURITY INVOKER -- sólo SELECT, cubierto '
  'por los mismos permisos de lectura que ya tienen los 3 puestos con dia_revision_edicion.';

GRANT EXECUTE ON FUNCTION tiempo.fn_dia_calcular_armado_tramos(bigint) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_dia_calcular_armado_tramos(bigint) FROM PUBLIC;

-- ============================================================================
-- 1.5) Angostar tramo_insert_revision (64_*.sql) -- con SCJ09 bloqueando todo el revisar en
-- cuanto queda una huérfana sin pareja, fn_dia_revisar ya nunca inserta un tramo abierto: la rama
-- (marca_cierre_id IS NULL AND fin IS NULL) quedó sin ningún llamador legítimo. Se quita ahora en
-- vez de dejarla "por si acaso" -- mismo criterio que ya documenta el proyecto sobre no dejar RLS
-- más permisiva de lo que el flujo real necesita.
-- ============================================================================

ALTER POLICY tramo_insert_revision ON tiempo.tramo
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND marca_cierre_id IS NOT NULL AND fin IS NOT NULL AND fin > inicio
  );

-- ============================================================================
-- 2) fn_dia_revisar -- misma firma (bigint, numeric), sin DROP. El bloque de armado inline de
-- 64_*.sql se reemplaza por: pre-chequeo de huerfana_sin_pareja (todo o nada, SCJ09, ANTES de
-- tocar cualquier tabla), y luego iterar fn_dia_calcular_armado_tramos aplicando cada acción real.
-- horas_totales sigue siendo exactamente lo que RH escribe a mano -- sin cambios ahí.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)
RETURNS tiempo.dia AS $$
DECLARE
  v_estado_actual  varchar(20);
  v_revisor_id     uuid;
  v_filas          integer;
  v_resultado      tiempo.dia;
  v_accion         record;
BEGIN
  IF p_horas_totales IS NULL OR p_horas_totales < 0 OR p_horas_totales > 24 THEN
    RAISE EXCEPTION 'Horas trabajadas inválidas: % (debe estar entre 0 y 24)', p_horas_totales
      USING ERRCODE = 'SCJ08';
  END IF;

  SELECT estado INTO v_estado_actual
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

  -- Todo o nada: si el armado dejaría alguna marca sin pareja, no se aplica ninguna acción --
  -- ni siquiera los cierres/pares que sí calificaban -- hay que corregir la marca faltante o usar
  -- captura manual antes de poder revisar el día.
  IF EXISTS (
    SELECT 1 FROM tiempo.fn_dia_calcular_armado_tramos(p_dia_id) WHERE accion = 'huerfana_sin_pareja'
  ) THEN
    RAISE EXCEPTION
      'El día % tiene una marca sin pareja -- corregí la marca faltante o usá captura manual antes '
      'de revisar', p_dia_id
      USING ERRCODE = 'SCJ09';
  END IF;

  FOR v_accion IN SELECT * FROM tiempo.fn_dia_calcular_armado_tramos(p_dia_id) LOOP
    IF v_accion.accion = 'cerrar_existente' THEN
      UPDATE tiempo.tramo
      SET marca_cierre_id = v_accion.marca_cierre_id,
          fin = v_accion.fin,
          minutos_trabajados = v_accion.minutos_trabajados
      WHERE id = v_accion.tramo_id;

      UPDATE tiempo.excepcion
      SET estado = 'resuelto'
      WHERE marca_id IN (v_accion.marca_apertura_id, v_accion.marca_cierre_id) AND estado = 'pendiente';

    ELSIF v_accion.accion = 'nuevo' THEN
      INSERT INTO tiempo.tramo (dia_id, marca_apertura_id, marca_cierre_id, inicio, fin, minutos_trabajados)
      VALUES (
        p_dia_id, v_accion.marca_apertura_id, v_accion.marca_cierre_id, v_accion.inicio, v_accion.fin,
        v_accion.minutos_trabajados
      );

      UPDATE tiempo.excepcion
      SET estado = 'resuelto'
      WHERE marca_id IN (v_accion.marca_apertura_id, v_accion.marca_cierre_id) AND estado = 'pendiente';
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
  'RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH. '
  'El armado de tramos faltantes se calcula con tiempo.fn_dia_calcular_armado_tramos y se aplica '
  'todo o nada: si alguna marca quedaría sin pareja, no se revisa nada (SCJ09) -- corregir la '
  'marca o usar captura manual primero. horas_totales del día sigue siendo exactamente lo que RH '
  'escribió, el armado de tramos no lo recalcula. Única transición bloqueado -> revisado '
  'alcanzable por un humano. SECURITY INVOKER -- dia_update_revision/tramo_insert_revision/'
  'tramo_update_revision son la autorización real. Señales de conflicto: ERRCODE SCJ06 (día no '
  'existe/no visible), SCJ07 (ya no está bloqueado, incluida la carrera de dos revisiones '
  'simultáneas), SCJ08 (horas_totales fuera de [0, 24] o NULL), SCJ09 (quedaría una marca sin '
  'pareja) -- ver cabecera de 65_tiempo_tramo_previsualizar.sql para el mapeo exacto que debe '
  'hacer backend. GRANT/REVOKE de 63_tiempo_dia_revisar_horas.sql siguen vigentes -- misma firma, '
  'sin DROP.';
