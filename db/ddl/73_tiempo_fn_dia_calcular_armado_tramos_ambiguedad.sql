-- 73_tiempo_fn_dia_calcular_armado_tramos_ambiguedad.sql
-- Fix de bug real (2026-09-11): tiempo.fn_dia_calcular_armado_tramos (65_tiempo_tramo_
-- previsualizar.sql:35-171) declara RETURNS TABLE(..., marca_apertura_id, ..., inicio, ...) --
-- esos nombres de salida quedan en el namespace de la función como si fueran variables. El loop
-- de "cerrar_existente" (línea 100-104 original) los usaba sin calificar
-- (`SELECT id, marca_apertura_id, inicio FROM tiempo.tramo WHERE dia_id = p_dia_id AND
-- marca_cierre_id IS NULL ORDER BY inicio`), y Postgres no puede decidir si `marca_apertura_id`/
-- `inicio` se refieren a la columna de tiempo.tramo o al parámetro de salida homónimo --
-- ERROR real reproducido: "column reference \"marca_apertura_id\" is ambiguous". Rompía tanto la
-- previsualización (frontend) como el POST real de "Revisar" (fn_dia_revisar llama esta función
-- internamente).
--
-- Depende de: 65_tiempo_tramo_previsualizar.sql. Sin ALTER FUNCTION posterior sobre
-- fn_dia_calcular_armado_tramos en todo db/ddl/*.sql (confirmado por grep antes de escribir este
-- archivo) -- mismo GRANT/REVOKE de 65_*.sql siguen vigentes, no se toca la firma.

CREATE OR REPLACE FUNCTION tiempo.fn_dia_calcular_armado_tramos(p_dia_id bigint)
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
  -- disponible más temprana que califique (efectivo > inicio del tramo). Columnas calificadas con
  -- el alias t -- marca_apertura_id e inicio colisionan con los nombres de salida de la función
  -- (fix 73_*.sql, "column reference is ambiguous").
  FOR v_tramo IN
    SELECT t.id, t.marca_apertura_id, t.inicio
    FROM tiempo.tramo t
    WHERE t.dia_id = p_dia_id AND t.marca_cierre_id IS NULL
    ORDER BY t.inicio
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
  'por los mismos permisos de lectura que ya tienen los 3 puestos con dia_revision_edicion. '
  'Columnas del loop de cerrar_existente calificadas con alias de tabla (73_*.sql, 2026-09-11) -- '
  'marca_apertura_id/inicio colisionaban con los nombres de salida de la función.';
