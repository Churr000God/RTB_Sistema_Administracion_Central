-- 37_tiempo_rls_terminal.sql
-- Primera RLS de todo el esquema tiempo. El checador físico es su propio subproyecto (repo
-- aparte: interfaz del aparato, credenciales de Supabase propias, base local y micro-backend que
-- procesa entradas/salidas y las sube a tiempo.marca — los batches de este repo las procesan
-- después). No es un usuario humano: sin sesión de Supabase Auth, sin puesto, sin permiso.
--
-- Identidad: rol de Postgres propio (terminal_checador), alcanzado por un JWT que la micro-backend
-- del terminal firma con el secreto del proyecto (mismo mecanismo que ya usa PostgREST para
-- anon/authenticated/service_role — no pasa por el flujo de login de Supabase Auth), claim
-- role=terminal_checador. Decisión confirmada con el usuario 2026-09-05 (SCJ-PRO-11): rol propio
-- en vez de service_role compartida — un checador de pared es mucho más expuesto físicamente que
-- un servidor, y con rol propio lo peor que puede hacer un aparato comprometido es insertar
-- marcas falsas, no leer/escribir el resto de la base.
--
-- Alcance deliberadamente mínimo: sólo INSERT en tiempo.marca, con origen='terminal' forzado por
-- la policy (aunque alguien manipule el payload, no puede insertarse como captura_manual). Nunca
-- SELECT/UPDATE/DELETE — ni siquiera de sus propias filas. El resto de RLS de tiempo (para el
-- backend humano vía get_caller_client) sigue pendiente, éste es sólo el primero.
-- Depende de: 02_tiempo.sql

CREATE ROLE terminal_checador NOLOGIN NOINHERIT;
GRANT terminal_checador TO authenticator;

GRANT USAGE ON SCHEMA tiempo TO terminal_checador;
GRANT INSERT ON tiempo.marca TO terminal_checador;

ALTER TABLE tiempo.marca ENABLE ROW LEVEL SECURITY;

CREATE POLICY terminal_inserta_su_origen ON tiempo.marca
  FOR INSERT
  TO terminal_checador
  WITH CHECK (origen = 'terminal');

COMMENT ON ROLE terminal_checador IS
  'Identidad de Postgres para el checador físico (repo aparte) — nunca un usuario humano. La '
  'micro-backend del terminal firma su propio JWT con el secreto del proyecto, claim '
  'role=terminal_checador. Alcance mínimo a propósito: sólo INSERT en tiempo.marca. SCJ-PRO-11.';
