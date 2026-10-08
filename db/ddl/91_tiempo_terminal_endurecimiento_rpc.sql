-- 91_tiempo_terminal_endurecimiento_rpc.sql
-- Dos endurecimientos pequeños de RPC de la terminal que pidió security como condición de salida a producción (SCJ-DEC-12):
--   1) fn_terminal_baja_por_persona_inactiva: el AUTOR de la baja automática es el del ÚLTIMO movimiento de suspensión/baja de la persona.
--      Hoy se ordena por fecha_efectiva DESC y luego creado_en DESC; pero fecha_efectiva la captura quien registra el movimiento (puede ser
--      una fecha anterior o futura) y no dice cuál fue el último acto. Ahora se ordena por creado_en DESC (cuándo se registró de verdad) y
--      fecha_efectiva sólo desempata, y al final id DESC para que el resultado sea determinista.
--   2) fn_terminal_movimiento_registrar: el detalle que manda el Pi (y que el trigger copia a terminal_usuario.error_detalle) sólo perdía
--      caracteres de control. Ahora además se QUITAN los caracteres de formato Unicode invisibles o de reordenamiento (U+00AD, U+061C,
--      U+200B-200F, U+2028-202E, U+2060-2064, U+2066-2069, U+FEFF, U+E0000-E007F), igual que en el texto de consentimiento (88_); U+2028 y
--      U+2029 se convierten antes en espacio para no pegar palabras. Un detalle que se muestra al personal de TI no debe poder esconder ni
--      reordenar texto.
--
-- Qué NO hace: no agrega un CHECK a la bitácora (los detalles web de baja_solicitada los saneó el backend; un CHECK rechazaría en vez de
-- limpiar y podría romper inserciones legítimas); no cambia firmas, permisos ni resultados de las dos funciones.
--
-- CREATE OR REPLACE FUNCTION (lección de 51_/66_/86_): ninguna de las dos funciones recibió un ALTER FUNCTION posterior a su creación en
-- 83_ (grep en db/ddl). Se repiten SECURITY DEFINER y SET search_path = tiempo, personas, pg_temp, y el REVOKE/GRANT (EXECUTE sólo
-- service_role). Verificado en la base real: ambas SECURITY DEFINER, proconfig {search_path=tiempo, personas, pg_temp}, ACL postgres y
-- service_role.
--
-- Recomendación sobre la vista/RPC de conteo de altas por estado (pregunta de backend): NO se agrega. Son 5 consultas `head` sobre una
-- tabla de decenas de filas con índice por terminal; una función ahorraría round-trips pero suma un objeto más con grants, ensayo y
-- verificador, y la ventaja de una lectura consistente es mínima para un tablero. Si el volumen o la consistencia llegaran a importar, bastaría
-- una función STABLE SECURITY INVOKER fn_terminal_altas_por_estado(p_terminal_id) que devuelva jsonb {estado: n} (la RLS de terminal_usuario
-- seguiría aplicando); no hace falta hoy.
--
-- Inventario de RLS/privilegios de este archivo: sin tablas ni policies nuevas. Las dos funciones siguen SECURITY DEFINER,
-- search_path = tiempo, personas, pg_temp, EXECUTE sólo service_role (el backend con el Pi / el hook de baja de personas).
--
-- Rollback de referencia (NO ejecutar sin revisar): volver a 83_tiempo_terminal_rpc.sql con CREATE OR REPLACE de las dos funciones (cuerpos de
-- 83_, con SECURITY DEFINER y SET search_path) y repetir REVOKE/GRANT.
--
-- Depende de: 83_tiempo_terminal_rpc.sql (versión que se reemplaza), 88_tiempo_terminal_consentimiento.sql (convención de invisibles)
-- Justificación: condiciones de salida a producción de security (SCJ-DEC-12 §5, §3)

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_estado  varchar(20);
  v_autor   uuid;
  v_n       integer := 0;
  rec       record;
BEGIN
  SELECT p.estado INTO v_estado FROM personas.persona p WHERE p.id = p_persona_id;
  IF FOUND AND v_estado = 'activo' THEN
    RETURN 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = p_persona_id AND tu.estado NOT IN ('pendiente_baja', 'baja')
  ) THEN
    RETURN 0;
  END IF;

  -- 91_: el último acto es el último REGISTRADO (creado_en); fecha_efectiva (capturada por quien registra) sólo desempata.
  SELECT b.registrado_por INTO v_autor
  FROM personas.bitacora_movimiento_persona b
  WHERE b.persona_id = p_persona_id AND b.tipo_movimiento IN ('suspension', 'baja_definitiva')
  ORDER BY b.creado_en DESC, b.fecha_efectiva DESC, b.id DESC
  LIMIT 1;
  IF v_autor IS NULL THEN
    RAISE WARNING 'fn_terminal_baja_por_persona_inactiva: sin autor derivable para la persona %', p_persona_id;
    RETURN -1;
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no
    FROM tiempo.terminal_usuario tu
    WHERE tu.persona_id = p_persona_id AND tu.estado NOT IN ('pendiente_baja', 'baja')
    ORDER BY tu.id
  LOOP
    BEGIN
      INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
        (terminal_usuario_id, terminal_id, persona_id, employee_no,
         tipo_movimiento, detalle, origen, registrado_por)
      VALUES
        (rec.id, rec.terminal_id, rec.persona_id, rec.employee_no,
         'baja_solicitada',
         left('baja automática: la persona pasó a ' || COALESCE(v_estado, 'inexistente'), 500),
         'web', v_autor);
      v_n := v_n + 1;
    EXCEPTION WHEN SQLSTATE 'SCJ11' OR SQLSTATE 'SCJ12' THEN
      NULL;  -- carrera o ya hecha: idempotente
    END;
  END LOOP;

  RETURN v_n;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(uuid) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(uuid) IS
  'SCJ-DEC-12 §5. Emite baja_solicitada de las altas de una persona NO activa (suspension, baja_definitiva '
  'o inexistente) con autor = el de su último movimiento REGISTRADO de suspension/baja_definitiva (91_: orden por '
  'creado_en DESC; fecha_efectiva sólo desempata). Devuelve el número emitido, 0 si está activa o no hay altas, '
  '-1 si no hay autor derivable. Idempotente. SECURITY DEFINER, search_path = tiempo, personas, pg_temp, '
  'EXECUTE sólo service_role (hook y job del backend).';

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_movimiento_registrar(
  p_terminal_id         bigint,
  p_terminal_usuario_id bigint,
  p_tipo                text,
  p_huellas             integer,
  p_detalle             text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_tope_error_hora  constant integer := 20;   -- valor inicial ajustable: máximo de movimientos error por alta y hora
  v_tu       tiempo.terminal_usuario;
  v_huellas  smallint;
  v_detalle  text;
  v_estado   varchar(20);
BEGIN
  SELECT tu.* INTO v_tu
  FROM tiempo.terminal_usuario tu
  WHERE tu.id = p_terminal_usuario_id AND tu.terminal_id = p_terminal_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('resultado', 'no_encontrado');
  END IF;

  IF p_tipo IS NULL OR p_tipo NOT IN ('usuario_creado', 'huella_capturada', 'baja_confirmada', 'error') THEN
    RAISE EXCEPTION 'tipo de movimiento no permitido para la terminal'
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  IF p_tipo = 'huella_capturada' THEN
    IF p_huellas IS NULL OR p_huellas NOT BETWEEN 1 AND 10 THEN
      RAISE EXCEPTION 'conteo de huellas fuera de rango'
        USING ERRCODE = '22023', HINT = 'huellas_invalidas';
    END IF;
    v_huellas := p_huellas::smallint;
  END IF;

  -- Idempotencia dentro de la función: ya aplicado = éxito, sin insertar.
  IF (p_tipo = 'usuario_creado'   AND v_tu.estado IN ('esperando_huella', 'activo'))
     OR (p_tipo = 'huella_capturada' AND v_tu.estado = 'activo' AND v_tu.huellas_capturadas = v_huellas)
     OR (p_tipo = 'baja_confirmada'  AND v_tu.estado = 'baja') THEN
    RETURN jsonb_build_object('resultado', 'ya_aplicado', 'estado', v_tu.estado);
  END IF;

  -- B4 (security): un Pi defectuoso o comprometido no debe llenar la bitácora inmutable de errores. Más de
  -- c_tope_error_hora movimientos error de esta alta en la última hora: no se inserta y se responde limitado.
  IF p_tipo = 'error' AND (
       SELECT count(*) FROM tiempo.bitacora_movimiento_terminal_usuario b
       WHERE b.terminal_usuario_id = v_tu.id AND b.tipo_movimiento = 'error'
         AND b.creado_en > now() - interval '1 hour'
     ) >= c_tope_error_hora THEN
    RETURN jsonb_build_object('resultado', 'limitado');
  END IF;

  -- Detalle (91_): U+2028/U+2029 a espacio (no pegar palabras); caracteres de formato Unicode invisibles o de reordenamiento QUITADOS;
  -- demás caracteres de control a espacio; sin espacios en los extremos; tope duro de 500 (el backend ya lo sanea; esto es defensa en
  -- profundidad). Un 'error' sin mensaje no pasa el CHECK de la bitácora: se le pone uno fijo.
  v_detalle := replace(replace(COALESCE(p_detalle, ''), chr(8232), ' '), chr(8233), ' ');
  v_detalle := regexp_replace(v_detalle, '[\u00AD\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\U000E0000-\U000E007F]', '', 'g');
  v_detalle := NULLIF(left(btrim(regexp_replace(v_detalle, '[[:cntrl:]]', ' ', 'g')), 500), '');
  IF p_tipo = 'error' AND v_detalle IS NULL THEN
    v_detalle := 'error sin detalle';
  END IF;

  INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
    (terminal_usuario_id, terminal_id, persona_id, employee_no,
     tipo_movimiento, huellas_capturadas, detalle, origen, registrado_por)
  VALUES
    (v_tu.id, v_tu.terminal_id, v_tu.persona_id, v_tu.employee_no,
     p_tipo, v_huellas, v_detalle, 'terminal', NULL);

  SELECT tu.estado INTO v_estado FROM tiempo.terminal_usuario tu WHERE tu.id = v_tu.id;
  RETURN jsonb_build_object('resultado', 'registrado', 'estado', v_estado);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_movimiento_registrar(bigint, bigint, text, integer, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_movimiento_registrar(bigint, bigint, text, integer, text)
  TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_movimiento_registrar(bigint, bigint, text, integer, text) IS
  'SCJ-DEC-12 §3. Movimiento del Pi (usuario_creado, huella_capturada, baja_confirmada, error) sobre una '
  'alta de la terminal p_terminal_id. FOR UPDATE de la alta; no_encontrado si no existe o es de otra '
  'terminal; ya_aplicado si el estado ya es el destino. Fija origen=terminal y registrado_por=NULL. '
  'Más de 20 errores de la alta en 1 h: limitado (sin insertar). El detalle se sanea (91_): sin caracteres de control ni de '
  'formato Unicode invisibles o de reordenamiento. '
  'La transición la valida el trigger de 81_*.sql (SCJ11/SCJ12).';
