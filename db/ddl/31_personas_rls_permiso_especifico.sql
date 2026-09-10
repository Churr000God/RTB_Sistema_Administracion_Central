-- 31_personas_rls_permiso_especifico.sql
-- Fix de hallazgo crítico de seguridad: las policies RLS de 06/10/12/14/17/21/22/23 (FOR ALL
-- USING/WITH CHECK personas.fn_caller_activo()) sólo validan "¿el caller tiene una persona
-- activa detrás?" -- no validan el permiso específico que el backend SÍ exige vía
-- requiere_permiso(...) en cada router. Cualquier cuenta activa, sin importar sus puestos ni
-- permisos, podía escribir directo contra PostgREST (sin pasar por backend/app) en area,
-- departamento, puesto, asignacion, permiso, puesto_permiso, bitacora_movimiento_puesto_permiso,
-- persona, expediente, usuario y bitacora_movimiento_persona -- RLS era sólo un candado de
-- "sesión viva", no de autorización real. Explotable vía PostgREST directo con la anon key +
-- cualquier JWT de una cuenta activa (confirmado: los 7+ routers usan get_caller_client, o sea
-- RLS es la vía real de escritura, no sólo una segunda línea de defensa -- ver mensaje a
-- "orchestrator" previo a este archivo).
--
-- Aditivo puro en el sentido de "no modifica el texto de los archivos DDL originales": lo que
-- hace es DROP + CREATE de policies ya existentes, ejecutado desde este archivo nuevo (mismo
-- patrón que 09_personas_bitacora_inmutable.sql, que ya reemplazó una policy FOR ALL de
-- 06_personas_rls.sql sin tocar ese archivo). No se tocan tablas, columnas, triggers, GRANT ni
-- funciones existentes -- sólo se agrega la función nueva de este archivo y se reemplazan
-- policies.
--
-- Por qué DROP + CREATE y no ALTER POLICY: Postgres no permite ALTER POLICY para cambiar de FOR
-- ALL a comandos separados (SELECT/INSERT/UPDATE/DELETE) ni para pasar de una condición a otra
-- por completo -- hay que recrearla. Importante: las policies RLS son PERMISSIVE por default y
-- se combinan con OR -- agregar una policy nueva sin borrar "solo_caller_activo" (FOR ALL) no
-- habría cerrado nada, porque esa policy vieja seguía autorizando todo con sólo
-- fn_caller_activo(). Por eso el DROP es obligatorio, no opcional.
--
-- Por qué la lectura (SELECT) no cambia: así lo pide el punto 2 del pedido de "orchestrator" --
-- es el mismo criterio "gate débil a propósito" que ya documenta CLAUDE.md para personas/
-- usuarios/movimientos (el catálogo de 16 permisos no tiene código de lectura para esos tres).
-- Para area/departamento/puesto/asignacion/permiso/puesto_permiso si existen códigos de lectura
-- (area_lectura, etc.) pero el enforcement de cuál código exacto (lectura vs edición) ya lo hace
-- el backend con requiere_permiso(...); esta migración no lo duplica en RLS porque no fue el
-- hallazgo reportado (el hallazgo era escritura sin ningún control de permiso) y el pedido pide
-- explícitamente dejar lectura como está.
--
-- Depende de: 06_personas_rls.sql, 10_personas_area.sql, 12_personas_departamento.sql,
--   14_personas_puesto.sql, 17_personas_asignacion.sql, 21_personas_permiso.sql,
--   22_personas_puesto_permiso.sql, 23_personas_bitacora_puesto_permiso.sql,
--   backend/app/permisos.py (fuente de la lógica que replica la función de abajo)

-- ============================================================================
-- Función: réplica SQL de backend/app/permisos.py::tiene_permiso()
-- ============================================================================
--
-- Mapeo explícito lógica Python -> SQL, para que quien revise pueda comparar línea a línea:
--   resolver_persona_id       -> CTE caller_persona
--   resolver_puestos_vigentes -> CTE vigentes
--   poseedores (en tiene_permiso) -> CTE poseedores
--   permiso.heredable         -> CTE permiso_info
--   mapa_hijos_por_puesto + descendientes_incluido_si_mismo, aplicado a CADA puesto vigente y
--     unido -> CTE RECURSIVE descendientes (arranca de todos los vigentes a la vez, incluidos
--     ellos mismos, y baja por personas.puesto.reporta_a_id -- equivalente matemático a "unión
--     de descendientes_incluido_si_mismo(hijos, v) para cada v en puestos_vigentes", porque
--     intersecar esa unión con poseedores es lo mismo que "algún v tiene un descendiente en
--     poseedores").
--   "not puestos_vigentes: return False"                    -> EXISTS (SELECT 1 FROM vigentes)
--   "poseedores.intersection(puestos_vigentes): return True" -> EXISTS join vigentes/poseedores
--   "not permiso or not permiso[0]['heredable']: return False" -> COALESCE(heredable, false)
--   recorrido de jerarquía sólo si heredable                 -> AND corto-circuitado con heredable
--
-- No SECURITY DEFINER (a diferencia de fn_caller_activo): esta función sólo lee
-- personas.usuario/asignacion/puesto_permiso/permiso/puesto, y las cinco ya permiten SELECT a
-- cualquier caller activo (policies *_select_caller_activo / la parte SELECT de las FOR ALL que
-- este archivo no toca) -- correr con privilegios de invoker alcanza y evita sumar una segunda
-- función con privilegio elevado (fn_caller_activo sigue siendo la única, por diseño, ver su
-- propio comentario en 06_personas_rls.sql). Sin REVOKE EXECUTE FROM PUBLIC, mismo criterio que
-- fn_caller_activo(): sólo devuelve un boolean sobre el propio caller (auth.uid()), no expone
-- datos de terceros -- no hay nada que proteger ocultando quién puede llamarla.
CREATE FUNCTION personas.fn_caller_tiene_permiso(p_codigo text)
RETURNS boolean AS $$
  WITH RECURSIVE
  caller_persona AS (
    SELECT persona_id
    FROM personas.usuario
    WHERE auth_user_id = auth.uid()
  ),
  vigentes AS (
    SELECT a.puesto_id
    FROM personas.asignacion a
    JOIN caller_persona cp ON cp.persona_id = a.persona_id
    WHERE a.vigente_hasta IS NULL
  ),
  poseedores AS (
    SELECT pp.puesto_id
    FROM personas.puesto_permiso pp
    WHERE pp.codigo = p_codigo
      AND pp.activo = true
  ),
  permiso_info AS (
    SELECT pe.heredable
    FROM personas.permiso pe
    WHERE pe.codigo = p_codigo
  ),
  descendientes AS (
    SELECT puesto_id AS id FROM vigentes
    UNION
    SELECT pu.id
    FROM personas.puesto pu
    JOIN descendientes d ON pu.reporta_a_id = d.id
  )
  SELECT
    EXISTS (SELECT 1 FROM vigentes)
    AND (
      EXISTS (SELECT 1 FROM vigentes v JOIN poseedores po ON po.puesto_id = v.puesto_id)
      OR (
        COALESCE((SELECT heredable FROM permiso_info), false)
        AND EXISTS (SELECT 1 FROM descendientes d JOIN poseedores po ON po.puesto_id = d.id)
      )
    );
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION personas.fn_caller_tiene_permiso(text) IS
  'Réplica en SQL, para uso en policies RLS, de backend/app/permisos.py::tiene_permiso() -- '
  'incluida la herencia jerárquica (el jefe hereda el permiso de cualquier subordinado, directo '
  'o transitivo, vía personas.puesto.reporta_a_id). Ver mapeo línea a línea en el comentario de '
  'cabecera de 31_personas_rls_permiso_especifico.sql. Si la lógica de tiene_permiso() cambia en '
  'Python, esta función se vuelve a divergir a propósito -- no hay generación automática.';

-- ============================================================================
-- personas.area (10_personas_area.sql) -- área_edición gatea alta/renombrado/estado
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.area;

CREATE POLICY area_select_caller_activo ON personas.area
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY area_insert_requiere_permiso ON personas.area
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion')
  );

CREATE POLICY area_update_requiere_permiso ON personas.area
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'))
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'));

CREATE POLICY area_delete_requiere_permiso ON personas.area
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion')
  );

-- ============================================================================
-- personas.departamento (12_personas_departamento.sql)
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.departamento;

CREATE POLICY departamento_select_caller_activo ON personas.departamento
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY departamento_insert_requiere_permiso ON personas.departamento
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion')
  );

CREATE POLICY departamento_update_requiere_permiso ON personas.departamento
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion')
  );

CREATE POLICY departamento_delete_requiere_permiso ON personas.departamento
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion')
  );

-- ============================================================================
-- personas.puesto (14_personas_puesto.sql)
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.puesto;

CREATE POLICY puesto_select_caller_activo ON personas.puesto
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY puesto_insert_requiere_permiso ON personas.puesto
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion')
  );

CREATE POLICY puesto_update_requiere_permiso ON personas.puesto
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'))
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'));

CREATE POLICY puesto_delete_requiere_permiso ON personas.puesto
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion')
  );

-- ============================================================================
-- personas.asignacion (17_personas_asignacion.sql)
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.asignacion;

CREATE POLICY asignacion_select_caller_activo ON personas.asignacion
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY asignacion_insert_requiere_permiso ON personas.asignacion
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion')
  );

CREATE POLICY asignacion_update_requiere_permiso ON personas.asignacion
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'))
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion')
  );

CREATE POLICY asignacion_delete_requiere_permiso ON personas.asignacion
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion')
  );

-- ============================================================================
-- personas.permiso (21_personas_permiso.sql) -- catálogo, sin endpoint de escritura hoy (se
-- siembra por migración, ver comentario de 21_), pero la policy vieja igual dejaba pasar
-- INSERT/UPDATE/DELETE directo por PostgREST a cualquier cuenta activa. permiso_edicion es el
-- código simétrico de permiso_lectura/permiso_edicion ya sembrado en 25_permiso_migracion_
-- inicial.sql, aunque ningún router lo use todavía para requiere_permiso(...) -- se aplica igual
-- por consistencia con el resto de pares <tabla>_edicion/<tabla>_lectura del módulo.
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.permiso;

CREATE POLICY permiso_select_caller_activo ON personas.permiso
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY permiso_insert_requiere_permiso ON personas.permiso
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion')
  );

CREATE POLICY permiso_update_requiere_permiso ON personas.permiso
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'))
  WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'));

CREATE POLICY permiso_delete_requiere_permiso ON personas.permiso
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion')
  );

-- ============================================================================
-- personas.puesto_permiso (22_personas_puesto_permiso.sql) -- el trigger
-- trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) hace el INSERT ... ON CONFLICT
-- DO UPDATE real, corriendo con los privilegios del caller que insertó en
-- bitacora_movimiento_puesto_permiso (la función del trigger no es SECURITY DEFINER) -- por eso
-- necesita policy de UPDATE además de INSERT (Postgres exige permiso de UPDATE para la rama
-- ON CONFLICT DO UPDATE). Ese caller ya tiene puesto_permiso_edicion -- es el mismo permiso que
-- exigió la policy de bitacora_movimiento_puesto_permiso más abajo para poder insertar ahí en
-- primer lugar -- así que esto no rompe el flujo de otorgar/revocar.
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.puesto_permiso;

CREATE POLICY puesto_permiso_select_caller_activo ON personas.puesto_permiso
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY puesto_permiso_insert_requiere_permiso ON personas.puesto_permiso
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  );

CREATE POLICY puesto_permiso_update_requiere_permiso ON personas.puesto_permiso
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  );

CREATE POLICY puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  );

-- ============================================================================
-- personas.bitacora_movimiento_puesto_permiso (23_personas_bitacora_puesto_permiso.sql) -- sólo
-- se toca la policy de INSERT (el único write real: otorgar_permiso/revocar_permiso en
-- backend/app/routers/permisos.py, ambos con requiere_permiso(CODIGO_PUESTO_PERMISO_EDICION)
-- = "puesto_permiso_edicion"). SELECT no cambia. UPDATE/DELETE siguen sin ninguna policy
-- permissive -- RLS ya las niega por default para anon/authenticated, y el trigger
-- trg_bitacora_puesto_permiso_inmutable las bloquea incluso para service_role -- no hay nada que
-- agregar ahí, esta migración no toca esa capa.
-- ============================================================================

DROP POLICY IF EXISTS bitacora_puesto_permiso_insert_caller_activo ON personas.bitacora_movimiento_puesto_permiso;

CREATE POLICY bitacora_puesto_permiso_insert_requiere_permiso ON personas.bitacora_movimiento_puesto_permiso
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
  );

-- ============================================================================
-- personas.persona (04_personas.sql / 06_personas_rls.sql) -- alta_persona (backend/app/
-- routers/personas.py) inserta con requiere_permiso("alta_personas_usuarios"). El UPDATE real
-- de persona.estado/fecha_baja lo hace trg_bitacora_sincroniza_persona (05_personas_estructura.
-- sql), disparado por el INSERT en bitacora_movimiento_persona de backend/app/routers/
-- movimientos.py -- ese INSERT exige requiere_permiso("cambio_estado_persona"), y el trigger no
-- es SECURITY DEFINER, así que corre con los privilegios de ESE mismo caller: por eso el UPDATE
-- de persona exige cambio_estado_persona, no alta_personas_usuarios. DELETE no tiene ningún flujo
-- legítimo (el modelo es inmutable/append-only, sin baja física) -- se gatea con
-- cambio_estado_persona por ser el permiso más cercano en intención (dar de baja), no porque
-- exista un endpoint que lo use.
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.persona;

CREATE POLICY persona_select_caller_activo ON personas.persona
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY persona_insert_requiere_permiso ON personas.persona
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

CREATE POLICY persona_update_requiere_permiso ON personas.persona
  FOR UPDATE
  USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona'))
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
  );

CREATE POLICY persona_delete_requiere_permiso ON personas.persona
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
  );

-- ============================================================================
-- personas.expediente (05_personas_estructura.sql) -- se inserta en la misma transacción de
-- alta_persona (backend/app/routers/personas.py), mismo requiere_permiso("alta_personas_
-- usuarios") que persona. Sin UPDATE/DELETE en el flujo actual -- se gatea igual por
-- consistencia con persona.
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.expediente;

CREATE POLICY expediente_select_caller_activo ON personas.expediente
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY expediente_insert_requiere_permiso ON personas.expediente
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

CREATE POLICY expediente_update_requiere_permiso ON personas.expediente
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

CREATE POLICY expediente_delete_requiere_permiso ON personas.expediente
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

-- ============================================================================
-- personas.usuario (05_personas_estructura.sql) -- OJO: el INSERT real de alta_usuario
-- (backend/app/routers/usuarios.py) corre con get_service_client, no get_caller_client -- ya
-- bypassea RLS (service_role) hoy. Esta policy no cambia ese flujo en nada; sólo cierra el hueco
-- de que alguien con anon key + JWT de cuenta activa pudiera insertar/tocar personas.usuario
-- DIRECTO contra PostgREST sin pasar por el backend (que es quien de verdad exige
-- alta_personas_usuarios antes de invitar). Sin UPDATE/DELETE en el flujo actual -- se gatea
-- igual, mismo código, por consistencia y para no dejarlas abiertas sin necesidad.
-- ============================================================================

DROP POLICY IF EXISTS solo_caller_activo ON personas.usuario;

CREATE POLICY usuario_select_caller_activo ON personas.usuario
  FOR SELECT USING (personas.fn_caller_activo());

CREATE POLICY usuario_insert_requiere_permiso ON personas.usuario
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

CREATE POLICY usuario_update_requiere_permiso ON personas.usuario
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

CREATE POLICY usuario_delete_requiere_permiso ON personas.usuario
  FOR DELETE USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')
  );

-- ============================================================================
-- personas.bitacora_movimiento_persona (05_personas_estructura.sql / 09_personas_bitacora_
-- inmutable.sql) -- sólo se toca INSERT. El otro INSERT que existe (tipo_movimiento = 'alta',
-- disparado por trg_usuario_bitacora_alta cuando se crea personas.usuario) corre bajo
-- service_role (ver bloque de arriba) -- service_role tiene bypassrls en Supabase, así que ese
-- INSERT ni pasa por esta policy. El único INSERT sujeto a esta policy hoy es el de
-- backend/app/routers/movimientos.py (requiere_permiso("cambio_estado_persona")). SELECT no
-- cambia. UPDATE/DELETE siguen sin policy permissive -- ya bloqueadas (RLS + trigger
-- trg_bitacora_inmutable), esta migración no toca esa capa.
-- ============================================================================

DROP POLICY IF EXISTS bitacora_insert_caller_activo ON personas.bitacora_movimiento_persona;

CREATE POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona
  FOR INSERT WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
  );
