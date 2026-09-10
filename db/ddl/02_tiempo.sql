-- 02_tiempo.sql
-- Tablas del subsistema de Tiempo.
-- Depende de: 00_esquemas.sql, 01_persona_stub.sql
-- Justificación: SCJ-MOD-03 · Decisiones SCJ-DEC-01 a SCJ-DEC-09
--
-- Nota de alcance (2026-09-02, actualizada): SCJ-DEC-01, SCJ-DEC-04 y SCJ-DEC-08 ya son
-- Aceptadas y este DDL las refleja:
--   - Paridad (SCJ-DEC-01, Opción C): no hay restricción que bloquee un número impar de marcas al
--     insertar — un tramo con marca_cierre_id nulo es un tramo abierto, válido. La cuenta de
--     marcas por persona/día se valida en la aplicación al cerrar el día, no en la base.
--   - Vigencias (SCJ-DEC-04, Opción A): `vigente_desde date NOT NULL` + `vigente_hasta date`
--     (`NULL` = vigente), sin `EXCLUDE GIST`. El traslape se valida en la aplicación antes de
--     insertar o actualizar una vigencia — ver CONVENCIONES.md §II.
--   - Clave de la marca (SCJ-DEC-08, Opción B): id bigint identity como PK (convención universal
--     de este repo, "clave primaria siempre id") y evento_id uuid como llave de negocio UNIQUE
--     para idempotencia. Confirmada como definitiva, sin cambios de esquema.
--
-- Corrección de reconciliación (2026-09-05): tiempo.marca había divergido de SCJ-CDT-01 §IV/§V sin
-- decisión formal — faltaban desfase_local y version_software (obligatorios en el contrato),
-- estado_reloj (enum de 3 valores) estaba colapsado en un boolean, momento_terminal/momento_servidor
-- no coincidían con los nombres cerrados del contrato (momento_dispositivo/momento_recepcion), y
-- origen tenía un tercer valor ('contingencia') que SCJ-CDT-01/SCJ-ESP-01 nunca contemplaron. Se
-- restauran los nombres y campos del contrato; origen se resuelve a los 2 valores reales
-- ('terminal' | 'captura_manual' — 'captura_manual' es el nombre definitivo, sustituye a 'asistido'
-- en SCJ-CDT-01/SCJ-ESP-01, ver notas de versión ahí). 'contingencia' se elimina por ser un error sin
-- respaldo. Ver bitácora 2026-09-05.

-- ============================================================================
-- Catálogos independientes
-- ============================================================================

CREATE TABLE tiempo.tope_legal (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vigente_desde    date NOT NULL,
  vigente_hasta    date,
  maximo_semanal   numeric(6,2) NOT NULL,
  maximo_extra     numeric(6,2) NOT NULL,
  CONSTRAINT uq_tope_legal_vigente_desde UNIQUE (vigente_desde)
);

COMMENT ON TABLE tiempo.tope_legal IS
  'Máximo semanal y de horas extra, con vigencia. vigente_hasta NULL = vigente actual; el '
  'traslape entre vigencias se valida en la aplicación (SCJ-DEC-04, Opción A). Ver SCJ-ESP-01 '
  '§VI.4.';

CREATE TABLE tiempo.dia_festivo (
  id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fecha   date NOT NULL,
  nombre  varchar(100) NOT NULL,
  CONSTRAINT uq_dia_festivo_fecha UNIQUE (fecha)
);

COMMENT ON TABLE tiempo.dia_festivo IS
  'Catálogo de días festivos. No calculable por fórmula (festivos móviles) — se carga a mano. '
  'Domingo no necesita catálogo: se deriva de la fecha. Usado para separar, al corte quincenal, '
  'las horas trabajadas en domingo o festivo con su concepto de pago — sin importar si esas horas '
  'fueron ordinarias, de reposición o extra.';

CREATE TABLE tiempo.parametro (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clave           varchar(100) NOT NULL,
  valor           text NOT NULL,
  vigente_desde   date NOT NULL,
  CONSTRAINT uq_parametro_clave_vigente UNIQUE (clave, vigente_desde)
);

COMMENT ON TABLE tiempo.parametro IS
  'Valor de regla de negocio, configurable y versionado por vigente_desde — mismo patrón que '
  'tope_legal. Ver SCJ-ESP-01 §VI.9 y SCJ-DIC-01 §IV para el catálogo de claves conocidas '
  '(tolerancia_retardo_min, hora_corte_dia, ventana_banco_meses, umbral_aviso_pct, '
  'umbral_escalamiento_pct, descuento_pausa_no_registrada_min).';

-- ============================================================================
-- Jornada
-- ============================================================================

CREATE TABLE tiempo.jornada_asignada (
  id                              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  persona_id                      uuid NOT NULL REFERENCES tiempo.persona (id),
  tipo_jornada                    varchar(20) NOT NULL,
  vigente_desde                   date NOT NULL,
  vigente_hasta                   date,
  descuento_comida_fija           boolean NOT NULL DEFAULT false,
  minutos_descuento_comida_fija   int,
  horas_semanales_calculadas      numeric(6,2),
  genera_alerta_horario           boolean NOT NULL DEFAULT true,
  CONSTRAINT ck_jornada_asignada_tipo
    CHECK (tipo_jornada IN ('normal', 'flexible', 'de_confianza')),
  CONSTRAINT ck_jornada_asignada_descuento_fijo
    CHECK ((descuento_comida_fija) = (minutos_descuento_comida_fija IS NOT NULL))
);

COMMENT ON TABLE tiempo.jornada_asignada IS
  'Qué jornada tuvo una persona, con vigencia. normal/flexible siguen el patrón semanal y '
  'registran marca; de_confianza no pasa por terminal, no maneja horas extra ni banco de horas, '
  'sólo primas dominical/festivo cuando aplique. vigente_hasta NULL = vigente actual; el '
  'traslape entre vigencias de la misma persona se valida en la aplicación, no con EXCLUDE '
  '(SCJ-DEC-04, Opción A).';
COMMENT ON COLUMN tiempo.jornada_asignada.horas_semanales_calculadas IS
  'Derivado de patron_semanal — se recalcula al modificar el patrón. No es fuente de verdad.';
COMMENT ON COLUMN tiempo.jornada_asignada.genera_alerta_horario IS
  'SCJ-PRO-09. true para normal (alerta si llega tarde o se pasa de hora contra patron_semanal '
  'exacto); false para flexible/de_confianza (sólo importa el total de horas, no el horario '
  'exacto). La app lo fija según tipo_jornada al crear la fila — regla de negocio en un campo, '
  'no comparación de tipo_jornada regada por el código (SCJ-ESP-01 §VI.9).';

CREATE TABLE tiempo.patron_semanal (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jornada_asignada_id    bigint NOT NULL REFERENCES tiempo.jornada_asignada (id),
  dia_semana             varchar(10) NOT NULL,
  hora_entrada           time NOT NULL,
  hora_salida            time NOT NULL,
  minutos_comida         int NOT NULL DEFAULT 0,
  horas_efectivas        numeric(5,2),
  CONSTRAINT ck_patron_semanal_dia_semana CHECK (dia_semana IN
    ('lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo')),
  CONSTRAINT ck_patron_semanal_horario CHECK (hora_salida > hora_entrada)
);

COMMENT ON TABLE tiempo.patron_semanal IS
  'Qué días, con qué horario y con qué pausa de comida. Admite jornada partida vía varias filas '
  'del mismo día_semana con distinto horario si hace falta (no restringido a una fila por día).';
COMMENT ON COLUMN tiempo.patron_semanal.horas_efectivas IS
  'Derivado: (hora_salida - hora_entrada) - minutos_comida. No es fuente de verdad.';

-- SCJ-PRO-09: tope legal al asignar jornada. CONSTRAINT TRIGGER, no CHECK — un CHECK no puede
-- hacer agregado entre filas ni consultar otra tabla. DEFERRABLE INITIALLY DEFERRED: se evalúa una
-- sola vez al final de la transacción, no fila por fila (patron_semanal se inserta como N filas
-- para una misma jornada_asignada; validar por fila reventaría con la primera aunque la suma final
-- sea válida). Recalcula horas desde hora_entrada/hora_salida/minutos_comida en vez de confiar en
-- horas_efectivas (columna derivada, "no es fuente de verdad" — no sirve para una validación de
-- cumplimiento legal). Sólo aplica a tipo_jornada='normal' — flexible/de_confianza no tienen
-- jornada fija que sumar contra un tope (SCJ-ESP-01 §VI.4). Refuerza en la base lo que la app ya
-- valida antes de enviar, porque cualquiera con la anon key puede pegarle directo a PostgREST
-- (mismo hallazgo que 31_personas_rls_permiso_especifico.sql) — esto es cumplimiento legal, no una
-- comodidad de UX.
CREATE FUNCTION tiempo.fn_patron_semanal_valida_tope_legal()
RETURNS trigger AS $$
DECLARE
  v_tipo_jornada  varchar(20);
  v_vigente_desde date;
  v_suma_horas    numeric(8,2);
  v_maximo        numeric;
BEGIN
  SELECT tipo_jornada, vigente_desde INTO v_tipo_jornada, v_vigente_desde
    FROM tiempo.jornada_asignada
    WHERE id = NEW.jornada_asignada_id;

  IF v_tipo_jornada IS DISTINCT FROM 'normal' THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(SUM(
    EXTRACT(EPOCH FROM (ps.hora_salida - ps.hora_entrada)) / 3600.0 - (ps.minutos_comida / 60.0)
  ), 0) INTO v_suma_horas
  FROM tiempo.patron_semanal ps
  WHERE ps.jornada_asignada_id = NEW.jornada_asignada_id;

  SELECT tl.maximo_semanal INTO v_maximo
  FROM tiempo.tope_legal tl
  WHERE tl.vigente_desde <= v_vigente_desde
    AND (tl.vigente_hasta IS NULL OR tl.vigente_hasta >= v_vigente_desde)
  ORDER BY tl.vigente_desde DESC
  LIMIT 1;

  IF v_maximo IS NOT NULL AND v_suma_horas > v_maximo THEN
    RAISE EXCEPTION
      'jornada_asignada % (tipo normal, vigente_desde %) suma % horas semanales — se pasa del '
      'tope legal vigente (% h)', NEW.jornada_asignada_id, v_vigente_desde, v_suma_horas, v_maximo;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_patron_semanal_valida_tope_legal
  AFTER INSERT OR UPDATE ON tiempo.patron_semanal
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_patron_semanal_valida_tope_legal();

COMMENT ON FUNCTION tiempo.fn_patron_semanal_valida_tope_legal() IS
  'SCJ-PRO-09. Suma las horas reales del patrón semanal completo de la jornada y la compara contra '
  'tope_legal.maximo_semanal vigente en jornada_asignada.vigente_desde. Sólo revienta para '
  'tipo_jornada=normal. DEFERRABLE INITIALLY DEFERRED para no fallar a medio insertar las filas '
  'del patrón.';

-- ============================================================================
-- Marca, día, tramo
-- ============================================================================

CREATE TABLE tiempo.marca (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  evento_id            uuid NOT NULL DEFAULT gen_random_uuid(),
  persona_id           uuid NOT NULL REFERENCES tiempo.persona (id),
  terminal_id          varchar(32) NOT NULL,
  secuencia_local      bigint,
  momento_dispositivo  timestamptz NOT NULL,
  desfase_local        varchar(6) NOT NULL,
  momento_recepcion    timestamptz NOT NULL DEFAULT now(),
  estado_reloj         varchar(20) NOT NULL,
  version_software     varchar(16) NOT NULL,
  origen               varchar(20) NOT NULL,
  requiere_revision    boolean NOT NULL DEFAULT false,
  CONSTRAINT uq_marca_evento_id UNIQUE (evento_id),
  CONSTRAINT ck_marca_origen CHECK (origen IN ('terminal', 'captura_manual')),
  CONSTRAINT ck_marca_estado_reloj
    CHECK (estado_reloj IN ('sincronizado', 'deriva', 'sin_sincronizar')),
  CONSTRAINT ck_marca_desfase_local CHECK (desfase_local ~ '^[+-][0-9]{2}:[0-9]{2}$'),
  CONSTRAINT ck_marca_secuencia_solo_terminal
    CHECK ((origen = 'terminal') = (secuencia_local IS NOT NULL))
);

CREATE UNIQUE INDEX uq_marca_terminal_secuencia
  ON tiempo.marca (terminal_id, secuencia_local)
  WHERE origen = 'terminal';

COMMENT ON TABLE tiempo.marca IS
  'Evento crudo producido por el terminal o por captura manual. Inmutable — ningún flujo de la '
  'aplicación emite UPDATE ni DELETE sobre esta tabla, sólo INSERT. Cualquier corrección pasa por '
  'tiempo.correccion (SCJ-DEC-03). Nunca guarda huella ni plantilla biométrica — sólo el '
  'identificador ya resuelto a persona_id. Nombres y campos cerrados por SCJ-CDT-01 §IV/§V, sin '
  'excepción.';
COMMENT ON COLUMN tiempo.marca.evento_id IS
  'Llave de negocio para idempotencia global de reintentos de envío. Nace en el origen (terminal o '
  'al abrir el formulario de captura manual), nunca en el servidor. No es la PK física, por '
  'decisión confirmada — ver SCJ-DEC-08, Opción B.';
COMMENT ON COLUMN tiempo.marca.terminal_id IS
  'Identifica el aparato o, en captura manual, el punto de captura (SCJ-ESP-01 §VII.1). No es un '
  'FK físico — el módulo de Equipos aún no existe (mismo patrón que tiempo.persona).';
COMMENT ON COLUMN tiempo.marca.secuencia_local IS
  'Contador del terminal, nulo salvo origen = terminal. Sirve para detectar huecos: si llegan 1, '
  '2 y 4, se perdió la 3. Ver SCJ-DEC-09.';
COMMENT ON COLUMN tiempo.marca.desfase_local IS
  'Desfase respecto de UTC vigente en el instante de momento_dispositivo, formato ±HH:MM. Junto '
  'con momento_dispositivo permite reconstruir la hora local sin almacenarla — SCJ-ESP-01 §VII.3.';
COMMENT ON COLUMN tiempo.marca.momento_recepcion IS
  'Cuándo llegó al servidor. Nunca se usa para calcular jornada — sólo mide retraso de '
  'sincronización (SCJ-CDT-01 §V.4).';
COMMENT ON COLUMN tiempo.marca.estado_reloj IS
  'Estado del reloj del origen en el momento exacto de esta marca, reportado por el propio '
  'dispositivo — no se deriva aquí. En captura_manual siempre sincronizado: la toma el reloj del '
  'servidor al capturar.';
COMMENT ON COLUMN tiempo.marca.version_software IS
  'Versión del software que generó el evento — del firmware del terminal, o de la aplicación web '
  'en captura_manual.';
COMMENT ON COLUMN tiempo.marca.origen IS
  'terminal: identificación biométrica en el aparato. captura_manual: formulario asistido por '
  'usuario aprobado (SCJ-ESP-01 §IV.2) — vía ordinaria y permanente, no una excepción; no existe '
  'un tercer valor.';
COMMENT ON COLUMN tiempo.marca.requiere_revision IS
  'Bandera rápida, calculada como estado_reloj <> ''sincronizado'' salvo que un proceso posterior '
  'la levante por otra razón. El detalle y el ciclo de vida de la revisión viven en '
  'tiempo.excepcion (SCJ-DEC-07).';

CREATE TABLE tiempo.dia (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  persona_id      uuid NOT NULL REFERENCES tiempo.persona (id),
  fecha           date NOT NULL,
  estado          varchar(20) NOT NULL DEFAULT 'abierto',
  horas_totales   numeric(5,2),
  origen          varchar(20),
  CONSTRAINT uq_dia_persona_fecha UNIQUE (persona_id, fecha),
  CONSTRAINT ck_dia_estado CHECK (estado IN ('abierto', 'cerrado', 'bloqueado', 'revisado')),
  CONSTRAINT ck_dia_origen
    CHECK (origen IS NULL OR origen IN ('automatico_confianza', 'ausencia_autorizada'))
);

COMMENT ON TABLE tiempo.dia IS
  'Marcas de una persona en una fecha, con estado. Entidad materializada, no vista — el bloqueo '
  'es una decisión que sobrevive a marcas tardías (SCJ-DEC-06). bloqueado pasa a revisado cuando '
  'RH lo revisa; nunca vuelve a cerrado automáticamente.';
COMMENT ON COLUMN tiempo.dia.horas_totales IS
  'Derivado de la suma de tramo.minutos_trabajados del día. No es fuente de verdad.';
COMMENT ON COLUMN tiempo.dia.origen IS
  'NULL para jornada normal/flexible cuando el día nace de marcas reales. automatico_confianza '
  'para jornada de_confianza, que no pasa por terminal — un proceso por lotes crea el día directo, '
  'sin marca ni tramo sintéticos (contaminarían marca como evidencia de jornada). '
  'ausencia_autorizada cuando el batch de cierre resuelve el día contra una ausencia en vez de '
  'marcas (SCJ-PRO-12) — corregido 2026-09-05: el CHECK traía "terminal" por error, un valor que '
  'nunca se usó (el caso de marcas reales siempre fue NULL, no "terminal").';

CREATE TABLE tiempo.tramo (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dia_id              bigint NOT NULL REFERENCES tiempo.dia (id),
  marca_apertura_id   bigint NOT NULL REFERENCES tiempo.marca (id),
  marca_cierre_id     bigint REFERENCES tiempo.marca (id),
  inicio              timestamptz NOT NULL,
  fin                 timestamptz,
  minutos_trabajados  numeric(6,2),
  CONSTRAINT uq_tramo_marca_apertura UNIQUE (marca_apertura_id),
  CONSTRAINT uq_tramo_marca_cierre UNIQUE (marca_cierre_id),
  CONSTRAINT ck_tramo_fin_posterior_a_inicio CHECK (fin IS NULL OR fin > inicio)
);

COMMENT ON TABLE tiempo.tramo IS
  'Par de marcas: la impar abre, la par cierra. marca_cierre_id nulo es un tramo abierto (día con '
  'número impar de marcas) — no es un error de restricción, es un dato que el proceso de cierre '
  'usa para decidir el estado de tiempo.dia. Ver SCJ-ESP-01 §VI.1 y SCJ-DEC-01.';
COMMENT ON COLUMN tiempo.tramo.minutos_trabajados IS
  'Derivado de fin - inicio. Nulo mientras el tramo esté abierto. No es fuente de verdad.';

CREATE TABLE tiempo.clasificacion_de_tiempo (
  id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tramo_id  bigint NOT NULL REFERENCES tiempo.tramo (id),
  tipo      varchar(20),
  CONSTRAINT uq_clasificacion_de_tiempo_tramo UNIQUE (tramo_id),
  CONSTRAINT ck_clasificacion_de_tiempo_tipo
    CHECK (tipo IS NULL OR tipo IN ('ordinario', 'reposicion', 'extra'))
);

COMMENT ON TABLE tiempo.clasificacion_de_tiempo IS
  'Ordinario, reposición o extra, sobre un tramo — cronológica y acumulada dentro del periodo '
  'quincenal, nunca por día ni por proporción; el mismo tramo nunca se parte entre dos '
  'clasificaciones. tipo lo calcula el batch de corte quincenal (SCJ-PRO-13), no un trigger de '
  'esta base: recorre los tramos del periodo en orden acumulando contra horas_esperadas '
  '(patron_semanal vigente, excluye domingo/festivo/bloqueado) — ordinario mientras no rebase lo '
  'esperado, reposición mientras haya deuda previa en banco_de_horas, extra una vez agotada esa '
  'deuda. No compara contra tope_legal — ese valor sólo topa la jornada al asignarla '
  '(trg_patron_semanal_valida_tope_legal), no participa en esta clasificación.';

-- ============================================================================
-- Banco de horas
-- ============================================================================

CREATE TABLE tiempo.banco_de_horas (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  persona_id       uuid NOT NULL REFERENCES tiempo.persona (id),
  monto            numeric(8,2) NOT NULL DEFAULT 0,
  vivo_desde       timestamptz,
  actualizado_en   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_banco_de_horas_persona UNIQUE (persona_id)
);

COMMENT ON TABLE tiempo.banco_de_horas IS
  'Deuda de horas acumulada de una persona. monto y vivo_desde nunca se escriben con UPDATE '
  'directo — sólo el disparador que reacciona a tiempo.movimiento_de_saldo los recalcula. Ver '
  'SCJ-DEC-02.';
COMMENT ON COLUMN tiempo.banco_de_horas.vivo_desde IS
  'Fecha del movimiento que llevó monto de 0 a positivo por última vez. NULL cuando monto = 0. '
  'Permite evaluar los umbrales de SCJ-ESP-01 §VI.6 (aviso al 100%, escalamiento al 200%, cuarto '
  'mes con saldo vivo) sin recorrer el histórico de movimientos en cada consulta.';

CREATE TABLE tiempo.movimiento_de_saldo (
  id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  banco_de_horas_id           bigint NOT NULL REFERENCES tiempo.banco_de_horas (id),
  clasificacion_de_tiempo_id  bigint REFERENCES tiempo.clasificacion_de_tiempo (id),
  tipo                        varchar(20) NOT NULL,
  monto                       numeric(8,2) NOT NULL,
  motivo                      text,
  autor_id                    uuid REFERENCES tiempo.persona (id),
  creado_en                   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_movimiento_de_saldo_tipo CHECK (tipo IN
    ('generado_quincena', 'cubrir', 'arrastrar', 'descontar', 'condonar'))
);

COMMENT ON TABLE tiempo.movimiento_de_saldo IS
  'Libro de movimientos del banco de horas — única fuente de verdad, banco_de_horas.monto es '
  'caché derivado. Ver SCJ-DEC-02.';
COMMENT ON COLUMN tiempo.movimiento_de_saldo.tipo IS
  'generado_quincena: +monto, automático al corte quincenal, sólo si horas_esperadas > '
  'horas_trabajadas (nunca genera saldo a favor). cubrir: -monto, automático desde una '
  'clasificacion_de_tiempo tipo reposicion. arrastrar: 0, pasa el saldo vivo al siguiente bloque '
  'semestral, manual RH. descontar/condonar: -monto, cancelan a cero, manual Dirección + RH.';
COMMENT ON COLUMN tiempo.movimiento_de_saldo.autor_id IS
  'NULL cuando el movimiento lo genera el sistema (generado_quincena, cubrir automático desde '
  'reposición). No nulo para arrastrar/descontar/condonar, siempre decisión humana.';

-- ============================================================================
-- Correcciones, ausencias, excepciones
-- ============================================================================

CREATE TABLE tiempo.correccion (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  marca_id              bigint NOT NULL REFERENCES tiempo.marca (id),
  valor_corregido       timestamptz NOT NULL,
  motivo                text NOT NULL,
  autor_id              uuid NOT NULL REFERENCES tiempo.persona (id),
  creado_en             timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE tiempo.correccion IS
  'Registro nuevo que apunta a una marca anterior — nunca se sobrescribe momento_dispositivo. Ver '
  'SCJ-DEC-03. Siempre lleva autor: una corrección es, por definición, una decisión humana tras '
  'revisar una excepción.';
COMMENT ON COLUMN tiempo.correccion.valor_corregido IS
  'Asume que sólo se corrige momento_dispositivo (encaja con el caso de uso real: reloj no '
  'sincronizado detectado, RH corrige la hora tras revisar). persona_id no se corrige aquí — el '
  'identificador biométrico ya resuelto es dato único y confiable, no un valor a ajustar.';

-- SCJ-PRO-10: una marca sólo se corrige resolviendo una excepcion — sin eso el sistema no tiene '
-- forma de saber que esa marca necesitaba revisión. La corrección tampoco puede alterar el orden
-- cronológico de las marcas de la persona (rompería qué marca abre/cierra cada tramo) — se
-- calcula contra el momento_dispositivo efectivo de las marcas vecinas (la última corrección si
-- existe, si no el original). La ventana de 30 días hábiles (tiempo.parametro
-- dias_habiles_correccion_marca) se valida en la aplicación, no aquí — política de proceso, no
-- integridad estructural, a diferencia de esto.
CREATE FUNCTION tiempo.fn_correccion_valida()
RETURNS trigger AS $$
DECLARE
  v_persona_id      uuid;
  v_efectivo_actual timestamptz;
  v_efectivo_prev   timestamptz;
  v_efectivo_next   timestamptz;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tiempo.excepcion WHERE marca_id = NEW.marca_id) THEN
    RAISE EXCEPTION
      'La marca % no tiene ninguna excepcion asociada — no se puede corregir sin pasar antes por '
      'la cola de excepciones (SCJ-PRO-10)', NEW.marca_id;
  END IF;

  SELECT persona_id INTO v_persona_id FROM tiempo.marca WHERE id = NEW.marca_id;

  SELECT COALESCE(
    (SELECT c.valor_corregido FROM tiempo.correccion c
       WHERE c.marca_id = NEW.marca_id ORDER BY c.creado_en DESC LIMIT 1),
    m.momento_dispositivo
  ) INTO v_efectivo_actual
  FROM tiempo.marca m WHERE m.id = NEW.marca_id;

  SELECT MAX(efectivo) INTO v_efectivo_prev
  FROM (
    SELECT COALESCE(
      (SELECT c.valor_corregido FROM tiempo.correccion c
         WHERE c.marca_id = m.id ORDER BY c.creado_en DESC LIMIT 1),
      m.momento_dispositivo
    ) AS efectivo
    FROM tiempo.marca m
    WHERE m.persona_id = v_persona_id AND m.id <> NEW.marca_id
  ) vecinas
  WHERE efectivo < v_efectivo_actual;

  SELECT MIN(efectivo) INTO v_efectivo_next
  FROM (
    SELECT COALESCE(
      (SELECT c.valor_corregido FROM tiempo.correccion c
         WHERE c.marca_id = m.id ORDER BY c.creado_en DESC LIMIT 1),
      m.momento_dispositivo
    ) AS efectivo
    FROM tiempo.marca m
    WHERE m.persona_id = v_persona_id AND m.id <> NEW.marca_id
  ) vecinas
  WHERE efectivo > v_efectivo_actual;

  IF v_efectivo_prev IS NOT NULL AND NEW.valor_corregido <= v_efectivo_prev THEN
    RAISE EXCEPTION
      'La corrección de la marca % rompería el orden cronológico: % no es posterior a la marca '
      'anterior de la misma persona (%)', NEW.marca_id, NEW.valor_corregido, v_efectivo_prev;
  END IF;

  IF v_efectivo_next IS NOT NULL AND NEW.valor_corregido >= v_efectivo_next THEN
    RAISE EXCEPTION
      'La corrección de la marca % rompería el orden cronológico: % no es anterior a la marca '
      'siguiente de la misma persona (%)', NEW.marca_id, NEW.valor_corregido, v_efectivo_next;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_correccion_valida
  BEFORE INSERT ON tiempo.correccion
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_correccion_valida();

COMMENT ON FUNCTION tiempo.fn_correccion_valida() IS
  'SCJ-PRO-10. Exige que la marca ya tenga una excepcion (cualquier estado) y bloquea toda '
  'corrección que dejaría el valor corregido fuera del hueco entre la marca anterior y la '
  'siguiente de la misma persona — la corrección ajusta la hora, nunca el orden.';

-- SCJ-PRO-10: al aceptarse la corrección, se recalcula sólo el tramo que involucra a esta marca
-- (nunca el histórico completo) y el total del día. Si la marca todavía no forma parte de ningún
-- tramo (día sin cerrar), no hay nada que recalcular todavía. También cierra sola la excepcion
-- pendiente asociada — mismo patrón que trg_ausencia_resuelve_excepcion.
CREATE FUNCTION tiempo.fn_correccion_recalcula_tramo()
RETURNS trigger AS $$
DECLARE
  v_dia_id bigint;
BEGIN
  UPDATE tiempo.excepcion
  SET estado = 'resuelto'
  WHERE marca_id = NEW.marca_id AND estado = 'pendiente';

  UPDATE tiempo.tramo t
  SET inicio = CASE WHEN t.marca_apertura_id = NEW.marca_id
                     THEN NEW.valor_corregido ELSE t.inicio END,
      fin    = CASE WHEN t.marca_cierre_id = NEW.marca_id
                     THEN NEW.valor_corregido ELSE t.fin END,
      minutos_trabajados = CASE
        WHEN (CASE WHEN t.marca_cierre_id = NEW.marca_id
                    THEN NEW.valor_corregido ELSE t.fin END) IS NOT NULL
        THEN EXTRACT(EPOCH FROM (
               (CASE WHEN t.marca_cierre_id = NEW.marca_id
                      THEN NEW.valor_corregido ELSE t.fin END)
               - (CASE WHEN t.marca_apertura_id = NEW.marca_id
                        THEN NEW.valor_corregido ELSE t.inicio END)
             )) / 60.0
        ELSE NULL
      END
  WHERE t.marca_apertura_id = NEW.marca_id OR t.marca_cierre_id = NEW.marca_id
  RETURNING t.dia_id INTO v_dia_id;

  IF v_dia_id IS NOT NULL THEN
    UPDATE tiempo.dia d
    SET horas_totales = (
      SELECT COALESCE(SUM(t2.minutos_trabajados), 0) / 60.0
      FROM tiempo.tramo t2
      WHERE t2.dia_id = v_dia_id
    )
    WHERE d.id = v_dia_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_correccion_recalcula_tramo
  AFTER INSERT ON tiempo.correccion
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_correccion_recalcula_tramo();

COMMENT ON FUNCTION tiempo.fn_correccion_recalcula_tramo() IS
  'SCJ-PRO-10. Recalcula únicamente el tramo (y el horas_totales del día) que involucra a la '
  'marca corregida — nunca el histórico completo. Cierra sola la excepcion pendiente asociada, '
  'mismo patrón que trg_ausencia_resuelve_excepcion.';

CREATE TABLE tiempo.ausencia (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  persona_id             uuid NOT NULL REFERENCES tiempo.persona (id),
  tipo_de_ausencia       varchar(30) NOT NULL,
  fecha_inicio           date NOT NULL,
  fecha_fin              date NOT NULL,
  estado_autorizacion    varchar(20) NOT NULL DEFAULT 'pendiente',
  documento_ref          varchar(50),
  CONSTRAINT ck_ausencia_tipo CHECK (tipo_de_ausencia IN
    ('vacaciones', 'permiso_con_goce', 'permiso_sin_goce', 'incapacidad', 'falta')),
  CONSTRAINT ck_ausencia_estado_autorizacion
    CHECK (estado_autorizacion IN ('pendiente', 'autorizada', 'rechazada')),
  CONSTRAINT ck_ausencia_fechas CHECK (fecha_fin >= fecha_inicio)
);

COMMENT ON TABLE tiempo.ausencia IS
  'Periodo no trabajado, con naturaleza y autorización. tipo_de_ausencia usa el enumerado ya '
  'documentado en SCJ-DIC-01 §III.';
COMMENT ON COLUMN tiempo.ausencia.estado_autorizacion IS
  'Materializado de sólo lectura — resumen de tiempo.aprobacion_ausencia, escrito únicamente por '
  'trigger (mismo patrón que tiempo.banco_de_horas, SCJ-DEC-02). Fuente de verdad real: la cadena '
  'de pasos en aprobacion_ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), '
  'Opción C.';
COMMENT ON COLUMN tiempo.ausencia.documento_ref IS
  'Evidencia cargada y conservada — SCJ-ESP-01 exige que una falta justificada la tenga antes de '
  'pagarse. NULL admitido: vacaciones/incapacidad pueden no requerir documento propio si ya '
  'consta en otro expediente.';

CREATE TABLE tiempo.aprobacion_ausencia (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ausencia_id    bigint NOT NULL REFERENCES tiempo.ausencia (id),
  numero_paso    smallint NOT NULL,
  aprobador_id   uuid NOT NULL REFERENCES tiempo.persona (id),
  decision       varchar(20) NOT NULL DEFAULT 'pendiente',
  motivo         text,
  decidido_en    timestamptz,
  CONSTRAINT uq_aprobacion_ausencia_paso UNIQUE (ausencia_id, numero_paso),
  CONSTRAINT ck_aprobacion_ausencia_decision
    CHECK (decision IN ('pendiente', 'autorizada', 'rechazada')),
  CONSTRAINT ck_aprobacion_ausencia_decidido
    CHECK ((decision = 'pendiente') = (decidido_en IS NULL))
);

COMMENT ON TABLE tiempo.aprobacion_ausencia IS
  'Cadena de aprobación de una ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), '
  'Opción C. La aplicación resuelve quién aprueba cada paso consultando personas.puesto_permiso/'
  'asignacion (permiso atómico de autorización, heredable jerárquicamente) en el momento de crear '
  'la ausencia, e inserta una fila pendiente por paso — no hay tabla de "definición de flujo" ni '
  '"instancia" en Tiempo, sólo el registro de lo ya resuelto. Un rechazo en cualquier paso detiene '
  'la cadena.';
COMMENT ON COLUMN tiempo.aprobacion_ausencia.aprobador_id IS
  'Persona específica congelada al crear la solicitud, no un rol. Si el permiso cambia de dueño '
  'mientras la ausencia sigue pendiente, este renglón no se recalcula (SCJ-DEC-05, misma lógica '
  'que SCJ-DEC-04).';

CREATE FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia()
RETURNS trigger AS $$
DECLARE
  v_total     int;
  v_autorizadas int;
  v_rechazadas  int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE decision = 'autorizada'),
         count(*) FILTER (WHERE decision = 'rechazada')
    INTO v_total, v_autorizadas, v_rechazadas
    FROM tiempo.aprobacion_ausencia
    WHERE ausencia_id = NEW.ausencia_id;

  UPDATE tiempo.ausencia
     SET estado_autorizacion = CASE
           WHEN v_rechazadas > 0 THEN 'rechazada'
           WHEN v_autorizadas = v_total THEN 'autorizada'
           ELSE 'pendiente'
         END
   WHERE id = NEW.ausencia_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_aprobacion_ausencia_actualiza_ausencia
  AFTER INSERT OR UPDATE OF decision ON tiempo.aprobacion_ausencia
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia();

COMMENT ON FUNCTION tiempo.fn_aprobacion_ausencia_actualiza_ausencia() IS
  'Recalcula ausencia.estado_autorizacion desde su cadena de pasos: cualquier rechazo cierra en '
  '''rechazada''; todos los pasos en ''autorizada'' cierra en ''autorizada''; cualquier otro caso '
  'se queda ''pendiente''.';

CREATE TABLE tiempo.excepcion (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  marca_id          bigint REFERENCES tiempo.marca (id),
  dia_id            bigint REFERENCES tiempo.dia (id),
  motivo_revision   text NOT NULL,
  estado            varchar(20) NOT NULL DEFAULT 'pendiente',
  creado_en         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_excepcion_estado CHECK (estado IN ('pendiente', 'resuelto')),
  CONSTRAINT ck_excepcion_marca_o_dia
    CHECK ((marca_id IS NOT NULL) <> (dia_id IS NOT NULL))
);

COMMENT ON TABLE tiempo.excepcion IS
  'Marca o día apartado para revisión humana — nunca ambos, nunca ninguno '
  '(ck_excepcion_marca_o_dia). Ver SCJ-DEC-07. Casos: reloj no sincronizado (marca_id), día sin '
  'checada y sin ausencia que lo justifique (dia_id), jornada ordinaria en domingo/festivo sin '
  'autorización previa (dia_id).';

-- ============================================================================
-- Orquestación de batches
-- ============================================================================

-- SCJ-PRO-12. Una fila por (tipo_batch, fecha) — el job programado y el botón manual escriben la
-- misma fila: reintentar o reprocesar es re-invocar el batch completo (es idempotente por persona,
-- ver SCJ-PRO-12 §V) y hacer UPSERT aquí, incrementando intentos. No tiene FK a ninguna otra
-- entidad — agrupa por tipo_batch/fecha, no por persona.
CREATE TABLE tiempo.corrida_batch (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tipo_batch     varchar(20) NOT NULL,
  fecha          date NOT NULL,
  estado         varchar(20) NOT NULL DEFAULT 'en_progreso',
  intentos       smallint NOT NULL DEFAULT 1,
  iniciado_en    timestamptz NOT NULL DEFAULT now(),
  terminado_en   timestamptz,
  detalle        text,
  CONSTRAINT uq_corrida_batch_tipo_fecha UNIQUE (tipo_batch, fecha),
  CONSTRAINT ck_corrida_batch_tipo
    CHECK (tipo_batch IN ('cierre_dia', 'corte_quincenal', 'de_confianza')),
  CONSTRAINT ck_corrida_batch_estado
    CHECK (estado IN ('en_progreso', 'exitosa', 'fallida')),
  CONSTRAINT ck_corrida_batch_terminado
    CHECK ((estado = 'en_progreso') = (terminado_en IS NULL))
);

COMMENT ON TABLE tiempo.corrida_batch IS
  'Estado visible de cada corrida de batch — de dónde lee la app "última corrida: exitosa/'
  'fallida, N pendientes" (SCJ-PRO-12). El job automático y el botón manual son la misma '
  'invocación; reintentar es re-ejecutar el batch (idempotente por persona) e incrementar '
  '''intentos'' en la misma fila via UPSERT sobre (tipo_batch, fecha).';
COMMENT ON COLUMN tiempo.corrida_batch.detalle IS
  'Resumen legible del resultado — ej. qué personas quedaron pendientes tras 3 intentos. No '
  'reemplaza logs, es para que RH/Dirección vea el estado sin entrar a Supabase.';

-- ============================================================================
-- Disparadores
-- ============================================================================

-- SCJ-PRO-11: 4 de los 5 motivos de revisión se calculan aquí, en un solo AFTER INSERT sobre
-- tiempo.marca, sin importar el origen (terminal o captura_manual — para captura_manual nunca
-- disparan por construcción: estado_reloj siempre 'sincronizado', y persona_inactiva/fuera_de_
-- horario/dia_cerrado pueden aplicar igual). El quinto, plantilla_desconocida, nace en Operación
-- (fuera de este repositorio) y sólo tendría sentido para una marca que tardó en resolverse ahí —
-- no se calcula en Tiempo. SECURITY DEFINER porque el checador (rol terminal_checador, ver
-- 37_tiempo_rls_terminal.sql) sólo tiene GRANT de INSERT en tiempo.marca — sin esto necesitaría
-- lectura directa de personas.persona y varias tablas de tiempo, mucho más de lo que su alcance
-- de seguridad debe tener. search_path fijo por la misma razón que cualquier SECURITY DEFINER:
-- evita que alguien cuelgue un objeto con el mismo nombre en un esquema anterior en el path.
CREATE FUNCTION tiempo.fn_marca_valida_revision()
RETURNS trigger
SECURITY DEFINER
SET search_path = tiempo, personas, pg_temp
AS $$
DECLARE
  v_persona_activa  boolean;
  v_dia_estado      varchar(20);
  v_momento_local   timestamp;
  v_fecha_local     date;
  v_hora_local      time;
  v_dia_semana      varchar(10);
  v_jornada_id      bigint;
  v_tolerancia_min  int;
  v_dentro_horario  boolean;
BEGIN
  -- reloj_no_sincronizado: el origen ya lo reporta, no se deriva aquí.
  IF NEW.estado_reloj <> 'sincronizado' THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'reloj_no_sincronizado');
  END IF;

  -- persona_inactiva: respaldo del lado servidor. El terminal ya filtra esto contra su caché
  -- local (sincronizada cada noche) y no debería llegar a mandar la marca — esto cubre el hueco
  -- entre sincronizaciones, o cualquier otro origen que no filtre.
  SELECT (estado = 'activo') INTO v_persona_activa
  FROM personas.persona WHERE id = NEW.persona_id;
  IF v_persona_activa IS NOT TRUE THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'persona_inactiva');
  END IF;

  -- Hora y fecha local reconstruidas — nunca se almacenan, SCJ-ESP-01 §VII.3.
  v_momento_local := (NEW.momento_dispositivo AT TIME ZONE 'UTC') + (NEW.desfase_local)::interval;
  v_fecha_local := v_momento_local::date;
  v_hora_local := v_momento_local::time;

  -- dia_cerrado: marca tardía sobre un día ya no abierto. Nunca lo reabre, sólo se señala
  -- (SCJ-ESP-01 §VI.2, confirmado 2026-09-05: "no se reabre" significa que no dispara recálculo,
  -- no que la marca se rechace — la evidencia nunca se descarta, SCJ-CDT-01 §II.5).
  SELECT estado INTO v_dia_estado
  FROM tiempo.dia WHERE persona_id = NEW.persona_id AND fecha = v_fecha_local;
  IF v_dia_estado IS NOT NULL AND v_dia_estado <> 'abierto' THEN
    INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'dia_cerrado');
  END IF;

  -- fuera_de_horario: contra el patrón semanal vigente de esa fecha, con tolerancia de retardo.
  -- Si la persona no tiene jornada vigente ese día, no se evalúa aquí — eso es un problema de
  -- asignación de jornada, no de esta marca. Si sí tiene jornada vigente pero ese día de la
  -- semana no tiene fila en patron_semanal, SÍ se evalúa: el EXISTS de abajo da false (no hay
  -- ninguna fila con la que comparar) y eso marca fuera_de_horario, correctamente -- fichar un día
  -- que el patrón no contempla es justo el caso que este motivo debe señalar.
  SELECT ja.id INTO v_jornada_id
  FROM tiempo.jornada_asignada ja
  WHERE ja.persona_id = NEW.persona_id
    AND ja.vigente_desde <= v_fecha_local
    AND (ja.vigente_hasta IS NULL OR ja.vigente_hasta >= v_fecha_local)
  ORDER BY ja.vigente_desde DESC
  LIMIT 1;

  IF v_jornada_id IS NOT NULL THEN
    v_dia_semana := (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                    [EXTRACT(ISODOW FROM v_momento_local)::int];

    SELECT COALESCE(valor::int, 0) INTO v_tolerancia_min
    FROM tiempo.parametro
    WHERE clave = 'tolerancia_retardo_min' AND vigente_desde <= v_fecha_local
    ORDER BY vigente_desde DESC LIMIT 1;

    SELECT EXISTS (
      SELECT 1 FROM tiempo.patron_semanal ps
      WHERE ps.jornada_asignada_id = v_jornada_id
        AND ps.dia_semana = v_dia_semana
        AND v_hora_local BETWEEN (ps.hora_entrada - make_interval(mins => v_tolerancia_min))
                              AND (ps.hora_salida  + make_interval(mins => v_tolerancia_min))
    ) INTO v_dentro_horario;

    IF NOT v_dentro_horario THEN
      INSERT INTO tiempo.excepcion (marca_id, motivo_revision) VALUES (NEW.id, 'fuera_de_horario');
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM tiempo.excepcion WHERE marca_id = NEW.id) THEN
    UPDATE tiempo.marca SET requiere_revision = true WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_marca_valida_revision
  AFTER INSERT ON tiempo.marca
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_marca_valida_revision();

COMMENT ON FUNCTION tiempo.fn_marca_valida_revision() IS
  'SCJ-PRO-11. Calcula reloj_no_sincronizado, persona_inactiva, dia_cerrado y fuera_de_horario al '
  'llegar una marca — el quinto motivo, plantilla_desconocida, nace en Operación y no se calcula '
  'aquí. SECURITY DEFINER: terminal_checador sólo tiene INSERT en tiempo.marca, esta función '
  'necesita más lectura de la que ese rol debe tener directamente.';

CREATE FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco()
RETURNS trigger AS $$
DECLARE
  v_monto_antes numeric(8,2);
  v_monto_despues numeric(8,2);
BEGIN
  SELECT monto INTO v_monto_antes FROM tiempo.banco_de_horas WHERE id = NEW.banco_de_horas_id;
  v_monto_despues := v_monto_antes + NEW.monto;

  UPDATE tiempo.banco_de_horas
  SET monto = v_monto_despues,
      actualizado_en = NEW.creado_en,
      vivo_desde = CASE
        WHEN v_monto_antes = 0 AND v_monto_despues > 0 THEN NEW.creado_en
        WHEN v_monto_despues = 0 THEN NULL
        ELSE vivo_desde
      END
  WHERE id = NEW.banco_de_horas_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_movimiento_de_saldo_actualiza_banco
  AFTER INSERT ON tiempo.movimiento_de_saldo
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco();

COMMENT ON FUNCTION tiempo.fn_movimiento_de_saldo_actualiza_banco() IS
  'Única vía de escritura de banco_de_horas.monto y .vivo_desde. Ver SCJ-DEC-02.';

CREATE FUNCTION tiempo.fn_ausencia_resuelve_excepcion()
RETURNS trigger AS $$
DECLARE
  v_fecha          date;
  v_jornada_id     bigint;
  v_dia_semana     varchar(10);
  v_horas_totales  numeric(5,2);
BEGIN
  IF NEW.estado_autorizacion NOT IN ('autorizada', 'rechazada') THEN
    RETURN NEW; -- sigue pendiente, no se cierra la excepción ni se materializa el día
  END IF;

  IF NEW.estado_autorizacion = 'autorizada' THEN
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia autorizada, carga tardía'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  ELSE
    UPDATE tiempo.excepcion
    SET estado = 'resuelto',
        motivo_revision = motivo_revision || ' — resuelto por ausencia rechazada (falta injustificada)'
    WHERE estado = 'pendiente'
      AND dia_id IN (
        SELECT d.id FROM tiempo.dia d
        WHERE d.persona_id = NEW.persona_id
          AND d.fecha BETWEEN NEW.fecha_inicio AND NEW.fecha_fin
      );
  END IF;

  -- SCJ-PRO-12 (SCJ-PRA-01 #13): materializa tiempo.dia para cada fecha del rango — sin esto, el
  -- día de una ausencia ya resuelta se queda 'abierto' para siempre, porque el batch de cierre de
  -- día nunca vuelve a tocarlo (ver SCJ-PRO-12 §III, rama G1/G4). ON CONFLICT sólo actualiza si el
  -- día seguía 'abierto' — nunca pisa un día que ya se resolvió por otra vía.
  FOR v_fecha IN
    SELECT generate_series(NEW.fecha_inicio::timestamp, NEW.fecha_fin::timestamp, interval '1 day')::date
  LOOP
    IF NEW.estado_autorizacion = 'autorizada'
       AND NEW.tipo_de_ausencia IN ('vacaciones', 'permiso_con_goce', 'incapacidad') THEN
      -- Neutro: cuenta como si hubiera trabajado la jornada completa pactada ese día.
      SELECT ja.id INTO v_jornada_id
      FROM tiempo.jornada_asignada ja
      WHERE ja.persona_id = NEW.persona_id
        AND ja.vigente_desde <= v_fecha
        AND (ja.vigente_hasta IS NULL OR ja.vigente_hasta >= v_fecha)
      ORDER BY ja.vigente_desde DESC
      LIMIT 1;

      v_dia_semana := (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                      [EXTRACT(ISODOW FROM v_fecha)::int];

      SELECT COALESCE(SUM(
        EXTRACT(EPOCH FROM (ps.hora_salida - ps.hora_entrada)) / 3600.0 - (ps.minutos_comida / 60.0)
      ), 0) INTO v_horas_totales
      FROM tiempo.patron_semanal ps
      WHERE ps.jornada_asignada_id = v_jornada_id AND ps.dia_semana = v_dia_semana;
    ELSE
      -- permiso_sin_goce autorizado, o falta rechazada: no cuenta como trabajado — la deuda la
      -- recoge sola el corte quincenal al comparar horas esperadas contra contabilizadas.
      v_horas_totales := 0;
    END IF;

    INSERT INTO tiempo.dia (persona_id, fecha, estado, horas_totales, origen)
    VALUES (NEW.persona_id, v_fecha, 'cerrado', v_horas_totales, 'ausencia_autorizada')
    ON CONFLICT (persona_id, fecha) DO UPDATE
      SET estado = 'cerrado', horas_totales = EXCLUDED.horas_totales, origen = 'ausencia_autorizada'
      WHERE tiempo.dia.estado = 'abierto';
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ausencia_resuelve_excepcion
  AFTER INSERT OR UPDATE OF estado_autorizacion ON tiempo.ausencia
  FOR EACH ROW
  EXECUTE FUNCTION tiempo.fn_ausencia_resuelve_excepcion();

COMMENT ON FUNCTION tiempo.fn_ausencia_resuelve_excepcion() IS
  'Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion '
  'por día sin checada, la resuelve sola — RH no tiene que cerrarla a mano. Un rechazo también '
  'cuenta como resolución (ya hay una decisión humana, aunque haya sido negativa — corregido '
  '2026-09-05, SCJ-PRO-08: antes sólo reaccionaba a autorizada y una falta rechazada dejaba la '
  'excepción abierta para siempre). Sólo pendiente no toca nada. Además materializa tiempo.dia '
  'para cada fecha del rango (SCJ-PRO-12, SCJ-PRA-01 #13) — vacaciones/permiso_con_goce/'
  'incapacidad cuentan como jornada completa trabajada; permiso_sin_goce y falta rechazada, cero '
  '— la deuda la recoge sola el corte quincenal, esta función nunca escribe en banco_de_horas '
  'directo.';
