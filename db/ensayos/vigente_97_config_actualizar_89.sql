CREATE FUNCTION tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_actor        uuid;
  v_cat          record;
  v_valor        integer;
  v_texto        text;
  v_hoy          date := CURRENT_DATE;
  v_activa_id    bigint;
  v_activa_desde date;
  v_activa_valor text;
  v_fila         tiempo.parametro;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_config_edicion')) THEN
    RAISE EXCEPTION 'No tienes permiso para editar la configuración de terminales'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  SELECT * INTO v_cat FROM tiempo.fn_terminal_config_catalogo() c WHERE c.clave = p_clave;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La clave % no es editable desde la configuración de terminales', p_clave
      USING ERRCODE = '22023', HINT = 'clave_no_editable';
  END IF;

  IF p_valor IS NULL OR btrim(p_valor) !~ '^[0-9]{1,4}$' THEN
    RAISE EXCEPTION 'El valor debe ser un entero entre % y %', v_cat.minimo, v_cat.maximo
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  v_valor := btrim(p_valor)::integer;
  IF v_valor < v_cat.minimo OR v_valor > v_cat.maximo THEN
    RAISE EXCEPTION 'El valor debe estar entre % y %', v_cat.minimo, v_cat.maximo
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  v_texto := v_valor::text;

  -- Las dos claves de llave se validan entre sí: un lock de transacción fijo evita el write-skew (dos ediciones simultáneas, cada una
  -- válida contra el valor VIEJO de la otra, que juntas romperían la regla). Se toma antes de leer el valor de la otra clave.
  IF p_clave IN ('terminal_traslape_llave_max_dias', 'terminal_llave_max_meses') THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('tiempo.terminal_config_llave', 0));
  END IF;

  -- Consistencia entre las dos claves de llave (petición de frontend, aceptada): el traslape máximo no puede superar la mitad de la
  -- antigüedad máxima expresada en días (meses * 30). Simétrico: se valida al editar cualquiera de las dos contra el valor VIGENTE de
  -- la otra (para subir el traslape por encima del límite actual hay que subir primero la antigüedad, y al revés al bajarla).
  IF p_clave = 'terminal_traslape_llave_max_dias'
     AND v_valor * 2 > tiempo.fn_terminal_config_valor('terminal_llave_max_meses') * 30 THEN
    RAISE EXCEPTION 'El traslape de llaves no puede superar la mitad de la antigüedad máxima de la llave'
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;
  IF p_clave = 'terminal_llave_max_meses'
     AND tiempo.fn_terminal_config_valor('terminal_traslape_llave_max_dias') * 2 > v_valor * 30 THEN
    RAISE EXCEPTION 'La antigüedad máxima de la llave no puede ser menor al doble del traslape máximo de llaves'
      USING ERRCODE = '22023', HINT = 'valor_invalido';
  END IF;

  -- tiempo.parametro.registrado_por referencia personas.usuario(auth_user_id) (60_): el autor es el auth_user_id, no la persona.
  v_actor := auth.uid();

  SELECT p.id, p.vigente_desde, p.valor INTO v_activa_id, v_activa_desde, v_activa_valor
  FROM tiempo.parametro p
  WHERE p.clave = p_clave AND p.vigente_hasta IS NULL
  FOR UPDATE;

  IF v_activa_id IS NULL THEN
    RAISE EXCEPTION 'No existe un parámetro activo con clave %', p_clave
      USING ERRCODE = 'SCJ02';
  END IF;

  IF v_activa_valor = v_texto THEN
    RETURN jsonb_build_object('resultado', 'sin_cambio', 'clave', p_clave, 'valor', v_texto,
                              'vigente_desde', v_activa_desde);
  END IF;

  IF v_activa_desde = v_hoy THEN
    -- Segundo cambio del mismo día: es la misma vigencia corregida, no una vigencia nueva.
    UPDATE tiempo.parametro SET valor = v_texto, registrado_por = v_actor
    WHERE id = v_activa_id
    RETURNING * INTO v_fila;
  ELSE
    UPDATE tiempo.parametro SET vigente_hasta = v_hoy - 1 WHERE id = v_activa_id;
    INSERT INTO tiempo.parametro (clave, valor, vigente_desde, vigente_hasta, registrado_por)
    VALUES (p_clave, v_texto, v_hoy, NULL, v_actor)
    RETURNING * INTO v_fila;
  END IF;

  RETURN jsonb_build_object('resultado', 'actualizada', 'clave', v_fila.clave, 'valor', v_fila.valor,
                            'vigente_desde', v_fila.vigente_desde);
END;
$$;
