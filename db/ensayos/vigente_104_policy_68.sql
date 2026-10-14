CREATE POLICY movimiento_de_saldo_insert_manual ON tiempo.movimiento_de_saldo
  FOR INSERT TO authenticated
  WITH CHECK (
    personas.fn_caller_activo()
    AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion')
    AND tipo IN ('arrastrar', 'descontar', 'condonar')
    AND autor_id = (SELECT u.persona_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid())
  );

GRANT INSERT ON TABLE tiempo.movimiento_de_saldo TO authenticated;
