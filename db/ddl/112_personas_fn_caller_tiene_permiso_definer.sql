-- 112_personas_fn_caller_tiene_permiso_definer.sql
-- personas.fn_caller_tiene_permiso(text) pasa de SECURITY INVOKER a SECURITY DEFINER. Motivo (medido): es la función que usan 64 policies y 11 funciones/triggers; al ser INVOKER lee personas.usuario,
-- personas.asignacion y personas.puesto_permiso CON LA RLS DEL CALLER, y desde 108_/109_ cada lectura vuelve a evaluar fn_caller_ve_padron()/fn_caller_ve_estructura_permisos()/fn_caller_puestos_en_rama():
-- cada llamada cuesta ~1.3 ms más y una consulta de Tiempo con nombres pasó de ~11 ms a ~57 ms (con DEFINER baja a ~3 ms, ensayo_112).
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 112_*.sql`. Es CREATE OR REPLACE (misma firma, mismo retorno): REPITE explícitos SECURITY DEFINER y SET search_path, y el GRANT/REVOKE (lección de
-- CLAUDE.md: CREATE OR REPLACE no hereda atributos de un ALTER anterior).
--
-- DOS cambios, y SOLO esos:
--  1. SECURITY DEFINER (search_path = personas, pg_temp ya lo tenía desde 106_).
--  2. Se antepone `personas.fn_caller_activo() AND` al resultado. NO es opcional: como INVOKER, la RLS de usuario/asignacion ya ocultaba toda fila a una persona SUSPENDIDA (esas policies exigen
--     fn_caller_activo()), así que la función devolvía false para ella sin decirlo. Como DEFINER (lee como dueño, sin RLS) ese efecto implícito desaparecería y una persona suspendida cuyo puesto tuviera el
--     permiso volvería a obtener true (p. ej. en fn_persona_protege_columnas_identidad, que la llama sin fn_caller_activo()). La guarda lo conserva idéntico. El cuerpo restante es el mismo, literal.
--
-- SEGURIDAD (condiciones de security):
--  - Solo usa auth.uid() (la identidad del propio caller): NO recibe ninguna identidad ajena (su único parámetro es el CÓDIGO de permiso), así que no se puede preguntar por los permisos de otra persona.
--  - Su única salida es un booleano sobre el propio caller; ningún dato de tablas sale. El propio caller ya podía derivar esos permisos (/api/sesion, lectura de sus filas).
--  - search_path fijo; EXECUTE solo authenticated y service_role (ni PUBLIC ni anon, como desde 105_). service_role no tiene auth.uid(): devuelve false.
--  - La resolución de herencia (puestos vigentes, descendientes, poseedores) ahora lee como dueño pero se acota por auth.uid(): el resultado equivale al de antes para una persona activa porque las policies
--    de 108_/109_ ya le dejaban ver exactamente sus puestos vigentes, su rama y los poseedores de su rama (comprobado en ensayo_112 para TODOS los códigos x todas las personas del fixture).
--  - Las funciones DEFINER que ya la llamaban (fn_caller_ve_padron, fn_caller_ve_identidad, ...) no cambian de comportamiento (ya corrían como dueño).
--
-- Inventario de RLS: sin policies nuevas ni cambiadas. Una función cambia de privilegio (INVOKER -> DEFINER). Verificador: sección 77 (solo violaciones); 70(d) ya la lista.
-- REVERSA (en una transacción; copia exacta en el scratchpad de la sesión, generada con pg_get_functiondef ANTES de aplicar): CREATE OR REPLACE con la definición anterior (INVOKER, search_path, sin guarda).
-- Probada dentro de ensayo_112 (D1: el resultado de todos los códigos vuelve a ser idéntico).

CREATE OR REPLACE FUNCTION personas.fn_caller_tiene_permiso(p_codigo text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
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
    personas.fn_caller_activo()
    AND EXISTS (SELECT 1 FROM vigentes)
    AND (
      EXISTS (SELECT 1 FROM vigentes v JOIN poseedores po ON po.puesto_id = v.puesto_id)
      OR (
        COALESCE((SELECT heredable FROM permiso_info), false)
        AND EXISTS (SELECT 1 FROM descendientes d JOIN poseedores po ON po.puesto_id = d.id)
      )
    );
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_caller_tiene_permiso(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION personas.fn_caller_tiene_permiso(text) TO authenticated, service_role;

COMMENT ON FUNCTION personas.fn_caller_tiene_permiso(text) IS
  'Permiso del PROPIO caller (auth.uid()), con herencia jerárquica y solo si la persona está activa (112_). SECURITY DEFINER: lee usuario/asignacion/puesto_permiso como dueño para no re-evaluar la RLS en cada llamada de las ~64 policies. Solo devuelve un booleano; no recibe identidad ajena.';
