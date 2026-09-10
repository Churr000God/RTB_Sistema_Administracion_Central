-- 39_tiempo_rls_jornada_patron.sql
-- Primera RLS de tiempo para usuarios humanos (la única que existía, 37_tiempo_rls_terminal.sql,
-- es del rol de sistema terminal_checador). backend/app/routers/tiempo/jornada_asignada.py (SCJ-
-- PRO-09) usa get_caller_client (anon key + JWT), nunca service_role -- esta policy es la
-- autorización real, no un respaldo (mismo motivo que 31_personas_rls_permiso_especifico.sql:
-- RLS sin permiso específico es sólo "sesión viva", no autorización).
--
-- SELECT gateado con lectura OR edición (no sólo fn_caller_activo() como en 31_*.sql): decisión de
-- orchestrator, mismo criterio que ya usa requiere_permiso() en el backend -- "lectura exige
-- lectura-o-edición". Necesario además porque "Responsable de Recursos Humanos"/"Gerente General"
-- (34_puesto_permiso_tiempo_mapeo_inicial.sql, ya aplicado) sólo tienen el código _edicion, nunca
-- se les otorgó _lectura -- si SELECT exigiera sólo _lectura se quedarían sin poder leer su propia
-- jornada_asignada/patron_semanal (rompe el flujo de renovar jornada, que necesita leer la vigencia
-- activa antes de cerrarla).
--
-- patron_semanal no tiene persona_id propio -- cuelga de jornada_asignada_id. Se gatea con sus
-- propios códigos patron_semanal_edicion/lectura (no reutiliza los de jornada_asignada) porque el
-- catálogo los sembró por separado (33_permiso_tiempo_migracion_inicial.sql) y así lo confirmó el
-- usuario -- son dos permisos distintos aunque una operación normalmente toque las dos tablas en la
-- misma transacción (ver 40_tiempo_fn_asignar_renovar_jornada.sql).
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql,
--   31_personas_rls_permiso_especifico.sql (fuente de personas.fn_caller_tiene_permiso)

ALTER TABLE tiempo.jornada_asignada ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiempo.patron_semanal ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- tiempo.jornada_asignada
-- ============================================================================

CREATE POLICY jornada_asignada_select_requiere_permiso ON tiempo.jornada_asignada
  FOR SELECT USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('jornada_asignada_lectura')
      OR personas.fn_caller_tiene_permiso('jornada_asignada_edicion')
    )
  );

CREATE POLICY jornada_asignada_insert_requiere_permiso ON tiempo.jornada_asignada
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion')
  );

CREATE POLICY jornada_asignada_update_requiere_permiso ON tiempo.jornada_asignada
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion')
  );

CREATE POLICY jornada_asignada_delete_requiere_permiso ON tiempo.jornada_asignada
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion')
  );

-- ============================================================================
-- tiempo.patron_semanal
-- ============================================================================

CREATE POLICY patron_semanal_select_requiere_permiso ON tiempo.patron_semanal
  FOR SELECT USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('patron_semanal_lectura')
      OR personas.fn_caller_tiene_permiso('patron_semanal_edicion')
    )
  );

CREATE POLICY patron_semanal_insert_requiere_permiso ON tiempo.patron_semanal
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion')
  );

CREATE POLICY patron_semanal_update_requiere_permiso ON tiempo.patron_semanal
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion')
  );

CREATE POLICY patron_semanal_delete_requiere_permiso ON tiempo.patron_semanal
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion')
  );
