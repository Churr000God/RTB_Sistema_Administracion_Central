-- 60_tiempo_parametro_vigencia_y_autor.sql
-- Habilita la tercera pantalla del módulo Parámetros ("Parámetros del sistema"): hasta hoy
-- tiempo.parametro sólo tenía vigente_desde (una fila activa por clave, sin cierre) y ningún
-- endpoint la editaba -- cambiar un valor exigía entrar al SQL Editor de Supabase a mano.
--
-- ADD COLUMN vigente_hasta date: mismo patrón de vigencia versionada que tope_legal (59_*.sql) --
-- NULL = vigencia activa, borde inclusivo (vigente_hasta = nueva.vigente_desde - 1). Sin backfill:
-- las 8 filas sembradas por 03_parametros_ejemplo.sql quedan con vigente_hasta IS NULL (todas
-- activas, claves distintas entre sí -- no chocan con uq_parametro_clave_vigente, que no se toca).
--
-- ADD COLUMN registrado_por uuid: autor humano del cambio, para mostrarlo en el historial (patrón
-- ya usado por otras tablas de auditoría del módulo Tiempo). NULL en las 8 filas sembradas por DDL
-- -- no tienen autor humano.
--
-- REVOKE UPDATE, DELETE ... FROM anon, authenticated: la tabla pasa a ser histórica, igual que
-- tope_legal -- se escribe sólo vía el RPC de abajo (SECURITY INVOKER, invocado con
-- get_service_client). No se revoca a service_role: el RPC necesita UPDATE (cerrar la vigencia
-- activa, o corregir el valor de la vigencia de hoy) e INSERT (abrir la vigencia nueva). Recordar
-- el gotcha de ALTER DEFAULT PRIVILEGES (08_personas_permisos.sql): el GRANT ALL heredado es
-- aditivo, así que el REVOKE explícito es obligatorio, no redundante.
--
-- Sin policies RLS nuevas: la tabla sigue deny-all (41_tiempo_rls_deny_default.sql) -- el router
-- usa get_service_client para toda lectura y escritura, igual que tope_legal.py/dias_festivos.py.
--
-- RPC tiempo.fn_parametro_actualizar_valor: SECURITY INVOKER (default, mismo razonamiento que
-- fn_tope_legal_crear_vigencia -- sólo lo invoca el backend con service_role, nunca un humano
-- autenticado directo). A diferencia de tope_legal, acá siempre hay una vigencia activa por clave
-- y el flujo siempre quiere cerrarla -- no hay flag de confirmación (SCJ-DEC-05 no aplica, la
-- confirmación de "vas a cerrar la vigencia vigente" se hace en el frontend antes de enviar, no en
-- el RPC). Regla especial: dos cambios de la misma clave el mismo día son la misma vigencia
-- corregida (UPDATE in-place de valor/registrado_por), no una vigencia nueva -- con vigente_desde
-- siempre en hoy, una segunda fila el mismo día chocaría contra uq_parametro_clave_vigente y
-- además cerraría la vigencia de hoy con vigente_hasta = hoy - 1 (rango invertido).
--
-- Señal de "no existe una vigencia activa con esa clave": RAISE EXCEPTION con ERRCODE 'SCJ02' --
-- código nuevo, distinto de 'SCJ01' (que ya significa "conflicto de vigencia sin confirmar" en
-- fn_jornada_asignar_renovar y fn_tope_legal_crear_vigencia). Backend mapea SCJ02 a 404, no 409:
-- esta pantalla no crea claves nuevas, sólo edita valores de claves ya existentes -- una clave
-- inexistente (o pasada por error) es "recurso no encontrado", no un conflicto de vigencia.
--
-- GRANT sólo a service_role, REVOKE de PUBLIC en el mismo archivo desde el arranque -- mismo
-- criterio que fn_tope_legal_crear_vigencia.
-- Depende de: 02_tiempo.sql, 41_tiempo_rls_deny_default.sql
-- Justificación: pantalla "Parámetros del sistema", módulo Parámetros de Tiempo

ALTER TABLE tiempo.parametro
  ADD COLUMN vigente_hasta  date,
  ADD COLUMN registrado_por uuid REFERENCES personas.usuario(auth_user_id);

COMMENT ON COLUMN tiempo.parametro.vigente_hasta IS
  'NULL = vigencia activa. Borde inclusivo: al abrir una vigencia nueva, la anterior se cierra con '
  'vigente_hasta = nueva.vigente_desde - 1 (mismo criterio que tiempo.tope_legal, divergente del '
  'borde semiabierto exclusivo de SCJ-DEC-04 -- ver nota de desalineación documentada ahí). Las 8 '
  'filas sembradas por 03_parametros_ejemplo.sql quedan en NULL (sin backfill, todas activas).';

COMMENT ON COLUMN tiempo.parametro.registrado_por IS
  'Autor humano del cambio (auth_user_id de personas.usuario), resuelto por el backend desde el '
  'caller autenticado. NULL en las filas sembradas por DDL -- no tienen autor humano.';

REVOKE UPDATE, DELETE ON tiempo.parametro FROM anon, authenticated;

CREATE FUNCTION tiempo.fn_parametro_actualizar_valor(
  p_clave           varchar,
  p_valor           text,
  p_registrado_por  uuid
) RETURNS tiempo.parametro AS $$
DECLARE
  v_hoy          date := CURRENT_DATE;
  v_activa_id    bigint;
  v_activa_desde date;
  v_fila         tiempo.parametro;
BEGIN
  -- La clave debe existir ya: esta pantalla edita valores, no crea parámetros.
  SELECT id, vigente_desde INTO v_activa_id, v_activa_desde
  FROM tiempo.parametro
  WHERE clave = p_clave AND vigente_hasta IS NULL;

  IF v_activa_id IS NULL THEN
    RAISE EXCEPTION 'No existe un parámetro activo con clave %', p_clave
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_activa_desde = v_hoy THEN
    -- Segundo cambio del mismo día: es la misma vigencia corregida, no una vigencia nueva.
    UPDATE tiempo.parametro
    SET valor = p_valor, registrado_por = p_registrado_por
    WHERE id = v_activa_id
    RETURNING * INTO v_fila;
    RETURN v_fila;
  END IF;

  UPDATE tiempo.parametro
  SET vigente_hasta = v_hoy - 1
  WHERE id = v_activa_id;

  INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
  VALUES (p_clave, p_valor, v_hoy, NULL, p_registrado_por)
  RETURNING * INTO v_fila;

  RETURN v_fila;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid) IS
  'RPC transaccional de "actualizar valor de parámetro": si no hay vigencia activa con esa clave, '
  'señaliza con RAISE EXCEPTION ... USING ERRCODE = ''SCJ02'' (backend lo mapea a 404). Si la '
  'vigencia activa es de hoy, corrige valor/registrado_por in-place (mismo día = misma vigencia). '
  'Si no, cierra la vigencia activa (vigente_hasta = hoy - 1) e inserta la vigencia nueva desde '
  'hoy, en una sola transacción.';

GRANT EXECUTE ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid)
  TO service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_parametro_actualizar_valor(varchar, text, uuid)
  FROM PUBLIC;
