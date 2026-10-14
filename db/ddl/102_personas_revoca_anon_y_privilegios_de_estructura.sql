-- 102_personas_revoca_anon_y_privilegios_de_estructura.sql
-- Endurecimiento de privilegios del esquema personas (la misma idea que 100_ para tiempo; ahí viven CURP, RFC, NSS y las bitácoras de identidad, de ahí la prioridad).
--
-- PROBLEMA. 08_personas_permisos.sql dio GRANT ALL schema-wide (y ALTER DEFAULT PRIVILEGES) a anon, authenticated y service_role; 21_/22_ lo repitieron por tabla y 23_ concedió
-- SELECT, INSERT sobre la bitácora de permisos. Resultado: anon conserva TODOS los privilegios de tabla (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER y, en PG17,
-- MAINTAIN) sobre personas.persona, usuario, expediente, asignacion, puesto, etc. La única barrera era RLS deny-by-default, que NO cubre TRUNCATE ni REFERENCES/TRIGGER/MAINTAIN.
--
-- QUÉ HACE (una transacción; el archivo NO lleva BEGIN/COMMIT: aplicar con `psql --single-transaction -v ON_ERROR_STOP=1 -f 102_*.sql`):
--   1) Por catálogo (DO) sobre CADA relación y secuencia de personas:
--        - anon: REVOKE ALL, con UNA excepción documentada: personas.permiso conserva SELECT para anon (ver «EXCEPCIÓN» abajo); de esa tabla se le quitan
--          INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER (y MAINTAIN en PG >= 17).
--        - authenticated y service_role, en cada tabla (r y p): REVOKE TRUNCATE, REFERENCES, TRIGGER y, en PG >= 17, MAINTAIN. CONSERVAN SELECT/INSERT/UPDATE/DELETE exactamente como
--          estaban (las RLS de 31_/69_/92_ y los REVOKE UPDATE/DELETE de las bitácoras inmutables, 28_, siguen mandando).
--      MAINTAIN solo existe desde PostgreSQL 17: esas partes van guardadas por current_setting('server_version_num') >= 170000 (el archivo se copia a RTB-App como migración).
--   2) ALTER DEFAULT PRIVILEGES IN SCHEMA personas: las tablas y secuencias futuras no nacen con GRANT ALL para anon, ni con TRUNCATE/REFERENCES/TRIGGER (ni MAINTAIN) para
--      authenticated y service_role. La regla del proyecto (cada tabla nueva hace su REVOKE ALL explícito y concede lo mínimo) sigue vigente.
--
-- EXCEPCIÓN (personas.permiso, SELECT para anon): verificar_ddl.sql sección 9 documenta un curl de humo con la anon key y Accept-Profile: personas que espera 200 con cuerpo []
-- (RLS deny-by-default: anon no ve ninguna fila). Revocar SELECT cambiaría esa respuesta a 401/42501 y esa comprobación dejaría de servir como humo del Data API. El privilegio
-- de SELECT no expone datos (RLS filtra todo para anon; el catálogo de permisos no es sensible) y es la ÚNICA tabla donde se conserva. ALTERNATIVA propuesta (decisión de
-- security/usuario, no hecha aquí): mover el humo a un endpoint sin tabla (por ejemplo GET /auth/v1/health o /rest/v1/ con Accept-Profile: personas) y revocar también ese SELECT
-- en un 103_ de una línea. Hasta entonces la excepción queda explícita en este archivo, en la sección 66 del verificador y en el ensayo.
--
-- LO QUE NO HACE (a propósito):
--   - No cambia ninguna policy RLS, función, trigger ni la inmutabilidad de las bitácoras (28_): solo GRANT/REVOKE de privilegios de tabla y secuencia y los defaults.
--   - No revoca USAGE del esquema a anon (la sección 3 del verificador lo exige) ni EXECUTE de funciones (nacen con PUBLIC; inventario de EXECUTE: corte aparte).
--   - No toca el esquema tiempo (100_).
--   - Quitar MAINTAIN NO impide `LOCK TABLE ... IN ACCESS EXCLUSIVE MODE` a authenticated/service_role (PostgreSQL lo permite con UPDATE, DELETE, TRUNCATE o MAINTAIN y ambos
--     conservan UPDATE/DELETE donde lo tenían); evita VACUUM, ANALYZE, REINDEX, CLUSTER y REFRESH MATERIALIZED VIEW a mano.
--
-- USO DE anon HOY (repositorio, sin consultar la base): backend/app/deps.py usa la anon key para get_caller_client (anon key + JWT => rol authenticated) y para auth.get_user (GoTrue);
-- nunca consulta personas como anon. El frontend usa supabase-js solo para autenticación. Supabase Auth corre con supabase_auth_admin (no afectado).
--
-- Inventario de RLS: sin cambios (este archivo no crea ni cambia policies ni activa/desactiva RLS).
--
-- REVERSA EXACTA (el estado previo NO es «todo concedido»: GRANT ALL genérico no es la reversa). ANTES de aplicar, guardar la salida de esta consulta (reversa lista para ejecutar):
--     SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
--                   CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
--     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--     CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
--     WHERE n.nspname = 'personas' AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
--     GROUP BY c.oid, c.relkind, r.rolname;
--   y los privilegios por defecto vuelven con:
--     ALTER DEFAULT PRIVILEGES IN SCHEMA personas GRANT ALL ON TABLES TO anon, authenticated, service_role;
--     ALTER DEFAULT PRIVILEGES IN SCHEMA personas GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
--   db/ensayos/ensayo_102.sql ejecuta exactamente este procedimiento dentro de su transacción y comprueba que la foto de privilegios queda idéntica a la previa.

DO $$
DECLARE
  r record;
  -- MAINTAIN existe solo desde PostgreSQL 17 (server_version_num >= 170000); en una versión anterior el REVOKE nombraría un privilegio inexistente.
  v_maintain text := CASE WHEN current_setting('server_version_num')::integer >= 170000 THEN ', MAINTAIN' ELSE '' END;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS rel, c.oid, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'personas' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
    ORDER BY c.relname
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM anon', r.rel);
    ELSIF r.oid = 'personas.permiso'::regclass THEN
      -- Única excepción: anon conserva SELECT (humo del Data API, sección 9 del verificador). RLS no le deja ninguna fila.
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER%s ON TABLE %s FROM anon', v_maintain, r.rel);
    ELSE
      EXECUTE format('REVOKE ALL ON TABLE %s FROM anon', r.rel);
    END IF;
    IF r.relkind IN ('r', 'p') THEN
      EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER%s ON TABLE %s FROM authenticated, service_role', v_maintain, r.rel);
    END IF;
  END LOOP;
END
$$;

-- ============================================================================
-- Privilegios por defecto de los objetos futuros del esquema (el ALTER DEFAULT PRIVILEGES de 08_ corre con el rol que aplica las migraciones)
-- ============================================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA personas REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA personas REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLES FROM authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA personas REVOKE ALL ON SEQUENCES FROM anon;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer >= 170000 THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA personas REVOKE MAINTAIN ON TABLES FROM authenticated, service_role';
  END IF;
END
$$;
