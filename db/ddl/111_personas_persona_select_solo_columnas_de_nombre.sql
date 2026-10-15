-- 111_personas_persona_select_solo_columnas_de_nombre.sql
-- BORRADOR (NO aplicable hasta que backend y frontend estén desplegados): PASO 2 (CIERRE) de la separación «nombre» / «identidad». Requiere 110_ aplicada.
--
-- RLS filtra filas, no columnas. Este archivo hace que `authenticated` ya NO pueda leer curp, rfc, nss ni fecha_nacimiento de personas.persona por ningún camino directo (PostgREST `select=*`,
-- columnas explícitas, filtros por esas columnas): la identidad solo sale por personas.fn_persona_identidad (110_), cuyo gate vive dentro. Las columnas de NOMBRE/LISTADO conservan SELECT.
--
-- IMPORTANTE (verificado en ensayo): `REVOKE SELECT (curp, …) ON personas.persona FROM authenticated` NO sirve: el grant de TABLA sigue dando todas las columnas. El camino correcto es quitar
-- el SELECT de tabla y conceder SELECT por columna, como aquí. INSERT/UPDATE/DELETE de tabla NO se tocan. service_role y el dueño conservan su grant de tabla (no se tocan). anon no tiene nada.
--
-- ANTES DE APLICAR (condición, no técnica sino de despliegue): backend ya no debe hacer `select("*")` sobre personas.persona (listado, ficha, PATCH) ni embeber personas.expediente; la ficha debe
-- leer identidad con fn_persona_identidad y degradar a campos nulos ante 42501; frontend debe tolerar esos campos nulos. Cualquier otro `select("*")` o filtro por curp/rfc/nss/fecha_nacimiento
-- con el cliente del caller pasará a dar 42501 («permission denied for table persona»).
--
-- COLUMNAS FUTURAS de personas.persona nacen SIN SELECT para authenticated (seguro por defecto): quien agregue una columna de listado debe concederla a propósito.
-- Inventario de RLS: sin policies nuevas. Privilegios de columna: ver abajo.
-- REVERSA (instantánea, sin riesgo para el backend nuevo, que funciona con ambos estados):  GRANT SELECT ON personas.persona TO authenticated;
--   (los grants por columna quedan redundantes; para dejarlo idéntico: REVOKE SELECT (id, actualizado_en, primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, fecha_ingreso,
--   fecha_baja, estado) ON personas.persona FROM authenticated;). Texto exacto en db/ensayos/ensayo_111.sql, bloque D.
-- VERIFICADOR: sección 76 (solo violaciones), que se agrega a verificar_ddl.sql junto con la aplicación de este archivo.

REVOKE SELECT ON personas.persona FROM authenticated;

GRANT SELECT (id, actualizado_en, primer_nombre, segundo_nombre, apellido_paterno, apellido_materno, fecha_ingreso, fecha_baja, estado)
  ON personas.persona TO authenticated;
