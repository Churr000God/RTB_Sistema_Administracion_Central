-- 58_tiempo_marca_indice_momento_recepcion.sql
-- GET /api/marcas (pestaña "marcas en tiempo real", backend/app/routers/marcas.py) hace polling
-- frecuente: ORDER BY momento_recepcion DESC siempre presente, filtro de rango desde/hasta sobre
-- la misma columna, persona_id sólo a veces (drill-down puntual, ya cubierto por
-- ix_marca_persona_id de 30_indices_fk.sql). Sin índice propio en momento_recepcion, ese ORDER BY
-- + rango cae en seq scan + sort a medida que tiempo.marca crece (tabla de sólo-INSERT, crece sin
-- límite). Se elige columna simple, no compuesta con persona_id: el caso dominante de la pestaña
-- es el feed general sin filtrar por persona, donde un índice líder en persona_id no ayudaría al
-- ORDER BY global. DESC para calzar exacto con el sentido del ORDER BY del endpoint.
-- Aditivo puro. Depende de: 02_tiempo.sql.

CREATE INDEX IF NOT EXISTS ix_marca_momento_recepcion
  ON tiempo.marca (momento_recepcion DESC);
