-- 87_tiempo_correccion_bloquea_marca_en_tramo.sql
-- Lleva a la base la regla que hoy sólo vive en el backend (backend/app/marca_en_tramo.py): una corrección de la hora de
-- una marca que YA es marca de apertura o de cierre de algún tramo no se puede registrar. Así un POST directo a
-- /rest/v1/correccion con el JWT del usuario no salta el 409 de POST /api/correcciones.
--
-- Por qué (ensayo real de db, BEGIN…ROLLBACK, 2026-10-07, ensayo_correccion.sql): fn_correccion_recalcula_tramo
-- (AFTER INSERT en tiempo.correccion, 02_tiempo.sql) es SECURITY INVOKER y su UPDATE de tiempo.tramo pasa por la RLS del
-- caller. Resultado medido por la API:
--   - tramo CERRADO (día cerrado o revisado): la corrección se guarda pero el UPDATE de tramo afecta 0 filas en silencio;
--     el tramo, dia.horas_totales, el corte quincenal y el banco de horas siguen con la hora vieja.
--   - tramo ABIERTO: el WITH CHECK de tramo_update_revision rechaza todo con 42501 (parece falta de permiso).
--   - como dueño o service_role (sin RLS) el UPDATE SÍ corre y pisa dia.horas_totales con la suma de tramos: pierde las
--     horas manuales de RH (7.00 -> 4.50) y el descuento de pausa de cierre_dia (3.00 -> 4.50).
-- Para nadie una corrección sobre una marca de un tramo se refleja bien, así que el trigger corre para TODOS los roles.
--
-- Qué crea (sin tablas, columnas, índices, policies ni permisos nuevos):
--   tiempo.fn_correccion_bloquea_marca_en_tramo()  trigger, SECURITY DEFINER, search_path = tiempo, personas, pg_temp
--   trg_correccion_bloquea_marca_en_tramo          BEFORE INSERT, por fila, en tiempo.correccion
--
-- Regla: si NEW.marca_id es marca_apertura_id o marca_cierre_id de CUALQUIER tramo (abierto o cerrado, de un día en
-- cualquier estado) -> ERRCODE 'SCJ15', HINT 'marca_en_tramo'. La marca que NO está en ningún tramo (día abierto o
-- bloqueado sin tramos armados) se corrige como siempre.
--
-- Por qué SECURITY DEFINER: tiene que ver todos los tramos sea cual sea la RLS del caller. Con INVOKER, quien tenga
-- correccion_edicion pero no tramo_lectura vería 0 filas y la regla se saltaría en silencio (fail-open).
--
-- Quién queda bloqueado y quién ve qué error:
--   - service_role y el dueño (sin sub en el JWT o sin JWT): siempre SCJ15 / marca_en_tramo.
--   - usuario humano (auth.uid() no nulo) con persona activa y correccion_edicion: SCJ15 / marca_en_tramo.
--   - usuario humano SIN persona activa o sin correccion_edicion, y el rol anon: el trigger NO responde y deja pasar; lo rechaza lo
--     siguiente en la cadena: trg_correccion_valida (INVOKER, sin lectura de excepcion levanta P0001) o la RLS de INSERT
--     (correccion_insert_requiere_permiso, 42501); nunca SCJ15, y el mismo error exista o no la marca / esté o no en un tramo. Se hace así a propósito para
--     no revelar a quien no puede corregir si un id de marca pertenece a un tramo (anon e authenticated tienen INSERT a
--     nivel de tabla por el GRANT ALL de 38_).
--   Orden en Postgres: los triggers BEFORE ROW corren antes de evaluar el WITH CHECK de la RLS de INSERT; por eso, para
--   quien SÍ tiene permiso, gana SCJ15 y no el 42501; para quien no, gana el error de lo que sigue (P0001 o 42501), porque el trigger lo deja pasar.
--
-- Orden de triggers (por nombre, alfabético): BEFORE INSERT trg_correccion_bloquea_marca_en_tramo corre ANTES de
-- trg_correccion_valida ('b' < 'v'), así que una marca en un tramo recibe marca_en_tramo y no el error de "sin excepción" ni
-- de orden cronológico; el AFTER INSERT trg_correccion_recalcula_tramo ya no llega a correr (no se resuelve la
-- excepción ni se toca tramo/dia). verificar_ddl.sql §45 comprueba ese orden.
--
-- Relación con el constraint trigger dia_cerrado de 86_ (un solo error por intento, nunca dos): una corrección sobre una marca
-- con excepción dia_cerrado pendiente QUE ESTÁ EN UN TRAMO falla aquí al instante con marca_en_tramo (el INSERT aborta antes
-- de que el AFTER INSERT resuelva la excepción, así que el constraint trigger diferido ni se encola). Si la marca con
-- dia_cerrado NO está en ningún tramo, esta regla no actúa y sigue valiendo 86_: SCJ15 / dia_cerrado_requiere_revision al
-- COMMIT. Dos hints distintos para dos situaciones distintas; el backend ya traduce ambos a 409.
--
-- Tramo ABIERTO: se bloquea también (decisión de db, a validar con security): por la API ya fallaba con 42501 y, para
-- dueño/service_role, el UPDATE correría y dejaría un tramo abierto con la hora de apertura nueva y dia.horas_totales
-- pisado; un único criterio ("marca en cualquier tramo") es más simple de explicar y de verificar que dos. Consecuencia de
-- producto, sin cambio respecto de hoy: la hora de una marca que ya está en un tramo abierto no se puede corregir por la
-- API; cuando haga falta, un RPC dedicado (ver propuesta B) o corregir antes de que cierre_dia arme el tramo.
--
-- CONSECUENCIA DE PRODUCTO (señalada por security): cierre_dia.py arma los tramos de todos los días con marcas. Después de que
-- corre, casi ninguna marca vuelve a ser corregible por esta vía: las pareadas quedan en tramos cerrados y las impares en un tramo
-- abierto. 'Corregir' sólo sirve (i) ANTES de armar tramos (día abierto o bloqueado sin tramos) o (ii) para marcas que no están
-- en ningún tramo. En la práctica dias_habiles_correccion_marca (ventana de corrección) y excepcion_reapertura (reabrir una
-- excepción resuelta para corregir) quedan casi sin efecto práctico hasta que exista el RPC dedicado de la opción B (corregir la marca,
-- actualizar el tramo y recalcular horas sólo en días 'cerrado', sin pisar las de RH). No es una regresión de seguridad ni de datos:
-- esas correcciones ya no se reflejaban en tramo, horas, corte ni banco (ver el ensayo de corrección de 2026-10-07).
--
-- Flujos legítimos revisados (grep en db/ddl y backend/app; ningún otro escritor de tiempo.correccion que POST /api/correcciones):
--   (a) corregir ANTES de armar tramos, con el día bloqueado: la marca no está en ningún tramo -> sigue funcionando; después
--       fn_dia_revisar/fn_dia_calcular_armado_tramos arman el tramo con el valor efectivo (73_*.sql). Una corrección previa
--       sobre una marca que luego entra a un tramo queda como estaba; la SIGUIENTE corrección de esa marca es SCJ15.
--   (b) cierre_dia.py solo lee tiempo.correccion (batches/cierre_dia.py:135) para usar la hora efectiva; no inserta.
--   (c) las 7 correcciones existentes no se tocan: el trigger es BEFORE INSERT, no revalida filas viejas.
--   (d) fn_correccion_valida y fn_correccion_recalcula_tramo no se modifican; este trigger corre antes y no duplica la
--       excepción ni su resolución.
--   (e) POST /api/correcciones: el backend ya devuelve 409 antes de insertar (marca_en_tramo.py); este trigger es el respaldo
--       para el POST directo a PostgREST. Backend: SCJ15 + hint 'marca_en_tramo' -> 409 con el MISMO mensaje fijo que ya usa para
--       en_tramo/en_tramo_cerrado; el texto de la base nunca va a la respuesta.
--
-- Hint nuevo 'marca_en_tramo' (verificado libre por grep en db/, backend/app y frontend/src: sólo aparece como nombre del
-- módulo Python backend/app/marca_en_tramo.py y en routers; ningún HINT con ese valor). SCJ15 ya existe en 86_.
--
-- Residual aceptado: una carrera entre este trigger y fn_dia_revisar/cierre_dia armando el tramo de la misma marca en otra
-- transacción puede dejar una corrección registrada justo antes de que el tramo se arme con el valor efectivo (si el tramo
-- se arma después, ya usa la corrección: es el flujo (a), correcto). La otra dirección (tramo armado, corrección insertada en
-- paralelo sin verlo) exigiría bloquear tramos en cada corrección; no se hace (el efecto es el de hoy: se registra sin reflejarse).
--
-- Inventario de RLS/privilegios de este archivo:
--   tiempo.fn_correccion_bloquea_marca_en_tramo()  SECURITY DEFINER, SET search_path = tiempo, personas, pg_temp.
--        REVOKE EXECUTE FROM PUBLIC, anon, authenticated, service_role (sólo la invoca el trigger, como dueño).
--   tiempo.correccion  sin cambios de RLS ni de privilegios (la policy correccion_insert_requiere_permiso sigue siendo la
--        autorización; este trigger es una regla de integridad adicional).
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP TRIGGER trg_correccion_bloquea_marca_en_tramo ON tiempo.correccion;
--   DROP FUNCTION tiempo.fn_correccion_bloquea_marca_en_tramo();
--   -- Sólo quita la regla; no hay datos que revertir. El backend (409) sigue protegiendo POST /api/correcciones.
--
-- Depende de: 02_tiempo.sql (tiempo.correccion, tiempo.tramo, fn_correccion_valida/recalcula_tramo), 48_tiempo_rls_correccion_excepcion.sql
--   (policy de INSERT), 86_tiempo_excepcion_protege_dia_cerrado_v2.sql (SCJ15 y su convención de hints)
-- Justificación: SCJ-PRO-10 (corrección de marca), SCJ-DEC-03 (la marca no se edita; la corrección es una fila aparte)

CREATE FUNCTION tiempo.fn_correccion_bloquea_marca_en_tramo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
BEGIN
  -- Quien no puede corregir no debe enterarse de si una marca está en un tramo: lo deja pasar y la RLS responde 42501.
  IF auth.role() = 'anon' THEN
    RETURN NEW;
  END IF;
  IF auth.uid() IS NOT NULL
     AND NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('correccion_edicion')) THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM tiempo.tramo t
    WHERE t.marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id
  ) THEN
    RAISE EXCEPTION 'La marca % ya forma parte de un tramo: su hora no se corrige por esta vía', NEW.marca_id
      USING ERRCODE = 'SCJ15', HINT = 'marca_en_tramo';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_correccion_bloquea_marca_en_tramo() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_correccion_bloquea_marca_en_tramo
  BEFORE INSERT ON tiempo.correccion
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_correccion_bloquea_marca_en_tramo();

COMMENT ON FUNCTION tiempo.fn_correccion_bloquea_marca_en_tramo() IS
  '87_. BEFORE INSERT en tiempo.correccion: rechaza con SCJ15 / marca_en_tramo la corrección de una marca que es apertura o '
  'cierre de cualquier tramo (el recálculo de fn_correccion_recalcula_tramo no se refleja para nadie: 0 filas por RLS para el '
  'caller, o pisa las horas de RH para dueño/service_role). Corre para todos los roles; el rol anon y el usuario sin persona '
  'activa o sin correccion_edicion no reciben respuesta (los rechaza la RLS con 42501). SECURITY DEFINER, '
  'search_path = tiempo, personas, pg_temp; sin EXECUTE para la API.';
