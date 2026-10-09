-- 93_tiempo_retira_terminal_checador.sql
-- Retira el camino de escritura directo a tiempo.marca del rol terminal_checador (37_*.sql). Desde SCJ-DEC-12 / SCJ-PRO-11 V3.0 las marcas de la
-- terminal suben por el backend con fn_marca_terminal_registrar (SECURITY DEFINER, EXECUTE sólo service_role): ese rol y su policy ya no los usa
-- ningún componente vivo. Sólo el checador básico (repo checador-fisico, hoy apagado) firmaba un JWT con role=terminal_checador. Revisado por db
-- el 9-oct-2026 contra la base real (sólo lectura): el rol sólo tiene INSERT en tiempo.marca y USAGE en el esquema tiempo, la policy
-- terminal_inserta_su_origen, y es miembro de authenticator (y de postgres con admin option, por haberlo creado). Ningún otro objeto lo menciona.
--
-- Qué NO resuelve (decisión del usuario de no rotar SUPABASE_JWT_SECRET ni SERVICE_ROLE_KEY): quien tenga el JWT secret puede firmar un token con
-- role=service_role o authenticated, que es más ancho que este rol; quien tenga la SERVICE_ROLE_KEY puede llamar al RPC de marcas directo. Esto es
-- higiene y defensa en profundidad (un solo camino de escritura de marcas), no una mitigación de esa fuga. Sólo rotar la cierra.
--
-- APLICAR con `psql --single-transaction -f 93_*.sql` (o confirmar con `SELECT txid_current(); SELECT txid_current();` que el SQL Editor es una sola
-- transacción). El archivo NO lleva BEGIN/COMMIT (los ensayos lo incluyen dentro de su propio BEGIN … ROLLBACK). Idempotente: DROP POLICY IF EXISTS y
-- REVOKE no fallan si ya se quitó.
--
-- Qué hace (orden):
--   a) DROP POLICY terminal_inserta_su_origen: sin ella, aun con privilegio, RLS rechazaría cualquier INSERT del rol.
--   b) REVOKE INSERT ON tiempo.marca: quita el único privilegio de tabla del rol.
--   c) REVOKE USAGE ON SCHEMA tiempo: el rol ya no ve el esquema.
--   d) REVOKE terminal_checador FROM authenticator: PostgREST ya no puede hacer SET ROLE a este rol, así que un JWT con role=terminal_checador
--      deja de ser un token utilizable (la petición falla). Quita también el efecto de cualquier GRANT futuro por descuido.
-- El rol queda VACÍO y NOLOGIN, a propósito: db/verificar_ddl.sql llama has_*_privilege('terminal_checador', …) en unas 15 consultas, que con el rol
-- borrado fallarían con "role does not exist". El DROP ROLE es un corte aparte (ver bloque al final), después de actualizar esos verificadores.
--
-- Qué NO toca: RLS de tiempo.marca sigue habilitada; marca_insert_captura_manual y marca_select_requiere_permiso (46_/61_) no cambian;
-- fn_marca_terminal_registrar inserta como dueño del esquema (postgres, BYPASSRLS, sin FORCE ROW LEVEL SECURITY), no depende de la policy.
--
-- Inventario de RLS/privilegios de este archivo: sin tablas ni policies nuevas; se QUITA 1 policy y se quitan privilegios, no se agrega ninguno.
--
-- REVERSA (si el checador básico tuviera que volver; son exactamente las líneas de 37_ salvo CREATE ROLE, que el rol ya existe):
--   GRANT terminal_checador TO authenticator;
--   GRANT USAGE ON SCHEMA tiempo TO terminal_checador;
--   GRANT INSERT ON tiempo.marca TO terminal_checador;
--   CREATE POLICY terminal_inserta_su_origen ON tiempo.marca FOR INSERT TO terminal_checador WITH CHECK (origen = 'terminal');
--
-- CORTE POSTERIOR (no en este archivo; requiere actualizar antes db/verificar_ddl.sql y los verificar_*.sql que nombran el rol):
--   DROP ROLE terminal_checador;   -- falla si queda algún objeto o privilegio que lo mencione; es la comprobación final

DROP POLICY IF EXISTS terminal_inserta_su_origen ON tiempo.marca;
REVOKE INSERT ON tiempo.marca FROM terminal_checador;
REVOKE USAGE ON SCHEMA tiempo FROM terminal_checador;
REVOKE terminal_checador FROM authenticator;

COMMENT ON ROLE terminal_checador IS
  'RETIRADO (93_). Sin privilegios, sin policies y sin membresía en authenticator: un JWT con role=terminal_checador ya no funciona. Las marcas de '
  'la terminal suben por fn_marca_terminal_registrar (SCJ-DEC-12). Se conserva vacío y NOLOGIN sólo para que db/verificar_ddl.sql siga corriendo; '
  'se borrará en un corte aparte.';
