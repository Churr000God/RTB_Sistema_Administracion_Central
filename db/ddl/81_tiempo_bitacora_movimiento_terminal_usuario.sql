-- 81_tiempo_bitacora_movimiento_terminal_usuario.sql
-- Bitácora inmutable de movimientos de enrolamiento en la terminal Hikvision: FUENTE DE VERDAD de
-- tiempo.terminal_usuario (80_*.sql), mismo patrón que bitacora_movimiento_puesto_permiso ->
-- puesto_permiso (23_/24_/28_*.sql). Cada fila insertada acá valida la transición de estado y
-- sincroniza la tabla viva en el mismo statement, vía un trigger BEFORE INSERT SECURITY DEFINER.
--
-- Diferencia deliberada con 24_*.sql: allá el trigger es AFTER INSERT sin SECURITY DEFINER y la
-- tabla viva tiene policies de escritura. Acá el trigger es SECURITY DEFINER y terminal_usuario no
-- tiene NINGUNA policy ni grant de escritura -- así nadie puede mover el estado sin dejar una fila
-- en la bitácora, y no se reabre el hueco del OR en policies de UPDATE (gotcha de 31_*.sql y
-- 70_*.sql). Es BEFORE (no AFTER) porque en 'asignado' el trigger crea la fila viva y completa
-- NEW.terminal_usuario_id / NEW.employee_no antes de que se evalúen NOT NULL y la FK.
--
-- Inmutabilidad en 3 capas (patrón de 23_*.sql, con la capa 1 correcta desde el arranque, sin
-- esperar un 28_*.sql):
--   1. REVOKE ALL a anon/authenticated/service_role y GRANT explícito sólo de SELECT, INSERT. El
--      ALTER DEFAULT PRIVILEGES de 38_tiempo_permisos.sql habría dado UPDATE, DELETE y TRUNCATE.
--   2. RLS sin policies de UPDATE ni DELETE.
--   3. Triggers que abortan y alcanzan también al dueño: BEFORE UPDATE OR DELETE por fila, y
--      BEFORE TRUNCATE por statement (TRUNCATE no dispara los triggers por fila).
--
-- Residual aceptado (lección de 75_*.sql): el dueño/superusuario sigue pudiendo DROP TABLE,
-- DROP TRIGGER o ALTER TABLE ... DISABLE TRIGGER; ninguna bitácora del proyecto lo evita. Y como
-- ningún movimiento es reversible, una fila mal insertada (ej. baja_solicitada por error) NO se
-- puede borrar con ningún rol de la API: se corrige con movimientos posteriores o, en el peor
-- caso, sólo con DISABLE TRIGGER de superusuario.
--
-- Texto libre: detalle tiene CHECK de 500 caracteres. El BACKEND debe sanear y truncar antes de
-- insertar, y nunca meter cuerpos crudos de respuestas ISAPI ni headers.
--
-- Quién inserta qué:
--   origen='web'      asignado, baja_solicitada: RH/TI con terminal_usuario_edicion, caller
--                     humano (policy de abajo; registrado_por atado a auth.uid(), como 68_*.sql).
--   origen='terminal' usuario_creado, huella_capturada, baja_confirmada, error: sólo el backend
--                     con service_role, después de validar el JWT de la terminal (siguiente corte).
--                     authenticated no puede insertarlos (la policy exige origen='web').
--
-- ERRCODE (SCJ10 era el último usado, 69_personas_edicion.sql; SCJ11 y SCJ12 libres, verificado
-- por grep). Cada raise lleva además USING HINT con un token estable para que backend distinga:
--   SCJ11  transición inválida o fila viva incoherente           HINT 'transicion_invalida'
--   SCJ12  alta duplicada                                         HINT 'alta_duplicada'
--          persona no elegible (no existe o no está activa)       HINT 'persona_no_activa'
--          terminal no válida (no existe o no está activa)        HINT 'terminal_no_valida'
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP TABLE tiempo.bitacora_movimiento_terminal_usuario;
--   DROP FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica();
--   DROP FUNCTION tiempo.fn_bitacora_terminal_usuario_inmutable();
--   DROP FUNCTION tiempo.fn_bitacora_terminal_usuario_truncate();
--   -- (los triggers caen con la tabla). Luego revertir 80_*.sql. Nota: aplicada con filas reales,
--   -- el DROP TABLE las destruye -- las bitácoras son inmutables por UPDATE/DELETE, no por DROP.
--
-- Inventario de RLS de este archivo:
--   tiempo.bitacora_movimiento_terminal_usuario  RLS on, 2 policies (SELECT lectura-o-edición,
--   INSERT sólo origen web con edición y autor = caller). Sin policies de UPDATE/DELETE.
--
-- Depende de: 05_personas_estructura.sql (personas.usuario/persona), 80_tiempo_terminal_usuario.sql
-- Justificación: SCJ-DEC-11

CREATE TABLE tiempo.bitacora_movimiento_terminal_usuario (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_usuario_id   bigint NOT NULL REFERENCES tiempo.terminal_usuario (id),
  terminal_id           bigint NOT NULL REFERENCES tiempo.terminal (id),
  persona_id            uuid NOT NULL REFERENCES tiempo.persona (id),
  employee_no           integer NOT NULL,
  tipo_movimiento       varchar(20) NOT NULL,
  huellas_capturadas    smallint,
  detalle               text,
  origen                varchar(10) NOT NULL,
  registrado_por        uuid REFERENCES personas.usuario (auth_user_id),
  creado_en             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bitacora_terminal_usuario_tipo CHECK (
    tipo_movimiento IN (
      'asignado', 'usuario_creado', 'huella_capturada',
      'baja_solicitada', 'baja_confirmada', 'error'
    )
  ),
  CONSTRAINT ck_bitacora_terminal_usuario_origen CHECK (origen IN ('web', 'terminal')),
  -- origen='web' si y sólo si el movimiento lo inicia RH desde la web.
  CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo CHECK (
    (origen = 'web') = (tipo_movimiento IN ('asignado', 'baja_solicitada'))
  ),
  -- Autor obligatorio si y sólo si origen='web' (la terminal no es un usuario de personas.usuario).
  CONSTRAINT ck_bitacora_terminal_usuario_autor CHECK (
    (registrado_por IS NOT NULL) = (origen = 'web')
  ),
  -- Conteo de huellas: obligatorio (1-10) en huella_capturada y ausente en todo lo demás.
  CONSTRAINT ck_bitacora_terminal_usuario_huellas CHECK (
    CASE WHEN tipo_movimiento = 'huella_capturada'
         THEN huellas_capturadas IS NOT NULL AND huellas_capturadas BETWEEN 1 AND 10
         ELSE huellas_capturadas IS NULL
    END
  ),
  -- Un error sin mensaje no sirve de nada en error_detalle.
  CONSTRAINT ck_bitacora_terminal_usuario_error_detalle CHECK (
    tipo_movimiento <> 'error' OR detalle IS NOT NULL
  ),
  CONSTRAINT ck_bitacora_terminal_usuario_detalle_len CHECK (
    detalle IS NULL OR char_length(detalle) <= 500
  )
);

CREATE INDEX ix_bitacora_terminal_usuario_terminal_usuario_id
  ON tiempo.bitacora_movimiento_terminal_usuario (terminal_usuario_id);
CREATE INDEX ix_bitacora_terminal_usuario_terminal_id
  ON tiempo.bitacora_movimiento_terminal_usuario (terminal_id);
CREATE INDEX ix_bitacora_terminal_usuario_persona_id
  ON tiempo.bitacora_movimiento_terminal_usuario (persona_id);
CREATE INDEX ix_bitacora_terminal_usuario_registrado_por
  ON tiempo.bitacora_movimiento_terminal_usuario (registrado_por);

COMMENT ON TABLE tiempo.bitacora_movimiento_terminal_usuario IS
  'Fuente de verdad de tiempo.terminal_usuario (SCJ-DEC-11). Sólo inserción: inmutable en 3 capas, '
  'ver cabecera. trg_bitacora_terminal_usuario_aplica valida la transición y sincroniza la tabla '
  'viva en el mismo INSERT.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.terminal_usuario_id IS
  'Fila viva afectada. En ''asignado'' debe llegar NULL: el trigger crea la fila viva y lo completa. '
  'En el resto es obligatorio.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.terminal_id IS
  'Terminal (tiempo.terminal.id). El trigger exige que coincida con la fila viva.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.persona_id IS
  'Persona afectada. El trigger exige que coincida con la fila viva.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.employee_no IS
  'employeeNo en la terminal. En ''asignado'' debe llegar NULL y lo asigna el trigger desde '
  'seq_terminal_employee_no; en el resto puede llegar NULL (se completa) o igual al de la fila viva.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.tipo_movimiento IS
  'asignado | usuario_creado | huella_capturada | baja_solicitada | baja_confirmada | error. '
  'Tabla de transiciones en fn_bitacora_terminal_usuario_aplica.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.huellas_capturadas IS
  'Total de huellas del usuario tras este movimiento (1-10). Sólo en huella_capturada.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.detalle IS
  'Motivo o mensaje de error (obligatorio en ''error''), máx. 500 caracteres. El backend sanea y '
  'trunca; nunca cuerpos crudos de ISAPI ni headers.';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.origen IS
  'web (RH desde la app) o terminal (reporte del Pi vía backend, service_role).';
COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.registrado_por IS
  'auth_user_id de quien hizo el movimiento web; NULL cuando origen=''terminal''.';

-- ============================================================================
-- Capa 1 y 2: grants mínimos y RLS.
-- ============================================================================

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.bitacora_movimiento_terminal_usuario FROM anon, authenticated, service_role;
GRANT SELECT, INSERT ON tiempo.bitacora_movimiento_terminal_usuario TO authenticated, service_role;

REVOKE ALL ON SEQUENCE tiempo.bitacora_movimiento_terminal_usuario_id_seq
  FROM anon, authenticated, service_role;

CREATE POLICY bitacora_terminal_usuario_select_lectura
  ON tiempo.bitacora_movimiento_terminal_usuario
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo()
    AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
         OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))
  );

-- INSERT humano: sólo los 2 movimientos de origen web, con edición, y autor = el propio caller
-- (anti-suplantación, mismo criterio que 62_*.sql y 68_*.sql). Los movimientos origen='terminal'
-- sólo los inserta service_role (bypassa RLS).
CREATE POLICY bitacora_terminal_usuario_insert_web
  ON tiempo.bitacora_movimiento_terminal_usuario
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion')
    AND origen = 'web'
    AND tipo_movimiento IN ('asignado', 'baja_solicitada')
    AND registrado_por = auth.uid()
  );

-- ============================================================================
-- Capa 3: inmutabilidad por trigger (alcanza también a service_role y al dueño).
-- ============================================================================

CREATE FUNCTION tiempo.fn_bitacora_terminal_usuario_inmutable()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION
    'tiempo.bitacora_movimiento_terminal_usuario es de solo inserción: % no está permitido (fila %)',
    TG_OP, OLD.id;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_terminal_usuario_inmutable
  BEFORE UPDATE OR DELETE ON tiempo.bitacora_movimiento_terminal_usuario
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_bitacora_terminal_usuario_inmutable();

-- TRUNCATE no dispara triggers por fila y a nivel statement no hay OLD: función propia, sin
-- referenciar OLD.
CREATE FUNCTION tiempo.fn_bitacora_terminal_usuario_truncate()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION
    'tiempo.bitacora_movimiento_terminal_usuario es de solo inserción: TRUNCATE no está permitido';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bitacora_terminal_usuario_truncate
  BEFORE TRUNCATE ON tiempo.bitacora_movimiento_terminal_usuario
  FOR EACH STATEMENT
  EXECUTE FUNCTION tiempo.fn_bitacora_terminal_usuario_truncate();

REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_terminal_usuario_inmutable()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_terminal_usuario_truncate()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_inmutable() IS
  'Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role y el dueño. Mismo '
  'patrón que personas.fn_bitacora_puesto_permiso_inmutable() (23_*.sql).';
COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_truncate() IS
  'Aborta TRUNCATE sobre la bitácora (trigger por statement, sin OLD). El dueño aún puede '
  'DROP/DISABLE TRIGGER: residual documentado en la cabecera.';

-- ============================================================================
-- Trigger de aplicación: valida la transición y sincroniza tiempo.terminal_usuario.
--
-- SECURITY DEFINER + search_path fijo: escribe en terminal_usuario (sin grants de escritura para
-- ningún rol de la API) y lee personas.persona (que el caller sólo ve tras pasar
-- fn_caller_activo). No puede llamarse a mano: es función de trigger, y además se le quita el
-- EXECUTE a PUBLIC. Corre con los privilegios de su dueño; los CREATE OR REPLACE futuros deben
-- repetir SECURITY DEFINER y SET search_path (gotcha de CLAUDE.md).
--
-- Transiciones (estado previo -> estado nuevo):
--   asignado          RH/web   terminal activa, ninguna alta no-baja de esa persona en esa
--                              terminal, persona 'activo' en personas.persona
--                              -> pendiente_alta (crea la fila viva)
--   usuario_creado    Pi       pendiente_alta                  -> esperando_huella
--   huella_capturada  Pi       esperando_huella | activo       -> activo, huellas = NEW.huellas
--   baja_solicitada   RH/web   cualquiera salvo pendiente_baja / baja -> pendiente_baja
--   baja_confirmada   Pi       pendiente_baja                  -> baja
--   error             Pi       cualquiera salvo baja           -> sin cambio, llena error_detalle
-- terminal.activa sólo se exige en 'asignado': una terminal dada de baja aún debe poder recibir
-- bajas y reportes del Pi. Todo movimiento válido distinto de 'error' limpia error_detalle.
-- ============================================================================

CREATE FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica()
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

    -- Antes del nextval: una asignación rechazada no debe quemar un employee_no.
    IF NOT EXISTS (
      SELECT 1 FROM tiempo.terminal t WHERE t.id = NEW.terminal_id AND t.activa
    ) THEN
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

CREATE TRIGGER trg_bitacora_terminal_usuario_aplica
  BEFORE INSERT ON tiempo.bitacora_movimiento_terminal_usuario
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica();

COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_aplica() IS
  'Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] '
  'desde cada fila de la bitácora (SCJ-DEC-11). SECURITY DEFINER SET search_path = tiempo, '
  'personas, pg_temp: único escritor de terminal_usuario. SCJ11 = transición inválida o fila viva '
  'incoherente; SCJ12 = alta duplicada, persona no elegible o terminal no válida; cada raise trae '
  'HINT estable. Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';
