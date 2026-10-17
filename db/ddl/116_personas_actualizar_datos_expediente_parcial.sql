-- 116_personas_actualizar_datos_expediente_parcial.sql
-- Corrige personas.fn_persona_actualizar_datos (69_ -> 110_): editar SOLO documento_ref o SOLO tipo_contrato fallaba con 23502 (not_null_violation) y el API respondía 500.
--
-- CAUSA RAÍZ. 110_ conserva de 69_ el bloque de expediente `INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref) VALUES (p, p_tipo_contrato, p_documento_ref)
-- ON CONFLICT (persona_id) DO UPDATE SET col = COALESCE(EXCLUDED.col, expediente.col)`. Postgres valida las restricciones NOT NULL de la tupla PROPUESTA antes de resolver el conflicto, así que con un
-- NULL en tipo_contrato o documento_ref (ambos NOT NULL, 05_) el INSERT muere con 23502 y el COALESCE del DO UPDATE nunca se alcanza. El frontend manda solo los campos que cambiaron.
--
-- ARREGLO. El bloque de expediente se reescribe SIN ON CONFLICT:
--   a) si el expediente de la persona EXISTE: UPDATE que asigna solo los parámetros NO nulos (mismos fragmentos fijos que el UPDATE de persona; ningún nombre de columna viene del caller). Si ese UPDATE
--      no toca ninguna fila, la RLS de UPDATE de expediente (persona_edicion) la ocultó: se levanta 42501 con mensaje fijo, igual que antes (con ON CONFLICT DO UPDATE la RLS fallaba con 42501);
--   b) si NO existe: se necesitan los DOS valores para crearlo; si falta alguno => ERRCODE SCJ22, HINT 'expediente_incompleto', mensaje fijo (sin valores ni identificadores). Con los dos, INSERT
--      (la policy de INSERT de expediente, alta_personas_usuarios, sigue siendo la autorización: sin ese permiso => 42501, como hasta hoy).
-- Los demás errores son los de la tabla y salen tal cual: 23514 (ck_expediente_tipo_contrato / ck_expediente_documento_ref_formato) y 23505 (uq_expediente_documento_ref).
--
-- QUÉ NO CAMBIA: firma (12 parámetros, mismo orden y defaults), tipo de retorno void, SECURITY INVOKER, SET search_path = personas, pg_temp, ACL (REVOKE de PUBLIC/anon/authenticated/service_role y GRANT
-- solo a authenticated), el UPDATE de persona por fragmentos fijos de 110_ (identidad fuera de la API directa), SCJ10 si la persona no existe, el trigger trg_persona_protege_columnas_identidad y
-- las policies. La función sigue en la lista cerrada de la sección 70(d) del verificador (mismo nombre y firma): no hace falta tocarla. Llamador: backend, routers/personas.py (PATCH /api/personas/{id}),
-- con get_caller_client.
-- NUEVO ERRCODE: SCJ22 (el último era SCJ21, 115_). Backend debe mapearlo a 422 por el HINT 'expediente_incompleto' (falta tipo_contrato o documento_ref al crear el expediente de una persona que no tiene).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 116_*.sql`. Sin DDL de tablas, sin datos. Idempotente (CREATE OR REPLACE con todas las cláusulas repetidas).
-- REVERSA (en una transacción): CREATE OR REPLACE de la función con el cuerpo de 110_ sección 5 (repitiendo SECURITY INVOKER y SET search_path = personas, pg_temp), nunca solo `CREATE OR REPLACE` sin esas
-- cláusulas; el ACL se conserva porque CREATE OR REPLACE no lo toca. Texto exacto en db/ensayos/ensayo_116.sql, bloque reversa. Volver a 110_ reintroduce el 23502.

CREATE OR REPLACE FUNCTION personas.fn_persona_actualizar_datos(
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
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_sql  text := 'UPDATE personas.persona SET actualizado_en = now()';
  v_filas bigint;
BEGIN
  -- Solo se asignan los parámetros NO nulos (equivale a COALESCE(p_x, columna) sin LEER la columna). Los fragmentos son literales fijos; los valores van por USING.
  IF p_curp IS NOT NULL             THEN v_sql := v_sql || ', curp = $1';             END IF;
  IF p_rfc IS NOT NULL              THEN v_sql := v_sql || ', rfc = $2';              END IF;
  IF p_nss IS NOT NULL              THEN v_sql := v_sql || ', nss = $3';              END IF;
  IF p_primer_nombre IS NOT NULL    THEN v_sql := v_sql || ', primer_nombre = $4';    END IF;
  IF p_segundo_nombre IS NOT NULL   THEN v_sql := v_sql || ', segundo_nombre = $5';   END IF;
  IF p_apellido_paterno IS NOT NULL THEN v_sql := v_sql || ', apellido_paterno = $6'; END IF;
  IF p_apellido_materno IS NOT NULL THEN v_sql := v_sql || ', apellido_materno = $7'; END IF;
  IF p_fecha_nacimiento IS NOT NULL THEN v_sql := v_sql || ', fecha_nacimiento = $8'; END IF;
  IF p_fecha_ingreso IS NOT NULL    THEN v_sql := v_sql || ', fecha_ingreso = $9';    END IF;
  v_sql := v_sql || ' WHERE id = $10';

  EXECUTE v_sql
    USING p_curp, p_rfc, p_nss, p_primer_nombre, p_segundo_nombre, p_apellido_paterno, p_apellido_materno,
          p_fecha_nacimiento, p_fecha_ingreso, p_persona_id;
  GET DIAGNOSTICS v_filas = ROW_COUNT;

  IF v_filas = 0 THEN
    RAISE EXCEPTION 'personas.persona % no existe', p_persona_id USING ERRCODE = 'SCJ10';
  END IF;

  IF p_tipo_contrato IS NOT NULL OR p_documento_ref IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM personas.expediente e WHERE e.persona_id = p_persona_id) THEN
      -- Expediente existente: solo se actualiza lo que llegó (sin upsert: un NULL en una columna NOT NULL de la tupla propuesta rompía el INSERT antes de resolver el conflicto).
      UPDATE personas.expediente
         SET tipo_contrato = COALESCE(p_tipo_contrato, tipo_contrato),
             documento_ref = COALESCE(p_documento_ref, documento_ref)
       WHERE persona_id = p_persona_id;
      GET DIAGNOSTICS v_filas = ROW_COUNT;
      IF v_filas = 0 THEN
        -- La fila existe y el caller la ve, pero la RLS de UPDATE (persona_edicion) no le deja tocarla.
        RAISE EXCEPTION 'No autorizado para editar el expediente.' USING ERRCODE = '42501';
      END IF;
    ELSE
      -- Sin expediente: crearlo exige los dos valores (ambas columnas son NOT NULL). Error propio y claro en vez de 23502.
      IF p_tipo_contrato IS NULL OR p_documento_ref IS NULL THEN
        RAISE EXCEPTION 'Para crear el expediente se requieren tipo de contrato y folio.'
          USING ERRCODE = 'SCJ22', HINT = 'expediente_incompleto';
      END IF;
      INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
      VALUES (p_persona_id, p_tipo_contrato, p_documento_ref);
    END IF;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar)
  TO authenticated;
