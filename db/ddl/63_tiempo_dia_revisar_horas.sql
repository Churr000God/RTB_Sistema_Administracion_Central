-- 63_tiempo_dia_revisar_horas.sql
-- Hueco encontrado por el usuario probando la pantalla de Días en vivo (día 7 y 8 de sep,
-- Administrador del Sistema, ver bitácora): fn_dia_revisar (62_tiempo_dia_revision.sql) sólo
-- cambiaba estado -- horas_totales seguía en NULL para siempre tras revisar, y el tramo asociado
-- se quedaba mostrando "En curso"/"Sin clasificar" indefinidamente. Ya estaba anotado como
-- pendiente a propósito en docs/01-analisis/SCJ-PRA-01_Preguntas_Abiertas_V1_0.md #14: un día
-- bloqueado es, por definición, un caso que el sistema no puede calcular solo -- las horas las
-- escribe RH a mano al revisar, no se auto-calculan desde marcas ni desde la jornada pactada.
--
-- CREATE OR REPLACE porque es la MISMA función (mismo nombre, mismo propósito) -- pero Postgres
-- exige DROP explícito cuando cambia la firma de parámetros (bigint) -> (bigint, numeric), no basta
-- CREATE OR REPLACE solo. El DROP se lleva GRANT/REVOKE de la función vieja -- se repiten al final
-- sobre la firma nueva.
-- Depende de: 62_tiempo_dia_revision.sql

DROP FUNCTION tiempo.fn_dia_revisar(bigint);

CREATE OR REPLACE FUNCTION tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)
RETURNS tiempo.dia AS $$
DECLARE
  v_estado_actual  varchar(20);
  v_revisor_id     uuid;
  v_filas          integer;
  v_resultado      tiempo.dia;
BEGIN
  IF p_horas_totales IS NULL OR p_horas_totales < 0 OR p_horas_totales > 24 THEN
    RAISE EXCEPTION 'Horas trabajadas inválidas: % (debe estar entre 0 y 24)', p_horas_totales
      USING ERRCODE = 'SCJ08';
  END IF;

  SELECT estado INTO v_estado_actual
  FROM tiempo.dia
  WHERE id = p_dia_id;

  IF v_estado_actual IS NULL THEN
    RAISE EXCEPTION 'El día % no existe', p_dia_id USING ERRCODE = 'SCJ06';
  END IF;

  IF v_estado_actual <> 'bloqueado' THEN
    RAISE EXCEPTION
      'El día % no está bloqueado (estado=%) -- alguien más se adelantó o nunca requirió revisión',
      p_dia_id, v_estado_actual
      USING ERRCODE = 'SCJ07';
  END IF;

  SELECT u.persona_id INTO v_revisor_id
  FROM personas.usuario u
  WHERE u.auth_user_id = auth.uid();

  UPDATE tiempo.dia
  SET estado = 'revisado', revisado_por = v_revisor_id, revisado_en = now(),
      horas_totales = p_horas_totales
  WHERE id = p_dia_id AND estado = 'bloqueado';

  GET DIAGNOSTICS v_filas = ROW_COUNT;
  IF v_filas = 0 THEN
    RAISE EXCEPTION
      'El día % dejó de estar bloqueado entre la verificación y la actualización', p_dia_id
      USING ERRCODE = 'SCJ07';
  END IF;

  SELECT * INTO v_resultado FROM tiempo.dia WHERE id = p_dia_id;

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_dia_revisar(bigint, numeric) IS
  'RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH '
  '-- un día bloqueado es, por definición, un caso que el sistema no puede calcular solo. Única '
  'transición bloqueado -> revisado alcanzable por un humano. SECURITY INVOKER -- '
  'dia_update_revision es la autorización real. Señales de conflicto: ERRCODE SCJ06 (día no '
  'existe/no visible), SCJ07 (ya no está bloqueado, incluida la carrera de dos revisiones '
  'simultáneas), SCJ08 (horas_totales fuera de [0, 24] o NULL) -- ver cabecera de '
  '63_tiempo_dia_revisar_horas.sql para el mapeo exacto que debe hacer backend.';

GRANT EXECUTE ON FUNCTION tiempo.fn_dia_revisar(bigint, numeric) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_dia_revisar(bigint, numeric) FROM PUBLIC;
