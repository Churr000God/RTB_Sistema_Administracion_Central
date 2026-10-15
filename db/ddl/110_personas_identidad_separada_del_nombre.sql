-- 110_personas_identidad_separada_del_nombre.sql
-- PASO 1 (ADITIVO) de la separación «nombre» / «identidad» de personas.persona. RLS filtra FILAS, no columnas: hoy quien pasa fn_caller_ve_padron() (27 permisos, incluidos marca_lectura y
-- terminal_usuario_lectura) lee curp, rfc, nss y fecha_nacimiento de TODAS las personas por la API directa, y los roles de Tiempo/Terminales solo necesitan el NOMBRE. Este archivo NO quita ningún
-- privilegio de tabla: prepara los caminos que el cierre (111_) necesita y que funcionan IGUAL con los grants de hoy y con los de después.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 110_*.sql`. ORDEN: 110_ -> desplegar backend + frontend -> 111_ (REVOKE de tabla + GRANT de columnas de nombre).
--
-- CONTENIDO
--  1. personas.fn_caller_ve_identidad() — SECURITY DEFINER, STABLE, search_path = personas, pg_temp, EXECUTE solo authenticated y service_role. true si el caller está activo y tiene (con la
--     herencia jerárquica de fn_caller_tiene_permiso, resuelta en UNA consulta como fn_caller_ve_padron) ALGUNO de: ver_modulo_1, alta_personas_usuarios, persona_edicion, cambio_estado_persona.
--     Es el CONJUNTO ESTRICTO de security. DEFINER por la misma razón que fn_caller_ve_padron: la usa una policy de personas.expediente y fn_caller_tiene_permiso (INVOKER) lee personas.usuario/
--     asignacion con la RLS del caller (recursión).
--  2. personas.fn_persona_identidad(p_persona_id uuid) RETURNS TABLE(curp, rfc, nss, fecha_nacimiento, tipo_contrato, documento_ref, fecha_firma) — SECURITY DEFINER, search_path fijo, EXECUTE solo
--     authenticated y service_role. El gate está DENTRO: fn_caller_activo() Y (p_persona_id es la persona del caller O fn_caller_ve_identidad()); si no, 42501 (mensaje fijo, sin identificadores).
--     Persona inexistente => 0 filas. Persona sin expediente => una fila con tipo_contrato/documento_ref/fecha_firma NULL. NOTA: con service_role (sin auth.uid()) el gate responde 42501: el backend
--     la llama con el cliente del CALLER; quien necesite identidad con service_role lee la tabla (conserva el GRANT).
--  3. personas.expediente: la policy de SELECT pasa de «fila propia O fn_caller_ve_padron()» a «fila propia O fn_caller_ve_identidad()». Nadie de Tiempo/Terminales lee expediente.
--  4. personas.fn_persona_crear: ya NO usa RETURNING * (leería curp/rfc/nss/fecha_nacimiento, que el cierre 111_ deja sin SELECT para authenticated): RETURNING solo de columnas de nombre/listado
--     (id, estado, fecha_baja, actualizado_en) y arma el compuesto con los valores recibidos (curp/rfc ya normalizados con btrim+upper). Mismo tipo de retorno, mismo orden de errores
--     (23505, 23514, 23502, 42501), SECURITY INVOKER (la RLS de INSERT sigue siendo la autorización), search_path = personas, pg_temp.
--  5. personas.fn_persona_actualizar_datos: ya NO lee las columnas con COALESCE(p_x, per.x) (eso exige SELECT sobre la columna): construye UN UPDATE que asigna solo los parámetros NO nulos
--     (misma semántica que COALESCE). Los fragmentos son LITERALES FIJOS del código (columna = $n) — ningún nombre de columna ni valor viene del caller como identificador; los valores van por
--     USING. SECURITY INVOKER, mismas policies y mismo trigger trg_persona_protege_columnas_identidad, mismo ERRCODE SCJ10; se le fija search_path = personas, pg_temp (antes no lo tenía; es
--     INVOKER, no cambia nada para el caller). La parte de expediente (INSERT … ON CONFLICT … COALESCE) no cambia: expediente conserva el grant de tabla.
--
-- QUÉ NO CAMBIA: policies de persona (siguen «propia O fn_caller_ve_padron()»), el GRANT de tabla de personas.persona, los triggers, ningún dato.
-- Inventario de RLS: 1 policy de SELECT reemplazada (expediente_select_caller_activo; mismo nombre y comando). 2 funciones nuevas.
-- ANTES DE APLICAR 111_: backend debe dejar de usar `select("*")` sobre personas.persona y de embeber expediente; ver el inventario entregado a backend.
--
-- RESIDUAL: service_role y el dueño leen todo (no se toca). El valor duplicado de una violación de unicidad (23505) se devuelve a quien intenta el alta (ya ocurría; requiere alta_personas_usuarios).
-- REVERSA (en una transacción; copia en el scratchpad de la sesión): recrear la policy con `USING (personas.fn_caller_activo() AND (persona_id = (SELECT personas.fn_caller_persona_id()) OR
-- (SELECT personas.fn_caller_ve_padron())))`, CREATE OR REPLACE de fn_persona_crear y fn_persona_actualizar_datos con los cuerpos de 107_ y 69_ (repitiendo SET search_path de 107_) y DROP FUNCTION de
-- las 2 funciones nuevas. Texto exacto en db/ensayos/ensayo_110.sql, bloque D.

-- 1) conjunto estricto
CREATE FUNCTION personas.fn_caller_ve_identidad()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
  SELECT personas.fn_caller_activo()
     AND EXISTS (
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
         AND pp.codigo = ANY (ARRAY['ver_modulo_1', 'alta_personas_usuarios', 'persona_edicion', 'cambio_estado_persona'])
         AND (
           pp.puesto_id IN (SELECT id FROM vigentes)
           OR (COALESCE(pe.heredable, false) AND pp.puesto_id IN (SELECT id FROM rama))
         )
     );
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_caller_ve_identidad() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_ve_identidad() TO authenticated, service_role;
COMMENT ON FUNCTION personas.fn_caller_ve_identidad() IS
  'Conjunto estricto que puede leer la IDENTIDAD de una persona (110_): activo y con ver_modulo_1, alta_personas_usuarios, persona_edicion o cambio_estado_persona (con herencia). DEFINER, una sola consulta.';

-- 2) RPC de identidad
CREATE FUNCTION personas.fn_persona_identidad(p_persona_id uuid)
RETURNS TABLE (
  curp             varchar,
  rfc              varchar,
  nss              varchar,
  fecha_nacimiento date,
  tipo_contrato    varchar,
  documento_ref    varchar,
  fecha_firma      timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
BEGIN
  IF NOT personas.fn_caller_activo() THEN
    RAISE EXCEPTION 'No autorizado para leer datos de identidad.' USING ERRCODE = '42501';
  END IF;
  IF NOT (COALESCE(p_persona_id = personas.fn_caller_persona_id(), false) OR personas.fn_caller_ve_identidad()) THEN
    RAISE EXCEPTION 'No autorizado para leer datos de identidad.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT p.curp, p.rfc, p.nss, p.fecha_nacimiento, e.tipo_contrato, e.documento_ref, e.fecha_firma
  FROM personas.persona p
  LEFT JOIN personas.expediente e ON e.persona_id = p.id
  WHERE p.id = p_persona_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_identidad(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_persona_identidad(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION personas.fn_persona_identidad(uuid) IS
  'Identidad de una persona (curp, rfc, nss, fecha_nacimiento) y su expediente (110_). DEFINER; el gate (activo Y fila propia O conjunto estricto) está dentro; 42501 sin permiso, 0 filas si no existe.';

-- 3) expediente: SELECT solo propia o conjunto estricto
DROP POLICY expediente_select_caller_activo ON personas.expediente;
CREATE POLICY expediente_select_caller_activo ON personas.expediente
  FOR SELECT
  USING (
    personas.fn_caller_activo()
    AND (
      persona_id = (SELECT personas.fn_caller_persona_id())
      OR (SELECT personas.fn_caller_ve_identidad())
    )
  );

-- 4) fn_persona_crear sin RETURNING * (misma firma, mismo tipo de retorno, INVOKER)
CREATE OR REPLACE FUNCTION personas.fn_persona_crear(
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
  v_id             uuid;
  v_estado         varchar;
  v_fecha_baja     date;
  v_actualizado_en timestamptz;
BEGIN
  INSERT INTO personas.persona (primer_nombre, segundo_nombre, apellido_paterno, apellido_materno,
                                curp, rfc, nss, fecha_nacimiento, fecha_ingreso)
  VALUES (p_primer_nombre, p_segundo_nombre, p_apellido_paterno, p_apellido_materno,
          upper(btrim(p_curp)), upper(btrim(p_rfc)), p_nss, p_fecha_nacimiento, p_fecha_ingreso)
  RETURNING id, estado, fecha_baja, actualizado_en
  INTO v_id, v_estado, v_fecha_baja, v_actualizado_en;

  INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
  VALUES (v_id, p_tipo_contrato, p_documento_ref);

  v_persona.id               := v_id;
  v_persona.actualizado_en   := v_actualizado_en;
  v_persona.curp             := upper(btrim(p_curp));
  v_persona.rfc              := upper(btrim(p_rfc));
  v_persona.nss              := p_nss;
  v_persona.primer_nombre    := p_primer_nombre;
  v_persona.segundo_nombre   := p_segundo_nombre;
  v_persona.apellido_paterno := p_apellido_paterno;
  v_persona.apellido_materno := p_apellido_materno;
  v_persona.fecha_nacimiento := p_fecha_nacimiento;
  v_persona.fecha_ingreso    := p_fecha_ingreso;
  v_persona.fecha_baja       := v_fecha_baja;
  v_persona.estado           := v_estado;

  RETURN v_persona;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_persona_crear(varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar, varchar, varchar)
  TO authenticated;

-- 5) fn_persona_actualizar_datos sin leer las columnas (misma firma, INVOKER)
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
    INSERT INTO personas.expediente (persona_id, tipo_contrato, documento_ref)
    VALUES (p_persona_id, p_tipo_contrato, p_documento_ref)
    ON CONFLICT (persona_id) DO UPDATE
      SET tipo_contrato = COALESCE(EXCLUDED.tipo_contrato, personas.expediente.tipo_contrato),
          documento_ref = COALESCE(EXCLUDED.documento_ref, personas.expediente.documento_ref);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_persona_actualizar_datos(uuid, varchar, varchar, varchar, varchar, varchar, varchar, varchar, date, date, varchar, varchar)
  TO authenticated;
