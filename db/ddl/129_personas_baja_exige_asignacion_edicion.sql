-- 129_personas_baja_exige_asignacion_edicion.sql
-- Una baja definitiva por la bitácora exige también asignacion_edicion (residual R1 de 128_). Cambio sobre el esquema congelado (SCJ-ACT-03 V1.1 §V),
-- aprobado por Diego el 28-oct-2026 con la opción C de security (policy, sin SECURITY DEFINER).
--
-- PROBLEMA. personas.fn_bitacora_sincroniza_persona() (AFTER INSERT de personas.bitacora_movimiento_persona, INVOKER) pone a la persona en baja y cierra sus
-- asignaciones vigentes con un UPDATE que corre como el caller. La policy asignacion_update_requiere_permiso exige asignacion_edicion: quien tuviera
-- cambio_estado_persona SIN asignacion_edicion dejaba a la persona en baja con sus asignaciones ABIERTAS, sin ningún error (la RLS filtra el UPDATE a 0 filas).
-- Peor con el puesto administrador: su WITH CHECK (32_) impide cerrar esa asignación, pero solo cuando el UPDATE la ve; sin asignacion_edicion el UPDATE no la ve,
-- el admin quedaba en baja con su asignación abierta y perdía el acceso (fn_caller_activo). cambio_estado_persona es heredable y asignacion_edicion no: un jefe
-- de RH que no tuviera asignacion_edicion directo caería en el caso. Hoy no hay ningún puesto así (sección 92 de verificar_ddl.sql en 0 filas, 28-oct-2026).
--
-- QUÉ HACE. ALTER POLICY bitacora_insert_requiere_permiso (de 92_) ... WITH CHECK: la expresión vigente sin cambios (contrastada con pg_policies el 28-oct-2026 y
-- escrita con la MISMA forma de fuente que 92_, para que pg_get_expr dé el mismo texto en esa parte; ensayo_129 R1), más
--   CASE WHEN tipo_movimiento = 'baja_definitiva' THEN personas.fn_caller_tiene_permiso('asignacion_edicion') ELSE true END
-- Es lo mismo que «tipo_movimiento <> 'baja_definitiva' OR fn_caller_tiene_permiso('asignacion_edicion')» (tipo_movimiento es varchar NOT NULL con CHECK, no un
-- enum, y nunca es NULL), escrito con CASE porque la sección 55 de verificar_ddl.sql rechaza cualquier ' OR ' en esta policy (es su guarda contra ampliarla).
-- ALTER POLICY conserva el comando (INSERT), los roles (PUBLIC), PERMISSIVE y la ausencia de USING; solo cambia WITH CHECK. Suspensión y reactivación no cambian.
-- service_role no pasa por RLS: sin cambio (su baja cierra todo, incluida la asignación del administrador; igual que hoy).
--
-- ERROR QUE RECIBE EL CALLER: el de cualquier WITH CHECK fallido de RLS en un INSERT: SQLSTATE 42501, mensaje
--   new row violates row-level security policy for table "bitacora_movimiento_persona"   — SIN HINT (por PostgREST: HTTP 403, code 42501).
-- No hay ERRCODE SCJ ni HINT nuevos: registro_seguro.HINTS_CONOCIDOS no cambia. Backend debe mapear ese 42501 en el POST de movimientos (baja) a 403.
--
-- APLICAR DESPUÉS de 128_, con `psql --single-transaction -v ON_ERROR_STOP=1 -f 129_*.sql`. A cualquier hora. Sin precondición de datos.
-- REVERSA (en una transacción): psql --single-transaction -f db/ensayos/vigente_129_bitacora_insert_policy.sql
-- Verificador: sección 55 (sigue en 0 filas), 91 (la policy exige asignacion_edicion en la baja) y 92 (informativa: puestos con cambio_estado_persona sin
-- asignacion_edicion, con herencia).
-- Depende de: 31_, 32_, 92_, 128_
-- Justificación: SCJ-PRO-02, SCJ-PRO-04 §VI, SCJ-PRO-06 §V

ALTER POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('cambio_estado_persona')
    AND registrado_por = auth.uid()
    AND tipo_movimiento IN ('suspension', 'reactivacion', 'baja_definitiva')
    AND CASE WHEN tipo_movimiento = 'baja_definitiva' THEN personas.fn_caller_tiene_permiso('asignacion_edicion') ELSE true END
  );

COMMENT ON POLICY bitacora_insert_requiere_permiso ON personas.bitacora_movimiento_persona IS
  '92_/129_. INSERT de movimientos de persona por la API: persona activa con cambio_estado_persona, registrado_por = auth.uid(), tipo suspension/reactivacion/baja_definitiva; la baja_definitiva exige además asignacion_edicion (129_), porque el trigger INVOKER que cierra las asignaciones corre con los permisos del caller. Fallo: 42501 sin HINT.';
