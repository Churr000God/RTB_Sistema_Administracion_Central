# SCJ-DEC-02 · ¿El saldo del banco de horas se calcula al vuelo o se materializa?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** —

---

## Contexto

`SCJ-ESP-01 §VI.6` exige que la deuda se salde dentro de una ventana configurable de seis meses,
con umbrales de alerta calculados como porcentaje de la jornada semanal de cada persona.

La consulta más exigente no es *"¿cuál es el saldo hoy?"* sino **"¿cuál era el saldo el 14 de
marzo?"** — porque de ahí sale la clasificación del tiempo entre reposición y extra
(`SCJ-ESP-01 §VI.5`), y esa clasificación debe poder recalcularse igual años después.

> El documento lo enuncia como pregunta abierta explícita: *"hay argumentos válidos de los dos
> lados"*.

---

## Opciones consideradas

### Opción A — Calcular al vuelo sobre las marcas

**A favor:** una sola fuente de verdad. El saldo nunca puede quedar inconsistente con las marcas
porque no existe por separado. Una corrección sobre una marca de marzo se propaga sola. Con 32
eventos diarios, el costo de recalcular seis meses es despreciable.
**En contra:** el cálculo depende de la jornada vigente en cada fecha, de los topes vigentes en cada
año y de las ausencias; es una consulta cara de escribir y difícil de leer. Y la clasificación de
tiempo depende del saldo **en el momento**, lo que introduce una recursión que hay que resolver con
cuidado.

### Opción B — Materializar el saldo y actualizarlo incrementalmente

**A favor:** consulta inmediata. La clasificación en reposición o extra se resuelve leyendo un
número. Los umbrales y alertas se evalúan sin recorrer el histórico.
**En contra:** dos fuentes de verdad. Una corrección sobre una marca vieja obliga a recalcular hacia
adelante, y si algo falla el saldo miente sin avisar. **Es el clásico caso donde el dato derivado
sobrevive al dato del que deriva.**

### Opción C — Libro de movimientos

Ni un total ni un recálculo: una tabla de **movimientos de saldo** —cargos por deuda, abonos por
reposición, cancelaciones por descuento o condonación— cada uno con su fecha, motivo y autor. El
saldo a cualquier fecha es la suma de los movimientos hasta esa fecha.

**A favor:** el saldo a una fecha pasada es una suma acotada, no un recálculo del mundo. Descontar y
condonar exigen motivo y autor permanentes (`§III.6`), y en este modelo eso es natural: son
movimientos, no cambios de un número. La corrección de una marca genera un movimiento de ajuste
visible, en lugar de reescribir la historia.
**En contra:** más tablas y más disciplina. Si un movimiento no se genera, el saldo queda mal y no
hay forma de detectarlo comparando con las marcas.

---

## Decisión

**Opción C, con un refinamiento: libro de movimientos como única fuente de verdad, más un total
materializado de sólo lectura.**

`tiempo.banco_de_horas` guarda una fila por persona con `monto` — el saldo vigente — y
`vivo_desde` — desde cuándo ese saldo es distinto de cero, útil para los umbrales de aviso y
escalamiento de `SCJ-ESP-01 §VI.6` sin recorrer el histórico en cada consulta. Pero ninguna de las
dos columnas se escribe con `UPDATE` directo: un disparador las recalcula cada vez que se inserta
un `tiempo.movimiento_de_saldo`. El saldo a una fecha pasada sigue siendo, siempre, la suma de
movimientos hasta esa fecha — el total materializado es caché, no dato.

Cinco tipos de movimiento, no cuatro: las cuatro salidas de `SCJ-ESP-01 §VI.6`
(`cubrir`/`arrastrar`/`descontar`/`condonar`) resuelven saldo existente, pero ninguna lo genera.
Falta el movimiento que carga la deuda: al corte quincenal, si `horas_esperadas − horas_trabajadas
> 0`, se inserta un movimiento `generado_quincena` con ese monto. Si el resultado es cero o
negativo, no se inserta nada — el excedente se resuelve como tiempo extraordinario, nunca como
saldo a favor (no existe saldo a favor acumulable).

## Por qué

La Opción A (calcular al vuelo) resuelve bien "¿cuál es el saldo hoy?" pero la consulta que
`SCJ-ESP-01 §VI.6` exige de verdad es "¿cuál era el saldo el 14 de marzo?" — y recalcular seis
meses de jornadas, topes y ausencias vigentes en cada fecha pasada para responder eso es frágil y
caro de razonar. La Opción B falla por la misma razón que ya se conoce de otros derivados: el
dato calculado sobrevive al dato del que deriva si algo se desincroniza.

El libro de movimientos evita ambos problemas porque el saldo a cualquier fecha —pasada o
presente— es la misma operación: sumar hasta esa fecha. El total materializado no compite con
eso; sólo evita que la lectura más común (el saldo *ahora*) pague el costo de una suma cada vez.

## Consecuencias

Se vuelve fácil: auditar quién autorizó cada cambio de saldo (motivo y autor viven en el
movimiento, no en un campo sobrescrito); reconstruir el saldo histórico sin lógica especial;
agregar una quinta o sexta salida sin migrar nada, sólo un valor más de `CHECK`.

Se vuelve difícil: si un movimiento no se genera (por ejemplo, el corte quincenal falla a medias),
el total materializado queda mal y nada lo detecta solo — hace falta una consulta de reconciliación
periódica que compare el total contra la suma de movimientos.

Queda cerrado para siempre: `banco_de_horas.monto` y `.vivo_desde` nunca se escriben fuera del
disparador. Cualquier corrección de saldo pasa por un movimiento nuevo, nunca por un `UPDATE`
directo a la fila de saldo.

---

## Cómo se verifica

`db/consultas/validacion/02_saldo_a_fecha.sql` — saldo del banco de horas de una persona **a una
fecha dada del pasado**, ejecutado dos veces con meses de diferencia y con el mismo resultado.

---

## Revisión posterior a la implementación

*(se llena al construir)*
