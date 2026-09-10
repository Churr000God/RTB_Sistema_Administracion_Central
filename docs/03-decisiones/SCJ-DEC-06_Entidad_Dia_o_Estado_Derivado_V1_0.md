# SCJ-DEC-06 · ¿El día es una entidad materializada con estado propio, o un estado derivado de sus marcas?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** —

---

## Contexto

`SCJ-ESP-01 §III.1` lista **día** como concepto que el modelo debe representar: *"el conjunto de
marcas de una persona en una fecha, con su estado"*. `§VI.2` exige que ese estado incluya
**bloqueado**: al cierre, si el número de marcas es impar, el día queda bloqueado para
procesamiento posterior y entra a la cola de excepciones.

No hay respuesta obvia porque el día **es, en principio, calculable**: sus marcas ya están en la
tabla `marca`, y su número de tramos, su jornada trabajada y su clasificación de tiempo se derivan
de ahí. Pero un derivado puro —una vista— **no tiene dónde guardar un estado que persiste**: el
bloqueo de un día no es una propiedad de sus marcas en este instante, es una decisión que se tomó
al cierre y que debe sobrevivir a que lleguen marcas tardías después (`§VI.2`, "marca tardía sobre
día cerrado no reabre").

---

## Opciones consideradas

### Opción A — Entidad materializada `dia`

Una fila por `(persona_id, fecha)`, con columnas propias: `estado` (`abierto` / `cerrado` /
`bloqueado`), `jornada_trabajada`, `fecha_cierre`.

**A favor:** el estado tiene dónde vivir sin artificios. Consultar "días bloqueados por persona y
periodo" (`§VI.2`, requisito de conteo) es una lectura directa, sin recalcular nada.
**En contra:** introduce una segunda fuente de verdad junto a `marca`. Si el proceso de cierre falla
a mitad de camino, `dia` y `marca` pueden quedar inconsistentes. Hay que decidir qué evento crea la
fila: ¿la primera marca del día, o el proceso de cierre?

### Opción B — Estado puramente derivado (vista o cálculo en consulta)

No existe tabla `dia`. Todo —tramos, paridad, jornada trabajada— se calcula sobre `marca` cada vez
que se necesita.

**A favor:** una sola fuente de verdad. Ningún riesgo de desincronización.
**En contra:** no resuelve el requisito que originó la pregunta. El bloqueo **no es derivable de las
marcas de hoy**: es la decisión que se tomó ayer al cierre, con la información que había entonces.
Un derivado puro recalcularía el bloqueo cada vez y podría cambiar de opinión si llegan marcas
tardías — exactamente lo que `§VI.2` prohíbe.

### Opción C — Híbrida: excepción/bloqueo materializados, el resto derivado

No existe una entidad `dia` completa, pero la decisión de bloqueo en sí —una vez tomada— se
registra como un hecho aparte (por ejemplo, en la entidad de excepción de `SCJ-DEC-07`, o en una
tabla mínima `dia_bloqueado(persona_id, fecha, motivo, fecha_bloqueo)`). El resto —tramos, jornada
trabajada, clasificación— se sigue calculando de `marca` en el momento de consultar, pero **usando
el conjunto de marcas vigente al momento del cierre**, no el actual, cuando el día está bloqueado.

**A favor:** una sola fuente de verdad para los datos que sí son recalculables (las marcas), y un
registro explícito sólo para la decisión que **no lo es** (el bloqueo). Evita la tabla `dia`
completa sin renunciar a la garantía de persistencia que el requisito exige.
**En contra:** dos lugares a los que mirar para entender el estado de un día: la marca y, si está
bloqueado, el registro de bloqueo. Depende de cómo quede resuelto `SCJ-DEC-07`.

---

## Decisión

**Opción A — entidad materializada `dia(id, persona_id, fecha, estado, horas_totales, ...)`**, con
un cuarto estado que las opciones originales no contemplaban: `abierto` / `cerrado` / `bloqueado` /
**`revisado`**. Un día bloqueado no vuelve a `cerrado` cuando RH lo revisa — pasa a `revisado`,
para que quede registro de que alguien lo miró sin perder el hecho de que en su momento estuvo
bloqueado.

La fila se crea al cierre (no con la primera marca): el proceso de cierre diario es el que arma
`tramo` a partir de las marcas del día, calcula `horas_totales` y decide el `estado` inicial.

## Por qué

Un derivado puro (Opción B) recalcularía el bloqueo cada vez que se consulta, y podría cambiar de
opinión si llegan marcas tardías — exactamente lo que `§VI.2` prohíbe ("marca tardía sobre día
cerrado no reabre"). La Opción C evita la tabla `dia` completa, pero el requisito no es sólo
"recordar que se bloqueó": también hace falta un lugar natural para `horas_totales` y el resto de
lo que el día agrega, y separar eso en dos estructuras (marca de bloqueo aparte + cálculo derivado
del resto) es más superficie de sincronización que una sola tabla con estado propio.

## Consecuencias

Se vuelve fácil: contar días bloqueados por persona y periodo es un filtro directo. Distinguir "se
bloqueó y nadie lo ha visto" de "se bloqueó y RH ya lo revisó" es una lectura del `estado`, no una
consulta que cruce `dia` contra `excepcion` para inferirlo.

Se vuelve difícil: `dia` y `marca` son ahora dos fuentes que pueden desincronizarse si el proceso
de cierre falla a la mitad — necesita ser una transacción, no una serie de pasos sueltos. Una
marca tardía sobre un día `revisado` (no sólo `bloqueado`) sigue siendo un caso a decidir: por
ahora se trata igual que sobre un día `bloqueado` — se registra, no reabre nada — pero queda como
refinamiento a probar en `SCJ-CVA-01`.

Queda cerrado para siempre: ningún proceso reabre un día `cerrado`, `bloqueado` o `revisado`
automáticamente. Cambiar de `bloqueado` a `revisado` es la única transición manual permitida, y
sólo la hace RH.

---

## Cómo se verifica

Una consulta que liste días bloqueados por persona y periodo, y que — tras insertar una marca
tardía sobre un día ya bloqueado — demuestre que el bloqueo original no cambia sin intervención
explícita de RH. Ver `SCJ-CVA-01`.

---

## Revisión posterior a la implementación

*(se llena al construir)*
