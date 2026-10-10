-- 99_tiempo_terminal_ingesta_detenida.sql
-- Campo opcional del latido (M1 de security): el puente avisa cuando un lazo de ingesta queda DETENIDO esperando a una persona (por ejemplo, tras un 403 o una
-- redirección que exige reanudar a mano), para que la tarjeta 15 del tablero de anomalías alarme. Diseño de backend: tiempo.terminal.ingesta_detenida boolean NULL.
--   NULL  = el puente NO lo reporta en su último latido (versiones anteriores del puente, o no aplica);
--   true  = algún lazo de ingesta está detenido esperando a una persona;
--   false = el puente lo reporta y todo corre.
-- La escribe SOLO fn_terminal_latido (SECURITY DEFINER), como las demás columnas de telemetría de 82_: no se concede UPDATE de la columna a nadie. Describe el ÚLTIMO latido
-- (cada latido la sobrescribe, también con NULL si el puente deja de reportarla).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 99_*.sql` (el archivo NO lleva BEGIN/COMMIT). Depende de 80_/82_/83_.
--
-- Qué hace (todo en una sola transacción):
--   1) ALTER TABLE tiempo.terminal ADD COLUMN ingesta_detenida boolean (NULL por omisión; sin CHECK: es un booleano de telemetría).
--   2) DROP de la firma VIEJA de fn_terminal_latido (6 argumentos) y CREATE de la nueva con un 7.º argumento p_ingesta_detenida boolean DEFAULT NULL. Un CREATE OR REPLACE con
--      otra lista de argumentos crearía un SEGUNDO overload y la llamada por nombre del backend (6 argumentos) quedaría AMBIGUA (42725); por eso se suelta la vieja en la
--      misma transacción y se repiten REVOKE/GRANT exactos (DROP FUNCTION descarta la ACL). Compatible hacia atrás: sin el argumento nuevo la llamada del backend actual
--      sigue funcionando y la columna queda NULL.
--   3) Cuerpo = definición vigente de 83_ (diff literal en db/ensayos/diff_99_latido.diff) + la columna nueva; el RAISE EXCEPTION que interpolaba terminal_id pasa a mensaje
--      fijo con el mismo HINT estable (terminal_no_valida).
--
-- Inventario de RLS/privilegios de este archivo (regla de CLAUDE.md):
--   tiempo.terminal            RLS y policy terminal_select_lectura SIN cambios. Privilegios de tabla sin cambios: SELECT para authenticated y service_role, INSERT para service_role,
--                              UPDATE solo de (ultimo_contacto_en, activa, nombre, modelo) para service_role; anon NADA. La columna nueva hereda SELECT de tabla (authenticated y service_role la
--                              leen; authenticated solo las filas que su policy permite) y NO tiene UPDATE para nadie fuera del dueño y fn_terminal_latido. Se repite REVOKE INSERT/UPDATE
--                              de columna a anon/authenticated/service_role (sin efecto sobre el INSERT de tabla de service_role, que ya existía: solo el alta puntual de una terminal).
--   fn_terminal_latido(...)    SECURITY DEFINER, SET search_path = tiempo, personas, pg_temp, REVOKE EXECUTE FROM PUBLIC, anon, authenticated; GRANT EXECUTE solo a service_role
--                              (repetidos tras el DROP; el backend la llama con service_role).
--
-- REVERSA (sin pérdida de datos relevantes; la columna es telemetría): DROP FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer, boolean);
-- ALTER TABLE tiempo.terminal DROP COLUMN ingesta_detenida; y volver a crear la función con el cuerpo de 83_ (db/ensayos/vigente_99_latido_83.sql, cambiando CREATE FUNCTION tal cual) repitiendo
-- SECURITY DEFINER, SET search_path = tiempo, personas, pg_temp y el REVOKE/GRANT del final de este archivo con la firma de 6 argumentos. Hacerlo en una sola transacción.

-- ============================================================================
-- 1) Columna
-- ============================================================================

ALTER TABLE tiempo.terminal ADD COLUMN ingesta_detenida boolean;

COMMENT ON COLUMN tiempo.terminal.ingesta_detenida IS
  '99_. Telemetría del último latido: true = algún lazo de ingesta del puente quedó DETENIDO esperando a una persona (p. ej. tras un 403 o una redirección); false = el puente lo '
  'reporta y todo corre; NULL = el puente no lo reportó en ese latido. La escribe solo fn_terminal_latido (SECURITY DEFINER); nadie tiene UPDATE de esta columna.';

REVOKE INSERT (ingesta_detenida), UPDATE (ingesta_detenida) ON tiempo.terminal FROM anon, authenticated, service_role;

-- ============================================================================
-- 2) fn_terminal_latido con el argumento nuevo (DROP de la firma vieja + CREATE; sin overload ambiguo)
-- ============================================================================

DROP FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer);

CREATE FUNCTION tiempo.fn_terminal_latido(
  p_terminal_id         bigint,
  p_hora_terminal       timestamptz,
  p_alcanzable          boolean,
  p_reloj_sincronizado  boolean,
  p_version_pi          text,
  p_marcas_pendientes   integer,
  p_ingesta_detenida    boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_serie     varchar(32);
  v_activa    boolean;
  v_ahora     timestamptz := clock_timestamp();
  v_desfase   integer;
  v_max_seq   bigint;
BEGIN
  SELECT t.terminal_id, t.activa INTO v_serie, v_activa
  FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND OR NOT v_activa THEN
    RAISE EXCEPTION 'La terminal no existe o no está activa'
      USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
  END IF;

  -- B8 (security): infinity/-infinity o una hora fuera de rango no deben romper el latido: el desfase queda NULL.
  IF p_hora_terminal IS NOT NULL AND isfinite(p_hora_terminal) THEN
    BEGIN
      v_desfase := LEAST(GREATEST(round(extract(epoch FROM (p_hora_terminal - v_ahora))),
                                  -2147483648), 2147483647)::integer;
    EXCEPTION WHEN data_exception THEN
      v_desfase := NULL;
    END;
  END IF;

  UPDATE tiempo.terminal t
  SET reloj_desfase_seg   = v_desfase,
      terminal_alcanzable = p_alcanzable,
      version_pi          = NULLIF(left(btrim(regexp_replace(COALESCE(p_version_pi, ''), '[[:cntrl:]]', '', 'g')), 16), ''),
      marcas_pendientes   = CASE WHEN p_marcas_pendientes IS NULL THEN NULL
                                 ELSE GREATEST(p_marcas_pendientes, 0) END,
      -- 99_: NULL = el puente no lo reportó en ESTE latido (el campo describe el último latido); true = algún lazo de ingesta quedó DETENIDO esperando a una persona.
      ingesta_detenida    = p_ingesta_detenida,
      ultimo_contacto_en  = v_ahora
  WHERE t.id = p_terminal_id;

  SELECT COALESCE(max(m.secuencia_local), 0) INTO v_max_seq
  FROM tiempo.marca m WHERE m.terminal_id = v_serie AND m.origen = 'terminal';

  RETURN jsonb_build_object(
    'hora_servidor',             v_ahora,
    'desfase_reloj_seg',         v_desfase,
    'ultima_secuencia_recibida', v_max_seq
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer, boolean)
  TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer, boolean) IS
  'SCJ-DEC-12 §3. Guarda terminal_alcanzable, reloj_desfase_seg (terminal menos servidor), version_pi, marcas_pendientes e (99_) ingesta_detenida en tiempo.terminal y devuelve '
  '{hora_servidor, desfase_reloj_seg, ultima_secuencia_recibida}. p_reloj_sincronizado se recibe pero no se persiste. p_ingesta_detenida es opcional (DEFAULT NULL = el puente no lo '
  'reporta); cada latido sobrescribe la columna. SCJ12 (mensaje fijo, HINT terminal_no_valida) si la terminal no existe o no está activa. SECURITY DEFINER, '
  'search_path = tiempo, personas, pg_temp, EXECUTE solo service_role. Al reescribirla repetir SECURITY DEFINER y SET search_path, y si cambia la firma, soltar la vieja en la misma '
  'transacción (un overload deja la llamada por nombre ambigua).';
