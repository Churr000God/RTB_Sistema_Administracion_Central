-- 118_tiempo_ausencia_jornada_neta_con_minutos_comida.sql
-- Corrige la «jornada completa neta» que tiempo.fn_ausencia_resuelve_excepcion escribe en tiempo.dia.horas_totales al resolver una ausencia (vacaciones, permiso con goce, incapacidad
-- autorizados, y de_confianza). 66_ la calculaba como (hora_salida - hora_entrada) - descuento_pausa_no_registrada_min (parámetro global, 60 min), pero el corte quincenal espera por cada fila de
-- patron_semanal (hora_salida - hora_entrada - minutos_comida), la fórmula de backend/app/batches/corte_quincenal.py::_horas_patron_fila. Con minutos_comida distinto de 60 (o con jornada partida, donde
-- el descuento global se restaba UNA vez sobre la suma de las filas y minutos_comida se resta por fila) el día de permiso no quedaba neutro. Caso real (oct-2026): una persona con 13 permisos con goce
-- guardó 11 h por día donde el corte esperaba 6.
--
-- DECISIÓN DEL USUARIO (opción a): la jornada completa neta de las ausencias usa minutos_comida del patrón, por fila, igual que el corte. El parámetro descuento_pausa_no_registrada_min queda SOLO
-- para backend/app/batches/cierre_dia.py en los días de 2 marcas (un solo tramo, sin pausa marcada); deja de intervenir en las ausencias. Esto REVIERTE el punto 1 de 66_ (el punto 2 —la excepción
-- deliberada de de_confianza, que nunca queda en 0— se conserva tal cual).
--
-- QUÉ CAMBIA: el cálculo de v_jornada_completa_neta: SUM sobre las filas del día de (salida - entrada) en horas menos minutos_comida / 60, sin acotar por fila (igual que el corte) y con
-- GREATEST(0, total) al final (como 66_). Se retira la lectura del parámetro descuento_pausa_no_registrada_min y su variable. Todo lo demás del cuerpo es idéntico a 66_.
-- QUÉ NO CAMBIA: la firma (sin argumentos, RETURNS trigger), el trigger trg_ausencia_resuelve_excepcion, las ramas (de_confianza / neutro / cero), el ON CONFLICT que solo toca días 'abierto'.
--
-- GOTCHA DE CREATE OR REPLACE (CLAUDE.md): esta función es SECURITY DEFINER con SET search_path = tiempo, pg_temp desde 51_. CREATE OR REPLACE no las hereda: se repiten EXPLÍCITAS abajo, y se
-- repite el REVOKE EXECUTE de 105_ (CREATE OR REPLACE conserva el ACL, pero se deja explícito y verificable). Función de trigger: sin EXECUTE para nadie de la API.
-- REDONDEO: tiempo.dia.horas_totales es numeric(5,2). Un minutos_comida que no sea múltiplo de 3 (p. ej. 50 min = 0.8333 h) se redondea a 2 decimales al guardar, mientras el corte suma float; la
-- diferencia por día es <= 0.005 h. Backend debe redondear las esperadas por día a 2 decimales (o comparar con tolerancia) para que un permiso quede neutro al centésimo.
-- NO TOCA DATOS EXISTENTES: los días ya escritos con la fórmula de 66_ NO se recalculan aquí; el recálculo de la persona afectada vive en db/correcciones/ (script aparte, sin ejecutar).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 118_*.sql` (o pegado en el SQL Editor).
-- REVERSA (en una transacción): CREATE OR REPLACE con el cuerpo de 66_ repitiendo SECURITY DEFINER SET search_path = tiempo, pg_temp (texto en db/ensayos/ensayo_118.sql, bloque reversa).
-- Depende de: 02_tiempo.sql, 51_*.sql, 66_*.sql, 105_*.sql
-- Justificación: SCJ-PRO-08, SCJ-PRO-12, SCJ-PRO-13, SCJ-PRO-14

CREATE OR REPLACE FUNCTION tiempo.fn_ausencia_resuelve_excepcion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_fecha                   date;
  v_jornada_id              bigint;
  v_tipo_jornada            varchar(20);
  v_dia_semana              varchar(10);
  v_jornada_completa_neta   numeric(6,2);
  v_horas_totales           numeric(5,2);
BEGIN
  IF NEW.estado_autorizacion NOT IN ('autorizada', 'rechazada') THEN
    RETURN NEW; -- sigue pendiente, no se cierra la excepción ni se materializa el día
  END IF;

  IF NEW.estado_autorizacion = 'autorizada' THEN
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia autorizada, carga tardía'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  ELSE
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia rechazada (falta injustificada)'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  END IF;

  -- SCJ-PRO-12 (SCJ-PRA-01 #13): materializa tiempo.dia para cada fecha del rango — sin esto, el
  -- día de una ausencia ya resuelta se queda 'abierto' para siempre, porque el batch de cierre de
  -- día nunca vuelve a tocarlo (ver SCJ-PRO-12 §III, rama G1/G4). ON CONFLICT sólo actualiza si el
  -- día seguía 'abierto' — nunca pisa un día que ya se resolvió por otra vía.
  FOR v_fecha IN
    SELECT generate_series(NEW.fecha_inicio::timestamp, NEW.fecha_fin::timestamp, interval '1 day')::date
  LOOP
    SELECT ja.id, ja.tipo_jornada INTO v_jornada_id, v_tipo_jornada
    FROM tiempo.jornada_asignada ja
    WHERE ja.persona_id = NEW.persona_id
      AND ja.vigente_desde <= v_fecha
      AND (ja.vigente_hasta IS NULL OR ja.vigente_hasta >= v_fecha)
    ORDER BY ja.vigente_desde DESC
    LIMIT 1;

    v_dia_semana := (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                    [EXTRACT(ISODOW FROM v_fecha)::int];

    -- Jornada completa neta del día = suma, POR FILA del patrón, de (salida - entrada) en horas menos
    -- minutos_comida / 60 (118_). Es la misma fórmula del corte quincenal (_horas_patron_fila): sin
    -- acotar cada fila, y GREATEST(0, total) al final. Sin patrón para ese día, 0.
    SELECT GREATEST(0, COALESCE(
             SUM(EXTRACT(EPOCH FROM (ps.hora_salida - ps.hora_entrada)) / 3600.0 - ps.minutos_comida / 60.0),
             0))
      INTO v_jornada_completa_neta
    FROM tiempo.patron_semanal ps
    WHERE ps.jornada_asignada_id = v_jornada_id AND ps.dia_semana = v_dia_semana;

    IF v_tipo_jornada = 'de_confianza' THEN
      -- SCJ-PRO-14 decía siempre NULL; excepción deliberada confirmada con el usuario (66_): una
      -- ausencia resuelta (cualquier tipo, incluso rechazada) SIEMPRE pone la jornada completa
      -- para de_confianza -- "su horario no marca faltas". Si no hay patrón cargado, cae a NULL
      -- (nunca 0, para no leerse como "faltó") -- respeta el espíritu original de SCJ-PRO-14 como
      -- último recurso, no como regla general.
      IF v_jornada_completa_neta > 0 THEN
        v_horas_totales := v_jornada_completa_neta;
      ELSE
        v_horas_totales := NULL;
      END IF;
    ELSIF NEW.estado_autorizacion = 'autorizada'
          AND NEW.tipo_de_ausencia IN ('vacaciones', 'permiso_con_goce', 'incapacidad') THEN
      -- Neutro: cuenta como si hubiera trabajado la jornada completa pactada ese día.
      v_horas_totales := v_jornada_completa_neta;
    ELSE
      -- permiso_sin_goce autorizado, o falta rechazada: no cuenta como trabajado -- la deuda la
      -- recoge sola el corte quincenal al comparar horas esperadas contra contabilizadas.
      v_horas_totales := 0;
    END IF;

    INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, origen)
    VALUES (NEW.persona_id, v_fecha, 'cerrado', v_horas_totales, 'ausencia_autorizada')
    ON CONFLICT (persona_id, fecha) DO UPDATE
      SET estado = 'cerrado', horas_totales = EXCLUDED.horas_totales, origen = 'ausencia_autorizada'
      WHERE tiempo.dia.estado = 'abierto';
  END LOOP;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() IS
  'Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion por día sin checada, la resuelve sola. Un rechazo también cuenta como resolución. Sólo pendiente no '
  'toca nada. Además materializa tiempo.dia para cada fecha del rango (SCJ-PRO-12, SCJ-PRA-01 #13): vacaciones/permiso_con_goce/incapacidad autorizados cuentan como jornada completa neta = suma, por '
  'fila de patron_semanal, de (hora_salida - hora_entrada) - minutos_comida (118_, igual que corte_quincenal.py::_horas_patron_fila; ya NO usa descuento_pausa_no_registrada_min, que queda sólo para '
  'cierre_dia en días de 2 marcas); permiso_sin_goce autorizado o falta rechazada, cero. Excepción deliberada para tipo_jornada=de_confianza (66_): cualquier ausencia resuelta, incluso rechazada, pone '
  'la jornada completa neta; NULL sólo si no hay patrón cargado (nunca 0). SECURITY DEFINER + search_path fijo (tiempo, pg_temp): escribe tiempo.dia, que humanos no tocan por RLS directo (51_). '
  'Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';
