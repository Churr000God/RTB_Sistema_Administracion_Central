-- 27_puesto_permiso_mapeo_inicial.sql
-- Mapeo real de permisos, confirmado con el usuario, sobre los puestos REALES ya sembrados del
-- organigrama (RH = "Responsable de Recursos Humanos", Dirección = "Gerente General"). Distinto
-- del bootstrap genérico de 26_*.sql — este archivo asume el seed de organigrama (11/13/15/16) ya
-- aplicado.
--
-- Heredables: RH otorgado directo; Dirección los recibe automático por herencia (reporta_a_id
-- apunta a Gerente General) salvo ver_modulo_1/ver_modulo_2, que se otorgan explícito a ambos. No
-- heredables: mismo patrón en Área/Departamento/Puesto/Permiso (RH lectura, Dirección lectura).
-- Puesto_permiso y Asignación: ambos en edición, lectura de ninguno se otorga por ahora (la
-- edición ya cubre el caso de uso). 18 filas en total.
--
-- Corrección 2026-09-05: este archivo originalmente otorgaba 10 permisos también a TI ("Encargado
-- de TI", edición en vez de lectura en los 4 pares no-heredables) -- ese era el mapeo real de
-- negocio confirmado con el usuario en su momento, documentado acá para no perder el rastro. Se
-- quitó porque el puesto "Encargado de TI" se unificó con "Gerente o Encargado de TI"
-- (16_puesto_migracion_inicial.sql, nota de cabecera) y ese puesto ya recibe los 16 permisos
-- completos de 26_puesto_permiso_bootstrap_admin_generico.sql -- superset estricto de los 10 que
-- este archivo le daba, así que repetirlos acá sería, en el mejor caso, un INSERT que el WHERE NOT
-- EXISTS descarta siempre (código muerto en cualquier despliegue nuevo, porque 26_ corre antes que
-- este archivo), y en el peor, una fuente de confusión sobre cuál de los dos archivos manda.
--
-- 18 INSERT en bitacora_movimiento_puesto_permiso (tipo_movimiento='otorgado'), resolviendo
-- puesto_id por nombre_puesto vía subconsulta, mismo patrón que 16_puesto_migracion_inicial.sql.
-- WHERE NOT EXISTS por fila para que reejecutar el archivo sea inocuo.
-- Depende de: 16_puesto_migracion_inicial.sql, 24_puesto_permiso_trigger.sql,
--   25_permiso_migracion_inicial.sql

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, m.codigo, 'otorgado'
FROM (VALUES
  -- Heredables: RH otorgado directo.
  ('Responsable de Recursos Humanos', 'alta_personas_usuarios'),
  ('Responsable de Recursos Humanos', 'cambio_estado_persona'),
  -- ver_modulo_1/ver_modulo_2: explícitos también en Dirección (no dependen de herencia acá).
  ('Responsable de Recursos Humanos', 'ver_modulo_1'),
  ('Gerente General',                 'ver_modulo_1'),
  ('Responsable de Recursos Humanos', 'ver_modulo_2'),
  ('Gerente General',                 'ver_modulo_2'),
  -- No heredables: RH lectura, Dirección lectura, mismo patrón en los cuatro.
  ('Responsable de Recursos Humanos', 'area_lectura'),
  ('Gerente General',                 'area_lectura'),
  ('Responsable de Recursos Humanos', 'departamento_lectura'),
  ('Gerente General',                 'departamento_lectura'),
  ('Responsable de Recursos Humanos', 'puesto_lectura'),
  ('Gerente General',                 'puesto_lectura'),
  ('Responsable de Recursos Humanos', 'permiso_lectura'),
  ('Gerente General',                 'permiso_lectura'),
  -- Puesto_permiso y Asignación: los dos en edición.
  ('Responsable de Recursos Humanos', 'puesto_permiso_edicion'),
  ('Gerente General',                 'puesto_permiso_edicion'),
  ('Responsable de Recursos Humanos', 'asignacion_edicion'),
  ('Gerente General',                 'asignacion_edicion')
) AS m(nombre_puesto, codigo)
JOIN personas.puesto p ON p.nombre_puesto = m.nombre_puesto
WHERE NOT EXISTS (
  SELECT 1 FROM personas.puesto_permiso pp
  WHERE pp.puesto_id = p.id AND pp.codigo = m.codigo AND pp.activo
);
