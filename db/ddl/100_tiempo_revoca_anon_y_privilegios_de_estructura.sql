-- 100_tiempo_revoca_anon_y_privilegios_de_estructura.sql
-- Endurecimiento de privilegios del esquema tiempo (parte B de la propuesta de security tras el retiro de terminal_checador, 93_). Inventario y razones:
-- db/ensayos/BORRADOR_inventario_anon.md (§1-§3) y db/ensayos/README.md.
--
-- PROBLEMA. 38_tiempo_permisos.sql dio GRANT ALL schema-wide (y ALTER DEFAULT PRIVILEGES) a anon, authenticated y service_role. Varias tablas lo revocaron a mano (80_, 81_, 82_, 84_,
-- 86_, 88_, 97_, 99_...), pero el resto (jornada, patrón, marca, día, tramo, banco, correcciones, ausencias, excepciones, parámetros...) conserva en anon TODOS los privilegios
-- de tabla (la lectura de relacl de tiempo.marca el 9-oct-2026 mostró anon=arDxtm). La única barrera era RLS deny-by-default, que NO cubre TRUNCATE (no está sujeto a RLS) ni
-- REFERENCES/TRIGGER (privilegios de estructura que ningún rol de la API debe tener).
--
-- QUÉ HACE (todo en una transacción; el archivo NO lleva BEGIN/COMMIT: aplicar con `psql --single-transaction -v ON_ERROR_STOP=1 -f 100_*.sql`):
--   1) Por catálogo (DO), sobre CADA relación de tiempo (tablas, particionadas, vistas, matviews, foráneas):  REVOKE ALL FROM anon.
--      Sobre CADA secuencia de tiempo: REVOKE ALL FROM anon. Es por catálogo y no por lista para que no dependa de que el inventario del DDL esté completo.
--   2) Sobre CADA tabla (relkind r y p) de tiempo: REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN FROM authenticated, service_role. Ningún router ni batch los usa (backend: cero
--      TRUNCATE y cero VACUUM/ANALYZE/REINDEX/CLUSTER/REFRESH; los FK y los triggers los crea y dispara el dueño; el DROP SCHEMA ... CASCADE de reconstrucción lo hace postgres; autovacuum
--      corre como dueño). authenticated y service_role CONSERVAN SELECT/INSERT/UPDATE/DELETE exactamente como estaban (las RLS y los REVOKE por tabla de cada migración siguen mandando).
--      MAINTAIN (letra m) solo existe desde PostgreSQL 17: ese pedazo va guardado por current_setting('server_version_num') >= 170000 para que el archivo siga aplicando en una base anterior
--      (se copia a RTB-App como migración). La base real es 17.6.
--      PRECISIÓN IMPORTANTE: quitar MAINTAIN NO impide `LOCK TABLE ... IN ACCESS EXCLUSIVE MODE` a authenticated/service_role: PostgreSQL lo permite con UPDATE, DELETE, TRUNCATE o MAINTAIN
--      y ambos roles CONSERVAN UPDATE/DELETE. Lo que sí evita es VACUUM, ANALYZE, REINDEX, CLUSTER y REFRESH MATERIALIZED VIEW a mano. La superficie de bloqueo mediante una función
--      SECURITY DEFINER mal escrita es el inventario de EXECUTE (corte aparte, pendiente).
--   3) ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo: las tablas y secuencias futuras ya no nacen con GRANT ALL para anon, ni con TRUNCATE/REFERENCES/TRIGGER (ni MAINTAIN en PG >= 17) para
--      authenticated y service_role. La regla del proyecto (cada tabla nueva hace su REVOKE ALL explícito y concede lo mínimo) sigue vigente: esto es la red de seguridad.
--
-- LO QUE NO HACE (a propósito):
--   - No toca el esquema personas (08_personas_permisos.sql tiene el mismo problema; decisión pendiente: mismo mecanismo, archivo aparte).
--   - No revoca USAGE del esquema a anon ni EXECUTE de funciones: las funciones nacen con EXECUTE para PUBLIC (revocar a anon no lo quita) y el verificador ya exige REVOKE
--     explícito en las del módulo de terminales; el inventario de las funciones de los módulos anteriores es un corte aparte.
--   - No cambia nada para authenticated/service_role fuera de TRUNCATE/REFERENCES/TRIGGER/MAINTAIN.
--   - No toca membresías de rol (p. ej. si Supabase hiciera a service_role miembro de pg_maintain, ese MAINTAIN heredado no lo quita ningún REVOKE de tabla: residuo conocido que el ensayo
--     informa, no una falla de este archivo).
--
-- USO DE anon HOY (verificado en el repositorio, sin consultar la base): backend/app/deps.py usa la anon key sólo (a) para construir get_caller_client (anon key + JWT del usuario:
-- el rol efectivo es authenticated) y (b) para auth.get_user(token) (GoTrue, no PostgREST). Nunca consulta tiempo como anon. El frontend sólo usa supabase-js para autenticación
-- (lib/supabaseClient.ts), sin .from()/.rpc() contra tiempo. El curl de humo de verificar_ddl.sql (sección 9) usa personas.permiso, que este archivo no toca.
--
-- Inventario de RLS: sin cambios (este archivo no crea ni cambia policies ni activa/desactiva RLS).
--
-- REVERSA EXACTA (el estado previo NO es «todo concedido»: varias tablas ya habían revocado a anon, así que un GRANT ALL genérico NO es la reversa). Procedimiento:
--   ANTES de aplicar, guardar la salida de esta consulta (es la reversa lista para ejecutar):
--     SELECT format('GRANT %s ON %s %s TO %I;', string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type),
--                   CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END, c.oid::regclass, r.rolname)
--     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--     CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee
--     WHERE n.nspname = 'tiempo' AND c.relkind IN ('r','p','v','m','f','S') AND r.rolname IN ('anon','authenticated','service_role')
--     GROUP BY c.oid, c.relkind, r.rolname;
--   y los privilegios por defecto vuelven con:
--     ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo GRANT ALL ON TABLES TO anon, authenticated, service_role;
--     ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
--   db/ensayos/ensayo_100.sql ejecuta exactamente este procedimiento dentro de su transacción y comprueba que el estado de privilegios queda idéntico al previo. La consulta incluye MAINTAIN
--   cuando existe (aclexplode lo lista como privilegio de la tabla), así que la reversa lo vuelve a conceder.
--   Nota: GRANT es aditivo y ejecutarlo de nuevo sobre algo ya concedido es inocuo; restaurar no vuelve a poner un privilegio de COLUMNA que no existía.

-- ============================================================================
-- 1) y 2) Revocaciones por catálogo
-- ============================================================================

DO $$
DECLARE
  r record;
  -- MAINTAIN existe solo desde PostgreSQL 17 (server_version_num >= 170000); en una versión anterior el REVOKE nombraría un privilegio inexistente.
  v_maintain text := CASE WHEN current_setting('server_version_num')::integer >= 170000 THEN ', MAINTAIN' ELSE '' END;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS rel, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'tiempo' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
    ORDER BY c.relname
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('REVOKE ALL ON SEQUENCE %s FROM anon', r.rel);
    ELSE
      EXECUTE format('REVOKE ALL ON TABLE %s FROM anon', r.rel);
      IF r.relkind IN ('r', 'p') THEN
        EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER%s ON TABLE %s FROM authenticated, service_role', v_maintain, r.rel);
      END IF;
    END IF;
  END LOOP;
END
$$;

-- ============================================================================
-- 3) Privilegios por defecto de los objetos futuros del esquema (el ALTER DEFAULT PRIVILEGES de 38_ corre con el rol que aplica las migraciones)
-- ============================================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLES FROM authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo REVOKE ALL ON SEQUENCES FROM anon;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer >= 170000 THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA tiempo REVOKE MAINTAIN ON TABLES FROM authenticated, service_role';
  END IF;
END
$$;
