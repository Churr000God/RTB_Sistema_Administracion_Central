# Acta — Modelo conceptual y acuerdo de frontera

**Sistema de Control de Jornada**
Folio SCJ-ACT-01 · Versión 1.1 · 2 de septiembre de 2026

Sesión conjunta de diseño. Corresponde a las tareas J1.1 y J1.2 del plan.

> **Estado: cerrado.** La preparación de Diego del 29 de agosto (`SCJ-MOD-01`, `SCJ-FRO-01 V1.1`)
> se validó en sesión conjunta real el 2 de septiembre con Efren Gómez (Personas) y Luis Picasso
> (Tiempo). La silueta de Personas de `SCJ-MOD-01 §III` se confirmó **tal cual, sin cambios**.
> J1.1/J1.2 quedan cerradas con esta firma.

---

## I. Datos de la sesión

| | |
|---|---|
| Fecha | 2 de septiembre de 2026 |
| Duración | |
| Participantes | Efren Gómez (Personas) · Luis Picasso (Tiempo) · Diego Hermilo |
| Modalidad | Presencial |

---

## II. Agenda cubierta

| # | Punto | ¿Se cubrió? |
|---|---|---|
| 1 | Presentación de las entidades del subsistema de Personas, como cajas con atributos | **Sí.** Efren Gómez confirmó la silueta de `SCJ-MOD-01 §III` **tal cual, sin cambios** |
| 2 | Presentación de la lectura del subsistema de Tiempo a partir de `SCJ-ESP-01` | Sí, en la preparación del 29 de agosto, confirmada por Luis Picasso en esta sesión |
| 3 | Dibujo del diagrama completo entre ambos | Validado en conjunto (`SCJ-MOD-01`, `diagramas/fuente/conceptual.mmd`, exportado a `diagramas/export/conceptual.svg`) |
| 4 | Identificación de las relaciones que cruzan la frontera | Sí — una sola relación, `PERSONA ||--|| PERSONA_STUB`, con `persona_id` y la excepción `fecha_ingreso` (`SCJ-FRO-01 §V`) |
| 5 | Registro de desacuerdos y preguntas abiertas | Sin desacuerdos — ambos confirmaron el modelo sin objeciones |

---

## III. Qué se acordó

*(Confirmado en sesión conjunta el 2 de septiembre por Efren Gómez y Luis Picasso — ya no es
propuesta unilateral de Diego.)*

- `fecha_ingreso` se replica en `tiempo.persona`, de sólo lectura, como única excepción a la regla
  de frontera del §I de `SCJ-FRO-01`. `SCJ-FRO-01` sube a V1.1
- Entidades de Personas (silueta conceptual, **confirmada sin cambios**): `persona`, `expediente`,
  `puesto`, `usuario`, `permiso`, `asignacion` — atributos principales en `SCJ-MOD-01 §III`
- Entidades de Tiempo (14, confirmadas contra `SCJ-ESP-01 §III.1`): atributos principales en
  `SCJ-MOD-01 §IV`
- Diagrama conceptual completo, con la frontera marcada como única línea que cruza
- El caso nuevo de `SCJ-DEC-05` (quién aprueba una ausencia, resuelto consultando el organigrama de
  Personas) se presentó y se acepta como segunda excepción de frontera — ver `SCJ-FRO-01 §IV`

---

## IV. Desacuerdos

Lo que no quedó resuelto y cómo se va a resolver.

| # | Desacuerdo | Postura de cada lado | Cómo se resuelve | Para cuándo |
|---|---|---|---|---|
| | *(ninguno — ambos confirmaron el modelo sin objeciones)* | | | |

---

## V. Preguntas abiertas levantadas

Se trasladan a `SCJ-PRA-01`. Ninguna nueva desde la preparación en solitario — la pregunta #01
(fecha de ingreso) pasó de abierta a resuelta.

| # | Pregunta | Bloquea a |
|---|---|---|
| | | |

---

## VI. Entregables de la sesión

| Entregable | Documento | Estado |
|---|---|---|
| Diagrama conceptual | `SCJ-MOD-01` | Validado en sesión conjunta, sin cambios |
| Contrato de frontera | `SCJ-FRO-01` | §V y el caso de `SCJ-DEC-05` (§IV) firmados en §VI |
| Lista de preguntas abiertas | `SCJ-PRA-01` | Al día |

---

## VII. Aceptación

Ambos aceptan lo acordado en el §III y el contrato de frontera `SCJ-FRO-01`.

| | Nombre | Fecha |
|---|---|---|
| Subsistema de Personas | Efren Gómez | 2 de septiembre de 2026 |
| Subsistema de Tiempo | Luis Picasso | 2 de septiembre de 2026 |

---

*Acta · Folio SCJ-ACT-01 · V1.1*
