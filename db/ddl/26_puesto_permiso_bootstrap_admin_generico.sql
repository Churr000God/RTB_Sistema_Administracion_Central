-- 26_puesto_permiso_bootstrap_admin_generico.sql
-- Fixture de sistema, independiente del organigrama real de esta empresa: un puesto genérico con
-- los 16 permisos completos, para que cualquier despliegue desde cero tenga por dónde entrar —
-- funciona incluso si el seed de organigrama (11/13/15/16) NO está aplicado.
--
-- Estructura propia (área/departamento/puesto), ON CONFLICT DO NOTHING por nombre: si un
-- despliegue ya tiene estructura real con esos nombres exactos, se reusa en vez de duplicar.
-- El puesto reporta al tope existente si ya hay uno (reporta_a_id = el puesto sin padre actual),
-- o se vuelve tope él mismo si no hay ninguno todavía (subconsulta da NULL). No se reconcilia
-- automáticamente si después se carga un organigrama real con su propio tope — manual, fuera de
-- alcance de este corte.
--
-- personas.usuario (el auth_user_id real) NO se crea acá — es la única pieza que no puede ser SQL
-- puro, necesita un auth.users real que sólo Supabase Auth puede emitir. Eso vive en
-- scripts/desplegar.sh (sesión devops), no en DDL.
--
-- Corrección 2026-09-05: este archivo corre antes que 16_puesto_migracion_inicial.sql en el orden
-- de despliegue, pero antes ambos sembraban un puesto de TI cada uno (16_ creaba "Encargado de
-- TI" como puesto propio del organigrama; éste crea "Gerente o Encargado de TI") — dos filas para
-- el mismo rol, siempre duplicadas en un despliegue nuevo. Se unificaron en uno solo: el que crea
-- ESTE archivo, "Gerente o Encargado de TI" bajo "Gerencia de Tecnologías de la Información". Ver
-- la nota de cabecera de 16_puesto_migracion_inicial.sql para el detalle completo.
-- Depende de: 14_personas_puesto.sql, 17_personas_asignacion.sql, 24_puesto_permiso_trigger.sql,
--   25_permiso_migracion_inicial.sql

INSERT INTO personas.area (nombre_area) VALUES
  ('Tecnologías de la Información')
ON CONFLICT (nombre_area) DO NOTHING;

INSERT INTO personas.departamento (area_id, nombre_departamento)
SELECT a.id, 'Gerencia de Tecnologías de la Información'
FROM personas.area a
WHERE a.nombre_area = 'Tecnologías de la Información'
ON CONFLICT (nombre_departamento) DO NOTHING;

INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Gerente o Encargado de TI', 'gerencia',
  (SELECT id FROM personas.puesto WHERE reporta_a_id IS NULL LIMIT 1)
FROM personas.departamento dep
WHERE dep.nombre_departamento = 'Gerencia de Tecnologías de la Información'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Gerente o Encargado de TI');

-- Los 16 permisos completos, otorgados vía bitácora (deja que el trigger de 24_*.sql arme
-- puesto_permiso). WHERE NOT EXISTS por fila para que reejecutar el archivo sea inocuo.
INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, perm.codigo, 'otorgado'
FROM personas.puesto p
CROSS JOIN personas.permiso perm
WHERE p.nombre_puesto = 'Gerente o Encargado de TI'
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = perm.codigo AND pp.activo
  );

-- Persona placeholder — CURP/RFC/NSS claramente sintéticos, mismo estilo "XEXX..." ya usado en
-- las consultas de validación del proyecto para personas de prueba. Sin expediente (opcional).
INSERT INTO personas.persona
  (curp, rfc, nss, primer_nombre, apellido_paterno, fecha_nacimiento, fecha_ingreso)
SELECT 'XEXX010101HNEXXXA9', 'XEXX010101AB9', '00000000000',
  'Administrador', 'del Sistema', '2000-01-01', CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM personas.persona WHERE curp = 'XEXX010101HNEXXXA9');

INSERT INTO personas.asignacion (persona_id, puesto_id, vigente_desde)
SELECT per.id, p.id, CURRENT_DATE
FROM personas.persona per, personas.puesto p
WHERE per.curp = 'XEXX010101HNEXXXA9'
  AND p.nombre_puesto = 'Gerente o Encargado de TI'
  AND NOT EXISTS (
    SELECT 1 FROM personas.asignacion a
    WHERE a.persona_id = per.id AND a.puesto_id = p.id AND a.vigente_hasta IS NULL
  );
