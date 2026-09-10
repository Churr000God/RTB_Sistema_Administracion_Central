-- 66_tiempo_ausencia_descuento_pausa_y_confianza.sql
-- Dos correcciones a la fórmula de "jornada completa" que fn_ausencia_resuelve_excepcion escribe
-- en tiempo.dia.horas_totales al resolver una ausencia:
--
-- 1. La fórmula restaba patron_semanal.minutos_comida -- un dato por patrón/persona que en la
--    práctica nunca se carga con cuidado real (dato de ejemplo). Pasa a restar el parámetro
--    global descuento_pausa_no_registrada_min (mismo que ya usa backend/app/batches/cierre_dia.py
--    desde el corte anterior) -- una sola fuente de verdad para "cuánto se descuenta por pausa no
--    registrada", en vez de un campo por patrón que nadie mantiene. Constante de respaldo (60)
--    duplicada a propósito con cierre_dia.py::DESCUENTO_PAUSA_POR_DEFECTO_MIN -- no hay forma
--    limpia de compartir una constante entre Python y SQL; si el valor por defecto cambia, hay
--    que tocar los dos lados.
-- 2. tipo_jornada nunca se miraba en esta función -- una persona de_confianza con una ausencia
--    resuelta (incluso rechazada) podía terminar con horas_totales=0 si no tenía patron_semanal
--    cargado (COALESCE(...,0) de la fórmula vieja), contradiciendo SCJ-PRO-14 ("de confianza
--    siempre NULL, nunca un número"). Se agrega una excepción DELIBERADA, confirmada con el
--    usuario: para de_confianza, cualquier ausencia resuelta (autorizada o rechazada) pone la
--    jornada completa neta -- "su horario no marca faltas", nunca 0. Si no hay patrón cargado
--    para calcular esa jornada completa, cae a NULL (nunca 0, para no leerse como "faltó") --
--    respeta el espíritu original de SCJ-PRO-14 como último recurso, no como regla general. Nota
--    de esta excepción agregada aparte en
--    docs/07-procesos/SCJ-PRO-14_Proceso_Batch_de_Confianza_V1_0.md (edición de doc, fuera de
--    este DDL).
--
-- CORRECCIÓN IMPORTANTE al pedido original: la función es SECURITY DEFINER con
-- SET search_path = tiempo, pg_temp desde 51_tiempo_fn_ausencia_resuelve_excepcion_security_
-- definer.sql -- necesario porque escribe tiempo.dia, que humanos no pueden tocar por RLS directo
-- (sólo batches con service_role). CREATE OR REPLACE FUNCTION sin repetir esas cláusulas las
-- resetea a los valores por defecto (SECURITY INVOKER, sin search_path fijo) -- NO las hereda de
-- la definición anterior. Si este archivo se hubiera escrito literal como "CREATE OR REPLACE
-- FUNCTION ... RETURNS trigger AS $$ ... $$ LANGUAGE plpgsql;" sin repetir
-- "SECURITY DEFINER SET search_path = tiempo, pg_temp", habría reintroducido en silencio el mismo
-- error de RLS que 51_*.sql arregló ("new row violates row-level security policy for table dia")
-- en la primera resolución de ausencia real después de este corte. Se repiten explícitas abajo.
-- Depende de: 02_tiempo.sql, 51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql,
--   60_tiempo_parametro_vigencia_y_autor.sql (descuento_pausa_no_registrada_min ya es una de las
--   8 claves editables de tiempo.parametro)
-- Justificación: SCJ-PRO-08, SCJ-PRO-12, SCJ-PRO-14 (excepción deliberada documentada en el doc
--   de proceso, no en este archivo)

CREATE OR REPLACE FUNCTION tiempo.fn_ausencia_resuelve_excepcion()
RETURNS trigger AS $$
DECLARE
  v_fecha                   date;
  v_jornada_id              bigint;
  v_tipo_jornada            varchar(20);
  v_dia_semana              varchar(10);
  v_jornada_completa_horas  numeric(6,2);
  v_descuento_min           numeric(6,2);
  v_jornada_completa_neta   numeric(6,2);
  v_horas_totales           numeric(5,2);
BEGIN
  IF NEW.estado_autorizacion NOT IN ('autorizada', 'rechazada') THEN
    RETURN NEW; -- sigue pendiente, no se cierra la excepción ni se materializa el día
  END IF;

  IF NEW.estado_autorizacion = 'autorizada' THEN
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia autorizada, carga tardía'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  ELSE
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia rechazada (falta injustificada)'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  END IF;

  -- SCJ-PRO-12 (SCJ-PRA-01 #13): materializa tiempo.dia para cada fecha del rango — sin esto, el
  -- día de una ausencia ya resuelta se queda 'abierto' para siempre, porque el batch de cierre de
  -- día nunca vuelve a tocarlo (ver SCJ-PRO-12 §III, rama G1/G4). ON CONFLICT sólo actualiza si el
  -- día seguía 'abierto' — nunca pisa un día que ya se resolvió por otra vía.
  FOR v_fecha IN
    SELECT generate_series(NEW.fecha_inicio::timestamp, NEW.fecha_fin::timestamp, interval '1 day')::date
  LOOP
    -- tipo_jornada hace falta SIEMPRE ahora (antes sólo se resolvía jornada_asignada dentro de la
    -- rama de los 3 tipos que "cuentan como trabajado") -- de_confianza necesita esta misma
    -- resolución incluso cuando la ausencia es rechazada.
    SELECT ja.id, ja.tipo_jornada INTO v_jornada_id, v_tipo_jornada
    FROM tiempo.jornada_asignada ja
    WHERE ja.persona_id = NEW.persona_id
      AND ja.vigente_desde <= v_fecha
      AND (ja.vigente_hasta IS NULL OR ja.vigente_hasta >= v_fecha)
    ORDER BY ja.vigente_desde DESC
    LIMIT 1;

    v_dia_semana := (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                    [EXTRACT(ISODOW FROM v_fecha)::int];

    -- Jornada completa pactada, SIN restar minutos_comida (ese término se quita -- pasa a vivir
    -- sólo en el parámetro global de abajo).
    SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (ps.hora_salida - ps.hora_entrada)) / 3600.0), 0)
      INTO v_jornada_completa_horas
    FROM tiempo.patron_semanal ps
    WHERE ps.jornada_asignada_id = v_jornada_id AND ps.dia_semana = v_dia_semana;

    -- Descuento de pausa no registrada vigente a v_fecha -- mismo patrón que la tolerancia de
    -- fn_marca_valida_revision (02_tiempo.sql:746-749). 60 min de respaldo si no hay ninguna fila
    -- (igual valor por defecto que cierre_dia.py::DESCUENTO_PAUSA_POR_DEFECTO_MIN).
    SELECT COALESCE(
      (SELECT valor::numeric FROM tiempo.parametro
         WHERE clave = 'descuento_pausa_no_registrada_min' AND vigente_desde <= v_fecha
         ORDER BY vigente_desde DESC LIMIT 1),
      60
    ) INTO v_descuento_min;

    v_jornada_completa_neta := GREATEST(0, v_jornada_completa_horas - v_descuento_min / 60.0);

    IF v_tipo_jornada = 'de_confianza' THEN
      -- SCJ-PRO-14 decía siempre NULL; excepción deliberada confirmada con el usuario: una
      -- ausencia resuelta (cualquier tipo, incluso rechazada) SIEMPRE pone la jornada completa
      -- para de_confianza -- "su horario no marca faltas". Si no hay patrón cargado, cae a NULL
      -- (nunca 0, para no leerse como "faltó" -- respeta el espíritu original de SCJ-PRO-14 como
      -- último recurso, no como regla general).
      IF v_jornada_completa_neta > 0 THEN
        v_horas_totales := v_jornada_completa_neta;
      ELSE
        v_horas_totales := NULL;
      END IF;
    ELSIF NEW.estado_autorizacion = 'autorizada'
          AND NEW.tipo_de_ausencia IN ('vacaciones', 'permiso_con_goce', 'incapacidad') THEN
      -- Neutro: cuenta como si hubiera trabajado la jornada completa pactada ese día.
      v_horas_totales := v_jornada_completa_neta;
    ELSE
      -- permiso_sin_goce autorizado, o falta rechazada: no cuenta como trabajado -- la deuda la
      -- recoge sola el corte quincenal al comparar horas esperadas contra contabilizadas.
      v_horas_totales := 0;
    END IF;

    INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, origen)
    VALUES (NEW.persona_id, v_fecha, 'cerrado', v_horas_totales, 'ausencia_autorizada')
    ON CONFLICT (persona_id, fecha) DO UPDATE
      SET estado = 'cerrado', horas_totales = EXCLUDED.horas_totales, origen = 'ausencia_autorizada'
      WHERE tiempo.dia.estado = 'abierto';
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = tiempo, pg_temp;

COMMENT ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() IS
  'Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion '
  'por día sin checada, la resuelve sola — RH no tiene que cerrarla a mano. Un rechazo también '
  'cuenta como resolución (ya hay una decisión humana, aunque haya sido negativa). Sólo pendiente '
  'no toca nada. Además materializa tiempo.dia para cada fecha del rango (SCJ-PRO-12, SCJ-PRA-01 '
  '#13): vacaciones/permiso_con_goce/incapacidad autorizados cuentan como jornada completa neta '
  '(jornada pactada menos descuento_pausa_no_registrada_min vigente, parámetro global -- '
  '66_tiempo_ausencia_descuento_pausa_y_confianza.sql, ya no resta patron_semanal.minutos_comida); '
  'permiso_sin_goce autorizado o falta rechazada, cero. Excepción deliberada para '
  'tipo_jornada=de_confianza (contradice a propósito SCJ-PRO-14 "siempre NULL, nunca un número" -- '
  'ver nota en docs/07-procesos/SCJ-PRO-14_*.md): cualquier ausencia resuelta, incluso rechazada, '
  'pone la jornada completa neta; NULL sólo si no hay patrón cargado para calcularla (nunca 0). '
  'SECURITY DEFINER + search_path fijo (tiempo, pg_temp) desde 2026-09-06: necesita escribir '
  'tiempo.dia, que humanos nunca deben tocar por RLS directo -- ver '
  '51_tiempo_fn_ausencia_resuelve_excepcion_security_definer.sql.';
