-- 86_tiempo_excepcion_protege_dia_cerrado_v2.sql
-- Cierre real del hallazgo de seguridad que 78_tiempo_excepcion_protege_dia_cerrado.sql sólo cubrió a
-- medias (revisión de security, 2026-10-07). 78_ (aplicado el 2026-10-07 sin ensayo) protege únicamente el
-- UPDATE suelto de una excepción de motivo EXACTO 'dia_cerrado' y dos evasiones lo rodean:
--   ALTO-1  dos UPDATE sucesivos: primero cambiar motivo_revision (el WHEN del constraint trigger de 78_ compara
--           OLD.motivo_revision = 'dia_cerrado' y deja de dispararse), después resolver.
--   ALTO-2  un tramo falso: tramo_insert_revision (64_) permite insertar un tramo con cualquier marca y 78_ sólo
--           pedía "existe un tramo con esa marca en un día 'revisado'", sin exigir que sea del mismo día/persona
--           ni que la revisión haya ocurrido ahora.
-- Decisiones de producto (usuario, 2026-10-07): (1) marcas tardías sobre un día YA revisado se resuelven con un
-- RPC de descarte con un permiso de ACCIÓN nuevo no heredable; (2) 'Corregir' sobre una marca con excepción
-- dia_cerrado debe BLOQUEARSE: una corrección no puede cerrar en silencio una marca de día cerrado, se resuelve
-- revisando el día. 78_ NO se edita (ya está aplicado); este archivo lo reemplaza en lo necesario.
--
-- Qué hace, en orden:
--   1) fn_marca_fecha_local(bigint): fecha local EFECTIVA de una marca (corrección más reciente si existe, si no
--      momento_dispositivo; más desfase_local). Es el mismo criterio que usa fn_dia_calcular_armado_tramos
--      (73_*.sql) y el batch de cierre de día, para que todas las comprobaciones coincidan con quien arma los tramos.
--   2) trg_excepcion_protege_columnas (BEFORE UPDATE): marca_id, dia_id y creado_en son inmutables; motivo_revision
--      sólo puede cambiar AGREGANDO un sufijo ' — ...' junto con pendiente -> resuelto (el que añaden
--      fn_ausencia_resuelve_excepcion, 66_*.sql, y el RPC de descarte de abajo). Cierra ALTO-1 de raíz: el prefijo
--      'dia_cerrado' ya no se puede reemplazar.
--   3) Constraint trigger recreado y fn_excepcion_protege_dia_cerrado reescrita: el WHEN pasa a
--      OLD.motivo_revision LIKE 'dia\_cerrado%' (el prefijo, no la igualdad: una excepción ya resuelta con sufijo y
--      reabierta sigue protegida), y la función exige lo que promete: o bien (a) un tramo que contenga la marca,
--      del MISMO día y persona de la marca (fecha local efectiva), con ese día en 'revisado' y revisado_en = now()
--      -- sólo una revisión hecha DENTRO de esta transacción la satisface, no una de ayer --, o bien (b) un descarte
--      registrado en esta misma transacción por el RPC. Error SCJ15, hint 'dia_cerrado_requiere_revision'.
--   4) trg_tramo_valida_coherencia (BEFORE INSERT OR UPDATE en tiempo.tramo): las marcas de apertura/cierre deben ser
--      de la misma persona que el día y tener fecha local efectiva = fecha del día. Cierra el origen de ALTO-2.
--   5) Descarte legítimo: tabla de auditoría tiempo.excepcion_descarte (sólo la escribe el RPC), permiso de acción
--      excepcion_dia_cerrado_descarte (heredable=false) y fn_excepcion_dia_cerrado_descartar(bigint, text).
--   6) La ruta de fn_correccion_recalcula_tramo (02_tiempo.sql) que resuelve excepciones sin pasar por revisión
--      ahora FALLA con SCJ15 por el constraint trigger de (3); ver "Mensajes para el backend" abajo.
--
-- ERRCODE nuevo 'SCJ15' (verificado libre por grep en db/, backend/app y frontend/src; el último usado era SCJ14). Un
-- solo código con HINT estable para que el backend distinga el caso sin leer el texto:
--   dia_cerrado_requiere_revision  constraint trigger (3), incluye el caso de una corrección sobre una marca de día cerrado
--   excepcion_columna_inmutable    trigger (2): marca_id, dia_id o creado_en cambiaron
--   excepcion_motivo_inmutable     trigger (2): motivo_revision cambió fuera de "agregar sufijo al resolver"
--   tramo_incoherente              trigger (4): marca de otra persona o de otro día
--   excepcion_no_descartable       RPC: no es una excepción dia_cerrado de marca, o ya está resuelta por otra vía
--   dia_no_revisado                RPC: el día de la marca no está 'revisado' (se resuelve revisando el día)
-- y los estándar 42501 (hint 'sin_permiso', RPC sin permiso/inactivo) y 22023 (hint 'motivo_invalido').
--
-- Mensajes para el backend (mapeo sugerido, el texto de la base nunca va a la respuesta):
--   SCJ15/dia_cerrado_requiere_revision  -> 409 "Esta marca es de un día ya cerrado: no se corrige ni se resuelve a mano. Revisa el
--      día (o, si el día ya está revisado, descarta la marca tardía)." Aparece al hacer COMMIT (el constraint trigger es
--      DEFERRABLE INITIALLY DEFERRED, porque fn_dia_revisar resuelve la excepción ANTES de marcar el día revisado), así que
--      el error llega en la respuesta de la petición completa: POST /api/correcciones sobre una marca con excepción
--      dia_cerrado pendiente falla con él. El botón 'Corregir' debe ocultarse/bloquearse en la UI para esas marcas; esto es
--      el respaldo de base.
--   SCJ15/excepcion_columna_inmutable | excepcion_motivo_inmutable -> 403/409 genérico "La excepción no se puede alterar".
--   SCJ15/tramo_incoherente -> 422 "La marca no corresponde a la persona o al día del tramo".
--   SCJ15/dia_no_revisado -> 409 "El día todavía no está revisado: revísalo en vez de descartar la marca".
--   SCJ15/excepcion_no_descartable -> 409.  42501/sin_permiso -> 403.  22023/motivo_invalido -> 422.
--
-- Por qué el tramo se protege con un TRIGGER y no con el patrón de 51_ (decisión de db): la alternativa era hacer
-- SECURITY DEFINER a fn_dia_revisar y revocar INSERT/UPDATE directo de authenticated sobre tiempo.tramo (quitar las
-- policies tramo_insert_revision/tramo_update_revision de 64_). Es más invasiva: redefine un RPC aplicado y distinto
-- modelo de privilegios (63_/64_), y deja sin cubrir a service_role (el batch cierre_dia inserta tramos directo).
-- El trigger valida los datos, no quién los escribe, así que cubre a ambos con un cambio local y no toca ningún grant.
-- Cuando un tramo es coherente pero falso (marca de la misma persona y del mismo día que no corresponde a una
-- revisión real), igual no sirve para resolver una excepción dia_cerrado: eso exige una revisión del día en la MISMA
-- transacción (3), y una petición HTTP/PostgREST es una transacción, no varias.
--
-- Por qué el descarte es SECURITY DEFINER con EXECUTE para authenticated (y no sólo service_role): la autorización
-- debe seguir viviendo en la base cuando el backend se equivoque (lección de 31_*.sql), y el RPC necesita (a) saber
-- QUIÉN descarta -- se deriva de auth.uid(), que no existe con service_role --, y (b) escribir en una tabla de
-- auditoría a la que la API no tiene INSERT. El gate (fn_caller_activo y excepcion_dia_cerrado_descarte) está DENTRO
-- de la función. service_role no necesita ejecutarlo y no puede (no tiene identidad de usuario). No se usa el patrón
-- de 62_/68_ (SECURITY INVOKER + policy) porque esas escrituras caen en tablas sin policy de escritura.
--
-- Por qué una tabla de auditoría y no un GUC de transacción: el constraint trigger debe poder distinguir "resuelta
-- por el RPC" de "resuelta por alguien que imita al RPC". Un set_config(..., true) lo puede fijar cualquier sesión que
-- ejecute SQL (hoy sólo el dueño y quien tenga SQL directo); una fila en excepcion_descarte sólo la puede escribir
-- el RPC (sin INSERT para la API, RLS sin policy de escritura) y además deja el registro durable de quién, cuándo y
-- por qué. La condición es "existe un descarte de ESTA excepción creado en ESTA transacción" (creado_en = now()).
-- El sufijo ' — descartada por <persona_id>: <motivo>' en motivo_revision es sólo informativo: no autoriza nada (el
-- trigger (2) deja a cualquiera agregar un sufijo, pero (3) sólo mira excepcion_descarte). Se escribe el persona_id y
-- no el nombre porque ningún atributo de identidad vive en tiempo (SCJ-FRO-01); la UI lo resuelve como en movimientos.
--
-- Inventario de RLS/privilegios de este archivo:
--   tiempo.excepcion_descarte  RLS on, 1 policy (SELECT con excepcion_lectura o excepcion_edicion). authenticated y
--                              service_role: sólo SELECT. Nadie de la API inserta/actualiza/borra/trunca: la escribe el
--                              RPC (dueño). Inmutable en 3 capas: REVOKE, RLS sin policy de escritura y triggers
--                              BEFORE UPDATE OR DELETE / BEFORE TRUNCATE. Secuencia identity sin privilegios.
--   Funciones: fn_excepcion_dia_cerrado_descartar (SECURITY DEFINER, search_path = tiempo, personas, pg_temp): EXECUTE
--              sólo authenticated (REVOKE PUBLIC, anon, service_role). Todas las demás son internas o de trigger:
--              REVOKE EXECUTE FROM PUBLIC, anon, authenticated, service_role (corren como dueño o invocadas por triggers).
--   Permiso excepcion_dia_cerrado_descarte (heredable=false), otorgado vía bitácora a "Responsable de Recursos
--   Humanos", "Gerente General" y "Gerente o Encargado de TI" (el último es el puesto administrador: se incluye
--   explícito, no lo recibe solo).
--
-- Efectos sobre flujos existentes (revisados contra el DDL y el backend; el backend no escribe tiempo.excepcion):
--   - fn_dia_revisar (74_/77_, SECURITY INVOKER): sigue funcionando sin cambios. Resuelve la excepción con un UPDATE de
--     estado únicamente (pasa por (2)), arma el tramo (pasa por (4): sus marcas son del día), y al final marca el día
--     revisado con revisado_en = now(); al COMMIT, (3) lo encuentra.
--   - fn_ausencia_resuelve_excepcion (66_/51_): agrega un sufijo ' — resuelto por ausencia ...' a excepciones de DÍA
--     (dia_id, sin marca): pasa por (2) y no dispara (3) (motivo distinto de dia_cerrado).
--   - cierre_dia.py (service_role): inserta tramos con marcas de la persona y del día por construcción: pasa por (4).
--   - fn_correccion_recalcula_tramo (AFTER INSERT en correccion): su UPDATE de excepcion a 'resuelto' sobre una marca con
--     excepción dia_cerrado pendiente ahora falla con SCJ15 al COMMIT (decisión 2 del usuario). Sobre marcas con otros
--     motivos (reloj_no_sincronizado, fuera_de_horario, ...) no cambia nada. Una marca con DOS excepciones pendientes
--     (p. ej. reloj_no_sincronizado y dia_cerrado) tampoco se puede corregir hasta revisar el día: la corrección resuelve
--     ambas en un UPDATE y la de dia_cerrado lo impide.
--   - Reapertura (excepcion_reapertura): resuelto -> pendiente no cambia columnas protegidas; volver a resolver una
--     dia_cerrado reabierta exige otra vez revisión o descarte.
--
-- Residuales conocidos (B2 de la revisión de security; no se cierran aquí):
--   - dia_update_revision (62_/77_) deja a quien tenga dia_revision_edicion pasar un día bloqueado/cerrado a 'revisado'
--     por PostgREST directo sin armar tramos. Quien tenga ADEMÁS excepcion_dia_cerrado_descarte puede marcar el día
--     revisado y descartar la marca tardía. Queda auditado (revisado_por/revisado_en en tiempo.dia y la fila de
--     tiempo.excepcion_descarte con el actor) y exige dos permisos explícitos (el de descarte no es heredable). Revisar
--     cuando se endurezca tiempo.dia.
--   - Una excepción descartada puede reabrirse (excepcion_reapertura) y descartarse otra vez: excepcion_descarte no es
--     UNIQUE por excepcion_id (M1) y cada descarte deja su propia fila de auditoría.
--
-- Rollback de referencia (NO ejecutar sin revisar; borra la auditoría de descartes y deja de proteger tramos):
--   DROP FUNCTION tiempo.fn_excepcion_dia_cerrado_descartar(bigint, text);
--   DROP TABLE tiempo.excepcion_descarte;   -- sus triggers e índices caen con la tabla
--   DROP FUNCTION tiempo.fn_excepcion_descarte_inmutable();
--   DROP FUNCTION tiempo.fn_excepcion_descarte_truncate();
--   DROP TRIGGER trg_tramo_valida_coherencia ON tiempo.tramo;
--   DROP FUNCTION tiempo.fn_tramo_valida_coherencia();
--   DROP TRIGGER trg_excepcion_protege_columnas ON tiempo.excepcion;
--   DROP FUNCTION tiempo.fn_excepcion_protege_columnas();
--   -- restaurar el constraint trigger y la función de 78_ (DROP TRIGGER trg_excepcion_protege_dia_cerrado;
--   -- CREATE OR REPLACE FUNCTION tiempo.fn_excepcion_protege_dia_cerrado() con el cuerpo de 78_, repitiendo SECURITY
--   -- DEFINER y SET search_path = tiempo, pg_temp; CREATE CONSTRAINT TRIGGER con WHEN (OLD.motivo_revision =
--   -- 'dia_cerrado' AND ...)); DROP FUNCTION tiempo.fn_marca_fecha_local(bigint);
--   -- El permiso excepcion_dia_cerrado_descarte y sus filas en la bitácora de puesto_permiso NO se pueden borrar (la
--   -- bitácora es inmutable); quedan inertes.
--
-- Depende de: 02_tiempo.sql, 48_tiempo_rls_correccion_excepcion.sql, 64_tiempo_tramo_formar_al_revisar.sql,
--   66_tiempo_ausencia_descuento_pausa_y_confianza.sql, 73_tiempo_fn_dia_calcular_armado_tramos_ambiguedad.sql,
--   77_tiempo_dia_revision_admite_cerrado.sql, 78_tiempo_excepcion_protege_dia_cerrado.sql
-- Justificación: SCJ-DEC-06 (la única resolución legítima de un día cerrado es revisarlo), SCJ-DEC-07 (excepciones),
--   hallazgo de security 2026-10-07 (ALTO-1 y ALTO-2)

-- ============================================================================
-- 1) fn_marca_fecha_local -- fecha local EFECTIVA de una marca. Interna: la llaman funciones que corren como dueño.
-- ============================================================================

CREATE FUNCTION tiempo.fn_marca_fecha_local(p_marca_id bigint)
RETURNS date
LANGUAGE sql
STABLE
SET search_path = tiempo, pg_temp
AS $$
  SELECT ((COALESCE(
            (SELECT c.valor_corregido FROM tiempo.correccion c
              WHERE c.marca_id = m.id ORDER BY c.creado_en DESC LIMIT 1),
            m.momento_dispositivo) AT TIME ZONE 'UTC') + m.desfase_local::interval)::date
  FROM tiempo.marca m
  WHERE m.id = p_marca_id;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_marca_fecha_local(bigint) FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_marca_fecha_local(bigint) IS
  'Interna (86_). Fecha local EFECTIVA de la marca: valor de la corrección más reciente si existe, si no '
  'momento_dispositivo, más desfase_local. Mismo criterio que fn_dia_calcular_armado_tramos y el batch de cierre de día. '
  'Sin EXECUTE para la API: la usan funciones SECURITY DEFINER y triggers.';

-- ============================================================================
-- 2) trg_excepcion_protege_columnas -- cierra ALTO-1: ni la marca, ni el día, ni creado_en cambian, y el motivo sólo
-- crece con un sufijo al resolver. SECURITY INVOKER (no escribe nada, sólo compara OLD/NEW).
-- ============================================================================

CREATE FUNCTION tiempo.fn_excepcion_protege_columnas()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  IF NEW.marca_id IS DISTINCT FROM OLD.marca_id
     OR NEW.dia_id IS DISTINCT FROM OLD.dia_id
     OR NEW.creado_en IS DISTINCT FROM OLD.creado_en THEN
    RAISE EXCEPTION 'marca_id, dia_id y creado_en de una excepción no se pueden cambiar (excepción %)', OLD.id
      USING ERRCODE = 'SCJ15', HINT = 'excepcion_columna_inmutable';
  END IF;

  IF NEW.motivo_revision IS DISTINCT FROM OLD.motivo_revision THEN
    -- Sólo se admite AGREGAR un sufijo '' — ...'' al resolver (pendiente -> resuelto), conservando el prefijo intacto.
    IF NOT (OLD.estado = 'pendiente' AND NEW.estado = 'resuelto'
            AND starts_with(NEW.motivo_revision, OLD.motivo_revision || ' — ')) THEN
      RAISE EXCEPTION 'el motivo de la excepción % no se puede cambiar; sólo se agrega un sufijo al resolverla', OLD.id
        USING ERRCODE = 'SCJ15', HINT = 'excepcion_motivo_inmutable';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_protege_columnas() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_excepcion_protege_columnas
  BEFORE UPDATE ON tiempo.excepcion
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_excepcion_protege_columnas();

COMMENT ON FUNCTION tiempo.fn_excepcion_protege_columnas() IS
  '86_ (security ALTO-1). marca_id, dia_id y creado_en inmutables; motivo_revision sólo puede cambiar agregando un '
  'sufijo '' — ...'' junto con pendiente -> resuelto. Error SCJ15 (excepcion_columna_inmutable | excepcion_motivo_inmutable). '
  'SECURITY INVOKER con search_path fijo; sin EXECUTE para la API.';

-- ============================================================================
-- 3) Constraint trigger recreado y función reescrita (reemplaza el de 78_). CREATE OR REPLACE repite SECURITY DEFINER y
-- SET search_path: no se heredan (gotcha de CLAUDE.md); 78_ creó la función con ambas cláusulas y no hay ALTER FUNCTION
-- posterior (verificado por grep). El DROP TRIGGER no pierde nada: el trigger nuevo se crea en la misma transacción.
-- ============================================================================

CREATE OR REPLACE FUNCTION tiempo.fn_excepcion_protege_dia_cerrado()
RETURNS trigger
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_persona_id  uuid;
  v_fecha       date;
BEGIN
  -- (b) descarte registrado por el RPC EN ESTA transacción (creado_en = now() = inicio de la transacción)
  IF EXISTS (
    SELECT 1 FROM tiempo.excepcion_descarte x
    WHERE x.excepcion_id = NEW.id AND x.creado_en = now()
  ) THEN
    RETURN NULL;
  END IF;

  -- (a) revisión del día hecha EN ESTA transacción, con un tramo que contenga la marca, del mismo día y persona
  IF NEW.marca_id IS NOT NULL THEN
    SELECT m.persona_id INTO v_persona_id FROM tiempo.marca m WHERE m.id = NEW.marca_id;
    v_fecha := tiempo.fn_marca_fecha_local(NEW.marca_id);

    IF EXISTS (
      SELECT 1
      FROM tiempo.tramo t
      JOIN tiempo.dia d ON d.id = t.dia_id
      WHERE (t.marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id)
        AND d.persona_id = v_persona_id
        AND d.fecha = v_fecha
        AND d.estado = 'revisado'
        AND d.revisado_en = now()
    ) THEN
      RETURN NULL;
    END IF;
  END IF;

  RAISE EXCEPTION
    'La excepción % (motivo dia_cerrado) sólo se resuelve revisando el día en esta misma transacción, o con el descarte de una marca tardía',
    NEW.id
    USING ERRCODE = 'SCJ15', HINT = 'dia_cerrado_requiere_revision';
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_protege_dia_cerrado() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER trg_excepcion_protege_dia_cerrado ON tiempo.excepcion;

CREATE CONSTRAINT TRIGGER trg_excepcion_protege_dia_cerrado
  AFTER UPDATE ON tiempo.excepcion
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  WHEN (
    OLD.motivo_revision LIKE 'dia\_cerrado%'
    AND OLD.estado = 'pendiente'
    AND NEW.estado = 'resuelto'
  )
  EXECUTE FUNCTION tiempo.fn_excepcion_protege_dia_cerrado();

COMMENT ON FUNCTION tiempo.fn_excepcion_protege_dia_cerrado() IS
  'Constraint trigger de motivo dia_cerrado% (86_, reemplaza el de 78_): bloquea, al COMMIT (DEFERRABLE INITIALLY DEFERRED), '
  'cualquier pendiente -> resuelto que no sea (a) una revisión del día hecha en la misma transacción -- tramo que contiene '
  'la marca, del mismo día y persona de la marca, día revisado con revisado_en = now() -- o (b) un descarte de '
  'fn_excepcion_dia_cerrado_descartar registrado en esta transacción. SCJ15 / dia_cerrado_requiere_revision. SECURITY DEFINER '
  'SET search_path = tiempo, pg_temp: al reescribirla con CREATE OR REPLACE repetir ambas cláusulas.';

-- ============================================================================
-- 4) trg_tramo_valida_coherencia -- cierra el origen de ALTO-2. SECURITY DEFINER: quien inserta (RH con
-- dia_revision_edicion o el batch con service_role) no necesariamente puede leer marca/correccion.
-- En UPDATE sólo se revisa si cambian dia_id o las marcas (fn_correccion_recalcula_tramo cambia inicio/fin, no la
-- pertenencia, y no debe romperse si una corrección cruza la medianoche).
-- ============================================================================

CREATE FUNCTION tiempo.fn_tramo_valida_coherencia()
RETURNS trigger
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_dia_persona  uuid;
  v_dia_fecha    date;
  v_marca_id     bigint;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.dia_id IS NOT DISTINCT FROM OLD.dia_id
     AND NEW.marca_apertura_id IS NOT DISTINCT FROM OLD.marca_apertura_id
     AND NEW.marca_cierre_id IS NOT DISTINCT FROM OLD.marca_cierre_id THEN
    RETURN NEW;
  END IF;

  SELECT d.persona_id, d.fecha INTO v_dia_persona, v_dia_fecha FROM tiempo.dia d WHERE d.id = NEW.dia_id;

  FOREACH v_marca_id IN ARRAY ARRAY[NEW.marca_apertura_id, NEW.marca_cierre_id] LOOP
    CONTINUE WHEN v_marca_id IS NULL;
    IF NOT EXISTS (SELECT 1 FROM tiempo.marca m WHERE m.id = v_marca_id AND m.persona_id = v_dia_persona)
       OR tiempo.fn_marca_fecha_local(v_marca_id) IS DISTINCT FROM v_dia_fecha THEN
      RAISE EXCEPTION 'La marca % no corresponde a la persona o al día del tramo (día %)', v_marca_id, NEW.dia_id
        USING ERRCODE = 'SCJ15', HINT = 'tramo_incoherente';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

REVOKE EXECUTE ON FUNCTION tiempo.fn_tramo_valida_coherencia() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_tramo_valida_coherencia
  BEFORE INSERT OR UPDATE ON tiempo.tramo
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_tramo_valida_coherencia();

COMMENT ON FUNCTION tiempo.fn_tramo_valida_coherencia() IS
  '86_ (security ALTO-2). Las marcas de apertura y cierre de un tramo deben ser de la misma persona que el día y tener '
  'fecha local efectiva igual a la fecha del día. En UPDATE sólo se revisa si cambian dia_id o las marcas. SCJ15 / '
  'tramo_incoherente. SECURITY DEFINER SET search_path = tiempo, pg_temp; sin EXECUTE para la API.';

-- ============================================================================
-- 5) Descarte legítimo de una marca tardía sobre un día YA revisado.
-- 5a) Permiso de acción nuevo, no heredable, otorgado por bitácora (molde de 62_ y 80_). El puesto administrador se
--     incluye explícito.
-- ============================================================================

INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('excepcion_dia_cerrado_descarte', false)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'excepcion_dia_cerrado_descarte', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto IN (
    'Responsable de Recursos Humanos',
    'Gerente General',
    'Gerente o Encargado de TI'
  )
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'excepcion_dia_cerrado_descarte' AND pp.activo
  );

-- ============================================================================
-- 5b) tiempo.excepcion_descarte -- auditoría durable de cada descarte; es también la condición que acepta el constraint
-- trigger. Sólo la escribe el RPC (dueño). Inmutable en 3 capas, como la bitácora de enrolamiento (81_).
-- ============================================================================

CREATE TABLE tiempo.excepcion_descarte (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  excepcion_id  bigint NOT NULL REFERENCES tiempo.excepcion (id),
  dia_id        bigint NOT NULL REFERENCES tiempo.dia (id),
  persona_id    uuid NOT NULL REFERENCES tiempo.persona (id),
  motivo        varchar(500) NOT NULL,
  creado_en     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_excepcion_descarte_motivo CHECK (char_length(btrim(motivo)) >= 1)
);

-- NO es UNIQUE (M1 de la revisión de security): una excepción descartada puede reabrirse (excepcion_reapertura) y volver a
-- descartarse; cada descarte es una fila de auditoría distinta y todas se conservan.
CREATE INDEX ix_excepcion_descarte_excepcion_id ON tiempo.excepcion_descarte (excepcion_id);
CREATE INDEX ix_excepcion_descarte_dia_id ON tiempo.excepcion_descarte (dia_id);
CREATE INDEX ix_excepcion_descarte_persona_id ON tiempo.excepcion_descarte (persona_id);

COMMENT ON TABLE tiempo.excepcion_descarte IS
  'Auditoría de fn_excepcion_dia_cerrado_descartar (86_): quién descartó una marca tardía sobre un día ya revisado, '
  'cuándo y por qué. Sólo la escribe el RPC; sin INSERT/UPDATE/DELETE/TRUNCATE para la API. El constraint trigger de '
  'dia_cerrado acepta la resolución de una excepción si hay aquí un descarte de ella creado en la misma transacción.';
COMMENT ON COLUMN tiempo.excepcion_descarte.excepcion_id IS
  'Excepción descartada. Sin UNIQUE: una excepción reabierta y descartada otra vez deja una fila nueva por cada descarte.';
COMMENT ON COLUMN tiempo.excepcion_descarte.dia_id IS 'Día (revisado) al que pertenece la marca tardía.';
COMMENT ON COLUMN tiempo.excepcion_descarte.persona_id IS
  'Quien descartó (vía frontera SCJ-FRO-01, tiempo.persona), derivado de auth.uid() dentro del RPC; nunca un parámetro.';
COMMENT ON COLUMN tiempo.excepcion_descarte.motivo IS 'Motivo saneado (sin caracteres de control), 1 a 500 caracteres.';
COMMENT ON COLUMN tiempo.excepcion_descarte.creado_en IS
  'Inicio de la transacción del descarte (now()); el constraint trigger lo compara con now() para exigir que sea de ESTA transacción.';

ALTER TABLE tiempo.excepcion_descarte ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON tiempo.excepcion_descarte FROM anon, authenticated, service_role;
GRANT SELECT ON tiempo.excepcion_descarte TO authenticated, service_role;

CREATE POLICY excepcion_descarte_select_lectura ON tiempo.excepcion_descarte
  FOR SELECT TO authenticated
  USING (
    personas.fn_caller_activo() AND (
      personas.fn_caller_tiene_permiso('excepcion_lectura')
      OR personas.fn_caller_tiene_permiso('excepcion_edicion')
    )
  );

REVOKE ALL ON SEQUENCE tiempo.excepcion_descarte_id_seq FROM anon, authenticated, service_role;

CREATE FUNCTION tiempo.fn_excepcion_descarte_inmutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'tiempo.excepcion_descarte es de solo inserción: % no está permitido (fila %)', TG_OP, OLD.id;
END;
$$;

CREATE TRIGGER trg_excepcion_descarte_inmutable
  BEFORE UPDATE OR DELETE ON tiempo.excepcion_descarte
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_excepcion_descarte_inmutable();

CREATE FUNCTION tiempo.fn_excepcion_descarte_truncate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = tiempo, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'tiempo.excepcion_descarte es de solo inserción: TRUNCATE no está permitido';
END;
$$;

CREATE TRIGGER trg_excepcion_descarte_truncate
  BEFORE TRUNCATE ON tiempo.excepcion_descarte
  FOR EACH STATEMENT
  EXECUTE FUNCTION tiempo.fn_excepcion_descarte_truncate();

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_descarte_inmutable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_descarte_truncate() FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION tiempo.fn_excepcion_descarte_inmutable() IS
  'Aborta UPDATE/DELETE sobre tiempo.excepcion_descarte, incluido service_role y el dueño. Sin EXECUTE para la API.';
COMMENT ON FUNCTION tiempo.fn_excepcion_descarte_truncate() IS
  'Aborta TRUNCATE sobre tiempo.excepcion_descarte (trigger por statement). Sin EXECUTE para la API.';

-- ============================================================================
-- 5c) fn_excepcion_dia_cerrado_descartar -- RPC. Devuelve {resultado: 'descartada' | 'ya_descartada' | 'no_encontrada'}.
-- Sólo para excepciones de motivo dia_cerrado% de una MARCA cuya fecha local efectiva corresponde a un día 'revisado'.
-- Quién descarta sale de auth.uid(); el permiso y la persona activa se exigen dentro. Idempotente: descartar de nuevo
-- una excepción que ya está resuelta y tiene un descarte devuelve 'ya_descartada' sin tocar nada; si fue reabierta
-- (pendiente) se descarta otra vez y se agrega una fila nueva de auditoría.
-- ============================================================================

CREATE FUNCTION tiempo.fn_excepcion_dia_cerrado_descartar(p_excepcion_id bigint, p_motivo text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  c_motivo_max  constant integer := 500;
  v_actor       uuid;
  v_motivo      text;
  v_exc         tiempo.excepcion;
  v_persona_id  uuid;
  v_fecha       date;
  v_dia         tiempo.dia;
BEGIN
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('excepcion_dia_cerrado_descarte')) THEN
    RAISE EXCEPTION 'No tienes permiso para descartar excepciones de días cerrados'
      USING ERRCODE = '42501', HINT = 'sin_permiso';
  END IF;

  v_motivo := left(btrim(regexp_replace(COALESCE(p_motivo, ''), '[[:cntrl:]]', ' ', 'g')), c_motivo_max);
  IF v_motivo = '' THEN
    RAISE EXCEPTION 'El motivo del descarte es obligatorio'
      USING ERRCODE = '22023', HINT = 'motivo_invalido';
  END IF;

  SELECT u.persona_id INTO v_actor FROM personas.usuario u WHERE u.auth_user_id = auth.uid();

  SELECT e.* INTO v_exc FROM tiempo.excepcion e WHERE e.id = p_excepcion_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('resultado', 'no_encontrada');
  END IF;

  IF v_exc.marca_id IS NULL OR v_exc.motivo_revision NOT LIKE 'dia\_cerrado%' THEN
    RAISE EXCEPTION 'La excepción % no es una marca tardía de día cerrado', p_excepcion_id
      USING ERRCODE = 'SCJ15', HINT = 'excepcion_no_descartable';
  END IF;

  IF v_exc.estado = 'resuelto' THEN
    IF EXISTS (SELECT 1 FROM tiempo.excepcion_descarte x WHERE x.excepcion_id = p_excepcion_id) THEN
      RETURN jsonb_build_object('resultado', 'ya_descartada', 'excepcion_id', p_excepcion_id);
    END IF;
    RAISE EXCEPTION 'La excepción % ya está resuelta por otra vía', p_excepcion_id
      USING ERRCODE = 'SCJ15', HINT = 'excepcion_no_descartable';
  END IF;

  SELECT m.persona_id INTO v_persona_id FROM tiempo.marca m WHERE m.id = v_exc.marca_id;
  v_fecha := tiempo.fn_marca_fecha_local(v_exc.marca_id);
  SELECT d.* INTO v_dia FROM tiempo.dia d WHERE d.persona_id = v_persona_id AND d.fecha = v_fecha;
  IF NOT FOUND OR v_dia.estado <> 'revisado' THEN
    RAISE EXCEPTION 'El día de la marca no está revisado; se resuelve revisándolo, no descartando la marca'
      USING ERRCODE = 'SCJ15', HINT = 'dia_no_revisado';
  END IF;

  INSERT INTO tiempo.excepcion_descarte (excepcion_id, dia_id, persona_id, motivo)
  VALUES (p_excepcion_id, v_dia.id, v_actor, v_motivo);

  UPDATE tiempo.excepcion
  SET estado = 'resuelto',
      motivo_revision = motivo_revision || ' — descartada por ' || v_actor::text || ': ' || v_motivo
  WHERE id = p_excepcion_id;

  RETURN jsonb_build_object('resultado', 'descartada', 'excepcion_id', p_excepcion_id, 'dia_id', v_dia.id);
END;
$$;

REVOKE EXECUTE ON FUNCTION tiempo.fn_excepcion_dia_cerrado_descartar(bigint, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_excepcion_dia_cerrado_descartar(bigint, text) TO authenticated;

COMMENT ON FUNCTION tiempo.fn_excepcion_dia_cerrado_descartar(bigint, text) IS
  '86_. Descarta una marca tardía sobre un día YA revisado: exige persona activa y el permiso de acción '
  'excepcion_dia_cerrado_descarte (no heredable) DENTRO de la función, deriva quién descarta de auth.uid(), registra '
  'quién/cuándo/por qué en tiempo.excepcion_descarte y resuelve la excepción con el sufijo '' — descartada por <persona_id>: '
  '<motivo>''. Sólo excepciones dia_cerrado% de marca cuyo día está revisado (SCJ15: excepcion_no_descartable | dia_no_revisado). '
  'Idempotente (ya_descartada). SECURITY DEFINER SET search_path = tiempo, personas, pg_temp; EXECUTE sólo authenticated.';
