# 2026-09-05 · Sesión — Proceso de corte quincenal (`SCJ-PRO-13`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (séptimo proceso seguido en el mismo día, después de
`SCJ-PRO-07` a `12`).

---

## Qué se hizo

Discutido en el chat, escrito `SCJ-PRO-13`. Propuse dejar `clasificacion_de_tiempo.tipo` fuera de
este documento (algoritmo aparte, sin diseñar) — el usuario pidió explícito incluirlo en el mismo
documento, y con razón: la reposición sólo se puede determinar sabiendo si había deuda, y eso sólo
se sabe al momento del corte. Quedaron combinados a propósito.

**Sin cambios de esquema** — es el primer `SCJ-PRO` del día que no tocó `db/ddl/`. Los valores que
necesita (`clasificacion_de_tiempo.tipo`, `movimiento_de_saldo.tipo`, `corrida_batch.tipo_batch`)
ya existían correctos desde antes; sólo faltaba el algoritmo que los usa.

## Qué se decidió

- **Periodos fijos: 1-15 y 16-30 de cada mes.** Meses cortos (febrero) cierran en el último día
  real. **Meses de 31 días no generan un tercer corte** — el día 31 se cuenta en el periodo
  siguiente (el `[1,15]` que entra, que en la práctica arranca desde ese 31).
- **Clasificación por tramo, cronológica, con acumulado dentro del periodo** — ordinario mientras
  no se rebase lo esperado; excedente con deuda previa → reposición (hasta agotarla, resta
  `banco_de_horas` vía `movimiento_de_saldo` tipo `cubrir`); excedente sin deuda → extra, sin tocar
  el banco de horas.
- **Déficit de periodo: todo lo trabajado es ordinario**, el faltante genera `generado_quincena` —
  nunca hay clasificación negativa por tramo.
- **Un día `bloqueado` se excluye del cálculo (ni esperado ni trabajado); un día `abierto` salta a
  la persona completa** (cierre de día no terminó para ella) — misma lógica de aislamiento por
  persona que `SCJ-PRO-12`.
- **Misma orquestación que `SCJ-PRO-12`**, reutilizada sin volver a preguntar: job + botón manual,
  `tiempo.corrida_batch`, idempotente por persona.
- Aclaración de vocabulario: el usuario dijo "excedente" para el caso sin deuda — confirmado que
  el valor real sigue siendo `extra` (ya en el `CHECK`), sólo cambió cómo lo describía hablando.

## Qué quedó pendiente

- **El batch en sí** — mismo criterio de riesgo que `SCJ-PRO-12`, se construye con pruebas reales,
  no de un intento sin verificar.
- Job programado (corre el 1° y el 16°) + botón manual — no existen.
- RLS de `clasificacion_de_tiempo`/`movimiento_de_saldo`/`banco_de_horas` — no existen.
- Qué pasa si se corrige una marca después de que su periodo ya tuvo corte — anotado como fuera de
  alcance de este documento, sin resolver todavía.

## Preguntas nuevas

- Ninguna sin resolver en esta sesión.

## Nota para la retrospectiva

Primer `SCJ-PRO` del día que no requirió tocar el esquema — señal de que el modelo de datos
(`tipo` de `clasificacion_de_tiempo`/`movimiento_de_saldo`, `corrida_batch`) ya estaba bien pensado
desde antes de que existiera el proceso que lo usa. Cierre de día y corte quincenal quedan como los
dos batches de mayor riesgo pendientes de programar — vale la pena construirlos juntos en la misma
sesión de implementación, ya comparten orquestación y el segundo depende directo del primero.
