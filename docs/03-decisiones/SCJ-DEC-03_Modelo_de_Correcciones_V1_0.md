# SCJ-DEC-03 · ¿Versionado, tabla de auditoría o registro de eventos para las correcciones?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** —

---

## Contexto

`SCJ-ESP-01 §VI.7`: una marca registrada **nunca se modifica ni se elimina**. Una corrección es un
registro nuevo que apunta a la original, con el valor corregido, el motivo, el autor y el momento.

**El requisito duro:** debe poder reconstruirse el estado del registro **tal como era en cualquier
momento del pasado**, junto con la cadena completa de correcciones.

Y a partir de enero de 2027 esto deja de ser una preferencia de diseño: es lo que una autoridad
laboral puede exigir.

---

## Opciones consideradas

### Opción A — Versionado en la misma tabla

Cada corrección inserta una fila nueva con el mismo identificador lógico y un número de versión o un
rango de vigencia. La vigente es la última.

**A favor:** consultar el estado a una fecha es un filtro por rango, sin unir tablas. Todas las
versiones tienen la misma forma.
**En contra:** toda consulta ordinaria debe acordarse de filtrar por la versión vigente, y la que se
olvide devuelve filas duplicadas en silencio. Mezcla el dato original con sus correcciones en la
misma tabla, lo que hace más fácil violar la inmutabilidad por accidente.

### Opción B — Tabla de auditoría separada

La marca vive en su tabla y se modifica; un disparador copia el estado anterior a una tabla espejo.

**A favor:** patrón conocido, la tabla principal queda limpia y las consultas ordinarias no cambian.
**En contra:** **contradice el requisito.** La marca sí se modifica; la auditoría sólo guarda copia.
Si el disparador falla o alguien lo desactiva, el histórico se pierde sin dejar rastro. La
inmutabilidad pasa a depender de que nadie toque la base directamente.

### Opción C — Registro de eventos

La marca original se inserta una vez y nunca se toca. Cada corrección es un **evento** en una tabla
aparte que apunta a la marca y describe el cambio. El estado a una fecha se obtiene aplicando los
eventos hasta esa fecha sobre el original.

**A favor:** cumple el requisito de forma literal — la marca es inmutable por construcción, no por
convención. La cadena de correcciones es el dato, no un subproducto. Motivo y autor son atributos
naturales del evento.
**En contra:** el estado vigente no es una lectura directa; requiere una vista que aplique los
eventos, o un campo derivado que hay que mantener. Más caro de consultar y más difícil de explicar.

---

## Decisión

**Opción C — registro de eventos.** `tiempo.correccion(id, marca_id, valor_corregido, motivo,
autor_id, creado_en)`. La marca original se inserta una vez y nunca se toca; cada corrección es
una fila nueva en `correccion` que apunta a la marca y describe qué valor debió tener y por qué.

## Por qué

Es la única de las tres que cumple el requisito de forma literal: la inmutabilidad de la marca
queda garantizada por construcción (no existe ningún `UPDATE` posible sobre `marca` una vez
insertada, porque el esquema no lo permite), no por convención o por confiar en que nadie la toque
directamente. A partir de enero de 2027 eso deja de ser preferencia de diseño.

La Opción A mezcla el dato original con sus correcciones en la misma tabla, lo que hace más fácil
violar la inmutabilidad sin darse cuenta. La Opción B contradice el requisito de raíz: la marca sí
se modifica, sólo que además queda copia — y esa copia depende de un disparador que puede fallar o
deshabilitarse sin dejar rastro.

## Consecuencias

Se vuelve fácil: motivo y autor son atributos naturales de la corrección, no columnas extra que
sobrescriben la fila original. Auditar cuántas veces se corrigió una marca es contar filas en
`correccion`, no inspeccionar un historial de versiones.

Se vuelve difícil: el estado vigente de una marca corregida no es una lectura directa — requiere
una vista o consulta que aplique la corrección más reciente sobre el original. Es exactamente el
costo que la Opción C anticipa y que `db/consultas/validacion/05_reconstruccion_historica.sql`
tiene que demostrar que vale la pena.

Queda cerrado para siempre: `tiempo.marca` no lleva `UPDATE` ni `DELETE` en ningún flujo de la
aplicación — sólo `INSERT`. Cualquier corrección, sin excepción, pasa por `tiempo.correccion`.

---

## Cómo se verifica

`db/consultas/validacion/05_reconstruccion_historica.sql` — **la consulta más exigente del
proyecto**: reconstruir el estado de un registro corregido tal como era en una fecha pasada, con la
cadena completa de correcciones aplicadas.

---

## Revisión posterior a la implementación

*(se llena al construir)*
