-- 108_personas_select_padron_por_permiso.sql
-- Cierra la lectura abierta del padrón. Hallazgo (14/15-oct-2026): las policies de SELECT de personas.persona, personas.expediente, personas.usuario y personas.asignacion (31_ y anteriores) solo exigían
-- personas.fn_caller_activo(), es decir, CUALQUIER persona activa —incluso recién dada de alta y SIN puesto— leía por la API todo el padrón (nombres, CURP, RFC, NSS, ingresos, puestos, estados, tipo de contrato,
-- folios). El gate débil era «a propósito» por no existir un código de lectura del módulo; con personal real ya no es aceptable.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 108_*.sql`. Crea UNA función y reemplaza 4 policies de SELECT; no toca tablas, datos, triggers ni las policies de INSERT/UPDATE/DELETE.
--
-- REGLA (decidida por orchestrator, «sin backend»: la más amplia, para no tocar los resolvers del backend en esta entrega):
--   SELECT permitido si la persona está ACTIVA y (la fila es PROPIA o el caller tiene alguno de los permisos de la lista cerrada de personas.fn_caller_ve_padron()).
--   - persona: id = persona del caller;  expediente: persona_id = persona del caller;  usuario: auth_user_id = auth.uid();  asignacion: persona_id = persona del caller.
--   - Las filas PROPIAS de usuario y asignacion siguen visibles para todo activo: app/permisos.py las lee en CADA ruta con requiere_permiso y personas.fn_caller_tiene_permiso (INVOKER) las lee con la RLS del caller.
--   - tiempo.persona NO cambia (solo `id`, sin PII; los validadores de jornada y marcas la leen con el caller).
--
-- personas.fn_caller_ve_padron() — SECURITY DEFINER, STABLE, search_path = personas, pg_temp, dueño postgres, EXECUTE solo authenticated y service_role (lista cerrada 70(d)). Devuelve true si el caller está
-- activo y tiene (con la herencia jerárquica de fn_caller_tiene_permiso) ALGUNO de estos 27 permisos:
--   módulos: ver_modulo_1, ver_modulo_2, ver_modulo_3
--   personas: alta_personas_usuarios, persona_edicion, cambio_estado_persona          (INSERT … RETURNING y fn_bitacora_sincroniza_persona necesitan VER la fila)
--   estructura: asignacion_lectura, asignacion_edicion, puesto_lectura, puesto_edicion (puestos.py:178 y asignaciones.py leen asignaciones ajenas)
--   permisos: permiso_lectura, permiso_edicion, puesto_permiso_lectura, puesto_permiso_edicion (routers/permisos.py resuelve el nombre del autor en personas.usuario con el caller; sin ver_modulo_2 quedaría en NULL sin error)
--   (areas.py y departamentos.py no leen persona/expediente/usuario/asignacion; excepcion_dia_cerrado_descarte solo llama un RPC DEFINER: ninguno necesita estar en la lista)
--   Tiempo: ausencia_lectura, ausencia_edicion, excepcion_lectura, excepcion_edicion, marca_lectura, captura_manual_edicion, jornada_asignada_lectura, jornada_asignada_edicion,
--           dia_revision_edicion, clasificacion_de_tiempo_lectura                    (hoy leen nombres de persona con el cliente del caller)
--   Terminales: terminal_usuario_lectura, terminal_usuario_edicion, terminal_config_edicion
--   Para añadir una pantalla nueva que lea personas con el cliente del caller hay que añadir su permiso AQUÍ (CREATE OR REPLACE repitiendo SECURITY DEFINER, search_path y el GRANT/REVOKE).
-- SIN RECURSIÓN: las policies de usuario/asignacion no llaman a fn_caller_tiene_permiso (INVOKER, lee esas tablas con la RLS del caller: recursión infinita), sino a esta función DEFINER; dentro de ella,
-- fn_caller_tiene_permiso corre como el dueño (RLS no aplica al dueño) y lee las tablas completas. Cada policy la evalúa UNA VEZ por consulta con `(SELECT …)` (initplan), no por fila.
--
-- RESIDUAL ACEPTADO (decisión explícita): NO hay RLS por columna. Quien pasa la regla ve la FILA COMPLETA de personas.persona, incluidos CURP, RFC y NSS. Por eso un puesto con solo permisos de Tiempo o Terminales
-- (p. ej. marca_lectura o terminal_usuario_lectura), sin ver_modulo_1, sigue pudiendo leer CURP/RFC/NSS de todo el padrón por PostgREST directo. Se acepta porque los resolvers de nombres del backend
-- (ausencias, alertas de retardo, excepciones, marcas, días, terminales, configuración de terminales, anomalías y altas) leen persona con el cliente del caller y se romperían. SEGUNDA FASE ya decidida (no
-- en esta entrega): mover esa resolución de NOMBRES al cliente de servicio tras el gate que ya tienen (patrón de banco_de_horas, dias, tramos y tope_legal) y entonces reducir persona/expediente a
-- «fila propia O ver_modulo_1 O permisos del módulo 1». La brecha que ESTE archivo cierra es la grave: persona sin puesto, o con puesto sin permisos, leyendo el padrón.
-- SEGUNDA FASE (110_, NO en esta entrega): vista/RPC DEFINER con id y nombres para Tiempo/Terminales y REVOKE SELECT de curp/rfc/nss/fecha_nacimiento al conjunto estricto.
--
-- Inventario de privilegios/RLS: se reemplazan 4 policies (mismos nombres y mismo comando SELECT; roles: PUBLIC como antes). anon ya no tiene privilegio de tabla (100_/102_/103_), así que la policy no lo alcanza.
-- REVERSA (en una transacción): DROP POLICY y CREATE POLICY de las 4 con `USING (personas.fn_caller_activo())` (texto exacto en db/ensayos/ensayo_108.sql, paso de reversa) y luego
-- DROP FUNCTION personas.fn_caller_ve_padron();  (guardar fuera del repo antes de aplicar).

CREATE FUNCTION personas.fn_caller_ve_padron()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  SELECT personas.fn_caller_activo()
     AND EXISTS (
       -- Mismo criterio que fn_caller_tiene_permiso, pero para TODOS los códigos en UNA sola consulta (antes: 27 llamadas, cada una con su CTE recursiva; ~35 ms por consulta
       -- sobre el padrón): puesto vigente que lo posee, o (si el permiso es heredable) un descendiente de un puesto vigente que lo posee.
       WITH RECURSIVE rama AS (
         SELECT a.puesto_id AS id
         FROM personas.asignacion a
         WHERE a.persona_id = personas.fn_caller_persona_id()
           AND a.vigente_hasta IS NULL
         UNION
         SELECT pu.id
         FROM personas.puesto pu
         JOIN rama r ON pu.reporta_a_id = r.id
       ),
       vigentes AS (
         SELECT a.puesto_id AS id
         FROM personas.asignacion a
         WHERE a.persona_id = personas.fn_caller_persona_id()
           AND a.vigente_hasta IS NULL
       )
       SELECT 1
       FROM personas.puesto_permiso pp
       JOIN personas.permiso pe ON pe.codigo = pp.codigo
       WHERE pp.activo
         AND pp.codigo = ANY (ARRAY[
           'ver_modulo_1', 'ver_modulo_2', 'ver_modulo_3',
           'alta_personas_usuarios', 'persona_edicion', 'cambio_estado_persona',
           'asignacion_lectura', 'asignacion_edicion', 'puesto_lectura', 'puesto_edicion',
           'ausencia_lectura', 'ausencia_edicion', 'excepcion_lectura', 'excepcion_edicion',
           'marca_lectura', 'captura_manual_edicion', 'jornada_asignada_lectura', 'jornada_asignada_edicion',
           'dia_revision_edicion', 'clasificacion_de_tiempo_lectura',
           'permiso_lectura', 'permiso_edicion', 'puesto_permiso_lectura', 'puesto_permiso_edicion',
           'terminal_usuario_lectura', 'terminal_usuario_edicion', 'terminal_config_edicion'
         ])
         AND (
           pp.puesto_id IN (SELECT id FROM vigentes)
           OR (COALESCE(pe.heredable, false) AND pp.puesto_id IN (SELECT id FROM rama))
         )
     );
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_caller_ve_padron() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_ve_padron() TO authenticated, service_role;

COMMENT ON FUNCTION personas.fn_caller_ve_padron() IS
  'true si el caller está activo y tiene alguno de los permisos de la lista cerrada del cuerpo (módulos 1-3, personas, estructura, Tiempo que lee nombres, Terminales): puede leer el padrón '
  '(personas.persona/expediente/usuario/asignacion ajenos). SECURITY DEFINER con search_path = personas, pg_temp para que las policies de usuario y asignacion no recursen vía fn_caller_tiene_permiso '
  '(INVOKER). Las policies la evalúan una vez por consulta con (SELECT …). Al reescribirla repetir SECURITY DEFINER, SET search_path y el GRANT/REVOKE.';

-- ============================================================================
-- Policies de SELECT (mismos nombres; reemplazo limpio)
-- ============================================================================

DROP POLICY persona_select_caller_activo ON personas.persona;
CREATE POLICY persona_select_caller_activo ON personas.persona
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (id = (SELECT personas.fn_caller_persona_id()) OR (SELECT personas.fn_caller_ve_padron()))
  );

DROP POLICY expediente_select_caller_activo ON personas.expediente;
CREATE POLICY expediente_select_caller_activo ON personas.expediente
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (persona_id = (SELECT personas.fn_caller_persona_id()) OR (SELECT personas.fn_caller_ve_padron()))
  );

DROP POLICY usuario_select_caller_activo ON personas.usuario;
CREATE POLICY usuario_select_caller_activo ON personas.usuario
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (auth_user_id = (SELECT auth.uid()) OR (SELECT personas.fn_caller_ve_padron()))
  );

DROP POLICY asignacion_select_caller_activo ON personas.asignacion;
CREATE POLICY asignacion_select_caller_activo ON personas.asignacion
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (persona_id = (SELECT personas.fn_caller_persona_id()) OR (SELECT personas.fn_caller_ve_padron()))
  );
