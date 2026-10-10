-- 96_tiempo_logs_sin_identidad_y_endurece_anon.sql  (BORRADOR — NO ensayado, NO aplicado; pendiente de la revisión de security)
-- Dos cosas en un solo archivo, como pidió security:
--   A) LOGS SIN IDENTIDAD (regla «nunca employee_no ni persona_id en logs»). Los WARNING de 95_ (fn_marca_terminal_registrar) ya cumplen la regla. Quedan dos
--      funciones que NO se tocan en 94_/95_ y se reemplazan aquí, con CREATE OR REPLACE desde su definición vigente (84_ y 91_), repitiendo SECURITY DEFINER,
--      SET search_path = tiempo, personas, pg_temp y el REVOKE/GRANT (CREATE OR REPLACE no hereda nada):
--        - fn_terminal_rechazo_registrar (84_): el WARNING «marca_rechazada» deja solo terminal_id, codigo y evento_id (sin employee_no).
--        - fn_terminal_baja_por_persona_inactiva (91_): el WARNING «sin autor derivable» deja de llevar persona_id (el -1 de retorno ya lo registra el backend).
--      Diffs literales: db/ensayos/diff_96_logs.diff (el resto de cada cuerpo es idéntico); copias de lo vigente: db/ensayos/vigente_96_*.sql.
--   B) ENDURECIMIENTO DE anon (propuesta de security, sin escribir todavía: ver la sección B al final; requiere inventario por tabla y ensayo propio).
-- Verificador: verificar_ddl.sql sección 59 (consulta estática sobre pg_proc.prosrc) devuelve filas para estas dos funciones hasta que se aplique este archivo.
--
-- APLICAR con `psql --single-transaction -f 96_*.sql`. Sin BEGIN/COMMIT. Depende de 84_ y 91_.
-- Inventario de RLS/privilegios (parte A): sin tablas, policies ni permisos nuevos; fn_terminal_rechazo_registrar sin EXECUTE para nadie de la API (REVOKE FROM
-- PUBLIC, anon, authenticated, service_role, como en 84_); fn_terminal_baja_por_persona_inactiva EXECUTE solo service_role (REVOKE FROM PUBLIC, anon, authenticated
-- + GRANT, como en 91_).
-- REVERSA: CREATE OR REPLACE con los cuerpos vigentes (db/ensayos/vigente_96_*.sql), repitiendo SECURITY DEFINER, SET search_path y REVOKE/GRANT.

-- ============================================================================
-- A) Logs sin identidad
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_rechazo_registrar(p_terminal_id bigint, p_evento jsonb, p_codigo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_tope_filas_dia  constant integer := 5000;   -- valor inicial ajustable (SCJ-DEC-12 Q13)
  v_eid   uuid;
  v_emp   integer;
  v_seq   bigint;
  v_mom   timestamptz;
  v_des   text;
  v_rel   text;
  v_txt   text;
  v_n     bigint;
BEGIN
  -- 96_: el log nunca lleva employee_no ni persona_id (regla de security); solo terminal_id, codigo y evento_id.
  RAISE WARNING 'marca_rechazada terminal_id=% codigo=% evento_id=%',
    p_terminal_id,
    left(COALESCE(p_codigo, '-'), 30),
    left(regexp_replace(COALESCE(p_evento->>'evento_id', '-'), '[^0-9a-fA-F-]', '?', 'g'), 40);

  IF p_codigo IS NULL OR p_codigo NOT IN ('forma_invalida', 'no_enrolado', 'secuencia_duplicada',
                                          'secuencia_fuera_de_rango', 'conflicto_evento') THEN
    RAISE WARNING 'marca_rechazada: código no reconocido, no se guarda';
    RETURN;
  END IF;

  BEGIN
    v_eid := (p_evento->>'evento_id')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_eid := NULL;
  END;

  v_txt := p_evento->>'employee_no';
  IF v_txt ~ '^[0-9]{1,8}$' THEN v_emp := v_txt::integer; END IF;

  v_txt := p_evento->>'secuencia_local';
  IF v_txt ~ '^[0-9]{1,18}$' THEN v_seq := v_txt::bigint; END IF;

  -- M2 (security): sólo ISO 8601 anclado (fecha, hora y zona); nada de formatos locales ni infinity.
  v_txt := p_evento->>'momento_dispositivo';
  IF v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$' THEN
    BEGIN
      v_mom := v_txt::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      v_mom := NULL;
    END;
  END IF;

  v_des := p_evento->>'desfase_local';
  IF v_des IS NULL OR v_des !~ '^[+-][0-9]{2}:[0-9]{2}$' THEN v_des := NULL; END IF;

  v_rel := p_evento->>'estado_reloj';
  IF v_rel IS NULL OR v_rel NOT IN ('sincronizado', 'deriva', 'sin_sincronizar') THEN v_rel := NULL; END IF;

  SELECT count(*) INTO v_n FROM tiempo.marca_rechazada r
  WHERE r.terminal_id = p_terminal_id AND r.creada_en > now() - interval '1 day';
  IF v_n >= c_tope_filas_dia THEN
    RAISE WARNING 'marca_rechazada_tope terminal_id=% filas_ultimas_24h=%: no se guarda la fila',
      p_terminal_id, v_n;
    RETURN;
  END IF;

  INSERT INTO tiempo.marca_rechazada
    (terminal_id, evento_id, employee_no, secuencia_local, momento_dispositivo,
     desfase_local, estado_reloj, codigo)
  VALUES
    (p_terminal_id, v_eid, v_emp, v_seq, v_mom, v_des, v_rel, p_codigo)
  ON CONFLICT (terminal_id, evento_id) DO NOTHING;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_rechazo_registrar(bigint, jsonb, text)
  FROM PUBLIC, anon, authenticated, service_role;

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
    -- 96_: sin persona_id en el log (regla de security); el job y el hook del backend registran el -1 de retorno.
    RAISE WARNING 'fn_terminal_baja_por_persona_inactiva: sin autor derivable';
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

-- ============================================================================
-- B) Endurecimiento de anon — PROPUESTA DE security, SIN ESCRIBIR (requiere inventario por tabla y ensayo propio)
-- ============================================================================
-- tiempo.marca y el resto de las tablas de tiempo conservan privilegios de tabla para anon (arDxtm) y authenticated por el GRANT ALL schema-wide de 38_; la
-- barrera real es RLS deny-by-default (sin policy para anon; el ensayo de 93_ caso 24 lo confirmó). La propuesta: REVOKE ALL explícito a anon sobre las tablas de
-- tiempo que ninguna ruta pública usa, y REVOKE TRUNCATE, REFERENCES, TRIGGER a anon y authenticated (TRUNCATE no está sujeto a RLS). Antes de escribirlo:
-- inventario por tabla de qué rol necesita qué, ensayo BEGIN … ROLLBACK, y aviso a backend (los routers con get_caller_client dependen de los GRANT de authenticated).
