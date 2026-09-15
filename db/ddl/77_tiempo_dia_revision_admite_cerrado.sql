-- 77_tiempo_dia_revision_admite_cerrado.sql
-- Fix de bug real reportado en vivo (2026-09-15): marcas tardías capturadas por captura manual
-- sobre un día que ya cerró PAR (tiempo.dia.estado='cerrado', cierre_dia.py armó sus tramos y
-- calculó horas_totales sin problema, sin paridad impar ni excepción de día) nunca podían
-- convertirse en tramo. tiempo.fn_dia_calcular_armado_tramos (65_/73_*.sql) SÍ las detecta y arma
-- el par correcto (confirmado en vivo contra tiempo.dia.id=5: devuelve accion='nuevo',
-- marca_apertura_id/marca_cierre_id de las 2 marcas tardías, 180 minutos) -- el cálculo nunca
-- filtró por estado. El problema es que NINGÚN camino de escritura lo admite: tanto
-- dia_update_revision (62_*.sql) como el chequeo interno de fn_dia_revisar (62_/65_/74_*.sql)
-- exigen textualmente estado = 'bloqueado', dejando fuera 'cerrado' -- ese tiempo queda muerto
-- para siempre, sin tramo, sin reflejarse en horas_totales, sin ningún RPC que lo repare.
--
-- SCJ-DEC-06 sólo describe la transición humana como "bloqueado -> revisado" porque el caso que
-- originó el documento era la paridad impar (día con número impar de marcas al cierre). El caso
-- real encontrado ahora es distinto pero análogo: un día que cerró completo (par) con la
-- información que había en ese momento, y después llegan marcas tardías que, si se hubieran
-- capturado a tiempo, habrían cambiado el resultado. Mismo principio de "revisión explícita de
-- RH, demostrable" que ya cubre 'bloqueado' -- se extiende la transición a 'cerrado -> revisado',
-- reusando exactamente el mismo RPC/algoritmo (no hay dos casos que tratar distinto: el cálculo de
-- fn_dia_calcular_armado_tramos ya es agnóstico al estado del día, sólo mira las marcas).
--
-- Alcance explícitamente NO tocado en este archivo (fuera del pedido, lo investiga `security`
-- aparte): las excepciones id=9/10 (motivo dia_cerrado sobre las marcas 13/14 de tiempo.dia.id=5)
-- ya aparecen estado='resuelto' sin que exista ningún mecanismo en el DDL que las resuelva para un
-- día 'cerrado' -- hallazgo real encontrado durante el diagnóstico, ajeno a este fix.
--
-- Depende de: 62_tiempo_dia_revision.sql, 63_tiempo_dia_revisar_horas.sql,
--   64_tiempo_tramo_formar_al_revisar.sql, 65_tiempo_tramo_previsualizar.sql,
--   74_tiempo_fn_dia_revisar_resuelve_excepcion_de_dia.sql
-- Justificación: SCJ-DEC-06 (extensión de la única transición manual permitida)

-- ============================================================================
-- 0) Verificación de la nota "CREATE OR REPLACE no hereda ALTER FUNCTION posterior" (gotcha de
-- CLAUDE.md, ya pasó con fn_ausencia_resuelve_excepcion): grep de "ALTER FUNCTION.*fn_dia_revisar"
-- en todo db/ddl/*.sql antes de escribir este archivo -- CERO resultados. fn_dia_revisar nunca
-- salió de SECURITY INVOKER por default (siempre CREATE FUNCTION / CREATE OR REPLACE FUNCTION
-- sin cláusula explícita, desde 62_*.sql:103 hasta 74_*.sql:15) -- no hay nada que repetir acá.
-- ============================================================================

-- ============================================================================
-- 1) dia_update_revision (62_*.sql:74-84) -- USING amplía a 'bloqueado' O 'cerrado'. WITH CHECK
-- no cambia (sigue exigiendo estado nuevo = 'revisado' + revisado_en/revisado_por del propio
-- caller) -- la fila resultante es indistinguible de una que vino de 'bloqueado', a propósito:
-- SCJ-DEC-06 ya decidió que 'revisado' es el único destino, sin distinguir de dónde vino.
-- ============================================================================

ALTER POLICY dia_update_revision ON tiempo.dia
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND estado IN ('bloqueado', 'cerrado')
  );

-- ============================================================================
-- 2) tramo_insert_revision / tramo_update_revision (64_*.sql) -- revisadas, NO gatean por
-- tiempo.dia.estado en ningún punto (sólo por permiso + columnas de tiempo.tramo mismo:
-- marca_cierre_id/fin/inicio). No necesitan cambio -- ya admiten escribir tramos de un día
-- 'cerrado' igual que de uno 'bloqueado', siempre que quien llama tenga dia_revision_edicion.
-- ============================================================================

-- ============================================================================
-- 3) fn_dia_revisar -- misma firma (bigint, numeric), sin DROP (no cambia de parámetros). Único
-- cambio real: el chequeo de estado admite también 'cerrado', mismo ERRCODE SCJ07 para cualquier
-- otro estado ('abierto' o 'revisado' ya no son revisables, igual que antes). El resto del cuerpo
-- -- cálculo todo-o-nada con SCJ09, aplicación de fn_dia_calcular_armado_tramos, resolución de
-- excepciones de marca Y de día (74_*.sql) -- queda idéntico: ya es agnóstico al estado de origen,
-- no hace falta ninguna rama nueva.
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

  IF v_estado_actual NOT IN ('bloqueado', 'cerrado') THEN
    RAISE EXCEPTION
      'El día % no está bloqueado ni cerrado (estado=%) -- alguien más se adelantó o nunca '
      'requirió revisión', p_dia_id, v_estado_actual
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

  -- Excepciones de día (marca_id NULL, dia_id = p_dia_id -- paridad_impar hoy): el armado con
  -- éxito de arriba ya es el evento que las resuelve (SCJ-DEC-07, 74_*.sql). Un día que llegó
  -- 'cerrado' a esta función nunca tuvo excepción de día (sólo la paridad impar la genera, y esa
  -- deja el día 'bloqueado', no 'cerrado') -- este UPDATE no encuentra filas en ese caso, sin
  -- efecto, no hace falta condicionarlo.
  UPDATE tiempo.excepcion
  SET estado = 'resuelto'
  WHERE dia_id = p_dia_id AND estado = 'pendiente';

  SELECT u.persona_id INTO v_revisor_id
  FROM personas.usuario u
  WHERE u.auth_user_id = auth.uid();

  UPDATE tiempo.dia
  SET estado = 'revisado', revisado_por = v_revisor_id, revisado_en = now(),
      horas_totales = p_horas_totales
  WHERE id = p_dia_id AND estado IN ('bloqueado', 'cerrado');

  GET DIAGNOSTICS v_filas = ROW_COUNT;
  IF v_filas = 0 THEN
    RAISE EXCEPTION
      'El día % dejó de estar bloqueado/cerrado entre la verificación y la actualización', p_dia_id
      USING ERRCODE = 'SCJ07';
  END IF;

  SELECT * INTO v_resultado FROM tiempo.dia WHERE id = p_dia_id;

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_dia_revisar(bigint, numeric) IS
  'RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH. '
  'Admite tanto días bloqueado (paridad impar al cierre) como cerrado (par al cierre, pero llegó '
  'una marca tardía después que fn_dia_calcular_armado_tramos sí puede emparejar -- 77_*.sql, '
  '2026-09-15). El armado de tramos faltantes se calcula con tiempo.fn_dia_calcular_armado_tramos '
  'y se aplica todo o nada: si alguna marca quedaría sin pareja, no se revisa nada (SCJ09) -- '
  'corregir la marca o usar captura manual primero. horas_totales del día sigue siendo exactamente '
  'lo que RH escribió, el armado de tramos no lo recalcula. Única transición alcanzable por un '
  'humano hacia "revisado". SECURITY INVOKER -- dia_update_revision/tramo_insert_revision/'
  'tramo_update_revision son la autorización real. Resuelve tanto las excepciones de marca '
  '(marca_id IN apertura/cierre, incluido motivo dia_cerrado) como las de día (dia_id = p_dia_id, '
  'marca_id NULL -- paridad_impar). Señales de conflicto: ERRCODE SCJ06 (día no existe/no visible), '
  'SCJ07 (no está bloqueado ni cerrado, incluida la carrera de dos revisiones simultáneas), SCJ08 '
  '(horas_totales fuera de [0, 24] o NULL), SCJ09 (quedaría una marca sin pareja) -- ver cabecera de '
  '77_tiempo_dia_revision_admite_cerrado.sql para el mapeo exacto que debe hacer backend. '
  'GRANT/REVOKE de 63_tiempo_dia_revisar_horas.sql siguen vigentes -- misma firma, sin DROP.';
