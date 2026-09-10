-- 69_personas_edicion.sql
-- Habilita edición real de datos de persona/expediente (módulo 1 era append-only hasta ahora:
-- alta_personas_usuarios crea, cambio_estado_persona sólo mueve estado vía bitácora). Nuevo
-- permiso persona_edicion + RPC transaccional para el UPDATE de los datos de identidad/contrato.
--
-- persona_update_requiere_permiso (31_personas_rls_permiso_especifico.sql:326) exigía
-- cambio_estado_persona -- nació para dejar pasar a trg_bitacora_sincroniza_persona (05_personas_
-- estructura.sql), que corre con los privilegios de quien insertó en bitacora_movimiento_persona
-- (requiere_permiso("cambio_estado_persona") en backend), no como autorización real de "editar
-- datos". Se agrega persona_edicion con OR -- el trigger de bitácora sigue pasando la policy sin
-- tener ese permiso nuevo.
--
-- expediente_update_requiere_permiso (31_*.sql:355) exigía alta_personas_usuarios "por
-- consistencia" con el INSERT (sin ningún UPDATE real detrás) -- se reemplaza limpio por
-- persona_edicion, sin OR: no hay trigger de por medio en expediente.
--
-- fn_persona_actualizar_datos: SECURITY INVOKER (patrón de 57_tiempo_fn_corte_quincenal_aplicar_
-- persona.sql) -- lo llama el caller humano vía get_caller_client, RLS de arriba es la
-- autorización real. Un solo UPDATE sobre personas.persona (nunca toca estado/fecha_baja --
-- trg_persona_sincroniza_baja sigue siendo la única vía, 04_personas.sql:52-67) + un INSERT ...
-- ON CONFLICT sobre personas.expediente (puede no existir para la persona, 05_personas_
-- estructura.sql:7-19). COALESCE(parametro, columna_actual) en ambos para no pisar con NULL lo
-- que el backend no mandó -- blindaje en SQL aunque backend ya sólo debería mandar lo que cambió.
-- El bloque de expediente sólo corre si se mandó al menos uno de sus 2 campos, para no forzar un
-- INSERT con tipo_contrato/documento_ref NULL (NOT NULL) cuando la persona todavía no tiene
-- expediente y sólo se están editando datos de persona.
--
-- Depende de: 04_personas.sql, 05_personas_estructura.sql, 21_personas_permiso.sql,
--   25_permiso_migracion_inicial.sql, 27_puesto_permiso_mapeo_inicial.sql,
--   31_personas_rls_permiso_especifico.sql

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('persona_edicion', true)
ON CONFLICT (codigo) DO NOTHING;

-- Catch-up al puesto de bootstrap ("Gerente o Encargado de TI"), mismo patrón que
-- 33_permiso_tiempo_migracion_inicial.sql:39-55 / 35_permiso_correccion_migracion_inicial.sql:
-- 18-30 -- 26_puesto_permiso_bootstrap_admin_generico.sql ya corrió antes que este archivo en el
-- orden de despliegue y no puede haber otorgado un código que todavía no existía.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'persona_edicion', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto = 'Gerente o Encargado de TI'
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'persona_edicion' AND pp.activo
  );

-- Otorgar persona_edicion a todo puesto que hoy tenga alta_personas_usuarios activo -- mismo
-- criterio de negocio que 27_puesto_permiso_mapeo_inicial.sql (RH; Dirección lo hereda por
-- reporta_a_id, ambos heredables). Dinámico en vez de hardcodear "Responsable de Recursos
-- Humanos" para cubrir cualquier otro puesto al que se le haya otorgado ese permiso después.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT pp.puesto_id, 'persona_edicion', 'otorgado'
FROM personas.puesto_permiso pp
WHERE pp.codigo = 'alta_personas_usuarios'
  AND pp.activo
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp2
    WHERE pp2.puesto_id = pp.puesto_id AND pp2.codigo = 'persona_edicion' AND pp2.activo
  );

-- ============================================================================
-- Policies: persona_update_requiere_permiso gana el OR (cambio_estado_persona sigue siendo
-- necesario para que trg_bitacora_sincroniza_persona pase); expediente_update_requiere_permiso
-- se reemplaza limpio por persona_edicion.
-- ============================================================================

DROP POLICY IF EXISTS persona_update_requiere_permiso ON personas.persona;

CREATE POLICY persona_update_requiere_permiso ON personas.persona
  FOR UPDATE
  USING (
    personas.fn_caller_activo()
    AND (
      personas.fn_caller_tiene_permiso('cambio_estado_persona')
      OR personas.fn_caller_tiene_permiso('persona_edicion')
    )
  )
  WITH CHECK (
    personas.fn_caller_activo()
    AND (
      personas.fn_caller_tiene_permiso('cambio_estado_persona')
      OR personas.fn_caller_tiene_permiso('persona_edicion')
    )
  );

DROP POLICY IF EXISTS expediente_update_requiere_permiso ON personas.expediente;

CREATE POLICY expediente_update_requiere_permiso ON personas.expediente
  FOR UPDATE
  USING (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion')
  )
  WITH CHECK (
    personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion')
  );

-- ============================================================================
-- RPC: fn_persona_actualizar_datos
-- ============================================================================

CREATE FUNCTION personas.fn_persona_actualizar_datos(
  p_persona_id        uuid,
  p_curp              varchar(18)  DEFAULT NULL,
  p_rfc               varchar(13)  DEFAULT NULL,
  p_nss               varchar(11)  DEFAULT NULL,
  p_primer_nombre     varchar(100) DEFAULT NULL,
  p_segundo_nombre    varchar(100) DEFAULT NULL,
  p_apellido_paterno  varchar(100) DEFAULT NULL,
  p_apellido_materno  varchar(100) DEFAULT NULL,
  p_fecha_nacimiento  date DEFAULT NULL,
  p_fecha_ingreso     date DEFAULT NULL,
  p_tipo_contrato     varchar(30)  DEFAULT NULL,
  p_documento_ref     varchar(50)  DEFAULT NULL
) RETURNS void AS $$
BEGIN
  UPDATE personas.persona AS per
  SET curp             = COALESCE(p_curp, per.curp),
      rfc              = COALESCE(p_rfc, per.rfc),
      nss              = COALESCE(p_nss, per.nss),
      primer_nombre    = COALESCE(p_primer_nombre, per.primer_nombre),
      segundo_nombre   = COALESCE(p_segundo_nombre, per.segundo_nombre),
      apellido_paterno = COALESCE(p_apellido_paterno, per.apellido_paterno),
      apellido_materno = COALESCE(p_apellido_materno, per.apellido_materno),
      fecha_nacimiento = COALESCE(p_fecha_nacimiento, per.fecha_nacimiento),
      fecha_ingreso    = COALESCE(p_fecha_ingreso, per.fecha_ingreso),
      actualizado_en   = now()
  WHERE per.id = p_persona_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'personas.persona % no existe', p_persona_id USING ERRCODE = 'SCJ10';
  END IF;

  IF p_tipo_contrato IS NOT NULL OR p_documento_ref IS NOT NULL THEN
    INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
    VALUES (p_persona_id, p_tipo_contrato, p_documento_ref)
    ON CONFLICT (persona_id) DO UPDATE
      SET tipo_contrato = COALESCE(EXCLUDED.tipo_contrato, personas.expediente.tipo_contrato),
          documento_ref = COALESCE(EXCLUDED.documento_ref, personas.expediente.documento_ref);
  END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION personas.fn_persona_actualizar_datos(
  uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar
) IS
  'RPC transaccional de edición de datos de persona/expediente (persona_edicion). Nunca toca '
  'estado/fecha_baja -- eso sigue siendo trg_persona_sincroniza_baja vía la bitácora de '
  'movimientos. COALESCE contra el valor actual para todo parámetro NULL. El bloque de expediente '
  'sólo corre si se mandó tipo_contrato o documento_ref -- ERRCODE SCJ10 si p_persona_id no '
  'existe.';

GRANT EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(
  uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar
) TO authenticated;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(
  uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar
) FROM PUBLIC;
