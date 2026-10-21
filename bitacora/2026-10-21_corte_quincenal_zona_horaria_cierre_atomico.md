# 2026-10-21 · SCJ-PRO-12/13 — corte quincenal, zona horaria de los batches y cierre del día atómico

**Participantes:** Diego; `orchestrator` con `db`, `backend`, `frontend`, `security` y `raspi-pruebas` (team-orchestrator).
**Duración:** 20 y 21 de octubre de 2026.

---

## Qué se hizo

### 1. Banco de horas con 86 h de deuda falsa (corte del 1 al 15 de octubre)
- **Causas.**
  - El corte ignoraba los días sin tramos (los permisos con goce).
  - `fn_ausencia_resuelve_excepcion` calculaba la jornada neta con el descuento de pausa global, y no con la comida del patrón.
  - La idempotencia del corte dependía de los tramos, así que una segunda corrida habría duplicado la deuda.
- **DDL `118_`–`122_`** (commit `01501d8`, aplicadas por el usuario el 20-oct):
  - **`118_`:** la jornada neta de la ausencia usa `minutos_comida` por fila del patrón.
  - **`119_`:** `tiempo.corte_quincenal_aplicado`, con UNIQUE (persona, periodo_desde); la RPC del corte tiene firma nueva y devuelve bigint.
  - **`120_`:** movimiento `compensacion` con `compensa_movimiento_id`, más el RPC `fn_movimiento_de_saldo_compensar` y el permiso `movimiento_de_saldo_compensar`. Con esto son 54 permisos.
  - **`121_`:** el tipo de ausencia no se puede cambiar una vez resuelta.
  - **`122_`:** nadie resuelve su propia ausencia (SCJ26).
- **Backend** (`fb8d621`):
  - en el corte, un día sin tramos cuenta la jornada esperada solo si lo cubre una ausencia autorizada con goce (vacaciones, permiso con goce o incapacidad); si no, cuenta 0, y `dia.horas_totales` ya no se lee (vector A1 de `security`);
  - corte idempotente por persona y periodo;
  - FIFO de la compensación;
  - de paso, `errores.py` tolera `error.code` entero.
- **Frontend** (`5462bae`):
  - compensación visible en Banco de Horas;
  - «Resolver» desactivado en las ausencias propias.
- **Corrección de datos** (script local fuera del repo, porque tiene uuids reales):
  - 17 días de ausencia recalculados;
  - el movimiento 58 (+86 h) quedó compensado por el 158 (−86 h), con la cuenta de administrador como autora;
  - saldo en 0.00;
  - el periodo quedó registrado como aplicado.

### 2. Inyección de filtros de PostgREST en la búsqueda por nombre (`ed5da96`)
- **Dónde:** `tramos.py`, `dias.py`, `banco_de_horas.py` y `ausencias.py` interpolaban `busqueda_persona` sin sanear dentro de `.or_()`.
- **Riesgo:** con `service_role` (tres de los cuatro), una entrada como `x,curp.like.ABC*` era un oráculo de CURP/RFC/NSS que se saltaba `110_`/`111_`.
- **Arreglo:** `app/busqueda.py` compartido, que también usa `terminales.py`:
  - saneo con lista blanca y normalización NFC;
  - `max_length=100`;
  - si queda vacío tras sanear, responde sin coincidencias y sin consultar;
  - guarda de CI contra ILIKE armados fuera del módulo.
- Revisado por `security`.

### 3. Batches programados en UTC (`7a97c81`)
- **Síntoma:** una marca de las 22:20 del 20-oct salió como «marca tardía · día cerrado».
- **Causa,** confirmada por `raspi-pruebas`, solo leyendo en el Pi:
  - en el contenedor, `/etc/localtime` es `Etc/UTC` y `tzlocal` da UTC;
  - `BackgroundScheduler()` se creaba sin zona;
  - el cron de las 03:00 corría a las 03:00 UTC, es decir a las 21:00 de México del día anterior, y además usaba `date.today()` en UTC.
- **Afectados:** `cierre_dia`, `de_confianza` y `corte_quincenal`.
- **Arreglo:**
  - `app/zona.py`, con `ZONA_MEXICO`, `hoy_mexico()` y `ahora_mexico()`;
  - `BackgroundScheduler(timezone=ZONA_MEXICO)`;
  - toda regla de negocio por día usa la fecha de México;
  - guarda de CI contra `date.today()`/`datetime.now()` sin zona.

### 4. Cierre del día atómico (`124_`) y tiempos de tramo (`123_`)
- **`124_`** (`360175f`, backend `e4c8c8d`): `tiempo.fn_cierre_dia_armar`, DEFINER y con EXECUTE solo para `service_role`.
  - Crea el día, sus tramos y la excepción de paridad en una sola transacción.
  - SCJ27: `dia_ya_existe`, `estado_invalido`, `tramos_inconsistentes` y `horas_fuera_de_rango`.
  - Antes, un tramo rechazado dejaba el día sin tramos, y `_dia_ya_resuelto` lo saltaba para siempre.
- **`123_`:** `trg_tramo_valida_tiempos` exige que inicio y fin coincidan con el momento efectivo de las marcas, y que minutos = fin − inicio ± 0.01 (SCJ15 `tramo_tiempos_incoherentes`). También agrega `uq_correccion_marca_creado_en`.
- **Orden aplicado:** `124_`, después el backend, después `123_`.
- **Verificación:**
  - diagnóstico de días a medias (`db/consultas/validacion/dias_cierre_incompleto.sql`) en 0;
  - tramos incoherentes en 0;
  - verificador 1–88 sin violaciones.
- **Lista cerrada de hints:** `registro_seguro.descripcion_segura` solo registra hints que estén en `HINTS_CONOCIDOS`, con un contrato bidireccional contra `db/ddl`.

### 5. Alerta «Fuera de horario» sin salida (`125_`)
- **Caso real:** una sola excepción, la 210. Su marca era el cierre de un tramo en un día cerrado. No había salida:
  - corregir lo impide `87_`;
  - `fn_dia_revisar` solo resuelve las marcas que arma;
  - el descarte de `86_` exige el prefijo `dia_cerrado`.
- **`125_`** (`20a60ab`): `fn_excepcion_horario_descartar`, un descarte auditado.
  - Usa el permiso `excepcion_dia_cerrado_descarte`, no heredable.
  - El autor sale de `auth.uid()`, y nadie descarta la alerta de su propia marca.
  - El motivo se normaliza (control, invisibles Unicode y espacios colapsados) y debe medir de 10 a 500 caracteres.
  - Queda registrado en `excepcion_descarte`.
- **Endpoint** `POST /api/excepciones/{id}/descartar-alerta-horario` y flag `puede_descartar_alerta_horario` (`131075f`).
- **Botón** «Descartar alerta» (`40d6a49`).
- La excepción 210 ya fue descartada por RH.

### 6. Jornadas reducidas por acuerdo (análisis, sin código)
- **Pregunta del usuario:** cómo cargar a una persona contratada por 48 h que, por un acuerdo, trabajará 35 h durante tres meses y repondrá después.
- **Hallazgo:** el sistema guarda una sola cifra de horas esperadas (el `patron_semanal`). Si el patrón refleja el acuerdo, la diferencia nunca se vuelve deuda.
- **Decisión (opción B del usuario):** el patrón siempre es el del contrato, la flexibilidad de horario se da con `flexible` y lo no cumplido se lleva como deuda en el banco. Mientras dure el acuerdo, RH renueva la antigüedad de esa deuda. Las horas de más sin deuda (`extra`) no tocan el banco ni generan pago, solo aparecen en Tramos y en Tope legal, y no se reconocen como horas extra. Queda como regla de operación en `SCJ-PRO-09` V1.1 §VIII.
- **Bug encontrado:** `cierre_dia` crea faltas en días sin fila de patrón (P-191 de la bóveda).

### 7. Guía de enrolamiento de huella (borrador, sin commit)
- **Fotos:** la parte B (el aparato) quedó completa con las fotos del 20 y 21-oct. Se les borraron los metadatos de ubicación y se taparon IDs y nombres con un bloque sólido.
- **Correcciones:**
  - en el aparato la persona aparece como «U» + Nº, no con su nombre real;
  - la columna HD cuenta las huellas;
  - la prueba de marca no sale en verde: es una palomita con «Autenticado.», y el aparato oculta con asteriscos los primeros dígitos del ID.

## Qué se decidió

- Días sin tramos en el corte: cuentan la jornada esperada solo si los cubre una ausencia autorizada con goce. La regla la propuso `security` y el usuario la aprobó.
- Ningún batch depende de la zona horaria del contenedor: la zona va explícita en el código.
- El cierre del día se hace atómico ANTES de validar los tiempos de los tramos (opción 1 del usuario).
- Las alertas de horario en días cerrados se descartan con constancia (opción A), no en bloque al revisar ni de forma automática.
- Los HINT del DDL son siempre literales fijos; está anotado en `db/ensayos/README.md`.

## Qué quedó pendiente

Ver la bóveda, `12-Pendientes/Pendientes_Activos` §3 (P-179 a P-190):
- **Corte de septiembre:** lo bloquea la ausencia #35, una falta propia de Diego que debe resolver otra persona.
- **Revisar el primer cierre nuevo** del 22-oct.
- **Dos capturas** de la guía de huella.
- **`CURRENT_DATE` UTC** en `75_`/`76_`.
- **Autor de la captura manual.**
- **Búsquedas de una letra** con plantilla grande.
- **Alinear la normalización** del descarte de `86_`.
- **RPC de corrección de días cerrados.**
- **Firmas del acta** del puente v0.1.2.

## Preguntas nuevas

- ¿Conviene fijar la zona horaria también en la sesión de la base, o en las funciones de vigencias, para cerrar la ventana de 6 h de `75_`/`76_`?

## Nota para la retrospectiva

- **Mismo error de zona horaria, ahora en el programador.** Es la tercera vez que aparece, después de `_desfase_local_en` (11-sep) y del frontend. Un contenedor sin `TZ` corre en UTC, y cualquier «hoy» implícito está mal entre las 18:00 y las 24:00 de México. Ya hay guarda de CI.
- **Una RPC transaccional para cada escritura en varias tablas.** Pasó otra vez, ahora con el cierre del día: el riesgo apareció en la revisión de `123_`, no en el diseño original.
- **Al validar algo nuevo, revisar que cada estado conserve una salida.** Aquí, una alerta que solo se podía corregir quedó sin salida al cerrarse el día.
