-- 127_tiempo_personas_hoy_en_hora_de_mexico.sql
-- «Hoy» en la base es la fecha de México, no la de UTC (P-055, con P-182 fusionada). Cambio sobre el esquema congelado (SCJ-ACT-03 V1.1 §V), aprobado por Diego
-- el 28-oct-2026 con el alcance de las 4 funciones extra (Nextcloud: Sistemas/Bitacora/2026-10-28_p055_fecha_mexico_cambio_esquema.md).
--
-- PROBLEMA. La base corre con TimeZone = UTC, así que CURRENT_DATE es la fecha de UTC. Entre las 18:00 y las 24:00 de la Ciudad de México (UTC-6) la base ya
-- cree que es «mañana»: una jornada que empieza mañana en México se trata como ya vigente (no se puede editar ni eliminar), la jornada en curso deja de ser
-- «la vigente hoy», el cierre que cae hoy se considera pasado, una baja toma la fecha de mañana y una vigencia nueva de parámetro o de configuración de terminal
-- empieza mañana (y cierra la anterior con la fecha de hoy). El backend ya usa la fecha de México desde el 21-oct (app/zona.py, P-176).
--
-- QUÉ HACE. CREATE OR REPLACE de las 10 funciones de tiempo/personas que usan CURRENT_DATE para decir «hoy», partiendo del cuerpo REAL de la base
-- (pg_get_functiondef del 28-oct-2026, copia en db/ensayos/vigente_127_fecha_mexico.sql), con UN solo cambio: CURRENT_DATE => personas.fn_hoy_mexico()
-- (113_, STABLE, INVOKER, search_path fijo; (now() AT TIME ZONE 'America/Mexico_City')::date). Nombre siempre calificado: varias no tienen search_path.
--   personas.fn_persona_sincroniza_baja()                         trigger; fecha_baja por omisión
--   tiempo.fn_jornada_asignada_protege_borrado()                   trigger (75_)
--   tiempo.fn_jornada_asignada_protege_vigencias()                 trigger (75_)
--   tiempo.fn_patron_semanal_solo_jornada_futura()                 trigger (75_)
--   tiempo.fn_jornada_en_curso_mover_limite(bigint, date)          RPC (76_)
--   tiempo.fn_jornada_futura_actualizar(bigint, varchar, date, jsonb, boolean, integer)   RPC (76_)
--   tiempo.fn_jornada_futura_eliminar(bigint)                      RPC (76_)
--   tiempo.fn_parametro_actualizar_valor(varchar, text, uuid)      RPC (60_/89_)
--   tiempo.fn_terminal_config_actualizar(text, text)               RPC DEFINER (89_/97_); se reescribe el comentario interno que decía que se mantenía CURRENT_DATE
--   tiempo.fn_terminal_config_valor(text)                          SQL STABLE DEFINER (89_)
-- En las 10, CURRENT_DATE significaba «hoy» (comparación con vigente_desde/vigente_hasta, o la fecha de una baja o de una vigencia nueva); ninguna lo usaba
-- con otro sentido. NO se tocan:
--   tiempo.fn_jornada_asignada_valida_cadena(): no usa CURRENT_DATE (solo encadena fechas entre filas).
--   tiempo.fn_terminal_inferir_huella_cambiar/_estado: usan (now() AT TIME ZONE 'UTC')::date A PROPÓSITO (97_ B2, ensayo_98 «medianoche UTC»); fuera del alcance
--   aprobado. Sus claves (terminal_inferir_huella_*) no las lee fn_terminal_config_valor ni las escribe fn_terminal_config_actualizar, así que no se mezclan.
--   DEFAULT y CHECK: ninguno usa CURRENT_DATE (solo now() en columnas timestamptz, que es un instante y no cambia).
--
-- ATRIBUTOS (gotcha de CREATE OR REPLACE): cada cuerpo repite lo que tiene hoy — LANGUAGE, STABLE, SECURITY DEFINER y SET search_path donde existen; las 8
--   INVOKER sin search_path siguen igual. Después se repiten explícitos el dueño (postgres), el EXECUTE exacto (REVOKE de PUBLIC, anon, authenticated y
--   service_role, y GRANT a los mismos roles que hoy) y el COMMENT (texto vigente + una frase de 127_). Sin cambios de proconfig ni de ACL: la sección 70 de
--   verificar_ddl.sql no cambia. fn_hoy_mexico ya tiene EXECUTE para authenticated y service_role (113_), que es lo que necesitan las INVOKER llamadas por la
--   API y los triggers que disparan esos roles; las DEFINER corren como postgres. No se abre a PUBLIC.
-- Sin ERRCODE ni HINT nuevos (registro_seguro.HINTS_CONOCIDOS no cambia). Mensajes iguales.
--
-- PRECONDICIÓN (bloque DO al inicio): ninguna fila de tiempo.parametro puede tener vigente_desde posterior a la fecha de México. Esa fila solo existe si alguien
--   editó un parámetro hoy después de las 18:00 de CDMX con el código viejo; con el nuevo, una edición la cerraría con vigente_hasta anterior a su vigente_desde
--   (tiempo.parametro no tiene CHECK de vigencia). Si aborta: aplicar al día siguiente antes de las 18:00 de CDMX. Conviene aplicar entre las 06:00 y las 18:00.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 127_*.sql`.
-- REVERSA (en una transacción): psql --single-transaction -f db/ensayos/vigente_127_fecha_mexico.sql (los cuerpos de antes; dueño, ACL y comentario se
--   repiten con este mismo bloque final si se quiere el texto viejo exacto del COMMENT, que está en ese archivo).
-- Verificador: sección 89 de verificar_ddl.sql (ninguna función de tiempo/personas con CURRENT_DATE, LOCALTIMESTAMP ni now()::date; las 10 usan fn_hoy_mexico).
-- Depende de: 60_, 75_, 76_, 89_, 97_, 113_
-- Justificación: SCJ-DEC-04, SCJ-ACT-03 §V

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM tiempo.parametro WHERE vigente_desde > personas.fn_hoy_mexico()) THEN
    RAISE EXCEPTION '127_: hay vigencias de tiempo.parametro que empiezan después de la fecha de México; aplicar antes de las 18:00 de CDMX de otro día';
  END IF;
END $$;

-- ---- personas.fn_persona_sincroniza_baja()
CREATE OR REPLACE FUNCTION personas.fn_persona_sincroniza_baja()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.estado = 'baja_definitiva' AND NEW.fecha_baja IS NULL THEN
    NEW.fecha_baja := personas.fn_hoy_mexico();
  ELSIF NEW.fecha_baja IS NOT NULL AND NEW.estado <> 'baja_definitiva' THEN
    NEW.estado := 'baja_definitiva';
  END IF;
  RETURN NEW;
END;
$function$;


-- ---- tiempo.fn_jornada_asignada_protege_borrado()
CREATE OR REPLACE FUNCTION tiempo.fn_jornada_asignada_protege_borrado()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.vigente_desde <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar una jornada que todavía no empezó (id %, vigente_desde %)',
      OLD.id, OLD.vigente_desde USING ERRCODE = '23514';
  END IF;

  IF OLD.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = OLD.persona_id AND j.id <> OLD.id
                  AND j.vigente_desde >= OLD.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar la última jornada de la cadena -- borrá desde el final hacia atrás (id %)',
      OLD.id USING ERRCODE = '23514';
  END IF;

  RETURN OLD;
END;
$function$;


-- ---- tiempo.fn_jornada_asignada_protege_vigencias()
CREATE OR REPLACE FUNCTION tiempo.fn_jornada_asignada_protege_vigencias()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_tiene_posterior boolean;
BEGIN
  IF OLD.persona_id IS DISTINCT FROM NEW.persona_id THEN
    RAISE EXCEPTION 'persona_id de una jornada asignada es inmutable (id %)', OLD.id
      USING ERRCODE = '23514';
  END IF;

  IF OLD.vigente_desde IS DISTINCT FROM NEW.vigente_desde THEN
    IF OLD.vigente_desde <= personas.fn_hoy_mexico() THEN
      RAISE EXCEPTION
        'No se puede mover la fecha de inicio de una jornada que ya empezó (id %, vigente_desde %)',
        OLD.id, OLD.vigente_desde USING ERRCODE = '23514';
    END IF;
    IF NEW.vigente_desde <= personas.fn_hoy_mexico() THEN
      RAISE EXCEPTION
        'Una jornada futura sólo puede moverse a otra fecha futura (id %, intento %)',
        OLD.id, NEW.vigente_desde USING ERRCODE = '23514';
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM tiempo.jornada_asignada j
      WHERE j.persona_id = OLD.persona_id AND j.id <> OLD.id
        AND j.vigente_desde >= OLD.vigente_desde
    ) INTO v_tiene_posterior;
    IF v_tiene_posterior THEN
      RAISE EXCEPTION
        'Sólo se puede mover la fecha de inicio de la última jornada de la cadena (id %)', OLD.id
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF OLD.vigente_desde <= personas.fn_hoy_mexico() AND (
       OLD.tipo_jornada                  IS DISTINCT FROM NEW.tipo_jornada
    OR OLD.descuento_comida_fija         IS DISTINCT FROM NEW.descuento_comida_fija
    OR OLD.minutos_descuento_comida_fija IS DISTINCT FROM NEW.minutos_descuento_comida_fija
    OR OLD.genera_alerta_horario         IS DISTINCT FROM NEW.genera_alerta_horario
  ) THEN
    RAISE EXCEPTION
      'De una jornada ya vigente sólo se puede mover vigente_hasta (id %)', OLD.id
      USING ERRCODE = '23514';
  END IF;

  -- Carve-out deliberado: OLD.vigente_hasta IS NULL (cerrar la fila abierta) queda SIN
  -- restringir -- es lo que hace fn_jornada_asignar_renovar y fn_jornada_futura_actualizar
  -- (archivo 76), incluido el caso de borde donde el cierre cae en el día de hoy.
  IF OLD.vigente_hasta IS DISTINCT FROM NEW.vigente_hasta AND OLD.vigente_hasta IS NOT NULL THEN
    IF OLD.vigente_hasta < personas.fn_hoy_mexico() THEN
      RAISE EXCEPTION
        'No se puede reabrir ni mover el cierre de una jornada que ya terminó (id %, vigente_hasta %)',
        OLD.id, OLD.vigente_hasta USING ERRCODE = '23514';
    END IF;
    IF NEW.vigente_hasta IS NOT NULL AND NEW.vigente_hasta < personas.fn_hoy_mexico() THEN
      RAISE EXCEPTION
        'El cierre de una jornada no puede quedar en el pasado (id %, intento %)',
        OLD.id, NEW.vigente_hasta USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;


-- ---- tiempo.fn_jornada_en_curso_mover_limite(bigint,date)
CREATE OR REPLACE FUNCTION tiempo.fn_jornada_en_curso_mover_limite(p_jornada_id bigint, p_vigente_hasta date)
 RETURNS tiempo.jornada_asignada
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_jornada   tiempo.jornada_asignada;
  v_siguiente tiempo.jornada_asignada;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF NOT (v_jornada.vigente_desde <= personas.fn_hoy_mexico()
          AND (v_jornada.vigente_hasta IS NULL OR v_jornada.vigente_hasta >= personas.fn_hoy_mexico())) THEN
    RAISE EXCEPTION
      'Sólo se puede mover la fecha de término de la jornada vigente hoy (id %)', p_jornada_id
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NULL THEN
    RAISE EXCEPTION
      'Esta jornada no tiene fecha de término ni un tramo planeado después -- para terminarla, '
      'asigná la jornada siguiente (id %)', p_jornada_id USING ERRCODE = 'SCJ03';
  END IF;

  IF p_vigente_hasta <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'La fecha de término debe ser posterior a hoy (intento %)', p_vigente_hasta
      USING ERRCODE = 'SCJ04';
  END IF;

  SELECT * INTO v_siguiente
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde > v_jornada.vigente_desde
  ORDER BY vigente_desde ASC LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Cadena inconsistente: la jornada % está cerrada pero no tiene tramo siguiente', p_jornada_id
      USING ERRCODE = 'SCJ06';
  END IF;

  IF v_siguiente.vigente_hasta IS NOT NULL THEN
    RAISE EXCEPTION
      'Hay más de un tramo planeado después -- eliminá los tramos futuros desde el final antes de '
      'mover esta fecha (id %)', p_jornada_id USING ERRCODE = 'SCJ05';
  END IF;

  UPDATE tiempo.jornada_asignada SET vigente_hasta = p_vigente_hasta
  WHERE id = p_jornada_id RETURNING * INTO v_jornada;

  UPDATE tiempo.jornada_asignada SET vigente_desde = p_vigente_hasta + 1 WHERE id = v_siguiente.id;

  RETURN v_jornada;
END;
$function$;


-- ---- tiempo.fn_jornada_futura_actualizar(bigint,character varying,date,jsonb,boolean,integer)
CREATE OR REPLACE FUNCTION tiempo.fn_jornada_futura_actualizar(p_jornada_id bigint, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean DEFAULT false, p_minutos_descuento_comida_fija integer DEFAULT NULL::integer)
 RETURNS tiempo.jornada_asignada
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_jornada           tiempo.jornada_asignada;
  v_predecesora_id    bigint;
  v_predecesora_desde date;
  v_actualizada       tiempo.jornada_asignada;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF v_jornada.vigente_desde <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'Sólo se puede editar una jornada que todavía no empezó (id %, vigente_desde %)',
      p_jornada_id, v_jornada.vigente_desde USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = v_jornada.persona_id AND j.id <> v_jornada.id
                  AND j.vigente_desde >= v_jornada.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede editar la última jornada de la cadena (id %)', p_jornada_id
      USING ERRCODE = 'SCJ03';
  END IF;

  IF p_vigente_desde <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'La jornada debe seguir empezando en una fecha futura (intento %)', p_vigente_desde
      USING ERRCODE = 'SCJ04';
  END IF;

  IF p_patron_semanal IS NULL OR jsonb_array_length(p_patron_semanal) = 0 THEN
    RAISE EXCEPTION 'El patrón semanal debe tener al menos un día' USING ERRCODE = 'SCJ06';
  END IF;

  SELECT id, vigente_desde INTO v_predecesora_id, v_predecesora_desde
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde < v_jornada.vigente_desde
  ORDER BY vigente_desde DESC LIMIT 1;

  IF v_predecesora_id IS NOT NULL AND p_vigente_desde <= v_predecesora_desde THEN
    RAISE EXCEPTION
      'La jornada no puede empezar antes ni el mismo día que la anterior (anterior empezó %)',
      v_predecesora_desde USING ERRCODE = 'SCJ05';
  END IF;

  UPDATE tiempo.jornada_asignada
  SET tipo_jornada = p_tipo_jornada, vigente_desde = p_vigente_desde,
      descuento_comida_fija = p_descuento_comida_fija,
      minutos_descuento_comida_fija = p_minutos_descuento_comida_fija,
      genera_alerta_horario = (p_tipo_jornada = 'normal')
  WHERE id = p_jornada_id
  RETURNING * INTO v_actualizada;

  IF v_predecesora_id IS NOT NULL THEN
    UPDATE tiempo.jornada_asignada SET vigente_hasta = p_vigente_desde - 1 WHERE id = v_predecesora_id;
  END IF;

  DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = p_jornada_id;
  INSERT INTO tiempo.patron_semanal (jornada_asignada_id, dia_semana, hora_entrada, hora_salida, minutos_comida)
  SELECT p_jornada_id, x.dia_semana, x.hora_entrada, x.hora_salida, COALESCE(x.minutos_comida, 0)
  FROM jsonb_to_recordset(p_patron_semanal) AS x(
    dia_semana varchar(10), hora_entrada time, hora_salida time, minutos_comida int
  );

  RETURN v_actualizada;
END;
$function$;


-- ---- tiempo.fn_jornada_futura_eliminar(bigint)
CREATE OR REPLACE FUNCTION tiempo.fn_jornada_futura_eliminar(p_jornada_id bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_jornada        tiempo.jornada_asignada;
  v_predecesora_id bigint;
BEGIN
  SELECT * INTO v_jornada FROM tiempo.jornada_asignada WHERE id = p_jornada_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La jornada asignada % no existe', p_jornada_id USING ERRCODE = 'SCJ01';
  END IF;

  IF v_jornada.vigente_desde <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar una jornada que todavía no empezó (id %, vigente_desde %)',
      p_jornada_id, v_jornada.vigente_desde USING ERRCODE = 'SCJ02';
  END IF;

  IF v_jornada.vigente_hasta IS NOT NULL
     OR EXISTS (SELECT 1 FROM tiempo.jornada_asignada j
                WHERE j.persona_id = v_jornada.persona_id AND j.id <> v_jornada.id
                  AND j.vigente_desde >= v_jornada.vigente_desde) THEN
    RAISE EXCEPTION
      'Sólo se puede eliminar la última jornada de la cadena (id %)', p_jornada_id
      USING ERRCODE = 'SCJ03';
  END IF;

  SELECT id INTO v_predecesora_id
  FROM tiempo.jornada_asignada
  WHERE persona_id = v_jornada.persona_id AND vigente_desde < v_jornada.vigente_desde
  ORDER BY vigente_desde DESC LIMIT 1;

  DELETE FROM tiempo.patron_semanal WHERE jornada_asignada_id = p_jornada_id;
  DELETE FROM tiempo.jornada_asignada WHERE id = p_jornada_id;

  IF v_predecesora_id IS NOT NULL THEN
    UPDATE tiempo.jornada_asignada SET vigente_hasta = NULL WHERE id = v_predecesora_id;
  END IF;
END;
$function$;


-- ---- tiempo.fn_parametro_actualizar_valor(character varying,text,uuid)
CREATE OR REPLACE FUNCTION tiempo.fn_parametro_actualizar_valor(p_clave character varying, p_valor text, p_registrado_por uuid)
 RETURNS tiempo.parametro
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_hoy          date := personas.fn_hoy_mexico();
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
$function$;


-- ---- tiempo.fn_patron_semanal_solo_jornada_futura()
CREATE OR REPLACE FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_jornada_id    bigint;
  v_vigente_desde date;
BEGIN
  v_jornada_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.jornada_asignada_id ELSE NEW.jornada_asignada_id END;

  SELECT vigente_desde INTO v_vigente_desde
  FROM tiempo.jornada_asignada WHERE id = v_jornada_id;

  IF v_vigente_desde IS NOT NULL AND v_vigente_desde <= personas.fn_hoy_mexico() THEN
    RAISE EXCEPTION
      'El patrón semanal de una jornada que ya empezó no se puede modificar ni borrar (jornada %)',
      v_jornada_id USING ERRCODE = '23514';
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;


-- ---- tiempo.fn_terminal_config_actualizar(text,text)
CREATE OR REPLACE FUNCTION tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'tiempo', 'personas', 'pg_temp'
AS $function$
DECLARE
  v_actor        uuid;
  v_cat          record;
  v_valor        integer;
  v_texto        text;
  -- 127_: «hoy» es la fecha de México (personas.fn_hoy_mexico()), igual que las demás vigencias de tiempo.parametro (antes era la fecha de la zona de la sesión, UTC).
  -- El interruptor de la activación por huella usa fecha UTC explícita en sus propias funciones (fn_terminal_inferir_huella_*), no aquí.
  v_hoy          date := personas.fn_hoy_mexico();
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
$function$;


-- ---- tiempo.fn_terminal_config_valor(text)
CREATE OR REPLACE FUNCTION tiempo.fn_terminal_config_valor(p_clave text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'tiempo', 'pg_temp'
AS $function$
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
      AND p.vigente_desde <= personas.fn_hoy_mexico()
      AND (p.vigente_hasta IS NULL OR p.vigente_hasta >= personas.fn_hoy_mexico())
    ORDER BY p.vigente_desde DESC
    LIMIT 1
  ) v ON true;
$function$;



-- ---- dueño, EXECUTE y comentario, explícitos (iguales a los vigentes)
ALTER FUNCTION personas.fn_persona_sincroniza_baja() OWNER TO postgres;
ALTER FUNCTION tiempo.fn_jornada_asignada_protege_borrado() OWNER TO postgres;
ALTER FUNCTION tiempo.fn_jornada_asignada_protege_vigencias() OWNER TO postgres;
ALTER FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura() OWNER TO postgres;
ALTER FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) OWNER TO postgres;
ALTER FUNCTION tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer) OWNER TO postgres;
ALTER FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) OWNER TO postgres;
ALTER FUNCTION tiempo.fn_parametro_actualizar_valor(character varying, text, uuid) OWNER TO postgres;
ALTER FUNCTION tiempo.fn_terminal_config_actualizar(text, text) OWNER TO postgres;
ALTER FUNCTION tiempo.fn_terminal_config_valor(text) OWNER TO postgres;

REVOKE ALL ON FUNCTION personas.fn_persona_sincroniza_baja() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_jornada_asignada_protege_borrado() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_jornada_asignada_protege_vigencias() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_parametro_actualizar_valor(character varying, text, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION tiempo.fn_terminal_config_valor(text) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint, date) TO authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_futura_actualizar(bigint, character varying, date, jsonb, boolean, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_parametro_actualizar_valor(character varying, text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_actualizar(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_config_valor(text) TO service_role;

COMMENT ON FUNCTION personas.fn_persona_sincroniza_baja() IS $c$Sincroniza estado y fecha_baja en ambos sentidos. Ver SCJ-MOD-01 §III y decisión de sesión 2026-08-31. 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_jornada_asignada_protege_borrado() IS $c$BEFORE DELETE en tiempo.jornada_asignada. Sólo permite borrar una fila con vigente_desde futura Y que sea la última de la cadena de esa persona (sin vigente_hasta, sin ninguna otra fila con vigente_desde >= la suya). RAISE con ERRCODE 23514, red de último recurso -- la autorización real de quién puede intentar el DELETE sigue siendo RLS (39_tiempo_rls_jornada_patron.sql). 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_jornada_asignada_protege_vigencias() IS $c$BEFORE UPDATE en tiempo.jornada_asignada. persona_id inmutable siempre; vigente_desde sólo se puede mover si la fila todavía no empezó, a otra fecha futura, y sólo si es la última de la cadena; tipo/patrón/descuento de una fila ya vigente son inmutables (sólo vigente_hasta se puede tocar); vigente_hasta no se puede reabrir/mover si ya quedó en el pasado, ni movida a una fecha pasada. RAISE con ERRCODE 23514 (check_violation) -- no SCJxx, es red de último recurso, cae en el 422 genérico existente (jornada_asignada.py:163). RLS sigue siendo la autorización de quién puede intentar el UPDATE (39_tiempo_rls_jornada_patron.sql); este trigger decide qué se le permite cambiar una vez autorizado. 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_jornada_en_curso_mover_limite(bigint,date) IS $c$RPC transaccional de "mover el límite de la jornada en curso": cambia vigente_hasta de la jornada vigente hoy a una fecha estrictamente futura, y desplaza vigente_desde de la única jornada siguiente para que la cadena quede sin hueco ni traslape. Sólo aplica si la jornada en curso ya tiene una fecha de término planeada (vigente_hasta NOT NULL) y esa siguiente jornada es a su vez la última de la cadena (sin su propio vigente_hasta) -- con más de un tramo planeado después, hay que eliminar los futuros desde el final primero (fn_jornada_futura_eliminar). La nueva fecha exige estrictamente futura sin el carve-out del caso de borde de fn_jornada_futura_actualizar (ese carve-out sólo aplica cuando el cierre de la predecesora es un EFECTO de mover la fecha de inicio de la sucesora, no cuando se mueve directo con este RPC). SECURITY INVOKER -- RLS es la autorización real, jornada_asignada_edicion. Señales de conflicto: SCJ01 la jornada no existe (404), SCJ02 no es la vigente hoy (422), SCJ03 es la fila abierta sin fecha de término ni sucesora (422), SCJ04 la nueva fecha no es estrictamente futura (422), SCJ05 la sucesora no es la última de la cadena (422), SCJ06 cadena inconsistente -- cerrada sin sucesora (422, debería ser inalcanzable si el resto de las protecciones de 75_*.sql se mantiene). 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_jornada_futura_actualizar(bigint,character varying,date,jsonb,boolean,integer) IS $c$RPC transaccional de "editar jornada futura": reemplazo TOTAL (no parcial) de tipo_jornada, vigente_desde, descuento de comida y patrón semanal completo, en una sola transacción. Sólo aplica a una jornada con vigente_desde futura que además sea la última de la cadena. Si mueve vigente_desde, ajusta vigente_hasta de la predecesora (nueva.vigente_desde - 1 día, mismo cálculo que fn_jornada_asignar_renovar/40_*.sql) -- incluye el caso de borde aprobado donde la nueva fecha es hoy + 1, forzando a la predecesora en curso a cerrar hoy mismo. genera_alerta_horario se deriva aquí de tipo_jornada, igual que fn_jornada_asignar_renovar. SECURITY INVOKER -- RLS es la autorización real, jornada_asignada_edicion + patron_semanal_edicion. Señales de conflicto: SCJ01 la jornada no existe (404), SCJ02 ya empezó (422), SCJ03 no es la última de la cadena (422), SCJ04 la nueva fecha no es futura (422), SCJ05 la nueva fecha no deja pasar a la predecesora (422), SCJ06 patrón semanal vacío (422). 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_jornada_futura_eliminar(bigint) IS $c$RPC transaccional de "eliminar jornada futura": borra el patron_semanal y la fila de jornada_asignada, y si existe una predecesora la reabre (vigente_hasta = NULL). Sólo aplica a una jornada con vigente_desde futura que además sea la última de la cadena de esa persona (sin vigente_hasta, sin otra fila con vigente_desde posterior o igual). SECURITY INVOKER -- RLS de jornada_asignada/patron_semanal (39_tiempo_rls_jornada_patron.sql) es la autorización real, jornada_asignada_edicion + patron_semanal_edicion. Los triggers de 75_tiempo_jornada_asignada_proteccion_vigencias.sql corren igual sobre cada DELETE/UPDATE que hace este RPC -- éste es sólo el que da el mensaje/ERRCODE específico. Señales de conflicto: SCJ01 la jornada no existe (backend mapea a 404), SCJ02 ya empezó (422), SCJ03 no es la última de la cadena (422). 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_parametro_actualizar_valor(character varying,text,uuid) IS $c$RPC transaccional de "actualizar valor de parámetro": si no hay vigencia activa con esa clave, señaliza con RAISE EXCEPTION ... USING ERRCODE = 'SCJ02' (backend lo mapea a 404). Si la vigencia activa es de hoy, corrige valor/registrado_por in-place (mismo día = misma vigencia). Si no, cierra la vigencia activa (vigente_hasta = hoy - 1) e inserta la vigencia nueva desde hoy, en una sola transacción. 89_: rechaza con SCJ17 / clave_reservada las claves terminal_%, que sólo se editan con fn_terminal_config_actualizar (permiso terminal_config_edicion). 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_patron_semanal_solo_jornada_futura() IS $c$BEFORE UPDATE OR DELETE en tiempo.patron_semanal. Bloquea tocar/borrar una fila de patrón que cuelga de una jornada_asignada con vigente_desde <= hoy. INSERT deliberadamente sin este trigger -- residual conocido, NO benigno: una fila insertada así sobre una jornada ya vigente queda irreversible por la vía normal, el propio trigger bloquea su propia corrección/borrado -- sólo se limpia con DISABLE TRIGGER de superusuario. Incidente real 2026-09-11 (patron_semanal id=21). Ver cabecera de 75_*.sql para el detalle completo. 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_terminal_config_actualizar(text,text) IS $c$89_/97_. Edita una de las 5 claves terminal_* del catálogo de tiempo.parametro: exige persona activa y terminal_config_edicion DENTRO (42501/sin_permiso), clave en la lista blanca (22023/clave_no_editable; las dos claves del interruptor de la activación por huella se rechazan siempre: solo fn_terminal_inferir_huella_cambiar) y entero dentro de su rango (22023/valor_invalido), deriva el autor de auth.uid() y versiona por vigencia (borde inclusivo; el mismo día corrige en sitio). Mensajes fijos + HINT estable. Devuelve {resultado: actualizada | sin_cambio, clave, valor, vigente_desde}. SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE solo authenticated. 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
COMMENT ON FUNCTION tiempo.fn_terminal_config_valor(text) IS $c$89_. Valor vigente de una clave terminal_* para los jobs del backend: acotado a su rango; si falta o está mal formado devuelve el valor por defecto; NULL si la clave no es del catálogo. Nunca falla por un parámetro corrupto. SECURITY DEFINER, search_path = tiempo, pg_temp; EXECUTE sólo service_role. 127_: «hoy» es personas.fn_hoy_mexico() (fecha de America/Mexico_City), no la fecha de la sesión (UTC).$c$;
