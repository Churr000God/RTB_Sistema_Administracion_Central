-- 35_permiso_correccion_migracion_inicial.sql
-- Permisos de tiempo.correccion (SCJ-PRO-10), confirmados con el usuario 2026-09-05. Se me habían
-- pasado en la ronda de 27 permisos de 33_*.sql — este archivo los agrega igual.
--
-- correccion_edicion/lectura: heredable, mismo trato que ausencia/excepcion/aprobacion_ausencia.
-- excepcion_reapertura: NO heredable, y a propósito distinto de excepcion_edicion — ese ya lo
-- tienen Gerente General y RH; este permiso es exclusivo para editar/reabrir una excepcion ya
-- resuelta, y sólo lo tiene Gerente o Encargado de TI.
--
-- Depende de: 21_personas_permiso.sql, 33_permiso_tiempo_migracion_inicial.sql

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('correccion_edicion', true),
  ('correccion_lectura', true),
  ('excepcion_reapertura', false)
ON CONFLICT (codigo) DO NOTHING;

-- Catch-up del puesto de bootstrap, mismo motivo que en 33_*.sql: 26_* corre antes que este
-- archivo, así que en un despliegue nuevo estos 3 códigos no existían cuando 26_ hizo su
-- CROSS JOIN. Se repite acotado a estos 3.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, perm.codigo, 'otorgado'
FROM personas.puesto p
CROSS JOIN personas.permiso perm
WHERE p.nombre_puesto = 'Gerente o Encargado de TI'
  AND perm.codigo IN ('correccion_edicion', 'correccion_lectura', 'excepcion_reapertura')
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = perm.codigo AND pp.activo
  );
