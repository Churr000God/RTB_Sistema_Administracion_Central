-- 97_tiempo_terminal_inferir_huella_interruptor.sql
-- Interruptor de la activación por huella (vía B de 94_/95_): vive en el SERVIDOR, APAGADO por omisión, y encenderlo es un acto humano deliberado con nota,
-- vencimiento de hasta 30 días, consentimiento biométrico vigente publicado y rastro inmutable. Diseño: db/ensayos/DISENO_interruptor_inferir_huella.md (v4),
-- aprobado por security; «activo hasta» confirmado por el usuario (10-oct-2026). Este archivo NO cambia ningún comportamiento por sí solo: el interruptor nace en
-- '0' y fn_marca_terminal_registrar solo lo respeta desde 98_ (hasta entonces lo respeta el backend).
--
-- ARCHIVO COMPLETO EN UNA SOLA TRANSACCIÓN. Aplicar con `psql --single-transaction -v ON_ERROR_STOP=1 -f 97_*.sql` (el archivo NO lleva BEGIN/COMMIT). No puede
-- aplicarse a medias: sin la función dedicada, la bitácora y el trigger, alguien con terminal_config_edicion podría encender el parámetro por la ruta genérica sin nota
-- ni rastro. Depende de 60_ (tiempo.parametro con vigencias y autor), 88_ (terminal_consentimiento, permiso terminal_config_edicion), 89_ (fn_terminal_config_*) y 92_.
--
-- Qué crea:
--   1) Siembra de DOS claves en tiempo.parametro (idempotente, molde de 89_):
--        terminal_inferir_huella_activa  '0'                      0/1 (apagado por omisión)
--        terminal_inferir_huella_hasta   '1970-01-01T00:00:00Z'   timestamp ISO con zona; centinela ya VENCIDO (inerte); lo fija la función al encender
--      Las dos claves van FUERA del catálogo tiempo.fn_terminal_config_catalogo(): así fn_terminal_config_actualizar ya las rechaza por construcción y el lector
--      tolerante fn_terminal_config_valor devuelve NULL para ellas (= apagado), en vez de un valor acotado que leería '7' como 1.
--   2) CHECK ck_parametro_inferir_huella_activa ('0' o '1') y ck_parametro_inferir_huella_hasta (formato ISO estricto con zona, rangos válidos por patrón).
--   3) tiempo.bitacora_config_terminal: bitácora append-only (UPDATE/DELETE/TRUNCATE bloqueados incluso al dueño), RLS, SELECT para authenticated (policy con
--      permiso) y service_role, NADIE con INSERT (solo el trigger, como dueño). registrado_por SIN clave foránea (uuid): con FK una bitácora inmutable impediría borrar
--      cuentas.
--   4) Trigger de auditoría ESTRECHO sobre tiempo.parametro (AFTER INSERT/UPDATE/DELETE, por fila): solo para las dos claves del interruptor. Un UPDATE, INSERT o
--      DELETE directo (service_role, psql, dueño) también deja fila: valor anterior/nuevo, rol del JWT, session_user, hora y txid. La nota viaja por una variable de
--      transacción que SOLO fija la función dedicada y limpia al terminar; el trigger solo la acepta si una segunda variable coincide con txid_current() (refuerzo D3).
--      Además un trigger BEFORE TRUNCATE (por statement) sobre tiempo.parametro que BLOQUEA el TRUNCATE con mensaje fijo + HINT: service_role conserva TRUNCATE y un
--      TRUNCATE no pasa por los triggers por fila, así que vaciaría las filas del interruptor sin dejar rastro. Nadie debe vaciar tiempo.parametro (guarda la política).
--   5) tiempo.fn_terminal_inferir_huella_cambiar(p_activa, p_nota, p_hasta): la ÚNICA ruta legítima para encender/apagar. Gate DENTRO (persona activa y
--      terminal_config_edicion, no heredable). Encender exige nota >= 10 caracteres saneados, p_hasta futuro y a lo más a 30 días, consentimiento biométrico vigente y
--      PUBLICADO (no provisional) y al menos una terminal activa. Apagar no exige nota y devuelve 'hasta' al centinela. Escribe AMBAS claves en la misma transacción.
--   6) tiempo.fn_terminal_inferir_huella_estado(): el estado EFECTIVO, UNA sola definición para el RPC de marcas (98_), el backend y el tablero. Solo lectura.
--   7) fn_terminal_config_actualizar (CREATE OR REPLACE desde la definición VIGENTE de 89_): rechaza las dos claves con 22023 / clave_no_editable; de paso sus
--      RAISE EXCEPTION dejan de interpolar valores (mensajes fijos + el mismo HINT estable).
--
-- Estado EFECTIVO «encendido» (todo debe cumplirse; cualquier otra cosa, error incluido, es APAGADO):
--   - de CADA clave hay exactamente UNA fila vigente (vigente_desde <= hoy_utc y vigente_hasta nulo o >= hoy_utc); cero o más de una => apagado;
--   - el valor del interruptor es EXACTAMENTE la cadena '1' (lectura cruda, sin acotar);
--   - 'hasta' pasa el patrón estricto, se convierte dentro de un bloque con excepción y cumple  hasta > now()  Y  hasta <= now() + 30 días (el tope también al LEER).
--   hoy_utc = (now() AT TIME ZONE 'UTC')::date explícito, no CURRENT_DATE (que depende de TimeZone de la sesión).
--
-- Errores (HINT estable; el backend los traduce):
--   42501 sin_permiso | 22023 nota_requerida | 22023 hasta_invalido | 22023 terminal_no_activa | 22023 parametros_invalidos | 22023 vigencias_inconsistentes
--   22023 clave_no_editable (fn_terminal_config_actualizar con una clave del interruptor) | SCJ16 sin_consentimiento_vigente | SCJ02 sin vigencia activa
--
-- Inventario de RLS/privilegios de este archivo (regla de CLAUDE.md):
--   tiempo.parametro                     sin policies nuevas (RLS deny-all sin policies, como hoy); 2 CHECK nuevos; 1 trigger AFTER nuevo.
--   tiempo.bitacora_config_terminal      RLS on; 1 policy SELECT (authenticated, con permiso); REVOKE ALL a anon/authenticated/service_role y GRANT SELECT a
--                                        authenticated y service_role; sin INSERT/UPDATE/DELETE/TRUNCATE para nadie; secuencia sin privilegios. Policies: 76 -> 77.
--   fn_parametro_inferir_audita()        SECURITY DEFINER, search_path = tiempo, pg_temp, EXECUTE para nadie (función de trigger).
--   fn_parametro_truncate_bloqueado()    SECURITY INVOKER, search_path = tiempo, pg_temp, EXECUTE para nadie (función de trigger BEFORE TRUNCATE).
--   fn_parametro_inferir_escribe(...)    SECURITY DEFINER, search_path = tiempo, pg_temp, EXECUTE para nadie (solo la llama la función dedicada).
--   fn_texto_sin_invisibles(text)        IMMUTABLE, search_path = pg_temp, EXECUTE para nadie (solo la llama la función dedicada, como dueño).
--   fn_terminal_inferir_huella_cambiar   SECURITY DEFINER, search_path = tiempo, personas, pg_temp, EXECUTE solo authenticated.
--   fn_terminal_inferir_huella_estado    SECURITY DEFINER, STABLE, search_path = tiempo, pg_temp, EXECUTE solo service_role.
--   fn_terminal_config_actualizar        SECURITY DEFINER, search_path = tiempo, personas, pg_temp, EXECUTE solo authenticated (repetidos).
--
-- Riesgos residuales aceptados (D3/D4): quien tenga la llave de service_role puede escribir en tiempo.parametro (60_ solo revocó a anon/authenticated): el trigger lo
-- registra (nota nula, rol_jwt service_role) y el tablero lo marca, y el lector exige un 'hasta' dentro de 30 días al leer, pero la escritura no se impide. Quien sea
-- dueño o superusuario puede DISABLE TRIGGER o fijar variables de transacción; verificar_ddl.sql comprueba existencia y tgenabled = 'O'.
--
-- REVERSA. Operativa e inmediata: fn_terminal_inferir_huella_cambiar(false, NULL) (deja su fila). Antes del primer uso real, de forma inversa a este archivo:
--   DROP TRIGGER trg_parametro_inferir_huella_audita ON tiempo.parametro; DROP FUNCTION tiempo.fn_parametro_inferir_audita();
--   DROP TRIGGER trg_parametro_truncate_bloqueado ON tiempo.parametro; DROP FUNCTION tiempo.fn_parametro_truncate_bloqueado();
--   DROP FUNCTION tiempo.fn_terminal_inferir_huella_cambiar(boolean, text, timestamptz); DROP FUNCTION tiempo.fn_terminal_inferir_huella_estado();
--   DROP FUNCTION tiempo.fn_parametro_inferir_escribe(text, text, date, uuid); DROP FUNCTION tiempo.fn_texto_sin_invisibles(text);
--   ALTER TABLE tiempo.parametro DROP CONSTRAINT ck_parametro_inferir_huella_activa, DROP CONSTRAINT ck_parametro_inferir_huella_hasta;
--   restaurar fn_terminal_config_actualizar con el cuerpo de 89_ (db/ensayos/vigente_97_config_actualizar_89.sql, repitiendo DEFINER/search_path/REVOKE/GRANT);
--   DELETE FROM tiempo.parametro WHERE clave IN ('terminal_inferir_huella_activa','terminal_inferir_huella_hasta')  -- solo si nunca se editaron.
-- Con filas en la bitácora NO se borra: es inmutable por diseño; se deja inerte y se documenta (DROP TABLE solo con superusuario y OK explícito del usuario;
-- nunca desactivar sus triggers).

-- ============================================================================
-- 1) Siembra (idempotente)
-- ============================================================================

INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
SELECT v.clave, v.valor, DATE '2026-01-01', NULL, NULL
FROM (VALUES
  ('terminal_inferir_huella_activa', '0'),
  ('terminal_inferir_huella_hasta',  '1970-01-01T00:00:00Z')
) AS v(clave, valor)
WHERE NOT EXISTS (SELECT 1 FROM tiempo.parametro p WHERE p.clave = v.clave);

-- ============================================================================
-- 2) Formato de los valores (el patrón es puro texto: no depende de la sesión; la lectura convierte dentro de un bloque con excepción)
-- ============================================================================

ALTER TABLE tiempo.parametro
  ADD CONSTRAINT ck_parametro_inferir_huella_activa CHECK (
    clave <> 'terminal_inferir_huella_activa' OR valor IN ('0', '1')
  ),
  ADD CONSTRAINT ck_parametro_inferir_huella_hasta CHECK (
    clave <> 'terminal_inferir_huella_hasta'
    OR valor ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$'
  );

-- ============================================================================
-- 3) Bitácora de configuración (append-only)
-- ============================================================================

CREATE TABLE tiempo.bitacora_config_terminal (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clave            text NOT NULL,
  operacion        text NOT NULL,
  valor_anterior   text,
  valor_nuevo      text,
  nota             text,
  registrado_por   uuid,
  rol_jwt          text,
  usuario_sesion   text NOT NULL,
  via_funcion      boolean NOT NULL,
  txid             bigint NOT NULL,
  creado_en        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_bitacora_config_terminal_clave CHECK (clave IN ('terminal_inferir_huella_activa', 'terminal_inferir_huella_hasta')),
  CONSTRAINT ck_bitacora_config_terminal_operacion CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE')),
  CONSTRAINT ck_bitacora_config_terminal_nota_len CHECK (nota IS NULL OR char_length(nota) <= 500)
);

COMMENT ON TABLE tiempo.bitacora_config_terminal IS
  'Rastro inmutable de los cambios al interruptor de la activación por huella (terminal_inferir_huella_*): valor anterior y nuevo, nota, autor, rol del JWT, '
  'usuario de sesión, hora y txid. La escribe SOLO el trigger de tiempo.parametro (como dueño); un cambio directo con service_role también deja fila (sin nota, '
  'via_funcion = false). registrado_por no lleva clave foránea a propósito (una bitácora inmutable con FK impediría borrar cuentas). Diseño: DISENO_interruptor_inferir_huella.md.';
COMMENT ON COLUMN tiempo.bitacora_config_terminal.via_funcion IS
  'true solo si el cambio ocurrió dentro de fn_terminal_inferir_huella_cambiar (la variable de transacción con txid_current() coincide). Calculado por el trigger, no recibido.';

ALTER TABLE tiempo.bitacora_config_terminal ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.bitacora_config_terminal FROM anon, authenticated, service_role;
GRANT SELECT ON tiempo.bitacora_config_terminal TO authenticated, service_role;
REVOKE UPDATE, DELETE, TRUNCATE, INSERT ON tiempo.bitacora_config_terminal FROM anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE tiempo.bitacora_config_terminal_id_seq FROM anon, authenticated, service_role;

-- Permiso específico, no solo «activo» (lección de 31_): quien edita la configuración o quien ve Terminales.
CREATE POLICY bitacora_config_terminal_select_lectura ON tiempo.bitacora_config_terminal
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('terminal_config_edicion')
      OR personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
      OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')
    )
  );

CREATE FUNCTION tiempo.fn_bitacora_config_terminal_inmutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora de configuración de terminales es de solo inserción'
    USING ERRCODE = 'P0001', HINT = 'bitacora_inmutable';
END;
$$;

CREATE TRIGGER trg_bitacora_config_terminal_inmutable
  BEFORE UPDATE OR DELETE ON tiempo.bitacora_config_terminal
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_bitacora_config_terminal_inmutable();

CREATE FUNCTION tiempo.fn_bitacora_config_terminal_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'La bitácora de configuración de terminales es de solo inserción'
    USING ERRCODE = 'P0001', HINT = 'bitacora_inmutable';
END;
$$;

CREATE TRIGGER trg_bitacora_config_terminal_truncate
  BEFORE TRUNCATE ON tiempo.bitacora_config_terminal
  FOR EACH STATEMENT
  EXECUTE FUNCTION tiempo.fn_bitacora_config_terminal_truncate();

REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_config_terminal_inmutable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_config_terminal_truncate() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_bitacora_config_terminal_inmutable() IS
  '97_. Aborta UPDATE/DELETE sobre tiempo.bitacora_config_terminal, incluido service_role y el dueño. Mensaje fijo + HINT estable. Sin EXECUTE para la API.';
COMMENT ON FUNCTION tiempo.fn_bitacora_config_terminal_truncate() IS
  '97_. Aborta TRUNCATE sobre tiempo.bitacora_config_terminal (trigger por statement). Mensaje fijo + HINT estable. Sin EXECUTE para la API.';

-- ============================================================================
-- 4) Trigger de auditoría sobre tiempo.parametro (estrecho: solo las dos claves del interruptor)
-- ============================================================================

CREATE FUNCTION tiempo.fn_parametro_inferir_audita()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  c_activa  constant text := 'terminal_inferir_huella_activa';
  c_hasta   constant text := 'terminal_inferir_huella_hasta';
  v_clave   text;
  v_ant     text;
  v_nue     text;
  v_nota    text;
  v_via     boolean := false;
  v_jwt     text;
BEGIN
  -- Qué clave nos interesa (el cambio de clave de una fila hacia o desde el interruptor también cuenta).
  IF TG_OP <> 'DELETE' AND NEW.clave IN (c_activa, c_hasta) THEN
    v_clave := NEW.clave;
  ELSIF TG_OP <> 'INSERT' AND OLD.clave IN (c_activa, c_hasta) THEN
    v_clave := OLD.clave;
  ELSE
    RETURN NULL;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_nue := NEW.valor;
    v_ant := (SELECT p.valor FROM tiempo.parametro p
              WHERE p.clave = NEW.clave AND p.id <> NEW.id
              ORDER BY p.vigente_desde DESC, p.id DESC LIMIT 1);
  ELSIF TG_OP = 'UPDATE' THEN
    -- El UPDATE que solo cierra la vigencia (vigente_hasta) no cambia el valor: no genera ruido.
    IF OLD.clave IS NOT DISTINCT FROM NEW.clave AND OLD.valor IS NOT DISTINCT FROM NEW.valor THEN
      RETURN NULL;
    END IF;
    v_ant := OLD.valor;
    v_nue := NEW.valor;
  ELSE
    v_ant := OLD.valor;
    v_nue := NULL;
  END IF;

  -- La nota solo vale si la fijó la función dedicada EN ESTA transacción (la segunda variable debe coincidir con txid_current()).
  IF current_setting('scj.txid_interruptor', true) IS NOT DISTINCT FROM txid_current()::text THEN
    v_via := true;
    v_nota := NULLIF(current_setting('scj.nota_interruptor', true), '');
  END IF;

  BEGIN
    v_jwt := (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb) ->> 'role';
  EXCEPTION WHEN OTHERS THEN
    v_jwt := NULL;
  END;

  INSERT INTO tiempo.bitacora_config_terminal
    (clave, operacion, valor_anterior, valor_nuevo, nota, registrado_por, rol_jwt, usuario_sesion, via_funcion, txid)
  VALUES
    (v_clave, TG_OP, v_ant, v_nue, v_nota,
     COALESCE(auth.uid(), CASE WHEN TG_OP <> 'DELETE' THEN NEW.registrado_por END),
     v_jwt, session_user::text, v_via, txid_current());
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_parametro_inferir_huella_audita
  AFTER INSERT OR UPDATE OR DELETE ON tiempo.parametro
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_parametro_inferir_audita();

REVOKE EXECUTE ON FUNCTION tiempo.fn_parametro_inferir_audita() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_parametro_inferir_audita() IS
  '97_. Trigger de auditoría del interruptor de la activación por huella: registra en tiempo.bitacora_config_terminal TODO cambio de valor (o alta/baja de fila) de las claves '
  'terminal_inferir_huella_activa y terminal_inferir_huella_hasta, venga de donde venga (función dedicada, service_role directo, psql). La nota solo se acepta si la fijó la '
  'función dedicada en esta misma transacción (variable scj.txid_interruptor = txid_current()). SECURITY DEFINER, search_path = tiempo, pg_temp, EXECUTE para nadie. '
  'Al reescribirla repetir SECURITY DEFINER y SET search_path.';

-- TRUNCATE de tiempo.parametro: bloqueado. service_role tiene TRUNCATE (GRANT ALL de 38_) y un TRUNCATE no dispara los triggers por fila, de modo que podría vaciar
-- las filas del interruptor sin dejar rastro en la bitácora. Ningún flujo legítimo vacía esta tabla (el reconstruir una base desde cero usa DROP SCHEMA, no TRUNCATE).
CREATE FUNCTION tiempo.fn_parametro_truncate_bloqueado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'tiempo.parametro no admite TRUNCATE'
    USING ERRCODE = 'P0001', HINT = 'parametro_truncate_bloqueado';
END;
$$;

CREATE TRIGGER trg_parametro_truncate_bloqueado
  BEFORE TRUNCATE ON tiempo.parametro
  FOR EACH STATEMENT
  EXECUTE FUNCTION tiempo.fn_parametro_truncate_bloqueado();

REVOKE EXECUTE ON FUNCTION tiempo.fn_parametro_truncate_bloqueado() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_parametro_truncate_bloqueado() IS
  '97_. Aborta TRUNCATE sobre tiempo.parametro (incluido service_role y el dueño): un TRUNCATE no pasa por el trigger de auditoría por fila y vaciaría el interruptor de la '
  'activación por huella sin rastro. Mensaje fijo + HINT estable. SECURITY INVOKER, search_path = tiempo, pg_temp, sin EXECUTE para la API.';

-- ============================================================================
-- 5) Ayudas internas (sin EXECUTE para la API)
-- ============================================================================

-- Saneado de la nota: los mismos invisibles y separadores que limpia 92_ en el detalle de la bitácora de terminal.
CREATE FUNCTION tiempo.fn_texto_sin_invisibles(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_temp
AS $$
  SELECT regexp_replace(
           replace(replace(p_texto, chr(8232), ' '), chr(8233), ' '),
           '[­؜​-‏ -‮⁠-⁤⁦-⁩﻿\U000E0000-\U000E007F]', '', 'g');
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_texto_sin_invisibles(text) FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_texto_sin_invisibles(text) IS
  '97_. Quita caracteres Unicode de formato/reordenamiento invisibles y convierte U+2028/U+2029 en espacio (misma regla que 92_ para el detalle de la bitácora de terminal). '
  'IMMUTABLE, search_path = pg_temp, sin EXECUTE para la API (solo la usa fn_terminal_inferir_huella_cambiar, como dueño).';

-- Escribe UNA clave del interruptor con el mismo versionado que 89_ (borde inclusivo; el mismo día corrige en sitio). Devuelve true si cambió algo.
CREATE FUNCTION tiempo.fn_parametro_inferir_escribe(p_clave text, p_valor text, p_hoy date, p_actor uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_n      integer;
  v_id     bigint;
  v_desde  date;
  v_valor  text;
BEGIN
  -- P1: «vigente» = vigente_desde <= hoy y (vigente_hasta nulo o >= hoy). Cero filas vigentes: no hay nada que versionar; más de una: vigencias solapadas, la
  -- función se NIEGA a escribir (el lector ya las lee como apagado); la reparación es una intervención directa y auditada, no esta ruta.
  SELECT count(*) INTO v_n FROM tiempo.parametro p
  WHERE p.clave = p_clave AND p.vigente_desde <= p_hoy AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= p_hoy);
  IF v_n = 0 THEN
    RAISE EXCEPTION 'No existe un parámetro activo para esa clave' USING ERRCODE = 'SCJ02';
  END IF;
  IF v_n > 1 THEN
    RAISE EXCEPTION 'Las vigencias del interruptor son inconsistentes' USING ERRCODE = '22023', HINT = 'vigencias_inconsistentes';
  END IF;

  SELECT p.id, p.vigente_desde, p.valor INTO v_id, v_desde, v_valor
  FROM tiempo.parametro p
  WHERE p.clave = p_clave AND p.vigente_hasta IS NULL AND p.vigente_desde <= p_hoy
  FOR UPDATE;
  IF NOT FOUND THEN
    -- La única fila vigente por fecha no es la abierta: inconsistente también.
    RAISE EXCEPTION 'Las vigencias del interruptor son inconsistentes' USING ERRCODE = '22023', HINT = 'vigencias_inconsistentes';
  END IF;

  IF v_valor = p_valor THEN
    RETURN false;
  END IF;

  IF v_desde >= p_hoy THEN
    -- Mismo día: es la misma vigencia corregida (el trigger de auditoría deja la fila del cambio de valor).
    UPDATE tiempo.parametro SET valor = p_valor, registrado_por = p_actor WHERE id = v_id;
  ELSE
    UPDATE tiempo.parametro SET vigente_hasta = p_hoy - 1 WHERE id = v_id;
    INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
    VALUES (p_clave, p_valor, p_hoy, NULL, p_actor);
  END IF;
  RETURN true;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_parametro_inferir_escribe(text, text, date, uuid) FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_parametro_inferir_escribe(text, text, date, uuid) IS
  '97_. Interna de fn_terminal_inferir_huella_cambiar: escribe una clave del interruptor con versionado por vigencia (borde inclusivo; el mismo día corrige en sitio). '
  'Devuelve true si cambió el valor. SECURITY DEFINER, search_path = tiempo, pg_temp, EXECUTE para nadie.';

-- ============================================================================
-- 6) Estado EFECTIVO del interruptor (UNA sola definición: RPC de marcas, backend y tablero)
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_inferir_huella_estado()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  c_activa  constant text     := 'terminal_inferir_huella_activa';
  c_hasta   constant text     := 'terminal_inferir_huella_hasta';
  c_tope    constant interval := interval '30 days';
  c_patron  constant text     := '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$';
  v_hoy        date := (now() AT TIME ZONE 'UTC')::date;
  v_n_activa   integer;
  v_n_hasta    integer;
  v_valor      text;
  v_hasta_txt  text;
  v_hasta      timestamptz;
  v_activo     boolean := false;
  v_vencido    boolean := false;
  v_motivo     text;
  v_por        uuid;
  v_en         timestamptz;
BEGIN
  SELECT count(*) INTO v_n_activa FROM tiempo.parametro p
  WHERE p.clave = c_activa AND p.vigente_desde <= v_hoy AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= v_hoy);
  SELECT count(*) INTO v_n_hasta FROM tiempo.parametro p
  WHERE p.clave = c_hasta AND p.vigente_desde <= v_hoy AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= v_hoy);

  IF v_n_activa <> 1 OR v_n_hasta <> 1 THEN
    v_motivo := 'vigencias_inconsistentes';
  ELSE
    SELECT p.valor INTO v_valor FROM tiempo.parametro p
    WHERE p.clave = c_activa AND p.vigente_desde <= v_hoy AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= v_hoy);
    SELECT p.valor INTO v_hasta_txt FROM tiempo.parametro p
    WHERE p.clave = c_hasta AND p.vigente_desde <= v_hoy AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= v_hoy);

    IF v_valor IS DISTINCT FROM '1' THEN
      v_motivo := CASE WHEN v_valor = '0' THEN 'apagado' ELSE 'valor_invalido' END;
    ELSIF v_hasta_txt IS NULL OR v_hasta_txt !~ c_patron THEN
      v_motivo := 'hasta_ilegible';
    ELSE
      BEGIN
        v_hasta := v_hasta_txt::timestamptz;
      EXCEPTION WHEN OTHERS THEN
        v_hasta := NULL;
      END;
      IF v_hasta IS NULL THEN
        v_motivo := 'hasta_ilegible';
      ELSIF v_hasta <= now() THEN
        v_vencido := true;
        v_motivo := 'vencido';
      ELSIF v_hasta > now() + c_tope THEN
        v_motivo := 'hasta_excede_tope';
      ELSE
        v_activo := true;
      END IF;
    END IF;
  END IF;

  -- Quién y cuándo lo encendió por última vez (de la bitácora de configuración); informativo, no decide el estado.
  SELECT b.registrado_por, b.creado_en INTO v_por, v_en
  FROM tiempo.bitacora_config_terminal b
  WHERE b.clave = c_activa AND b.valor_nuevo = '1'
  ORDER BY b.id DESC LIMIT 1;

  RETURN jsonb_build_object(
    'activo', v_activo,
    'vencido', v_vencido,
    'motivo', v_motivo,
    'valor', v_valor,
    'hasta', v_hasta_txt,
    'encendido_por', v_por,
    'encendido_en', v_en
  );
EXCEPTION WHEN OTHERS THEN
  -- Falla CERRADO: cualquier error de lectura es «apagado». Solo el SQLSTATE en el log, nunca texto del error ni identidad.
  RAISE WARNING 'fn_terminal_inferir_huella_estado: lectura fallida sqlstate=%', SQLSTATE;
  RETURN jsonb_build_object('activo', false, 'vencido', false, 'motivo', 'error', 'valor', NULL, 'hasta', NULL,
                            'encendido_por', NULL, 'encendido_en', NULL);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_inferir_huella_estado() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_inferir_huella_estado() TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_inferir_huella_estado() IS
  '97_. Estado EFECTIVO del interruptor de la activación por huella: {activo, vencido, motivo, valor, hasta, encendido_por, encendido_en}. UNA sola definición para el RPC de '
  'marcas (98_), el backend y el tablero. activo = exactamente una vigencia por clave, valor = ''1'' (lectura cruda, sin acotar), hasta futuro y a lo más a 30 días '
  '(también al leer); cualquier otra cosa o error = apagado (falla cerrado; solo SQLSTATE en el warning). Solo lectura. SECURITY DEFINER, STABLE, '
  'search_path = tiempo, pg_temp, EXECUTE solo service_role.';

-- ============================================================================
-- 7) Función dedicada: la ÚNICA ruta para encender/apagar
-- ============================================================================

CREATE FUNCTION tiempo.fn_terminal_inferir_huella_cambiar(p_activa boolean, p_nota text, p_hasta timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_activa       constant text     := 'terminal_inferir_huella_activa';
  c_hasta        constant text     := 'terminal_inferir_huella_hasta';
  c_centinela    constant text     := '1970-01-01T00:00:00Z';
  c_tope         constant interval := interval '30 days';
  c_nota_min     constant integer  := 10;
  v_hoy          date := (now() AT TIME ZONE 'UTC')::date;
  v_actor        uuid := auth.uid();
  v_nota         text;
  v_valor        text;
  v_hasta_txt    text;
  v_cambio_a     boolean;
  v_cambio_h     boolean;
  v_provisional  boolean;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_config_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para cambiar el interruptor de la activación por huella'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  IF p_activa IS NULL THEN
    RAISE EXCEPTION 'Falta indicar si se enciende o se apaga' USING ERRCODE = '22023', HINT = 'parametros_invalidos';
  END IF;

  -- Un solo cambio a la vez (las dos claves se escriben juntas).
  PERFORM pg_advisory_xact_lock(hashtextextended('tiempo.terminal_inferir_huella', 0));

  v_nota := NULLIF(btrim(tiempo.fn_texto_sin_invisibles(p_nota)), '');

  IF p_activa THEN
    IF v_nota IS NULL OR char_length(v_nota) < c_nota_min OR char_length(v_nota) > 500 THEN
      RAISE EXCEPTION 'Encender exige una nota de entre 10 y 500 caracteres'
        USING ERRCODE = '22023', HINT = 'nota_requerida';
    END IF;
    IF p_hasta IS NULL OR p_hasta <= now() OR p_hasta > now() + c_tope THEN
      RAISE EXCEPTION 'El vencimiento debe ser futuro y a lo más a 30 días'
        USING ERRCODE = '22023', HINT = 'hasta_invalido';
    END IF;
    -- P4: consentimiento biométrico vigente y PUBLICADO (no la semilla provisional) y al menos una terminal activa.
    SELECT c.provisional INTO v_provisional FROM tiempo.terminal_consentimiento c ORDER BY c.version DESC LIMIT 1;
    IF NOT FOUND OR v_provisional THEN
      RAISE EXCEPTION 'No hay un texto de consentimiento biométrico vigente publicado'
        USING ERRCODE = 'SCJ16', HINT = 'sin_consentimiento_vigente';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM tiempo.terminal t WHERE t.activa) THEN
      RAISE EXCEPTION 'No hay ninguna terminal activa' USING ERRCODE = '22023', HINT = 'terminal_no_activa';
    END IF;
    v_valor := '1';
    v_hasta_txt := to_char(p_hasta AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  ELSE
    v_valor := '0';
    v_hasta_txt := c_centinela;   -- apagar nunca deja una fecha futura colgada
  END IF;

  -- Anuncia al trigger de auditoría que el cambio ocurre dentro de esta función (nota + txid; ambas se limpian al terminar).
  PERFORM set_config('scj.txid_interruptor', txid_current()::text, true);
  PERFORM set_config('scj.nota_interruptor', COALESCE(v_nota, ''), true);

  v_cambio_a := tiempo.fn_parametro_inferir_escribe(c_activa, v_valor, v_hoy, v_actor);
  v_cambio_h := tiempo.fn_parametro_inferir_escribe(c_hasta, v_hasta_txt, v_hoy, v_actor);

  PERFORM set_config('scj.txid_interruptor', '', true);
  PERFORM set_config('scj.nota_interruptor', '', true);

  RETURN jsonb_build_object(
    'resultado', CASE WHEN v_cambio_a OR v_cambio_h THEN 'actualizada' ELSE 'sin_cambio' END,
    'estado', tiempo.fn_terminal_inferir_huella_estado()
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_inferir_huella_cambiar(boolean, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_inferir_huella_cambiar(boolean, text, timestamptz) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_terminal_inferir_huella_cambiar(boolean, text, timestamptz) IS
  '97_. Única ruta para encender/apagar el interruptor de la activación por huella. Gate DENTRO: persona activa y terminal_config_edicion (42501/sin_permiso). Encender '
  'exige nota de 10 a 500 caracteres saneados (22023/nota_requerida), p_hasta futuro y a lo más a 30 días (22023/hasta_invalido), consentimiento vigente publicado '
  '(SCJ16/sin_consentimiento_vigente) y una terminal activa (22023/terminal_no_activa); apagar no exige nota y devuelve el vencimiento al centinela. Escribe AMBAS claves en '
  'la misma transacción (el trigger de auditoría deja una fila por cada cambio de valor). Devuelve {resultado: actualizada | sin_cambio, estado: <estado efectivo>}. '
  'SECURITY DEFINER, search_path = tiempo, personas, pg_temp, EXECUTE solo authenticated.';

-- ============================================================================
-- 8) fn_terminal_config_actualizar: rechaza las dos claves (desde la definición VIGENTE de 89_)
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)
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

  -- 97_: las dos claves del interruptor de la activación por huella NO se editan por aquí (ni siquiera con permiso): solo con
  -- fn_terminal_inferir_huella_cambiar (nota, vencimiento, consentimiento vigente y rastro). Ya están fuera del catálogo; este guard
  -- evita que un alta futura del catálogo por descuido reabra la ruta.
  IF p_clave IN ('terminal_inferir_huella_activa', 'terminal_inferir_huella_hasta') THEN
    RAISE EXCEPTION 'Esta clave no se edita desde la configuración general de terminales'
      USING ERRCODE = '22023', HINT = 'clave_no_editable';
  END IF;

  SELECT * INTO v_cat FROM tiempo.fn_terminal_config_catalogo() c WHERE c.clave = p_clave;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La clave no es editable desde la configuración de terminales'
      USING ERRCODE = '22023', HINT = 'clave_no_editable';
  END IF;

  IF p_valor IS NULL OR btrim(p_valor) !~ '^[0-9]{1,4}$' THEN
    RAISE EXCEPTION 'El valor debe ser un entero dentro del rango permitido'
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  v_valor := btrim(p_valor)::integer;
  IF v_valor < v_cat.minimo OR v_valor > v_cat.maximo THEN
    RAISE EXCEPTION 'El valor está fuera del rango permitido'
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
    RAISE EXCEPTION 'No existe un parámetro activo para esa clave'
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
  '89_/97_. Edita una de las 5 claves terminal_* del catálogo de tiempo.parametro: exige persona activa y terminal_config_edicion DENTRO (42501/sin_permiso), clave en la '
  'lista blanca (22023/clave_no_editable; las dos claves del interruptor de la activación por huella se rechazan siempre: solo fn_terminal_inferir_huella_cambiar) y entero '
  'dentro de su rango (22023/valor_invalido), deriva el autor de auth.uid() y versiona por vigencia (borde inclusivo; el mismo día corrige en sitio). Mensajes fijos + HINT '
  'estable. Devuelve {resultado: actualizada | sin_cambio, clave, valor, vigente_desde}. SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE solo authenticated.';
