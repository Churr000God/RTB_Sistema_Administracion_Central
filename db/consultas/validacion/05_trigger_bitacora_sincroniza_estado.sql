-- Verifica que un movimiento de suspensión sincroniza persona.estado y que el alta no lo toca dos veces.
BEGIN;

INSERT INTO personas.persona
  (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
VALUES
  ('XEXX010101HNEXXXA4', 'XEXX010101AB1', '12345678901', 'Prueba', 'Validación', '1990-01-01', '2026-01-01')
RETURNING id \gset persona_

INSERT INTO personas.bitacora_movimiento_persona (persona_id, tipo_movimiento)
VALUES (:'persona_id', 'suspension');

SELECT estado FROM personas.persona WHERE id = :'persona_id';
-- Esperado: suspension

ROLLBACK;
