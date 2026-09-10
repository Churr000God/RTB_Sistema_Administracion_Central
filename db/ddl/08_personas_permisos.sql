-- 08_personas_permisos.sql
-- Otorga a los roles de la API de Supabase (anon, authenticated, service_role) los permisos de
-- Postgres sobre el esquema personas. Exponer el esquema en el dashboard (Data API) solo le dice
-- a PostgREST que lo busque ahí -- sin estos GRANT, Postgres sigue negando el acceso
-- ("permission denied for schema personas") incluso a service_role. RLS (06_personas_rls.sql)
-- sigue siendo el control real por fila para anon/authenticated; service_role la salta pero
-- igual necesita el GRANT de esquema/tabla para llegar a las filas.
-- Depende de: 05_personas_estructura.sql, 06_personas_rls.sql

GRANT USAGE ON SCHEMA personas TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA personas TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA personas TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA personas
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA personas
  GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
