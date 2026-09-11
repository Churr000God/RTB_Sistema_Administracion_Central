-- 72_tiempo_fn_marca_valida_revision_genera_alerta_horario.sql
-- Fix de bug real (2026-09-11): fn_marca_valida_revision (02_tiempo.sql:684-770) insertaba la
-- excepcion fuera_de_horario para CUALQUIER jornada vigente sin leer
-- tiempo.jornada_asignada.genera_alerta_horario -- columna que existe justo para esto
-- (02_tiempo.sql:101-105: "false para flexible/de_confianza -- sólo importa el total de horas, no
-- el horario exacto"). Resultado real: persona con jornada flexible (genera_alerta_horario=false)
-- recibió una excepcion fuera_de_horario falsa (excepcion.id=1, marca_id=2).
--
-- Depende de: 02_tiempo.sql. Sin ALTER FUNCTION posterior sobre fn_marca_valida_revision en todo
-- db/ddl/*.sql (confirmado por grep antes de escribir este archivo) -- SECURITY DEFINER y
-- SET search_path = tiempo, personas, pg_temp se repiten explícitos de cualquier forma, por ser
-- el mismo CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION tiempo.fn_marca_valida_revision()
RETURNS trigger
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_persona_activa       boolean;
  v_dia_estado            varchar(20);
  v_momento_local         timestamp;
  v_fecha_local           date;
  v_hora_local            time;
  v_dia_semana            varchar(10);
  v_jornada_id            bigint;
  v_genera_alerta_horario boolean;
  v_tolerancia_min        int;
  v_dentro_horario        boolean;
BEGIN
  -- reloj_no_sincronizado: el origen ya lo reporta, no se deriva aquí.
  IF NEW.estado_reloj <> 'sincronizado' THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'reloj_no_sincronizado');
  END IF;

  -- persona_inactiva: respaldo del lado servidor. El terminal ya filtra esto contra su caché
  -- local (sincronizada cada noche) y no debería llegar a mandar la marca — esto cubre el hueco
  -- entre sincronizaciones, o cualquier otro origen que no filtre.
  SELECT (estado = 'activo') INTO v_persona_activa
  FROM personas.persona WHERE id = NEW.persona_id;
  IF v_persona_activa IS NOT TRUE THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'persona_inactiva');
  END IF;

  -- Hora y fecha local reconstruidas — nunca se almacenan, SCJ-ESP-01 §VII.3.
  v_momento_local := (NEW.momento_dispositivo AT TIME ZONE 'UTC') + (NEW.desfase_local)::interval;
  v_fecha_local := v_momento_local::date;
  v_hora_local := v_momento_local::time;

  -- dia_cerrado: marca tardía sobre un día ya no abierto. Nunca lo reabre, sólo se señala
  -- (SCJ-ESP-01 §VI.2, confirmado 2026-09-05: "no se reabre" significa que no dispara recálculo,
  -- no que la marca se rechace — la evidencia nunca se descarta, SCJ-CDT-01 §II.5).
  SELECT estado INTO v_dia_estado
  FROM tiempo.dia WHERE persona_id = NEW.persona_id AND fecha = v_fecha_local;
  IF v_dia_estado IS NOT NULL AND v_dia_estado <> 'abierto' THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'dia_cerrado');
  END IF;

  -- fuera_de_horario: contra el patrón semanal vigente de esa fecha, con tolerancia de retardo.
  -- Si la persona no tiene jornada vigente ese día, no se evalúa aquí — eso es un problema de
  -- asignación de jornada, no de esta marca. Si la jornada vigente tiene genera_alerta_horario =
  -- false (flexible/de_confianza, SCJ-PRO-09), tampoco se evalúa: para esos tipos sólo importa el
  -- total de horas, no el horario exacto contra patron_semanal (02_tiempo.sql:101-105). Si sí
  -- tiene jornada vigente con genera_alerta_horario = true pero ese día de la semana no tiene fila
  -- en patron_semanal, SÍ se evalúa: el EXISTS de abajo da false (no hay ninguna fila con la que
  -- comparar) y eso marca fuera_de_horario, correctamente -- fichar un día que el patrón no
  -- contempla es justo el caso que este motivo debe señalar.
  SELECT ja.id, ja.genera_alerta_horario INTO v_jornada_id, v_genera_alerta_horario
  FROM tiempo.jornada_asignada ja
  WHERE ja.persona_id = NEW.persona_id
    AND ja.vigente_desde <= v_fecha_local
    AND (ja.vigente_hasta IS NULL OR ja.vigente_hasta >= v_fecha_local)
  ORDER BY ja.vigente_desde DESC
  LIMIT 1;

  IF v_jornada_id IS NOT NULL AND v_genera_alerta_horario THEN
    v_dia_semana := (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                    [EXTRACT(ISODOW FROM v_momento_local)::int];

    SELECT COALESCE(valor::int, 0) INTO v_tolerancia_min
    FROM tiempo.parametro
    WHERE clave = 'tolerancia_retardo_min' AND vigente_desde <= v_fecha_local
    ORDER BY vigente_desde DESC LIMIT 1;

    SELECT EXISTS (
      SELECT 1 FROM tiempo.patron_semanal ps
      WHERE ps.jornada_asignada_id = v_jornada_id
        AND ps.dia_semana = v_dia_semana
        AND v_hora_local BETWEEN (ps.hora_entrada - make_interval(mins => v_tolerancia_min))
                              AND (ps.hora_salida  + make_interval(mins => v_tolerancia_min))
    ) INTO v_dentro_horario;

    IF NOT v_dentro_horario THEN
      INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'fuera_de_horario');
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM tiempo.excepcion WHERE marca_id = NEW.id) THEN
    UPDATE tiempo.marca SET requiere_revision = true WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_marca_valida_revision() IS
  'SCJ-PRO-11. Calcula reloj_no_sincronizado, persona_inactiva, dia_cerrado y fuera_de_horario al '
  'llegar una marca — el quinto motivo, plantilla_desconocida, nace en Operación y no se calcula '
  'aquí. SECURITY DEFINER: terminal_checador sólo tiene INSERT en tiempo.marca, esta función '
  'necesita más lectura de la que ese rol debe tener directamente. fuera_de_horario sólo se evalúa '
  'cuando la jornada vigente tiene genera_alerta_horario = true (72_*.sql, 2026-09-11) — '
  'flexible/de_confianza no comparan contra patron_semanal.';
