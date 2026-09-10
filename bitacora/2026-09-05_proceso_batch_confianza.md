# 2026-09-05 · Sesión — Batch de jornada de_confianza (`SCJ-PRO-14`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (octavo y último `SCJ-PRO` del día, después de `07` a `13`).

---

## Qué se hizo

Discutido en el chat, escrito `SCJ-PRO-14` — el más simple de los tres batches, y el último
proceso identificado hoy. **Sin cambios de esquema**, igual que `SCJ-PRO-13`: `tiempo.dia.origen`
ya tenía `'automatico_confianza'`, `horas_totales` ya era nullable, `corrida_batch.tipo_batch` ya
incluía `'de_confianza'`.

## Qué se decidió

- **El patrón semanal de una persona `de_confianza` es un formalismo, no se consulta.** El batch
  marca **todos** los días como trabajados, sin distinguir esperado/no esperado — ni domingo ni
  festivo se filtran, se crean igual que cualquier otro día (la prima especial la calcula nómina
  después, derivando la fecha, fuera de este repositorio).
- **`horas_totales = NULL`, nunca `0`** — no hay marca ni patrón real que contar; `NULL` es "sin
  dato", no "trabajó cero horas".
- **Misma orquestación que `SCJ-PRO-12`/`13`** — job + botón, `tiempo.corrida_batch`, idempotente
  por persona. Reutilizada sin volver a discutirla.
- Nunca se genera `marca`/`tramo` sintéticos — decisión ya tomada antes de hoy, sólo se ratificó.

## Qué quedó pendiente

- El batch en sí — el más simple y de menor riesgo de los tres, puede construirse primero.
- Job/botón/RLS compartidos con los otros dos batches — nada existe todavía.

## Preguntas nuevas

- Ninguna.

## Nota de cierre del día

Con este documento, el subsistema de Tiempo tiene **8 `SCJ-PRO` completos** (`07` a `14`) — el
conjunto identificado al arrancar la sesión de hoy queda cubierto por completo. Los tres batches
(`SCJ-PRO-12`/`13`/`14`) comparten una sola orquestación diseñada una vez en `SCJ-PRO-12` y
reutilizada sin fricción en los otros dos — señal de que decidir bien la orquestación temprano
ahorró tres rondas de preguntas repetidas. Siguiente paso real: compilar el plan de implementación
con `SCJ-MOD`/`SCJ-DEC`/los 8 `SCJ-PRO` (mismo patrón que Personas/Estructura Organizacional) y
empezar a construir — probablemente el batch `de_confianza` primero (menor riesgo), después
`cierre_dia`/`corte_quincenal` juntos con pruebas reales.
