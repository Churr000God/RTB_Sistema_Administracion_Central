# Modelo lógico — Subsistema de Tiempo

**Sistema de Control de Jornada**
Folio SCJ-MOD-02 · Versión 2.2 · 5 de septiembre de 2026

> **Cambio de versión (V1.0 → V1.1, menor):** se completan los atributos de las 14 entidades, que
> antes sólo estaban listadas por nombre. No se contradice nada de lo ya escrito — se precisa. Ver
> DDL real en `db/ddl/02_tiempo.sql` y decisiones `SCJ-DEC-02`, `SCJ-DEC-03`, `SCJ-DEC-06`,
> `SCJ-DEC-07`, `SCJ-DEC-09`, ya aceptadas.

> **Cambio de versión (V1.1 → V2.0, mayor):** `marca` había divergido de `SCJ-CDT-01`/`SCJ-ESP-01`
> sin decisión formal — se restauran `desfase_local` y `version_software` (faltaban), se restaura
> `estado_reloj` como enum de 3 valores (estaba colapsado en un boolean `reloj_sincronizado`), se
> renombran `momento_terminal`→`momento_dispositivo` y `momento_servidor`→`momento_recepcion` para
> igualar los nombres cerrados del contrato, y `origen` vuelve a sus 2 valores reales
> (`terminal`/`captura_manual`) — se elimina `contingencia`, que nunca tuvo respaldo en ningún
> documento. Se agrega la entidad `aprobacion_ausencia` (15ª tabla del subsistema) para implementar
> `SCJ-DEC-05` (aceptada el 2 de septiembre, el DDL seguía con el comentario "Propuesta"). Ver
> reconciliación completa en bitácora 2026-09-05.

> **Cambio de versión (V2.0 → V2.1, menor):** `jornada_asignada` gana `genera_alerta_horario`
> (`SCJ-PRO-09`) — regla de negocio en un campo en vez de comparar `tipo_jornada` contra `'normal'`
> por todo el código.

> **Cambio de versión (V2.1 → V2.2, menor):** se agrega la entidad `corrida_batch` (16ª tabla) —
> estado visible de los batches de orquestación (`SCJ-PRO-12`). Se corrige `dia.origen`: el `CHECK`
> traía `'terminal'` por error (nunca se usó — el caso de marcas reales siempre fue `NULL`) y se
> agrega `'ausencia_autorizada'`, el tercer caso real que `SCJ-PRO-12` necesita.

Entidades, atributos, claves y cardinalidades del subsistema de Tiempo. Entregable E2 de
`SCJ-ESP-01`. La justificación de normalización va aparte, en `SCJ-NRM-01`.

---

## I. Diagrama

> Fuente en `diagramas/fuente/logico.mmd` · Imagen en `diagramas/export/logico.svg`

---

## II. Entidades

### II.1 `persona` *(stub)*

Ancla de claves foráneas. Una sola columna. Ver `SCJ-FRO-01`.

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | uuid | PK | No | Identificador opaco — sincronizado desde `personas.persona`, ver `SCJ-FRO-01` |

### II.2 `marca`

*Evento crudo producido por el terminal. **Inmutable.** Ver `SCJ-CDT-01`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | Subrogada — `SCJ-DEC-08`, Opción B (aceptada) |
| `evento_id` | uuid | UNIQUE | No | Llave de negocio, idempotencia global |
| `persona_id` | uuid | FK → `persona` | No | Ya resuelto por el terminal, nunca la plantilla |
| `terminal_id` | varchar(32) | | No | Aparato o, en `captura_manual`, punto de captura |
| `secuencia_local` | bigint | | Sí | Nulo salvo `origen = terminal`. Detecta huecos |
| `momento_dispositivo` | timestamptz | | No | Hora que reporta el origen |
| `desfase_local` | varchar(6) | | No | `±HH:MM` vigente en `momento_dispositivo` |
| `momento_recepcion` | timestamptz | | No | Hora de llegada al servidor. No calcula |
| `estado_reloj` | varchar(20) | | No | `sincronizado` / `deriva` / `sin_sincronizar` |
| `version_software` | varchar(16) | | No | Versión del firmware o de la app que generó el evento |
| `origen` | varchar(20) | | No | `terminal` / `captura_manual` |
| `requiere_revision` | boolean | | No | Bandera rápida; detalle en `excepcion` |

**Restricciones:**
- `uq_marca_evento_id` — idempotencia por llave de negocio
- `uq_marca_terminal_secuencia` (parcial, `WHERE origen = 'terminal'`) — huecos de secuencia, `SCJ-DEC-09`
- `ck_marca_origen`, `ck_marca_estado_reloj`, `ck_marca_desfase_local`, `ck_marca_secuencia_solo_terminal`

### II.3 `tramo`

*Par de marcas: la impar abre, la par cierra. Ver `SCJ-ESP-01 §VI.1`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `dia_id` | bigint | FK → `dia` | No | |
| `marca_apertura_id` | bigint | FK → `marca`, UNIQUE | No | |
| `marca_cierre_id` | bigint | FK → `marca`, UNIQUE | Sí | Nulo = tramo abierto, día con número impar de marcas |
| `inicio` | timestamptz | | No | |
| `fin` | timestamptz | | Sí | |
| `minutos_trabajados` | numeric(6,2) | | Sí | Derivado de `fin - inicio` |

### II.4 `jornada_asignada`

*Jornada de una persona **con vigencia**. Ver `SCJ-ESP-01 §VI.3`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `persona_id` | uuid | FK → `persona` | No | |
| `tipo_jornada` | varchar(20) | | No | `normal` / `flexible` / `de_confianza` |
| `vigente_desde` | date | | No | `SCJ-DEC-04`, Opción A |
| `vigente_hasta` | date | | Sí | `NULL` = vigente. Traslape por persona validado en la aplicación, no con `EXCLUDE` (`SCJ-DEC-04`) |
| `descuento_comida_fija` | boolean | | No | |
| `minutos_descuento_comida_fija` | int | | Sí | No nulo si `descuento_comida_fija` |
| `horas_semanales_calculadas` | numeric(6,2) | | Sí | Derivado de `patron_semanal` |
| `genera_alerta_horario` | boolean | | No | `true`=`normal` (alerta si llega tarde/se pasa); `false`=`flexible`/`de_confianza` (`SCJ-PRO-09`) |

### II.5 `patron_semanal`

*Qué días se trabaja, con qué horario. Admite jornada partida (varias filas por `dia_semana`).*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `jornada_asignada_id` | bigint | FK → `jornada_asignada` | No | |
| `dia_semana` | varchar(10) | | No | `lunes`…`domingo` |
| `hora_entrada` | time | | No | |
| `hora_salida` | time | | No | |
| `minutos_comida` | int | | No | Predeterminado 0 |
| `horas_efectivas` | numeric(5,2) | | Sí | Derivado |

### II.6 `tope_legal`

*Máximo semanal por vigencia. Ver `SCJ-ESP-01 §VI.4`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `vigente_desde` | date | UNIQUE | No | El siguiente registro cierra la vigencia del anterior |
| `maximo_semanal` | numeric(6,2) | | No | |
| `maximo_extra` | numeric(6,2) | | No | |

### II.6-bis `clasificacion_de_tiempo`

*Ordinario, reposición o extra, sobre un tramo. Ver `SCJ-ESP-01 §VI.5`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `tramo_id` | bigint | FK → `tramo`, UNIQUE | No | |
| `tipo` | varchar(20) | | Sí | `ordinario` / `reposicion` / `extra` — nulo hasta clasificar |

### II.7 `banco_de_horas` y `movimiento_de_saldo`

*Deuda, ventana de resolución y las cuatro salidas más el movimiento que la origina.
Ver `SCJ-ESP-01 §VI.6` y `SCJ-DEC-02` (aceptada).*

**`banco_de_horas`**

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `persona_id` | uuid | FK → `persona`, UNIQUE | No | Un renglón acumulador por persona |
| `monto` | numeric(8,2) | | No | `[CALCULADO]` — sólo el disparador de `movimiento_de_saldo` lo escribe |
| `vivo_desde` | timestamptz | | Sí | `[CALCULADO]` — nulo cuando `monto = 0` |
| `actualizado_en` | timestamptz | | No | `[CALCULADO]` |

**`movimiento_de_saldo`**

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `banco_de_horas_id` | bigint | FK → `banco_de_horas` | No | |
| `clasificacion_de_tiempo_id` | bigint | FK → `clasificacion_de_tiempo` | Sí | Sólo si lo generó una reposición |
| `tipo` | varchar(20) | | No | `generado_quincena` / `cubrir` / `arrastrar` / `descontar` / `condonar` |
| `monto` | numeric(8,2) | | No | Signo: positivo aumenta la deuda, negativo o cero la reduce |
| `motivo` | text | | Sí | |
| `autor_id` | uuid | FK → `persona` | Sí | Nulo si lo generó el sistema |
| `creado_en` | timestamptz | | No | |

### II.8 `correccion`

*Registro nuevo que apunta al original. Ver `SCJ-ESP-01 §VI.7` y `SCJ-DEC-03` (aceptada).*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `marca_id` | bigint | FK → `marca` | No | |
| `valor_corregido` | timestamptz | | No | Corrige `momento_dispositivo`; `persona_id` no se corrige aquí |
| `motivo` | text | | No | |
| `autor_id` | uuid | FK → `persona` | No | Siempre humano |
| `creado_en` | timestamptz | | No | |

### II.9 `ausencia`

*Ver `SCJ-ESP-01 §VI.8` y `SCJ-DEC-05` (aceptada, Opción C).*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `persona_id` | uuid | FK → `persona` | No | |
| `tipo_de_ausencia` | varchar(30) | | No | `vacaciones` / `permiso_con_goce` / `permiso_sin_goce` / `incapacidad` / `falta` |
| `fecha_inicio` | date | | No | |
| `fecha_fin` | date | | No | |
| `estado_autorizacion` | varchar(20) | | No | `pendiente` / `autorizada` / `rechazada` — **materializado**, escrito por trigger desde `aprobacion_ausencia` |
| `documento_ref` | varchar(50) | | Sí | Evidencia cargada, exigida para pagar una falta justificada |

### II.9-bis `aprobacion_ausencia`

*Cadena de aprobación congelada al crear la solicitud — `SCJ-DEC-05`, Opción C. No hay tabla de
"definición de flujo": quién aprueba cada paso lo resuelve la aplicación contra
`personas.puesto_permiso`/`asignacion` (permiso `autorizar_ausencia`, heredable jerárquicamente) en
el momento de crear la ausencia, y esta tabla sólo guarda el resultado ya resuelto.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `ausencia_id` | bigint | FK → `ausencia` | No | |
| `numero_paso` | smallint | UNIQUE (con `ausencia_id`) | No | Orden de la cadena congelada |
| `aprobador_id` | uuid | FK → `persona` | No | Persona específica, no un rol — congelada al crearse |
| `decision` | varchar(20) | | No | `pendiente` / `autorizada` / `rechazada` |
| `motivo` | text | | Sí | |
| `decidido_en` | timestamptz | | Sí (`NULL` mientras `pendiente`) | |

**Restricciones:** `uq_aprobacion_ausencia_paso` (`ausencia_id`, `numero_paso`),
`ck_aprobacion_ausencia_decidido` (`decidido_en` nulo ⟺ `decision = 'pendiente'`). Un rechazo en
cualquier paso cierra `ausencia.estado_autorizacion` en `rechazada`; todos los pasos en
`autorizada` la cierran en `autorizada`.

### II.10 `parametro`

*Toda regla de negocio vive aquí. Ver `SCJ-ESP-01 §VI.9`.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `clave` | varchar(100) | UNIQUE con `vigente_desde` | No | |
| `valor` | text | | No | |
| `vigente_desde` | date | UNIQUE con `clave` | No | Mismo patrón de versionado que `tope_legal` |

### II.11 `excepcion`

*Cola de revisión humana: días sin checada, marcas con reloj no sincronizado, jornada ordinaria en
domingo/festivo sin autorización previa. Ver `SCJ-DEC-07` (aceptada).*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `marca_id` | bigint | FK → `marca` | Sí | Uno de los dos, nunca ambos ni ninguno |
| `dia_id` | bigint | FK → `dia` | Sí | |
| `motivo_revision` | text | | No | |
| `estado` | varchar(20) | | No | `pendiente` / `resuelto` |
| `creado_en` | timestamptz | | No | |

### II.12 `dia`

*Marcas de una persona en una fecha, con estado. Ver `SCJ-ESP-01 §III.1`, `§VI.2` y `SCJ-DEC-06`
(aceptada).*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `persona_id` | uuid | FK → `persona`, UNIQUE con `fecha` | No | |
| `fecha` | date | UNIQUE con `persona_id` | No | |
| `estado` | varchar(20) | | No | `abierto` / `cerrado` / `bloqueado` / `revisado` — cuarto estado agregado en esta versión |
| `horas_totales` | numeric(5,2) | | Sí | `[CALCULADO]`, suma de `tramo.minutos_trabajados` |
| `origen` | varchar(20) | | Sí | Nulo si nace de marcas reales; `automatico_confianza` (jornada `de_confianza`, sin marca/tramo) o `ausencia_autorizada` (resuelto contra una ausencia, `SCJ-PRO-12`) |

### II.13 `dia_festivo`

*Catálogo de días festivos — no estaba en el modelo original, se agrega para que el sistema pueda
detectar automáticamente cuándo un día es festivo. Domingo no necesita catálogo, se deriva de la
fecha.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `fecha` | date | UNIQUE | No | |
| `nombre` | varchar(100) | | No | |

### II.14 `corrida_batch`

*Estado visible de cada corrida de los batches de orquestación — `SCJ-PRO-12`. Sin FK a ninguna
otra entidad: agrupa por `tipo_batch`/`fecha`, no por persona. El job automático y el botón manual
son la misma invocación; reintentar/reprocesar es un `UPSERT` sobre la misma fila.*

| Atributo | Tipo | Clave | Nulo | Descripción |
|---|---|---|---|---|
| `id` | bigint | PK | No | |
| `tipo_batch` | varchar(20) | UNIQUE (con `fecha`) | No | `cierre_dia` / `corte_quincenal` / `de_confianza` |
| `fecha` | date | UNIQUE (con `tipo_batch`) | No | |
| `estado` | varchar(20) | | No | `en_progreso` / `exitosa` / `fallida` |
| `intentos` | smallint | | No | Default 1, se incrementa en cada reintento/reproceso |
| `iniciado_en` | timestamptz | | No | |
| `terminado_en` | timestamptz | | Sí (`NULL` mientras `en_progreso`) | |
| `detalle` | text | | Sí | Resumen legible, ej. personas pendientes tras 3 intentos |

---

## III. Cardinalidades

| Relación | Cardinalidad | Comentario |
|---|---|---|
| `persona` — `marca` | 1:N | |
| `persona` — `dia` | 1:N | |
| `persona` — `jornada_asignada` | 1:N | Con vigencia, no traslapada |
| `persona` — `ausencia` | 1:N | |
| `persona` — `banco_de_horas` | 1:1 | Un solo renglón acumulador |
| `dia` — `tramo` | 1:N | |
| `marca` — `tramo` | 1:1 (apertura) y 0:1 (cierre) | Dos FK distintas, misma tabla `marca` |
| `tramo` — `clasificacion_de_tiempo` | 1:1 | |
| `jornada_asignada` — `patron_semanal` | 1:N | |
| `banco_de_horas` — `movimiento_de_saldo` | 1:N | |
| `clasificacion_de_tiempo` — `movimiento_de_saldo` | 1:0..N | Sólo cuando el movimiento es `cubrir` automático |
| `marca` — `correccion` | 1:N | |
| `marca` — `excepcion` | 1:0..N | Exclusivo con `dia` — `excepcion` |
| `dia` — `excepcion` | 1:0..N | Exclusivo con `marca` — `excepcion` |

---

## IV. Restricciones que el modelo debe sostener

Las cuatro más exigentes, con la estructura que las garantiza:

| # | Restricción | Cómo se sostiene | Decisión |
|---|---|---|---|
| 1 | Paridad de marcas por día | No se bloquea al insertar: `tramo.marca_cierre_id` nulo es válido, `dia.estado` lo refleja | `SCJ-DEC-01` (sigue propuesta) |
| 2 | Un cálculo pasado da el mismo resultado indefinidamente | `tope_legal`/`jornada_asignada` versionados por vigencia, nunca se sobrescriben | `SCJ-DEC-04` (sigue propuesta) |
| 3 | Una marca nunca se modifica | Sin `UPDATE`/`DELETE` en ningún flujo; toda corrección es una fila nueva en `correccion` | `SCJ-DEC-03` (aceptada) |
| 4 | Los topes cambian por vigencia sin alterar el histórico | `tope_legal.vigente_desde` UNIQUE, sin `UPDATE` sobre registros pasados | `SCJ-DEC-04` (sigue propuesta) |

---

## V. Lo que quedó fuera del modelo, a propósito

| Qué | Por qué |
|---|---|
| Tabla `usuario` / autenticación | Vive en `personas`, fuera del alcance de este subsistema (`SCJ-FRO-01`); `movimiento_de_saldo.autor_id` y `correccion.autor_id` referencian `tiempo.persona` directamente, no un usuario de sistema |
| Flujo de autorización de `ausencia` | `estado_autorizacion` es un placeholder de un solo paso a propósito — la entidad completa depende de que `SCJ-DEC-05` se resuelva primero |
| Marcas sintéticas para jornada `de_confianza` | Se decidió expresamente no generarlas — contaminarían `marca` como evidencia de jornada. El batch que crea `dia` directo para `de_confianza` (campo `origen`) queda sin diseñar todavía |

---

*Modelo lógico · Folio SCJ-MOD-02 · V1.1*
