-- 28_bitacora_puesto_permiso_revoca_update_delete.sql
-- Fix de seguridad (hallazgo de auditoría, severidad baja): 23_personas_bitacora_puesto_permiso.sql
-- asumió que UPDATE/DELETE "nunca se concedieron" a esta tabla, pero el ALTER DEFAULT PRIVILEGES
-- de 08_personas_permisos.sql ya los había otorgado por default al crearla (antes de que el GRANT
-- explícito de 23 corriera) -- GRANT es aditivo, no reemplaza. Sin impacto funcional (el trigger
-- de 23_*.sql ya bloquea UPDATE/DELETE para cualquier rol, incluido postgres/service_role), pero
-- la capa 1 de la inmutabilidad documentada no existía de verdad en la base -- mismo REVOKE que
-- ya usa 09_personas_bitacora_inmutable.sql para bitacora_movimiento_persona.
-- Depende de: 23_personas_bitacora_puesto_permiso.sql

REVOKE UPDATE, DELETE ON personas.bitacora_movimiento_puesto_permiso FROM anon, authenticated, service_role;
