-- 90_tiempo_terminal_anomalias.sql
-- Tablero de anomalías de marcas de una terminal (SCJ-DEC-12 §6, contrato del Paquete 2 §9): las tres categorías que son AGREGACIONES
-- sobre tiempo.marca se calculan en SQL (evita los truncamientos de max-rows de PostgREST, el N+1 y agregar en Python):
--   marcas_posteriores_a_baja   (1)  marcas de una persona en la terminal posteriores al baja_confirmada de su alta
--   picos_de_tasa               (2)  persona con > 10 marcas en una hora y terminal con > 1 000 marcas en una hora (los umbrales del RPC)
--   huecos_de_secuencia         (4)  saltos en secuencia_local de la terminal
-- El resto de las categorías (reloj degradado, rechazos, credenciales, inconsistencias de baja, altas atascadas, altas recientes y
-- reconsentimientos pendientes) las arma el backend con consultas simples.
--
-- Qué crea (sin tablas, columnas, índices, policies ni permisos nuevos):
--   tiempo.fn_terminal_anomalias(p_terminal_id, p_categoria, p_desde, p_hasta, p_limite, p_desplazamiento) RETURNS jsonb
--   Devuelve {total, items:[...]} de UNA categoría, con paginación (p_limite 1..200, por omisión 3 = los ejemplos de la tarjeta).
--
-- Decisiones:
--   - SECURITY INVOKER, STABLE, de sólo lectura, EXECUTE sólo service_role. No es DEFINER: no necesita más privilegios que los del
--     llamador, y el único llamador previsto es el backend con service_role (que no pasa por RLS) DESPUÉS de su propio gate
--     (terminal_usuario_lectura o terminal_usuario_edicion). Un usuario de la API (authenticated) NO puede ejecutarla: ver marcas de
--     otras personas exige marca_lectura, y el gate del tablero es otro; el backend es quien expone el subconjunto.
--   - Filtra SIEMPRE por la terminal pedida DENTRO (serie de tiempo.terminal), nunca acepta una serie del cliente; una terminal
--     inexistente da 22023 / terminal_invalida.
--   - Devuelve persona_id (uuid) y NO nombres: ningún atributo de identidad vive en tiempo (SCJ-FRO-01); el backend resuelve los nombres
--     y nunca los ids hacia el cliente.
--   - Ventana: p_desde y p_hasta obligatorios, p_hasta >= p_desde y a lo más 90 días (22023 / ventana_invalida). Los filtros usan
--     momento_dispositivo (picos, marcas tras la baja) y momento_recepcion (huecos).
--   - Los umbrales 10 y 1 000 por hora son los de fn_marca_terminal_registrar (83_) y están FIJOS (decisión del usuario 2026-10-08): el RPC
--     y el tablero deben compartir el mismo número.
--   - BACKLOG (B5 de security): índice por (terminal_id, momento_dispositivo) en tiempo.marca, en un corte aparte, cuando el volumen lo pida.
--   - Costo: tiempo.marca no tiene índice por (terminal_id, momento_dispositivo); con una terminal y el volumen actual basta. Si el
--     volumen crece, el índice parcial uq_marca_terminal_secuencia (terminal_id, secuencia_local) ya sirve a los huecos y se puede
--     agregar un índice por (terminal_id, momento_dispositivo) en un corte aparte.
--   - Marcas tras la baja: se excluyen las marcas posteriores a la creación de una alta NUEVA de la misma persona en la misma terminal
--     (re-asignación legítima después de una baja).
--
-- Inventario de RLS/privilegios de este archivo:
--   fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer)
--        SECURITY INVOKER, STABLE, SET search_path = tiempo, pg_temp. REVOKE EXECUTE FROM PUBLIC, anon, authenticated;
--        GRANT EXECUTE sólo a service_role. Sin tablas ni grants de tabla nuevos.
--
-- Errores (22023, HINT estable; el backend los traduce a 422): terminal_invalida, categoria_invalida, ventana_invalida, paginacion_invalida.
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer);
--
-- Depende de: 02_tiempo.sql (tiempo.marca), 80_/81_ (terminal_usuario y su bitácora), 82_ (tiempo.terminal), 88_ (usuario_creado_en)
-- Justificación: SCJ-DEC-12 §6 (tablero de anomalías), contrato del Paquete 2 §9

CREATE FUNCTION tiempo.fn_terminal_anomalias(
  p_terminal_id      bigint,
  p_categoria        text,
  p_desde            timestamptz,
  p_hasta            timestamptz,
  p_limite           integer DEFAULT 3,
  p_desplazamiento   integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  c_pico_persona_hora  constant integer := 10;     -- igual que c_tope_persona_hora de fn_marca_terminal_registrar (83_)
  c_pico_terminal_hora constant integer := 1000;   -- igual que c_alarma_terminal_hora de fn_marca_terminal_registrar (83_)
  c_ventana_max        constant interval := interval '90 days';
  v_serie   varchar;
  v_res     jsonb;
BEGIN
  SELECT t.terminal_id INTO v_serie FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La terminal % no existe', p_terminal_id USING ERRCODE = '22023', HINT = 'terminal_invalida';
  END IF;

  IF p_categoria IS NULL OR p_categoria NOT IN ('marcas_posteriores_a_baja', 'picos_de_tasa', 'huecos_de_secuencia') THEN
    RAISE EXCEPTION 'Categoría desconocida: %', p_categoria USING ERRCODE = '22023', HINT = 'categoria_invalida';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde OR p_hasta - p_desde > c_ventana_max THEN
    RAISE EXCEPTION 'La ventana debe tener desde y hasta, hasta >= desde, y a lo más 90 días'
      USING ERRCODE = '22023', HINT = 'ventana_invalida';
  END IF;

  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 200 OR p_desplazamiento IS NULL OR p_desplazamiento < 0 THEN
    RAISE EXCEPTION 'p_limite debe estar entre 1 y 200 y p_desplazamiento no puede ser negativo'
      USING ERRCODE = '22023', HINT = 'paginacion_invalida';
  END IF;

  IF p_categoria = 'marcas_posteriores_a_baja' THEN
    WITH base AS (
      SELECT m.persona_id, m.id AS marca_id, m.momento_dispositivo AS marca_en, b.creado_en AS baja_confirmada_en
      FROM tiempo.terminal_usuario tu
      JOIN tiempo.bitacora_movimiento_terminal_usuario b
        ON b.terminal_usuario_id = tu.id AND b.tipo_movimiento = 'baja_confirmada'
      JOIN tiempo.marca m
        ON m.persona_id = tu.persona_id AND m.terminal_id = v_serie AND m.origen = 'terminal'
       AND m.momento_dispositivo > b.creado_en
      WHERE tu.terminal_id = p_terminal_id
        AND m.momento_dispositivo >= p_desde AND m.momento_dispositivo <= p_hasta
        -- una alta NUEVA de la misma persona ya creada en el aparato cuando ocurrió la marca la hace legítima
        AND NOT EXISTS (
          SELECT 1 FROM tiempo.terminal_usuario tu2
          WHERE tu2.terminal_id = tu.terminal_id AND tu2.persona_id = tu.persona_id AND tu2.id > tu.id
            AND tu2.usuario_creado_en IS NOT NULL AND tu2.usuario_creado_en <= m.momento_dispositivo
        )
    ), pag AS (
      SELECT * FROM base ORDER BY marca_en DESC, marca_id DESC LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.marca_en DESC, pag.marca_id DESC) FROM pag), '[]'::jsonb))
    INTO v_res;

  ELSIF p_categoria = 'picos_de_tasa' THEN
    WITH por_persona AS (
      SELECT m.persona_id, date_trunc('hour', m.momento_dispositivo) AS hora, count(*)::integer AS marcas, c_pico_persona_hora AS limite
      FROM tiempo.marca m
      WHERE m.terminal_id = v_serie AND m.origen = 'terminal'
        AND m.momento_dispositivo >= p_desde AND m.momento_dispositivo <= p_hasta
      GROUP BY m.persona_id, date_trunc('hour', m.momento_dispositivo)
      HAVING count(*) > c_pico_persona_hora
    ), por_terminal AS (
      SELECT NULL::uuid AS persona_id, date_trunc('hour', m.momento_dispositivo) AS hora, count(*)::integer AS marcas, c_pico_terminal_hora AS limite
      FROM tiempo.marca m
      WHERE m.terminal_id = v_serie AND m.origen = 'terminal'
        AND m.momento_dispositivo >= p_desde AND m.momento_dispositivo <= p_hasta
      GROUP BY date_trunc('hour', m.momento_dispositivo)
      HAVING count(*) > c_pico_terminal_hora
    ), base AS (
      SELECT * FROM por_persona UNION ALL SELECT * FROM por_terminal
    ), pag AS (
      SELECT * FROM base ORDER BY hora DESC, marcas DESC, persona_id NULLS LAST LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.hora DESC, pag.marcas DESC, pag.persona_id NULLS LAST) FROM pag), '[]'::jsonb))
    INTO v_res;

  ELSE  -- huecos_de_secuencia
    WITH orden AS (
      SELECT m.secuencia_local, m.momento_recepcion,
             lag(m.secuencia_local) OVER (ORDER BY m.secuencia_local) AS anterior
      FROM tiempo.marca m
      WHERE m.terminal_id = v_serie AND m.origen = 'terminal'
    ), base AS (
      SELECT o.anterior + 1 AS desde, o.secuencia_local - 1 AS hasta,
             (o.secuencia_local - o.anterior - 1) AS faltan, o.momento_recepcion AS fecha
      FROM orden o
      WHERE o.anterior IS NOT NULL AND o.secuencia_local - o.anterior > 1
        AND o.momento_recepcion >= p_desde AND o.momento_recepcion <= p_hasta
    ), pag AS (
      SELECT * FROM base ORDER BY desde DESC LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.desde DESC) FROM pag), '[]'::jsonb))
    INTO v_res;
  END IF;

  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer) IS
  '90_. Una categoría del tablero de anomalías de una terminal (marcas_posteriores_a_baja | picos_de_tasa | huecos_de_secuencia) '
  'como {total, items} paginado (p_limite 1..200, p_desplazamiento >= 0). Filtra SIEMPRE por la terminal pedida dentro; devuelve '
  'persona_id, nunca nombres (SCJ-FRO-01). Ventana de a lo más 90 días. Umbrales fijos: 10 marcas/h por persona, 1 000/h por '
  'terminal. SECURITY INVOKER, STABLE, search_path = tiempo, pg_temp; EXECUTE sólo service_role (el backend aplica el gate de '
  'lectura antes). 22023 con HINT: terminal_invalida, categoria_invalida, ventana_invalida, paginacion_invalida.';
