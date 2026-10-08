-- 88_tiempo_terminal_consentimiento.sql
-- Texto de consentimiento biométrico VERSIONADO y reconsentimiento de los ya enrolados (SCJ-PRO-15 §IV.7, Paquete 2).
-- Decisiones del usuario (2026-10-08): el texto del consentimiento se edita desde una pantalla del sistema con un
-- permiso de edición que sólo tienen "Gerente o Encargado de TI" y "Gerente General" (RH no); cada alta queda ligada a
-- la versión del texto que se aceptó; una versión desactualizada al asignar se rechaza SIEMPRE; un cambio material de
-- texto obliga a reconsentir a los ya enrolados; el reconsentimiento pendiente NO bloquea marcas (sólo se muestra).
--
-- Orden de aplicación: no depende de cambios del backend (los endpoints de 'asignado' y de configuración aún no existen).
-- APLICAR EN UNA SOLA TRANSACCIÓN (psql --single-transaction / -1; si se pega en el SQL Editor de Supabase, confirmar que ejecuta el
-- script completo como una transacción): la guarda de la sección 0 toma ACCESS EXCLUSIVE sobre terminal_usuario y la bitácora, y ese
-- lock sólo protege los ALTER siguientes mientras la transacción siga abierta. NO se agrega BEGIN/COMMIT al archivo (los ensayos lo incluyen
-- dentro de su propio BEGIN … ROLLBACK). Aplicación recomendada: `psql --single-transaction -f 88_*.sql`. Si se pega en el SQL Editor, confirmar
-- ANTES que es una sola transacción: ejecutar `SELECT txid_current(); SELECT txid_current();` en un mismo envío; si devuelve el MISMO número en
-- las dos, es una transacción.
--
-- Endurecimiento de la revisión de security (2026-10-08):
--   M1  El trigger de la bitácora es SECURITY DEFINER y corre ANTES del WITH CHECK de la RLS de INSERT: sin un filtro inicial, un
--       authenticated SIN terminal_usuario_edicion obtenía como oráculo los errores del trigger (SCJ12 alta_duplicada, persona_no_activa,
--       terminal_no_valida, SCJ16, SCJ11) y efectos (nextval del employee_no, fila viva, locks) aunque la RLS lo rechazara después. Ahora,
--       para quien llega con rol anon/authenticated y NO es una persona activa con terminal_usuario_edicion (o el movimiento no es web, o
--       no hay sub), el trigger devuelve NEW sin hacer nada y la RLS responde 42501 (mismo patrón que 87_). El Pi (service_role) y el
--       dueño no cambian.
--   M2  btrim(texto) sólo quita espacios: '\n\n' pasaba el CHECK y el RPC y dejaba un consentimiento vacío. Ahora CHECK y RPC usan
--       btrim(texto, E' \n').
--   B3  Se quitan (RPC) y se prohíben (CHECK) los caracteres de formato Unicode invisibles o de reordenamiento (U+200B-200F, U+202A-202E,
--       U+2060-2064, U+2066-2069, U+FEFF y, ampliado, U+00AD, U+061C, U+2028-2029 y las etiquetas U+E0000-E007F): un texto legal no puede esconder ni reordenar caracteres. El saneo por líneas ya no usa un marcador
--       temporal que pudiera colisionar con el texto.
--   BAJO-2 (decisión del usuario 2026-10-08): la misma regla y la misma excepción se extienden al RECONSENTIMIENTO: nadie registra el 'reconsentido'
--       de su PROPIA alta salvo el administrador genérico (SCJ12 / auto_reconsentimiento_prohibido en el trigger; en el lote la alta propia se
--       omite con motivo 'alta_propia', o rechaza todo el lote con p_estricto). Pedir la propia baja sigue permitido.
--   Regla de seguridad llevada a la base: AUTO-ASIGNACIÓN PROHIBIDA salvo el administrador genérico (decisión del usuario 2026-10-06,
--       SCJ-PRO-15 §V.3). Antes sólo la aplicaba el backend y quien tuviera terminal_usuario_edicion podía asignarse por PostgREST. Ahora
--       lo impide el trigger (SCJ12 / auto_asignacion_prohibida, antes del nextval) con la excepción de quien ocupa hoy un puesto con
--       es_administrador_generico (personas.fn_usuario_es_administrador_generico, sobre NEW.registrado_por). Se hace en el trigger y no en la policy porque el
--       trigger corre antes de la RLS y así el rechazo no deja efectos.
--
-- Qué hace, en orden:
--   1) Permiso terminal_config_edicion (heredable = false, patrón de 62_/86_), otorgado por bitácora sólo a esos dos
--      puestos. Sin permiso de lectura aparte: ver la pantalla = terminal_usuario_lectura/edicion (mismo gate que
--      Terminales); dentro, editar = terminal_config_edicion.
--   2) Tabla tiempo.terminal_consentimiento: versiones del texto, de sólo inserción (inmutable en 3 capas), con
--      provisional y cambio_material. Sin vigente_hasta: la versión vigente es la de mayor version, no hay hueco ni
--      traslape posibles y no hay columna mutable que cerrar. La escribe sólo fn_terminal_consentimiento_publicar.
--   3) SIEMBRA de la versión 1 (texto provisional del mockup 03, provisional = true, sin autor). No habrá estado "sin
--      texto". Dejar de ser provisional = publicar una versión nueva (provisional = false), que además fuerza
--      cambio_material = true: nadie consintió el texto definitivo.
--   4) Bitácora de enrolamiento: columna consentimiento_id (FK) obligatoria en 'asignado' y 'reconsentido' y prohibida en
--      el resto; tipo de movimiento nuevo 'reconsentido' (origen web); tiempo.terminal_usuario [CALCULADO] gana la misma
--      columna (versión aceptada más reciente de la alta), que fija sólo el trigger.
--   5) fn_bitacora_terminal_usuario_aplica reemplazada (CREATE OR REPLACE, repitiendo SECURITY DEFINER, SET search_path y
--      el FOR SHARE de la terminal de 83_ y, nuevo, un LOCK ROW EXCLUSIVE de la tabla de versiones): 'asignado' y 'reconsentido' exigen la versión vigente (SCJ16); 'reconsentido'
--      no cambia estado ni huellas y conserva error_detalle.
--   6) RPC fn_terminal_consentimiento_publicar (publica una versión nueva), fn_terminal_reconsentimiento_pendiente_ids
--      (definición única de "reconsentimiento pendiente") y fn_terminal_reconsentir (lote para RH, hasta 200 altas).
--
-- ERRCODE nuevo 'SCJ16' (verificado libre por grep en db/, backend/app y frontend/src; el último usado era SCJ15). Un solo
-- código con HINT estable para que el backend distinga el caso sin leer el texto:
--   consentimiento_desactualizado  la versión enviada en 'asignado'/'reconsentido' no es la vigente (backend: 409, mensaje
--                                  fijo "El texto de consentimiento cambió; vuelve a leerlo", y devolver el texto vigente)
--   consentimiento_requerido       'asignado'/'reconsentido' sin consentimiento_id (backend: 422; no debería ocurrir)
-- Otros errores nuevos (códigos estándar, el backend los distingue por HINT):
--   42501 sin_permiso              fn_terminal_consentimiento_publicar sin persona activa o sin terminal_config_edicion
--   22023 texto_invalido           texto vacío o de más de 4000 caracteres
--   22023 nota_invalida            nota de más de 200 caracteres
--   22023 lote_invalido            fn_terminal_reconsentir con arreglo vacío, NULL o de más de 200 altas
--   22023 lote_no_elegible         fn_terminal_reconsentir con p_estricto = true y altas no elegibles (ids en DETAIL; backend: 409)
--   SCJ16 version_base_desactualizada  fn_terminal_consentimiento_publicar con p_base_version distinta de la vigente (publicación concurrente; backend: 409)
-- Mensajes para el backend: SCJ16/consentimiento_desactualizado -> 409; SCJ16/consentimiento_requerido -> 422;
-- 42501/sin_permiso -> 403; 22023 (texto_invalido, nota_invalida, lote_invalido) -> 422; SCJ11/transicion_invalida en
-- 'reconsentido' (alta en pendiente_baja/baja, o ya con esa versión) -> 409.
--
-- Decisiones de diseño:
--   - Tabla append-only y no vigencias con rango (SCJ-DEC-04): lo que importa es "qué versión aceptó ESTA alta", que lo
--     responde la FK del movimiento, no una fecha; un rango añadiría una columna mutable (vigente_hasta) que habría que
--     proteger. La semilla es la única fila sin autor (ck_terminal_consentimiento_autor).
--   - Sin "persona de sistema": tiempo.persona refleja a personas.persona; una persona falsa ensuciaría Personas y rompería
--     la frontera SCJ-FRO-01. creado_por es NULLable y sólo la versión 1 provisional puede carecer de actor.
--   - fn_terminal_reconsentir es SECURITY INVOKER a propósito: la policy bitacora_terminal_usuario_insert_web sigue siendo
--     la autorización real de cada fila (lección de 31_: si el router usa el cliente del caller, la RLS es la autorización).
--   - Reconsentimiento pendiente (decisión del usuario): alta en pendiente_alta, esperando_huella o activo cuyo
--     consentimiento_id apunta a una versión con version < la última versión con cambio_material. NO bloquea marcas (la
--     marca es el registro de asistencia que sirve para el pago; el remedio de un rechazo es la baja, flujo existente);
--     sólo se muestra en ficha/lista y en la tarjeta #10 del tablero de anomalías. Sin plazo automático.
--   - 'reconsentido' mide 12 caracteres: cabe en varchar(20) sin ensanchar la columna ('consentimiento_renovado' mide 23).
--   - Evidencia: el documento firmado vive en el expediente de RH (fuera del sistema); aquí la evidencia es la declaración de
--     RH (casilla) + quién, cuándo y qué versión. El trigger fija el detalle: "consentimiento y aviso de privacidad recabados: versión N"
--     en 'asignado' y "reconsentimiento recabado: versión N" en 'reconsentido' (nunca NULL ni texto del cliente).
--   - usuario_creado_en (columna de la tabla viva, sólo trigger): momento de 'usuario_creado'; plazo de la caducidad y de las altas atascadas.
--
-- Aviso: el backend (aún sin endpoint de 'asignado') debe mandar consentimiento_id en cada 'asignado'; esta migración
-- exige que las tablas terminal_usuario y bitácora estén vacías (0 filas verificadas el 2026-10-08). Si tuvieran filas, la
-- migración ABORTA con un mensaje claro: las filas de la bitácora son inmutables y no se les puede asignar versión.
--
-- Efectos sobre flujos existentes: los movimientos del Pi (usuario_creado, huella_capturada, baja_confirmada, error) y las
-- bajas (baja_solicitada, fn_terminal_baja_por_persona_inactiva, fn_terminal_baja_por_caducidad) llegan con consentimiento_id
-- NULL y siguen igual; sólo 'asignado' cambia (ahora exige la versión).
--
-- Inventario de RLS/privilegios de este archivo (regla de CLAUDE.md):
--   tiempo.terminal_consentimiento  RLS on, 1 policy (SELECT para activo y terminal_usuario_lectura | terminal_usuario_edicion |
--                                   terminal_config_edicion). authenticated y service_role: sólo SELECT; anon: nada. Nadie de la
--                                   API inserta/actualiza/borra/trunca: sólo el RPC (dueño). Secuencia identity sin privilegios.
--   tiempo.bitacora_movimiento_terminal_usuario / tiempo.terminal_usuario  grants de tabla sin cambio (SELECT, INSERT / SELECT);
--                                   las columnas nuevas quedan cubiertas. Policy de INSERT recreada con 'reconsentido'.
--   fn_terminal_consentimiento_publicar    SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE sólo authenticated.
--   fn_terminal_reconsentimiento_pendiente_ids  SECURITY INVOKER, search_path = tiempo, pg_temp; EXECUTE authenticated y
--                                   service_role (devuelve ids; la RLS de terminal_usuario sigue aplicando al llamador).
--   fn_terminal_reconsentir                SECURITY INVOKER, search_path = tiempo, personas, pg_temp; EXECUTE sólo authenticated.
--   personas.fn_caller_persona_id() y personas.fn_caller_es_administrador_generico()  SECURITY DEFINER, search_path = personas, pg_temp; EXECUTE sólo
--                                   authenticated (datos del PROPIO llamador; los usa el lote, que corre como el llamador).
--   personas.fn_persona_de_usuario(uuid) y personas.fn_usuario_es_administrador_generico(uuid)  SECURITY INVOKER, search_path = personas, pg_temp;
--                                   internas del trigger: EXECUTE para nadie de la API (reciben el usuario por parámetro).
--   Funciones de trigger de la tabla nueva: sin EXECUTE para nadie de la API.
--
-- Rollback de referencia (NO ejecutar sin revisar; sólo es posible mientras no haya movimientos con consentimiento_id):
--   DROP FUNCTION tiempo.fn_terminal_reconsentir(bigint[], bigint, boolean);
--   DROP FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids();
--   DROP FUNCTION tiempo.fn_terminal_consentimiento_publicar(text, boolean, text, integer);
--   -- restaurar fn_bitacora_terminal_usuario_aplica con el cuerpo de 83_*.sql (SECURITY DEFINER, SET search_path, FOR SHARE);
--   DROP POLICY bitacora_terminal_usuario_insert_web ON tiempo.bitacora_movimiento_terminal_usuario;
--   -- recrearla como en 81_*.sql; recrear ck_bitacora_terminal_usuario_tipo y _origen_tipo sin 'reconsentido';
--   ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario DROP CONSTRAINT ck_bitacora_terminal_usuario_consentimiento,
--     DROP COLUMN consentimiento_id;
--   ALTER TABLE tiempo.terminal_usuario DROP COLUMN consentimiento_id;
--   DROP TABLE tiempo.terminal_consentimiento;   -- sus triggers e índices caen con la tabla
--   DROP FUNCTION tiempo.fn_terminal_consentimiento_inmutable(); DROP FUNCTION tiempo.fn_terminal_consentimiento_truncate();
--   -- El permiso terminal_config_edicion y sus filas en la bitácora de puesto_permiso NO se pueden borrar (bitácora
--   -- inmutable); quedan inertes.
--
-- Depende de: 80_/81_ (terminal_usuario y su bitácora), 83_ (versión vigente de fn_bitacora_terminal_usuario_aplica, con
--   FOR SHARE), 86_ (convención SCJ15 y del permiso de acción por bitácora), 08_/38_ (grants schema-wide)
-- Justificación: SCJ-PRO-15 §IV.7 (aviso de privacidad y consentimiento), SCJ-DEC-12 (terminal), LFPDPPP (datos biométricos)

-- ============================================================================
-- 0) Guarda: la migración exige que no haya altas ni movimientos (ver "Aviso" arriba).
-- ============================================================================

-- Primera línea ejecutable: si algo retiene un lock, la migración falla en 5 s en vez de colgarse (SET LOCAL sólo rige dentro de una transacción).
SET LOCAL lock_timeout = '5s';

-- ACCESS EXCLUSIVE: nadie inserta una alta mientras se cuenta y se ejecutan los ALTER (ver "APLICAR EN UNA SOLA TRANSACCIÓN").
-- Orden fijo: primero la bitácora, luego la tabla viva (el trigger de la bitácora escribe la viva; mismo orden = sin deadlock).
LOCK TABLE tiempo.bitacora_movimiento_terminal_usuario, tiempo.terminal_usuario IN ACCESS EXCLUSIVE MODE;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario)
     OR EXISTS (SELECT 1 FROM tiempo.terminal_usuario) THEN
    RAISE EXCEPTION
      '88_ exige tiempo.terminal_usuario y la bitácora de enrolamiento vacías: hay filas y las de la bitácora son inmutables; avisar a db para diseñar el backfill'
      USING ERRCODE = 'SCJ16', HINT = 'migracion_con_filas';
  END IF;
END
$$;

-- ============================================================================
-- 1) Permiso de acción terminal_config_edicion (no heredable), sólo TI y Gerente General.
-- ============================================================================

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('terminal_config_edicion', false)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'terminal_config_edicion', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto IN ('Gerente o Encargado de TI', 'Gerente General')
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'terminal_config_edicion' AND pp.activo
  );

-- ============================================================================
-- 1b) Ayudas del llamador para la regla de auto-asignación (datos del PROPIO llamador; nada de terceros).
-- ============================================================================

-- INTERNAS: las llama sólo el trigger de la bitácora (como dueño). Reciben el usuario por parámetro y por eso NINGÚN rol de la API puede
-- ejecutarlas (si pudieran, servirían para averiguar quién es administrador). La regla deriva el actor de NEW.registrado_por, que la policy de
-- INSERT ata a auth.uid(): no depende del contexto de la sesión (BAJO-1 de la segunda revisión de security).
CREATE FUNCTION personas.fn_persona_de_usuario(p_auth_user_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = personas, pg_temp
AS $$
  SELECT u.persona_id FROM personas.usuario u WHERE u.auth_user_id = p_auth_user_id;
$$;

CREATE FUNCTION personas.fn_usuario_es_administrador_generico(p_auth_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = personas, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM personas.usuario u
    JOIN personas.asignacion a ON a.persona_id = u.persona_id AND a.vigente_hasta IS NULL
    JOIN personas.puesto pu ON pu.id = a.puesto_id
    WHERE u.auth_user_id = p_auth_user_id AND pu.es_administrador_generico
  );
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_persona_de_usuario(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_usuario_es_administrador_generico(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- Envoltorios SIN parámetro para el lote (fn_terminal_reconsentir es SECURITY INVOKER y corre como el llamador): sólo devuelven datos del
-- PROPIO llamador (su persona y si ocupa el puesto administrador), nada de terceros.
CREATE FUNCTION personas.fn_caller_persona_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  SELECT personas.fn_persona_de_usuario(auth.uid());
$$;

CREATE FUNCTION personas.fn_caller_es_administrador_generico()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  SELECT personas.fn_usuario_es_administrador_generico(auth.uid());
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_caller_persona_id() FROM PUBLIC, anon, service_role;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_es_administrador_generico() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_persona_id() TO authenticated;
GRANT EXECUTE ON FUNCTION personas.fn_caller_es_administrador_generico() TO authenticated;

COMMENT ON FUNCTION personas.fn_caller_persona_id() IS
  '88_. Persona del llamador (por auth.uid()); NULL si no tiene usuario. Sólo datos propios; la usa fn_terminal_reconsentir. SECURITY DEFINER, search_path = personas, pg_temp; EXECUTE sólo authenticated.';
COMMENT ON FUNCTION personas.fn_caller_es_administrador_generico() IS
  '88_. true si el llamador ocupa HOY (asignación vigente, sin herencia) un puesto con es_administrador_generico. Sólo datos propios; la usa fn_terminal_reconsentir. SECURITY DEFINER, search_path = personas, pg_temp; EXECUTE sólo authenticated.';

COMMENT ON FUNCTION personas.fn_persona_de_usuario(uuid) IS
  '88_. Persona de un usuario (auth_user_id); NULL si no tiene. Interna del trigger de la bitácora de enrolamiento; sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp.';
COMMENT ON FUNCTION personas.fn_usuario_es_administrador_generico(uuid) IS
  '88_. true si el usuario ocupa HOY (asignación vigente, sin herencia) un puesto con es_administrador_generico. Excepción de la regla de '
  'auto-asignación a una terminal (SCJ-PRO-15 §V.3). Interna del trigger; sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp.';

-- ============================================================================
-- 2) tiempo.terminal_consentimiento -- versiones del texto, sólo inserción.
-- ============================================================================

CREATE TABLE tiempo.terminal_consentimiento (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version         integer NOT NULL,
  texto           text NOT NULL,
  texto_sha256    char(64) NOT NULL,
  provisional     boolean NOT NULL DEFAULT false,
  cambio_material boolean NOT NULL DEFAULT false,
  nota            varchar(200),
  creado_por      uuid REFERENCES tiempo.persona (id),
  creado_en       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_terminal_consentimiento_version UNIQUE (version),
  CONSTRAINT ck_terminal_consentimiento_version CHECK (version >= 1),
  -- btrim(texto, E' \n'): quita espacios Y saltos de línea de los extremos (un texto de sólo '\n' no es un texto). Sin caracteres de
  -- control salvo \n, ni caracteres de formato Unicode invisibles o de reordenamiento.
  CONSTRAINT ck_terminal_consentimiento_texto CHECK (
    texto = btrim(texto, E' \n') AND char_length(texto) BETWEEN 1 AND 4000
    AND translate(texto, E'\n', '') !~ '[[:cntrl:]]'
    AND texto !~ '[\u00AD\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\U000E0000-\U000E007F]'
  ),
  CONSTRAINT ck_terminal_consentimiento_hash CHECK (
    texto_sha256 = encode(sha256(convert_to(texto, 'UTF8')), 'hex')
  ),
  -- provisional sólo puede ser la versión 1 (la semilla); el RPC nunca publica provisional = true.
  CONSTRAINT ck_terminal_consentimiento_provisional CHECK (NOT provisional OR version = 1),
  -- Sólo la semilla provisional puede carecer de autor.
  CONSTRAINT ck_terminal_consentimiento_autor CHECK (
    creado_por IS NOT NULL OR (version = 1 AND provisional)
  )
);

CREATE INDEX ix_terminal_consentimiento_creado_por ON tiempo.terminal_consentimiento (creado_por);

COMMENT ON TABLE tiempo.terminal_consentimiento IS
  'Versiones del texto de consentimiento biométrico y aviso de privacidad (SCJ-PRO-15 §IV.7). Sólo inserción, inmutable en '
  '3 capas. La versión vigente es la de mayor version. Sólo la escribe fn_terminal_consentimiento_publicar; la versión 1 es '
  'una semilla provisional sin autor.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.version IS 'Número consecutivo (1, 2, 3...) que asigna el RPC bajo lock de tabla; UNIQUE como respaldo.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.texto IS 'Texto plano (sin HTML), 1 a 4000 caracteres, sin espacios ni saltos de línea en los extremos, sin caracteres de control salvo salto de línea ni caracteres de formato Unicode invisibles. La interfaz debe mostrarlo como texto, nunca como HTML.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.texto_sha256 IS 'SHA-256 hex del texto en UTF-8; sirve para citar la versión en el documento impreso. Lo valida un CHECK.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.provisional IS 'true sólo en la semilla (versión 1). Dejar de ser provisional = publicar una versión nueva.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.cambio_material IS 'true = los ya enrolados con una versión anterior deben reconsentir. El RPC lo fuerza cuando la versión anterior era provisional.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.nota IS 'Motivo del cambio, opcional, hasta 200 caracteres.';
COMMENT ON COLUMN tiempo.terminal_consentimiento.creado_por IS 'Persona que publicó (frontera SCJ-FRO-01). NULL sólo en la semilla provisional (la interfaz lo muestra como "Sistema").';

ALTER TABLE tiempo.terminal_consentimiento ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.terminal_consentimiento FROM anon, authenticated, service_role;
GRANT SELECT ON tiempo.terminal_consentimiento TO authenticated, service_role;
REVOKE ALL ON SEQUENCE tiempo.terminal_consentimiento_id_seq FROM anon, authenticated, service_role;

-- Permiso específico, no sólo "activo" (lección de 31_): quien ve Terminales o quien edita la configuración.
CREATE POLICY terminal_consentimiento_select_lectura ON tiempo.terminal_consentimiento
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
      OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')
      OR personas.fn_caller_tiene_permiso('terminal_config_edicion')
    )
  );

CREATE FUNCTION tiempo.fn_terminal_consentimiento_inmutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'tiempo.terminal_consentimiento es de solo inserción: % no está permitido (fila %)', TG_OP, OLD.id;
END;
$$;

CREATE TRIGGER trg_terminal_consentimiento_inmutable
  BEFORE UPDATE OR DELETE ON tiempo.terminal_consentimiento
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_terminal_consentimiento_inmutable();

CREATE FUNCTION tiempo.fn_terminal_consentimiento_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'tiempo.terminal_consentimiento es de solo inserción: TRUNCATE no está permitido';
END;
$$;

CREATE TRIGGER trg_terminal_consentimiento_truncate
  BEFORE TRUNCATE ON tiempo.terminal_consentimiento
  FOR EACH STATEMENT
  EXECUTE FUNCTION tiempo.fn_terminal_consentimiento_truncate();

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_consentimiento_inmutable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_consentimiento_truncate() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_consentimiento_inmutable() IS
  'Aborta UPDATE/DELETE sobre tiempo.terminal_consentimiento, incluido service_role y el dueño. Sin EXECUTE para la API.';
COMMENT ON FUNCTION tiempo.fn_terminal_consentimiento_truncate() IS
  'Aborta TRUNCATE sobre tiempo.terminal_consentimiento (trigger por statement). Sin EXECUTE para la API.';

-- ============================================================================
-- 3) Siembra de la versión 1 (provisional, sin autor). Idempotente.
-- ============================================================================

INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, provisional, cambio_material, nota, creado_por)
SELECT 1, t.texto, encode(sha256(convert_to(t.texto, 'UTF8')), 'hex'), true, false,
       'Texto provisional sembrado por la migración 88_; sustituir por el aviso de privacidad revisado por Legal', NULL
FROM (VALUES (
  'La persona recibió el aviso de privacidad y otorgó por escrito su consentimiento para el tratamiento de su huella con fines de control de asistencia. La huella queda sólo en el aparato; el sistema guarda únicamente el conteo. Puede revocarlo en cualquier momento solicitando su baja a Recursos Humanos. El documento firmado queda en su expediente.'
)) AS t(texto)
WHERE NOT EXISTS (SELECT 1 FROM tiempo.terminal_consentimiento WHERE version = 1);

-- ============================================================================
-- 4) Columnas y restricciones en la bitácora y en la tabla viva.
-- ============================================================================

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  ADD COLUMN consentimiento_id bigint REFERENCES tiempo.terminal_consentimiento (id);

COMMENT ON COLUMN tiempo.bitacora_movimiento_terminal_usuario.consentimiento_id IS
  'Versión del texto de consentimiento que se aceptó. Obligatoria en ''asignado'' y ''reconsentido'', NULL en el resto '
  '(ck_bitacora_terminal_usuario_consentimiento). Debe ser la versión vigente al insertar (SCJ16 si no).';

CREATE INDEX ix_bitacora_terminal_usuario_consentimiento_id
  ON tiempo.bitacora_movimiento_terminal_usuario (consentimiento_id);

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  DROP CONSTRAINT ck_bitacora_terminal_usuario_tipo,
  DROP CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo;

ALTER TABLE tiempo.bitacora_movimiento_terminal_usuario
  ADD CONSTRAINT ck_bitacora_terminal_usuario_tipo CHECK (
    tipo_movimiento IN (
      'asignado', 'usuario_creado', 'huella_capturada',
      'baja_solicitada', 'baja_confirmada', 'error', 'reconsentido'
    )
  ),
  -- origen='web' si y sólo si el movimiento lo inicia RH desde la web.
  ADD CONSTRAINT ck_bitacora_terminal_usuario_origen_tipo CHECK (
    (origen = 'web') = (tipo_movimiento IN ('asignado', 'baja_solicitada', 'reconsentido'))
  ),
  ADD CONSTRAINT ck_bitacora_terminal_usuario_consentimiento CHECK (
    (tipo_movimiento IN ('asignado', 'reconsentido')) = (consentimiento_id IS NOT NULL)
  );

-- La tabla viva está vacía (guarda de 0): NOT NULL sin backfill.
ALTER TABLE tiempo.terminal_usuario
  ADD COLUMN consentimiento_id bigint NOT NULL REFERENCES tiempo.terminal_consentimiento (id);

COMMENT ON COLUMN tiempo.terminal_usuario.consentimiento_id IS
  '[CALCULADO] Versión del texto de consentimiento aceptada más reciente de esta alta (la fija el trigger en ''asignado'' y '
  'en ''reconsentido''). Reconsentimiento pendiente = alta en pendiente_alta, esperando_huella o activo con una versión menor '
  'que la última con cambio_material.';

CREATE INDEX ix_terminal_usuario_consentimiento_id ON tiempo.terminal_usuario (consentimiento_id);

-- Cuándo se creó el usuario en el aparato ('usuario_creado'); NULL mientras la alta está en pendiente_alta. Sólo la fija el trigger.
-- Barata (sin índice): evita la subconsulta a la bitácora para el plazo de caducidad y para la anomalía de altas atascadas.
ALTER TABLE tiempo.terminal_usuario ADD COLUMN usuario_creado_en timestamptz;

COMMENT ON COLUMN tiempo.terminal_usuario.usuario_creado_en IS
  '[CALCULADO] Momento del movimiento ''usuario_creado'' (el Pi creó el usuario en el aparato); NULL mientras sigue en pendiente_alta. '
  'Sólo la fija el trigger. Plazo de la caducidad de altas sin huella y de la anomalía de altas atascadas.';

-- Policy de INSERT humano: se agrega 'reconsentido' (mismos requisitos: persona activa, terminal_usuario_edicion, origen web y
-- autor = el propio caller).
DROP POLICY bitacora_terminal_usuario_insert_web ON tiempo.bitacora_movimiento_terminal_usuario;

CREATE POLICY bitacora_terminal_usuario_insert_web
  ON tiempo.bitacora_movimiento_terminal_usuario
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion')
    AND origen = 'web'
    AND tipo_movimiento IN ('asignado', 'baja_solicitada', 'reconsentido')
    AND registrado_por = auth.uid()
  );

-- ============================================================================
-- 5) Trigger de transiciones: versión de 83_ (SECURITY DEFINER, search_path y FOR SHARE de la terminal) + consentimiento.
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
  'Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] '
  'desde cada fila de la bitácora (SCJ-DEC-11). SECURITY DEFINER SET search_path = tiempo, '
  'personas, pg_temp: único escritor de terminal_usuario. SCJ11 = transición inválida o fila viva '
  'incoherente; SCJ12 = alta duplicada, persona no elegible o terminal no válida; SCJ16 = versión del '
  'texto de consentimiento ausente o desactualizada (88_); cada raise trae HINT estable. En ''asignado'' '
  'la terminal se toma FOR SHARE (83_*.sql) para serializar con el trigger SCJ13, y la tabla de versiones '
  'se bloquea en ROW EXCLUSIVE (choca con el SHARE ROW EXCLUSIVE de la publicación) antes de leer la vigente. ''reconsentido'' no cambia estado '
  'ni huellas y conserva error_detalle. Al reescribirla con CREATE OR REPLACE repetir SECURITY DEFINER y SET search_path.';

-- ============================================================================
-- 6) RPC
-- ============================================================================

-- 6a) Definición ÚNICA de "reconsentimiento pendiente": ids de las altas en pendiente_alta, esperando_huella o activo cuya
-- versión aceptada es menor que la última versión con cambio_material. SECURITY INVOKER: la RLS de terminal_usuario sigue
-- aplicando a quien llama (RH ve las altas porque tiene terminal_usuario_lectura/edicion); el backend (service_role) las ve todas.
CREATE FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids()
RETURNS SETOF bigint
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = tiempo, pg_temp
AS $$
  SELECT tu.id
  FROM tiempo.terminal_usuario tu
  JOIN tiempo.terminal_consentimiento c ON c.id = tu.consentimiento_id
  WHERE tu.estado IN ('pendiente_alta', 'esperando_huella', 'activo')
    AND c.version < (SELECT max(m.version) FROM tiempo.terminal_consentimiento m WHERE m.cambio_material)
  ORDER BY tu.id;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids() TO authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_reconsentimiento_pendiente_ids() IS
  '88_. Ids de tiempo.terminal_usuario con reconsentimiento pendiente (pendiente_alta | esperando_huella | activo con una '
  'versión menor que la última con cambio_material). Definición única: la usan fn_terminal_consentimiento_publicar, '
  'fn_terminal_reconsentir y el backend (tablero de anomalías, tarjeta #10). SECURITY INVOKER, search_path fijo.';

-- 6b) Publicar una versión nueva del texto.
CREATE FUNCTION tiempo.fn_terminal_consentimiento_publicar(
  p_texto            text,
  p_cambio_material  boolean DEFAULT false,
  p_nota             text DEFAULT NULL,
  p_base_version     integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_texto_max  constant integer := 4000;
  c_nota_max   constant integer := 200;
  v_actor      uuid;
  v_texto      text;
  v_nota       text;
  v_hash       text;
  v_vigente    tiempo.terminal_consentimiento;
  v_hay_vigente boolean;
  v_material   boolean;
  v_nueva      tiempo.terminal_consentimiento;
  v_pendientes bigint;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_config_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para publicar el texto de consentimiento'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  -- Texto: saltos de línea normalizados; caracteres de formato Unicode invisibles o de reordenamiento QUITADOS; demás caracteres de
  -- control a espacio, LÍNEA POR LÍNEA (así no hace falta un marcador temporal para proteger el salto de línea); sin espacios ni saltos
  -- en los extremos.
  v_texto := replace(replace(COALESCE(p_texto, ''), E'\r\n', E'\n'), E'\r', E'\n');
  -- U+2028/U+2029 (separadores de línea/párrafo) pasan a salto de línea ANTES de quitar los invisibles: así no pegan palabras.
  v_texto := replace(replace(v_texto, chr(8232), E'\n'), chr(8233), E'\n');
  v_texto := regexp_replace(v_texto, '[\u00AD\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\U000E0000-\U000E007F]', '', 'g');
  v_texto := array_to_string(
    ARRAY(SELECT regexp_replace(l.x, '[[:cntrl:]]', ' ', 'g')
          FROM unnest(string_to_array(v_texto, E'\n')) WITH ORDINALITY AS l(x, ord)
          ORDER BY l.ord),
    E'\n');
  v_texto := btrim(v_texto, E' \n');
  IF char_length(v_texto) = 0 OR char_length(v_texto) > c_texto_max THEN
    RAISE EXCEPTION 'El texto debe tener entre 1 y % caracteres', c_texto_max
      USING ERRCODE = '22023', HINT = 'texto_invalido';
  END IF;

  v_nota := NULLIF(btrim(regexp_replace(COALESCE(p_nota, ''), '[[:cntrl:]]', ' ', 'g')), '');
  IF v_nota IS NOT NULL AND char_length(v_nota) > c_nota_max THEN
    RAISE EXCEPTION 'La nota no puede pasar de % caracteres', c_nota_max
      USING ERRCODE = '22023', HINT = 'nota_invalida';
  END IF;

  SELECT u.persona_id INTO v_actor FROM personas.usuario u WHERE u.auth_user_id = auth.uid();

  -- Serializa publicaciones concurrentes y las asignaciones/reconsentimientos en curso (que toman ROW EXCLUSIVE de esta tabla).
  LOCK TABLE tiempo.terminal_consentimiento IN SHARE ROW EXCLUSIVE MODE;

  SELECT c.* INTO v_vigente FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
  v_hay_vigente := FOUND;
  v_hash := encode(sha256(convert_to(v_texto, 'UTF8')), 'hex');

  -- Publicación concurrente: la pantalla editó sobre la versión p_base_version; si mientras tanto alguien publicó otra, se rechaza
  -- (SCJ16 / version_base_desactualizada) en vez de pisar su texto. NULL = no se comprueba.
  IF p_base_version IS NOT NULL AND p_base_version IS DISTINCT FROM (CASE WHEN v_hay_vigente THEN v_vigente.version ELSE 0 END) THEN
    RAISE EXCEPTION 'Otra persona publicó una versión nueva mientras editabas: vuelve a leer el texto vigente'
      USING ERRCODE = 'SCJ16', HINT = 'version_base_desactualizada';
  END IF;

  -- El mismo texto sobre una versión definitiva no es un cambio. Sobre la provisional SÍ vale: es la forma de "dejar de ser
  -- provisional".
  IF v_hay_vigente AND NOT v_vigente.provisional AND v_vigente.texto_sha256 = v_hash THEN
    RETURN jsonb_build_object('resultado', 'sin_cambio', 'version', v_vigente.version, 'id', v_vigente.id);
  END IF;

  -- Si la versión anterior era provisional, nadie consintió el texto definitivo: cambio material forzado.
  v_material := COALESCE(p_cambio_material, false) OR (v_hay_vigente AND v_vigente.provisional);

  INSERT INTO tiempo.terminal_consentimiento (version, texto, texto_sha256, provisional, cambio_material, nota, creado_por)
  VALUES (CASE WHEN v_hay_vigente THEN v_vigente.version + 1 ELSE 1 END, v_texto, v_hash, false, v_material, v_nota, v_actor)
  RETURNING * INTO v_nueva;

  SELECT count(*) INTO v_pendientes FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids();

  RETURN jsonb_build_object(
    'resultado', 'publicada', 'id', v_nueva.id, 'version', v_nueva.version,
    'cambio_material', v_nueva.cambio_material, 'pendientes', v_pendientes);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_consentimiento_publicar(text, boolean, text, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_consentimiento_publicar(text, boolean, text, integer) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_terminal_consentimiento_publicar(text, boolean, text, integer) IS
  '88_. Publica una versión nueva del texto de consentimiento: exige persona activa y terminal_config_edicion DENTRO (42501/'
  'sin_permiso), deriva el autor de auth.uid(), sanea el texto (1 a 4000 caracteres, 22023/texto_invalido), serializa con '
  'LOCK TABLE y numera; si se manda p_base_version y ya no es la vigente, SCJ16 / version_base_desactualizada (publicación concurrente). ''sin_cambio'' si el texto es igual al de la vigente definitiva. Si la anterior era provisional '
  'fuerza cambio_material. Devuelve {resultado, id, version, cambio_material, pendientes}. SECURITY DEFINER, '
  'search_path = tiempo, personas, pg_temp; EXECUTE sólo authenticated (el backend la llama con el cliente del caller).';

-- 6c) Lote de reconsentimientos para RH. SECURITY INVOKER: la policy bitacora_terminal_usuario_insert_web es la autorización.
CREATE FUNCTION tiempo.fn_terminal_reconsentir(p_altas bigint[], p_consentimiento_id bigint, p_estricto boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_tope        constant integer := 200;
  v_vigente_id  bigint;
  v_ids         bigint[];
  v_pendientes  bigint[];
  v_omitidas    bigint[];
  v_propias     bigint[];
  v_motivos     jsonb;
  v_n           integer := 0;
  rec           record;
BEGIN
  -- Quien no es una persona activa con terminal_usuario_edicion no usa el lote: 42501 claro (sin él, la RLS le ocultaría las altas y la
  -- versión y el resultado sería confuso).
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para registrar reconsentimientos'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  IF p_altas IS NULL OR cardinality(p_altas) = 0 OR cardinality(p_altas) > c_tope THEN
    RAISE EXCEPTION 'El lote debe traer entre 1 y % altas', c_tope
      USING ERRCODE = '22023', HINT = 'lote_invalido';
  END IF;

  SELECT c.id INTO v_vigente_id
  FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
  IF v_vigente_id IS DISTINCT FROM p_consentimiento_id THEN
    RAISE EXCEPTION 'El texto de consentimiento cambió: la versión enviada ya no es la vigente'
      USING ERRCODE = 'SCJ16', HINT = 'consentimiento_desactualizado';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_ids FROM unnest(p_altas) AS x;
  SELECT COALESCE(array_agg(i), '{}') INTO v_pendientes FROM tiempo.fn_terminal_reconsentimiento_pendiente_ids() AS i;
  -- Altas PROPIAS del llamador (salvo que sea el administrador genérico): no elegibles, mismo mecanismo y regla que el trigger.
  SELECT COALESCE(array_agg(tu.id ORDER BY tu.id), '{}') INTO v_propias
  FROM tiempo.terminal_usuario tu
  WHERE tu.id = ANY (v_ids) AND tu.persona_id IS NOT DISTINCT FROM personas.fn_caller_persona_id()
    AND NOT personas.fn_caller_es_administrador_generico();
  SELECT COALESCE(array_agg(x ORDER BY x), '{}') INTO v_omitidas
  FROM unnest(v_ids) AS x WHERE NOT (x = ANY (v_pendientes)) OR x = ANY (v_propias);
  SELECT COALESCE(jsonb_object_agg(x::text, CASE WHEN x = ANY (v_propias) THEN 'alta_propia' ELSE 'no_elegible' END), '{}'::jsonb)
  INTO v_motivos FROM unnest(v_omitidas) AS x;

  -- Modo estricto: si alguna alta del lote no es elegible (no existe, no la ve el caller, no tiene el reconsentimiento pendiente),
  -- se rechaza TODO el lote y se devuelven los ids en DETAIL; garantiza todo-o-nada también respecto de lo que RH vio en pantalla.
  IF COALESCE(p_estricto, false) AND cardinality(v_omitidas) > 0 THEN
    RAISE EXCEPTION 'El lote trae altas que no son elegibles (sin reconsentimiento pendiente o la propia del llamador)'
      USING ERRCODE = '22023', HINT = 'lote_no_elegible', DETAIL = array_to_string(v_omitidas, ',');
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id
    FROM tiempo.terminal_usuario tu
    WHERE tu.id = ANY (v_ids) AND tu.id = ANY (v_pendientes) AND NOT (tu.id = ANY (v_propias))
    ORDER BY tu.id
  LOOP
    INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
      (terminal_usuario_id, terminal_id, persona_id, tipo_movimiento, origen, registrado_por, consentimiento_id)
    VALUES
      (rec.id, rec.terminal_id, rec.persona_id, 'reconsentido', 'web', auth.uid(), p_consentimiento_id);  -- el detalle fijo lo pone el trigger
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('resultado', 'ok', 'registradas', v_n, 'omitidas', to_jsonb(v_omitidas), 'motivos_omision', v_motivos);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentir(bigint[], bigint, boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_reconsentir(bigint[], bigint, boolean) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_terminal_reconsentir(bigint[], bigint, boolean) IS
  '88_. Registra un ''reconsentido'' por cada alta del lote (hasta 200) que tenga el reconsentimiento pendiente y no sea la PROPIA del llamador '
  '(salvo el administrador genérico); las demás se devuelven en omitidas, con su motivo fijo en motivos_omision (alta_propia | no_elegible) (con p_estricto = true se rechaza todo el lote si hay alguna: 22023 / lote_no_elegible, ids en DETAIL). Exige que p_consentimiento_id sea la versión vigente (SCJ16). Un solo statement = una transacción: '
  'todo o nada. SECURITY INVOKER: la policy bitacora_terminal_usuario_insert_web (persona activa, terminal_usuario_edicion, '
  'origen web, autor = auth.uid()) es la autorización real de cada fila. El detalle fijo lo pone el trigger; la evidencia es la '
  'declaración de RH (el documento firmado vive en el expediente).';
