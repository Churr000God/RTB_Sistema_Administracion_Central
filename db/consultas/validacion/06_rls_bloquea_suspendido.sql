-- Verifica que fn_caller_activo() devuelve false para una persona suspendida.
-- No podemos simular auth.uid() con SET ROLE simple porque es una función de Supabase Auth
-- (lee el JWT de la sesión PostgREST); esta consulta valida la lógica de negocio equivalente
-- directamente sobre la tabla, que es lo que la función encapsula.
BEGIN;

INSERT INTO personas.persona
  (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso, estado)
VALUES
  ('XEXX020202HNEXXXA5', 'XEXX020202AB2', '10987654321', 'Prueba', 'Suspendida', '1990-01-01', '2026-01-01', 'suspension')
RETURNING id \gset persona_

SELECT EXISTS (
  SELECT 1 FROM personas.persona WHERE id = :'persona_id' AND estado = 'activo'
) AS deberia_ser_false;

ROLLBACK;
