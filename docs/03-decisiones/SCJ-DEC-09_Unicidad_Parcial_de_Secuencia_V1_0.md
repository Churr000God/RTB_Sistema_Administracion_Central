# SCJ-DEC-09 · ¿Cómo se aplica la unicidad de `terminal_id` + `secuencia_local`, que sólo rige cuando `origen = terminal`?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** —

---

## Contexto

`SCJ-CDT-01 §VIII.1` define dos llaves con dos propósitos distintos: `evento_id` para idempotencia
global, y `terminal_id` + `secuencia_local` para **detección de huecos** — si llegan las secuencias
1, 2 y 4, se perdió la 3. Pero `secuencia_local` **es nulo cuando `origen = asistido`**
(`SCJ-ESP-01 §IV.2`, "ese contador es del aparato"): el registro asistido no tiene secuencia de
terminal.

No hay respuesta obvia porque una restricción `UNIQUE` convencional sobre `(terminal_id,
secuencia_local)` trataría todos los `NULL` de `secuencia_local` como valores distintos entre sí en
PostgreSQL — lo cual no rompe nada por accidente, pero tampoco expresa la regla real: la unicidad
**sólo importa** cuando el origen es `terminal`.

---

## Opciones consideradas

### Opción A — Índice único parcial

```sql
CREATE UNIQUE INDEX uq_marca_terminal_secuencia
  ON tiempo.marca (terminal_id, secuencia_local)
  WHERE origen = 'terminal';
```

**A favor:** la condición vive en el índice, declarativa, y PostgreSQL la soporta de forma nativa.
El registro asistido, con `secuencia_local` nulo, nunca entra a evaluarse. Una sola sentencia cierra
el requisito completo.
**En contra:** ninguno relevante a esta escala — es la vía estándar en PostgreSQL para exactamente
este caso.

### Opción B — Restricción condicional vía `CHECK` + columna generada

Una columna generada que colapse a un valor constante cuando `origen != 'terminal'` (por ejemplo,
usar `secuencia_local` tal cual pero forzar una restricción `UNIQUE` sobre una expresión que
incluya `origen`), combinada con un `CHECK` que valide la coherencia de `origen` y
`secuencia_local`.

**A favor:** ninguno claro frente a la opción A; es un rodeo para llegar al mismo resultado sin usar
`WHERE` en el índice.
**En contra:** más compleja de leer y de mantener sin ganar nada. PostgreSQL no soporta `CHECK`
sobre unicidad directamente — terminaría necesitando el mismo índice parcial por debajo, o un
disparador.

### Opción C — Validar en la aplicación

No hay restricción en la base; el proceso que inserta marcas de origen `terminal` verifica antes de
insertar que la pareja no exista.

**A favor:** ninguno frente a A, salvo evitar aprender la sintaxis de índice parcial.
**En contra:** dos rutas de inserción (o una migración de datos) que no pasen por ese código dejan
huecos sin detectar — justo el requisito que esta llave existe para cumplir. Contradice el principio
de `SCJ-ESP-01 §V` de que la evidencia de integridad no debe depender de que la aplicación se porte
bien.

---

## Decisión

**Opción A — índice único parcial**, tal como está redactado en el contexto:
`CREATE UNIQUE INDEX uq_marca_terminal_secuencia ON tiempo.marca (terminal_id, secuencia_local)
WHERE origen = 'terminal';`

## Por qué

Es la vía nativa de PostgreSQL para exactamente este caso, y las opciones B y C no ofrecen ninguna
ventaja a cambio de su complejidad o su riesgo: B llega al mismo resultado por un camino más largo,
C saca la garantía de la base y la deja depender de que la aplicación se porte bien —lo que
`SCJ-ESP-01 §V` prohíbe para evidencia de integridad.

## Consecuencias

Se vuelve fácil: detectar huecos de secuencia por terminal es una consulta directa sobre `marca`
filtrada por `origen = 'terminal'`, sin `CASE` ni lógica adicional para ignorar los nulos de otros
orígenes.

Se vuelve difícil: nada nuevo — es la razón por la que se eligió.

Queda cerrado para siempre: ninguna ruta de inserción de marcas de `origen = 'terminal'` puede
evadir esta restricción, porque vive en el índice, no en el código que inserta.

---

## Cómo se verifica

Insertar dos marcas de `origen = terminal` con la misma pareja `(terminal_id, secuencia_local)` y
confirmar que la segunda falla; insertar dos marcas de `origen = asistido` con `secuencia_local`
nulo y confirmar que ambas se aceptan. Ver `SCJ-CVA-01`.

---

## Revisión posterior a la implementación

*(se llena al construir)*
