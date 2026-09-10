-- 46_tiempo_rls_marca_excepcion_humano.sql
-- RLS de tiempo.marca/tiempo.excepcion para el flujo humano (SCJ-PRO-07, captura manual) --
-- distinta de la RLS del checador físico (37_tiempo_rls_terminal.sql, rol terminal_checador):
-- estas policies son PERMISSIVE para el rol authenticated, coexisten sin pisarse con la del
-- terminal porque esa es TO terminal_checador exclusivamente.
--
-- tiempo.marca INSERT: fn_caller_activo() + captura_manual_edicion + origen='captura_manual'
-- forzado en el mismo WITH CHECK -- mismo criterio que terminal_inserta_su_origen: aunque alguien
-- manipule el payload, no puede insertarse como origen='terminal' por este camino (ese origen sólo
-- lo puede escribir terminal_checador, rol distinto). Sin UPDATE/DELETE para humanos -- tiempo.marca
-- es inmutable por diseño (02_tiempo.sql), cualquier corrección pasa por tiempo.correccion
-- (SCJ-DEC-03), nunca por un UPDATE directo de este router.
--
-- tiempo.marca SELECT: fn_caller_activo() + (marca_lectura OR captura_manual_edicion) -- mismo
-- patrón lectura-OR-edición que 39_tiempo_rls_jornada_patron.sql. Necesario en la práctica: el
-- backend de captura manual busca por evento_id (uq_marca_evento_id) ANTES de insertar, para
-- detectar duplicados de reintento (SCJ-PRO-07) -- sin este SELECT, quien tiene sólo
-- captura_manual_edicion no podría ni siquiera chequear si su propio evento_id ya se insertó.
-- marca_lectura sólo mira, captura_manual_edicion mira y además puede insertar.
--
-- tiempo.excepcion: NO se toca en este archivo -- ver mensaje a orchestrator. Habilitar RLS ahí
-- aunque sea "sólo para SELECT" reintroduce el mismo bug que 42_tiempo_rls_persona_lectura_y_
-- excepcion_sin_rls.sql ya corrigió una vez: fn_correccion_recalcula_tramo (SCJ-PRO-10) y
-- fn_ausencia_resuelve_excepcion (SCJ-PRO-08) hacen UPDATE real sobre tiempo.excepcion, ninguna es
-- SECURITY DEFINER -- sin una policy de UPDATE que las cubra, esos UPDATE se silenciarían en
-- cuanto Fase 3 conecte esos endpoints. Queda para cuando se diseñe junto con la RLS de
-- correccion/ausencia de Fase 3, no suelto acá.
-- Depende de: 02_tiempo.sql, 33_permiso_tiempo_migracion_inicial.sql, 37_tiempo_rls_terminal.sql

-- ============================================================================
-- tiempo.marca (RLS ya habilitada desde 37_tiempo_rls_terminal.sql)
-- ============================================================================

CREATE POLICY marca_insert_captura_manual ON tiempo.marca
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('captura_manual_edicion')
    AND origen = 'captura_manual'
  );

CREATE POLICY marca_select_requiere_permiso ON tiempo.marca
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('marca_lectura')
      OR personas.fn_caller_tiene_permiso('captura_manual_edicion')
    )
  );

