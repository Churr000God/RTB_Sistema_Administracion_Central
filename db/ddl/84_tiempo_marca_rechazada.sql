-- 84_tiempo_marca_rechazada.sql
-- Tercera pieza de SCJ-DEC-12: tiempo.marca_rechazada, la evidencia de cada rechazo DEFINITIVO de
-- fn_marca_terminal_registrar (83_*.sql) -- sobre todo 'no_enrolado' --, para no perderla si el Pi se
-- reinstala o se pierde (SCJ-CDT-01 §II.5: "la evidencia nunca se pierde"). Una marca rechazada NO
-- entra a tiempo.marca (persona_id es NOT NULL y no hay a quién atribuirla sin falsear la identidad):
-- se conserva aquí, fuera de Tiempo, hasta que RH la resuelva o venza la retención.
--
-- Qué crea:
--   1) tiempo.marca_rechazada -- sin escritura directa para la API (sólo la inserta fn_terminal_rechazo_registrar), sin datos de identidad ni texto libre
--      (tipos acotados; tamaño de fila fijo).
--   2) fn_terminal_rechazo_registrar -- CREATE OR REPLACE de la función interna de 83_*.sql (que sólo
--      hacía log) para insertar aquí, con tope de filas por terminal y por día.
--   3) fn_marca_rechazada_purgar -- el ÚNICO camino de borrado de la tabla.
--
-- EXCEPCIÓN DELIBERADA a la inmutabilidad en 3 capas de 81_*.sql (decisión de db, SCJ-DEC-12 §6): la
-- bitácora de enrolamiento es auditoría y no se borra; marca_rechazada es evidencia DIAGNÓSTICA con vida
-- limitada (90 días) y por eso debe poder borrarse, pero por un solo camino. La garantía aquí es de
-- PRIVILEGIOS, no de triggers: REVOKE ALL a anon/authenticated/service_role y GRANT sólo de lo
-- estrictamente necesario, sin UPDATE, DELETE ni TRUNCATE para ningún rol de la API; la purga es una
-- función SECURITY DEFINER que corre como dueño y a la que sólo service_role puede llamar. No lleva
-- triggers BEFORE UPDATE/DELETE/TRUNCATE (la propia purga los dispararía). verificar_ddl.sql lo
-- comprueba y lo anota como excepción.
--
-- Valores iniciales AJUSTABLES (SCJ-DEC-12 Q13), con comentario y nombre, no constantes mudas:
--   - tope de 5 000 filas por terminal en las últimas 24 horas (constante c_tope_filas_dia de
--     fn_terminal_rechazo_registrar): pasado el tope sólo se registra un WARNING (una inundación no
--     llena el disco);
--   - retención de 90 días (parámetro p_dias de fn_marca_rechazada_purgar, por defecto 90; mínimo 7).
--
-- Inventario de RLS/privilegios de este archivo:
--   tiempo.marca_rechazada  RLS on, 1 policy (SELECT para quien tiene terminal_usuario_lectura o
--                           _edicion: el tablero de anomalías de RH lee los rechazos por código, SCJ-DEC-12
--                           §6 fila 5). authenticated y service_role: SELECT. anon: nada. Nadie de la API inserta (B5): sólo fn_terminal_rechazo_registrar.
--                           Sin UPDATE/DELETE/TRUNCATE para nadie de la API. Secuencia identity sin
--                           privilegios.
--   Funciones               fn_terminal_rechazo_registrar: sin EXECUTE para la API (sólo la llama el RPC
--                           de marcas, que corre como dueño). fn_marca_rechazada_purgar: EXECUTE sólo
--                           service_role (scheduler del backend).
--
-- Rollback de referencia (NO ejecutar sin revisar; aplicarlo borra la evidencia guardada):
--   -- restaurar fn_terminal_rechazo_registrar de 83_*.sql (CREATE OR REPLACE con SECURITY DEFINER y
--   -- SET search_path repetidos), luego:
--   DROP FUNCTION tiempo.fn_marca_rechazada_purgar(integer);
--   DROP TABLE tiempo.marca_rechazada;
--   -- La policy marca_rechazada_select_lectura, los índices, la UNIQUE y la secuencia identity caen con la tabla.
--
-- Depende de: 38_tiempo_permisos.sql, 80_tiempo_terminal_usuario.sql, 83_tiempo_terminal_rpc.sql
-- Justificación: SCJ-DEC-12 §2 (no_enrolado), §6 (marca_rechazada), §8.3

-- ============================================================================
-- 1) tiempo.marca_rechazada
-- ============================================================================

CREATE TABLE tiempo.marca_rechazada (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_id          bigint NOT NULL REFERENCES tiempo.terminal (id),
  evento_id            uuid,
  employee_no          integer,
  secuencia_local      bigint,
  momento_dispositivo  timestamptz,
  desfase_local        varchar(6),
  estado_reloj         varchar(20),
  codigo               varchar(30) NOT NULL,
  creada_en            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_marca_rechazada_terminal_evento UNIQUE (terminal_id, evento_id),
  CONSTRAINT ck_marca_rechazada_codigo CHECK (
    codigo IN ('forma_invalida', 'no_enrolado', 'secuencia_duplicada',
               'secuencia_fuera_de_rango', 'conflicto_evento')
  )
);

CREATE INDEX ix_marca_rechazada_creada_en ON tiempo.marca_rechazada (creada_en);

COMMENT ON TABLE tiempo.marca_rechazada IS
  'Evidencia de un rechazo DEFINITIVO de fn_marca_terminal_registrar (SCJ-DEC-12 §6): la marca no entró a '
  'tiempo.marca. Sin datos de identidad y sin texto libre (tipos acotados). Sin escritura directa para la API (sólo la inserta fn_terminal_rechazo_registrar); '
  'se purga a los 90 días con fn_marca_rechazada_purgar, el único camino de borrado (excepción deliberada '
  'a la inmutabilidad de las bitácoras: la garantía es de privilegios, no de triggers).';
COMMENT ON COLUMN tiempo.marca_rechazada.terminal_id IS 'FK a tiempo.terminal(id) (surrogate, no la serie).';
COMMENT ON COLUMN tiempo.marca_rechazada.evento_id IS
  'evento_id que mandó el Pi, si pudo leerse como uuid; NULL si el evento venía mal formado. Con '
  'terminal_id es único: un reintento no duplica la fila (ON CONFLICT DO NOTHING).';
COMMENT ON COLUMN tiempo.marca_rechazada.employee_no IS
  'employee_no del evento, sólo si es un entero de hasta 8 dígitos; NULL si no. No se resuelve a persona.';
COMMENT ON COLUMN tiempo.marca_rechazada.secuencia_local IS 'secuencia_local del evento, sólo si es un entero válido.';
COMMENT ON COLUMN tiempo.marca_rechazada.momento_dispositivo IS 'momento_dispositivo del evento, sólo si se pudo leer.';
COMMENT ON COLUMN tiempo.marca_rechazada.desfase_local IS 'desfase_local del evento, sólo si cumple el formato ±HH:MM.';
COMMENT ON COLUMN tiempo.marca_rechazada.estado_reloj IS 'estado_reloj del evento, sólo si es uno de los 3 valores válidos.';
COMMENT ON COLUMN tiempo.marca_rechazada.codigo IS
  'Código del rechazo, de lista cerrada: forma_invalida, no_enrolado, secuencia_duplicada, '
  'secuencia_fuera_de_rango, conflicto_evento (SCJ-CDT-01 §IX.6).';
COMMENT ON COLUMN tiempo.marca_rechazada.creada_en IS 'Cuándo se registró el rechazo. Base de la retención.';

ALTER TABLE tiempo.marca_rechazada ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.marca_rechazada FROM anon, authenticated, service_role;
-- B5 (security): service_role NO tiene INSERT: la única escritura es fn_terminal_rechazo_registrar
-- (SECURITY DEFINER, corre como dueño), así nadie puede sembrar evidencia falsa desde la API.
GRANT SELECT ON tiempo.marca_rechazada TO authenticated, service_role;  -- sin INSERT, UPDATE, DELETE ni TRUNCATE

CREATE POLICY marca_rechazada_select_lectura ON tiempo.marca_rechazada
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo()
    AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
         OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))
  );

REVOKE ALL ON SEQUENCE tiempo.marca_rechazada_id_seq FROM anon, authenticated, service_role;

-- ============================================================================
-- 2) fn_terminal_rechazo_registrar -- reemplaza la versión de 83_*.sql (sólo log). CREATE OR REPLACE
-- repite SECURITY DEFINER y SET search_path (no se heredan; la función no tiene ningún ALTER
-- FUNCTION previo, verificado por grep). Cada campo del evento se lee de forma defensiva: sólo se
-- guarda lo que cumple su formato, el resto queda NULL; nunca texto libre del evento. Idempotente por
-- (terminal_id, evento_id). Tope de filas por terminal en las últimas 24 h: pasado el tope sólo avisa.
-- No debe fallar nunca hacia el RPC de marcas (éste además la llama dentro de un bloque con handler).
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
  RAISE WARNING 'marca_rechazada terminal_id=% codigo=% evento_id=% employee_no=%',
    p_terminal_id,
    left(COALESCE(p_codigo, '-'), 30),
    left(regexp_replace(COALESCE(p_evento->>'evento_id', '-'), '[^0-9a-fA-F-]', '?', 'g'), 40),
    left(regexp_replace(COALESCE(p_evento->>'employee_no', '-'), '[^0-9]', '?', 'g'), 12);

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

COMMENT ON FUNCTION tiempo.fn_terminal_rechazo_registrar(bigint, jsonb, text) IS
  'Interna (SCJ-DEC-12 §6). Guarda en tiempo.marca_rechazada la evidencia de un rechazo definitivo de '
  'fn_marca_terminal_registrar, leyendo cada campo del evento de forma defensiva (sólo lo que cumple su '
  'formato). Tope de 5 000 filas por terminal en 24 h. Sin EXECUTE para la API. Al reescribirla repetir '
  'SECURITY DEFINER y SET search_path.';

-- ============================================================================
-- 3) fn_marca_rechazada_purgar -- ÚNICO camino de borrado de marca_rechazada. Borra lo anterior a
-- p_dias días (por defecto 90; mínimo 7, para que un argumento descuidado no vacíe la evidencia) y
-- devuelve cuántas filas borró. La llama el scheduler del backend con service_role.
-- ============================================================================

CREATE FUNCTION tiempo.fn_marca_rechazada_purgar(p_dias integer DEFAULT 90)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_retencion_minima_dias  constant integer := 7;
  v_n  integer;
BEGIN
  IF p_dias IS NULL OR p_dias < c_retencion_minima_dias THEN
    RAISE EXCEPTION 'la retención mínima es de % días', c_retencion_minima_dias
      USING ERRCODE = '22023', HINT = 'retencion_invalida';
  END IF;

  DELETE FROM tiempo.marca_rechazada r WHERE r.creada_en < now() - make_interval(days => p_dias);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_rechazada_purgar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_marca_rechazada_purgar(integer) TO service_role;

COMMENT ON FUNCTION tiempo.fn_marca_rechazada_purgar(integer) IS
  'SCJ-DEC-12 §6. Único camino de borrado de tiempo.marca_rechazada: elimina las filas con más de p_dias días '
  '(por defecto 90, mínimo 7) y devuelve cuántas. SECURITY DEFINER, search_path fijo, EXECUTE sólo '
  'service_role (job del scheduler).';
