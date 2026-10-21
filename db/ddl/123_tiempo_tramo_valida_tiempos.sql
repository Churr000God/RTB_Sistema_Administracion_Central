-- 123_tiempo_tramo_valida_tiempos.sql
-- MEDIO preexistente de security: coherencia de inicio, fin y minutos_trabajados de tiempo.tramo con las marcas.
-- NO MEZCLAR con el paquete 118_–122_: se aplica DESPUÉS de desplegarlo, y solo tras revisar la consulta de datos existentes (ver «ACTIVACIÓN»).
--
-- PROBLEMA. Las policies tramo_insert_revision y tramo_update_revision (64_) dejan a quien tiene dia_revision_edicion escribir por PostgREST un tramo con CUALQUIER minutos_trabajados, inicio y fin. El trigger
-- fn_tramo_valida_coherencia (86_) solo valida que las marcas sean de la persona y del día. El corte quincenal paga minutos_trabajados.
--
-- QUÉ HACE. Trigger nuevo BEFORE INSERT OR UPDATE OF (inicio, fin, minutos_trabajados, marca_apertura_id, marca_cierre_id) ON tiempo.tramo, por fila, que exige:
--   - inicio = momento EFECTIVO de la marca de apertura;
--   - si hay marca_cierre_id: fin = momento efectivo de la marca de cierre y minutos_trabajados = (fin - inicio) en minutos, con tolerancia de 0.01 min por el redondeo a numeric(6,2);
--   - si NO hay marca_cierre_id (tramo abierto): fin y minutos_trabajados son NULL.
--   Error: ERRCODE SCJ15 (la familia de 86_/87_, que backend ya traduce por HINT) con HINT 'tramo_tiempos_incoherentes' y mensaje fijo, sin valores.
--   Momento efectivo = valor de la corrección MÁS RECIENTE de la marca (creado_en desc, id desc) si existe, si no momento_dispositivo: la misma definición que fn_marca_fecha_local (86_), fn_dia_calcular_armado_tramos
--   (65_/73_), fn_correccion_valida (02_) y backend/app/batches/cierre_dia.py. Se factoriza en tiempo.fn_marca_momento_efectivo(bigint), interna (STABLE, search_path fijo, sin EXECUTE para la API).
--   Función nueva tiempo.fn_tramo_valida_tiempos(): SECURITY DEFINER con search_path fijo (lee marca y correccion, que RH con dia_revision_edicion no necesariamente puede leer), REVOKE a los cuatro roles. Cubre también
--   service_role y el dueño. Se prefiere un trigger NUEVO a reescribir fn_tramo_valida_coherencia (86_): su atajo en UPDATE solo revisa si cambian dia/marcas y su cuerpo ya es DEFINER con REVOKE; no se toca ninguna
--   función existente (sin gotcha de CREATE OR REPLACE). El nombre ordena DESPUÉS de trg_tramo_valida_coherencia, que valida primero que las marcas sean de la persona y del día.
--
-- COMPATIBILIDAD VERIFICADA leyendo el código (todos producen exactamente esta regla):
--   - cierre_dia.py::_crear_tramo: inicio = efectivo de la apertura, fin = efectivo del cierre, minutos = (cierre - apertura)/60 sin redondear (se redondea al guardar en numeric(6,2)); abierto: fin y minutos NULL.
--   - fn_dia_calcular_armado_tramos (73_) y fn_dia_revisar (64_/77_): 'nuevo' inserta (apertura, cierre, inicio, fin efectivos, minutos = epoch/60); 'cerrar_existente' actualiza marca_cierre_id, fin y minutos
--     en UN solo UPDATE con el inicio ya guardado: el trigger ve la fila nueva completa y coherente.
--   - fn_correccion_recalcula_tramo (02_): reescribe inicio/fin/minutos al corregir una marca que está en un tramo. Desde 87_ esa vía está BLOQUEADA (trg_correccion_bloquea_marca_en_tramo, SCJ15 marca_en_tramo), de modo
--     que no corre; si corriera, el AFTER INSERT de la corrección ya ve la corrección nueva como la más reciente y deja los tres campos coherentes.
--   - EL DESCUENTO DE PAUSA NO VA EN EL TRAMO: se resta en tiempo.dia.horas_totales (cierre_dia.py, parámetro descuento_pausa_no_registrada_min), nunca en tramo.minutos_trabajados. Confirmado en cierre_dia.py.
--
-- DESEMPATE DE CORRECCIONES (BAJO 1 de security). fn_marca_momento_efectivo ordena por creado_en DESC, id DESC, pero fn_correccion_valida (02_), fn_marca_fecha_local (86_), fn_dia_calcular_armado_tramos (73_), fn_dia_revisar
--   (64_), la previsualización (65_) y backend (cierre_dia.py, routers/marcas.py) ordenan solo por creado_en DESC. Con DOS correcciones de la misma marca en una sola transacción (mismo now()), el orden entre ellas no está
--   definido y podría dar un falso SCJ15. En vez de tocar ~7 funciones SQL y 2 módulos Python, se elimina la ambigüedad en su origen: índice ÚNICO uq_correccion_marca_creado_en (marca_id, creado_en) sobre tiempo.correccion.
--   Así dos correcciones de la misma marca nunca comparten creado_en: el «más reciente» es único y TODAS las definiciones coinciden, con o sin id DESC. No cambia ningún flujo real: cada corrección entra por
--   POST /api/correcciones (una por petición, una transacción) y el ledger es append-only. Si ya hubiera duplicados, CREATE UNIQUE INDEX falla y la migración aborta sin cambios (ver la segunda consulta de
--   db/consultas/validacion/tramos_tiempos_incoherentes.sql). No requiere cambios en backend. El id DESC del helper queda como defensa en profundidad.
--
-- ACTIVACIÓN (importante). Antes de aplicar, correr en SOLO LECTURA db/consultas/validacion/tramos_tiempos_incoherentes.sql, que lista los tramos existentes que violarían la regla, con el detalle por tramo.
--   El trigger NO se dispara sobre filas existentes que nadie modifique, así que un tramo histórico incoherente no bloquea nada por sí solo; pero sí impediría actualizarlo con estas columnas. Si la consulta devuelve filas,
--   decidir con el usuario qué hacer con ellas ANTES de aplicar; la sección 86 del verificador repite la misma comprobación (Esperado: 0 filas).
--
-- INVENTARIO DE RLS: sin cambios de policies ni GRANT; solo un trigger y dos funciones. Las policies de 64_ siguen siendo la autorización de quién escribe; este trigger es la validación de lo escrito.
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 123_*.sql`.
-- REVERSA (en una transacción): DROP INDEX tiempo.uq_correccion_marca_creado_en; DROP TRIGGER trg_tramo_valida_tiempos ON tiempo.tramo; DROP FUNCTION tiempo.fn_tramo_valida_tiempos(); DROP FUNCTION tiempo.fn_marca_momento_efectivo(bigint). Texto exacto en db/ensayos/ensayo_123.sql.
-- Depende de: 02_tiempo.sql, 64_*.sql, 86_*.sql, 87_*.sql, 105_*.sql
-- Justificación: SCJ-DEC-01, SCJ-PRO-12, SCJ-PRO-13

-- Desempate: ver «DESEMPATE DE CORRECCIONES» arriba.
CREATE UNIQUE INDEX uq_correccion_marca_creado_en ON tiempo.correccion (marca_id, creado_en);

CREATE FUNCTION tiempo.fn_marca_momento_efectivo(p_marca_id bigint)
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path = tiempo, pg_temp
AS $$
  SELECT COALESCE(
           (SELECT c.valor_corregido FROM tiempo.correccion c
             WHERE c.marca_id = m.id ORDER BY c.creado_en DESC, c.id DESC LIMIT 1),
           m.momento_dispositivo)
  FROM tiempo.marca m
  WHERE m.id = p_marca_id;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_momento_efectivo(bigint) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION tiempo.fn_marca_momento_efectivo(bigint) IS
  'Interna (123_). Momento EFECTIVO de una marca: el valor de la corrección más reciente (creado_en desc, id desc) si existe, si no momento_dispositivo. Misma definición que fn_marca_fecha_local, fn_dia_calcular_armado_tramos '
  'y cierre_dia.py. Sin EXECUTE para la API: la usan funciones DEFINER y triggers.';

CREATE FUNCTION tiempo.fn_tramo_valida_tiempos()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_apertura timestamptz;
  v_cierre   timestamptz;
BEGIN
  v_apertura := tiempo.fn_marca_momento_efectivo(NEW.marca_apertura_id);

  IF NEW.inicio IS DISTINCT FROM v_apertura THEN
    RAISE EXCEPTION 'Los tiempos del tramo no coinciden con sus marcas.' USING ERRCODE = 'SCJ15', HINT = 'tramo_tiempos_incoherentes';
  END IF;

  IF NEW.marca_cierre_id IS NULL THEN
    IF NEW.fin IS NOT NULL OR NEW.minutos_trabajados IS NOT NULL THEN
      RAISE EXCEPTION 'Los tiempos del tramo no coinciden con sus marcas.' USING ERRCODE = 'SCJ15', HINT = 'tramo_tiempos_incoherentes';
    END IF;
  ELSE
    v_cierre := tiempo.fn_marca_momento_efectivo(NEW.marca_cierre_id);
    IF v_cierre IS NULL OR NEW.fin IS DISTINCT FROM v_cierre
       OR NEW.minutos_trabajados IS NULL
       OR abs(NEW.minutos_trabajados - round((EXTRACT(EPOCH FROM (NEW.fin - NEW.inicio)) / 60.0)::numeric, 2)) > 0.01 THEN
      RAISE EXCEPTION 'Los tiempos del tramo no coinciden con sus marcas.' USING ERRCODE = 'SCJ15', HINT = 'tramo_tiempos_incoherentes';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_tramo_valida_tiempos() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION tiempo.fn_tramo_valida_tiempos() IS
  'Trigger BEFORE INSERT OR UPDATE OF inicio, fin, minutos_trabajados, marca_apertura_id, marca_cierre_id de tiempo.tramo (123_): inicio = momento efectivo de la marca de apertura; con cierre, fin = efectivo del cierre y '
  'minutos_trabajados = (fin - inicio) en minutos (tolerancia 0.01); sin cierre, fin y minutos NULL. SCJ15 / tramo_tiempos_incoherentes. SECURITY DEFINER con search_path fijo; sin EXECUTE para nadie. '
  'El descuento de pausa NO va en el tramo sino en tiempo.dia.horas_totales.';

CREATE TRIGGER trg_tramo_valida_tiempos
  BEFORE INSERT OR UPDATE OF inicio, fin, minutos_trabajados, marca_apertura_id, marca_cierre_id ON tiempo.tramo
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_tramo_valida_tiempos();
