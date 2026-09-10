# Notas de traspaso

**Sistema de Control de Jornada**
Folio SCJ-ENT-02 · Versión 1.0 · 2 de octubre de 2026

Notas de la sesión de traspaso del subsistema de Tiempo.

> **Por qué esta sesión existe.** Quien diseñó el subsistema de Tiempo termina su participación y se
> va. Quien queda como responsable **no lo diseñó**. Si el traspaso no ocurre en esta sesión, no
> ocurre nunca, y el primer problema del subsistema se va a resolver leyendo código a ciegas.

---

## I. Recorrido tabla por tabla

Para cada tabla: qué guarda, por qué está así, y qué decisión la explica.

| Tabla | Qué guarda | Decisión que la explica | Nota |
|---|---|---|---|
| | | | |

---

## II. Las trampas

**Lo que parece obvio y no lo es.** El apartado más útil del documento.

| Qué parece | Qué es en realidad | Qué pasa si se toca |
|---|---|---|
| | | |

Ejemplos de lo que va aquí: una restricción que no se ve leyendo el DDL porque vive en un
disparador · una columna que parece redundante y congela un valor a propósito · un índice cuyo orden
de columnas importa · un valor predeterminado que la aplicación asume.

---

## III. Qué se intentó y se descartó

Para que nadie lo vuelva a intentar sin saber que ya se probó.

| Qué se intentó | Por qué se descartó |
|---|---|
| | |

---

## IV. Qué quedó a medias

**Deuda técnica reconocida.** Ver también `SCJ-ENT-03`.

| Qué | Estado | Qué falta |
|---|---|---|
| | | |

---

## V. Cómo correr el generador

*(procedimiento completo, con la semilla documentada y qué esperar de la salida)*

---

## VI. Qué haría distinto si empezara de nuevo

**La última pregunta de la sesión, y suele ser la más valiosa.**

*(respuesta textual, sin editar)*

---

## VII. Verificación del traspaso

Se da por hecho cuando quien recibe puede, sin ayuda:

| | Verificación |
|---|---|
| | Levantar la base desde cero con los archivos del repositorio |
| | Generar datos sintéticos y cargarlos |
| | Correr las cinco consultas de validación e interpretar el resultado |
| | Explicar por qué una marca no se puede modificar |
| | Localizar dónde cambiar un parámetro de política |

---

*Notas de traspaso · Folio SCJ-ENT-02 · V1.0*
