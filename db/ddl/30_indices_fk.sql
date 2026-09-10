-- 30_indices_fk.sql
-- Índices explícitos sobre columnas FK que hoy sólo tienen el índice implícito de la PK
-- referenciada (útil para el lado "uno" del join, inútil para buscar por el lado "muchos" —
-- ej. "traer todas las marcas de esta persona" barre tiempo.marca completa sin este índice).
-- Aditivo puro: no modifica DDL existente, sólo agrega. Convención de nombre: ix_<tabla>_<columnas>
-- (CONVENCIONES.md §... tabla de prefijos).
--
-- Se excluyen las columnas FK que ya quedan cubiertas por una columna líder de un índice
-- existente (UNIQUE simple o compuesto), porque Postgres puede usar ese índice para buscar por
-- esa sola columna sin necesitar uno adicional:
--   - tiempo.dia.persona_id            -> cubierta por uq_dia_persona_fecha (persona_id, fecha)
--   - tiempo.tramo.marca_apertura_id   -> cubierta por uq_tramo_marca_apertura (UNIQUE)
--   - tiempo.tramo.marca_cierre_id     -> cubierta por uq_tramo_marca_cierre (UNIQUE)
--   - tiempo.clasificacion_de_tiempo.tramo_id -> cubierta por uq_clasificacion_de_tiempo_tramo (UNIQUE)
--   - tiempo.banco_de_horas.persona_id -> cubierta por uq_banco_de_horas_persona (UNIQUE)
--   - personas.expediente.persona_id   -> cubierta por uq_expediente_persona (UNIQUE)
--   - personas.usuario.persona_id      -> cubierta por uq_usuario_persona (UNIQUE)
--   - personas.puesto_permiso.puesto_id -> cubierta por uq_puesto_permiso_puesto_codigo (puesto_id, codigo)
-- personas.asignacion.persona_id/puesto_id NO se excluyen pese a existir
-- ux_asignacion_vigente_persona_puesto: ese índice es parcial (WHERE vigente_hasta IS NULL) y no
-- sirve para consultas sobre historial completo (filas cerradas).
-- personas.*.codigo (FK a personas.permiso) se excluye a propósito: catálogo de 16 filas, un
-- índice ahí no aporta selectividad real.
--
-- Depende de: 02_tiempo.sql, 05_personas_estructura.sql, 12_personas_departamento.sql,
--   14_personas_puesto.sql, 17_personas_asignacion.sql, 23_personas_bitacora_puesto_permiso.sql

-- ============================================================================
-- tiempo.*
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_jornada_asignada_persona_id
  ON tiempo.jornada_asignada (persona_id);

CREATE INDEX IF NOT EXISTS ix_patron_semanal_jornada_asignada_id
  ON tiempo.patron_semanal (jornada_asignada_id);

CREATE INDEX IF NOT EXISTS ix_marca_persona_id
  ON tiempo.marca (persona_id);

CREATE INDEX IF NOT EXISTS ix_tramo_dia_id
  ON tiempo.tramo (dia_id);

CREATE INDEX IF NOT EXISTS ix_movimiento_de_saldo_banco_de_horas_id
  ON tiempo.movimiento_de_saldo (banco_de_horas_id);

CREATE INDEX IF NOT EXISTS ix_movimiento_de_saldo_clasificacion_de_tiempo_id
  ON tiempo.movimiento_de_saldo (clasificacion_de_tiempo_id);

CREATE INDEX IF NOT EXISTS ix_movimiento_de_saldo_autor_id
  ON tiempo.movimiento_de_saldo (autor_id);

CREATE INDEX IF NOT EXISTS ix_correccion_marca_id
  ON tiempo.correccion (marca_id);

CREATE INDEX IF NOT EXISTS ix_correccion_autor_id
  ON tiempo.correccion (autor_id);

CREATE INDEX IF NOT EXISTS ix_ausencia_persona_id
  ON tiempo.ausencia (persona_id);

CREATE INDEX IF NOT EXISTS ix_excepcion_marca_id
  ON tiempo.excepcion (marca_id);

CREATE INDEX IF NOT EXISTS ix_excepcion_dia_id
  ON tiempo.excepcion (dia_id);

-- ============================================================================
-- personas.*
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_bitacora_movimiento_persona_persona_id
  ON personas.bitacora_movimiento_persona (persona_id);

CREATE INDEX IF NOT EXISTS ix_bitacora_movimiento_persona_registrado_por
  ON personas.bitacora_movimiento_persona (registrado_por);

CREATE INDEX IF NOT EXISTS ix_departamento_area_id
  ON personas.departamento (area_id);

CREATE INDEX IF NOT EXISTS ix_puesto_departamento_id
  ON personas.puesto (departamento_id);

-- reporta_a_id no estaba en la lista original del pedido, pero es la misma clase de columna
-- (FK auto-referenciada sin índice propio) y es justo la que recorre la resolución de jerarquía
-- de permisos (backend/app/permisos.py, "el jefe hereda lo del subordinado") — se agrega por
-- consistencia, a confirmar si se prefiere dejar fuera de este corte.
CREATE INDEX IF NOT EXISTS ix_puesto_reporta_a_id
  ON personas.puesto (reporta_a_id);

CREATE INDEX IF NOT EXISTS ix_asignacion_persona_id
  ON personas.asignacion (persona_id);

CREATE INDEX IF NOT EXISTS ix_asignacion_puesto_id
  ON personas.asignacion (puesto_id);

CREATE INDEX IF NOT EXISTS ix_bitacora_movimiento_puesto_permiso_puesto_id
  ON personas.bitacora_movimiento_puesto_permiso (puesto_id);

CREATE INDEX IF NOT EXISTS ix_bitacora_movimiento_puesto_permiso_registrado_por
  ON personas.bitacora_movimiento_puesto_permiso (registrado_por);
