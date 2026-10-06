# Proceso — Registro por terminal

**Sistema de Control de Jornada**
Folio SCJ-PRO-11 · Versión 2.0 · 5 de octubre de 2026

> **Cambio de versión (V1.0 → V2.0, mayor):** el aparato de registro pasa del lector R503Pro a la
> terminal biométrica Hikvision DS-K1A8503EF-B, con el Raspberry Pi como **puente** sin pantalla
> propia (`SCJ-DEC-11`). Se contradicen dos cosas ya escritas: (1) §III decía que el micro-backend del
> checador firmaba un JWT de Supabase con `role=terminal_checador`; ahora el Pi se autentica ante
> el backend de este proyecto con una credencial propia de terminal, y las marcas suben por ese
> backend, no directo a la base. (2) §I y §V daban el enrolamiento por fuera de alcance y vinculado a
> una caché local; ahora el mapeo `employeeNo` ↔ persona vive en el servidor
> (`tiempo.terminal_usuario`, con bitácora inmutable) y el Pi sólo lo cachea. El resto (§IV, cálculo
> de revisión) no cambia.

Quinto `SCJ-PRO` del subsistema de **Tiempo**, y el primero que no involucra un usuario humano.
Cubre cómo el checador físico (`origen = 'terminal'`) se integra a este repositorio — el protocolo
en sí ya está cerrado en `SCJ-CDT-01`; este documento cubre la conexión real y el cálculo de
`requiere_revision`/`motivo_revision`.

---

## I. Alcance

**Cubre:** desde que el checador tiene una marca lista para subir, hasta que queda en
`tiempo.marca`, señalada o no, con la identidad y el permiso mínimo necesarios para insertarla.

**No cubre — vive en el repositorio propio del checador, fuera de éste:**

- El código del puente (el Raspberry Pi que habla ISAPI con la terminal), su base de datos local
  (SQLite, caché del mapeo `employeeNo` ↔ `persona_id`) y su configuración — todo eso es **un
  subproyecto aparte, con su propio repositorio**. La terminal Hikvision tiene su propia pantalla
  y su propio almacén de huellas; el Pi no tiene pantalla. Este documento sólo fija el contrato del
  lado de este repositorio: qué necesita ese subproyecto para operar, y qué recibe.
- Las **plantillas biométricas** (huellas) y su captura: se capturan siempre de forma presencial
  frente a la terminal y nunca salen del aparato ni se guardan en este repositorio ni en la base.
- El resto del `flujo = evento` (bitácora de Operación) — declarado fuera de alcance por
  `SCJ-ESP-01 §II`. Nunca se modela aquí.

**Sí cubre, desde V2.0:** el mapeo `employeeNo` ↔ persona y la bitácora de enrolamiento y baja de
usuarios de la terminal (`tiempo.terminal`, `tiempo.terminal_usuario`,
`tiempo.bitacora_movimiento_terminal_usuario`). Decisión y transiciones en `SCJ-DEC-11`.
- El batch de cierre de día que arma `tramo`/`dia.estado` a partir de las marcas ya insertadas —
  pendiente de diseñar aparte. Este documento entrega la marca ya en la tabla; ese batch la
  procesa después, "cada cierto tiempo", sin importar si llegó por terminal o por captura manual.

---

## II. Precondiciones

1. El puente ya resolvió la identidad (`employeeNo` del evento de la terminal → `persona_id`) con
   su caché del mapeo del servidor — a Tiempo sólo llega una marca con `persona_id` ya resuelto,
   nunca antes (`SCJ-ESP-01 §I.4` regla 5). Un `employeeNo` desconocido se queda en Operación
   (fuera de este repositorio).
2. El puente sincronizó su caché del mapeo (`tiempo.terminal_usuario` vía backend) en algún
   momento reciente, y procesó las altas y bajas pendientes (`pendiente_alta`, `pendiente_baja`).
   La frecuencia y el mecanismo exacto son del subproyecto del checador.
3. El Pi tiene credencial propia de terminal para llamar al backend de este proyecto (§III), y la
   terminal está dada de alta en `tiempo.terminal`.

---

## III. Identidad del checador — no es un usuario humano

Los procesos `07`-`10` gatean por `personas.puesto_permiso`/`asignacion` porque son personas con
puesto. El checador no tiene puesto ni sesión de Supabase Auth — necesita su propio mecanismo.

**Mecanismo vigente desde V2.0 (`SCJ-DEC-11`):** el Pi **no toca la base de datos**. Llama a
endpoints del backend de este proyecto con una **credencial propia de terminal** (no el secreto JWT
de Supabase, no `service_role`), y el backend es quien inserta las marcas y los movimientos de
enrolamiento que corresponden. Dos razones, la misma de siempre: un aparato de pared está mucho
más expuesto a robo o manipulación que un servidor, y una credencial de terminal comprometida sólo
puede hacer lo que el backend le deja hacer — no tiene acceso a la base.

**Alcance previsto del Pi vía backend** (los endpoints aún no existen; se confirma al
construirlos): puede subir marcas de su terminal (siempre `origen='terminal'`), leer el mapeo de su
propia terminal para refrescar su caché, y reportar los movimientos de enrolamiento que le tocan al
aparato (`usuario_creado`, `huella_capturada`, `baja_confirmada`, `error`). **Qué no puede:** pedir
`asignado` ni `baja_solicitada` (los inicia Recursos Humanos desde la aplicación, con
`terminal_usuario_edicion`), leer otras terminales ni nada de `personas`.

**Mecanismo original (V1.0, R503Pro), ya no usado por el puente Hikvision:** rol de Postgres
dedicado `terminal_checador`, con JWT firmado con el secreto del proyecto (claim
`role=terminal_checador`). El rol y su policy siguen existiendo en la base
(`db/ddl/37_tiempo_rls_terminal.sql`) con el mismo alcance mínimo; este documento no los retira,
simplemente el puente nuevo no los necesita.

| Rol `terminal_checador` — alcance sin cambio | |
|---|---|
| Puede: `INSERT` en `tiempo.marca`, forzado a `origen='terminal'` por la policy | No puede: `SELECT`/`UPDATE`/`DELETE` en `tiempo.marca`, ni ninguna otra tabla de `tiempo` o `personas` |

---

## IV. Cálculo de `requiere_revision`/`motivo_revision`

De los 5 valores de `motivo_revision`, 4 se calculan en un disparador centralizado
(`trg_marca_valida_revision`, `AFTER INSERT` sobre `tiempo.marca`, sin importar el origen — corre
igual para `terminal` y `captura_manual`, ver `SCJ-PRO-07 V1.1`):

| Motivo | Cómo se calcula | Capa |
|---|---|---|
| `reloj_no_sincronizado` | El origen ya reporta `estado_reloj` — si no es `sincronizado`, se señala. No se deriva nada | Trigger |
| `persona_inactiva` | Cruza `personas.persona.estado` en el momento de la marca. **Respaldo**: el puente ya filtra esto contra su caché del mapeo y no debería llegar a mandarla — esto cubre el hueco entre sincronizaciones | Trigger |
| `dia_cerrado` | Si ya existe `tiempo.dia` para esa persona/fecha con estado distinto de `abierto`. **No reabre el día ni dispara recálculo** — sólo señala; la marca se guarda igual (confirmado 2026-09-05: la evidencia nunca se descarta) | Trigger |
| `fuera_de_horario` | Hora local (`momento_dispositivo` + `desfase_local`) contra el `patron_semanal` vigente de esa fecha, con tolerancia de `tiempo.parametro.tolerancia_retardo_min` | Trigger |
| `plantilla_desconocida` | Nace en Operación, antes de que la marca exista en Tiempo — por construcción, una marca que llega a `tiempo.marca` ya tiene `persona_id` resuelto. No se calcula aquí; sólo tendría sentido como aviso si una marca tardó en resolverse allá y entra tarde | No aplica en Tiempo |

**SECURITY DEFINER, a propósito:** `terminal_checador` sólo tiene `INSERT` en `tiempo.marca` (§III)
— sin `SECURITY DEFINER`, el disparador correría con esos mismos permisos mínimos y no podría leer
`personas.persona`, `tiempo.dia`, `tiempo.jornada_asignada` ni `tiempo.patron_semanal`. La función
corre con los permisos de su dueño, no del rol que dispara el `INSERT`, con `search_path` fijo
(`tiempo, personas, pg_temp`) para evitar secuestro de objetos por otro esquema en el path.

---

## V. Reglas de negocio confirmadas

- **El puente es su propio subproyecto, con su propio repositorio.** Este repositorio no construye
  el código del Pi, su base local ni su configuración — sólo el contrato de conexión (§III), el
  mapeo y su bitácora (`SCJ-DEC-11`) y el procesamiento del lado de Tiempo (§IV).
- **El mapeo `employeeNo` ↔ persona vive en el servidor; el Pi sólo lo cachea** (`SCJ-DEC-11`).
  Una persona sólo puede tener un alta vigente por terminal, y un `employeeNo` nunca se reutiliza.
- **La captura de huella es siempre presencial**, frente a la terminal. Las huellas nunca salen del
  aparato.
- **Alta y baja las inicia Recursos Humanos desde la aplicación** (`terminal_usuario_edicion`,
  permiso no heredable); el Pi sólo ejecuta lo pendiente y reporta el resultado. Todo movimiento
  queda en una bitácora inmutable.
- **La sincronización del mapeo es responsabilidad del puente.** Falla de diseño aceptada a
  propósito: entre sincronizaciones, la terminal puede dejar marcar a alguien que ya se volvió
  inactivo — por eso existe el respaldo del lado servidor (`persona_inactiva` en el trigger), no
  porque se espere que falle seguido. Cuando una persona pasa a `inactivo`, el backend debe emitir
  `baja_solicitada` para su alta en la terminal (el esquema no lo hace solo: cruzar de `personas` a
  `tiempo` por trigger violaría `SCJ-FRO-01`).
- **Un día cerrado nunca se reabre por una marca tardía, y la marca nunca se rechaza.** Ambas cosas
  son ciertas a la vez: el día se queda como estaba, la marca se guarda señalada. Confirmado
  explícito 2026-09-05 para evitar la lectura ambigua de "rebota" (que sonaba a rechazo).
- **`persona_inactiva` en el trigger nunca rechaza, sólo señala** — mismo principio que
  `dia_cerrado` y que toda la filosofía del contrato (`SCJ-CDT-01 §II.5`): la evidencia nunca se
  pierde por un error del sistema.
- **El Pi no toca la base de datos ni usa el secreto del proyecto** — decisión de seguridad
  explícita, justificada por el modelo de amenaza distinto de un aparato físico expuesto frente a
  un servidor (§III).

---

## VI. Estado actual

Con la terminal Hikvision DS-K1A8503EF-B como aparato y el Raspberry Pi como puente (5 de octubre
de 2026).

Ya implementado en `db/ddl/`:

- `37_tiempo_rls_terminal.sql` — rol `terminal_checador`, RLS de `tiempo.marca` (primera de todo el
  esquema `tiempo`). Se conserva sin cambio; el puente Hikvision no lo usa (§III).
- `fn_marca_valida_revision`/`trg_marca_valida_revision` en `02_tiempo.sql` — los 4 motivos de
  revisión calculados.
- `80_tiempo_terminal_usuario.sql` — `tiempo.terminal`, `tiempo.terminal_usuario`, la secuencia
  `tiempo.seq_terminal_employee_no` y los permisos `terminal_usuario_lectura` (heredable) y
  `terminal_usuario_edicion` (no heredable), otorgados a Recursos Humanos, Gerente General y
  Gerente o Encargado de TI.
- `81_tiempo_bitacora_movimiento_terminal_usuario.sql` — bitácora inmutable de enrolamiento y baja,
  y el trigger que valida las transiciones y deriva `terminal_usuario`. Aplicado a la base real el
  5 de octubre de 2026 y verificado (`db/verificar_ddl.sql`).

Falta:

1. Dar de alta la terminal en `tiempo.terminal` (`INSERT` puntual con la serie del aparato; no es
   seed del DDL).
2. Los endpoints del backend para el puente (credencial propia de terminal, subida de marcas,
   lectura del mapeo, reporte de movimientos) y para Recursos Humanos (asignar y dar de baja), con
   el mapeo de errores `23503`/`23505`/`SCJ11`/`SCJ12` a `409`/`422` descrito en `SCJ-DEC-11`.
3. El código del puente en su repositorio (ISAPI contra la terminal, caché local, procesamiento de
   altas y bajas pendientes) — reemplaza al lector R503Pro y a su SQLite anterior.
4. Configuración de red y hora de la terminal (hora manual sin sincronización, DHCP, sin HTTPS):
   se atiende en el aparato, fuera de este repositorio. Una hora desfasada afecta
   `estado_reloj` y `fuera_de_horario`.
5. La emisión de `baja_solicitada` cuando una persona pasa a `inactivo`, y que el ingestor señale
   las marcas de personas inactivas.

---

## VII. Siguiente paso

Construir los endpoints del backend para el puente y para Recursos Humanos, dar de alta la terminal
y escribir el puente en su repositorio, en ese orden: el servidor tiene que existir antes de que el
Pi tenga a quién llamarle. Los batches de cierre de día y corte quincenal (`SCJ-PRO-12`,
`SCJ-PRO-13`) ya consumen las marcas sin importar el origen; este cambio no los toca.

---

*Proceso · Folio SCJ-PRO-11 · V2.0*
