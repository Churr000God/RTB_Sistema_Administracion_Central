-- 117_tiempo_correccion_insert_policy_marca_propia.sql
-- Corrige la policy correccion_insert_requiere_permiso de tiempo.correccion (48_*.sql): nadie salvo quien tiene excepcion_reapertura (hoy solo TI) podía registrar una corrección, aunque tuviera
-- correccion_edicion y la excepción de la marca estuviera PENDIENTE. RH recibía 403 en POST /api/correcciones.
--
-- CAUSA RAÍZ. La policy decía `NOT EXISTS (SELECT 1 FROM tiempo.excepcion e WHERE e.marca_id = marca_id AND e.estado = 'resuelto')`. Dentro de la subconsulta, el `marca_id` sin calificar se resuelve
-- a la columna del alias más cercano, es decir `e.marca_id`: la condición quedaba `e.marca_id = e.marca_id` (siempre verdadera) y el NOT EXISTS pasaba a significar «no existe NINGUNA excepción resuelta en
-- toda la tabla». Como ya hay excepciones resueltas (10 al 19-oct-2026), el NOT EXISTS es siempre falso y la policy exigía excepcion_reapertura a todo el mundo. Backend lo traduce (42501 -> 403 con
-- «No tienes permiso para esta acción.» vía traducir_error_dia_cerrado). En esta ruta la RLS es la autorización real (routers/correcciones.py usa get_caller_client para el INSERT); el gate de Python es solo un adelanto con mensaje legible. La intención documentada en 48_ y en routers/correcciones.py es AND: correccion_edicion siempre, y excepcion_reapertura ADEMÁS solo
-- al corregir una marca cuya excepción ya está resuelta.
--
-- ARREGLO. La referencia a la fila nueva se califica con el nombre de la tabla: `e.marca_id = tiempo.correccion.marca_id` (PostgreSQL la muestra como `correccion.marca_id`). Mismo nombre de policy,
-- mismo comando (INSERT), mismo rol (authenticated), mismo resto de la condición. No toca datos, funciones ni otras policies. Se revisaron las demás policies y las funciones de personas/tiempo en busca
-- de la misma autocomparación (`x.col = x.col`): no hay otra.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 117_*.sql` (o pegado en el SQL Editor). Sin DDL de tablas.
-- REVERSA (en una transacción): DROP POLICY y recrearla con el texto de 48_ (`e.marca_id = marca_id`). Volver reintroduce el defecto.
-- Inventario de RLS: 1 policy de INSERT reemplazada (tiempo.correccion), nada más.

DROP POLICY correccion_insert_requiere_permiso ON tiempo.correccion;
CREATE POLICY correccion_insert_requiere_permiso ON tiempo.correccion
  FOR INSERT
  TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('correccion_edicion')
    AND (
      NOT EXISTS (
        SELECT 1 FROM tiempo.excepcion e
        WHERE e.marca_id = tiempo.correccion.marca_id AND e.estado = 'resuelto'
      )
      OR personas.fn_caller_tiene_permiso('excepcion_reapertura')
    )
  );
