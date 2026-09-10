-- 16_puesto_migracion_inicial.sql
-- Seed de personas.puesto con 12 de los 13 puestos marcados "Actual" en el organigrama (no se
-- siembran los "Previsto"/"Crecimiento" — estructura aspiracional, fuera de alcance de este
-- corte). Fuente: organigrama externo no versionado (no entra al repo). Sólo se tomaron los
-- nombres de puesto, su departamento, nivel y jerarquía de reporte — nada de personas, ni razón
-- social.
--
-- Nota de resolución: el organigrama lista a "Gerente de Adm. y Finanzas" dos veces (cabeza de
-- área y, de nuevo, como titular actual de Finanzas y Tesorería). Se modela como UN SOLO puesto
-- (fila 9, colgado del departamento placeholder de Dirección) — el departamento real "Finanzas y
-- Tesorería" queda sin puesto propio en este seed; su único ocupante actual ya está representado
-- a nivel de área.
--
-- Corrección 2026-09-05: el puesto #13 del organigrama ("Encargado de TI", cabeza de Tecnologías
-- de la Información) SE QUITÓ de este archivo -- este seed lo creaba como fila propia, colgado
-- del departamento placeholder "Dirección de Tecnologías de la Información" (15_*.sql), en
-- paralelo e independiente del puesto "Gerente o Encargado de TI" que
-- 26_puesto_permiso_bootstrap_admin_generico.sql siembra para el fixture de bootstrap (16_ corre
-- antes que 26_ por orden de archivo, así que en un despliegue nuevo el duplicado nacía siempre).
-- El usuario decidió unificar en un solo puesto: "Gerente o Encargado de TI", bajo el
-- departamento que ya crea 26_ ("Gerencia de Tecnologías de la Información") -- ver ese archivo
-- para la fila real. El mapeo de permisos que este puesto tenía en 27_puesto_permiso_mapeo_
-- inicial.sql también se ajustó en consecuencia (ver ese archivo). El dato ya existente en el
-- Supabase de esta sesión (la fila vieja "Encargado de TI", con historial real de otorgar/revocar
-- permisos) NO se tocó desde este archivo -- se desactivó a mano vía el flujo real de la app,
-- porque su bitácora es inmutable y no se puede borrar (detalle en la bitácora de sesión del
-- 2026-09-05, pendiente de escribir al cierre del pase).
-- Orden top-down: cada INSERT resuelve su departamento_id por nombre_departamento y su
-- reporta_a_id por nombre_puesto de una fila ya insertada por un paso anterior de este mismo
-- archivo. Sin UNIQUE en nombre_puesto (ver 14_personas_puesto.sql) — cada INSERT usa WHERE NOT
-- EXISTS para que reejecutar el archivo sea inocuo.
-- Depende de: 14_personas_puesto.sql, 15_estructura_placeholders_direccion.sql

-- 1. Gerente General — puesto tope, reporta_a_id NULL.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Gerente General', 'direccion', NULL
FROM personas.departamento dep
WHERE dep.nombre_departamento = 'Dirección General'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Gerente General');

-- 2. Gerente Comercial — reporta a Gerente General.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Gerente Comercial', 'gerencia', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Dirección Comercial'
  AND jefe.nombre_puesto = 'Gerente General'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Gerente Comercial');

-- 3. Vendedor y Asesor Comercial — reporta a Gerente Comercial.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Vendedor y Asesor Comercial', 'operativo', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Dirección Comercial'
  AND jefe.nombre_puesto = 'Gerente Comercial'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Vendedor y Asesor Comercial');

-- 4. Gerente de Operaciones — reporta a Gerente General.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Gerente de Operaciones', 'gerencia', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Dirección de Operaciones'
  AND jefe.nombre_puesto = 'Gerente General'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Gerente de Operaciones');

-- 5. Responsable de Compras y Abastecimiento — reporta a Gerente de Operaciones.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Responsable de Compras y Abastecimiento', 'mando_medio', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Compras y Abastecimiento'
  AND jefe.nombre_puesto = 'Gerente de Operaciones'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Responsable de Compras y Abastecimiento');

-- 6. Encargado de Almacén — reporta a Gerente de Operaciones.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Encargado de Almacén', 'mando_medio', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Almacén'
  AND jefe.nombre_puesto = 'Gerente de Operaciones'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Encargado de Almacén');

-- 7. Auxiliar de Almacén y Empaque — reporta a Encargado de Almacén.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Auxiliar de Almacén y Empaque', 'operativo', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Almacén'
  AND jefe.nombre_puesto = 'Encargado de Almacén'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Auxiliar de Almacén y Empaque');

-- 8. Chofer Repartidor y Recolector — reporta a Gerente de Operaciones.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Chofer Repartidor y Recolector', 'operativo', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Logística y Distribución'
  AND jefe.nombre_puesto = 'Gerente de Operaciones'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Chofer Repartidor y Recolector');

-- 9. Gerente de Adm. y Finanzas — reporta a Gerente General. Un solo puesto (cabeza de área y
--    titular de Finanzas y Tesorería a la vez, ver nota de cabecera); cuelga del departamento
--    placeholder de Dirección, no de "Finanzas y Tesorería".
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Gerente de Adm. y Finanzas', 'gerencia', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Dirección de Administración y Finanzas'
  AND jefe.nombre_puesto = 'Gerente General'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Gerente de Adm. y Finanzas');

-- 10. Auxiliar de Facturación y Cobranza — reporta a Gerente de Adm. y Finanzas.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Auxiliar de Facturación y Cobranza', 'operativo', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Facturación y Cobranza'
  AND jefe.nombre_puesto = 'Gerente de Adm. y Finanzas'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Auxiliar de Facturación y Cobranza');

-- 11. Auxiliar Administrativo — reporta a Gerente de Adm. y Finanzas.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Auxiliar Administrativo', 'operativo', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Administración'
  AND jefe.nombre_puesto = 'Gerente de Adm. y Finanzas'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Auxiliar Administrativo');

-- 12. Responsable de Recursos Humanos — reporta a Gerente General.
INSERT INTO personas.puesto (departamento_id, nombre_puesto, nivel, reporta_a_id)
SELECT dep.id, 'Responsable de Recursos Humanos', 'mando_medio', jefe.id
FROM personas.departamento dep, personas.puesto jefe
WHERE dep.nombre_departamento = 'Dirección de Recursos Humanos'
  AND jefe.nombre_puesto = 'Gerente General'
  AND NOT EXISTS (SELECT 1 FROM personas.puesto WHERE nombre_puesto = 'Responsable de Recursos Humanos');

-- 13. Encargado de TI — QUITADO 2026-09-05, ver nota de cabecera de este archivo. Ahora lo crea
-- 26_puesto_permiso_bootstrap_admin_generico.sql como "Gerente o Encargado de TI".
