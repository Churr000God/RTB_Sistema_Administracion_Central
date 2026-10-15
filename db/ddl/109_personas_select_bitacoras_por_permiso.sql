-- 109_personas_select_bitacoras_por_permiso.sql
-- Mismo hallazgo que 108_ sobre las dos BITÁCORAS del esquema personas: bitacora_select_caller_activo y bitacora_puesto_permiso_select_caller_activo solo exigían personas.fn_caller_activo(), así que
-- CUALQUIER persona activa leía por la API el historial completo de altas, suspensiones, reactivaciones y bajas (con `motivo` en texto libre y quién lo registró) y el historial de quién recibió o perdió
-- qué permiso. Es dato de RH/seguridad más sensible que el propio padrón.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 109_*.sql`. Crea 2 funciones DEFINER y reemplaza 3 policies de SELECT; no toca tablas, datos, triggers ni las policies de INSERT/UPDATE/DELETE.
-- Requiere 108_ aplicada? NO: no depende de fn_caller_ve_padron (usa fn_caller_persona_id/fn_caller_activo/fn_caller_tiene_permiso, ya existentes).
--
-- REGLA (más ESTRECHA que la de 108_: las bitácoras no las lee ninguna pantalla de Tiempo ni de Terminales, así que no hace falta la lista amplia de fn_caller_ve_padron()):
--   bitacora_movimiento_persona:
--     fn_caller_activo() AND ( ver_modulo_1 OR cambio_estado_persona OR persona_edicion OR alta_personas_usuarios )
--       - las lee routers/movimientos.py (GET /api/personas/{id}/movimientos: ficha y bitácora de personas, módulo 1);
--       - quien registra un movimiento (cambio_estado_persona) necesita VER la fila que inserta (INSERT … RETURNING de movimientos.py:75) y trg_bitacora_sincroniza_persona (INVOKER) trabaja con ella;
--       - alta_personas_usuarios porque el alta de usuario inserta el movimiento «alta» (trg_usuario_bitacora_alta).
--   bitacora_movimiento_puesto_permiso: ver REGLA más abajo (permiso de estructura O filas de la propia rama).
--       - las lee routers/permisos.py (GET /api/permisos/otorgados, con requiere_permiso(permiso_lectura, permiso_edicion, puesto_permiso_lectura, puesto_permiso_edicion)) y las pantallas de permisos y
--         de ficha de puesto; quien otorga o revoca (puesto_permiso_edicion) necesita ver su INSERT … RETURNING (permisos.py:169 y :233).
--   Cada permiso se evalúa UNA vez por consulta con `(SELECT personas.fn_caller_tiene_permiso(…))`. Sin recursión: fn_caller_tiene_permiso (INVOKER) NO lee estas dos tablas.
--
-- FILA PROPIA: NO se incluye (a diferencia del padrón). Motivos: (1) el `motivo` es texto libre interno de RH (p. ej. la razón de una suspensión) que se redacta para el expediente, no para la persona; mostrárselo
-- por defecto por la API sería una decisión de producto, no un efecto lateral de una policy; (2) no existe pantalla de autoservicio que lo requiera: la ficha propia (FichaPersonaPage) degrada a «sin
-- movimientos» sin error (GET devuelve lista vacía por RLS); (3) la persona sigue viendo su estado actual en persona. Si el negocio decide darle a cada persona su propio historial, es AÑADIR
-- `persona_id = (SELECT personas.fn_caller_persona_id())` a la primera policy: una línea.
--
-- puesto_permiso (quién tiene qué permiso AHORA) y la bitácora de permisos se tratan igual, con una excepción obligada: el backend resuelve CADA gate de permisos leyendo puesto_permiso con el cliente del
-- caller (app/permisos.py::tiene_permiso) y fn_caller_tiene_permiso (INVOKER) la lee con la RLS del caller. Por eso, además del permiso de estructura, cada persona activa conserva las filas de SU RAMA:
-- los puestos que ocupa hoy y sus descendientes (justo lo que ambas funciones recorren para la herencia jerárquica). Sin eso, una persona sin permisos de estructura perdería sus propios permisos.
--   REGLA puesto_permiso y bitacora_movimiento_puesto_permiso (SELECT):
--     fn_caller_activo() AND ( (SELECT personas.fn_caller_ve_estructura_permisos()) OR puesto_id IN (SELECT personas.fn_caller_puestos_en_rama()) )
--   fn_caller_ve_estructura_permisos(): SECURITY DEFINER (la policy NO puede llamar a fn_caller_tiene_permiso directo: leería puesto_permiso con esta misma RLS = recursión infinita); true con ver_modulo_2,
--   permiso_lectura/edicion o puesto_permiso_lectura/edicion. fn_caller_puestos_en_rama(): SECURITY DEFINER, setof uuid, puestos vigentes del caller y descendientes (CTE recursiva sobre puesto.reporta_a_id).
--   EXECUTE solo authenticated y service_role (lista cerrada 70(d): +2 funciones). Las policies de INSERT/UPDATE/DELETE de puesto_permiso no cambian.
--
-- FUERA DE ALCANCE (a propósito, decisión de security): area, departamento, puesto y permiso se QUEDAN legibles por toda persona activa (organigrama, sidebar y árbol de herencia que app/permisos.py recorre
-- con puesto). Sensibilidad baja. Sin PII.
--
-- SEGUNDA FASE (110_, NO en esta entrega): vista/RPC DEFINER con id y nombres para Tiempo/Terminales y REVOKE SELECT de curp/rfc/nss/fecha_nacimiento al conjunto estricto (ver cabecera de 108_).
--
-- Inventario de RLS: 3 policies de SELECT reemplazadas (bitacora_select_caller_activo, bitacora_puesto_permiso_select_caller_activo, puesto_permiso_select_caller_activo; mismos nombres y comando) y 2 funciones
-- nuevas. anon no tiene privilegio de tabla (102_/103_).
-- REVERSA (en una transacción): DROP POLICY y CREATE POLICY de las 3 con `USING (personas.fn_caller_activo())` y luego DROP FUNCTION de las 2 (texto exacto en db/ensayos/ensayo_109.sql, bloque D).

CREATE FUNCTION personas.fn_caller_ve_estructura_permisos()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  SELECT personas.fn_caller_activo()
     AND EXISTS (
       SELECT 1
       FROM unnest(ARRAY['ver_modulo_2', 'permiso_lectura', 'permiso_edicion', 'puesto_permiso_lectura', 'puesto_permiso_edicion']) AS c(codigo)
       WHERE personas.fn_caller_tiene_permiso(c.codigo)
     );
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_ve_estructura_permisos() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_ve_estructura_permisos() TO authenticated, service_role;
COMMENT ON FUNCTION personas.fn_caller_ve_estructura_permisos() IS 'Policies SELECT de puesto_permiso y su bitácora (109_): activo y con algún permiso de estructura. DEFINER para no recursionar con la RLS de puesto_permiso.';

CREATE FUNCTION personas.fn_caller_puestos_en_rama()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  WITH RECURSIVE rama AS (
    SELECT a.puesto_id AS id
    FROM personas.asignacion a
    WHERE a.persona_id = personas.fn_caller_persona_id()
      AND a.vigente_hasta IS NULL
    UNION
    SELECT pu.id
    FROM personas.puesto pu
    JOIN rama r ON pu.reporta_a_id = r.id
  )
  SELECT id FROM rama WHERE personas.fn_caller_activo();
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_puestos_en_rama() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_puestos_en_rama() TO authenticated, service_role;
COMMENT ON FUNCTION personas.fn_caller_puestos_en_rama() IS 'Puestos vigentes del caller y sus descendientes (109_): filas de puesto_permiso que cada persona conserva para resolver su herencia.';

DROP POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona;
CREATE POLICY bitacora_select_caller_activo ON personas.bitacora_movimiento_persona
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (
      (SELECT personas.fn_caller_tiene_permiso('ver_modulo_1'))
      OR (SELECT personas.fn_caller_tiene_permiso('cambio_estado_persona'))
      OR (SELECT personas.fn_caller_tiene_permiso('persona_edicion'))
      OR (SELECT personas.fn_caller_tiene_permiso('alta_personas_usuarios'))
    )
  );

DROP POLICY bitacora_puesto_permiso_select_caller_activo ON personas.bitacora_movimiento_puesto_permiso;
CREATE POLICY bitacora_puesto_permiso_select_caller_activo ON personas.bitacora_movimiento_puesto_permiso
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (
      (SELECT personas.fn_caller_ve_estructura_permisos())
      OR puesto_id IN (SELECT personas.fn_caller_puestos_en_rama())
    )
  );

DROP POLICY puesto_permiso_select_caller_activo ON personas.puesto_permiso;
CREATE POLICY puesto_permiso_select_caller_activo ON personas.puesto_permiso
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (
      (SELECT personas.fn_caller_ve_estructura_permisos())
      OR puesto_id IN (SELECT personas.fn_caller_puestos_en_rama())
    )
  );
