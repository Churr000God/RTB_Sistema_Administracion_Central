-- db/consultas/validacion/tramos_tiempos_incoherentes.sql
-- SOLO LECTURA. Lista los tramos EXISTENTES que violarían la regla de 123_ (inicio/fin/minutos_trabajados incoherentes con sus marcas), con el detalle por tramo. Sin nombres ni datos de identidad (persona_id es un uuid opaco).
-- NO correr sin OK explícito del usuario. Antes de aplicar 123_: si devuelve filas, decidir con el usuario qué hacer con ellas (corregir con un script aparte, o aceptarlas). Correr con:
--   psql -X "$DATABASE_URL" -c "SET default_transaction_read_only = on" -f db/consultas/validacion/tramos_tiempos_incoherentes.sql
-- Momento efectivo de una marca = corrección más reciente (creado_en desc, id desc) si existe, si no momento_dispositivo (misma definición que fn_marca_momento_efectivo de 123_, escrita aquí en línea porque la función no existe antes de aplicarla).
WITH t AS (
  SELECT tr.id, tr.dia_id, d.persona_id, d.fecha, tr.marca_apertura_id, tr.marca_cierre_id, tr.inicio, tr.fin, tr.minutos_trabajados,
         COALESCE((SELECT c.valor_corregido FROM tiempo.correccion c WHERE c.marca_id = tr.marca_apertura_id ORDER BY c.creado_en DESC, c.id DESC LIMIT 1),
                  (SELECT m.momento_dispositivo FROM tiempo.marca m WHERE m.id = tr.marca_apertura_id)) AS ef_apertura,
         COALESCE((SELECT c.valor_corregido FROM tiempo.correccion c WHERE c.marca_id = tr.marca_cierre_id ORDER BY c.creado_en DESC, c.id DESC LIMIT 1),
                  (SELECT m.momento_dispositivo FROM tiempo.marca m WHERE m.id = tr.marca_cierre_id)) AS ef_cierre
  FROM tiempo.tramo tr
  JOIN tiempo.dia d ON d.id = tr.dia_id
)
SELECT t.id AS tramo_id, t.dia_id, t.persona_id, t.fecha,
       array_remove(ARRAY[
         CASE WHEN t.inicio IS DISTINCT FROM t.ef_apertura THEN 'inicio_distinto_del_efectivo' END,
         CASE WHEN t.marca_cierre_id IS NULL AND (t.fin IS NOT NULL OR t.minutos_trabajados IS NOT NULL) THEN 'abierto_con_fin_o_minutos' END,
         CASE WHEN t.marca_cierre_id IS NOT NULL AND t.fin IS DISTINCT FROM t.ef_cierre THEN 'fin_distinto_del_efectivo' END,
         CASE WHEN t.marca_cierre_id IS NOT NULL AND (t.minutos_trabajados IS NULL
              OR abs(t.minutos_trabajados - round((EXTRACT(EPOCH FROM (t.fin - t.inicio)) / 60.0)::numeric, 2)) > 0.01) THEN 'minutos_distintos_de_fin_menos_inicio' END
       ], NULL) AS motivos,
       t.inicio, t.ef_apertura, EXTRACT(EPOCH FROM (t.inicio - t.ef_apertura)) AS dif_inicio_seg,
       t.fin, t.ef_cierre, EXTRACT(EPOCH FROM (t.fin - t.ef_cierre)) AS dif_fin_seg,
       t.minutos_trabajados, round((EXTRACT(EPOCH FROM (t.fin - t.inicio)) / 60.0)::numeric, 2) AS minutos_esperados
FROM t
WHERE t.inicio IS DISTINCT FROM t.ef_apertura
   OR (t.marca_cierre_id IS NULL AND (t.fin IS NOT NULL OR t.minutos_trabajados IS NOT NULL))
   OR (t.marca_cierre_id IS NOT NULL AND (t.fin IS DISTINCT FROM t.ef_cierre
        OR t.minutos_trabajados IS NULL
        OR abs(t.minutos_trabajados - round((EXTRACT(EPOCH FROM (t.fin - t.inicio)) / 60.0)::numeric, 2)) > 0.01))
ORDER BY t.fecha, t.id;

-- 2) Correcciones duplicadas por (marca_id, creado_en): 123_ crea el índice único uq_correccion_marca_creado_en, que FALLARÍA si ya hubiera alguna. Esperado: 0 filas. Sin datos de identidad.
SELECT c.marca_id, c.creado_en, count(*) AS correcciones, array_agg(c.id ORDER BY c.id) AS ids
FROM tiempo.correccion c
GROUP BY c.marca_id, c.creado_en
HAVING count(*) > 1;
