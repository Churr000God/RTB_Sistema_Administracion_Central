-- 80_tiempo_terminal_usuario.sql
-- Modelo de datos del servidor para la terminal biométrica Hikvision DS-K1A8503EF-B (auditada el
-- 2026-10-05; reemplaza al lector R503Pro). Este archivo crea las dos tablas "de estado" del
-- mapeo employeeNo <-> persona: tiempo.terminal (el aparato) y tiempo.terminal_usuario (la
-- persona enrolada en ese aparato). La bitácora inmutable que es la FUENTE DE VERDAD de
-- terminal_usuario vive en 81_tiempo_bitacora_movimiento_terminal_usuario.sql -- a propósito en un
-- archivo aparte, porque su trigger SECURITY DEFINER es lo único que escribe terminal_usuario.
--
-- Decisiones ya tomadas (plan aprobado por el usuario, 2026-10-05):
-- - El mapeo vive en el servidor; el Pi sólo lo cachea. La captura de huella es presencial.
-- - El Pi accede por endpoints del backend, no por RLS directa: terminal_checador sigue con sólo
--   INSERT en tiempo.marca (37_tiempo_rls_terminal.sql) y NO se toca acá.
-- - tiempo.marca.terminal_id NO es FK a tiempo.terminal.terminal_id a propósito: esa columna
--   también guarda puntos de captura manual ('rh-captura-01'). marca no se modifica.
-- - PK bigint GENERATED ALWAYS AS IDENTITY, convención de tiempo (02_tiempo.sql), no uuid.
--
-- Endurecimiento de grants (lección de 28_*.sql / 41_*.sql / 47_*.sql): el ALTER DEFAULT
-- PRIVILEGES de 38_tiempo_permisos.sql da GRANT ALL (incluido UPDATE, DELETE y TRUNCATE) a anon,
-- authenticated y service_role sobre toda tabla y secuencia nueva, y GRANT es aditivo. Por eso
-- cada objeto nuevo hace REVOKE ALL a los tres roles y luego GRANT explícito de lo estrictamente
-- necesario -- en el mismo archivo, no en un fix posterior. TRUNCATE entra en el REVOKE ALL:
-- RLS y los triggers por fila no lo frenan.
--
-- Inventario de RLS de este archivo (regla de CLAUDE.md "todo GRANT nuevo trae inventario"):
--   tiempo.terminal          RLS on, 1 policy (SELECT lectura-o-edición). Escribe service_role.
--   tiempo.terminal_usuario  RLS on, 1 policy (SELECT lectura-o-edición). Sin policies de
--                            escritura: la escribe sólo el trigger de 81_*.sql (SECURITY DEFINER).
--
-- Texto libre (error_detalle, y detalle en 81_*.sql): CHECK de 500 caracteres como tope duro. El
-- BACKEND debe sanear y truncar antes de insertar, y nunca meter cuerpos crudos de respuestas
-- ISAPI ni headers (pueden traer credenciales Digest, seriales o datos de otros usuarios).
--
-- Permisos nuevos (heredabilidad confirmada por el usuario el 2026-10-05: lectura=true,
-- edicion=false, o sea sólo quien tiene el puesto con el permiso, sin herencia jerárquica; vive
-- en un solo lugar, el INSERT INTO personas.permiso de la sección 4; molde de
-- 62_tiempo_dia_revision.sql:47-62):
--   terminal_usuario_lectura  ver el mapeo terminal <-> persona y su estado de enrolamiento.
--   terminal_usuario_edicion  asignar una persona a una terminal y solicitar su baja (INSERT en
--                             la bitácora, 81_*.sql). Es permiso de ACCIÓN, no de CRUD de tabla.
-- Se otorgan vía bitacora_movimiento_puesto_permiso a "Responsable de Recursos Humanos",
-- "Gerente General" y "Gerente o Encargado de TI". Este último es el puesto administrador
-- (es_administrador_generico): no recibe permisos nuevos solo, se incluye explícito.
--
-- Rollback de referencia (NO ejecutar sin revisar; 81_*.sql se revierte primero):
--   DROP TABLE tiempo.terminal_usuario;
--   DROP TABLE tiempo.terminal;
--   DROP SEQUENCE tiempo.seq_terminal_employee_no;
--   -- Los dos permisos y sus filas en bitacora_movimiento_puesto_permiso NO se pueden borrar: la
--   -- bitácora es inmutable incluso para postgres. Quedan inertes (nada los consume); la única
--   -- limpieza real es DROP SCHEMA personas CASCADE + reaplicar el DDL (ver CLAUDE.md).
--
-- Depende de: 01_persona_stub.sql, 02_tiempo.sql, 21_personas_permiso.sql,
--   23_personas_bitacora_puesto_permiso.sql, 24_puesto_permiso_trigger.sql,
--   31_personas_rls_permiso_especifico.sql, 38_tiempo_permisos.sql
-- Justificación: SCJ-DEC-11 (mapeo terminal <-> persona en el servidor, bitácora como fuente de
--   verdad)

-- ============================================================================
-- 1) Secuencia del employeeNo -- primera secuencia explícita del proyecto. El employeeNo es el
-- identificador que la terminal guarda por usuario (rango válido ISAPI hasta 8 dígitos). Una sola
-- secuencia global, nunca se reutiliza ni se reinicia: un employeeNo dado de baja no vuelve a
-- asignarse, así los eventos AcsEvent históricos jamás apuntan a otra persona. NO CYCLE: si se
-- agota, nextval falla en vez de reutilizar números.
-- ============================================================================

CREATE SEQUENCE tiempo.seq_terminal_employee_no
  AS integer
  MINVALUE 1
  MAXVALUE 99999999
  START WITH 1
  NO CYCLE;

COMMENT ON SEQUENCE tiempo.seq_terminal_employee_no IS
  'Fuente de terminal_usuario.employee_no. Global (no por terminal), sin ciclo, sin reutilización. '
  'Sólo la usa fn_bitacora_terminal_usuario_aplica (81_*.sql, SECURITY DEFINER, corre como dueño) '
  '-- ningún rol de la API tiene privilegio sobre ella.';

REVOKE ALL ON SEQUENCE tiempo.seq_terminal_employee_no FROM anon, authenticated, service_role;

-- ============================================================================
-- 2) tiempo.terminal -- el aparato físico. Una sola hoy (serie F33791980, se da de alta con un
-- INSERT puntual, no como seed del DDL), pero el modelo soporta varias.
-- ============================================================================

CREATE TABLE tiempo.terminal (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_id         varchar(32) NOT NULL,
  nombre              varchar(100) NOT NULL,
  modelo              varchar(50),
  activa              boolean NOT NULL DEFAULT true,
  ultimo_contacto_en  timestamptz,
  creado_en           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_terminal_terminal_id UNIQUE (terminal_id)
);

COMMENT ON TABLE tiempo.terminal IS
  'Terminal biométrica física (SCJ-DEC-11). Una fila por aparato. La escribe sólo service_role '
  '(alta puntual y ultimo_contacto_en); sin DELETE para nadie, una terminal fuera de servicio se '
  'marca activa=false.';
COMMENT ON COLUMN tiempo.terminal.terminal_id IS
  'Serie del aparato; MISMO valor que tiempo.marca.terminal_id cuando la marca viene de esta '
  'terminal. Sin FK desde marca (esa columna también guarda puntos de captura manual).';
COMMENT ON COLUMN tiempo.terminal.nombre IS 'Nombre legible para la UI (ej. "Entrada principal").';
COMMENT ON COLUMN tiempo.terminal.modelo IS 'Modelo del aparato (ej. DS-K1A8503EF-B). Opcional.';
COMMENT ON COLUMN tiempo.terminal.activa IS 'false = fuera de servicio. No se borra nunca.';
COMMENT ON COLUMN tiempo.terminal.ultimo_contacto_en IS
  'Última vez que el Pi (puente) llamó al backend para esta terminal. Lo actualiza el backend con '
  'service_role; NULL si nunca ha contactado.';

ALTER TABLE tiempo.terminal ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.terminal FROM anon, authenticated, service_role;
GRANT SELECT ON tiempo.terminal TO authenticated;
-- service_role: sin DELETE y con UPDATE sólo de las columnas mutables (nunca id, terminal_id ni
-- creado_en: terminal_id es la serie que coincide con tiempo.marca.terminal_id).
GRANT SELECT, INSERT ON tiempo.terminal TO service_role;
GRANT UPDATE (ultimo_contacto_en, activa, nombre, modelo) ON tiempo.terminal TO service_role;

CREATE POLICY terminal_select_lectura ON tiempo.terminal
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo()
    AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
         OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))
  );

REVOKE ALL ON SEQUENCE tiempo.terminal_id_seq FROM anon, authenticated, service_role;

-- ============================================================================
-- 3) tiempo.terminal_usuario -- tabla viva [CALCULADO]: una fila por alta de una persona en una
-- terminal, con el estado de su enrolamiento. NADIE la escribe directo: la deriva el trigger
-- fn_bitacora_terminal_usuario_aplica de 81_*.sql a partir de cada fila de la bitácora (mismo
-- patrón que personas.puesto_permiso <- bitacora_movimiento_puesto_permiso, 24_*.sql). El
-- trigger es SECURITY DEFINER, por eso esta tabla no necesita ninguna policy de escritura y no se
-- repite el problema del OR en policies de UPDATE (gotcha de 31_*.sql / 70_*.sql).
-- ============================================================================

CREATE TABLE tiempo.terminal_usuario (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_id         bigint NOT NULL REFERENCES tiempo.terminal (id),
  persona_id          uuid NOT NULL REFERENCES tiempo.persona (id),
  employee_no         integer NOT NULL,
  estado              varchar(20) NOT NULL,
  huellas_capturadas  smallint NOT NULL DEFAULT 0,
  error_detalle       text,
  creado_en           timestamptz NOT NULL DEFAULT now(),
  actualizado_en      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_terminal_usuario_employee_no CHECK (employee_no BETWEEN 1 AND 99999999),
  CONSTRAINT ck_terminal_usuario_estado CHECK (
    estado IN ('pendiente_alta', 'esperando_huella', 'activo', 'pendiente_baja', 'baja')
  ),
  CONSTRAINT ck_terminal_usuario_huellas CHECK (huellas_capturadas BETWEEN 0 AND 10),
  CONSTRAINT uq_terminal_usuario_employee_no UNIQUE (terminal_id, employee_no),
  CONSTRAINT ck_terminal_usuario_error_detalle_len CHECK (
    error_detalle IS NULL OR char_length(error_detalle) <= 500
  )
);

-- Una persona sólo puede tener UN alta vigente por terminal; las bajas históricas no cuentan.
CREATE UNIQUE INDEX uq_terminal_usuario_persona_vigente
  ON tiempo.terminal_usuario (terminal_id, persona_id)
  WHERE estado <> 'baja';

-- (terminal_id ya está cubierto por el prefijo de los dos únicos de arriba)
CREATE INDEX ix_terminal_usuario_persona_id ON tiempo.terminal_usuario (persona_id);

COMMENT ON TABLE tiempo.terminal_usuario IS
  '[CALCULADO] Persona enrolada en una terminal y estado de su enrolamiento (SCJ-DEC-11). La '
  'deriva sólo trg_bitacora_terminal_usuario_aplica (81_*.sql) desde '
  'bitacora_movimiento_terminal_usuario; ningún rol de la API tiene INSERT/UPDATE/DELETE.';
COMMENT ON COLUMN tiempo.terminal_usuario.terminal_id IS 'FK a tiempo.terminal(id) (surrogate, no la serie).';
COMMENT ON COLUMN tiempo.terminal_usuario.persona_id IS
  'Persona vía frontera SCJ-FRO-01 (tiempo.persona). Ningún dato de identidad vive acá.';
COMMENT ON COLUMN tiempo.terminal_usuario.employee_no IS
  'employeeNo en la terminal. Sale de seq_terminal_employee_no, entre 1 y 99999999, nunca se '
  'reutiliza. Único por terminal.';
COMMENT ON COLUMN tiempo.terminal_usuario.estado IS
  'pendiente_alta (asignado en el servidor, falta crearlo en el aparato) -> esperando_huella '
  '(usuario creado, sin huella) -> activo (>=1 huella) -> pendiente_baja -> baja. Transiciones '
  'validadas por el trigger de 81_*.sql.';
COMMENT ON COLUMN tiempo.terminal_usuario.huellas_capturadas IS
  'Huellas registradas en el aparato (0-10, tope del DS-K1A8503EF-B). Lo fija huella_capturada.';
COMMENT ON COLUMN tiempo.terminal_usuario.error_detalle IS
  'Último error reportado por el Pi. Se limpia con el siguiente movimiento válido distinto de '
  'error. Sin datos sensibles.';
COMMENT ON COLUMN tiempo.terminal_usuario.actualizado_en IS 'Lo fija el trigger en cada movimiento.';

ALTER TABLE tiempo.terminal_usuario ENABLE ROW LEVEL SECURITY;

-- Sólo SELECT. Ni authenticated ni service_role escriben: el único escritor es el trigger
-- SECURITY DEFINER de 81_*.sql, que corre como dueño de la tabla.
REVOKE ALL ON tiempo.terminal_usuario FROM anon, authenticated, service_role;
GRANT SELECT ON tiempo.terminal_usuario TO authenticated, service_role;

CREATE POLICY terminal_usuario_select_lectura ON tiempo.terminal_usuario
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo()
    AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura')
         OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'))
  );

REVOKE ALL ON SEQUENCE tiempo.terminal_usuario_id_seq FROM anon, authenticated, service_role;

-- ============================================================================
-- 4) Permisos nuevos y su otorgamiento -- molde exacto de 62_tiempo_dia_revision.sql:47-62. Se
-- otorgan insertando en la bitácora (24_*.sql deriva puesto_permiso), nunca directo en
-- puesto_permiso. El NOT EXISTS hace el bloque idempotente ante un re-aplicado.
-- ============================================================================

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('terminal_usuario_lectura', true),
  ('terminal_usuario_edicion', false)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, c.codigo, 'otorgado'
FROM personas.puesto p
CROSS JOIN (VALUES ('terminal_usuario_lectura'), ('terminal_usuario_edicion')) AS c (codigo)
WHERE p.nombre_puesto IN (
    'Responsable de Recursos Humanos',
    'Gerente General',
    'Gerente o Encargado de TI'
  )
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = c.codigo AND pp.activo
  );
