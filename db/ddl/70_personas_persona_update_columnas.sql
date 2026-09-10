-- 70_personas_persona_update_columnas.sql
-- Fix de hallazgo HIGH de "security" sobre 69_personas_edicion.sql: personas.persona tiene
-- GRANT ALL schema-wide a authenticated (08_personas_permisos.sql:11), y RLS no filtra por
-- columna -- sólo por fila. persona_update_requiere_permiso (69_*.sql) exige
-- cambio_estado_persona OR persona_edicion en USING y WITH CHECK, pero el OR no distingue QUÉ
-- columnas toca el UPDATE: cualquiera con sólo cambio_estado_persona (sin persona_edicion) puede
-- reescribir curp/rfc/nss/nombre/apellidos/fechas vía PostgREST directo
-- (PATCH /rest/v1/persona?id=eq.X), bypaseando FastAPI por completo -- mismo patrón del hallazgo
-- crítico ya documentado en CLAUDE.md sobre 31_*.sql. Hoy no es explotable en la práctica (los 2
-- puestos con cambio_estado_persona también tienen persona_edicion), pero es coincidencia de
-- datos, no garantía estructural.
--
-- Por qué esto NO se resuelve tocando el WITH CHECK de la policy: en Postgres, el WITH CHECK de
-- una policy de UPDATE sólo tiene acceso a la fila NUEVA (columnas sin calificar = NEW) -- no
-- existe una forma de referenciar la fila ANTERIOR (OLD) dentro de una expresión de policy, ni
-- inline ni vía función (una función llamada desde WITH CHECK sólo puede recibir columnas de
-- NEW como argumentos). Comparar "¿cambió alguna columna de identidad respecto a lo que había
-- antes?" requiere el único mecanismo de Postgres que sí expone OLD y NEW juntos: un trigger BEFORE
-- UPDATE -- mismo mecanismo ya usado en este proyecto para invariantes que RLS no puede expresar
-- (trg_puesto_administrador_generico_inmutable, 32_puesto_administrador_generico_proteccion.sql;
-- trg_persona_sincroniza_baja, 04_personas.sql). La policy persona_update_requiere_permiso
-- (69_*.sql) no se toca -- su OR sigue siendo necesario para que trg_bitacora_sincroniza_persona
-- (05_personas_estructura.sql, no SECURITY DEFINER, corre con privilegios de quien insertó en
-- bitacora_movimiento_persona) siga pasando cuando sólo cambia estado/fecha_baja.
--
-- Diseño del trigger: WHEN compara OLD vs NEW de las 9 columnas de identidad (mismas que edita
-- fn_persona_actualizar_datos, 69_*.sql) -- sólo dispara la función si al menos una cambió, igual
-- que trg_puesto_administrador_generico_inmutable. Deja libres estado/fecha_baja/actualizado_en/
-- id (no son identidad, y estado/fecha_baja son [CALCULADO] por la bitácora, no por este flujo).
-- No SECURITY DEFINER: corre con los privilegios del caller, igual que fn_caller_tiene_permiso()
-- (31_*.sql) a la que llama -- ambas ya asumen que SELECT sobre las tablas que tocan está abierto
-- a cualquier caller activo, no hace falta privilegio elevado.
--
-- Nota para backend: fn_persona_actualizar_datos debe invocarse con get_caller_client (ya era el
-- diseño, comentario propio de 69_*.sql) -- si se invoca con service_role, auth.uid() es NULL,
-- fn_caller_tiene_permiso() siempre da false, y este trigger bloquearía cualquier edición real de
-- identidad sin importar el permiso ya validado en Python. No es un caso nuevo: RLS de este mismo
-- archivo (69_*.sql) ya dependía de esa misma condición para autorizar cualquier UPDATE.
--
-- Depende de: 04_personas.sql, 31_personas_rls_permiso_especifico.sql, 69_personas_edicion.sql

CREATE FUNCTION personas.fn_persona_protege_columnas_identidad()
RETURNS trigger AS $$
BEGIN
  IF NOT personas.fn_caller_tiene_permiso('persona_edicion') THEN
    RAISE EXCEPTION
      'UPDATE de columnas de identidad en personas.persona requiere el permiso persona_edicion '
      '(fila %)', OLD.id
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION personas.fn_persona_protege_columnas_identidad() IS
  'Cierra el hueco de que persona_update_requiere_permiso (69_personas_edicion.sql) no puede '
  'distinguir columnas: RLS WITH CHECK sólo ve la fila NUEVA, no la anterior. Este trigger sí '
  'compara OLD/NEW (vía su WHEN) y exige persona_edicion cuando cambia cualquiera de las 9 '
  'columnas de identidad -- cambio_estado_persona solo ya no alcanza para tocarlas, aunque la '
  'policy RLS lo siga dejando pasar.';

CREATE TRIGGER trg_persona_protege_columnas_identidad
  BEFORE UPDATE ON personas.persona
  FOR EACH ROW
  WHEN (
    OLD.curp IS DISTINCT FROM NEW.curp
    OR OLD.rfc IS DISTINCT FROM NEW.rfc
    OR OLD.nss IS DISTINCT FROM NEW.nss
    OR OLD.primer_nombre IS DISTINCT FROM NEW.primer_nombre
    OR OLD.segundo_nombre IS DISTINCT FROM NEW.segundo_nombre
    OR OLD.apellido_paterno IS DISTINCT FROM NEW.apellido_paterno
    OR OLD.apellido_materno IS DISTINCT FROM NEW.apellido_materno
    OR OLD.fecha_nacimiento IS DISTINCT FROM NEW.fecha_nacimiento
    OR OLD.fecha_ingreso IS DISTINCT FROM NEW.fecha_ingreso
  )
  EXECUTE FUNCTION personas.fn_persona_protege_columnas_identidad();

REVOKE EXECUTE ON FUNCTION personas.fn_persona_protege_columnas_identidad() FROM PUBLIC;
