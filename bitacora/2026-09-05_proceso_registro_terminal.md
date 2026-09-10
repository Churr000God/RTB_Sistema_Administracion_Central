# 2026-09-05 · Sesión — Proceso de registro por terminal (`SCJ-PRO-11`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (quinto proceso seguido en el mismo día, después de
`SCJ-PRO-07/08/09/10`).

---

## Qué se hizo

Discutido en el chat, escrito `SCJ-PRO-11`: primer proceso del subsistema de Tiempo que no
involucra un usuario humano con puesto — el checador es un dispositivo.

**Revelación arquitectónica importante:** el checador va a ser **su propio subproyecto, con
repositorio aparte** — interfaz visual, credenciales de Supabase propias, base de datos local
(SQLite) y micro-backend propio que procesa entradas/salidas y las sube a `tiempo.marca`; los
batches de este repo las procesan después. `SCJ-PRO-11` sólo documenta el contrato del lado de
este repositorio (identidad, permisos mínimos, cálculo de revisión), no construye el subproyecto
del checador en sí.

Implementado de una vez en `db/ddl/`:

- `37_tiempo_rls_terminal.sql` — **primera RLS de todo el esquema `tiempo`**. Rol de Postgres
  dedicado `terminal_checador` (no `service_role` compartida — decisión de seguridad: un aparato
  de pared es mucho más expuesto físicamente que un servidor). Alcance mínimo: sólo `INSERT` en
  `tiempo.marca`, con `origen='terminal'` forzado por la policy.
- `fn_marca_valida_revision`/`trg_marca_valida_revision` (`02_tiempo.sql`) — disparador
  centralizado `AFTER INSERT` sobre `tiempo.marca` que calcula 4 de los 5 `motivo_revision`
  (`reloj_no_sincronizado`, `persona_inactiva`, `dia_cerrado`, `fuera_de_horario`) sin importar el
  origen — corre igual para `terminal` y `captura_manual`. `SECURITY DEFINER` porque
  `terminal_checador` sólo tiene `INSERT`, no lectura de `personas.persona`/`tiempo.dia`/etc.

**Refactor de paso:** `SCJ-PRO-07` (captura manual) sube a **V1.1** — el chequeo de
`persona_inactiva` que hacía el backend a mano antes de insertar se reemplaza por el mismo
disparador centralizado, evitando duplicar la regla en dos lugares.

`SCJ-MOD-03` sube a **V1.4** (menor). `SCJ-TRZ-01` actualizado (2 filas que decían "disparador
pendiente" ya están implementadas).

## Qué se decidió

- **Identidad del checador: rol de Postgres propio, JWT firmado con el secreto del proyecto**
  (mismo mecanismo que usa PostgREST para `anon`/`authenticated`, sin pasar por el login de
  Supabase Auth), no `service_role`. El usuario ya se inclinaba por esto; confirmé con mi
  evaluación de esfuerzo/riesgo — no es mucho más trabajo, y el modelo de amenaza de un aparato
  físico lo justifica.
- **`plantilla_desconocida` casi nunca aplica en Tiempo** — por construcción, una marca que llega
  ya tiene `persona_id` resuelto (la resolución ocurre en Operación, fuera de este repo). Sólo
  tendría sentido como aviso histórico para una marca que tardó en resolverse.
- **Persona inactiva, dos capas confirmadas:** el checador filtra localmente contra su caché
  (sincronizada de madrugada) y rechaza + registra un `evento` de auditoría en su propia bitácora
  de Operación (fuera de este repo); el servidor tiene un respaldo (`fn_marca_valida_revision`)
  para el hueco entre sincronizaciones — **nunca rechaza, sólo señala**, mismo principio que todo
  el sistema.
- **Día cerrado: se aclaró una ambigüedad real.** "Rebota" no significa que la marca se rechace —
  significa que el día no se reabre. La marca se guarda igual, señalada. Esto **no contradice**
  `SCJ-CDT-01`/`SCJ-ESP-01` (que ya decían exactamente esto) — fue una aclaración de lenguaje, no
  un cambio de decisión, así que esos documentos no se tocaron.

## Qué quedó pendiente

- El subproyecto del checador en sí (repo aparte) — no es responsabilidad de este repositorio.
- RLS del resto de `tiempo` para el backend humano (routers que todavía no existen).
- El batch de cierre de día, del que ahora dependen `SCJ-PRO-08`, `10` y `11` por igual.

## Preguntas nuevas

- Ninguna — las dos dudas de esta sesión (rol de Postgres vs. service role, y el significado de
  "rebota" en día cerrado) se resolvieron en la misma conversación.

## Nota para la retrospectiva

Primera vez en el día que el diseño destapa una pieza de arquitectura más grande que el DDL de este
repo — el checador como subproyecto aparte. Vale la pena, antes de escribir el `SCJ-PRO` de cierre
de día (el siguiente natural, ver `SCJ-PRO-11 §VII`), confirmar con el usuario si ya existe algún
avance o decisión sobre ese subproyecto que no se ha mencionado aquí, para no diseñar el batch de
cierre asumiendo un contrato de subida distinto al real.
