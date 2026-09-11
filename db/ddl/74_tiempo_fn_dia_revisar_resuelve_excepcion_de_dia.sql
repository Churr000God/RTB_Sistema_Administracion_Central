-- 74_tiempo_fn_dia_revisar_resuelve_excepcion_de_dia.sql
-- Fix de bug real (2026-09-11): fn_dia_revisar (65_tiempo_tramo_previsualizar.sql:254-256,
-- 265-267) sólo resolvía excepciones con marca_id IN (apertura, cierre) -- nunca las que cuelgan
-- del día (marca_id NULL, dia_id NOT NULL), el único motivo así del catálogo de 6 es
-- paridad_impar. SCJ-DEC-07 espera auto-resolución vía el evento que causa la excepción; al
-- revisar el día con éxito, ese evento ya ocurrió (los tramos quedaron armados) pero la excepción
-- de día quedaba pendiente para siempre -- routers/excepciones.py es sólo lectura por diseño, no
-- hay ningún endpoint que la resuelva a mano.
--
-- Depende de: 65_tiempo_tramo_previsualizar.sql. Sin ALTER FUNCTION posterior sobre
-- fn_dia_revisar en todo db/ddl/*.sql (confirmado por grep antes de escribir este archivo) --
-- siempre SECURITY INVOKER por default (62_tiempo_dia_revision.sql:87, nunca escrito SECURITY
-- DEFINER), nada que repetir explícito. Misma firma (bigint, numeric), sin DROP.

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

  -- Excepciones de día (marca_id NULL, dia_id = p_dia_id -- hoy sólo paridad_impar, cualquier
  -- motivo de día futuro también queda cubierto por no acoplarse al string exacto): el armado con
  -- éxito de arriba ya es el evento que las resuelve (SCJ-DEC-07). Fix 74_*.sql, 2026-09-11 --
  -- antes quedaban pendiente para siempre, sin ningún endpoint que las resolviera a mano.
  UPDATE tiempo.excepcion
  SET estado = 'resuelto'
  WHERE dia_id = p_dia_id AND estado = 'pendiente';

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
  'tramo_update_revision son la autorización real. Resuelve tanto las excepciones de marca '
  '(marca_id IN apertura/cierre) como las de día (dia_id = p_dia_id, marca_id NULL -- '
  'paridad_impar hoy, 74_*.sql, 2026-09-11). Señales de conflicto: ERRCODE SCJ06 (día no '
  'existe/no visible), SCJ07 (ya no está bloqueado, incluida la carrera de dos revisiones '
  'simultáneas), SCJ08 (horas_totales fuera de [0, 24] o NULL), SCJ09 (quedaría una marca sin '
  'pareja) -- ver cabecera de 65_tiempo_tramo_previsualizar.sql para el mapeo exacto que debe '
  'hacer backend. GRANT/REVOKE de 63_tiempo_dia_revisar_horas.sql siguen vigentes -- misma firma, '
  'sin DROP.';
