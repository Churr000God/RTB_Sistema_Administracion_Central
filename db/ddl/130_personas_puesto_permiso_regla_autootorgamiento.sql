-- 130_personas_puesto_permiso_regla_autootorgamiento.sql
-- Cierre del auto-otorgamiento de permisos por puesto en la base. Cambio sobre el esquema congelado (SCJ-ACT-03 V1.3 §V, segundo cambio por ese procedimiento),
-- aprobado por Diego el 11-nov-2026: «sí cambia el esquema para arreglar el error de autootorgamiento».
--
-- PROBLEMA (hallazgos de security, 11-nov-2026). Dos caminos, los dos con solo puesto_permiso_edicion y PostgREST directo (sin pasar por FastAPI):
--   (1) Por la bitácora. backend/app/routers/permisos.py (otorgar_permiso) rechaza con 422 que alguien otorgue un permiso a su propio puesto (no heredable) o a su
--       puesto o cualquier descendiente por reporta_a_id (heredable: terminaría heredándolo). La base no lo replicaba: la policy
--       bitacora_puesto_permiso_insert_requiere_permiso (31_/32_) solo exige persona activa + puesto_permiso_edicion, y trg_puesto_permiso_sincroniza (24_)
--       convierte cualquier fila 'otorgado' en un otorgamiento real. Además la policy no ata registrado_por al caller: se podía registrar a nombre de otro.
--   (2) CRÍTICO, sin bitácora. personas.puesto_permiso tenía GRANT ALL a authenticated (22_) y policies de INSERT/UPDATE/DELETE que solo exigían
--       puesto_permiso_edicion (31_/32_). Existían porque fn_puesto_permiso_sincroniza era INVOKER y escribía como el caller. Un POST /rest/v1/puesto_permiso
--       {puesto_id: propio, codigo: X, activo: true} o un PATCH activo=true sobre una fila revocada otorgaba sin pasar por la bitácora: ni regla ni auditoría.
-- El rodeo por la API (UUID en MAYÚSCULAS) se cerró en 832682d; esto es el cierre de fondo.
--
-- QUÉ HACE (todo en una transacción):
--   A. fn_puesto_permiso_sincroniza() pasa a SECURITY DEFINER con search_path fijo, con ALTER FUNCTION (nunca CREATE OR REPLACE: el cuerpo de 24_ no cambia).
--      Su EXECUTE ya está revocado a PUBLIC/anon/authenticated/service_role desde 105_; un trigger dispara sin EXECUTE del caller.
--      Como DEFINER escribe puesto_permiso como su dueño (postgres, el mismo dueño de la tabla y sin FORCE ROW LEVEL SECURITY), así que ya no necesita privilegio
--      ni policy de escritura del caller. Lección de CLAUDE.md aplicada: al pasar un trigger de INVOKER a DEFINER se revisaron sus caminos de escritura. El único
--      camino que lo dispara es el INSERT en la bitácora, que sigue protegido por su policy (32_: persona activa, puesto_permiso_edicion, nunca 'revocado' sobre
--      el puesto administrador) y ahora por el trigger de la parte C. No se abre ningún camino nuevo: se cierra uno.
--   B. personas.puesto_permiso queda de solo lectura para la API: REVOKE INSERT, UPDATE, DELETE a anon, authenticated y service_role (TRUNCATE/REFERENCES/TRIGGER
--      ya revocados en 102_; a anon todo desde 102_), y DROP de las tres policies de escritura (puesto_permiso_insert/update/delete_requiere_permiso). Queda la
--      policy de SELECT de 109_. El único escritor es el trigger de la bitácora. Nada del backend ni de scripts/ escribe puesto_permiso (todas las llamadas son
--      .select); las semillas (26_, 27_, 33_-36_, 45_, 62_, 69_, 120_) escriben en la BITÁCORA como dueño, y el trigger DEFINER sigue sincronizando.
--      La protección del puesto administrador en puesto_permiso (UPDATE activo=false y DELETE prohibidos, 32_ §4) se vuelve innecesaria: nadie de la API escribe
--      ahí. La que importa sigue en la policy de la bitácora (32_ §3).
--   C. Trigger BEFORE INSERT FOR EACH ROW en la bitácora (trg_bitacora_puesto_permiso_regla_autootorgamiento), solo cuando auth.uid() no es NULL (sin identidad
--      de usuario —psql/SQL Editor, migraciones, semillas, service_role, scripts/bootstrap_usuario_base.py— no aplica):
--      C1. Autoría (otorgado y revocado): registrado_por debe ser auth.uid(). Mismo criterio que 92_ en la bitácora de personas. El backend ya manda
--          registrado_por = caller.auth_user_id en otorgar y revocar.
--      C2. Solo 'otorgado', réplica EXACTA de la regla de Python. Caller = persona de personas.usuario con auth_user_id = auth.uid(); sus puestos vigentes =
--          personas.asignacion con vigente_hasta IS NULL (sin mirar vigente_desde ni persona.estado, igual que Python; la policy ya exige persona activa).
--          heredable: rechaza NEW.puesto_id si es un vigente del caller o un descendiente por reporta_a_id (unión sobre todos los vigentes). HINT
--          'autootorgamiento_por_herencia' (también sobre el propio puesto: Python cae en esa rama). No heredable: rechaza solo un vigente del caller. HINT
--          'autootorgamiento_directo'. Código inexistente: no decide (la FK rechaza la fila con 23503).
--      Por qué trigger y no policy: una policy fallida da 42501 sin HINT; no se agrega ningún OR a la policy de INSERT (gotcha de 31_), cuyo texto no cambia; es
--      BEFORE (un constraint trigger solo puede ser AFTER) y aborta antes de que la fila exista: la bitácora inmutable no se toca.
--      SECURITY DEFINER con search_path fijo, dueño postgres, sin EXECUTE para ningún rol de la API (función de trigger, sección 70(a); no entra en la lista
--      cerrada 70(d)). No reutiliza fn_caller_puestos_en_rama() (109_) a propósito: esa devuelve vacío si el caller no está activo, y Python no mira el estado.
--      Orden: los BEFORE ROW corren antes del WITH CHECK de RLS; quien no tiene puesto_permiso_edicion puede recibir SCJ29 en vez de 42501. No filtra nada que
--      no vea ya (su propio puesto y el organigrama son legibles para toda persona activa).
--
-- PUESTO ADMINISTRADOR (es_administrador_generico). C solo RESTRINGE; A y B no revocan nada ni tocan asignacion. Revocarle un permiso sigue imposible por la API
-- (policy de la bitácora, 32_). Consecuencia ya existente en Python: quien ocupa ese puesto tampoco se otorga por la app un permiso nuevo del catálogo; se
-- siembra por migración, como hasta hoy.
--
-- ERRORES QUE RECIBE EL CALLER (literales fijos). Lista exacta para backend (registro_seguro.HINTS_CONOCIDOS y errores.py):
--   SCJ29 / 'autootorgamiento_directo'       No puedes otorgarte este permiso a ti mismo.
--   SCJ29 / 'autootorgamiento_por_herencia'  No puedes otorgar este permiso: terminarías heredándolo por el rodeo del organigrama.
--   SCJ29 / 'autor_distinto_del_caller'      El movimiento debe registrarse a nombre de quien lo hace.
-- Por PostgREST: HTTP 400 con code SCJ29 y hint. Escritura directa sobre personas.puesto_permiso: 42501 (permission denied for table puesto_permiso), HTTP 403.
--
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f db/ddl/130_personas_puesto_permiso_regla_autootorgamiento.sql`. A cualquier hora. Sin
-- precondición de datos (no revisa otorgamientos pasados).
-- REVERSA (en una transacción; texto exacto de 31_/32_ para las policies):
--   DROP TRIGGER trg_bitacora_puesto_permiso_regla_autootorgamiento ON personas.bitacora_movimiento_puesto_permiso;
--   DROP FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento();
--   ALTER FUNCTION personas.fn_puesto_permiso_sincroniza() SECURITY INVOKER RESET search_path;   (y su COMMENT con el texto de 24_, sin la última frase)
--   GRANT INSERT, UPDATE, DELETE ON personas.puesto_permiso TO authenticated, service_role;
--   CREATE POLICY puesto_permiso_insert_requiere_permiso ON personas.puesto_permiso
--     FOR INSERT WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'));
--   CREATE POLICY puesto_permiso_update_requiere_permiso ON personas.puesto_permiso
--     FOR UPDATE
--     USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'))
--     WITH CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
--       AND NOT (activo = false AND EXISTS (SELECT 1 FROM personas.puesto pu WHERE pu.id = puesto_id AND pu.es_administrador_generico)));
--   CREATE POLICY puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso
--     FOR DELETE USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')
--       AND NOT EXISTS (SELECT 1 FROM personas.puesto pu WHERE pu.id = puesto_id AND pu.es_administrador_generico));
-- (anon no recupera nada: 102_ le quitó todo y así se queda.) Copia ejecutable: db/ensayos/vigente_130_reversa.sql, probada en ensayo_130.sql (fase R).
-- Verificador: sección 93. Inventario de RLS: 3 policies menos (76 -> 73), ninguna nueva ni cambiada.
-- Depende de: 14_, 17_, 21_, 22_, 23_, 24_, 31_, 32_, 102_, 105_, 109_
-- Justificación: SCJ-PRO-05 §V, SCJ-ACT-03 V1.3

-- ============================================================================
-- A. El trigger que sincroniza puesto_permiso pasa a DEFINER (cuerpo de 24_ sin cambios)
-- ============================================================================

ALTER FUNCTION personas.fn_puesto_permiso_sincroniza() SECURITY DEFINER SET search_path = personas, pg_temp;

COMMENT ON FUNCTION personas.fn_puesto_permiso_sincroniza() IS
  'Implementa SCJ-PRO-05 G8 ("crea o reactiva la fila"): ON CONFLICT (puesto_id, codigo) DO UPDATE '
  'resuelve en una sola sentencia el caso de otorgar un permiso ya revocado antes, apoyado en '
  'uq_puesto_permiso_puesto_codigo (22_personas_puesto_permiso.sql). puesto_permiso.activo es '
  '[CALCULADO] — nunca se actualiza con UPDATE directo, sólo insertando en la bitácora. '
  'Desde 130_ es SECURITY DEFINER: es el único escritor de puesto_permiso (la API ya no tiene privilegio ni policy de escritura ahí).';

-- ============================================================================
-- B. personas.puesto_permiso de solo lectura para la API
-- ============================================================================

REVOKE INSERT, UPDATE, DELETE ON personas.puesto_permiso FROM anon, authenticated, service_role;

DROP POLICY puesto_permiso_insert_requiere_permiso ON personas.puesto_permiso;
DROP POLICY puesto_permiso_update_requiere_permiso ON personas.puesto_permiso;
DROP POLICY puesto_permiso_delete_requiere_permiso ON personas.puesto_permiso;

-- ============================================================================
-- C. Autoría y regla anti auto-otorgamiento en la bitácora
-- ============================================================================

CREATE FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_heredable boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.registrado_por IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'El movimiento debe registrarse a nombre de quien lo hace.'
      USING ERRCODE = 'SCJ29', HINT = 'autor_distinto_del_caller';
  END IF;

  IF NEW.tipo_movimiento <> 'otorgado' THEN
    RETURN NEW;
  END IF;

  SELECT pe.heredable INTO v_heredable
  FROM personas.permiso pe
  WHERE pe.codigo = NEW.codigo;

  IF NOT FOUND THEN
    RETURN NEW;  -- la FK rechaza la fila (23503)
  END IF;

  IF v_heredable THEN
    IF EXISTS (
      WITH RECURSIVE rama AS (
        SELECT a.puesto_id AS id
        FROM personas.usuario u
        JOIN personas.asignacion a ON a.persona_id = u.persona_id
        WHERE u.auth_user_id = v_uid
          AND a.vigente_hasta IS NULL
        UNION
        SELECT pu.id
        FROM personas.puesto pu
        JOIN rama r ON pu.reporta_a_id = r.id
      )
      SELECT 1 FROM rama WHERE rama.id = NEW.puesto_id
    ) THEN
      RAISE EXCEPTION 'No puedes otorgar este permiso: terminarías heredándolo por el rodeo del organigrama.'
        USING ERRCODE = 'SCJ29', HINT = 'autootorgamiento_por_herencia';
    END IF;
  ELSE
    IF EXISTS (
      SELECT 1
      FROM personas.usuario u
      JOIN personas.asignacion a ON a.persona_id = u.persona_id
      WHERE u.auth_user_id = v_uid
        AND a.vigente_hasta IS NULL
        AND a.puesto_id = NEW.puesto_id
    ) THEN
      RAISE EXCEPTION 'No puedes otorgarte este permiso a ti mismo.'
        USING ERRCODE = 'SCJ29', HINT = 'autootorgamiento_directo';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento() IS
  '130_. BEFORE INSERT de bitacora_movimiento_puesto_permiso, solo con auth.uid(): registrado_por debe ser el caller (SCJ29 autor_distinto_del_caller); y en otorgado, réplica exacta de la regla anti auto-otorgamiento de routers/permisos.py: heredable => rechaza el puesto vigente del caller o cualquier descendiente (SCJ29 autootorgamiento_por_herencia); no heredable => rechaza el puesto vigente del caller (SCJ29 autootorgamiento_directo). Sin auth.uid() (migraciones, semillas, service_role) no aplica. DEFINER con search_path fijo; sin EXECUTE para ningún rol de la API.';

CREATE TRIGGER trg_bitacora_puesto_permiso_regla_autootorgamiento
  BEFORE INSERT ON personas.bitacora_movimiento_puesto_permiso
  FOR EACH ROW
  EXECUTE FUNCTION personas.fn_bitacora_puesto_permiso_regla_autootorgamiento();
