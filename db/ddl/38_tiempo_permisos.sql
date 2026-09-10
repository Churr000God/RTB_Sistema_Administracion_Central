-- 38_tiempo_permisos.sql
-- Otorga a los roles de la API de Supabase (anon, authenticated, service_role) los permisos de
-- Postgres sobre el esquema tiempo. Mismo motivo que 08_personas_permisos.sql: exponer el esquema
-- en el dashboard (Data API) sólo le dice a PostgREST que lo busque ahí -- sin estos GRANT,
-- Postgres sigue negando el acceso ("permission denied for schema tiempo") incluso a service_role.
-- Sin este archivo, get_caller_client (anon key + JWT) del backend no puede pegarle a tiempo en
-- absoluto -- bloqueador duro para todo router de Tiempo, no sólo jornada_asignada/patron_semanal.
--
-- terminal_checador NO se toca aquí -- ya tiene su propio GRANT mínimo, acotado a INSERT en
-- tiempo.marca (37_tiempo_rls_terminal.sql). Este archivo es para anon/authenticated/service_role,
-- los tres roles que ya usa el resto del proyecto.
--
-- REVOKE UPDATE, DELETE en tiempo.marca: mismo hallazgo que 28_bitacora_puesto_permiso_revoca_
-- update_delete.sql -- el ALTER DEFAULT PRIVILEGES de abajo es "GRANT ALL" a cualquier tabla nueva
-- del esquema, aditivo, sin excepción por tabla. tiempo.marca está documentada como inmutable
-- (02_tiempo.sql: "ningún flujo de la aplicación emite UPDATE ni DELETE... sólo INSERT, cualquier
-- corrección pasa por tiempo.correccion") pero, a diferencia de las bitácoras de personas, no tiene
-- un trigger BEFORE UPDATE/DELETE que la respalde -- sin este REVOKE, service_role (que ignora RLS
-- por completo, Ignora RLS en pg_roles) sí podría hacerlo. Se revoca desde el arranque, no se
-- espera a que un hallazgo de auditoría lo encuentre después.
-- Depende de: 02_tiempo.sql
--
-- No se agrega ver_modulo_3/gate de permiso específico aquí -- eso es RLS (31_*.sql es el patrón,
-- 39_tiempo_rls_jornada_patron.sql lo aplica a jornada_asignada/patron_semanal), no un GRANT de
-- Postgres. Este archivo sólo abre la puerta del esquema; quién puede hacer qué adentro lo decide
-- cada policy.

GRANT USAGE ON SCHEMA tiempo TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA tiempo TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA tiempo TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

REVOKE UPDATE, DELETE ON tiempo.marca FROM anon, authenticated, service_role;
