-- 61_tiempo_marca_ventana_captura_manual.sql
-- Endurece marca_insert_captura_manual (46_tiempo_rls_marca_excepcion_humano.sql:34-41) para la
-- hora editable de captura manual (momento_dispositivo elegido por el usuario, no forzado a
-- now() por el backend -- ver plan "hora del dispositivo y motivo de revisión", Fase 1).
--
-- routers/marcas.py usa get_caller_client (anon key + JWT), no service_role -- la policy RLS es
-- la autorización real, no un respaldo (gotcha CLAUDE.md sobre RLS que sólo valida "activo"). Sin
-- este WITH CHECK, cualquier cuenta con captura_manual_edicion podía pegarle a PostgREST directo
-- e insertar momento_dispositivo arbitrario -- retroactivo sin límite o futuro -- bypaseando
-- FastAPI por completo.
--
-- Este es sólo el techo duro (backstop de bypass directo). La ventana fina en días hábiles
-- (tiempo.parametro.dias_habiles_correccion_marca + tiempo.dia_festivo) vive en el backend --
-- replicarla aquí duplicaría lógica de calendario. Mismo reparto que la protección del puesto
-- administrador: RLS pone el límite duro, backend da el mensaje legible.
--
-- No es CHECK de tabla porque now() no es inmutable -- sólo válido dentro de una policy.
--
-- Además exige estado_reloj = 'sincronizado' en captura_manual (sugerencia de security en la
-- revisión de esta policy): sin esto, quien bypasea FastAPI podía insertar 'deriva' o
-- 'sin_sincronizar' -- el backend siempre fuerza 'sincronizado' para este origen, RLS lo respalda.
--
-- Ningún ALTER TABLE, ninguna columna nueva. Sólo policy + comentarios.
-- Depende de: 02_tiempo.sql, 46_tiempo_rls_marca_excepcion_humano.sql

-- ============================================================================
-- Policy: agrega ventana de momento_dispositivo al WITH CHECK existente
-- ============================================================================

DROP POLICY marca_insert_captura_manual ON tiempo.marca;

CREATE POLICY marca_insert_captura_manual ON tiempo.marca
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('captura_manual_edicion')
    AND origen = 'captura_manual'
    AND momento_dispositivo <= now()
    AND momento_dispositivo >= now() - interval '90 days'
    AND estado_reloj = 'sincronizado'
  );

-- ============================================================================
-- Comentarios
-- ============================================================================

COMMENT ON COLUMN tiempo.marca.momento_dispositivo IS
  'Instante real del evento según el reloj del origen (terminal o, desde la hora editable de '
  'captura manual, el instante que declara quien captura). Campo autoritativo para el cálculo de '
  'jornada -- SCJ-CDT-01 §VII.3 fija que el orden de los eventos lo determina éste, no el de '
  'llegada. En captura_manual el backend valida que no sea futuro y que caiga dentro de la '
  'ventana de días hábiles de tiempo.parametro.dias_habiles_correccion_marca; esta tabla añade '
  'sólo un techo duro (90 días, no futuro) como respaldo ante un INSERT directo por PostgREST que '
  'se salte esa validación.';

COMMENT ON COLUMN tiempo.marca.estado_reloj IS
  'Estado del reloj del origen en el momento exacto de esta marca, reportado por el propio '
  'dispositivo -- no se deriva aquí. Captura retroactiva (momento_dispositivo distinto de ahora) '
  'no es deriva de reloj: el reloj del origen está bien, sólo el evento es viejo -- '
  'estado_reloj sigue sincronizado en captura_manual.';
