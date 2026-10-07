-- 82_tiempo_terminal_credencial_y_estado.sql
-- Primera de tres piezas de SCJ-DEC-12 (autenticación de la terminal y ruta de marcas): DATOS Y
-- PRIVILEGIOS. Las funciones (los RPC y el trigger de desactivación) van en 83_*.sql y la tabla de
-- rechazos en 84_*.sql, partidos a propósito: un defecto en un RPC no obliga a rehacer el esquema ni
-- a reabrir los grants.
--
-- Qué crea:
--   1) tiempo.terminal_credencial -- la llave opaca (scjt_...) del Pi, guardada SÓLO como hash
--      SHA-256. Una fila por llave; una terminal puede tener varias vigentes a la vez (es el
--      traslape de una rotación). Se revoca por llave (revocada_en) o por terminal (activa=false).
--   2) 4 columnas de estado/telemetría en tiempo.terminal que escribe el latido del Pi
--      (fn_terminal_latido, 83_*.sql): reloj_desfase_seg, terminal_alcanzable, version_pi,
--      marcas_pendientes.
--
-- Endurecimiento de grants (mismo molde de 80_*/81_*, lección de 28_*/41_*/47_*): el ALTER DEFAULT
-- PRIVILEGES de 38_tiempo_permisos.sql da GRANT ALL a anon, authenticated y service_role sobre toda
-- tabla y secuencia nueva, y GRANT es aditivo. Por eso terminal_credencial hace REVOKE ALL a los
-- tres y luego concede sólo lo estrictamente necesario, en este mismo archivo.
--
-- Inventario de RLS/privilegios de este archivo (regla de CLAUDE.md):
--   tiempo.terminal_credencial  RLS on, 0 policies. anon/authenticated: ningún privilegio.
--                               service_role: SELECT, INSERT, y UPDATE sólo de revocada_en,
--                               expira_en y etiqueta. Sin DELETE ni TRUNCATE para nadie. ultimo_uso_en,
--                               ultima_ip e ip_cambiada_en los escribe sólo fn_terminal_autenticar
--                               (SECURITY DEFINER, 83_*.sql); hash nunca se actualiza.
--   tiempo.terminal             RLS y policy de 80_*.sql sin cambio. Las 4 columnas nuevas quedan
--                               legibles por quien ya lee la tabla (RLS: lectura o edición de
--                               terminal_usuario; no son datos sensibles) y FUERA del GRANT UPDATE de
--                               columna de service_role (80_*.sql:117): las escribe sólo
--                               fn_terminal_latido. verificar_ddl.sql (sección 14) lo comprueba.
--
-- Una revocación es irreversible: el trigger trg_terminal_credencial_revocacion_inmutable (SCJ14, 83_*.sql, M3
-- de la revisión de security) impide que revocada_en cambie una vez fijada (ni a NULL ni a otro instante).
--
-- Rollback de referencia (NO ejecutar sin revisar; 83_*.sql y 84_*.sql se revierten primero):
--   ALTER TABLE tiempo.terminal
--     DROP COLUMN reloj_desfase_seg, DROP COLUMN terminal_alcanzable,
--     DROP COLUMN version_pi, DROP COLUMN marcas_pendientes;
--   DROP TABLE tiempo.terminal_credencial;
--   -- Las policies (ninguna), el índice ix_terminal_credencial_terminal_id, la secuencia identity y el CHECK
--   -- ck_terminal_marcas_pendientes caen con la tabla/las columnas. Antes de DROP TABLE hay que haber quitado
--   -- el trigger SCJ14 de 83_*.sql (cuya función queda huérfana si no se borra).
--
-- Depende de: 38_tiempo_permisos.sql, 80_tiempo_terminal_usuario.sql
-- Justificación: SCJ-DEC-12 §1, §6, §9

-- ============================================================================
-- 1) tiempo.terminal_credencial
-- ============================================================================

CREATE TABLE tiempo.terminal_credencial (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_id     bigint NOT NULL REFERENCES tiempo.terminal (id),
  hash            char(64) NOT NULL,
  etiqueta        varchar(60),
  creada_en       timestamptz NOT NULL DEFAULT now(),
  expira_en       timestamptz,
  revocada_en     timestamptz,
  ultimo_uso_en   timestamptz,
  ultima_ip       inet,
  ip_cambiada_en  timestamptz,
  CONSTRAINT uq_terminal_credencial_hash UNIQUE (hash),
  CONSTRAINT ck_terminal_credencial_hash CHECK (hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX ix_terminal_credencial_terminal_id ON tiempo.terminal_credencial (terminal_id);

COMMENT ON TABLE tiempo.terminal_credencial IS
  'Llave opaca del puente de una terminal (SCJ-DEC-12 §1): formato scjt_ + 43 caracteres URL-safe, '
  'guardada sólo como hash SHA-256 hex. Acceso válido si revocada_en IS NULL, expira_en IS NULL o '
  'futuro, y tiempo.terminal.activa. Se da de alta sólo por script de TI con service_role (sin '
  'endpoint web). Sin DELETE: una llave retirada se revoca.';
COMMENT ON COLUMN tiempo.terminal_credencial.terminal_id IS
  'FK a tiempo.terminal(id) (surrogate, no la serie). Todo valor de terminal que se escriba lo fija el '
  'servidor desde esta fila, nunca el cliente.';
COMMENT ON COLUMN tiempo.terminal_credencial.hash IS
  'SHA-256 hex (64 caracteres en minúscula) de la llave completa. Nunca la llave. UNIQUE: la '
  'búsqueda es por igualdad. No se actualiza nunca.';
COMMENT ON COLUMN tiempo.terminal_credencial.etiqueta IS
  'Nombre legible para TI (ej. "llave 2026-10"). Sin datos sensibles.';
COMMENT ON COLUMN tiempo.terminal_credencial.expira_en IS
  'Opcional. NULL = sin vencimiento (aparato desatendido: un vencimiento automático lo apagaría en '
  'silencio). La rotación es manual, recomendada cada 12 meses.';
COMMENT ON COLUMN tiempo.terminal_credencial.revocada_en IS
  'Momento de la revocación; NULL = vigente. Una rotación deja ambas llaves vigentes (el traslape) '
  'hasta revocar la vieja.';
COMMENT ON COLUMN tiempo.terminal_credencial.ultimo_uso_en IS
  'Última petición autenticada con esta llave. Lo escribe sólo fn_terminal_autenticar, con una '
  'escritura como máximo cada 30 segundos.';
COMMENT ON COLUMN tiempo.terminal_credencial.ultima_ip IS
  'IP de la última petición autenticada. Un cambio respecto de la anterior es una alarma (tablero), '
  'no un bloqueo: un Pi con DHCP cambiante da falsos positivos.';
COMMENT ON COLUMN tiempo.terminal_credencial.ip_cambiada_en IS
  'Momento del último cambio de IP detectado.';

ALTER TABLE tiempo.terminal_credencial ENABLE ROW LEVEL SECURITY;  -- sin policies: nadie de la API lee

REVOKE ALL ON tiempo.terminal_credencial FROM anon, authenticated, service_role;
GRANT SELECT, INSERT ON tiempo.terminal_credencial TO service_role;
GRANT UPDATE (revocada_en, expira_en, etiqueta) ON tiempo.terminal_credencial TO service_role;

REVOKE ALL ON SEQUENCE tiempo.terminal_credencial_id_seq FROM anon, authenticated, service_role;

-- ============================================================================
-- 2) Columnas de estado y telemetría en tiempo.terminal. Las escribe sólo fn_terminal_latido
-- (SECURITY DEFINER, 83_*.sql). No se amplía el GRANT UPDATE de columna de service_role.
-- ============================================================================

ALTER TABLE tiempo.terminal
  ADD COLUMN reloj_desfase_seg    integer,
  ADD COLUMN terminal_alcanzable  boolean,
  ADD COLUMN version_pi           varchar(16),
  ADD COLUMN marcas_pendientes    integer,
  ADD CONSTRAINT ck_terminal_marcas_pendientes CHECK (marcas_pendientes IS NULL OR marcas_pendientes >= 0);

COMMENT ON COLUMN tiempo.terminal.reloj_desfase_seg IS
  'Segundos que adelanta (+) o atrasa (-) el reloj de la terminal respecto del servidor, calculado por '
  'fn_terminal_latido con la hora que reporta el Pi. NULL = nunca reportado.';
COMMENT ON COLUMN tiempo.terminal.terminal_alcanzable IS
  'true si el Pi ve a la terminal (ISAPI responde); false = el Pi habla pero no ve el aparato. NULL = '
  'nunca reportado.';
COMMENT ON COLUMN tiempo.terminal.version_pi IS
  'Versión del software del puente que reportó el último latido (máx. 16 caracteres).';
COMMENT ON COLUMN tiempo.terminal.marcas_pendientes IS
  'Marcas que el Pi tiene en cola sin sincronizar (último latido). Condición del procedimiento de '
  'desactivación de una terminal (SCJ-DEC-12 §6): debe ser 0 antes de apagarla.';
