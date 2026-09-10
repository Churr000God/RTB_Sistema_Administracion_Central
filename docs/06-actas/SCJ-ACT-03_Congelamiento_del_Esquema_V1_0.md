# Acta — Congelamiento del esquema

**Sistema de Control de Jornada**
Folio SCJ-ACT-03 · Versión 1.0 · 25 de septiembre de 2026

**A partir de esta fecha el esquema no cambia.** Corresponde a la tarea J3.1 del plan.

---

## I. Qué significa congelar

Lo que venga después son **ajustes de parámetros, no de estructura**.

Si en la operación aparece algo que exige cambiar el esquema, **se anota como pendiente para una
versión posterior** — no se cambia sobre la marcha con datos reales adentro.

---

## II. Lo que se congela

| | |
|---|---|
| Esquema | `tiempo` |
| Versión | |
| Última migración aplicada | |
| Huella del DDL | *(salida de `sha256sum db/ddl/*.sql`)* |
| Fecha y hora | 25 de septiembre de 2026 |

---

## III. Verificación previa

| # | Verificación | |
|---|---|---|
| 1 | Los dos subsistemas funcionan integrados | |
| 2 | La frontera de `SCJ-FRO-01` sigue intacta | |
| 3 | No quedan migraciones pendientes de aplicar | |
| 4 | La documentación corresponde a lo que está construido | |
| 5 | `SCJ-DIC-01` refleja el esquema real | |
| 6 | Las cinco consultas de validación pasan | |
| 7 | `SCJ-TRZ-01` no tiene requisitos en estado *Pendiente* sin justificación | |

---

## IV. Pendientes que quedan fuera del congelamiento

Cambios de estructura identificados y **deliberadamente pospuestos**.

| # | Cambio | Por qué se pospone | Cuándo se retomaría |
|---|---|---|---|
| | | | |

---

## V. Procedimiento para un cambio posterior

Si después de esta fecha resulta indispensable cambiar el esquema:

1. Se documenta el motivo por escrito
2. Se acuerda entre ambos responsables — **no se resuelve de forma unilateral**
3. Se escribe una migración, nunca un cambio directo sobre la base
4. Se actualiza `SCJ-DIC-01` y la decisión de diseño afectada
5. Se levanta una versión nueva de esta acta

---

## VI. Firma

| | Nombre | Fecha |
|---|---|---|
| Subsistema de Personas | | |
| Subsistema de Tiempo | | |

---

*Acta de congelamiento · Folio SCJ-ACT-03 · V1.0*
