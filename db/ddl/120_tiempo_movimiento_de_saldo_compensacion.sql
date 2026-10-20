-- 120_tiempo_movimiento_de_saldo_compensacion.sql
-- Vía auditada para COMPENSAR un movimiento generado_quincena erróneo (p. ej. el corte de 01–15-oct-2026 que cargó 86 h de deuda por permisos con goce mal calculados, 118_/119_).
--
-- HASTA HOY no había forma de deshacer un generado_quincena: el ledger es append-only (UPDATE/DELETE revocados, 103_) y los tipos manuales (arrastrar/descontar/condonar, 68_/104_) están pensados
-- para decisiones de negocio sobre deuda REAL (renovar antigüedad, descontar de nómina, condonar), no para corregir un error del sistema, y su tope es el saldo total. Corregir un error exige un
-- movimiento opuesto LIGADO al original, con motivo, autor y fecha, que no se pueda aplicar dos veces.
--
-- QUÉ HACE
--  1. tiempo.movimiento_de_saldo.tipo admite 'compensacion' (se reescribe el CHECK ck_movimiento_de_saldo_tipo).
--  2. Columna compensa_movimiento_id (FK al propio ledger) + índice ÚNICO parcial sobre ella: un movimiento solo se puede compensar UNA vez (la base lo garantiza, también para service_role).
--  3. CHECK ck_movimiento_de_saldo_compensacion: tipo = 'compensacion' si y solo si hay compensa_movimiento_id; y toda compensación lleva monto < 0, autor_id y motivo no vacío de a lo más 500 caracteres.
--  4. Trigger BEFORE INSERT tiempo.fn_movimiento_compensacion_valida (SECURITY DEFINER, search_path fijo, sin EXECUTE para nadie): la compensación debe apuntar a un generado_quincena del MISMO banco, su
--     monto debe ser exactamente el opuesto y, con el banco BLOQUEADO (FOR UPDATE), no puede dejar su saldo por debajo de 0. Cubre cualquier camino de escritura (el RPC, el batch con service_role, el SQL Editor).
--  5. Permiso nuevo movimiento_de_saldo_compensar (NO heredable: corrige el ledger financiero). Sembrado en «Gerente General» y «Gerente o Encargado de TI» (el administrador genérico conserva todos
--     los permisos); NO en RH. Decisión final de security.
--  6. RPC tiempo.fn_movimiento_de_saldo_compensar(p_movimiento_id bigint, p_motivo text) RETURNS tiempo.movimiento_de_saldo — SECURITY DEFINER, search_path = tiempo, personas, pg_temp; EXECUTE solo
--     authenticated. La autorización va DENTRO (persona activa + permiso), el autor sale de auth.uid() (nunca del cliente) y la fecha es now() de la transacción.
--
-- ERRORES del RPC (ERRCODE SCJ24, mensaje fijo, HINT estable): 'motivo_obligatorio', 'motivo_demasiado_largo' (más de 500 caracteres), 'compensacion_propia' (el banco es de la propia persona que compensa: nadie corrige su propia deuda; condición de security para la siembra en Gerente General y TI), 'movimiento_inexistente', 'no_compensable' (no es generado_quincena), 'ya_compensado', 'saldo_insuficiente' (la
-- compensación dejaría el saldo del banco por debajo de 0: p. ej. parte de esa deuda ya se cubrió con horas de reposición; esa devolución exige decisión humana aparte). 42501 sin permiso.
--
-- EFECTO EN EL SALDO. El trigger de 104_ (fn_movimiento_de_saldo_actualiza_banco, DEFINER) suma NEW.monto (negativo) a banco_de_horas.monto: SÍ mueve el saldo. Si queda en 0, vivo_desde pasa a NULL;
-- si queda saldo positivo, vivo_desde NO cambia (comportamiento existente, no se toca).
-- EFECTO EN EL FIFO de backend/app/banco_antiguedad.py::calcular_lotes: una compensación es monto < 0 y hoy consumiría el lote MÁS VIEJO primero, que NO es el que se está corrigiendo (el erróneo suele
-- ser el más reciente). Backend debe tratar tipo = 'compensacion' aparte: consumir primero el lote cuyo movimiento_id = compensa_movimiento_id (hasta su restante) y solo un remanente, si lo hubiera,
-- por FIFO normal. Sin ese cambio, el desglose por antigüedad quedaría mal y la reconciliación contra banco_de_horas.monto seguiría cuadrando en total pero no por tramo. El listado del ledger debe
-- mostrar el tipo nuevo y compensa_movimiento_id.
--
-- CHECKS DE EXISTENTES: ninguna fila actual tiene compensa_movimiento_id ni tipo 'compensacion', así que los constraints nuevos validan limpio.
-- APLICAR con `psql --single-transaction -v ON_ERROR_STOP=1 -f 120_*.sql`.
-- ORDEN: 120_ se aplica ANTES de desplegar el backend nuevo (este ya selecciona compensa_movimiento_id): 118_, 119_, 120_ (sección 83 tras cada una), luego backend y frontend en la misma ventana, luego el script de db/correcciones/.
-- REVERSA (en una transacción, y solo si NO existe ninguna fila 'compensacion'): DROP FUNCTION del RPC y del trigger, DROP INDEX, DROP CONSTRAINT del CHECK nuevo, DROP COLUMN compensa_movimiento_id,
-- recrear ck_movimiento_de_saldo_tipo con los 5 tipos de 02_, y dar de baja el permiso (revocar del puesto y borrar de personas.permiso si no tiene bitácora; si la tiene, dejarlo sin asignar).
-- Texto exacto en db/ensayos/ensayo_120.sql, bloque reversa.
-- Depende de: 02_tiempo.sql, 103_*.sql, 104_*.sql, 105_*.sql, personas.permiso / bitacora_movimiento_puesto_permiso
-- Justificación: SCJ-DEC-02, SCJ-PRO-13

-- 1) tipo nuevo
ALTER TABLE tiempo.movimiento_de_saldo DROP CONSTRAINT ck_movimiento_de_saldo_tipo;
ALTER TABLE tiempo.movimiento_de_saldo ADD CONSTRAINT ck_movimiento_de_saldo_tipo CHECK (tipo IN
  ('generado_quincena', 'cubrir', 'arrastrar', 'descontar', 'condonar', 'compensacion'));

-- 2) liga a la compensada + unicidad
ALTER TABLE tiempo.movimiento_de_saldo
  ADD COLUMN compensa_movimiento_id bigint REFERENCES tiempo.movimiento_de_saldo (id);
CREATE UNIQUE INDEX uq_movimiento_de_saldo_compensa ON tiempo.movimiento_de_saldo (compensa_movimiento_id)
  WHERE compensa_movimiento_id IS NOT NULL;

-- 3) forma de una compensación
ALTER TABLE tiempo.movimiento_de_saldo ADD CONSTRAINT ck_movimiento_de_saldo_compensacion CHECK (
  ((tipo = 'compensacion') = (compensa_movimiento_id IS NOT NULL))
  AND (tipo <> 'compensacion' OR (monto < 0 AND autor_id IS NOT NULL AND length(btrim(COALESCE(motivo, ''))) > 0 AND length(motivo) <= 500))
);

COMMENT ON COLUMN tiempo.movimiento_de_saldo.compensa_movimiento_id IS
  'Solo para tipo = compensacion: el generado_quincena que revierte (120_). UNIQUE parcial: un movimiento se compensa una sola vez.';
COMMENT ON COLUMN tiempo.movimiento_de_saldo.tipo IS
  'generado_quincena: +monto, automático al corte quincenal, sólo si horas_esperadas > horas_trabajadas (nunca genera saldo a favor). cubrir: -monto, automático desde una clasificacion_de_tiempo tipo '
  'reposicion. arrastrar: par -monto/+monto (renueva antigüedad), manual RH. descontar/condonar: -monto, manual. compensacion (120_): -monto exacto del generado_quincena que corrige, ligado en '
  'compensa_movimiento_id, con motivo y autor obligatorios.';

-- 4) validación al insertar, sea cual sea el camino de escritura
CREATE FUNCTION tiempo.fn_movimiento_compensacion_valida()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, pg_temp
AS $$
DECLARE
  v_original    tiempo.movimiento_de_saldo;
  v_monto_banco numeric;
BEGIN
  SELECT * INTO v_original FROM tiempo.movimiento_de_saldo WHERE id = NEW.compensa_movimiento_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El movimiento a compensar no existe.' USING ERRCODE = 'SCJ24', HINT = 'movimiento_inexistente';
  END IF;
  IF v_original.tipo <> 'generado_quincena' THEN
    RAISE EXCEPTION 'Solo se puede compensar un movimiento generado por el corte quincenal.' USING ERRCODE = 'SCJ24', HINT = 'no_compensable';
  END IF;
  IF v_original.banco_de_horas_id <> NEW.banco_de_horas_id OR NEW.monto <> -v_original.monto THEN
    RAISE EXCEPTION 'La compensación debe ser del mismo banco y por el monto exacto, en negativo.' USING ERRCODE = 'SCJ24', HINT = 'compensacion_no_coincide';
  END IF;

  -- B1: con el banco bloqueado (serializa compensaciones y movimientos concurrentes), la compensación no puede dejar el saldo por debajo de 0, sea cual sea el camino de escritura.
  SELECT b.monto INTO v_monto_banco FROM tiempo.banco_de_horas b WHERE b.id = NEW.banco_de_horas_id FOR UPDATE;
  IF v_monto_banco IS NULL OR v_monto_banco + NEW.monto < 0 THEN
    RAISE EXCEPTION 'La compensación dejaría el saldo por debajo de cero.' USING ERRCODE = 'SCJ24', HINT = 'saldo_insuficiente';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_compensacion_valida() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION tiempo.fn_movimiento_compensacion_valida() IS
  'Trigger BEFORE INSERT de tiempo.movimiento_de_saldo (120_): una compensación debe apuntar a un generado_quincena del mismo banco por el monto exacto en negativo. SECURITY DEFINER con search_path '
  'fijo; sin EXECUTE para nadie. SCJ24 con HINT movimiento_inexistente / no_compensable / compensacion_no_coincide.';

CREATE TRIGGER trg_movimiento_compensacion_valida
  BEFORE INSERT ON tiempo.movimiento_de_saldo
  FOR EACH ROW
  WHEN (NEW.tipo = 'compensacion')
  EXECUTE FUNCTION tiempo.fn_movimiento_compensacion_valida();

-- 5) permiso nuevo (no heredable)
INSERT INTO personas.permiso (codigo, heredable) VALUES
  ('movimiento_de_saldo_compensar', false)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO personas.bitacora_movimiento_puesto_permiso (puesto_id, codigo, tipo_movimiento)
SELECT p.id, 'movimiento_de_saldo_compensar', 'otorgado'
FROM personas.puesto p
WHERE p.nombre_puesto IN ('Gerente General', 'Gerente o Encargado de TI')
  AND NOT EXISTS (
    SELECT 1 FROM personas.puesto_permiso pp
    WHERE pp.puesto_id = p.id AND pp.codigo = 'movimiento_de_saldo_compensar' AND pp.activo
  );

-- 6) RPC
CREATE FUNCTION tiempo.fn_movimiento_de_saldo_compensar(
  p_movimiento_id  bigint,
  p_motivo         text
) RETURNS tiempo.movimiento_de_saldo
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_autor_id     uuid;
  v_original     tiempo.movimiento_de_saldo;
  v_monto_banco  numeric;
  v_persona_banco uuid;
  v_fila         tiempo.movimiento_de_saldo;
BEGIN
  -- Autorización dentro (la RLS no se hereda a una función DEFINER): persona activa con el permiso.
  IF NOT (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_compensar')) THEN
    RAISE EXCEPTION 'No tienes permiso para compensar movimientos de saldo.' USING ERRCODE = '42501';
  END IF;

  -- autor_id SIEMPRE desde la sesión (nunca del cliente).
  SELECT u.persona_id INTO v_autor_id FROM personas.usuario u WHERE u.auth_user_id = auth.uid();
  IF v_autor_id IS NULL THEN
    RAISE EXCEPTION 'No tienes permiso para compensar movimientos de saldo.' USING ERRCODE = '42501';
  END IF;

  IF p_motivo IS NULL OR length(btrim(p_motivo)) = 0 THEN
    RAISE EXCEPTION 'El motivo es obligatorio.' USING ERRCODE = 'SCJ24', HINT = 'motivo_obligatorio';
  END IF;

  IF length(btrim(p_motivo)) > 500 THEN
    RAISE EXCEPTION 'El motivo no puede exceder 500 caracteres.' USING ERRCODE = 'SCJ24', HINT = 'motivo_demasiado_largo';
  END IF;

  SELECT * INTO v_original FROM tiempo.movimiento_de_saldo WHERE id = p_movimiento_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El movimiento a compensar no existe.' USING ERRCODE = 'SCJ24', HINT = 'movimiento_inexistente';
  END IF;
  IF v_original.tipo <> 'generado_quincena' THEN
    RAISE EXCEPTION 'Solo se puede compensar un movimiento generado por el corte quincenal.' USING ERRCODE = 'SCJ24', HINT = 'no_compensable';
  END IF;

  -- FOR UPDATE: serializa dos compensaciones/movimientos concurrentes sobre el mismo banco (la comprobación es check-then-act).
  SELECT b.monto, b.persona_id INTO v_monto_banco, v_persona_banco FROM tiempo.banco_de_horas b WHERE b.id = v_original.banco_de_horas_id FOR UPDATE;

  -- M1 (security): nadie compensa su propia deuda; condición de la siembra en Gerente General y TI.
  IF v_persona_banco = v_autor_id THEN
    RAISE EXCEPTION 'No puedes compensar movimientos de tu propio banco de horas.' USING ERRCODE = 'SCJ24', HINT = 'compensacion_propia';
  END IF;

  IF EXISTS (SELECT 1 FROM tiempo.movimiento_de_saldo m WHERE m.compensa_movimiento_id = v_original.id) THEN
    RAISE EXCEPTION 'Este movimiento ya fue compensado.' USING ERRCODE = 'SCJ24', HINT = 'ya_compensado';
  END IF;
  IF v_monto_banco - v_original.monto < 0 THEN
    RAISE EXCEPTION 'La compensación dejaría el saldo por debajo de cero.' USING ERRCODE = 'SCJ24', HINT = 'saldo_insuficiente';
  END IF;

  INSERT INTO tiempo.movimiento_de_saldo (banco_de_horas_id, tipo, monto, motivo, autor_id, compensa_movimiento_id)
  VALUES (v_original.banco_de_horas_id, 'compensacion', -v_original.monto, btrim(p_motivo), v_autor_id, v_original.id)
  RETURNING * INTO v_fila;

  RETURN v_fila;
END;
$$;
REVOKE EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_compensar(bigint, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION tiempo.fn_movimiento_de_saldo_compensar(bigint, text) TO authenticated;
COMMENT ON FUNCTION tiempo.fn_movimiento_de_saldo_compensar(bigint, text) IS
  'Compensa un movimiento generado_quincena erróneo con el movimiento opuesto ligado (120_). Autorización dentro: persona activa + movimiento_de_saldo_compensar (no heredable); autor desde auth.uid(); '
  'motivo obligatorio; una sola vez por movimiento; no deja el saldo del banco por debajo de 0. DEFINER con search_path fijo; EXECUTE solo authenticated. SCJ24 con HINT motivo_obligatorio / '
  'movimiento_inexistente / no_compensable / ya_compensado / saldo_insuficiente; 42501 sin permiso. Rechaza compensar el banco propio (compensacion_propia) y un motivo de más de 500 caracteres (motivo_demasiado_largo). Backend: banco_antiguedad.calcular_lotes debe tratar tipo = compensacion contra el lote ligado.';
