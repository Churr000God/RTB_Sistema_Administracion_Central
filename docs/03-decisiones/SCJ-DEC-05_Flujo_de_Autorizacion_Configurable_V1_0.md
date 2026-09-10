# SCJ-DEC-05 · ¿Cómo se modela un flujo de autorización de pasos variables sin cablear ninguno?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** 2026-09-02

---

## Contexto

`SCJ-ESP-01 §VI.8` exige que una ausencia soporte un **flujo de autorización de varios pasos,
configurable**. No dos pasos, no tres: un número variable, distinto según el tipo de ausencia y
posiblemente según quién la solicita.

**Lo que no se puede hacer:** una columna `autorizado_por_jefe` y otra `autorizado_por_direccion`.
Eso cablea el flujo en el esquema, y el día que se agregue un paso hay que migrar la tabla.

> Es el problema de diseño con más soluciones válidas del proyecto, y por eso está aquí como
> decisión y no como detalle de implementación.

---

## Opciones consideradas

### Opción A — Definición de flujo + instancias de paso

Dos niveles: una **definición** —qué pasos existen para este tipo de ausencia, en qué orden, quién
aprueba cada uno— y una **instancia** por solicitud, con una fila por paso y su estado.

**A favor:** agregar un paso es insertar una fila en la definición, sin tocar el esquema. La
instancia es una bitácora completa de quién aprobó qué y cuándo. Consultar "qué falta" es un filtro.
**En contra:** dos tablas más y la pregunta de qué pasa con las solicitudes en curso cuando la
definición cambia a la mitad — que hay que responder, no ignorar.

### Opción B — Máquina de estados con tabla de transiciones

El flujo es un grafo: estados y transiciones permitidas, cada una con su rol autorizado.

**A favor:** admite bifurcaciones, rechazos, devoluciones y saltos, no sólo una secuencia lineal.
Muy general.
**En contra:** más general de lo que el caso necesita. Con ocho personas y un flujo de dos o tres
pasos, la generalidad se paga sin usarse. Y una máquina de estados mal configurada puede dejar una
solicitud atrapada sin salida.

### Opción C — Cadena de aprobaciones sin definición previa

Sólo la tabla de aprobaciones. Quién debe aprobar se resuelve fuera de la base, en la aplicación,
consultando el organigrama.

**A favor:** el esquema queda mínimo. El flujo puede ser tan complejo como se quiera sin tocar la
base.
**En contra:** **contradice `SCJ-ESP-01 §VI.9`** — ninguna regla de negocio codificada. Saca el
flujo del alcance del modelo de datos, que es justamente el objeto de este proyecto. Y el
organigrama vive del otro lado de la frontera.

---

## La pregunta que hay que responder de todos modos

Con cualquiera de las tres:

> **¿Qué pasa con una solicitud en curso cuando cambia la definición del flujo?**

Tres respuestas posibles: la solicitud sigue con la definición vigente al crearse *(vigencias otra
vez → `SCJ-DEC-04`)*, se recalcula con la nueva, o se rechaza el cambio mientras haya solicitudes
abiertas.

---

## Decisión

**Opción C — cadena de aprobaciones sin definición previa.** `tiempo.ausencia` guarda sólo el
registro de aprobación (`estado_autorizacion`, y quién aprobó cada paso). **Quién debe aprobar se
resuelve en la aplicación**, consultando el organigrama del subsistema de Personas: permiso
atómico de autorización (p. ej. `autorizar_ausencia`), asignado por `puesto_permiso` con
`heredable = true` en el puesto de **RH/responsable directo**, y heredado hacia arriba en la
jerarquía (nivel Gerencia/Dirección) cuando el flujo del tipo de ausencia exige más de un paso.

**Esto sí cruza la frontera** — a diferencia de "mostrar el nombre en un reporte" (que sólo cruza
`persona_id` en la capa de consulta), aquí Tiempo necesita **resolver una pregunta que depende del
organigrama**, y el organigrama vive enteramente en Personas. Autorizado explícitamente por Diego
en esta sesión, por ser necesario para el diseño. **Lo único que queda intacto al otro lado de la
frontera es la nómina** (salarios, cálculo de compensación) — el organigrama y los permisos ya no
se tratan como zona prohibida para esta consulta.

---

## Por qué

Opción A (definición + instancias) y B (máquina de estados) modelan un flujo que, en este proyecto,
ya existe en otro lugar: la jerarquía de puestos y el catálogo de permisos heredables del
subsistema de Personas (`RTB-ESP-01 §III.4`, ver `[[diseno-bd-scj-control-jornada]]`). Construir una
definición de flujo *dentro* de Tiempo sería duplicar esa estructura con datos que ya viven en
Personas. Opción C evita la duplicación: el flujo de aprobación de una ausencia **es** un caso más
de la pregunta general "¿quién tiene tal permiso sobre tal persona/puesto?", que el subsistema de
Personas ya resuelve.

---

## Consecuencias

- `tiempo.ausencia` no necesita tabla de "definición de flujo" ni "instancia de paso" — sólo el
  registro de aprobación por ausencia (quién aprobó, cuándo, en qué paso si el tipo exige más de
  uno).
- La aplicación, al recibir una solicitud de ausencia, consulta Personas (`puesto_permiso`,
  `asignacion`, jerarquía por `nivel`/`area`/`departamento`) para resolver la cadena de aprobadores
  vigente **en el momento de crear la solicitud**.
- **Pregunta que el propio documento de decisión exige responder — confirmada:** si el permiso de
  aprobación cambia de dueño (RH se reasigna, un puesto se vuelve heredable o deja de serlo)
  **mientras una ausencia sigue pendiente**, **la solicitud sigue con el aprobador que tenía
  vigente al crearse** — no se recalcula contra el permiso actual. Consistente con `SCJ-DEC-04`
  (vigencias): la aplicación debe resolver y **congelar** el aprobador/cadena de aprobación en el
  momento de crear la solicitud, no re-resolverlo en cada consulta posterior.
- `SCJ-FRO-01` sube a **V1.2**: se agregó la fila "Saber quién debe aprobar una ausencia" en su
  §IV, y quedó validada en la misma sesión conjunta del 2 de septiembre de 2026 (Efren Gómez,
  Personas; Luis Picasso, Tiempo) que también cerró `SCJ-ACT-01` (J1.1/J1.2).

---

## Cómo se verifica

Configurar un flujo de dos pasos, crear una solicitud, agregar un tercer paso a la definición, y
verificar que la solicitud en curso se comporta como se decidió — sin migración de esquema.

---

## Revisión posterior a la implementación

*(se llena al construir)*
