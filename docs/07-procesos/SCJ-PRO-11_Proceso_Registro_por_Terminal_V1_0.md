# Proceso — Registro por terminal

**Sistema de Control de Jornada**
Folio SCJ-PRO-11 · Versión 1.0 · 5 de septiembre de 2026

Quinto `SCJ-PRO` del subsistema de **Tiempo**, y el primero que no involucra un usuario humano.
Cubre cómo el checador físico (`origen = 'terminal'`) se integra a este repositorio — el protocolo
en sí ya está cerrado en `SCJ-CDT-01`; este documento cubre la conexión real y el cálculo de
`requiere_revision`/`motivo_revision`.

---

## I. Alcance

**Cubre:** desde que el checador tiene una marca lista para subir, hasta que queda en
`tiempo.marca`, señalada o no, con la identidad y el permiso mínimo necesarios para insertarla.

**No cubre — vive en el repositorio propio del checador, fuera de éste:**

- La interfaz visual del aparato, su base de datos local (SQLite, caché de plantillas biométricas
  ↔ `persona_id`), y su micro-backend — todo eso es **un subproyecto aparte, con su propio
  repositorio**. Este documento sólo fija el contrato del lado de este repositorio: qué necesita
  ese subproyecto para poder insertar, y qué recibe.
- Enrolamiento y borrado de plantillas biométricas, y el resto del `flujo = evento` (bitácora de
  Operación) — declarado fuera de alcance por `SCJ-ESP-01 §II`. Nunca se modela aquí.
- El batch de cierre de día que arma `tramo`/`dia.estado` a partir de las marcas ya insertadas —
  pendiente de diseñar aparte. Este documento entrega la marca ya en la tabla; ese batch la
  procesa después, "cada cierto tiempo", sin importar si llegó por terminal o por captura manual.

---

## II. Precondiciones

1. El checador ya resolvió la identidad (plantilla → `persona_id`) en su propia caché local — a
   Tiempo sólo llega una marca con `persona_id` ya resuelto, nunca antes (`SCJ-ESP-01 §I.4` regla
   5). Sin plantilla conocida, la marca se queda en Operación (fuera de este repositorio).
2. El checador sincronizó su caché local de personas activas/inactivas (y de personas nuevas) en
   algún momento reciente — de madrugada, en el mismo corte donde sube lo del día. La frecuencia y
   el mecanismo exacto de esa sincronización son del subproyecto del checador, no de este
   documento.
3. Existe la identidad de Postgres `terminal_checador` (§III) con permiso de insertar en
   `tiempo.marca` — sin esto, ninguna marca de terminal puede llegar.

---

## III. Identidad del checador — no es un usuario humano

Los procesos `07`-`10` gatean por `personas.puesto_permiso`/`asignacion` porque son personas con
puesto. El checador no tiene puesto ni sesión de Supabase Auth — necesita su propio mecanismo.

**Decisión confirmada con el usuario:** rol de Postgres dedicado (`terminal_checador`), no
`service_role` compartida. La micro-backend del checador firma su propio JWT con el secreto del
proyecto (mismo mecanismo que ya usa PostgREST para `anon`/`authenticated`/`service_role` — no pasa
por el flujo de login de Supabase Auth), con un claim `role=terminal_checador`.

**Por qué no `service_role`:** un checador es un aparato de pared, mucho más expuesto físicamente a
robo o manipulación que un servidor. Con `service_role` compartida, un aparato comprometido tiene
acceso a *toda* la base. Con rol propio y alcance mínimo, lo peor que puede hacer es insertar
marcas falsas — nunca leer ni tocar nada más.

**Alcance del rol, implementado en `db/ddl/37_tiempo_rls_terminal.sql`:**

| Puede | No puede |
|---|---|
| `INSERT` en `tiempo.marca`, forzado a `origen='terminal'` por la policy | `SELECT`/`UPDATE`/`DELETE` en `tiempo.marca` — ni de sus propias filas |
| — | Ninguna otra tabla de `tiempo` ni de `personas` |

---

## IV. Cálculo de `requiere_revision`/`motivo_revision`

De los 5 valores de `motivo_revision`, 4 se calculan en un disparador centralizado
(`trg_marca_valida_revision`, `AFTER INSERT` sobre `tiempo.marca`, sin importar el origen — corre
igual para `terminal` y `captura_manual`, ver `SCJ-PRO-07 V1.1`):

| Motivo | Cómo se calcula | Capa |
|---|---|---|
| `reloj_no_sincronizado` | El origen ya reporta `estado_reloj` — si no es `sincronizado`, se señala. No se deriva nada | Trigger |
| `persona_inactiva` | Cruza `personas.persona.estado` en el momento de la marca. **Respaldo**: el checador ya filtra esto contra su caché local y no debería llegar a mandarla — esto cubre el hueco entre sincronizaciones | Trigger |
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

- **El checador es su propio subproyecto, con su propio repositorio.** Este repositorio no
  construye su interfaz, su base local ni su micro-backend — sólo el contrato de conexión (§III) y
  el procesamiento del lado de Tiempo (§IV).
- **La sincronización de personas activas/nuevas es responsabilidad del checador, diaria.** Falla
  de diseño aceptada a propósito: entre sincronizaciones, el checador puede dejar marcar a alguien
  que ya se volvió inactivo — por eso existe el respaldo del lado servidor (`persona_inactiva` en
  el trigger), no porque se espere que falle seguido.
- **Enrolar una plantilla exige vincularla a una persona ya conocida en la caché local del
  checador.** No hay enrolamiento "huérfano" — sin eso, no hay forma de asociar la plantilla a un
  `persona_id`.
- **Un día cerrado nunca se reabre por una marca tardía, y la marca nunca se rechaza.** Ambas cosas
  son ciertas a la vez: el día se queda como estaba, la marca se guarda señalada. Confirmado
  explícito 2026-09-05 para evitar la lectura ambigua de "rebota" (que sonaba a rechazo).
- **`persona_inactiva` en el trigger nunca rechaza, sólo señala** — mismo principio que
  `dia_cerrado` y que toda la filosofía del contrato (`SCJ-CDT-01 §II.5`): la evidencia nunca se
  pierde por un error del sistema.
- **Rol de Postgres dedicado, no `service_role` compartida** — decisión de seguridad explícita,
  justificada por el modelo de amenaza distinto de un aparato físico expuesto frente a un servidor.

---

## VI. Estado actual

Ya implementado en `db/ddl/`:

- `37_tiempo_rls_terminal.sql` — rol `terminal_checador`, RLS de `tiempo.marca` (primera de todo el
  esquema `tiempo`).
- `fn_marca_valida_revision`/`trg_marca_valida_revision` en `02_tiempo.sql` — los 4 motivos de
  revisión calculados.

Falta:

1. El subproyecto del checador en sí (repo aparte) — interfaz, base local, micro-backend, y el
   mecanismo real de firma del JWT con el secreto del proyecto.
2. RLS del resto de `tiempo` para el backend humano — sigue pendiente desde `SCJ-PRO-07`.
3. El batch de cierre de día que consume las marcas ya insertadas.

---

## VII. Siguiente paso

Con `SCJ-PRO-07` a `11`, el subsistema de Tiempo tiene 5 procesos documentados. Queda: los batches
de cierre de día y corte quincenal, que varios de estos documentos ya dan por existentes sin
haberlos diseñado todavía — probablemente el siguiente paso natural, porque varios procesos
(`08`, `10`, `11`) dependen de que exista.

---

*Proceso · Folio SCJ-PRO-11 · V1.0*
