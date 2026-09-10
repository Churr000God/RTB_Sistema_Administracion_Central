-- 07_personas_storage.sql
-- Bucket privado para el archivo del expediente (documento_ref). Solo el backend (service_role)
-- sube/descarga; no hay acceso directo del frontend al bucket.
-- Depende de: 06_personas_rls.sql
-- Justificación: NOTAS_campos_extra_mockups.md (diseno_paginas/personas/) · SCJ-PRO-01

INSERT INTO storage.buckets (id, name, public)
VALUES ('expedientes', 'expedientes', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY solo_service_role_expedientes ON storage.objects
  FOR ALL
  USING (bucket_id = 'expedientes' AND auth.role() = 'service_role')
  WITH CHECK (bucket_id = 'expedientes' AND auth.role() = 'service_role');
