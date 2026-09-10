# 2026-09-08 · Rediseño de Ausencias + descuento de pausa unificado

**Participantes:** Diego (usuario), `orchestrator` + equipo (`db`/`backend`/`frontend`) vía
`team-orchestrator`.
**Duración:** dos cortes el mismo día, cada uno con su propio `EnterPlanMode`/`ExitPlanMode`.

---

## Qué se hizo

**Corte 1 — descuento de pausa no registrada al cerrar un día con un solo tramo:** debe existir
siempre una pausa de comida, sin importar el tipo de jornada. `tiempo.parametro` clave
`descuento_pausa_no_registrada_min` existía en el catálogo desde hace semanas, sembrada sin
consumidor (`impacta_logica=False`). `backend/app/batches/cierre_dia.py::_armar_dia_par` ahora
resta ese parámetro (vigente a la fecha, con default 60) de `horas_totales` cuando el día resultó
en exactamente 1 tramo (entró una vez, salió una vez, nunca marcó la pausa) — piso en 0, nunca
negativo. `catalogo_parametros.py` pasa esa clave a `impacta_logica=True` (primer consumidor real).

**Corte 2 — rediseño de Ausencias, pedido explícito con 2 diagramas ER del usuario:** el schema que
mandó (`tiempo.ausencia`, `tiempo.aprobacion_ausencia`) **ya existía casi exacto** en la base real
(la única diferencia real eran los tipos de PK/FK — `uuid` en el diagrama, `bigint identity` en la
base — no se migró, no fue un pedido explícito). El flujo multi-paso (`numero_paso`) también ya
estaba soportado por la tabla/trigger, aunque el RPC lo usa hoy con un solo paso fijo (decisión ya
documentada en `SCJ-PRO-08 §V`).

Dos piezas:
1. **Fórmula de horas al aprobar (`db/ddl/66_*.sql`):** `fn_ausencia_resuelve_excepcion` restaba
   `patron_semanal.minutos_comida` (dato por patrón que nadie mantenía) — pasa a restar el mismo
   parámetro global del corte 1, unificando el concepto de "descuento por pausa" en todo el
   sistema. Se agregó además una **excepción deliberada** a `SCJ-DEC-06`/`SCJ-PRO-14` ("de
   confianza siempre `NULL`, nunca un número"): cualquier ausencia resuelta de una persona
   `de_confianza` (incluso rechazada — "su horario no marca faltas") pone la jornada completa neta,
   nunca `0`; cae a `NULL` sólo si no hay patrón cargado para calcularla. Documentado como
   excepción explícita directamente en `docs/07-procesos/SCJ-PRO-14_*.md`, no como bug nuevo.
   **Detalle de Postgres real encontrado por `db` antes de aplicar:** `CREATE OR REPLACE FUNCTION`
   NO hereda `SECURITY DEFINER`/`search_path` de un `ALTER FUNCTION` anterior si no se repiten
   explícitas — sin ese fix se habría reintroducido en silencio el mismo bug de RLS sobre
   `tiempo.dia` que `51_*.sql` ya había corregido en septiembre 6.
2. **Pantalla completa (frontend + `GET /api/ausencias` nuevo):** de tarjetas-sólo-pendientes a
   tabla de TODAS las ausencias, con leyenda de los 5 tipos (`lib/tiposAusencia.ts`, molde
   `motivosRevision.ts` — catálogo espejado sin endpoint propio) y columna "Aprobado por" (nombre +
   motivo, resuelto desde `tiempo.aprobacion_ausencia` tomando el `numero_paso` más alto, sin
   asumir un solo paso aunque hoy siempre lo sea). Decisión de UI: el badge de estado muestra
   "Pendiente" tanto para `pendiente` como para `rechazada` (sólo cosmético, el dato real se
   guarda correcto) — el botón "Resolver" sigue gateado por el estado real, no por la etiqueta.
   `POST /api/ausencias/{id}/resolver` no cambió.

## Qué se decidió

- El descuento de pausa vive en un único parámetro global, no en `patron_semanal.minutos_comida`
  (que sigue existiendo, pero ya sólo para tope legal/corte quincenal — horas *esperadas*, no
  *trabajadas*).
- `de_confianza` nunca queda en `0` al resolver una ausencia, aunque eso contradiga literal el texto
  de `SCJ-PRO-14` — se documentó la excepción en el propio proceso en vez de dejarla implícita.
- No se migran los PK/FK de `bigint` a `uuid` aunque el diagrama del usuario los mostrara así.
- No se toca `corte_quincenal.py` (sigue sumando `tramo.minutos_trabajados` sin este descuento) —
  divergencia conocida entre lo que muestra Días y lo que calcula nómina, aceptada explícitamente
  para no tocar cálculo financiero sin pedido aparte.

## Qué quedó pendiente

- `corte_quincenal.py` no ve el descuento de pausa — si se quiere consistencia total con nómina,
  es un corte aparte.
- Flujo multi-paso real de aprobación (RH → Dirección) — el schema ya lo soporta, activar una
  cadena de aprobadores queda fuera de alcance (`SCJ-PRO-08` lo dejó así a propósito).
- Deep-link desde Días a la Cola de excepciones filtrada por persona/fecha — no se hizo,
  `ColaExcepcionesPage` no soporta query params hoy.

## Preguntas nuevas

-

## Nota para la retrospectiva

El usuario mandó los 2 diagramas ER como si fueran una propuesta de schema nuevo, pero casi todo ya
existía — verificarlo con un `Explore` dedicado antes de diseñar nada evitó proponer una migración
de PK/FK que nadie necesitaba. Vale la pena, ante cualquier pedido con "diagrama nuevo" de un
esquema que ya lleva semanas implementado, comparar primero contra la base real antes de asumir que
hace falta construir desde cero.
