-- 06_personas_rls.sql
-- Candado de acceso de SCJ-PRO-02: bloquea cualquier operación si persona.estado != 'activo',
-- sin importar la vía de entrada (app, script, API) — vive en Postgres, no en el backend.
-- Depende de: 05_personas_estructura.sql
-- Justificación: SCJ-PRO-02 §III/§V

CREATE FUNCTION personas.fn_caller_activo()
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1
    FROM personas.usuario u
    JOIN personas.persona p ON p.id = u.persona_id
    WHERE u.auth_user_id = auth.uid()
      AND p.estado = 'activo'
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = personas, pg_temp;

COMMENT ON FUNCTION personas.fn_caller_activo() IS
  'true si el usuario autenticado (auth.uid()) tiene una persona activa detrás. SECURITY DEFINER '
  'porque el propio caller normalmente no tendría permiso de leer personas.usuario/persona hasta '
  'pasar este chequeo — es la única función que corre con privilegio elevado en este esquema.';

ALTER TABLE personas.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.expediente ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.bitacora_movimiento_persona ENABLE ROW LEVEL SECURITY;

CREATE POLICY solo_caller_activo ON personas.persona
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.expediente
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.usuario
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());

CREATE POLICY solo_caller_activo ON personas.bitacora_movimiento_persona
  FOR ALL USING (personas.fn_caller_activo()) WITH CHECK (personas.fn_caller_activo());
