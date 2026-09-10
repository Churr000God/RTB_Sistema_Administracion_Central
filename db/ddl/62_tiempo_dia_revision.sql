-- 62_tiempo_dia_revision.sql
-- Primer camino humano de escritura sobre tiempo.dia (SCJ-PRO-07..14 sólo la leían; la escriben
-- siempre los batches con service_role, 44_tiempo_rls_dia_corrida_batch_lectura.sql). Nace de la
-- pantalla de Días (/tiempo/dias): SCJ-DEC-06 exige que bloqueado -> revisado sea una intervención
-- explícita de RH, demostrable (quién y cuándo) -- hoy esa transición no tiene ningún camino, ni
-- de permiso, ni de RLS, ni de endpoint. Un solo archivo porque las 5 piezas (columnas + permiso +
-- mapeo + policy + RPC) son un cambio atómico con orden obligatorio, mismo criterio que
-- 45_permiso_corrida_batch_migracion_inicial.sql.
-- Depende de: 02_tiempo.sql, 21_personas_permiso.sql, 33_permiso_tiempo_migracion_inicial.sql,
--   34_puesto_permiso_tiempo_mapeo_inicial.sql, 41_tiempo_rls_deny_default.sql,
--   44_tiempo_rls_dia_corrida_batch_lectura.sql, 48_tiempo_rls_correccion_excepcion.sql,
--   50_tiempo_fn_ausencia_resolver.sql
-- Justificación: SCJ-DEC-06

-- ============================================================================
-- 1) Columnas de auditoría -- tiempo.dia no tenía ninguna (ni creado_en, ni autor). Sin estas
-- columnas el sistema sabe QUE alguien revisó pero no QUIÉN ni CUÁNDO. Nullable, sin backfill:
-- ningún día bloqueado/cerrado/abierto existente fue revisado por un humano todavía. Verificado
-- que ningún select("*") sobre tiempo.dia existe en el repo -- agregar columnas no rompe nada.
-- ============================================================================

ALTER TABLE tiempo.dia
  ADD COLUMN revisado_por uuid REFERENCES tiempo.persona (id),
  ADD COLUMN revisado_en  timestamptz;

COMMENT ON COLUMN tiempo.dia.revisado_por IS
  'Persona (vía frontera SCJ-FRO-01, tiempo.persona) que hizo clic en "Marcar como revisado". '
  'NULL mientras el día no pasó por bloqueado -> revisado. Atado al propio caller por el WITH '
  'CHECK de dia_update_revision -- nadie puede atribuirle la revisión a otra persona.';

COMMENT ON COLUMN tiempo.dia.revisado_en IS
  'Momento de la revisión humana (SCJ-DEC-06: "demostrar la intervención explícita de RH"). NULL '
  'mientras el día no pasó por bloqueado -> revisado. No puede ser futuro (dia_update_revision).';

CREATE INDEX IF NOT EXISTS ix_dia_revisado_por
  ON tiempo.dia (revisado_por);

-- ============================================================================
-- 2) Permiso dia_revision_edicion -- código de ACCIÓN, no de tabla (precedente: corrida_batch_
-- edicion, 45_*.sql). Deliberadamente NO se llama dia_edicion: ese nombre significaría CRUD
-- general sobre tiempo.dia, evitado a propósito (44_*.sql: "el sistema las calcula solo").
-- heredable=true, mismo criterio que dia_lectura. Mapeo a los 3 puestos acordados con el usuario:
-- Responsable de Recursos Humanos, Gerente General y Gerente o Encargado de TI (mismo patrón de
-- INSERT único que 45_*.sql:25-36).
-- ============================================================================

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('dia_revision_edicion', true)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'dia_revision_edicion', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto IN (
    'Responsable de Recursos Humanos',
    'Gerente General',
    'Gerente o Encargado de TI'
  )
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'dia_revision_edicion' AND pp.activo
  );

-- ============================================================================
-- 3) Policy de UPDATE -- molde exacto de 48_tiempo_rls_correccion_excepcion.sql:54-68 (asimetría
-- USING ve la fila vieja / WITH CHECK ve la nueva). tiempo.dia no tiene REVOKE UPDATE, DELETE (a
-- diferencia de marca/correccion) -- verificado: sólo faltaba la policy, no el GRANT. Esto hace
-- que bloqueado -> revisado sea la ÚNICA transición alcanzable por un humano: USING exige estado
-- actual = bloqueado, WITH CHECK exige estado nuevo = revisado + revisado_en no futuro +
-- revisado_por = la propia persona del caller (sin esto, alguien con el permiso podría atribuirle
-- la revisión a otra persona pegándole directo a PostgREST, saltándose FastAPI).
-- ============================================================================

CREATE POLICY dia_update_revision ON tiempo.dia
  FOR UPDATE TO authenticated
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND estado = 'bloqueado'
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion')
    AND estado = 'revisado' AND revisado_en IS NOT NULL AND revisado_en <= now()
    AND revisado_por = (SELECT u.persona_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid())
  );

-- ============================================================================
-- 4) RPC tiempo.fn_dia_revisar -- SECURITY INVOKER (default, no se escribe SECURITY DEFINER):
-- corre con los permisos del caller para que la policy de arriba siga siendo la autorización
-- real, mismo criterio que fn_ausencia_resolver (50_*.sql). Actor resuelto por auth.uid() dentro
-- de la función, mismo patrón que fn_ausencia_resolver:77-79 -- backend ya no necesita
-- resolver_persona_id() antes de llamar.
--
-- Dos ERRCODE propios (SCJ01-SCJ05 ya tomados, verificado por grep):
--   'SCJ06' el día no existe (o RLS no lo deja ver -- mismo criterio de siempre, sin distinguir
--     los dos casos, igual que fn_ausencia_resolver/SCJ02) -> backend mapea a 404.
--   'SCJ07' el día existe pero estado <> 'bloqueado' -> backend mapea a 409. El mismo código
--     cubre la carrera de dos personas revisando a la vez: el UPDATE de abajo lleva
--     WHERE estado = 'bloqueado' explícito además del chequeo previo, así que si alguien más
--     revisó el día entre el SELECT y el UPDATE, GET DIAGNOSTICS ROW_COUNT = 0 y se levanta el
--     mismo SCJ07.
-- ============================================================================

CREATE FUNCTION tiempo.fn_dia_revisar(p_dia_id bigint) RETURNS tiempo.dia AS $$
DECLARE
  v_estado_actual  varchar(20);
  v_revisor_id     uuid;
  v_filas          integer;
  v_resultado      tiempo.dia;
BEGIN
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
  SET estado = 'revisado', revisado_por = v_revisor_id, revisado_en = now()
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

COMMENT ON FUNCTION tiempo.fn_dia_revisar(bigint) IS
  'RPC de "marcar día como revisado" (SCJ-DEC-06): única transición bloqueado -> revisado '
  'alcanzable por un humano. SECURITY INVOKER -- dia_update_revision es la autorización real. '
  'Señales de conflicto: ERRCODE SCJ06 (día no existe/no visible), SCJ07 (ya no está bloqueado, '
  'incluida la carrera de dos revisiones simultáneas) -- ver cabecera de '
  '62_tiempo_dia_revision.sql para el mapeo exacto que debe hacer backend.';

GRANT EXECUTE ON FUNCTION tiempo.fn_dia_revisar(bigint) TO authenticated;
REVOKE EXECUTE ON FUNCTION tiempo.fn_dia_revisar(bigint) FROM PUBLIC;
