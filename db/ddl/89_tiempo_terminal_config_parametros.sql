-- 89_tiempo_terminal_config_parametros.sql
-- Variables numéricas del módulo de terminales editables desde el sistema (decisión del usuario, 2026-10-08), con el
-- permiso terminal_config_edicion de 88_ (sólo "Gerente o Encargado de TI" y "Gerente General"; RH NO, aunque tenga
-- parametro_edicion). Van como claves nuevas de tiempo.parametro (versionadas por vigencia) y se editan con un RPC propio.
--
-- Claves (valor inicial; rango editable, decidido por el usuario):
--   terminal_caducidad_alta_horas        24    4..168   horas tras 'usuario_creado' para dar de baja una alta sin huella
--   terminal_llave_max_meses             12    3..36    antigüedad máxima de una llave de la terminal (tablero de anomalías)
--   terminal_traslape_llave_max_dias      7    1..90    días máximos con dos llaves vigentes (tablero)
--   terminal_anomalias_ventana_dias       7    1..90    ventana por omisión del tablero de anomalías
--   terminal_retencion_rechazos_dias     90    30..365  retención de tiempo.marca_rechazada
-- FIJOS a propósito (rieles de seguridad: subirlos debilita defensas, bajarlos rompe invariantes): tope de bajas por corrida
-- (50), tope de filas de rechazos (5 000/día), alarma y tope de marcas por hora de la terminal (1 000/5 000), tope de lote (200),
-- salto de secuencia, tolerancias de reloj y el pico de marcas por persona (10/h), que el RPC y el tablero deben compartir.
--
-- Qué hace:
--   1) Siembra las 5 claves en tiempo.parametro (vigente_desde = 2026-01-01, como las demás; idempotente).
--      Regla cruzada: terminal_traslape_llave_max_dias * 2 <= terminal_llave_max_meses * 30 (el traslape no pasa de la mitad de la
--      antigüedad máxima en días), validada en ambos sentidos contra el valor vigente de la otra clave.
--   2) tiempo.fn_terminal_config_catalogo(): valor por defecto y rango de cada clave (una sola fuente para el RPC y el lector).
--   3) tiempo.fn_terminal_config_actualizar(p_clave, p_valor): SECURITY DEFINER, gate DENTRO (persona activa y
--      terminal_config_edicion), lista blanca de las 5 claves con su rango, autor de auth.uid(), mismo versionado que
--      fn_parametro_actualizar_valor (borde inclusivo: vigente_hasta = hoy - 1; un segundo cambio el mismo día corrige la
--      vigencia en sitio). EXECUTE sólo authenticated: el backend la llama con el cliente del caller.
--   4) tiempo.fn_terminal_config_valor(p_clave): lector tolerante para los jobs del backend (service_role): valor vigente, acotado
--      al rango; si falta o está mal formado devuelve el valor por defecto. Un parámetro corrupto jamás debe tumbar un job.
--   5) Guard en fn_parametro_actualizar_valor: las claves terminal_% sólo se editan con el RPC de arriba (SCJ17 /
--      clave_reservada). Sin esto, RH (que tiene parametro_edicion) podría editarlas por la pantalla genérica de Parámetros.
--
-- Consumo (SIN cambiar funciones SQL): el job del backend lee terminal_caducidad_alta_horas con fn_terminal_config_valor y se la
-- pasa como p_horas a fn_terminal_baja_por_caducidad (piso 4 h y tope 50 siguen dentro de esa función); fn_marca_rechazada_purgar
-- recibe terminal_retencion_rechazos_dias como p_dias (piso 7 días dentro); el tablero lee las otras tres. La caducidad editable
-- aplica también a las altas ya en curso: la función evalúa contra el movimiento 'usuario_creado' en cada corrida.
-- Backend: excluir el grupo 'terminal' del catálogo y del listado de la pantalla genérica de Parámetros.
--
-- ERRCODE nuevo 'SCJ17' (verificado libre por grep en db/, backend/app y frontend/src; el último usado era SCJ16 de 88_):
--   clave_reservada      fn_parametro_actualizar_valor con una clave terminal_% (backend: 403/409; la pantalla genérica no debe ofrecerla)
-- Otros errores (códigos estándar, el backend los distingue por HINT):
--   42501 sin_permiso        fn_terminal_config_actualizar sin persona activa o sin terminal_config_edicion (backend: 403)
--   22023 clave_no_editable  clave fuera de la lista blanca (backend: 422)
--   22023 valor_invalido     valor no entero, fuera de rango, o que rompe la regla traslape*2 <= antigüedad_meses*30 entre las dos
--                            claves de llave (backend: 422, con el rango y la regla en el mensaje de la interfaz)
--   SCJ02                    la clave no tiene vigencia activa (seed ausente; backend: 404, igual que parámetros)
--
-- Decisiones de diseño:
--   - tiempo.parametro y no una tabla propia: reusa versionado, registrado_por y la pantalla de historial. Una tabla tipada con
--     CHECK de rangos y valores por terminal sólo valdría si aparece la necesidad de valores distintos por terminal (hoy hay una).
--   - El RPC no llama a fn_parametro_actualizar_valor (INVOKER, sólo service_role): replica su versionado para no cambiar su contrato.
--   - Aviso conocido de tiempo.parametro: dos cambios el mismo día son un UPDATE en sitio (se pierde el valor intermedio) y "hoy"
--     es CURRENT_DATE en UTC (gotcha de CLAUDE.md). Aceptable para estas 5 variables.
--   - Riesgos de producto: bajar terminal_caducidad_alta_horas (p. ej. de 24 a 4) hace que la PRÓXIMA corrida dé de baja las altas en
--     esperando_huella de entre 4 y 24 h (hasta 50 por corrida); la baja es reversible sólo reasignando (consume otro employee_no).
--     La interfaz debe mostrar cuántas altas caerían antes de confirmar. Bajar la retención borra evidencia de rechazos de forma
--     irreversible en la siguiente purga (el piso absoluto de 7 días vive en fn_marca_rechazada_purgar).
--
-- Inventario de RLS/privilegios de este archivo:
--   tiempo.parametro  sin cambios (RLS sin policies = deny-all; lo accede el backend con service_role o estas funciones).
--   fn_terminal_config_actualizar  SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE sólo authenticated.
--   fn_terminal_config_valor       SECURITY DEFINER, search_path = tiempo, pg_temp; EXECUTE sólo service_role.
--   fn_terminal_config_catalogo    SQL IMMUTABLE, search_path = pg_temp; EXECUTE authenticated y service_role (datos no sensibles).
--   fn_parametro_actualizar_valor  CREATE OR REPLACE con el guard; mismos atributos que antes (SECURITY INVOKER, sin SET, EXECUTE sólo
--                                  service_role); se repiten GRANT/REVOKE para no depender de lo heredado.
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP FUNCTION tiempo.fn_terminal_config_actualizar(text, text);
--   DROP FUNCTION tiempo.fn_terminal_config_valor(text);
--   DROP FUNCTION tiempo.fn_terminal_config_catalogo();
--   -- restaurar fn_parametro_actualizar_valor sin el guard (cuerpo de 60_*.sql);
--   DELETE FROM tiempo.parametro WHERE clave LIKE 'terminal\_%';   -- sólo si ninguna clave se ha editado y con OK del usuario
--
-- Depende de: 60_tiempo_parametro_vigencia_y_autor.sql (parametro.vigente_hasta/registrado_por y fn_parametro_actualizar_valor),
--   88_tiempo_terminal_consentimiento.sql (permiso terminal_config_edicion)
-- Justificación: decisión del usuario (2026-10-08), SCJ-DEC-12 §6 y §12.7, SCJ-PRO-15

-- ============================================================================
-- 1) Siembra de las 5 claves (idempotente).
-- ============================================================================

INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
SELECT v.clave, v.valor, DATE '2026-01-01', NULL, NULL
FROM (VALUES
  ('terminal_caducidad_alta_horas',     '24'),
  ('terminal_llave_max_meses',          '12'),
  ('terminal_traslape_llave_max_dias',  '7'),
  ('terminal_anomalias_ventana_dias',   '7'),
  ('terminal_retencion_rechazos_dias',  '90')
) AS v(clave, valor)
WHERE NOT EXISTS (SELECT 1 FROM tiempo.parametro p WHERE p.clave = v.clave);

-- ============================================================================
-- 2) Catálogo: valor por defecto y rango de cada clave (única fuente).
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_config_catalogo()
RETURNS TABLE (clave text, valor_defecto integer, minimo integer, maximo integer)
LANGUAGE sql
IMMUTABLE
SET search_path = pg_temp
AS $$
  SELECT * FROM (VALUES
    ('terminal_caducidad_alta_horas'::text,     24,   4, 168),
    ('terminal_llave_max_meses'::text,          12,   3,  36),
    ('terminal_traslape_llave_max_dias'::text,   7,   1,  90),
    ('terminal_anomalias_ventana_dias'::text,    7,   1,  90),
    ('terminal_retencion_rechazos_dias'::text,  90,  30, 365)
  ) AS c(clave, valor_defecto, minimo, maximo);
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_config_catalogo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_catalogo() TO authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_config_catalogo() IS
  '89_. Valor por defecto y rango (mínimo, máximo) de las 5 claves terminal_* de tiempo.parametro. Única fuente para '
  'fn_terminal_config_actualizar y fn_terminal_config_valor; datos no sensibles.';

-- ============================================================================
-- 3) Editar una clave (gate dentro, lista blanca, versionado por vigencia).
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_actor        uuid;
  v_cat          record;
  v_valor        integer;
  v_texto        text;
  v_hoy          date := CURRENT_DATE;
  v_activa_id    bigint;
  v_activa_desde date;
  v_activa_valor text;
  v_fila         tiempo.parametro;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_config_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para editar la configuración de terminales'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  SELECT * INTO v_cat FROM tiempo.fn_terminal_config_catalogo() c WHERE c.clave = p_clave;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La clave % no es editable desde la configuración de terminales', p_clave
      USING ERRCODE = '22023', HINT = 'clave_no_editable';
  END IF;

  IF p_valor IS NULL OR btrim(p_valor) !~ '^[0-9]{1,4}$' THEN
    RAISE EXCEPTION 'El valor debe ser un entero entre % y %', v_cat.minimo, v_cat.maximo
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  v_valor := btrim(p_valor)::integer;
  IF v_valor < v_cat.minimo OR v_valor > v_cat.maximo THEN
    RAISE EXCEPTION 'El valor debe estar entre % y %', v_cat.minimo, v_cat.maximo
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  v_texto := v_valor::text;

  -- Las dos claves de llave se validan entre sí: un lock de transacción fijo evita el write-skew (dos ediciones simultáneas, cada una
  -- válida contra el valor VIEJO de la otra, que juntas romperían la regla). Se toma antes de leer el valor de la otra clave.
  IF p_clave IN ('terminal_traslape_llave_max_dias', 'terminal_llave_max_meses') THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('tiempo.terminal_config_llave', 0));
  END IF;

  -- Consistencia entre las dos claves de llave (petición de frontend, aceptada): el traslape máximo no puede superar la mitad de la
  -- antigüedad máxima expresada en días (meses * 30). Simétrico: se valida al editar cualquiera de las dos contra el valor VIGENTE de
  -- la otra (para subir el traslape por encima del límite actual hay que subir primero la antigüedad, y al revés al bajarla).
  IF p_clave = 'terminal_traslape_llave_max_dias'
     AND v_valor * 2 > tiempo.fn_terminal_config_valor('terminal_llave_max_meses') * 30 THEN
    RAISE EXCEPTION 'El traslape de llaves no puede superar la mitad de la antigüedad máxima de la llave'
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  IF p_clave = 'terminal_llave_max_meses'
     AND tiempo.fn_terminal_config_valor('terminal_traslape_llave_max_dias') * 2 > v_valor * 30 THEN
    RAISE EXCEPTION 'La antigüedad máxima de la llave no puede ser menor al doble del traslape máximo de llaves'
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;

  -- tiempo.parametro.registrado_por referencia personas.usuario(auth_user_id) (60_): el autor es el auth_user_id, no la persona.
  v_actor := auth.uid();

  SELECT p.id, p.vigente_desde, p.valor INTO v_activa_id, v_activa_desde, v_activa_valor
  FROM tiempo.parametro p
  WHERE p.clave = p_clave AND p.vigente_hasta IS NULL
  FOR UPDATE;

  IF v_activa_id IS NULL THEN
    RAISE EXCEPTION 'No existe un parámetro activo con clave %', p_clave
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_activa_valor = v_texto THEN
    RETURN jsonb_build_object('resultado', 'sin_cambio', 'clave', p_clave, 'valor', v_texto,
                              'vigente_desde', v_activa_desde);
  END IF;

  IF v_activa_desde = v_hoy THEN
    -- Segundo cambio del mismo día: es la misma vigencia corregida, no una vigencia nueva.
    UPDATE tiempo.parametro SET valor = v_texto, registrado_por = v_actor
    WHERE id = v_activa_id
    RETURNING * INTO v_fila;
  ELSE
    UPDATE tiempo.parametro SET vigente_hasta = v_hoy - 1 WHERE id = v_activa_id;
    INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
    VALUES (p_clave, v_texto, v_hoy, NULL, v_actor)
    RETURNING * INTO v_fila;
  END IF;

  RETURN jsonb_build_object('resultado', 'actualizada', 'clave', v_fila.clave, 'valor', v_fila.valor,
                            'vigente_desde', v_fila.vigente_desde);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) IS
  '89_. Edita una de las 5 claves terminal_* de tiempo.parametro: exige persona activa y terminal_config_edicion DENTRO (42501/'
  'sin_permiso), clave en la lista blanca (22023/clave_no_editable) y entero dentro de su rango (22023/valor_invalido), deriva '
  'el autor de auth.uid() y versiona por vigencia (borde inclusivo; el mismo día corrige en sitio). Devuelve {resultado: '
  'actualizada | sin_cambio, clave, valor, vigente_desde}. SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE '
  'sólo authenticated.';

-- ============================================================================
-- 4) Lector tolerante para los jobs del backend (service_role).
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_config_valor(p_clave text)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
  SELECT CASE
           WHEN c.clave IS NULL THEN NULL
           ELSE LEAST(GREATEST(COALESCE(v.valor_num, c.valor_defecto), c.minimo), c.maximo)
         END
  FROM (SELECT p_clave AS clave) AS q
  LEFT JOIN tiempo.fn_terminal_config_catalogo() c ON c.clave = q.clave
  LEFT JOIN LATERAL (
    SELECT CASE WHEN p.valor ~ '^[0-9]{1,6}$' THEN p.valor::integer END AS valor_num
    FROM tiempo.parametro p
    WHERE p.clave = q.clave
      AND p.vigente_desde <= CURRENT_DATE
      AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= CURRENT_DATE)
    ORDER BY p.vigente_desde DESC
    LIMIT 1
  ) v ON true;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_config_valor(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_valor(text) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_config_valor(text) IS
  '89_. Valor vigente de una clave terminal_* para los jobs del backend: acotado a su rango; si falta o está mal formado devuelve '
  'el valor por defecto; NULL si la clave no es del catálogo. Nunca falla por un parámetro corrupto. SECURITY DEFINER, '
  'search_path = tiempo, pg_temp; EXECUTE sólo service_role.';

-- ============================================================================
-- 5) Guard en fn_parametro_actualizar_valor: las claves terminal_% sólo se editan con fn_terminal_config_actualizar.
--    Atributos idénticos a los vivos (SECURITY INVOKER, sin SET, plpgsql): ningún ALTER FUNCTION posterior a 60_ la cambió
--    (grep en db/ddl); se repiten GRANT/REVOKE para no depender de lo heredado.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_parametro_actualizar_valor(
  p_clave           varchar,
  p_valor           text,
  p_registrado_por  uuid
) RETURNS tiempo.parametro AS $$
DECLARE
  v_hoy          date := CURRENT_DATE;
  v_activa_id    bigint;
  v_activa_desde date;
  v_fila         tiempo.parametro;
BEGIN
  -- 89_: las claves de terminales se editan con su propio permiso (terminal_config_edicion), no con parametro_edicion.
  IF p_clave LIKE 'terminal\_%' THEN
    RAISE EXCEPTION 'La clave % sólo se edita desde la configuración de terminales', p_clave
      USING ERRCODE = 'SCJ17', HINT = 'clave_reservada';
  END IF;

  -- La clave debe existir ya: esta pantalla edita valores, no crea parámetros.
  SELECT id, vigente_desde INTO v_activa_id, v_activa_desde
  FROM tiempo.parametro
  WHERE clave = p_clave AND vigente_hasta IS NULL;

  IF v_activa_id IS NULL THEN
    RAISE EXCEPTION 'No existe un parámetro activo con clave %', p_clave
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_activa_desde = v_hoy THEN
    -- Segundo cambio del mismo día: es la misma vigencia corregida, no una vigencia nueva.
    UPDATE tiempo.parametro
    SET valor = p_valor, registrado_por = p_registrado_por
    WHERE id = v_activa_id
    RETURNING * INTO v_fila;
    RETURN v_fila;
  END IF;

  UPDATE tiempo.parametro
  SET vigente_hasta = v_hoy - 1
  WHERE id = v_activa_id;

  INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
  VALUES (p_clave, p_valor, v_hoy, NULL, p_registrado_por)
  RETURNING * INTO v_fila;

  RETURN v_fila;
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid) TO service_role;

COMMENT ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid) IS
  'RPC transaccional de "actualizar valor de parámetro": si no hay vigencia activa con esa clave, '
  'señaliza con RAISE EXCEPTION ... USING ERRCODE = ''SCJ02'' (backend lo mapea a 404). Si la '
  'vigencia activa es de hoy, corrige valor/registrado_por in-place (mismo día = misma vigencia). '
  'Si no, cierra la vigencia activa (vigente_hasta = hoy - 1) e inserta la vigencia nueva desde '
  'hoy, en una sola transacción. 89_: rechaza con SCJ17 / clave_reservada las claves terminal_%, que sólo '
  'se editan con fn_terminal_config_actualizar (permiso terminal_config_edicion).';
