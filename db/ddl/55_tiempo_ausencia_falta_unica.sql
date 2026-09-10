-- 55_tiempo_ausencia_falta_unica.sql
-- Fix de carrera real (hallazgo de security, 2026-09-06): _resolver_sin_marcas de cierre_dia.py
-- (SCJ-PRO-12) hace SELECT-then-INSERT en tiempo.ausencia sin ningún UNIQUE que lo respalde --
-- dos corridas casi simultáneas del batch (cron + botón manual solapados, o dos invocaciones del
-- cron por un reintento) pueden crear DOS filas tipo_de_ausencia='falta' para la misma persona/
-- fecha, cada una con su propia cadena de aprobación en tiempo.aprobacion_ausencia -- RH vería
-- dos "faltas" pendientes idénticas y podría resolverlas con decisiones distintas.
--
-- Índice único parcial, mismo criterio que uq_dia_persona_fecha (02_tiempo.sql): sólo aplica a
-- tipo_de_ausencia='falta' -- el placeholder que crea el batch automáticamente (SCJ-PRO-08 §V:
-- "el sistema crea la ausencia, nadie la solicita"). No restringe ausencias ya reclasificadas
-- (vacaciones/permiso_con_goce/permiso_sin_goce/incapacidad) ni rechazadas que ya cambiaron de
-- tipo -- para esas SÍ podría haber, en teoría, más de un periodo real distinto para la misma
-- persona con fechas que no se solapan (una futura solicitud manual, por ejemplo) -- el índice
-- parcial evita restringir de más un caso que no es el que causó el hallazgo.
--
-- (persona_id, fecha_inicio, fecha_fin) y no sólo (persona_id, fecha_inicio): cierre_dia opera un
-- día a la vez, así que en la práctica fecha_inicio=fecha_fin=el día que se está cerrando -- se
-- incluye fecha_fin igual por completitud del criterio pedido, sin asumir que el batch nunca vaya
-- a generar un rango de más de un día.
-- Depende de: 02_tiempo.sql

CREATE UNIQUE INDEX uq_ausencia_falta_persona_fecha
  ON tiempo.ausencia (persona_id, fecha_inicio, fecha_fin)
  WHERE tipo_de_ausencia = 'falta';
