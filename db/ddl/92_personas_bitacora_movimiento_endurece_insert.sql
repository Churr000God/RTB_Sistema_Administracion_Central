-- 92_personas_bitacora_movimiento_endurece_insert.sql
-- Endurece el INSERT HUMANO en personas.bitacora_movimiento_persona (hallazgo M1 de security, preexistente desde 31_) y limpia los caracteres
-- invisibles del detalle de la bitácora de enrolamiento de terminal (B2 de security).
--
-- El problema (A): la policy bitacora_insert_requiere_permiso (31_) sólo exigía persona activa y cambio_estado_persona. No ataba
-- registrado_por a auth.uid() ni obligaba creado_en = now(): por PostgREST directo, quien tuviera cambio_estado_persona podía falsificar el
-- AUTOR y la HORA del movimiento de cualquier persona (y también insertar un movimiento 'alta' a mano). De ahí sale el autor de la baja
-- automática de terminal (fn_terminal_baja_por_persona_inactiva, 91_: último movimiento por creado_en) y la auditoría de estados de persona.
--
-- APLICAR con `psql --single-transaction -f 92_*.sql` (o confirmar con `SELECT txid_current(); SELECT txid_current();` que el SQL Editor es una sola
-- transacción). El archivo NO lleva BEGIN/COMMIT (los ensayos lo incluyen dentro de su propio BEGIN … ROLLBACK).
--
-- REQUISITO DE USO (B2 de security): el INSERT en personas.usuario debe hacerse SIEMPRE con service_role (como hoy routers/usuarios.py y
-- scripts/bootstrap_usuario_base.py). fn_usuario_bitacora_alta corre con los privilegios de quien inserta el usuario; si se hiciera con el cliente
-- del caller, la policy nueva (tipo alta no permitido, registrado_por = auth.uid()) rechazaría el 'alta' automático y la creación del usuario
-- fallaría. No se cambia la función; el requisito queda anotado aquí y en su COMMENT ON FUNCTION.
--
-- Qué hace:
--   1) Policy nueva (DROP + CREATE) con WITH CHECK: persona activa AND cambio_estado_persona AND registrado_por = auth.uid() AND tipo_movimiento
--      IN ('suspension','reactivacion','baja_definitiva'). Un 'alta' lo crea SÓLO el trigger trg_usuario_bitacora_alta (como service_role/dueño).
--   2) Trigger BEFORE INSERT trg_bitacora_persona_fija_hora (fn_bitacora_persona_fija_hora): para llamadores de la API (rol anon/authenticated)
--      FIJA creado_en := now() (el cliente no elige cuándo "ocurrió" el registro) y acota fecha_efectiva a [now() - 90 días, now() + 5 minutos]
--      (22023 / fecha_efectiva_invalida). service_role y el dueño NO se tocan: el alta automática y los scripts conservan lo que insertan.
--   3) (B2) Trigger BEFORE INSERT trg_bitacora_terminal_usuario_a0_limpia_detalle en la bitácora de enrolamiento: quita del detalle los caracteres de
--      formato Unicode invisibles o de reordenamiento y pasa U+2028/U+2029 a espacio, también para el detalle de origen web (el del Pi ya lo
--      limpia fn_terminal_movimiento_registrar desde 91_). Va como trigger aparte, y no dentro de fn_bitacora_terminal_usuario_aplica, para no
--      reabrir esa función validada (143 casos). Su nombre (a0_) lo hace correr ANTES que trg_bitacora_terminal_usuario_aplica, que copia
--      NEW.detalle a terminal_usuario.error_detalle.
--
-- Por qué la regla de fecha_efectiva es una VENTANA y no "= now()": fecha_efectiva alimenta persona.fecha_baja y el cierre de asignaciones
-- (fn_bitacora_sincroniza_persona); un movimiento puede registrarse con retraso (una baja ocurrió la semana pasada), pero no en el futuro (sólo una tolerancia de reloj de 5 minutos): el
-- trigger de sincronización aplica el estado AHORA, así que una fecha futura sería incoherente. 90 días de retroactividad es un valor inicial
-- ajustable (constante c_retroactivo_max_dias), no un hecho del negocio: ninguna pantalla ni endpoint manda hoy fecha_efectiva.
--
-- Flujos revisados (lectura de código, sin tocar la base):
--   - backend/app/routers/movimientos.py (POST): inserta persona_id, tipo_movimiento, motivo y registrado_por = caller.auth_user_id con el
--     cliente del caller; NUNCA manda fecha_efectiva ni creado_en (defaults). Cumple las reglas nuevas sin cambios.
--   - fn_usuario_bitacora_alta (05_) + trg_usuario_bitacora_alta: inserta el 'alta' con registrado_por = el propio usuario nuevo y
--     fecha_efectiva = now() al crear personas.usuario; el backend (routers/usuarios.py) y scripts/bootstrap_usuario_base.py lo hacen con
--     service_role (sin RLS, auth.role() = 'service_role'): ni la policy ni el trigger de hora lo afectan.
--   - Datos reales (SELECT de sólo lectura, 8-oct-2026): 2 filas, ambas 'alta' por el trigger, registrado_por = la propia persona y
--     creado_en = fecha_efectiva: ninguna viola las reglas nuevas. La tabla es inmutable (09_), así que no habría cómo corregir filas viejas;
--     no hace falta.
--   - Frontend: no manda estos campos.
--   - Ensayos propios (91_) insertan con creado_en explícito COMO DUEÑO: siguen funcionando (el trigger no toca al dueño).
--
-- Inventario de RLS/privilegios de este archivo:
--   personas.bitacora_movimiento_persona  policy de INSERT recreada (más estricta); SELECT y la inmutabilidad (09_) sin cambio.
--   fn_bitacora_persona_fija_hora          SECURITY INVOKER, SET search_path = personas, pg_temp; EXECUTE para nadie (función de trigger).
--   fn_bitacora_terminal_usuario_limpia_detalle  SECURITY INVOKER, SET search_path = tiempo, pg_temp; EXECUTE para nadie.
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP TRIGGER trg_bitacora_persona_fija_hora ON personas.bitacora_movimiento_persona; DROP FUNCTION personas.fn_bitacora_persona_fija_hora();
--   DROP TRIGGER trg_bitacora_terminal_usuario_a0_limpia_detalle ON tiempo.bitacora_movimiento_terminal_usuario;
--   DROP FUNCTION tiempo.fn_bitacora_terminal_usuario_limpia_detalle();
--   DROP POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona;  -- y recrearla como en 31_*.sql
--
-- Depende de: 09_personas_bitacora_inmutable.sql, 31_personas_rls_permiso_especifico.sql (policy que se reemplaza), 81_/88_ (bitácora de terminal)
-- Justificación: revisión de security (M1 y B2, 2026-10-08); lección de 31_: la RLS es la autorización real

-- ============================================================================
-- 1) Policy de INSERT humano
-- ============================================================================

DROP POLICY IF EXISTS bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona;

CREATE POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
    AND registrado_por = auth.uid()
    AND tipo_movimiento IN ('suspension', 'reactivacion', 'baja_definitiva')
  );

-- ============================================================================
-- 2) Hora fijada por la base y fecha_efectiva acotada para llamadores de la API
-- ============================================================================

CREATE FUNCTION personas.fn_bitacora_persona_fija_hora()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = personas, pg_temp
AS $$
DECLARE
  c_retroactivo_max_dias constant integer := 90;                 -- valor inicial ajustable
  c_futuro_max           constant interval := interval '5 minutes';  -- tolerancia de reloj; no hay movimientos futuros
BEGIN
  -- Sólo llamadores de la API: service_role (alta automática, bootstrap, scripts) y el dueño conservan lo que insertan.
  IF auth.role() IN ('anon', 'authenticated') THEN
    NEW.creado_en := now();
    IF NEW.fecha_efectiva > now() + c_futuro_max
       OR NEW.fecha_efectiva < now() - make_interval(days => c_retroactivo_max_dias) THEN
      RAISE EXCEPTION 'fecha_efectiva fuera de la ventana permitida (desde % días atrás hasta 5 minutos adelante)', c_retroactivo_max_dias
        USING ERRCODE = '22023', HINT = 'fecha_efectiva_invalida';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bitacora_persona_fija_hora
  BEFORE INSERT ON personas.bitacora_movimiento_persona
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_persona_fija_hora();

REVOKE EXECUTE ON FUNCTION personas.fn_bitacora_persona_fija_hora() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION personas.fn_bitacora_persona_fija_hora() IS
  '92_. BEFORE INSERT en personas.bitacora_movimiento_persona: para llamadores de la API (anon/authenticated) fija creado_en = now() y exige '
  'fecha_efectiva entre now() - 90 días y now() + 5 minutos (22023 / fecha_efectiva_invalida). service_role y el dueño no se tocan. '
  'SECURITY INVOKER, search_path = personas, pg_temp; sin EXECUTE para la API.';

-- ============================================================================
-- 3) (B2) Detalle de la bitácora de enrolamiento sin caracteres invisibles o de reordenamiento, también el de origen web
-- ============================================================================

CREATE FUNCTION tiempo.fn_bitacora_terminal_usuario_limpia_detalle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  IF NEW.detalle IS NOT NULL THEN
    NEW.detalle := replace(replace(NEW.detalle, chr(8232), ' '), chr(8233), ' ');
    NEW.detalle := regexp_replace(NEW.detalle, '[\u00AD\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\U000E0000-\U000E007F]', '', 'g');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_bitacora_terminal_usuario_a0_limpia_detalle
  BEFORE INSERT ON tiempo.bitacora_movimiento_terminal_usuario
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_bitacora_terminal_usuario_limpia_detalle();

REVOKE EXECUTE ON FUNCTION tiempo.fn_bitacora_terminal_usuario_limpia_detalle() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_bitacora_terminal_usuario_limpia_detalle() IS
  '92_ (B2 de security). BEFORE INSERT en la bitácora de enrolamiento: quita del detalle los caracteres de formato Unicode invisibles o de '
  'reordenamiento (U+00AD, U+061C, U+200B-200F, U+2028-202E, U+2060-2064, U+2066-2069, U+FEFF, U+E0000-E007F) y pasa U+2028/2029 a espacio. '
  'Corre ANTES de fn_bitacora_terminal_usuario_aplica (el nombre del trigger ordena antes: a0_ < aplica), de modo que el error_detalle que copia ese trigger '
  'a la alta ya viene limpio, y no cambia el resto del texto. SECURITY INVOKER, '
  'search_path = tiempo, pg_temp; sin EXECUTE para la API.';

-- ============================================================================
-- 4) (B2) Requisito de uso de fn_usuario_bitacora_alta anotado en su COMMENT (la función NO cambia)
-- ============================================================================

COMMENT ON FUNCTION personas.fn_usuario_bitacora_alta() IS
  'Implementa SCJ-PRO-01 paso A3. registrado_por = el propio usuario recién creado, porque en el alta todavía no hay "quién más" lo hizo — es un alta '
  'administrada por RH vía backend. 92_: el INSERT en personas.usuario debe hacerse SIEMPRE con service_role (backend/app/routers/usuarios.py y '
  'scripts/bootstrap_usuario_base.py lo hacen así); con el cliente del caller, la policy bitacora_insert_requiere_permiso (que no admite el tipo alta y '
  'exige registrado_por = auth.uid()) rechazaría el alta automática y la creación del usuario fallaría.';
