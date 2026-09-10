# Documento final

**Sistema de Control de Jornada · Diseño del subsistema de Tiempo**
Folio SCJ-ENT-01 · Versión 1.0 · 2 de octubre de 2026

Hilo narrativo del proyecto. **Enlaza a los demás documentos; no los repite.**

---

## I. El problema

*(dos párrafos)* Qué se encontró, por qué el control verbal no sirve, y qué exige la ley a partir de
enero de 2027. Ver `SCJ-CTX-01`.

---

## II. Qué se diseñó

*(dos párrafos)* El alcance, la frontera entre subsistemas y por qué existe. Ver `SCJ-FRO-01`.

---

## III. Cómo se llegó al modelo

El recorrido: conceptual → lógico → físico, y qué cambió en cada paso.

| Etapa | Documento | Qué se resolvió ahí |
|---|---|---|
| Conceptual | `SCJ-MOD-01` | |
| Lógico | `SCJ-MOD-02`, `SCJ-NRM-01` | |
| Físico | `SCJ-MOD-03`, `SCJ-DIC-01` | |

---

## IV. Las cinco decisiones

**El apartado central del documento.** Una página por decisión: la pregunta, las opciones, la
elección, el porqué, y —lo más importante— **qué se aprendió al implementarla**.

| # | Pregunta | Decisión | ¿Se sostuvo al construir? |
|---|---|---|---|
| `SCJ-DEC-01` | Validación de la paridad | | |
| `SCJ-DEC-02` | Saldo del banco de horas | | |
| `SCJ-DEC-03` | Modelo de correcciones | | |
| `SCJ-DEC-04` | Vigencias temporales | | |
| `SCJ-DEC-05` | Flujo de autorización | | |

---

## V. Cómo se probó

Generador de datos sintéticos con los siete casos difíciles (`SCJ-GEN-01`), cinco consultas de
validación (`SCJ-CVA-01`), pruebas de volumen hasta ×1000 (`SCJ-VOL-01`) e índices justificados uno
por uno (`SCJ-IDX-01`).

**La matriz de trazabilidad** (`SCJ-TRZ-01`) muestra que cada requisito de la especificación tiene
una estructura que lo sostiene y una consulta que lo demuestra.

---

## VI. Qué quedó fuera y qué quedó a medias

Ver `SCJ-ENT-03`. **Se dice aquí, no se esconde.**

---

## VII. Índice de anexos

| Anexo | Documento |
|---|---|
| A | `SCJ-ESP-01` — Especificación funcional |
| B | `SCJ-MOD-01` a `SCJ-MOD-03` — Modelos |
| C | `SCJ-DEC-01` a `SCJ-DEC-05` — Decisiones |
| D | `SCJ-DIC-01` — Diccionario de datos |
| E | `SCJ-TRZ-01` — Matriz de trazabilidad |
| F | `SCJ-VOL-01`, `SCJ-IDX-01` — Rendimiento |
| G | DDL completo — `db/ddl/` |

---

*Documento final · Folio SCJ-ENT-01 · V1.0*
