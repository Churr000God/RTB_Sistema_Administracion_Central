-- db/consultas/validacion/dias_cierre_incompleto.sql
-- SOLO LECTURA. Diagnóstico de días que el cierre de día anterior a 124_ pudo dejar A MEDIAS (el día se insertaba y luego cada tramo con llamadas sueltas). Sin nombres ni uuids: solo ids numéricos y fechas.
-- NO correr sin OK explícito del usuario. Correr con:
--   psql -X "$DATABASE_URL" -c "SET default_transaction_read_only = on" -f db/consultas/validacion/dias_cierre_incompleto.sql
-- Considera solo días nacidos del cierre (origen IS NULL) y en estado 'cerrado' o 'bloqueado': los de origen 'ausencia_autorizada' o 'automatico_confianza' nunca tienen tramos a propósito, y los 'revisado' ya pasaron por una persona.
-- Momento/fecha efectivos de la marca = los de fn_marca_fecha_local (86_): corrección más reciente si existe, si no momento_dispositivo, más desfase_local. Tramos esperados de un día con n marcas = ceil(n / 2) (par: n/2 cerrados; impar: (n-1)/2 cerrados + 1 abierto).
-- Esperado: 0 filas en cada bloque. Una fila = un día a revisar (no se corrige aquí: decidir con el usuario).

\echo '== 1) días cerrado/bloqueado SIN ningún tramo (nacidos del cierre)'
SELECT d.id AS dia_id, d.fecha, d.estado, d.horas_totales
FROM tiempo.dia d
WHERE d.origen IS NULL AND d.estado IN ('cerrado', 'bloqueado')
  AND NOT EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.dia_id = d.id)
ORDER BY d.fecha, d.id;

\echo '== 2) días con MENOS tramos de los que corresponden a sus marcas efectivas, o con marcas del día fuera de todo tramo del día'
WITH marcas_dia AS (
  SELECT d.id AS dia_id, m.id AS marca_id
  FROM tiempo.dia d
  JOIN tiempo.marca m ON m.persona_id = d.persona_id AND tiempo.fn_marca_fecha_local(m.id) = d.fecha
  WHERE d.origen IS NULL AND d.estado IN ('cerrado', 'bloqueado')
), resumen AS (
  SELECT d.id AS dia_id, d.fecha, d.estado,
         (SELECT count(*) FROM marcas_dia md WHERE md.dia_id = d.id) AS marcas,
         (SELECT count(*) FROM tiempo.tramo t WHERE t.dia_id = d.id) AS tramos,
         (SELECT count(*) FROM marcas_dia md WHERE md.dia_id = d.id
            AND NOT EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.dia_id = d.id AND md.marca_id IN (t.marca_apertura_id, t.marca_cierre_id))) AS marcas_fuera_de_tramo
  FROM tiempo.dia d
  WHERE d.origen IS NULL AND d.estado IN ('cerrado', 'bloqueado')
)
SELECT r.dia_id, r.fecha, r.estado, r.marcas, r.tramos, (r.marcas + 1) / 2 AS tramos_esperados, r.marcas_fuera_de_tramo
FROM resumen r
WHERE r.tramos < (r.marcas + 1) / 2 OR r.marcas_fuera_de_tramo > 0
ORDER BY r.fecha, r.dia_id;

\echo '== 3) días BLOQUEADOS sin su excepción de día (paridad_impar)'
SELECT d.id AS dia_id, d.fecha
FROM tiempo.dia d
WHERE d.origen IS NULL AND d.estado = 'bloqueado'
  AND NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.dia_id = d.id)
ORDER BY d.fecha, d.id;

\echo '== 4) días CERRADOS cuyas horas_totales no cuadran con Σ minutos de sus tramos (con el descuento de pausa si hay un solo tramo)'
SELECT x.dia_id, x.fecha, x.tramos, x.horas_totales, x.esperadas_horas, round(x.horas_totales - x.esperadas_horas, 2) AS diferencia_horas, x.descuento_min
FROM (
  SELECT d.id AS dia_id, d.fecha, d.horas_totales,
         (SELECT count(*) FROM tiempo.tramo t WHERE t.dia_id = d.id) AS tramos,
         COALESCE((SELECT valor::numeric FROM tiempo.parametro WHERE clave = 'descuento_pausa_no_registrada_min' AND vigente_desde <= d.fecha ORDER BY vigente_desde DESC LIMIT 1), 60) AS descuento_min,
         round((GREATEST(0,
           COALESCE((SELECT sum(t.minutos_trabajados) FROM tiempo.tramo t WHERE t.dia_id = d.id), 0)
           - CASE WHEN (SELECT count(*) FROM tiempo.tramo t WHERE t.dia_id = d.id) = 1
                  THEN COALESCE((SELECT valor::numeric FROM tiempo.parametro WHERE clave = 'descuento_pausa_no_registrada_min' AND vigente_desde <= d.fecha ORDER BY vigente_desde DESC LIMIT 1), 60)
                  ELSE 0 END
         ) / 60.0)::numeric, 2) AS esperadas_horas
  FROM tiempo.dia d
  WHERE d.origen IS NULL AND d.estado = 'cerrado'
    AND EXISTS (SELECT 1 FROM tiempo.tramo t WHERE t.dia_id = d.id)
) x
WHERE x.horas_totales IS NULL OR abs(x.horas_totales - x.esperadas_horas) > 0.01
ORDER BY x.fecha, x.dia_id;

\echo '== 5) resumen de lo analizado (para dar contexto a los conteos de arriba)'
SELECT d.estado, count(*) AS dias_del_cierre
FROM tiempo.dia d WHERE d.origen IS NULL GROUP BY d.estado ORDER BY d.estado;
