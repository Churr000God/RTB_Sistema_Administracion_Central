# 2026-09-05 · Sesión — Proceso de detección y resolución de falta (`SCJ-PRO-08`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (continuación del día, después de la reconciliación del módulo
Registro-marcas-jornadas-ausencias-asistencias, ver `2026-09-05_reconciliacion_registro_marcas.md`).

---

## Qué se hizo

Se diseñó, discutido pregunta por pregunta en el chat (mismo patrón que `SCJ-PRO-01`/`02`), el
primer flujo real de `tiempo.ausencia`/`tiempo.aprobacion_ausencia`. Escrito como `SCJ-PRO-08`.

Se corrigió `tiempo.fn_ausencia_resuelve_excepcion` (`db/ddl/02_tiempo.sql`): antes sólo cerraba la
`excepcion` asociada cuando `estado_autorizacion` pasaba a `autorizada`; un rechazo dejaba la
excepción abierta para siempre aunque ya hubiera una decisión humana tomada. Ahora reacciona a los
dos casos.

## Qué se decidió

- **No hay solicitud manual de ausencia todavía.** Vacaciones/permiso/incapacidad pedidos por la
  propia persona quedan para cuando el sistema se aplique a la empresa real. Hoy la única fuente de
  `tiempo.ausencia` es la detección automática: día laboral completo esperado, sin marca, sin
  ausencia previa que lo cubra (regla que debe seguir el batch de cierre de día, todavía sin
  diseñar aparte).
- **`tipo_de_ausencia='falta'` es el placeholder inicial** — se resuelve al aprobar (reclasificando
  a `vacaciones`/`permiso_con_goce`/`incapacidad`, neutro, o a `permiso_sin_goce`, con deuda) o al
  rechazar (se queda `falta`, injustificada).
- **`permiso_sin_goce` sustituye lo que iba a ser "falta aceptada".** Sin módulo de nómina todavía,
  no hay forma de descontar el sueldo — se modela como deuda en banco de horas en su lugar. Es
  decisión explícita del usuario, documentada como simplificación temporal en `SCJ-PRO-08`.
- **`permiso_sin_goce` y `falta` (rechazada) generan la misma deuda** — la única diferencia es la
  etiqueta de injustificada, pensada para consecuencias disciplinarias futuras (no construidas).
- **Un solo paso de aprobación, sin jerarquía**, para este flujo específico: cualquiera de los tres
  puestos con `ausencia_edicion` (`Gerente General`, `Responsable de Recursos Humanos`, `Gerente o
  Encargado de TI`) puede resolver cualquier caso — diverge de la lectura original de `SCJ-DEC-05`
  (que anticipaba cadena jerárquica), pero no la contradice: `SCJ-DEC-05` deja la resolución del
  aprobador a la aplicación, y para este flujo la aplicación resuelve "cualquiera de los tres", no
  una cadena.
- **La fila de `aprobacion_ausencia` se crea en el momento de resolver, no antes** — no hay
  "pendiente pre-asignado", porque no se sabe de antemano quién de los tres va a actuar. El
  `UNIQUE(ausencia_id, numero_paso)` ya existente resuelve la carrera si dos intentan resolver a la
  vez, sin cambios de esquema.
- **Ninguna deuda se escribe directo desde este proceso.** La diferencia entre día neutro
  (`vacaciones`/`permiso_con_goce`/`incapacidad`) y día con deuda (`permiso_sin_goce`/`falta`) la
  recoge sola el corte quincenal al comparar horas esperadas contra contabilizadas — no hace falta
  un tipo de `movimiento_de_saldo` nuevo para "ausencia individual".

## Qué quedó pendiente

- **Batch de cierre de día** — sigue sin diseñar. `SCJ-PRO-08` sólo fija la regla puntual que debe
  seguir cuando encuentra un día sin cubrir (crear la `ausencia`), no el batch completo.
- **Corte quincenal (`generado_quincena`)** — sigue sin diseñar. La lógica de "la deuda aparece
  sola ahí" depende de que este batch exista.
- Nada de backend/frontend/RLS para `tiempo.ausencia`/`aprobacion_ausencia`/`excepcion` — ver
  `SCJ-PRO-08 §VI`.
- Tres preguntas nuevas anotadas en `SCJ-PRA-01` (`#10`, `#11`, `#12`), todas bloqueadas por "no
  hay solicitud manual de ausencia todavía": saldo de vacaciones por antigüedad, traslape entre
  personas del mismo grupo, mecanismo de subida de `documento_ref`.

## Preguntas nuevas

- `SCJ-PRA-01 #10` — dónde vive la tabla de saldo de vacaciones por antigüedad.
- `SCJ-PRA-01 #11` — qué es "mismo grupo" para detectar traslape de ausencias.
- `SCJ-PRA-01 #12` — mecanismo de subida de `documento_ref`.

## Nota para la retrospectiva

El hallazgo más útil de esta sesión no fue de diseño sino de lectura: `SCJ-DEC-05` se había escrito
pensando en un flujo jerárquico multi-paso, pero el primer caso de uso real (falta autodetectada)
resultó ser de un solo paso sin jerarquía. La decisión sigue siendo válida tal como está redactada
(la aplicación resuelve el aprobador, no la base) — sólo hacía falta la conversación con el usuario
para saber que "la aplicación resuelve" significa, en este caso, "cualquiera de tres roles", no una
cadena. Vale la pena, al diseñar la futura solicitud manual de vacaciones/permiso, revisar si esa sí
necesita la cadena jerárquica completa que `SCJ-DEC-05` describe, o si el patrón de un solo paso
también le basta.
