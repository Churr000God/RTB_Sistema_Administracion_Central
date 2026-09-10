# SCJ-DEC-08 · ¿`evento_id` es la clave primaria de la marca, o una clave única alterna junto a una subrogada?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** 2026-09-02

---

## Contexto

`SCJ-CDT-01 §VIII.2` exige que `evento_id` **nazca en el origen** —el terminal o, en captura
asistida, al abrir el formulario— y sea **único globalmente**. Es la llave que hace segura la
idempotencia: un evento reenviado se reconoce por su `evento_id`, sin importar cuántas veces llegue.

Eso no obliga a que `evento_id` sea la clave primaria de la tabla `marca`, pero lo permite. La
pregunta es si conviene además una clave subrogada (`id bigserial` o similar), generada por la base
al insertar.

---

## Opciones consideradas

### Opción A — `evento_id` como clave primaria

`marca(evento_id UUID PRIMARY KEY, ...)`.

**A favor:** una sola llave, sin duplicar el concepto de identidad de la fila. Cualquier referencia
externa (una corrección, una excepción) apunta directo al mismo identificador que ya trae el
contrato — no hay que traducir entre dos espacios de identificadores.
**En contra:** los UUID como clave primaria fragmentan el índice físico más que un entero
secuencial, porque llegan en orden aleatorio, no en orden de inserción. Con el volumen de este
proyecto (~32 marcas/día, `SCJ-CTX-01 §V`) el costo es irrelevante, pero es la razón habitual por la
que se evita en sistemas de mayor escala.

### Opción B — Subrogada + `evento_id` único

`marca(id bigserial PRIMARY KEY, evento_id UUID UNIQUE NOT NULL, ...)`.

**A favor:** la clave primaria crece en orden de inserción, más amigable para el índice y para
claves foráneas compactas en tablas grandes (`tramo`, `correccion`). Desacopla la identidad interna
de la fila del identificador de transporte, que en teoría podría cambiar de formato sin tocar las
referencias internas.
**En contra:** dos identificadores para el mismo concepto. Cualquier consulta que reciba un
`evento_id` desde afuera —una corrección que llega por API, por ejemplo— tiene que resolverlo contra
`id` antes de poder unir con otras tablas, o las tablas dependientes tienen que decidir contra cuál
de los dos apuntan.

---

## Decisión

**Opción B — subrogada + `evento_id` único.** `marca(id bigint GENERATED ALWAYS AS IDENTITY
PRIMARY KEY, evento_id uuid UNIQUE NOT NULL, ...)`. Ya estaba implementada así en `02_tiempo.sql`
como elección física provisional mientras esta decisión seguía abierta; queda confirmada como
definitiva, sin cambios al DDL.

---

## Por qué

Consistente con la convención universal del repo ("clave primaria siempre `id`", `CONVENCIONES.md
§II`) y con que `tramo`/`correccion` referencian `marca` con volumen creciente — la PK entera
secuencial es más compacta para esas claves foráneas que un UUID. El costo de Opción B (dos
identificadores) se acepta porque `evento_id` sigue siendo `UNIQUE NOT NULL` y resuelve la
idempotencia igual de bien como llave de negocio.

---

## Consecuencias

- Sin cambios de esquema — el DDL ya implementaba esta opción.
- Cualquier referencia externa que llegue por `evento_id` (una corrección desde la API, por
  ejemplo) debe resolverse contra `id` antes de unir con `tramo`/`correccion`/`excepcion`.
- Queda como convención confirmada para el resto de entidades del proyecto: PK siempre `id`
  subrogado, llave de negocio externa siempre `UNIQUE` aparte — no hay más entidades con este
  mismo dilema pendiente.

---

## Cómo se verifica

Insertar el mismo `evento_id` dos veces y confirmar que la segunda inserción se resuelve como
duplicado sin crear una fila nueva (`SCJ-CDT-01 §VIII.1`), y medir el tamaño del índice de la clave
elegida con el volumen de `SCJ-VOL-01`.

---

## Revisión posterior a la implementación

*(se llena al construir)*
