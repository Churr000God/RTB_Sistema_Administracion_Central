-- 94_tiempo_terminal_huella_evidencia.sql
-- Evidencia de huella SIN conteo (decisión del usuario, 9-oct-2026): la terminal Hikvision V1.3.0 no expone el conteo de huellas
-- (numOfFP), así que una alta en 'esperando_huella' no puede pasar a 'activo' por el camino original (huella_capturada con conteo 1-10). Este
-- archivo agrega las DOS vías que la reemplazan:
--   C) 'huella_confirmada_manual': una persona con terminal_usuario_edicion (RH, Gerente General, TI) declara en la web que la huella quedó
--      enrolada en el menú del aparato. Origen web, autor = auth.uid(), nota obligatoria (D5).
--   B) 'huella_inferida': la PRIMERA marca verificada por huella de ese empleado (la registra fn_marca_terminal_registrar, 95_) activa la alta.
--      Origen terminal, sin autor. Este archivo deja el esquema y el trigger listos; la lógica en el RPC de marcas es 95_.
-- Ninguna vía guarda plantillas ni conteo: huellas_capturadas queda en 0 = "enrolada, conteo desconocido". Lo que distingue el origen del dato es la
-- columna nueva tiempo.terminal_usuario.huella_evidencia ('conteo' | 'inferida' | 'manual').
--
-- Diseño revisado por security (9-oct-2026): M1 (95_), M2 (aquí: validación de la marca), M3 (backend/frontend dejan de leer 0 como "sin huellas"
-- ANTES de activar esto), y las decisiones D1 (reusar terminal_usuario_edicion: NO hay permiso nuevo, 53 permisos), D2 (cuatro ojos) y D5 (nota)
-- aisladas en c_cuatro_ojos / c_nota_min_manual dentro de fn_bitacora_terminal_usuario_aplica (bloque "DECISIONES AJUSTABLES").
--
-- APLICAR con `psql --single-transaction -f 94_*.sql` (o confirmar con `SELECT txid_current(); SELECT txid_current();` que el SQL Editor es una sola
-- transacción). El archivo NO lleva BEGIN/COMMIT (el ensayo lo incluye dentro de su propio BEGIN … ROLLBACK). Depende de 80_/81_/85_/88_/90_/92_.
--
-- Qué hace:
--   1) tiempo.terminal_usuario.huella_evidencia varchar(10) NULL, CALCULADA por el trigger. CHECK de valores y CHECK de coherencia con el conteo
--      (evidencia = 'conteo' <=> huellas_capturadas > 0). Backfill: las altas con conteo existente pasan a 'conteo'. Sin GRANT de escritura de la
--      columna a nadie (la tabla sólo tiene SELECT para authenticated/service_role; REVOKE explícito de UPDATE/INSERT de columna).
--      Monótona por construcción: sólo 'huella_capturada' la sube a 'conteo'; 'inferida' y 'manual' sólo nacen desde esperando_huella (evidencia NULL).
--   2) bitacora_movimiento_terminal_usuario: tipo_movimiento varchar(20) -> varchar(30) ('huella_confirmada_manual' mide 24); tipos nuevos en ck_..._tipo; ck_..._origen_tipo (origen web <=> tipo en {asignado, baja_solicitada,
--      reconsentido, huella_confirmada_manual}); columna marca_id (FK a tiempo.marca, ON DELETE NO ACTION: una marca nunca se borra y mientras la
--      evidencia la cite, no podría); CHECK (marca_id IS NOT NULL) = (tipo = 'huella_inferida'); índice único parcial sobre marca_id (una marca
--      sirve de evidencia una sola vez). ck_..._huellas NO cambia: los tipos nuevos caen en "cualquier otro => huellas NULL". ck_..._consentimiento
--      NO cambia: los tipos nuevos llevan consentimiento_id NULL.
--   3) Policy bitacora_terminal_usuario_insert_web (DROP + CREATE): se agrega 'huella_confirmada_manual'. 'huella_inferida' NO entra: ningún humano
--      puede insertarla (42501), sólo service_role/dueño.
--   4) fn_bitacora_terminal_usuario_aplica (CREATE OR REPLACE desde la definición vigente de 88_): ramas nuevas y huella_evidencia. Diff literal contra
--      88_ en db/ensayos/diff_94_trigger.diff.
--   5) fn_terminal_baja_por_caducidad (CREATE OR REPLACE desde 85_): el NOT EXISTS considera las tres evidencias y la re-lectura de cada alta pasa a
--      FOR UPDATE SKIP LOCKED (R1 de security): la caducidad nunca espera ni cierra ciclos con una activación o un movimiento del Pi; si la alta
--      está tomada la pospone a la siguiente corrida (posponer una baja es inocuo).
--   6) fn_terminal_anomalias (CREATE OR REPLACE desde 90_): tres categorías nuevas (huellas_inferidas_exceso, inferida_sin_marcas,
--      asignador_confirmador). Las muestra el backend (pendiente en backend/app/anomalias_terminal.py). OJO: huellas_inferidas_exceso es
--      ESPERADO el primer día de puesta en marcha (varias altas se activan a la vez); la pantalla y la documentación deben decirlo.
--
-- Consentimiento biométrico: NINGUNA de las dos vías lo elude. El consentimiento vigente se exige en 'asignado' (SCJ16) y queda ligado a la alta
-- (terminal_usuario.consentimiento_id); 'esperando_huella' sólo existe si hubo un 'asignado' con esa versión. Las ramas nuevas operan SOBRE esa alta,
-- no crean ni cambian consentimiento_id, y el reconsentimiento pendiente no bloquea marcas ni activaciones (SCJ-PRO-15 §VIII).
--
-- Una confirmación equivocada NO se "desconfirma": la bitácora es inmutable y 'activo' no vuelve a 'esperando_huella'. El remedio es pedir la baja
-- (baja_solicitada: el puente borra el usuario y sus huellas) y asignar de nuevo (employee_no nuevo, consentimiento vigente).
--
-- Códigos de error (nuevos HINT, ERRCODE existentes): SCJ11 transicion_invalida (estado de origen incorrecto); SCJ12 auto_confirmacion_huella_prohibida,
-- misma_persona_que_asigno (sólo si c_cuatro_ojos), nota_requerida, marca_no_corresponde. El backend los mapea sin mostrar texto de la base.
--
-- Inventario de RLS/privilegios de este archivo (regla de CLAUDE.md):
--   - Sin tablas, secuencias ni permisos (personas.permiso) nuevos. Policies: 1 reemplazada (misma cantidad: 76 en total).
--   - Columnas nuevas: terminal_usuario.huella_evidencia (SELECT por el GRANT de tabla; sin escritura para nadie salvo el trigger SECURITY DEFINER)
--     y bitacora.marca_id (INSERT por el GRANT de tabla, pero sólo service_role/dueño pueden insertar origen terminal: la policy web exige
--     origen web y un tipo cuya fila no admite marca_id por el CHECK).
--   - Funciones (todas conservan su ACL, repetida aquí): fn_bitacora_terminal_usuario_aplica SECURITY DEFINER, search_path = tiempo, personas,
--     pg_temp, sin EXECUTE para nadie (trigger); fn_terminal_baja_por_caducidad SECURITY DEFINER, mismo search_path, EXECUTE sólo service_role;
--     fn_terminal_anomalias SECURITY INVOKER STABLE, search_path = tiempo, pg_temp, EXECUTE sólo service_role.
--
-- Locks (sin ciclos): el trigger toma la alta FOR UPDATE (como siempre); 'huella_inferida' además lee la marca y la terminal sin lock; no toma
-- el advisory lock de marcas ni el lock de la tabla de consentimiento. La caducidad usa SKIP LOCKED (nunca espera), así que no puede cerrar un ciclo
-- con una activación del RPC de marcas (que retiene las altas que activó en el lote) ni con un movimiento del Pi.
-- R2: la rama 'huella_inferida' se rechaza al principio del trigger (antes de leer la alta) si el origen no es terminal, hay autor o el llamador es
-- anon/authenticated (SCJ12 marca_no_corresponde), de modo que un humano no obtiene ningún dato del estado de la alta.
--
-- REVERSA. ANTES de cualquier fila con los tipos nuevos (la bitácora es inmutable y los CHECK se revalidan: después de la primera fila ya no se
-- pueden quitar los tipos ni la columna sin perder datos):
--   DROP INDEX tiempo.uq_bitacora_terminal_usuario_marca;
--   ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
--     DROP CONSTRAINT ck_bitacora_terminal_usuario_marca, DROP CONSTRAINT ck_bitacora_terminal_usuario_tipo,   -- (tipo_movimiento queda varchar(30): ensanchar es inocuo)
--     DROP CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo, DROP COLUMN marca_id;
--   ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
--     ADD CONSTRAINT ck_bitacora_terminal_usuario_tipo CHECK (tipo_movimiento IN ('asignado','usuario_creado','huella_capturada','baja_solicitada','baja_confirmada','error','reconsentido')),
--     ADD CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo CHECK ((origen = 'web') = (tipo_movimiento IN ('asignado','baja_solicitada','reconsentido')));
--   ALTER TABLE tiempo.terminal_usuario DROP CONSTRAINT ck_terminal_usuario_evidencia_conteo, DROP CONSTRAINT ck_terminal_usuario_huella_evidencia, DROP COLUMN huella_evidencia;
--   -- y CREATE OR REPLACE de las 3 funciones con los cuerpos de 88_ / 85_ / 90_ (copias literales en db/ensayos/vigente_94_*.sql, repitiendo
--   -- SECURITY DEFINER/INVOKER, SET search_path y REVOKE/GRANT), y la policy bitacora_terminal_usuario_insert_web de 88_ (sin el tipo nuevo).
-- DESPUÉS de que existan filas con los tipos nuevos: NO borrar columnas ni constraints. "Desactivar": restaurar las 3 funciones y la policy a las
-- versiones previas (nadie puede volver a insertar los tipos nuevos; quedan inertes en el esquema) y documentar. Nunca desactivar triggers.

-- ============================================================================
-- 1) tiempo.terminal_usuario.huella_evidencia
-- ============================================================================

ALTER TABLE tiempo.terminal_usuario ADD COLUMN huella_evidencia varchar(10);

UPDATE tiempo.terminal_usuario SET huella_evidencia = 'conteo' WHERE huellas_capturadas > 0;

ALTER TABLE tiempo.terminal_usuario
  ADD CONSTRAINT ck_terminal_usuario_huella_evidencia CHECK (
    huella_evidencia IS NULL OR huella_evidencia IN ('conteo', 'inferida', 'manual')
  ),
  ADD CONSTRAINT ck_terminal_usuario_evidencia_conteo CHECK (
    COALESCE(huella_evidencia = 'conteo', false) = (huellas_capturadas > 0)
  );

REVOKE INSERT (huella_evidencia), UPDATE (huella_evidencia) ON tiempo.terminal_usuario FROM anon, authenticated, service_role;

COMMENT ON COLUMN tiempo.terminal_usuario.huella_evidencia IS
  '[CALCULADO] Cómo se supo que la huella está enrolada: conteo (el aparato reportó el conteo, huella_capturada), inferida (primera marca '
  'verificada por huella, huella_inferida) o manual (una persona la confirmó en la web, huella_confirmada_manual). NULL mientras no hay '
  'evidencia. Sólo la fija el trigger; sólo sube (conteo > inferida > manual). huellas_capturadas = 0 con estado activo significa "enrolada, '
  'conteo desconocido": no leer 0 como "sin huellas".';

-- ============================================================================
-- 2) Bitácora: tipos nuevos, marca_id, unicidad de la evidencia
-- ============================================================================

-- La policy de INSERT web referencia tipo_movimiento: Postgres no deja cambiar el tipo de una columna usada en una policy, así que se suelta primero
-- (se recrea en la sección 3). Entre el DROP y el CREATE no hay ningún INSERT posible: todo el archivo corre en una sola transacción.
DROP POLICY bitacora_terminal_usuario_insert_web ON tiempo.bitacora_movimiento_terminal_usuario;

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  DROP CONSTRAINT ck_bitacora_terminal_usuario_tipo,
  DROP CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo;

-- 'huella_confirmada_manual' mide 24 caracteres y la columna era varchar(20) (hallazgo del ensayo_94: 22001). Ensanchar un varchar no reescribe la tabla.
ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario ALTER COLUMN tipo_movimiento TYPE varchar(30);

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  ADD COLUMN marca_id bigint REFERENCES tiempo.marca (id) ON DELETE NO ACTION;

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  ADD CONSTRAINT ck_bitacora_terminal_usuario_tipo CHECK (
    tipo_movimiento IN (
      'asignado', 'usuario_creado', 'huella_capturada',
      'baja_solicitada', 'baja_confirmada', 'error', 'reconsentido',
      'huella_confirmada_manual', 'huella_inferida'
    )
  ),
  -- origen='web' si y sólo si el movimiento lo inicia una persona desde la web. 'huella_inferida' es origen terminal.
  ADD CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo CHECK (
    (origen = 'web') = (tipo_movimiento IN ('asignado', 'baja_solicitada', 'reconsentido', 'huella_confirmada_manual'))
  ),
  ADD CONSTRAINT ck_bitacora_terminal_usuario_marca CHECK (
    (marca_id IS NOT NULL) = (tipo_movimiento = 'huella_inferida')
  );

CREATE UNIQUE INDEX uq_bitacora_terminal_usuario_marca
  ON tiempo.bitacora_movimiento_terminal_usuario (marca_id) WHERE marca_id IS NOT NULL;

COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.marca_id IS
  'Marca (tiempo.marca) que sirvió de evidencia en un huella_inferida; NULL en los demás tipos. FK sin borrado en cascada (la marca es inmutable). '
  'Una marca sólo puede servir de evidencia una vez (índice único parcial).';

-- ============================================================================
-- 3) Policy de INSERT humano: se agrega huella_confirmada_manual (huella_inferida NO)
-- ============================================================================

CREATE POLICY bitacora_terminal_usuario_insert_web
  ON tiempo.bitacora_movimiento_terminal_usuario
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion')
    AND origen = 'web'
    AND tipo_movimiento IN ('asignado', 'baja_solicitada', 'reconsentido', 'huella_confirmada_manual')
    AND registrado_por = auth.uid()
  );

-- ============================================================================
-- 4) Trigger de transiciones (desde la definición vigente de 88_)
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
  v_consent      bigint;
  v_vigente_id   bigint;
  v_vigente_ver  integer;
  v_usuario_creado_en timestamptz;
  v_evidencia    varchar(10);
  v_marca        tiempo.marca%ROWTYPE;
  v_serie        varchar(32);
  v_asigno       uuid;
  v_nota         text;
  -- ======================= DECISIONES AJUSTABLES (94_) =======================
  -- D2 (cuatro ojos): si es true, quien confirma la huella a mano no puede ser quien hizo el 'asignado' de esa alta (salvo el
  -- administrador genérico). Por omisión false: la variante barata es la alerta de anomalías 'asignador_confirmador'.
  c_cuatro_ojos      constant boolean := false;
  -- D5 (nota): caracteres mínimos (ya saneados y sin espacios en los extremos) de la nota en 'huella_confirmada_manual'.
  -- 0 = nota opcional. En 'huella_inferida' no hay nota: el detalle es fijo.
  c_nota_min_manual  constant integer := 10;
  -- ===========================================================================
BEGIN
  -- ---- Filtro de autorización (88_, M1 de security) ---------------------------------------
  -- Este trigger es SECURITY DEFINER y corre ANTES del WITH CHECK de la RLS de INSERT. Un llamador de la API (rol anon/authenticated)
  -- que NO sea una persona activa con terminal_usuario_edicion, o cuyo movimiento no sea web, o sin sub, no debe obtener de aquí errores
  -- ni efectos (oráculo de altas/personas/terminales/versiones, nextval, fila viva, locks): se devuelve NEW sin hacer nada y la RLS
  -- responde 42501. El Pi (service_role) y el dueño no pasan por aquí (auth.role() distinto).
  IF auth.role() IN ('anon', 'authenticated')
     AND (auth.uid() IS NULL
          OR NEW.origen IS DISTINCT FROM 'web'
          OR NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))) THEN
    RETURN NEW;
  END IF;

  -- ---- huella_inferida: rechazo PREVIO a leer la alta (R2 de security, cierra el oraculo minimo de SCJ11/SCJ12) --------------
  -- Solo fn_marca_terminal_registrar (95_), como dueno/service_role, origen terminal y sin autor, puede escribir este tipo. A un llamador de la API
  -- (anon/authenticated) o a cualquier otro origen se le contesta SIEMPRE lo mismo, sin tocar ni bloquear la alta y sin revelar su estado.
  IF NEW.tipo_movimiento = 'huella_inferida'
     AND (NEW.origen IS DISTINCT FROM 'terminal' OR NEW.registrado_por IS NOT NULL OR auth.role() IN ('anon', 'authenticated')) THEN
    RAISE EXCEPTION 'La marca no corresponde a esta alta o ya se usó como evidencia'
      USING ERRCODE = 'SCJ12', HINT = 'marca_no_corresponde';
  END IF;

  -- ---- asignado: crea la fila viva -------------------------------------------------------
  IF NEW.tipo_movimiento = 'asignado' THEN
    IF NEW.terminal_usuario_id IS NOT NULL OR NEW.employee_no IS NOT NULL THEN
      RAISE EXCEPTION
        'En "asignado" terminal_usuario_id y employee_no los asigna el servidor; deben llegar NULL'
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;

    -- Auto-asignación prohibida salvo el administrador genérico (decisión del usuario 2026-10-06; antes sólo la aplicaba el backend).
    -- Antes de cualquier efecto. Sólo para llamadores de la API (con sub): el dueño y service_role no tienen "propia persona".
    -- El actor sale de NEW.registrado_por (la policy lo ata a auth.uid()), no del contexto de la sesión.
    IF NEW.registrado_por IS NOT NULL
       AND NEW.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes asignarte a ti mismo a la terminal; la asigna otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_asignacion_prohibida';
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

    -- Consentimiento (88_): debe ser la versión VIGENTE. LOCK ROW EXCLUSIVE (compatible entre asignaciones) choca con el
    -- SHARE ROW EXCLUSIVE de fn_terminal_consentimiento_publicar: si hay una publicación en curso esta asignación espera a
    -- que termine y entonces lee la versión nueva (el lock va ANTES del SELECT). Un FOR SHARE de fila no bastaría: no choca con
    -- un INSERT de versión nueva. Antes del nextval.
    IF NEW.consentimiento_id IS NULL THEN
      RAISE EXCEPTION 'La asignación exige la versión del texto de consentimiento'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_requerido';
    END IF;
    LOCK TABLE tiempo.terminal_consentimiento IN ROW EXCLUSIVE MODE;
    SELECT c.id, c.version INTO v_vigente_id, v_vigente_ver
    FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
    IF v_vigente_id IS DISTINCT FROM NEW.consentimiento_id THEN
      RAISE EXCEPTION 'El texto de consentimiento cambió: la versión enviada ya no es la vigente'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_desactualizado';
    END IF;
    -- Evidencia fija: el detalle del 'asignado' lo pone SIEMPRE la base (nunca NULL ni texto del cliente).
    NEW.detalle := 'consentimiento y aviso de privacidad recabados: versión ' || v_vigente_ver;

    INSERT INTO tiempo.terminal_usuario (terminal_id, persona_id, employee_no, estado, consentimiento_id)
    VALUES (NEW.terminal_id, NEW.persona_id, nextval('tiempo.seq_terminal_employee_no'),
            'pendiente_alta', NEW.consentimiento_id)
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
  v_error   := NULL;  -- todo movimiento válido distinto de 'error' y de 'reconsentido' limpia el último error
  v_consent := v_vivo.consentimiento_id;
  v_usuario_creado_en := v_vivo.usuario_creado_en;
  v_evidencia := v_vivo.huella_evidencia;   -- 94_: sólo sube (conteo > inferida > manual); ver cada rama

  IF NEW.tipo_movimiento = 'usuario_creado' THEN
    IF v_vivo.estado IS DISTINCT FROM 'pendiente_alta' THEN
      RAISE EXCEPTION 'usuario_creado exige estado pendiente_alta (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado := 'esperando_huella';
    v_usuario_creado_en := NEW.creado_en;   -- 88_: cuándo se creó el usuario en el aparato (plazo de caducidad)

  ELSIF NEW.tipo_movimiento = 'huella_capturada' THEN
    IF v_vivo.estado NOT IN ('esperando_huella', 'activo') THEN
      RAISE EXCEPTION 'huella_capturada exige estado esperando_huella o activo (estado actual: %)',
        v_vivo.estado USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_estado  := 'activo';
    v_huellas := NEW.huellas_capturadas;
    v_evidencia := 'conteo';   -- 94_: el conteo del aparato es la evidencia más fuerte; sustituye a 'inferida'/'manual'

  ELSIF NEW.tipo_movimiento = 'huella_confirmada_manual' THEN
    -- 94_ (C): una persona con terminal_usuario_edicion declara que la huella quedó enrolada en el aparato. Sin conteo
    -- (huellas_capturadas no cambia) y sin tocar el consentimiento: el de 'asignado' sigue ligado a la alta (consentimiento_id).
    IF v_vivo.estado IS DISTINCT FROM 'esperando_huella' THEN
      RAISE EXCEPTION 'huella_confirmada_manual exige estado esperando_huella (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    -- Nadie confirma la huella de su PROPIA alta, salvo el administrador genérico (misma regla que auto-asignación y
    -- auto-reconsentimiento). El actor sale de NEW.registrado_por (la policy lo ata a auth.uid()).
    IF NEW.registrado_por IS NOT NULL
       AND v_vivo.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes confirmar tu propia huella; la confirma otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_confirmacion_huella_prohibida';
    END IF;
    -- [D2] Cuatro ojos (apagado por omisión, ver c_cuatro_ojos).
    IF c_cuatro_ojos AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      SELECT a.registrado_por INTO v_asigno
      FROM tiempo.bitacora_movimiento_terminal_usuario a
      WHERE a.terminal_usuario_id = v_vivo.id AND a.tipo_movimiento = 'asignado'
      ORDER BY a.id LIMIT 1;
      IF v_asigno IS NOT DISTINCT FROM NEW.registrado_por THEN
        RAISE EXCEPTION 'Quien asignó la alta no puede confirmar su huella; la confirma otra persona con permiso'
          USING ERRCODE = 'SCJ12', HINT = 'misma_persona_que_asigno';
      END IF;
    END IF;
    -- [D5] Nota. El detalle ya llega saneado (trigger a0_ de 92_: sin invisibles ni separadores de línea).
    v_nota := btrim(COALESCE(NEW.detalle, ''));
    IF char_length(v_nota) < c_nota_min_manual THEN
      RAISE EXCEPTION 'La confirmación manual exige una nota de al menos % caracteres', c_nota_min_manual
        USING ERRCODE = 'SCJ12', HINT = 'nota_requerida';
    END IF;
    NEW.detalle := NULLIF(v_nota, '');
    v_estado    := 'activo';
    v_evidencia := 'manual';

  ELSIF NEW.tipo_movimiento = 'huella_inferida' THEN
    -- 94_ (B): sólo la escribe fn_marca_terminal_registrar (95_) como dueño/service_role, nunca un humano (la policy no deja
    -- insertar este tipo). La evidencia es UNA marca de la propia terminal y de la propia persona, recibida después de que
    -- se creó el usuario en el aparato, y usada una sola vez.
    IF v_vivo.estado IS DISTINCT FROM 'esperando_huella' THEN
      RAISE EXCEPTION 'huella_inferida exige estado esperando_huella (estado actual: %)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    SELECT t.terminal_id INTO v_serie FROM tiempo.terminal t WHERE t.id = v_vivo.terminal_id;
    SELECT m.* INTO v_marca FROM tiempo.marca m WHERE m.id = NEW.marca_id;
    IF NEW.marca_id IS NULL OR NOT FOUND
       OR v_marca.origen IS DISTINCT FROM 'terminal'
       OR v_marca.terminal_id IS DISTINCT FROM v_serie
       OR v_marca.persona_id IS DISTINCT FROM v_vivo.persona_id
       OR v_vivo.usuario_creado_en IS NULL
       OR v_marca.momento_recepcion < v_vivo.usuario_creado_en
       OR EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario u WHERE u.marca_id = NEW.marca_id) THEN
      RAISE EXCEPTION 'La marca no corresponde a esta alta o ya se usó como evidencia'
        USING ERRCODE = 'SCJ12', HINT = 'marca_no_corresponde';
    END IF;
    NEW.detalle := 'primera marca verificada por huella';   -- fijo: ningún texto del Pi
    v_estado    := 'activo';
    v_evidencia := 'inferida';

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

  ELSIF NEW.tipo_movimiento = 'reconsentido' THEN
    -- 88_: RH registra que la persona aceptó la versión vigente. No cambia estado ni huellas, no reenrola nada y NO limpia
    -- el último error (se conserva error_detalle). Estados donde aplica: los mismos del reconsentimiento pendiente.
    -- Nadie registra el reconsentimiento de su PROPIA alta, salvo el administrador genérico (misma regla y excepción que la
    -- auto-asignación; decisión del usuario 2026-10-08). Pedir la propia baja sigue permitido (no pasa por aquí).
    IF NEW.registrado_por IS NOT NULL
       AND v_vivo.persona_id IS NOT DISTINCT FROM personas.fn_persona_de_usuario(NEW.registrado_por)
       AND NOT personas.fn_usuario_es_administrador_generico(NEW.registrado_por) THEN
      RAISE EXCEPTION 'No puedes registrar tu propio reconsentimiento; lo registra otra persona con permiso'
        USING ERRCODE = 'SCJ12', HINT = 'auto_reconsentimiento_prohibido';
    END IF;
    IF v_vivo.estado NOT IN ('pendiente_alta', 'esperando_huella', 'activo') THEN
      RAISE EXCEPTION 'reconsentido no aplica en estado % (la alta ya se está retirando)', v_vivo.estado
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    IF NEW.consentimiento_id IS NULL THEN
      RAISE EXCEPTION 'El reconsentimiento exige la versión del texto de consentimiento'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_requerido';
    END IF;
    LOCK TABLE tiempo.terminal_consentimiento IN ROW EXCLUSIVE MODE;
    SELECT c.id, c.version INTO v_vigente_id, v_vigente_ver
    FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
    IF v_vigente_id IS DISTINCT FROM NEW.consentimiento_id THEN
      RAISE EXCEPTION 'El texto de consentimiento cambió: la versión enviada ya no es la vigente'
        USING ERRCODE = 'SCJ16', HINT = 'consentimiento_desactualizado';
    END IF;
    NEW.detalle := 'reconsentimiento recabado: versión ' || v_vigente_ver;
    IF v_vivo.consentimiento_id = NEW.consentimiento_id THEN
      RAISE EXCEPTION 'La alta % ya tiene aceptada esa versión del texto', v_vivo.id
        USING ERRCODE = 'SCJ11', HINT = 'transicion_invalida';
    END IF;
    v_consent := NEW.consentimiento_id;
    v_error   := v_vivo.error_detalle;
  END IF;

  UPDATE tiempo.terminal_usuario
  SET estado = v_estado,
      huellas_capturadas = v_huellas,
      huella_evidencia = v_evidencia,
      error_detalle = v_error,
      consentimiento_id = v_consent,
      usuario_creado_en = v_usuario_creado_en,
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
  'Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] desde cada fila de la bitácora (SCJ-DEC-11). '
  'SECURITY DEFINER SET search_path = tiempo, personas, pg_temp: único escritor de terminal_usuario. SCJ11 = transición inválida o fila viva '
  'incoherente; SCJ12 = alta duplicada, persona no elegible, terminal no válida, auto-asignación/auto-reconsentimiento/auto-confirmación, nota '
  'requerida o marca que no corresponde (94_); SCJ16 = versión del texto de consentimiento ausente o desactualizada (88_); cada raise trae HINT '
  'estable. huella_confirmada_manual y huella_inferida (94_) activan una alta en esperando_huella sin conteo y fijan huella_evidencia. En ''asignado'' '
  'la terminal se toma FOR SHARE y la tabla de versiones se bloquea en ROW EXCLUSIVE. ''reconsentido'' no cambia estado ni huellas. Al reescribirla '
  'con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';

-- ============================================================================
-- 5) Caducidad: las tres evidencias impiden la baja automática (desde la definición vigente de 85_)
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_baja_por_caducidad(p_horas integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_horas_minimas  constant integer := 4;   -- piso: nunca caducar con menos de 4 horas (ver cabecera)
  c_tope_bajas     constant integer := 50;  -- máximo de bajas por llamada; el resto queda para la siguiente corrida
  v_n              integer := 0;
  rec              record;
BEGIN
  IF p_horas IS NULL OR p_horas < c_horas_minimas THEN
    RAISE EXCEPTION 'las horas de caducidad deben ser al menos %', c_horas_minimas
      USING ERRCODE = '22023', HINT = 'horas_invalidas';
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no,
           (SELECT a.registrado_por
              FROM tiempo.bitacora_movimiento_terminal_usuario a
             WHERE a.terminal_usuario_id = tu.id AND a.tipo_movimiento = 'asignado'
             ORDER BY a.id
             LIMIT 1) AS autor
    FROM tiempo.terminal_usuario tu
    WHERE tu.estado = 'esperando_huella'
      AND NOT EXISTS (
        SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario h
        WHERE h.terminal_usuario_id = tu.id
          AND h.tipo_movimiento IN ('huella_capturada', 'huella_inferida', 'huella_confirmada_manual'))
      AND (SELECT max(c.creado_en)
             FROM tiempo.bitacora_movimiento_terminal_usuario c
            WHERE c.terminal_usuario_id = tu.id AND c.tipo_movimiento = 'usuario_creado')
          < clock_timestamp() - make_interval(hours => p_horas)
    ORDER BY tu.id
  LOOP
    IF v_n >= c_tope_bajas THEN
      RAISE WARNING 'tope de bajas por corrida alcanzado';
      EXIT;
    END IF;

    IF rec.autor IS NULL THEN
      RAISE WARNING 'fn_terminal_baja_por_caducidad: sin autor derivable para la alta %', rec.id;
      CONTINUE;
    END IF;

    -- Carrera con huella_capturada (ver cabecera): se re-lee la alta FOR UPDATE exigiendo que siga en
    -- esperando_huella; si el Pi ya la pasó a activo, no se le da de baja.
    -- 94_ (R1 de security): SKIP LOCKED. La caducidad NUNCA espera ni cierra ciclos con una activacion (fn_marca_terminal_registrar) ni con un
    -- movimiento del Pi: si otra transaccion tiene la alta, o ya no esta en esperando_huella, se pospone a la siguiente corrida (posponer una baja es inocuo).
    PERFORM 1 FROM tiempo.terminal_usuario t WHERE t.id = rec.id AND t.estado = 'esperando_huella' FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    BEGIN
      INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
        (terminal_usuario_id, terminal_id, persona_id, employee_no,
         tipo_movimiento, detalle, origen, registrado_por)
      VALUES
        (rec.id, rec.terminal_id, rec.persona_id, rec.employee_no,
         'baja_solicitada', 'baja automática: sin huella tras ' || p_horas || ' horas', 'web', rec.autor);
      v_n := v_n + 1;
    EXCEPTION WHEN SQLSTATE 'SCJ11' OR SQLSTATE 'SCJ12' THEN
      NULL;  -- carrera con otro job o con el Pi, o ya hecha: idempotente
    END;
  END LOOP;

  RETURN v_n;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) IS
  'SCJ-DEC-12 §12.7. Emite baja_solicitada (origen web, autor = el del movimiento asignado de la alta, detalle "baja automática: sin huella tras N '
  'horas") de las altas en esperando_huella sin ninguna evidencia de huella (huella_capturada, huella_inferida o huella_confirmada_manual, 94_) '
  'cuyo movimiento usuario_creado tiene más de p_horas horas (por defecto 24, mínimo 4; 22023/horas_invalidas). Máximo 50 bajas por llamada. No '
  'toca pendiente_alta ni activo; re-lee cada alta FOR UPDATE SKIP LOCKED antes de emitir (si una activación o un movimiento la tiene tomada, la pospone a la siguiente corrida). Sin autor derivable no '
  'emite (WARNING). Idempotente (ignora SCJ11/SCJ12). Devuelve cuántas bajas emitió. SECURITY DEFINER, search_path = tiempo, personas, pg_temp.';

-- ============================================================================
-- 6) Tablero de anomalías: tres categorías nuevas (desde la definición vigente de 90_)
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_anomalias(
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
  c_inferidas_dia      constant integer  := 5;                 -- 94_: más de 5 'huella_inferida' en un día local = alerta
  c_manuales_min       constant integer  := 3;                 -- 94_: la mitad-manual sólo cuenta con al menos 3 confirmaciones manuales en el día
  c_sin_marcas_dias    constant interval := interval '7 days'; -- 94_: alta inferida/manual sin ninguna marca más en este plazo
  c_zona               constant text     := 'America/Mexico_City';
  v_serie   varchar;
  v_res     jsonb;
BEGIN
  SELECT t.terminal_id INTO v_serie FROM tiempo.terminal t WHERE t.id = p_terminal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La terminal % no existe', p_terminal_id USING ERRCODE = '22023', HINT = 'terminal_invalida';
  END IF;

  IF p_categoria IS NULL OR p_categoria NOT IN ('marcas_posteriores_a_baja', 'picos_de_tasa', 'huecos_de_secuencia',
                                                'huellas_inferidas_exceso', 'inferida_sin_marcas', 'asignador_confirmador') THEN
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

  ELSIF p_categoria = 'huecos_de_secuencia' THEN
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

  ELSIF p_categoria = 'huellas_inferidas_exceso' THEN
    -- 94_: activaciones por día local de la terminal. Alerta si hubo más de c_inferidas_dia 'huella_inferida' en el día, o si las
    -- confirmaciones MANUALES (>= c_manuales_min) son más de la mitad de las activaciones del día (la vía automática no está
    -- funcionando). Nota: sin conteo del aparato, casi toda activación es inferida o manual, así que "la mitad de las altas del
    -- día" se mide sobre las activaciones, no sobre las altas asignadas.
    WITH act AS (
      SELECT (b.creado_en AT TIME ZONE c_zona)::date AS dia, b.tipo_movimiento
      FROM tiempo.bitacora_movimiento_terminal_usuario b
      WHERE b.terminal_id = p_terminal_id
        AND b.tipo_movimiento IN ('huella_inferida', 'huella_confirmada_manual', 'huella_capturada')
        AND b.creado_en >= p_desde AND b.creado_en <= p_hasta
    ), por_dia AS (
      SELECT dia,
             (count(*) FILTER (WHERE tipo_movimiento = 'huella_inferida'))::integer          AS inferidas,
             (count(*) FILTER (WHERE tipo_movimiento = 'huella_confirmada_manual'))::integer AS manuales,
             count(*)::integer                                                              AS activaciones
      FROM act GROUP BY dia
    ), base AS (
      SELECT dia, inferidas, manuales, activaciones, c_inferidas_dia AS limite_inferidas
      FROM por_dia
      WHERE inferidas > c_inferidas_dia OR (manuales >= c_manuales_min AND manuales * 2 > activaciones)
    ), pag AS (
      SELECT * FROM base ORDER BY dia DESC LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.dia DESC) FROM pag), '[]'::jsonb))
    INTO v_res;

  ELSIF p_categoria = 'inferida_sin_marcas' THEN
    -- 94_: alta activada por inferencia o confirmación manual hace más de 7 días y SIN ninguna marca más de esa persona en la
    -- terminal en los 7 días siguientes a la activación (la marca que sirvió de evidencia no cuenta).
    WITH base AS (
      SELECT tu.id AS terminal_usuario_id, tu.persona_id, tu.huella_evidencia AS evidencia, b.creado_en AS activada_en
      FROM tiempo.terminal_usuario tu
      JOIN tiempo.bitacora_movimiento_terminal_usuario b
        ON b.terminal_usuario_id = tu.id AND b.tipo_movimiento IN ('huella_inferida', 'huella_confirmada_manual')
      WHERE tu.terminal_id = p_terminal_id AND tu.estado = 'activo' AND tu.huella_evidencia IN ('inferida', 'manual')
        AND b.creado_en >= p_desde AND b.creado_en <= p_hasta
        AND b.creado_en <= clock_timestamp() - c_sin_marcas_dias
        AND NOT EXISTS (
          SELECT 1 FROM tiempo.marca m
          WHERE m.persona_id = tu.persona_id AND m.terminal_id = v_serie AND m.origen = 'terminal'
            AND m.momento_recepcion > b.creado_en AND m.momento_recepcion <= b.creado_en + c_sin_marcas_dias
            AND (b.marca_id IS NULL OR m.id <> b.marca_id))
    ), pag AS (
      SELECT * FROM base ORDER BY activada_en DESC, terminal_usuario_id DESC LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.activada_en DESC, pag.terminal_usuario_id DESC) FROM pag), '[]'::jsonb))
    INTO v_res;

  ELSE  -- asignador_confirmador
    -- 94_: confirmaciones manuales hechas por la misma persona que asignó la alta (la variante barata de los cuatro ojos).
    WITH base AS (
      SELECT b.terminal_usuario_id, tu.persona_id, b.creado_en AS confirmada_en, b.registrado_por AS usuario_id
      FROM tiempo.bitacora_movimiento_terminal_usuario b
      JOIN tiempo.terminal_usuario tu ON tu.id = b.terminal_usuario_id
      WHERE b.terminal_id = p_terminal_id AND b.tipo_movimiento = 'huella_confirmada_manual'
        AND b.creado_en >= p_desde AND b.creado_en <= p_hasta
        AND EXISTS (
          SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario a
          WHERE a.terminal_usuario_id = b.terminal_usuario_id AND a.tipo_movimiento = 'asignado'
            AND a.registrado_por = b.registrado_por)
    ), pag AS (
      SELECT * FROM base ORDER BY confirmada_en DESC, terminal_usuario_id DESC LIMIT p_limite OFFSET p_desplazamiento
    )
    SELECT jsonb_build_object(
             'total', (SELECT count(*) FROM base),
             'items', COALESCE((SELECT jsonb_agg(to_jsonb(pag) ORDER BY pag.confirmada_en DESC, pag.terminal_usuario_id DESC) FROM pag), '[]'::jsonb))
    INTO v_res;
  END IF;

  RETURN v_res;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_anomalias(bigint, text, timestamptz, timestamptz, integer, integer) IS
  '90_/94_. Una categoría del tablero de anomalías de una terminal (marcas_posteriores_a_baja | picos_de_tasa | huecos_de_secuencia | '
  'huellas_inferidas_exceso | inferida_sin_marcas | asignador_confirmador) como {total, items} paginado (p_limite 1..200, p_desplazamiento >= 0). '
  'Filtra SIEMPRE por la terminal pedida dentro; devuelve persona_id/usuario_id, nunca nombres (SCJ-FRO-01). Ventana de a lo más 90 días. Umbrales '
  'fijos: 10 marcas/h por persona, 1 000/h por terminal, más de 5 huella_inferida por día (ESPERADO el primer día de puesta en marcha), confirmaciones manuales > la mitad (con al menos 3), '
  '7 días sin marcas tras la activación. SECURITY INVOKER, STABLE, search_path = tiempo, pg_temp; EXECUTE sólo service_role (el backend aplica el gate '
  'de lectura antes). 22023 con HINT: terminal_invalida, categoria_invalida, ventana_invalida, paginacion_invalida.';
