-- 125_tiempo_excepcion_horario_descartar.sql
-- Descarte AUDITADO de excepciones de ALERTA DE HORARIO (fuera_de_horario) en días ya cerrados o revisados.
--
-- PROBLEMA (caso real 21-oct-2026, excepción 210). Una marca fuera de horario genera una excepción 'fuera_de_horario' al insertarse (fn_marca_valida_revision, 72_). Mientras el día sigue abierto, RH la resuelve CORRIGIENDO la marca. Si el día
-- cierra con la excepción todavía pendiente, la marca ya forma parte de un tramo y no hay camino: «Corregir» está bloqueado por 87_ (marca en tramo); fn_dia_revisar (77_) resuelve solo las marcas que ARMA, no las que ya están en un tramo; y el
-- descarte de 86_ exige el prefijo 'dia_cerrado' y el día 'revisado'. La excepción queda pendiente para siempre (no afecta ningún cálculo: el tramo y las horas ya cuentan la marca).
--
-- QUÉ HACE. Función nueva tiempo.fn_excepcion_horario_descartar(p_excepcion_id bigint, p_motivo text) RETURNS bigint (el id de la fila de auditoría), que descarta una alerta de horario con motivo, autor y fecha:
--   - Autorización DENTRO: persona activa con el permiso de acción excepcion_dia_cerrado_descarte (no heredable; RH, Gerente General y TI). Se REUSA ese permiso: es el mismo acto (cerrar con constancia una excepción de marca que el flujo normal ya
--     no puede resolver) y evita un permiso más; si se prefiere uno propio se agrega sin tocar la función. El autor sale de auth.uid() (personas.usuario), NUNCA de un parámetro.
--   - Reglas: la excepción existe, es de MARCA (marca_id no nulo), su motivo empieza por 'fuera_de_horario' (el único motivo de alerta de horario que existe: 72_ no genera variantes de entrada/salida; el prefijo admite el sufijo que
--     deja una resolución o reapertura), está pendiente, el día de esa persona y fecha local de la marca está 'cerrado' o 'revisado' (con el día abierto, bloqueado o inexistente el flujo correcto es Corregir o Revisar), la alerta NO es de una marca
--     propia (nadie descarta su propia alerta, coherente con 122_) y el motivo, recortado, mide de 10 a 500 caracteres (se rechaza, no se trunca).
--   - Efecto: INSERT en tiempo.excepcion_descarte (la auditoría inmutable de 86_: excepcion_id, dia_id, persona_id = quien descarta, motivo, creado_en) y la excepción pasa a 'resuelto' con el sufijo ' — descartada por <persona_id>: <motivo>', igual que 86_.
--     Esa tabla ya admite este uso sin cambios: su estructura no depende del tipo de excepción (la excepción ligada dice cuál es) y sus triggers de inmutabilidad (UPDATE, DELETE, TRUNCATE) aplican igual. NO se agrega columna 'tipo'.
--   - Triggers de excepcion (86_): trg_excepcion_protege_columnas admite justo este cambio (pendiente -> resuelto agregando un sufijo ' — ...'); trg_excepcion_protege_dia_cerrado SOLO se dispara para motivos 'dia_cerrado%' y no interviene.
--
-- ERRORES (literales fijos; SCJ28 salvo el primero). Lista exacta para backend:
--   42501 / HINT 'sin_permiso'                (no es persona activa con el permiso, o no tiene persona/usuario)
--   SCJ28 / 'motivo_obligatorio'              (motivo vacío o NULL)
--   SCJ28 / 'motivo_corto'                    (menos de 10 caracteres)
--   SCJ28 / 'motivo_largo'                    (más de 500 caracteres)
--   SCJ28 / 'excepcion_inexistente'
--   SCJ28 / 'no_es_alerta_de_horario'         (de día, o de otro motivo: dia_cerrado%, reloj_no_sincronizado, etc.)
--   SCJ28 / 'ya_resuelta'
--   SCJ28 / 'alerta_propia'                   (la marca es de quien descarta)
--   SCJ28 / 'dia_no_cerrado'                  (el día de la marca está abierto, bloqueado o no existe)
-- Mensajes fijos, sin valores ni identificadores.
--
-- SEGURIDAD. SECURITY DEFINER con search_path = tiempo, personas, pg_temp; REVOKE EXECUTE de PUBLIC, anon, authenticated y service_role y GRANT solo a authenticated (la llama el caller desde backend). Se agrega a la lista cerrada de la
--   sección 70(d) de verificar_ddl.sql en el MISMO cambio. Lee con FOR UPDATE la excepción (serializa dos descartes simultáneos). No hay funciones existentes reescritas: sin gotcha de CREATE OR REPLACE.
-- COMPATIBILIDAD: 125_ no depende de 123_ ni de 124_ ni los afecta (no toca tramo, dia ni marca); se puede aplicar en cualquier orden, primero o después. Su ensayo reproduce el caso real con datos sintéticos.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 125_*.sql`.
-- REVERSA (en una transacción): DROP FUNCTION tiempo.fn_excepcion_horario_descartar(bigint, text). Las filas de auditoría ya escritas quedan (son inmutables) y las excepciones descartadas quedan resueltas.
-- Depende de: 02_tiempo.sql, 72_*.sql, 86_*.sql
-- Justificación: SCJ-DEC-07, SCJ-PRO-11

CREATE FUNCTION tiempo.fn_excepcion_horario_descartar(p_excepcion_id bigint, p_motivo text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_motivo_min  constant integer := 10;
  c_motivo_max  constant integer := 500;
  v_actor       uuid;
  v_motivo      text;
  v_exc         tiempo.excepcion;
  v_persona_id  uuid;
  v_dia         tiempo.dia;
  v_id          bigint;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('excepcion_dia_cerrado_descarte')) THEN
    RAISE EXCEPTION 'No tienes permiso para descartar alertas de horario.' USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  SELECT u.persona_id INTO v_actor FROM personas.usuario u WHERE u.auth_user_id = auth.uid();
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'No tienes permiso para descartar alertas de horario.' USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  -- Normalización del motivo (antes de medirlo): los caracteres de control, los separadores de línea y párrafo (U+2028, U+2029), los controles bidireccionales (U+202A-U+202E), los invisibles de ancho cero (U+200B-U+200F, U+2060, U+FEFF)
  -- y el espacio de no separación (U+00A0) pasan a un espacio; luego los grupos de espacios se colapsan a uno y se recorta. Así ni un listado se engaña a la vista ni «a        b» cumple el mínimo de 10.
  v_motivo := btrim(regexp_replace(
                regexp_replace(COALESCE(p_motivo, ''), '[[:cntrl:]\u00A0\u2028\u2029\u202A-\u202E\u200B-\u200F\u2060\uFEFF]', ' ', 'g'),
                '\s+', ' ', 'g'));
  IF v_motivo = '' THEN
    RAISE EXCEPTION 'El motivo del descarte es obligatorio.' USING ERRCODE = 'SCJ28', HINT = 'motivo_obligatorio';
  END IF;
  IF char_length(v_motivo) < c_motivo_min THEN
    RAISE EXCEPTION 'El motivo del descarte es demasiado corto.' USING ERRCODE = 'SCJ28', HINT = 'motivo_corto';
  END IF;
  IF char_length(v_motivo) > c_motivo_max THEN
    RAISE EXCEPTION 'El motivo del descarte es demasiado largo.' USING ERRCODE = 'SCJ28', HINT = 'motivo_largo';
  END IF;

  SELECT e.* INTO v_exc FROM tiempo.excepcion e WHERE e.id = p_excepcion_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La excepción no existe.' USING ERRCODE = 'SCJ28', HINT = 'excepcion_inexistente';
  END IF;

  IF v_exc.marca_id IS NULL OR v_exc.motivo_revision NOT LIKE 'fuera\_de\_horario%' THEN
    RAISE EXCEPTION 'La excepción no es una alerta de horario.' USING ERRCODE = 'SCJ28', HINT = 'no_es_alerta_de_horario';
  END IF;

  IF v_exc.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'La excepción ya está resuelta.' USING ERRCODE = 'SCJ28', HINT = 'ya_resuelta';
  END IF;

  SELECT m.persona_id INTO v_persona_id FROM tiempo.marca m WHERE m.id = v_exc.marca_id;
  IF v_persona_id = v_actor THEN
    RAISE EXCEPTION 'No puedes descartar tu propia alerta de horario.' USING ERRCODE = 'SCJ28', HINT = 'alerta_propia';
  END IF;

  SELECT d.* INTO v_dia FROM tiempo.dia d WHERE d.persona_id = v_persona_id AND d.fecha = tiempo.fn_marca_fecha_local(v_exc.marca_id);
  IF NOT FOUND OR v_dia.estado NOT IN ('cerrado', 'revisado') THEN
    RAISE EXCEPTION 'El día de la marca no está cerrado ni revisado; se resuelve corrigiendo la marca o revisando el día.' USING ERRCODE = 'SCJ28', HINT = 'dia_no_cerrado';
  END IF;

  INSERT INTO tiempo.excepcion_descarte (excepcion_id, dia_id, persona_id, motivo)
  VALUES (p_excepcion_id, v_dia.id, v_actor, v_motivo)
  RETURNING id INTO v_id;

  UPDATE tiempo.excepcion
  SET estado = 'resuelto',
      motivo_revision = motivo_revision || ' — descartada por ' || v_actor::text || ': ' || v_motivo
  WHERE id = p_excepcion_id;

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_horario_descartar(bigint, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_excepcion_horario_descartar(bigint, text) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_excepcion_horario_descartar(bigint, text) IS
  '125_. Descarta con constancia una alerta fuera_de_horario pendiente de una marca ajena cuyo día está cerrado o revisado: exige persona activa con excepcion_dia_cerrado_descarte (no heredable) DENTRO de la función, autor por auth.uid(), '
  'motivo de 10 a 500 caracteres, registra en tiempo.excepcion_descarte y resuelve la excepción con el sufijo '' — descartada por <persona_id>: <motivo>''. Devuelve el id de la auditoría. 42501/sin_permiso; SCJ28 con HINT motivo_obligatorio | '
  'motivo_corto | motivo_largo | excepcion_inexistente | no_es_alerta_de_horario | ya_resuelta | alerta_propia | dia_no_cerrado. SECURITY DEFINER SET search_path = tiempo, personas, pg_temp; EXECUTE solo authenticated.';
