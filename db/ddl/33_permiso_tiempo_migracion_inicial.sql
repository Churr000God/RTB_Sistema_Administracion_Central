-- 33_permiso_tiempo_migracion_inicial.sql
-- Catálogo de permisos del subsistema de Tiempo — módulo "Registro-marcas-jornadas-ausencias-
-- asistencias" (mapeo confirmado con el usuario, 2026-09-05). 27 códigos nuevos, mismo patrón de
-- 25_permiso_migracion_inicial.sql: par edición/lectura por recurso salvo donde se indica lo
-- contrario. Catálogo pasa de 16 a 43.
--
-- Reglas de heredabilidad, tal como las dio el usuario:
--   - ver_modulo_3, movimiento_de_saldo, jornada_asignada, patron_semanal, ausencia, excepcion,
--     aprobacion_ausencia, marca, tramo, clasificacion_de_tiempo, dia: heredables.
--   - tope_legal, dia_festivo, parametro, captura_manual, tiempo_persona, banco_de_horas: NO
--     heredables.
--   - tiempo_persona: sólo existe la versión edición (tabla interna de cálculo, sin uso de
--     lectura por separado). marca/tramo/clasificacion_de_tiempo/dia: sólo existe la versión
--     lectura (el sistema las calcula solo, nadie las edita a mano). banco_de_horas: sólo lectura
--     (materializado por trigger, igual que las anteriores).
--
-- Depende de: 21_personas_permiso.sql

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('ver_modulo_3', true),
  ('tope_legal_edicion', false), ('tope_legal_lectura', false),
  ('dia_festivo_edicion', false), ('dia_festivo_lectura', false),
  ('parametro_edicion', false), ('parametro_lectura', false),
  ('captura_manual_edicion', false), ('captura_manual_lectura', false),
  ('movimiento_de_saldo_edicion', true), ('movimiento_de_saldo_lectura', true),
  ('jornada_asignada_edicion', true), ('jornada_asignada_lectura', true),
  ('patron_semanal_edicion', true), ('patron_semanal_lectura', true),
  ('ausencia_edicion', true), ('ausencia_lectura', true),
  ('excepcion_edicion', true), ('excepcion_lectura', true),
  ('aprobacion_ausencia_edicion', true), ('aprobacion_ausencia_lectura', true),
  ('tiempo_persona_edicion', false),
  ('marca_lectura', true),
  ('tramo_lectura', true),
  ('clasificacion_de_tiempo_lectura', true),
  ('dia_lectura', true),
  ('banco_de_horas_lectura', false)
ON CONFLICT (codigo) DO NOTHING;

-- Catch-up del puesto de bootstrap ("Gerente o Encargado de TI"): 26_puesto_permiso_bootstrap_
-- admin_generico.sql ya le da TODO personas.permiso vía CROSS JOIN, pero corre antes que este
-- archivo en el orden de despliegue — en un despliegue nuevo, estos 27 códigos todavía no existían
-- cuando 26_ corrió. Se repite aquí el mismo CROSS JOIN, acotado a los códigos de este archivo,
-- para que el puesto administrador genérico quede con el catálogo completo sin depender de que
-- alguien reejecute 26_ a mano. WHERE NOT EXISTS por fila, mismo patrón que el resto.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, perm.codigo, 'otorgado'
FROM personas.puesto p
CROSS JOIN personas.permiso perm
WHERE p.nombre_puesto = 'Gerente o Encargado de TI'
  AND perm.codigo IN (
    'ver_modulo_3',
    'tope_legal_edicion', 'tope_legal_lectura',
    'dia_festivo_edicion', 'dia_festivo_lectura',
    'parametro_edicion', 'parametro_lectura',
    'captura_manual_edicion', 'captura_manual_lectura',
    'movimiento_de_saldo_edicion', 'movimiento_de_saldo_lectura',
    'jornada_asignada_edicion', 'jornada_asignada_lectura',
    'patron_semanal_edicion', 'patron_semanal_lectura',
    'ausencia_edicion', 'ausencia_lectura',
    'excepcion_edicion', 'excepcion_lectura',
    'aprobacion_ausencia_edicion', 'aprobacion_ausencia_lectura',
    'tiempo_persona_edicion',
    'marca_lectura', 'tramo_lectura', 'clasificacion_de_tiempo_lectura', 'dia_lectura',
    'banco_de_horas_lectura'
  )
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = perm.codigo AND pp.activo
  );
