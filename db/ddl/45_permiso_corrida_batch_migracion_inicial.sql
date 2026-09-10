-- 45_permiso_corrida_batch_migracion_inicial.sql
-- Gap real encontrado por backend: ninguno de los 27 códigos de 33_permiso_tiempo_migracion_
-- inicial.sql sirve para gatear "disparar un batch manualmente" -- tiempo_persona_edicion queda
-- descartado a propósito (exclusivo TI, no de los otros dos actores del botón manual documentados
-- en SCJ-PRO-12: RH/Dirección/TI). backend estaba usando jornada_asignada_edicion como parche
-- temporal. Este archivo agrega el código real, catálogo + mapeo en el mismo archivo (a diferencia
-- de 33_/34_*.sql, que lo separaron en dos porque el catch-up del bootstrap de TI corría antes que
-- el archivo de mapeo -- acá no hace falta ese paso intermedio, se mapean los 3 puestos en el mismo
-- INSERT).
--
-- corrida_batch_edicion: heredable, mismo criterio que el resto de los permisos de escritura del
-- módulo de Tiempo (ausencia_edicion, movimiento_de_saldo_edicion, etc.) -- sirve para el botón
-- manual de este batch (de_confianza, SCJ-PRO-14) y de los dos que faltan en Fase 4 (cierre_dia,
-- corte_quincenal): mismo botón, mismo actor, un solo código para los tres.
--
-- Mapeo a los 3 puestos que ya tienen el resto de permisos de tiempo (33_/34_*.sql, ya aplicados):
-- "Responsable de Recursos Humanos", "Gerente General" y "Gerente o Encargado de TI" (bootstrap).
-- Depende de: 21_personas_permiso.sql, 33_permiso_tiempo_migracion_inicial.sql,
--   34_puesto_permiso_tiempo_mapeo_inicial.sql

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('corrida_batch_edicion', true)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'corrida_batch_edicion', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto IN (
    'Responsable de Recursos Humanos',
    'Gerente General',
    'Gerente o Encargado de TI'
  )
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'corrida_batch_edicion' AND pp.activo
  );
