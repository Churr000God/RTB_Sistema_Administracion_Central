-- 83_tiempo_terminal_rpc.sql
-- Segunda pieza de SCJ-DEC-12: las FUNCIONES. Seis RPC SECURITY DEFINER para el puente de la
-- terminal (el Pi nunca toca la base: el backend llama estas funciones con service_role), una
-- función auxiliar interna, el trigger SCJ13 de desactivación y el CREATE OR REPLACE de
-- fn_bitacora_terminal_usuario_aplica (81_*.sql) para cerrar la carrera de desactivación.
--
--   fn_terminal_autenticar(text, text)                    autentica una llave (hash) y registra el uso
--   fn_terminal_mapa(bigint)                              altas no-baja de UNA terminal, sin persona_id
--   fn_terminal_movimiento_registrar(bigint, bigint, ...) movimientos del Pi sobre una alta de SU terminal
--   fn_terminal_latido(bigint, ...)                       estado de la terminal y del reloj
--   fn_marca_terminal_registrar(bigint, jsonb)            ruta de marcas, confirmación por evento
--   fn_terminal_baja_por_persona_inactiva(uuid)           emite baja_solicitada de una persona no activa
--   fn_terminal_rechazo_registrar(bigint, jsonb, text)    (interna) deja constancia de un rechazo definitivo
--   fn_terminal_valida_desactivacion() + trigger SCJ13    impide activa=false con altas vigentes
--   fn_bitacora_terminal_usuario_aplica()                 CREATE OR REPLACE: FOR SHARE en 'asignado'
--
-- Aislamiento entre terminales (SCJ-DEC-12 M2): todo RPC que lee o escribe sobre una terminal recibe
-- p_terminal_id, que el backend toma de la credencial (nunca del cuerpo). La validación de pertenencia
-- vive aquí, no en un .eq() del código que un descuido pueda omitir.
--
-- Reglas comunes (CLAUDE.md, SCJ-DEC-12 §8.3):
--   - Toda función es SECURITY DEFINER con SET search_path = tiempo, personas, pg_temp, y cualquier
--     CREATE OR REPLACE futuro debe repetir ambas cláusulas (no se heredan de un ALTER FUNCTION
--     ni de la versión anterior). Verificado por grep: ninguna de estas funciones tiene un ALTER
--     FUNCTION previo; fn_bitacora_terminal_usuario_aplica nació en 81_*.sql con las dos cláusulas.
--   - EXECUTE nace en PUBLIC por defecto: cada función hace REVOKE EXECUTE y, si el backend la
--     llama, GRANT EXECUTE sólo a service_role, en este mismo archivo.
--   - Las funciones sólo devuelven códigos de una lista cerrada; nunca texto de una excepción.
--
-- ERRCODE: SCJ13 (hint 'terminal_con_altas_vigentes') y SCJ14 (hint 'credencial_revocada_inmutable'), nuevos y
-- libres (el último usado era SCJ12, verificado por grep; SCJ14 se comprobó libre al agregar la revisión de security). SCJ11/SCJ12 se reutilizan de 81_*.sql (transición inválida / terminal no
-- válida). Errores de lote del RPC de marcas: 22023 (hint 'lote_invalido'), sin código SCJ propio.
--
-- Valores iniciales AJUSTABLES (SCJ-DEC-12 Q10-Q14), declarados como constantes con nombre al
-- inicio de fn_marca_terminal_registrar: tope de lote 200; por persona, más de 10 marcas/hora
-- genera alarma; por terminal, 1 000/hora alarma y 5 000/hora rechazo transitorio; reloj
-- 'sincronizado' que declara más de 5 min en el futuro o más de 7 días en el pasado se degrada a
-- 'deriva'; instante absurdo: antes de 2024-01-01 o más de 1 año en el futuro; secuencia_local a
-- lo más 1 000 000 por encima de la última recibida.
--
-- Concurrencia: fn_marca_terminal_registrar toma un advisory lock transaccional por terminal (un lote
-- a la vez, también con varios workers del backend); fn_terminal_movimiento_registrar bloquea la alta
-- con FOR UPDATE; el trigger SCJ13 y 'asignado' se serializan con FOR UPDATE / FOR SHARE sobre la
-- fila de la terminal (ver su comentario). Sin ciclos de bloqueo: 'asignado' toma terminal(SHARE) y
-- crea una alta nueva; la desactivación toma terminal(UPDATE) y sólo lee altas; los movimientos del
-- Pi toman alta(UPDATE) y nunca la terminal.
--
-- Revisión de security (2026-10-06), cambios incorporados aquí:
--   M1 fn_marca_terminal_registrar rechaza como no_enrolado (a) una marca de una alta en 'baja' con momento
--      posterior a su baja (+1 h de holgura) y (b) cualquier marca anterior a la creación de la alta (-1 h):
--      el employee_no nunca se reutiliza, pero una alta en 'baja' no debe servir para falsear marcas
--      posteriores. Para una alta en 'baja', actualizado_en es el momento de baja_confirmada.
--   M2 momento_dispositivo exige ISO 8601 anclado (fecha, hora y zona); se descartan formatos locales,
--      palabras ('yesterday') e infinity/-infinity.
--   M3 trigger SCJ14: una revocación de llave (revocada_en) ya fijada no se puede deshacer ni cambiar.
--   B1 los conteos de tope y el max(secuencia_local) se calculan UNA vez por lote y se actualizan al confirmar.
--   B3 sólo un CHECK propio de tiempo.marca (ck_marca_*) es rechazo definitivo de forma; cualquier otro
--      22/23502/23514 dentro del INSERT es transitorio (error del servidor, no del evento).
--   B4 fn_terminal_movimiento_registrar: más de 20 movimientos 'error' de una alta en 1 h devuelven
--      {resultado: limitado} sin insertar (la bitácora es inmutable; no se debe poder llenar).
--   B6 el hash se compara con cast explícito a bpchar. B7 version_pi sin caracteres de control. B8 el latido
--      tolera infinity/-infinity y horas fuera de rango (desfase NULL).
--
-- B2 (costo): cada evento del lote usa 1 o 2 subtransacciones (el bloque ev con EXCEPTION y el INSERT con
-- EXCEPTION); un lote de 200 eventos llega a ~400 subxids en una sola transacción, más allá del caché de
-- 64 por sesión: mientras dura el lote, los snapshots de otras sesiones pueden pasar por pg_subtrans
-- (más lento, no incorrecto). Aceptado: con 1 terminal y ~20 personas los lotes reales son de decenas de
-- eventos. Si el volumen crece, bajar el tope de lote o procesar el lote en varias llamadas.
--
-- B9 (NOTA PARA BACKEND): fn_terminal_baja_por_persona_inactiva devuelve -1 de forma permanente para una
-- persona no activa sin ningún movimiento de suspension/baja_definitiva en personas.bitacora_movimiento_persona
-- (o cuyo autor es NULL): no hay autor derivable y la función no inventa uno. El job de reconciliación debe
-- tratar -1 como alerta (log ERROR + tablero, fila 7), no como "nada que hacer", o esa persona seguirá
-- pudiendo marcar hasta que alguien repare la bitácora de personas.
--
-- Registro de rechazos: fn_marca_terminal_registrar llama a fn_terminal_rechazo_registrar en cada
-- rechazo definitivo. Aquí la función sólo emite un RAISE WARNING estructurado (log); 84_*.sql la
-- redefine para guardar la evidencia en tiempo.marca_rechazada. Así el RPC grande no se reescribe.
--
-- DECISIÓN DE BACKEND PENDIENTE (confirmada por orchestrator): p_reloj_sincronizado de fn_terminal_latido
-- se recibe porque el contrato del latido lo trae, pero NO
-- se persiste: no hay columna para él y el estado de reloj de cada marca ya viaja en la propia marca.
--
-- Rollback de referencia (NO ejecutar sin revisar; 84_*.sql se revierte primero -- incluye DROP FUNCTION
-- tiempo.fn_marca_rechazada_purgar(integer) y restaurar aquí la versión de fn_terminal_rechazo_registrar):
--   DROP TRIGGER trg_terminal_credencial_revocacion_inmutable ON tiempo.terminal_credencial;
--   DROP FUNCTION tiempo.fn_terminal_credencial_revocacion_inmutable();
--   DROP TRIGGER trg_terminal_valida_desactivacion ON tiempo.terminal;
--   DROP FUNCTION tiempo.fn_terminal_valida_desactivacion();
--   DROP FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(uuid);
--   DROP FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb);
--   DROP FUNCTION tiempo.fn_terminal_rechazo_registrar(bigint, jsonb, text);
--   DROP FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer);
--   DROP FUNCTION tiempo.fn_terminal_movimiento_registrar(bigint, bigint, text, integer, text);
--   DROP FUNCTION tiempo.fn_terminal_mapa(bigint);
--   DROP FUNCTION tiempo.fn_terminal_autenticar(text, text);
--   -- y restaurar la versión de fn_bitacora_terminal_usuario_aplica de 81_*.sql (CREATE OR REPLACE
--   -- con SECURITY DEFINER y SET search_path repetidos).
--   -- Los GRANT/REVOKE EXECUTE caen con cada función; no hay tablas, índices, policies ni secuencias nuevas en este archivo.
--
-- Depende de: 02_tiempo.sql, 72_*.sql (fn_marca_valida_revision), 80_*.sql, 81_*.sql, 82_*.sql
-- Justificación: SCJ-DEC-12 §1, §2, §3, §5, §6

-- ============================================================================
-- 1) fn_terminal_autenticar -- el backend la llama en cada petición de /api/terminal/*.
-- Devuelve un jsonb {terminal_id, serie, credencial_id, ip_cambio} o NULL (llave desconocida,
-- revocada, vencida o terminal inactiva: el backend responde un 401 genérico sin distinguir).
-- Valida el formato del hash antes de tocar la tabla. Escribe como máximo una vez cada 30 s por llave
-- y por terminal (ultimo_uso_en, ultima_ip, ultimo_contacto_en), salvo un cambio de IP, que se registra
-- siempre. Un cambio de IP es una alarma para el tablero, no un bloqueo.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_autenticar(p_hash text, p_ip text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_cred       tiempo.terminal_credencial;
  v_serie      varchar(32);
  v_ip         inet;
  v_ip_cambio  boolean := false;
BEGIN
  IF p_hash IS NULL OR p_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN NULL;
  END IF;

  SELECT c.* INTO v_cred
  FROM tiempo.terminal_credencial c
  JOIN tiempo.terminal t ON t.id = c.terminal_id
  WHERE c.hash = p_hash::bpchar   -- cast explícito a char(64): igualdad con el tipo de la columna
    AND c.revocada_en IS NULL
    AND (c.expira_en IS NULL OR c.expira_en > now())
    AND t.activa;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT t.terminal_id INTO v_serie FROM tiempo.terminal t WHERE t.id = v_cred.terminal_id;

  BEGIN
    v_ip := p_ip::inet;
  EXCEPTION WHEN OTHERS THEN
    v_ip := NULL;
  END;
  v_ip_cambio := v_ip IS NOT NULL AND v_cred.ultima_ip IS NOT NULL AND v_ip <> v_cred.ultima_ip;

  UPDATE tiempo.terminal_credencial c
  SET ultimo_uso_en  = now(),
      ultima_ip      = COALESCE(v_ip, c.ultima_ip),
      ip_cambiada_en = CASE WHEN v_ip_cambio THEN now() ELSE c.ip_cambiada_en END
  WHERE c.id = v_cred.id
    AND (c.ultimo_uso_en IS NULL OR c.ultimo_uso_en < now() - interval '30 seconds' OR v_ip_cambio);

  UPDATE tiempo.terminal t
  SET ultimo_contacto_en = now()
  WHERE t.id = v_cred.terminal_id
    AND (t.ultimo_contacto_en IS NULL OR t.ultimo_contacto_en < now() - interval '30 seconds');

  RETURN jsonb_build_object(
    'terminal_id',   v_cred.terminal_id,
    'serie',         v_serie,
    'credencial_id', v_cred.id,
    'ip_cambio',     v_ip_cambio
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_autenticar(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_autenticar(text, text) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_autenticar(text, text) IS
  'SCJ-DEC-12 §1/§3. Busca la credencial vigente por hash SHA-256 y la terminal activa; devuelve '
  '{terminal_id, serie, credencial_id, ip_cambio} o NULL. Escribe ultimo_uso_en/ultima_ip/ultimo_contacto_en '
  'como máximo una vez cada 30 s (siempre ante un cambio de IP). SECURITY DEFINER, search_path fijo, '
  'EXECUTE sólo service_role.';

-- ============================================================================
-- 2) fn_terminal_mapa -- altas no-baja de UNA terminal. Sin persona_id, sin nombres, sin
-- persona_activa: un Pi comprometido no puede unir un employee_no con una persona.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_mapa(p_terminal_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
BEGIN
  RETURN COALESCE(
    (SELECT jsonb_agg(
              jsonb_build_object(
                'terminal_usuario_id', tu.id,
                'employee_no',         tu.employee_no,
                'estado',              tu.estado,
                'huellas_capturadas',  tu.huellas_capturadas)
              ORDER BY tu.employee_no)
     FROM tiempo.terminal_usuario tu
     WHERE tu.terminal_id = p_terminal_id
       AND tu.estado <> 'baja'),
    '[]'::jsonb);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_mapa(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_mapa(bigint) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_mapa(bigint) IS
  'SCJ-DEC-12 §3. Arreglo jsonb de las altas no-baja de la terminal: terminal_usuario_id, employee_no, '
  'estado, huellas_capturadas. Sin persona_id ni nombres. SECURITY DEFINER, EXECUTE sólo service_role.';

-- ============================================================================
-- 3) fn_terminal_movimiento_registrar -- el Pi reporta usuario_creado, huella_capturada,
-- baja_confirmada o error sobre una alta de SU terminal. Idempotente, sin carrera (la alta se
-- bloquea FOR UPDATE). El Pi sólo manda el id de la alta: terminal_id, persona_id y employee_no se toman
-- de la fila. Esta función es lo único que garantiza origen='terminal' y registrado_por=NULL (los CHECK
-- de la bitácora lo respaldan). Devuelve {resultado: 'registrado'|'ya_aplicado'|'no_encontrado'}; una
-- alta de OTRA terminal responde igual que una inexistente ('no_encontrado'), para no revelar que existe.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_movimiento_registrar(
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

  -- Detalle: sin caracteres de control, tope duro de 500 (el backend ya lo sanea; esto es defensa en
  -- profundidad). Un 'error' sin mensaje no pasa el CHECK de la bitácora: se le pone uno fijo.
  v_detalle := NULLIF(left(btrim(regexp_replace(COALESCE(p_detalle, ''), '[[:cntrl:]]', ' ', 'g')), 500), '');
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
  'Más de 20 errores de la alta en 1 h: limitado (sin insertar). '
  'La transición la valida el trigger de 81_*.sql (SCJ11/SCJ12).';

-- ============================================================================
-- 4) fn_terminal_latido -- el Pi reporta su estado cada ~60 s. Guarda el estado del aparato y del
-- reloj en tiempo.terminal y responde la hora del servidor, el desfase y la última secuencia
-- recibida (para que un Pi reinstalado renumere sin chocar con uq_marca_terminal_secuencia,
-- SCJ-DEC-09). Desfase = hora de la terminal MENOS hora del servidor: positivo = la terminal
-- adelanta. No toca la columna activa, así que NO dispara el trigger SCJ13.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_latido(
  p_terminal_id         bigint,
  p_hora_terminal       timestamptz,
  p_alcanzable          boolean,
  p_reloj_sincronizado  boolean,
  p_version_pi          text,
  p_marcas_pendientes   integer
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
    RAISE EXCEPTION 'La terminal % no existe o no está activa', p_terminal_id
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

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer)
  TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_latido(bigint, timestamptz, boolean, boolean, text, integer) IS
  'SCJ-DEC-12 §3. Guarda terminal_alcanzable, reloj_desfase_seg (terminal menos servidor), version_pi y '
  'marcas_pendientes en tiempo.terminal y devuelve {hora_servidor, desfase_reloj_seg, '
  'ultima_secuencia_recibida}. p_reloj_sincronizado se recibe pero no se persiste. SCJ12 si la terminal '
  'no existe o no está activa.';

-- ============================================================================
-- 5) fn_terminal_rechazo_registrar (INTERNA) -- deja constancia de un rechazo definitivo. En este
-- archivo sólo emite un RAISE WARNING estructurado (sin texto libre del evento: valores
-- saneados a [0-9a-f-] y dígitos). 84_*.sql la reemplaza (CREATE OR REPLACE, repitiendo
-- SECURITY DEFINER y search_path) para guardar la evidencia en tiempo.marca_rechazada. Sin EXECUTE
-- para ningún rol de la API: sólo la llama fn_marca_terminal_registrar (que corre como dueño).
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_rechazo_registrar(p_terminal_id bigint, p_evento jsonb, p_codigo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
BEGIN
  RAISE WARNING 'marca_rechazada terminal_id=% codigo=% evento_id=% employee_no=%',
    p_terminal_id,
    left(COALESCE(p_codigo, '-'), 30),
    left(regexp_replace(COALESCE(p_evento->>'evento_id', '-'), '[^0-9a-fA-F-]', '?', 'g'), 40),
    left(regexp_replace(COALESCE(p_evento->>'employee_no', '-'), '[^0-9]', '?', 'g'), 12);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_rechazo_registrar(bigint, jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_rechazo_registrar(bigint, jsonb, text) IS
  'Interna (SCJ-DEC-12 §6). Constancia de un rechazo definitivo de fn_marca_terminal_registrar. En 83_*.sql '
  'sólo log (RAISE WARNING); 84_*.sql la redefine para insertar en tiempo.marca_rechazada. Sin EXECUTE '
  'para ningún rol de la API.';

-- ============================================================================
-- 6) fn_marca_terminal_registrar -- ruta de marcas. Procesa un lote por evento en un sub-bloque
-- (un evento malo no tumba el lote) y devuelve {momento_recepcion, resultados:[{indice, evento_id,
-- estado, codigo?}]} con confirmación INDIVIDUAL (SCJ-CDT-01 §IX.2/§IX.6). Sólo devuelve códigos de
-- una lista cerrada, nunca texto de excepción:
--   estado: confirmado | duplicado | rechazo_definitivo | rechazo_transitorio
--   rechazo_definitivo: forma_invalida, no_enrolado, secuencia_duplicada, secuencia_fuera_de_rango,
--     conflicto_evento
--   rechazo_transitorio: tope_terminal, error_interno
-- Errores de LOTE (se propagan como excepción): SCJ12/terminal_no_valida (terminal inexistente o
-- inactiva) y 22023/lote_invalido (no es un arreglo, está vacío o excede 200).
--
-- El Pi manda employee_no; el persona_id nunca sale del servidor ni se lee del evento. origen,
-- requiere_revision y cualquier otra clave extra del evento se IGNORAN: origen='terminal' lo fija esta
-- función y requiere_revision=false (trg_marca_valida_revision lo calcula). tiempo.marca.terminal_id se
-- escribe con la SERIE de la terminal (varchar), no con su id bigint. employee_no no se persiste.
--
-- Orden de las comprobaciones por evento, tal como en SCJ-DEC-12 §2: forma, absurdos de fecha,
-- secuencia_local acotada, resolución employee_no -> persona (sin alta o alta en pendiente_alta =
-- no_enrolado; altas en baja SÍ resuelven), degradación del reloj, topes, duplicado/conflicto, INSERT.
-- Un 23505 se desambigua por nombre de restricción: uq_marca_evento_id (carrera de dos lotes con el
-- mismo evento) -> se re-lee y se responde duplicado/conflicto_evento; sólo uq_marca_terminal_secuencia
-- -> secuencia_duplicada. Sólo se declara definitivo un error de datos reconocible por clase
-- (22, 23502, 23514); todo lo desconocido es transitorio (el Pi reintenta) y se registra como WARNING
-- con el SQLSTATE, nunca con SQLERRM.
-- ============================================================================

CREATE FUNCTION tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  -- Valores iniciales ajustables (SCJ-DEC-12 Q10-Q14). No son constantes mudas: se cambian aquí.
  c_tope_lote             constant integer     := 200;
  c_tope_persona_hora     constant integer     := 10;       -- más de esto en 1 h: alarma, se inserta
  c_alarma_terminal_hora  constant integer     := 1000;     -- más de esto en 1 h: alarma, se inserta
  c_tope_terminal_hora    constant integer     := 5000;     -- más de esto en 1 h: rechazo transitorio
  c_salto_secuencia       constant bigint      := 1000000;
  c_futuro_reloj          constant interval    := interval '5 minutes';
  c_pasado_reloj          constant interval    := interval '7 days';
  c_instante_minimo       constant timestamptz := timestamptz '2024-01-01 00:00:00+00';
  c_instante_max_futuro   constant interval    := interval '1 year';
  c_holgura_alta          constant interval    := interval '1 hour';      -- tolerancia del reloj frente a la vida de la alta

  v_serie          varchar(32);
  v_activa         boolean;
  v_resultados     jsonb := '[]'::jsonb;
  rec              record;
  v_evento         jsonb;
  v_idx            integer;
  v_estado         text;
  v_codigo         text;
  v_eid            uuid;
  v_emp            integer;
  v_seq            bigint;
  v_momento        timestamptz;
  v_desfase        text;
  v_reloj          text;
  v_reloj_ins      text;
  v_version        text;
  v_persona        uuid;
  v_estado_alta    varchar(20);
  v_max_seq        bigint;
  v_n              bigint;
  v_min            integer;
  v_alta_creada    timestamptz;
  v_alta_actualizada timestamptz;
  v_n_term         bigint;       -- marcas de la terminal en la última hora (se calcula UNA vez por lote)
  v_personas_hora  jsonb;        -- marcas por persona en la última hora (UNA vez por lote)
  v_max_lote       bigint;       -- max(secuencia_local) de la terminal (UNA vez por lote)
  v_exist          tiempo.marca;
  v_cons           text;
  v_carrera        boolean;
BEGIN
  SELECT t.terminal_id, t.activa INTO v_serie, v_activa
  FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND OR NOT v_activa THEN
    RAISE EXCEPTION 'La terminal % no existe o no está activa', p_terminal_id
      USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
  END IF;

  IF p_eventos IS NULL OR jsonb_typeof(p_eventos) <> 'array'
     OR jsonb_array_length(p_eventos) < 1 OR jsonb_array_length(p_eventos) > c_tope_lote THEN
    RAISE EXCEPTION 'lote inválido: se espera un arreglo de 1 a % eventos', c_tope_lote
      USING ERRCODE = '22023', HINT = 'lote_invalido';
  END IF;

  -- Un lote a la vez por terminal, aunque haya varios workers del backend.
  PERFORM pg_advisory_xact_lock(hashtext('fn_marca_terminal_registrar'),
                                (p_terminal_id % 2147483647)::integer);

  -- B1 (security): los conteos de tope y el max(secuencia_local) se calculan UNA vez y se actualizan
  -- conforme se inserta, en vez de dos o tres consultas por evento.
  SELECT COALESCE(max(m.secuencia_local), 0) INTO v_max_lote
  FROM tiempo.marca m WHERE m.terminal_id = v_serie AND m.origen = 'terminal';
  SELECT count(*) INTO v_n_term FROM tiempo.marca m
  WHERE m.terminal_id = v_serie AND m.origen = 'terminal' AND m.momento_recepcion > now() - interval '1 hour';
  SELECT COALESCE(jsonb_object_agg(s.persona_id::text, s.c), '{}'::jsonb) INTO v_personas_hora
  FROM (SELECT m.persona_id, count(*) AS c FROM tiempo.marca m
        WHERE m.momento_recepcion > now() - interval '1 hour'
          AND m.persona_id IN (SELECT tu.persona_id FROM tiempo.terminal_usuario tu WHERE tu.terminal_id = p_terminal_id)
        GROUP BY m.persona_id) s;

  -- En orden de secuencia_local (un evento sin secuencia válida va al final); el índice original se
  -- conserva en la respuesta.
  FOR rec IN
    SELECT (o.ord - 1)::integer AS idx,
           o.elem               AS ev,
           CASE WHEN jsonb_typeof(o.elem) = 'object' AND (o.elem->>'secuencia_local') ~ '^[0-9]{1,18}$'
                THEN (o.elem->>'secuencia_local')::bigint END AS orden_seq
    FROM jsonb_array_elements(p_eventos) WITH ORDINALITY AS o(elem, ord)
    ORDER BY orden_seq NULLS LAST, o.ord
  LOOP
    v_idx := rec.idx;
    v_evento := rec.ev;
    v_estado := NULL;
    v_codigo := NULL;
    v_eid := NULL;
    v_carrera := false;

    -- evento_id: se valida con regex en vez de un bloque con EXCEPTION (cada bloque con EXCEPTION es una
    -- subtransacción; ver B2 de la cabecera).
    IF jsonb_typeof(v_evento) = 'object'
       AND (v_evento->>'evento_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_eid := (v_evento->>'evento_id')::uuid;
    END IF;

    <<ev>>
    BEGIN
      -- 1. Forma. Todo cast y rango dentro de este sub-bloque: un error de clase 22 cae al handler.
      IF jsonb_typeof(v_evento) <> 'object' OR v_eid IS NULL THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      v_emp     := (v_evento->>'employee_no')::integer;
      v_seq     := (v_evento->>'secuencia_local')::bigint;
      v_desfase := v_evento->>'desfase_local';
      v_reloj   := v_evento->>'estado_reloj';
      v_version := v_evento->>'version_software';

      IF v_emp IS NULL OR v_emp NOT BETWEEN 1 AND 99999999
         OR v_seq IS NULL OR v_seq < 0
         OR (v_evento->>'momento_dispositivo') IS NULL
         -- M2 (security): ISO 8601 con fecha, hora y zona, anclada al inicio y al final. Descarta formatos
         -- locales ('06/10/2026 10:00:00Z'), palabras ('yesterday 10:00Z') e infinity/-infinity.
         OR (v_evento->>'momento_dispositivo') !~
            '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$'
         OR v_desfase IS NULL OR v_desfase !~ '^[+-][0-9]{2}:[0-9]{2}$'
         OR v_reloj IS NULL OR v_reloj NOT IN ('sincronizado', 'deriva', 'sin_sincronizar')
         OR v_version IS NULL OR char_length(v_version) NOT BETWEEN 1 AND 16 THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      v_momento := (v_evento->>'momento_dispositivo')::timestamptz;

      -- Rango real del desfase (validación nueva del RPC; el CHECK de marca sólo valida el formato):
      -- -12:00 .. +14:00, minutos 00-59.
      v_min := substr(v_desfase, 2, 2)::integer * 60 + substr(v_desfase, 5, 2)::integer;
      IF substr(v_desfase, 5, 2)::integer > 59
         OR (substr(v_desfase, 1, 1) = '-' AND v_min > 720)
         OR (substr(v_desfase, 1, 1) = '+' AND v_min > 840) THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      -- 2. Absurdos de fecha: el único rechazo por tiempo.
      IF NOT isfinite(v_momento) OR v_momento < c_instante_minimo OR v_momento > now() + c_instante_max_futuro THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida'; EXIT ev;
      END IF;

      -- 3. secuencia_local acotada por la última recibida de esta terminal (calculada una vez por lote
      -- y actualizada al confirmar cada marca).
      IF v_seq > v_max_lote + c_salto_secuencia THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'secuencia_fuera_de_rango'; EXIT ev;
      END IF;

      -- 4. Resolución employee_no -> persona. UNIQUE (terminal_id, employee_no) sin condición de
      -- estado: resuelve también altas en 'baja' (una marca legítima encolada antes de la baja).
      -- Sin alta, o alta aún en pendiente_alta (el aparato no pudo crear ese usuario): no_enrolado.
      SELECT tu.persona_id, tu.estado, tu.creado_en, tu.actualizado_en
        INTO v_persona, v_estado_alta, v_alta_creada, v_alta_actualizada
      FROM tiempo.terminal_usuario tu
      WHERE tu.terminal_id = p_terminal_id AND tu.employee_no = v_emp;
      IF NOT FOUND OR v_estado_alta = 'pendiente_alta' THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'no_enrolado'; EXIT ev;
      END IF;

      -- M1 (security): el employee_no nunca se reutiliza y las altas en 'baja' siguen resolviendo (una marca
      -- legítima encolada antes de la baja), pero eso no debe servir para falsear marcas fuera de la vida de la
      -- alta: (a) una marca de una alta en 'baja' con momento posterior a su baja (+1 h de holgura de reloj)
      -- y (b) cualquier marca anterior a la creación de la alta (-1 h) se rechazan como no_enrolado. Para
      -- una alta en 'baja', actualizado_en es el momento de baja_confirmada (después no admite más
      -- movimientos).
      IF (v_estado_alta = 'baja' AND v_momento > v_alta_actualizada + c_holgura_alta)
         OR v_momento < v_alta_creada - c_holgura_alta THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'no_enrolado'; EXIT ev;
      END IF;

      -- 5. Degradación del reloj: sólo puede empeorarse, nunca mejorarse. No se rechaza.
      v_reloj_ins := v_reloj;
      IF v_reloj = 'sincronizado'
         AND (v_momento > now() + c_futuro_reloj OR v_momento < now() - c_pasado_reloj) THEN
        v_reloj_ins := 'deriva';
      END IF;

      -- 6. Topes de tasa (última hora, por momento_recepcion).
      -- Los conteos se calcularon UNA vez antes del bucle y se suman al confirmar (B1).
      IF v_n_term >= c_tope_terminal_hora THEN
        v_estado := 'rechazo_transitorio'; v_codigo := 'tope_terminal'; EXIT ev;
      END IF;
      IF v_n_term >= c_alarma_terminal_hora THEN
        RAISE WARNING 'alarma_tasa_terminal terminal_id=% marcas_ultima_hora=%', p_terminal_id, v_n_term;
      END IF;
      v_n := COALESCE((v_personas_hora ->> v_persona::text)::bigint, 0);
      IF v_n >= c_tope_persona_hora THEN
        RAISE WARNING 'alarma_tasa_persona terminal_id=% employee_no=% marcas_ultima_hora=%',
          p_terminal_id, v_emp, v_n;
      END IF;

      -- 7. Duplicado / conflicto por evento_id (idempotencia).
      SELECT m.* INTO v_exist FROM tiempo.marca m WHERE m.evento_id = v_eid;
      IF FOUND THEN
        IF v_exist.terminal_id = v_serie AND v_exist.persona_id = v_persona
           AND v_exist.momento_dispositivo = v_momento
           AND v_exist.secuencia_local IS NOT DISTINCT FROM v_seq THEN
          v_estado := 'duplicado';
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% employee_no=%', p_terminal_id, v_emp;
          v_estado := 'rechazo_definitivo'; v_codigo := 'conflicto_evento';
        END IF;
        EXIT ev;
      END IF;

      -- 8. INSERT. origen y requiere_revision los fija esta función, no el evento.
      BEGIN
        INSERT INTO tiempo.marca
          (evento_id, persona_id, terminal_id, secuencia_local, momento_dispositivo,
           desfase_local, estado_reloj, version_software, origen, requiere_revision)
        VALUES
          (v_eid, v_persona, v_serie, v_seq, v_momento,
           v_desfase, v_reloj_ins, v_version, 'terminal', false);
        v_estado := 'confirmado';
        -- Contadores del lote (B1): lo recién confirmado cuenta para los topes y el tope de secuencia.
        v_n_term := v_n_term + 1;
        v_personas_hora := jsonb_set(v_personas_hora, ARRAY[v_persona::text],
          to_jsonb(COALESCE((v_personas_hora ->> v_persona::text)::bigint, 0) + 1));
        v_max_lote := GREATEST(v_max_lote, v_seq);
      EXCEPTION
        WHEN unique_violation THEN
          GET STACKED DIAGNOSTICS v_cons = CONSTRAINT_NAME;
          IF v_cons = 'uq_marca_evento_id' THEN
            v_carrera := true;
          ELSIF v_cons = 'uq_marca_terminal_secuencia' THEN
            v_estado := 'rechazo_definitivo'; v_codigo := 'secuencia_duplicada';
          ELSE
            RAISE WARNING 'fn_marca_terminal_registrar: unicidad no prevista en terminal_id=%', p_terminal_id;
            v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
          END IF;
        -- B3 (security): sólo un CHECK propio de tiempo.marca (ck_marca_*) es un rechazo definitivo de forma.
        -- Cualquier otro 22/23502/23514 ocurrido dentro del INSERT (p. ej. de un trigger) es un error del
        -- servidor, no del evento: transitorio, el Pi reintenta.
        WHEN data_exception OR not_null_violation OR check_violation THEN
          GET STACKED DIAGNOSTICS v_cons = CONSTRAINT_NAME;
          IF v_cons LIKE 'ck\_marca\_%' THEN
            v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida';
          ELSE
            RAISE WARNING 'fn_marca_terminal_registrar: error de datos dentro del INSERT sqlstate=% terminal_id=%',
              SQLSTATE, p_terminal_id;
            v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
          END IF;
      END;

      -- Carrera por evento_id: otro lote insertó el mismo evento entre el SELECT y el INSERT.
      IF v_carrera THEN
        SELECT m.* INTO v_exist FROM tiempo.marca m WHERE m.evento_id = v_eid;
        IF FOUND AND v_exist.terminal_id = v_serie AND v_exist.persona_id = v_persona
           AND v_exist.momento_dispositivo = v_momento
           AND v_exist.secuencia_local IS NOT DISTINCT FROM v_seq THEN
          v_estado := 'duplicado';
        ELSE
          RAISE WARNING 'conflicto_evento terminal_id=% employee_no=%', p_terminal_id, v_emp;
          v_estado := 'rechazo_definitivo'; v_codigo := 'conflicto_evento';
        END IF;
      END IF;
    EXCEPTION
      WHEN data_exception OR not_null_violation OR check_violation THEN
        v_estado := 'rechazo_definitivo'; v_codigo := 'forma_invalida';
      WHEN OTHERS THEN
        RAISE WARNING 'fn_marca_terminal_registrar: error no previsto sqlstate=% terminal_id=%',
          SQLSTATE, p_terminal_id;
        v_estado := 'rechazo_transitorio'; v_codigo := 'error_interno';
    END;

    IF v_estado = 'rechazo_definitivo' THEN
      BEGIN
        PERFORM tiempo.fn_terminal_rechazo_registrar(p_terminal_id, v_evento, v_codigo);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_marca_terminal_registrar: no se pudo registrar el rechazo sqlstate=%', SQLSTATE;
      END;
    END IF;

    v_resultados := v_resultados || jsonb_build_array(
      jsonb_build_object('indice', v_idx, 'evento_id', v_eid, 'estado', v_estado)
      || CASE WHEN v_codigo IS NOT NULL THEN jsonb_build_object('codigo', v_codigo) ELSE '{}'::jsonb END);
  END LOOP;

  RETURN jsonb_build_object(
    'momento_recepcion', now(),
    'resultados', (SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'indice')::integer), '[]'::jsonb)
                   FROM jsonb_array_elements(v_resultados) AS r)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb) TO service_role;

COMMENT ON FUNCTION tiempo.fn_marca_terminal_registrar(bigint, jsonb) IS
  'SCJ-DEC-12 §2. Registra un lote (1-200) de marcas de la terminal p_terminal_id y devuelve '
  '{momento_recepcion, resultados:[{indice, evento_id, estado, codigo?}]}. Resuelve employee_no a '
  'persona_id en la base (nunca sale del servidor), fija origen=terminal, degrada estado_reloj, aplica '
  'topes y confirma por evento. Sólo códigos de lista cerrada. Errores de lote: SCJ12 (terminal) y 22023 '
  '(lote). SECURITY DEFINER, search_path fijo, EXECUTE sólo service_role. Al reescribirla repetir '
  'SECURITY DEFINER y SET search_path.';

-- ============================================================================
-- 7) fn_terminal_baja_por_persona_inactiva -- un solo camino para el hook sincrónico y el job de
-- reconciliación (SCJ-DEC-12 §5). Si la persona NO está activa en personas.persona (suspension,
-- baja_definitiva o inexistente: lo mismo que evalúa trg_marca_valida_revision) emite baja_solicitada de
-- cada alta suya que no esté ya en pendiente_baja o baja. El autor es el de su último movimiento de
-- suspension/baja_definitiva en personas.bitacora_movimiento_persona (no hay usuario "sistema").
-- Devuelve cuántas bajas emitió; 0 si la persona está activa o no tiene altas por dar de baja; -1 si no
-- se pudo derivar un autor (se deja un WARNING; no se inventa autor). SCJ11/SCJ12 de una alta se
-- ignoran (carrera o ya hecha). No se puede usar para dar de baja a personas activas.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)
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

  SELECT b.registrado_por INTO v_autor
  FROM personas.bitacora_movimiento_persona b
  WHERE b.persona_id = p_persona_id AND b.tipo_movimiento IN ('suspension', 'baja_definitiva')
  ORDER BY b.fecha_efectiva DESC, b.creado_en DESC
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
  'o inexistente) con autor = el de su último movimiento de suspension/baja_definitiva. Devuelve el número '
  'emitido, 0 si está activa o no hay altas, -1 si no hay autor derivable. Idempotente. SECURITY DEFINER, '
  'EXECUTE sólo service_role (hook y job del backend).';

-- ============================================================================
-- 8) Trigger SCJ13 -- tiempo.terminal.activa no puede pasar de true a false mientras existan altas
-- no-baja de esa terminal: las bajas y reportes del Pi necesitan la terminal activa para llegar, así
-- que apagarla primero dejaría altas atascadas en pendiente_baja (SCJ-DEC-12 §6). Lo bloquean así
-- tanto la UI/script como cualquier UPDATE directo de service_role.
-- Carrera con 'asignado' (81_*.sql): este trigger toma la fila de la terminal FOR UPDATE antes de
-- contar altas, y 'asignado' (CREATE OR REPLACE de abajo) la toma FOR SHARE: o la asignación ve la
-- terminal ya inactiva, o la desactivación ve la alta ya creada. WHEN (OLD.activa AND NOT NEW.activa) y
-- UPDATE OF activa acotan el disparo a la desactivación real.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_valida_desactivacion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
BEGIN
  PERFORM 1 FROM tiempo.terminal t WHERE t.id = OLD.id FOR UPDATE;
  IF EXISTS (
    SELECT 1 FROM tiempo.terminal_usuario tu WHERE tu.terminal_id = OLD.id AND tu.estado <> 'baja'
  ) THEN
    RAISE EXCEPTION 'La terminal % tiene altas vigentes; dalas de baja antes de desactivarla', OLD.id
      USING ERRCODE = 'SCJ13', HINT = 'terminal_con_altas_vigentes';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_valida_desactivacion()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_terminal_valida_desactivacion
  BEFORE UPDATE OF activa ON tiempo.terminal
  FOR EACH ROW
  WHEN (OLD.activa AND NOT NEW.activa)
  EXECUTE FUNCTION tiempo.fn_terminal_valida_desactivacion();

COMMENT ON FUNCTION tiempo.fn_terminal_valida_desactivacion() IS
  'SCJ-DEC-12 §6. Aborta con SCJ13 (terminal_con_altas_vigentes) si se desactiva una terminal que aún '
  'tiene altas no-baja. Toma la fila de la terminal FOR UPDATE antes de contar (serializa con '
  '''asignado'', que la toma FOR SHARE). SECURITY DEFINER, search_path fijo, sin EXECUTE para la API.';

-- ============================================================================
-- 8b) Trigger SCJ14 -- una revocación de llave es irreversible (M3 de la revisión de security).
-- 82_*.sql dejaba a service_role poner revocada_en en NULL (reactivar una llave ya revocada). Este
-- trigger lo prohíbe: una vez que revocada_en tiene valor, no puede cambiar (ni a NULL ni a otro
-- instante); revocar una llave vigente (NULL -> valor) sí se permite. Una llave retirada se
-- sustituye por una nueva (rotación), nunca se reactiva. UPDATE OF revocada_en + WHEN acotan el disparo.
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_credencial_revocacion_inmutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'La credencial % ya está revocada; una revocación no se puede deshacer ni modificar', OLD.id
    USING ERRCODE = 'SCJ14', HINT = 'credencial_revocada_inmutable';
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_credencial_revocacion_inmutable()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_terminal_credencial_revocacion_inmutable
  BEFORE UPDATE OF revocada_en ON tiempo.terminal_credencial
  FOR EACH ROW
  WHEN (OLD.revocada_en IS NOT NULL AND NEW.revocada_en IS DISTINCT FROM OLD.revocada_en)
  EXECUTE FUNCTION tiempo.fn_terminal_credencial_revocacion_inmutable();

COMMENT ON FUNCTION tiempo.fn_terminal_credencial_revocacion_inmutable() IS
  'SCJ-DEC-12 (revisión de security M3). Aborta con SCJ14 (credencial_revocada_inmutable) cualquier cambio de '
  'revocada_en sobre una credencial ya revocada, incluido NULL. SECURITY DEFINER, search_path fijo, sin '
  'EXECUTE para la API. El dueño aún puede DISABLE TRIGGER/DROP: residual como en toda bitácora.';

-- ============================================================================
-- 9) CREATE OR REPLACE de fn_bitacora_terminal_usuario_aplica (81_*.sql). ÚNICO cambio respecto de
-- la versión de 81: en 'asignado' el chequeo de terminal activa pasa de un EXISTS sin bloqueo a
-- PERFORM ... FOR SHARE (para serializar con el trigger SCJ13). Todo lo demás es idéntico.
-- Repite SECURITY DEFINER y SET search_path = tiempo, personas, pg_temp: CREATE OR REPLACE no hereda
-- esas cláusulas (gotcha de CLAUDE.md); esta función no tiene ningún ALTER FUNCTION previo, verificado
-- por grep. Los privilegios (EXECUTE revocado) se conservan al reemplazar; se reafirman abajo.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica()
RETURNS trigger AS $$
DECLARE
  v_vivo         tiempo.terminal_usuario;
  v_id           bigint;
  v_employee_no  integer;
  v_estado       varchar(20);
  v_huellas      smallint;
  v_error        text;
BEGIN
  -- ---- asignado: crea la fila viva -------------------------------------------------------
  IF NEW.tipo_movimiento = 'asignado' THEN
    IF NEW.terminal_usuario_id IS NOT NULL OR NEW.employee_no IS NOT NULL THEN
      RAISE EXCEPTION
        'En "asignado" terminal_usuario_id y employee_no los asigna el servidor; deben llegar NULL'
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;

    -- Antes del nextval: una asignación rechazada no debe quemar un employee_no. FOR SHARE (83_*.sql):
    -- bloquea la fila de la terminal frente a una desactivación concurrente (trigger SCJ13).
    PERFORM 1 FROM tiempo.terminal t WHERE t.id = NEW.terminal_id AND t.activa FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La terminal % no existe o no está activa; no se puede asignar',
        NEW.terminal_id USING ERRCODE = 'SCJ12', HINT = 'terminal_no_valida';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM personas.persona p WHERE p.id = NEW.persona_id AND p.estado = 'activo'
    ) THEN
      RAISE EXCEPTION 'La persona % no existe o no está activa; no se puede asignar a la terminal',
        NEW.persona_id USING ERRCODE = 'SCJ12', HINT = 'persona_no_activa';
    END IF;

    IF EXISTS (
      SELECT 1 FROM tiempo.terminal_usuario tu
      WHERE tu.terminal_id = NEW.terminal_id AND tu.persona_id = NEW.persona_id
        AND tu.estado <> 'baja'
    ) THEN
      RAISE EXCEPTION 'La persona % ya tiene un alta vigente en la terminal %',
        NEW.persona_id, NEW.terminal_id USING ERRCODE = 'SCJ12', HINT = 'alta_duplicada';
    END IF;

    INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado)
    VALUES (NEW.terminal_id, NEW.persona_id, nextval('tiempo.seq_terminal_employee_no'),
            'pendiente_alta')
    RETURNING id, employee_no INTO v_id, v_employee_no;

    NEW.terminal_usuario_id := v_id;
    NEW.employee_no := v_employee_no;
    RETURN NEW;
  END IF;

  -- ---- resto: actúan sobre una fila viva existente ---------------------------------------
  IF NEW.terminal_usuario_id IS NULL THEN
    RAISE EXCEPTION 'El movimiento "%" requiere terminal_usuario_id', NEW.tipo_movimiento
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  -- FOR UPDATE serializa dos movimientos concurrentes sobre la misma alta.
  SELECT * INTO v_vivo FROM tiempo.terminal_usuario WHERE id = NEW.terminal_usuario_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'terminal_usuario % no existe', NEW.terminal_usuario_id
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  IF NEW.terminal_id IS DISTINCT FROM v_vivo.terminal_id
     OR NEW.persona_id IS DISTINCT FROM v_vivo.persona_id THEN
    RAISE EXCEPTION 'terminal_id/persona_id no coinciden con la alta % (terminal %, persona %)',
      v_vivo.id, v_vivo.terminal_id, v_vivo.persona_id
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  IF NEW.employee_no IS NULL THEN
    NEW.employee_no := v_vivo.employee_no;
  ELSIF NEW.employee_no IS DISTINCT FROM v_vivo.employee_no THEN
    RAISE EXCEPTION 'employee_no % no coincide con el de la alta % (%)',
      NEW.employee_no, v_vivo.id, v_vivo.employee_no
      USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
  END IF;

  v_estado  := v_vivo.estado;
  v_huellas := v_vivo.huellas_capturadas;
  v_error   := NULL;  -- todo movimiento válido distinto de 'error' limpia el último error

  IF NEW.tipo_movimiento = 'usuario_creado' THEN
    IF v_vivo.estado IS DISTINCT FROM 'pendiente_alta' THEN
      RAISE EXCEPTION 'usuario_creado exige estado pendiente_alta (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'esperando_huella';

  ELSIF NEW.tipo_movimiento = 'huella_capturada' THEN
    IF v_vivo.estado NOT IN ('esperando_huella', 'activo') THEN
      RAISE EXCEPTION 'huella_capturada exige estado esperando_huella o activo (estado actual: %)',
        v_vivo.estado USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado  := 'activo';
    v_huellas := NEW.huellas_capturadas;

  ELSIF NEW.tipo_movimiento = 'baja_solicitada' THEN
    IF v_vivo.estado IN ('pendiente_baja', 'baja') THEN
      RAISE EXCEPTION 'baja_solicitada no aplica en estado % (ya está en baja o por darse de baja)',
        v_vivo.estado USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'pendiente_baja';

  ELSIF NEW.tipo_movimiento = 'baja_confirmada' THEN
    IF v_vivo.estado IS DISTINCT FROM 'pendiente_baja' THEN
      RAISE EXCEPTION 'baja_confirmada exige estado pendiente_baja (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'baja';

  ELSIF NEW.tipo_movimiento = 'error' THEN
    IF v_vivo.estado = 'baja' THEN
      RAISE EXCEPTION 'error no aplica sobre una alta ya dada de baja'
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_error := NEW.detalle;  -- sin cambio de estado
  END IF;

  UPDATE tiempo.terminal_usuario
  SET estado = v_estado,
      huellas_capturadas = v_huellas,
      error_detalle = v_error,
      actualizado_en = now()
  WHERE id = v_vivo.id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = tiempo, personas, pg_temp;

REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica() IS
  'Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] '
  'desde cada fila de la bitácora (SCJ-DEC-11). SECURITY DEFINER SET search_path = tiempo, '
  'personas, pg_temp: único escritor de terminal_usuario. SCJ11 = transición inválida o fila viva '
  'incoherente; SCJ12 = alta duplicada, persona no elegible o terminal no válida; cada raise trae '
  'HINT estable. En ''asignado'' la terminal se toma FOR SHARE (83_*.sql) para serializar con el '
  'trigger SCJ13. Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';
