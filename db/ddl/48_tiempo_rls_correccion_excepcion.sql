-- 48_tiempo_rls_correccion_excepcion.sql
-- RLS de tiempo.correccion y tiempo.excepcion para el flujo humano (SCJ-PRO-10, corrección de
-- marca) -- completa lo que quedó pendiente de Fase 2 (ver 46_tiempo_rls_marca_excepcion_humano.sql
-- y 47_tiempo_excepcion_revoca_anon.sql): ahora sí hay contexto completo de correccion/ausencia
-- para diseñar la RLS de excepcion sin romper los triggers que la tocan.
--
-- ============================================================================
-- tiempo.excepcion (RLS deshabilitada desde 42_*.sql -- se vuelve a habilitar acá con policies
-- reales de SELECT/UPDATE. anon ya sin ningún privilegio, 47_*.sql -- esto es sólo para
-- authenticated).
-- ============================================================================
--
-- SELECT: fn_caller_activo() + (excepcion_lectura OR excepcion_edicion) -- para armar la cola de
-- excepciones pendientes (Fase 3) y porque fn_correccion_valida (BEFORE INSERT ON tiempo.
-- correccion, NO es SECURITY DEFINER) hace "EXISTS (SELECT 1 FROM tiempo.excepcion WHERE
-- marca_id=...)" con los privilegios del caller humano -- sin este SELECT, cualquiera con sólo
-- correccion_edicion vería la EXISTS en falso aunque la excepcion sí exista, y el trigger
-- rechazaría con "no tiene excepcion asociada" incorrectamente. RH/Gerente General/TI ya tienen
-- excepcion_edicion además de correccion_edicion (34_/36_/33_/35_*.sql) -- no hay hueco real hoy.
--
-- UPDATE: dos ramas según el estado ANTERIOR de la fila (USING ve la fila vieja, WITH CHECK ve la
-- nueva -- por eso la asimetría):
--   - pendiente -> requiere excepcion_edicion: cubre a fn_correccion_recalcula_tramo (UPDATE ...
--     WHERE estado='pendiente', SCJ-PRO-10) y fn_ausencia_resuelve_excepcion (mismo WHERE,
--     SCJ-PRO-08) -- ninguna es SECURITY DEFINER, corren con los privilegios del humano que
--     insertó la corrección o resolvió la ausencia. Los 3 puestos con correccion_edicion/
--     ausencia_edicion/aprobacion_ausencia_edicion ya tienen excepcion_edicion también
--     (34_*.sql) -- no rompe nada de lo ya construido.
--   - resuelto -> requiere excepcion_reapertura: defensivo -- ningún trigger de hoy hace UPDATE
--     sobre una excepcion ya resuelto (ambos triggers filtran WHERE estado='pendiente', así que
--     tocar una fila resuelto es un no-op para ellos, nunca llega a evaluar esta rama), pero
--     modela correctamente la regla de SCJ-PRO-10 §V ("reabrir una excepción ya resuelto es
--     exclusivo de TI") para el día en que exista un endpoint que la reabra directamente en vez
--     de sólo insertar otra corrección. El gate REAL de esa regla, hoy, vive en la policy de
--     INSERT de tiempo.correccion (más abajo) -- ver esa policy para el detalle de por qué ahí y
--     no acá.
--
-- Sin INSERT: los 4 INSERT que existen (reloj_no_sincronizado/persona_inactiva/dia_cerrado/
-- fuera_de_horario, todos en fn_marca_valida_revision) corren SECURITY DEFINER -- no necesitan
-- ninguna policy de INSERT para humanos, ninguna debería existir.

ALTER TABLE tiempo.excepcion ENABLE ROW LEVEL SECURITY;

CREATE POLICY excepcion_select_requiere_permiso ON tiempo.excepcion
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('excepcion_lectura')
      OR personas.fn_caller_tiene_permiso('excepcion_edicion')
    )
  );

CREATE POLICY excepcion_update_requiere_permiso ON tiempo.excepcion
  FOR UPDATE
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      (estado = 'pendiente' AND personas.fn_caller_tiene_permiso('excepcion_edicion'))
      OR (estado = 'resuelto' AND personas.fn_caller_tiene_permiso('excepcion_reapertura'))
    )
  )
  WITH CHECK (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('excepcion_edicion')
      OR personas.fn_caller_tiene_permiso('excepcion_reapertura')
    )
  );

-- ============================================================================
-- tiempo.correccion (RLS habilitada sin policy desde 41_tiempo_rls_deny_default.sql)
-- ============================================================================
--
-- INSERT: correccion_edicion siempre, MÁS excepcion_reapertura si la excepcion de la marca ya
-- está 'resuelto' -- esto es lo que de verdad implementa SCJ-PRO-10 §II.3/§V ("si la excepción ya
-- está resuelto, hace falta además excepcion_reapertura -- exclusivo TI, ni RH ni Gerente General
-- pueden aunque tengan correccion_edicion"). fn_correccion_valida (trigger BEFORE INSERT) exige
-- "existe una excepcion" en CUALQUIER estado -- no distingue pendiente/resuelto, así que sin este
-- EXISTS acá, RH/Gerente General podrían insertar una segunda corrección sobre una marca cuya
-- excepcion ya se cerró, saltándose la exclusividad de TI que el proceso exige. No se duplica la
-- validación de "existe excepcion" del trigger (esa es sobre CUALQUIER estado, siempre corre) --
-- esto sólo agrega la condición extra cuando esa excepcion está resuelto.
--
-- SELECT: correccion_lectura OR correccion_edicion -- también lo necesita fn_correccion_valida
-- para leer la corrección más reciente de las marcas vecinas (mismos 3 puestos, ya cubiertos).
--
-- Sin UPDATE/DELETE: ledger append-only, ya tiene REVOKE UPDATE, DELETE desde 38_tiempo_
-- permisos.sql -- no hace falta ninguna policy, Postgres deniega el privilegio de plano antes de
-- llegar a evaluar RLS.

CREATE POLICY correccion_insert_requiere_permiso ON tiempo.correccion
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('correccion_edicion')
    AND (
      NOT EXISTS (
        SELECT 1 FROM tiempo.excepcion e
        WHERE e.marca_id = marca_id AND e.estado = 'resuelto'
      )
      OR personas.fn_caller_tiene_permiso('excepcion_reapertura')
    )
  );

CREATE POLICY correccion_select_requiere_permiso ON tiempo.correccion
  FOR SELECT
  TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('correccion_lectura')
      OR personas.fn_caller_tiene_permiso('correccion_edicion')
    )
  );
