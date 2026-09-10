# SCJ-DEC-01 · ¿La paridad se valida con restricción declarativa, con disparador o en la aplicación?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-02
**Última revisión:** 2026-09-02

---

## Contexto

`SCJ-ESP-01 §VI.1` establece que las marcas no tienen tipo: la impar abre y la par cierra, y **el
número de marcas de un día cerrado siempre es par**.

No hay respuesta obvia porque la paridad **no es una propiedad de una fila**, sino de un conjunto de
filas agrupadas por persona y por día. Y además **sólo aplica a un día cerrado**: durante la jornada,
el número impar es el estado normal.

> Una restricción que se cumple sólo después de cierta hora no es una restricción de integridad al
> uso.

---

## Opciones consideradas

### Opción A — Restricción declarativa

**A favor:** la base garantiza la regla; ninguna ruta de escritura puede violarla.
**En contra:** PostgreSQL no permite `CHECK` sobre agregados de otras filas. Habría que forzarlo con
una vista materializada y una restricción sobre ella, o con una columna contadora denormalizada.
**Y sobre todo:** haría **imposible insertar la primera marca del día**, porque el estado impar es
legítimo mientras el día está abierto.

### Opción B — Disparador al cierre del día

**A favor:** la regla vive junto a los datos; se ejecuta pase lo que pase, venga la marca del
terminal o de una captura manual. Puede distinguir día abierto de día cerrado.
**En contra:** lógica escondida en la base, más difícil de probar y de leer. El orden de disparo con
otros disparadores puede volverse sutil.

### Opción C — En la aplicación, al procesar el día

**A favor:** el procesamiento del día ya existe —hay que emparejar marcas, calcular tramos,
clasificar tiempo—; validar la paridad ahí es un paso más del mismo proceso. Fácil de probar.
**En contra:** una escritura que no pase por la aplicación deja el dato inconsistente.

### Opción D — No validar: derivar

**A favor:** la paridad no se "viola", simplemente el día es impar y **eso es un dato, no un error**.
`SCJ-ESP-01 §VI.2` ya define qué hacer: rellenar, bloquear y encolar la excepción. Bajo esta
lectura, no hay restricción que imponer.
**En contra:** deja sin garantía estructural una regla que el documento enuncia como invariante.

---

## Decisión

**Opción C — validación en la aplicación, dentro del proceso de cierre del día.**

Al cerrar el día, el sistema cuenta las marcas de la persona en ese día:

- Si el conteo es par (`n % 2 == 0`), el día **procede a carga y cálculo**: emparejamiento de
  marcas, cómputo de tramos y clasificación de tiempo.
- Si el conteo es impar (`n % 2 != 0`), el sistema **no calcula**: genera una **excepción
  pendiente de resolver**, conforme a `SCJ-ESP-01 §VI.2` (rellenar, bloquear, encolar).

---

## Por qué

La paridad no es propiedad de una fila, es de un conjunto, y sólo aplica a día cerrado. Validarla
en el mismo paso donde ya se procesa el día —emparejar marcas, calcular tramos— evita duplicar
lógica en otro lugar, es fácil de probar, y no exige forzar un `CHECK` sobre agregados que
PostgreSQL no soporta de forma declarativa (Opción A) ni esconder la regla en un disparador
(Opción B). Es la misma lectura de fondo que la Opción D —el día impar no es un error sino un dato
a resolver por excepción—, sólo que aquí queda como un paso explícito y verificable del proceso de
cierre, no implícito.

---

## Consecuencias

- El cierre de día queda en tres pasos: (1) contar marcas de la persona en el día, (2) si es par,
  procesar —emparejar, calcular tramos, clasificar tiempo—, (3) si es impar, crear la excepción y
  bloquear/encolar sin calcular.
- Cualquier escritura que no pase por el proceso de cierre de la aplicación queda sin esta
  validación — riesgo aceptado, ya señalado en el "en contra" de la Opción C.
- `db/consultas/validacion/01_paridad.sql` queda como auditoría de segunda línea, fuera del flujo
  normal de cierre.

---

## Cómo se verifica

`db/consultas/validacion/01_paridad.sql` — cuenta días con número impar de marcas por persona y
periodo, que es además el requisito de conteo de `SCJ-ESP-01 §VI.2`.

---

## Revisión posterior a la implementación

*(se llena al construir)*
