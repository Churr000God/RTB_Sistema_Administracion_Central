-- 107_personas_fn_persona_crear.sql
-- RPC transaccional del alta de persona + expediente (SCJ-PRO-01 paso A1). Hallazgo de testing (D7): POST /api/personas hacía dos inserts sueltos (personas.persona y luego personas.expediente); si el
-- segundo fallaba (documento_ref mal formado, tipo_contrato inválido, folio duplicado) la persona quedaba SIN expediente con CURP/RFC/NSS consumidos y reintentar daba duplicado. Es el patrón que el proyecto ya
-- documentó: un endpoint que escribe en 2 tablas relacionadas necesita un RPC transaccional (fn_jornada_asignar_renovar, fn_ausencia_resolver, fn_persona_actualizar_datos…).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 107_*.sql`. Solo CREATE FUNCTION + REVOKE/GRANT + COMMENT: no toca tablas, policies, triggers ni datos.
--
-- FIRMA (la que usará backend por PostgREST, argumentos por NOMBRE):
--   personas.fn_persona_crear(
--     p_primer_nombre varchar(100), p_apellido_paterno varchar(100), p_curp varchar(18), p_rfc varchar(13), p_nss varchar(11),
--     p_fecha_nacimiento date, p_fecha_ingreso date, p_tipo_contrato varchar(30), p_documento_ref varchar(50),
--     p_segundo_nombre varchar(100) DEFAULT NULL, p_apellido_materno varchar(100) DEFAULT NULL
--   ) RETURNS personas.persona
-- Devuelve la fila COMPLETA de personas.persona (incluye `id`): es lo mismo que devolvía el router con `insert().execute().data[0]` (PersonaOut), así que el backend no necesita una segunda consulta;
-- PostgREST la entrega como un objeto JSON (`{"id": "...", "curp": "...", …}`).
--
-- SEGURIDAD: SECURITY INVOKER (patrón de fn_persona_actualizar_datos, 69_): corre con los privilegios Y LA RLS del caller. La autorización real es la de las policies de INSERT de 31_
-- (persona_insert_requiere_permiso y expediente_insert_requiere_permiso: persona activa + alta_personas_usuarios); quien no la tiene recibe 42501 de la propia RLS, y quien llama por PostgREST directo
-- tampoco puede saltársela (la función no es DEFINER, no eleva privilegios). SET search_path = personas, pg_temp fijo. EXECUTE solo para authenticated (el router usa el cliente del caller:
-- get_caller_client); ni PUBLIC, ni anon, ni service_role. Se agrega a la lista cerrada de la sección 70(d) del verificador en el MISMO commit (regla de 105_/106_).
--
-- VALIDACIONES: las MISMAS que hoy aplica el router + la base: (a) backend/app/schemas/personas.py normaliza curp y rfc con strip().upper(); aquí se repite (btrim + upper) para que quien llame por
-- PostgREST directo no almacene minúsculas; (b) todo lo demás lo hacen las restricciones de la base, sin duplicarlas: CHECK de formato de documento_ref (ck_expediente_documento_ref_formato, 71_:
-- '^RTB-RH-EIT-[0-9]{4}-[0-9]+$'), CHECK de tipo_contrato, UNIQUE de curp/rfc/nss y de documento_ref, NOT NULL.
--
-- CONTRATO DE ERRORES (acordado con backend; mismos códigos que hoy, ahora con UNA transacción):
--   23505  unique_violation: CURP, RFC, NSS o documento_ref ya en uso (backend: manejar_violacion_unicidad -> 409 «CURP, RFC, NSS o número de documento ya está en uso por otra persona.»)
--   23514  check_violation: documento_ref con formato inválido (el mensaje contiene `ck_expediente_documento_ref_formato`; backend lo mapea a 422 con MENSAJE_DOCUMENTO_REF_FORMATO), tipo_contrato fuera
--          del dominio u otra restricción CHECK de persona/expediente (backend: 422 genérico)
--   23502  not_null_violation: campo obligatorio NULL (PostgREST ya rechaza la llamada si falta el argumento: PGRST202)
--   42501  insufficient_privilege: RLS (persona inactiva o sin alta_personas_usuarios): backend ya filtra antes con requiere_permiso -> 403; aquí es el respaldo
-- Ningún mensaje lleva identificadores. En cualquier error, NO queda ni persona ni expediente (la función completa se revierte).
--
-- Inventario de RLS: sin cambios.
-- REVERSA: DROP FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar); (nada depende de ella; el router sigue funcionando con
-- dos inserts sueltos mientras no se despliegue el cambio de backend).

CREATE FUNCTION personas.fn_persona_crear(
  p_primer_nombre     varchar(100),
  p_apellido_paterno  varchar(100),
  p_curp              varchar(18),
  p_rfc               varchar(13),
  p_nss               varchar(11),
  p_fecha_nacimiento  date,
  p_fecha_ingreso     date,
  p_tipo_contrato     varchar(30),
  p_documento_ref     varchar(50),
  p_segundo_nombre    varchar(100) DEFAULT NULL,
  p_apellido_materno  varchar(100) DEFAULT NULL
) RETURNS personas.persona
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_persona personas.persona;
BEGIN
  INSERT INTO personas.persona (primer_nombre, segundo_nombre, apellido_paterno, apellido_materno,
                                curp, rfc, nss, fecha_nacimiento, fecha_ingreso)
  VALUES (p_primer_nombre, p_segundo_nombre, p_apellido_paterno, p_apellido_materno,
          upper(btrim(p_curp)), upper(btrim(p_rfc)), p_nss, p_fecha_nacimiento, p_fecha_ingreso)
  RETURNING * INTO v_persona;

  INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
  VALUES (v_persona.id, p_tipo_contrato, p_documento_ref);

  RETURN v_persona;
END;
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar)
  TO authenticated;

COMMENT ON FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar) IS
  'SCJ-PRO-01 A1: inserta personas.persona y personas.expediente en UNA transacción y devuelve la fila de persona (incluye id). SECURITY INVOKER (la RLS de INSERT, con alta_personas_usuarios, es la '
  'autorización) con search_path = personas, pg_temp. curp/rfc se normalizan con btrim+upper. Errores nativos: 23505 (CURP/RFC/NSS/documento_ref duplicado), 23514 (formato de documento_ref, tipo_contrato), '
  '42501 (RLS). Ante cualquier error no queda ni persona ni expediente. EXECUTE solo para authenticated; incluida en la lista cerrada de la sección 70(d) del verificador.';
