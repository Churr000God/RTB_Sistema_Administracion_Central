-- 85_tiempo_terminal_baja_por_caducidad.sql
-- Cuarta pieza de SCJ-DEC-12: la CADUCIDAD de las altas que se quedan en 'esperando_huella' (§12.7).
-- Un alta en 'esperando_huella' es un usuario que ya existe en el aparato pero cuya huella nadie ha
-- enrolado: consume un employee_no y, mientras siga abierta, es un usuario sin huella en la terminal.
-- Para que no quede abierta indefinidamente, un job del scheduler del backend llama a
-- fn_terminal_baja_por_caducidad(), que emite baja_solicitada de las altas vencidas; el Pi la ve como
-- pendiente_baja, borra el usuario y reporta baja_confirmada. Para volver a enrolar a la persona, RH la
-- asigna de nuevo (otro employee_no).
--
-- Va en un archivo APARTE (y no en 83_*.sql) porque 82_/83_/84_ ya están validados (ensayo 230/230 y OK de
-- security) y se aplican tal cual; ningún archivo ya validado se edita (SCJ-DEC-12 Q17).
--
-- Qué crea: una función, sin tablas, columnas, índices, policies, secuencias ni triggers nuevos.
--   tiempo.fn_terminal_baja_por_caducidad(p_horas integer DEFAULT 24) RETURNS integer
--
-- Reglas (SCJ-DEC-12 §12.7):
--   - El plazo se mide con el movimiento 'usuario_creado' de la BITÁCORA (bitacora_movimiento_terminal_usuario.
--     creado_en), NO con terminal_usuario.actualizado_en: éste también lo mueve un movimiento 'error', que no
--     debe aplazar la caducidad. Si hubiera más de un usuario_creado de la misma alta (no puede: la transición
--     sólo es válida desde pendiente_alta), se toma el más reciente.
--   - Sólo altas en 'esperando_huella'. NO toca pendiente_alta (dependen de que el Pi esté vivo y las cubre
--     la anomalía "altas atascadas" del tablero) ni activo ni las que ya están en pendiente_baja/baja.
--   - Autor: el registrado_por del movimiento 'asignado' de esa alta (quien asignó a la persona). No hay
--     usuario "sistema" ni origen nuevo (SCJ-DEC-12 Q4): el movimiento es origen='web' como cualquier
--     baja_solicitada. Si el autor no se puede derivar (no hay movimiento 'asignado' o su autor es NULL) NO se
--     emite esa baja y se deja un WARNING (el backend lo reemite como ERROR).
--   - Detalle del movimiento: 'baja automática: sin huella tras N horas' (N = p_horas).
--   - Idempotente: SCJ11/SCJ12 de una alta (carrera con otro job o con un movimiento del Pi, o ya hecha) se
--     ignoran. Segunda corrida seguida: devuelve 0.
--   - Devuelve cuántas bajas emitió.
--
-- Valor inicial ajustable (SCJ-DEC-12 Q16): p_horas = 24 por defecto. Piso mínimo c_horas_minimas = 4 (revisión de
-- security: defensa en profundidad): un argumento descuidado (NULL, 0, negativo, o un 1-3 tecleado por error)
-- no debe dar de baja todas las altas en espera; el piso deja margen para que una persona llegue a la terminal. Entrada fuera de
-- rango: ERRCODE 22023, HINT 'horas_invalidas' (mismo estilo que fn_marca_rechazada_purgar, 84_*.sql).
--
-- Concurrencia (revisión de security, OBLIGATORIO): el FOR ... IN SELECT del bucle toma su snapshot al abrir el
-- cursor. Si el Pi confirma una huella (huella_capturada: la alta pasa a 'activo') entre ese SELECT y el INSERT,
-- el trigger de la bitácora SÍ permitiría baja_solicitada desde 'activo' y se daría de baja a alguien que
-- acaba de enrolar. Por eso, dentro del bucle y antes del INSERT, cada alta se vuelve a leer FOR UPDATE
-- exigiendo estado = 'esperando_huella': si ya cambió, se salta (CONTINUE). El FOR UPDATE se mantiene hasta el
-- fin de la transacción, de modo que un huella_capturada concurrente espera a esta función y entonces ve una
-- alta en pendiente_baja (SCJ11 para el Pi). El trigger vuelve a tomar FOR UPDATE de la misma fila en la
-- misma transacción, sin problema. Dos jobs simultáneos tampoco pueden emitir dos bajas de la misma alta:
-- el segundo recibe SCJ11 (ya está en pendiente_baja) y lo ignora. La carrera real no se simula en un solo
-- script de ensayo: queda como residual anotado.
--
-- Tope por corrida (revisión de security): c_tope_bajas = 50. Al emitir 50 bajas en una misma llamada se deja
-- el resto para la siguiente corrida del job (RAISE WARNING 'tope de bajas por corrida alcanzado', sin datos):
-- una terminal o una tabla comprometida no puede dar de baja a todos de un golpe.
--
-- Nota de auditoría: la baja queda atribuida a quien ASIGNÓ a la persona, aunque la dispare un job; el detalle
-- 'baja automática: sin huella tras N horas' debe mostrarse junto al autor en el tablero y en el historial
-- para que no parezca una decisión humana de esa persona.
--
-- Inventario de RLS/privilegios de este archivo:
--   fn_terminal_baja_por_caducidad(integer)  SECURITY DEFINER, SET search_path = tiempo, personas, pg_temp.
--                                            REVOKE EXECUTE FROM PUBLIC, anon, authenticated; GRANT EXECUTE sólo a
--                                            service_role (job del scheduler). Escribe en la bitácora como dueño,
--                                            igual que fn_terminal_baja_por_persona_inactiva (83_*.sql); la RLS de
--                                            la bitácora no se evalúa para el dueño, y el trigger BEFORE INSERT
--                                            valida la transición. Sin tablas ni grants de tabla nuevos.
--
-- Rollback de referencia (NO ejecutar sin revisar):
--   DROP FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer);
--   -- El GRANT/REVOKE EXECUTE cae con la función. No hay nada más que revertir. Las bajas ya emitidas son filas
--   -- inmutables de la bitácora y no se borran.
--
-- Depende de: 81_tiempo_bitacora_movimiento_terminal_usuario.sql (bitácora y trigger de transiciones),
--   83_tiempo_terminal_rpc.sql (el patrón de fn_terminal_baja_por_persona_inactiva y la versión vigente del
--   trigger con FOR SHARE)
-- Justificación: SCJ-DEC-12 §12.7 (caducidad de altas en esperando_huella)

CREATE FUNCTION tiempo.fn_terminal_baja_por_caducidad(p_horas integer DEFAULT 24)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_horas_minimas  constant integer := 4;   -- piso: nunca caducar con menos de 4 horas (ver cabecera)
  c_tope_bajas     constant integer := 50;  -- máximo de bajas por llamada; el resto queda para la siguiente corrida
  v_n              integer := 0;
  rec              record;
BEGIN
  IF p_horas IS NULL OR p_horas < c_horas_minimas THEN
    RAISE EXCEPTION 'las horas de caducidad deben ser al menos %', c_horas_minimas
      USING ERRCODE = '22023', HINT = 'horas_invalidas';
  END IF;

  FOR rec IN
    SELECT tu.id, tu.terminal_id, tu.persona_id, tu.employee_no,
           (SELECT a.registrado_por
              FROM tiempo.bitacora_movimiento_terminal_usuario a
             WHERE a.terminal_usuario_id = tu.id AND a.tipo_movimiento = 'asignado'
             ORDER BY a.id
             LIMIT 1) AS autor
    FROM tiempo.terminal_usuario tu
    WHERE tu.estado = 'esperando_huella'
      AND NOT EXISTS (
        SELECT 1 FROM tiempo.bitacora_movimiento_terminal_usuario h
        WHERE h.terminal_usuario_id = tu.id AND h.tipo_movimiento = 'huella_capturada')
      AND (SELECT max(c.creado_en)
             FROM tiempo.bitacora_movimiento_terminal_usuario c
            WHERE c.terminal_usuario_id = tu.id AND c.tipo_movimiento = 'usuario_creado')
          < clock_timestamp() - make_interval(hours => p_horas)
    ORDER BY tu.id
  LOOP
    IF v_n >= c_tope_bajas THEN
      RAISE WARNING 'tope de bajas por corrida alcanzado';
      EXIT;
    END IF;

    IF rec.autor IS NULL THEN
      RAISE WARNING 'fn_terminal_baja_por_caducidad: sin autor derivable para la alta %', rec.id;
      CONTINUE;
    END IF;

    -- Carrera con huella_capturada (ver cabecera): se re-lee la alta FOR UPDATE exigiendo que siga en
    -- esperando_huella; si el Pi ya la pasó a activo, no se le da de baja.
    PERFORM 1 FROM tiempo.terminal_usuario t WHERE t.id = rec.id AND t.estado = 'esperando_huella' FOR UPDATE;
    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    BEGIN
      INSERT INTO tiempo.bitacora_movimiento_terminal_usuario
        (terminal_usuario_id, terminal_id, persona_id, employee_no,
         tipo_movimiento, detalle, origen, registrado_por)
      VALUES
        (rec.id, rec.terminal_id, rec.persona_id, rec.employee_no,
         'baja_solicitada', 'baja automática: sin huella tras ' || p_horas || ' horas', 'web', rec.autor);
      v_n := v_n + 1;
    EXCEPTION WHEN SQLSTATE 'SCJ11' OR SQLSTATE 'SCJ12' THEN
      NULL;  -- carrera con otro job o con el Pi, o ya hecha: idempotente
    END;
  END LOOP;

  RETURN v_n;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) TO service_role;

COMMENT ON FUNCTION tiempo.fn_terminal_baja_por_caducidad(integer) IS
  'SCJ-DEC-12 §12.7. Emite baja_solicitada (origen web, autor = el del movimiento asignado de la alta, detalle '
  '"baja automática: sin huella tras N horas") de las altas en esperando_huella cuyo movimiento usuario_creado '
  'en la bitácora tiene más de p_horas horas (por defecto 24, mínimo 4; 22023/horas_invalidas). Máximo 50 bajas por llamada. No toca '
  'pendiente_alta ni activo; re-lee cada alta FOR UPDATE antes de emitir. Sin autor derivable no emite (WARNING). Idempotente (ignora SCJ11/SCJ12). Devuelve '
  'cuántas bajas emitió. SECURITY DEFINER, search_path fijo, EXECUTE sólo service_role (job del scheduler).';
