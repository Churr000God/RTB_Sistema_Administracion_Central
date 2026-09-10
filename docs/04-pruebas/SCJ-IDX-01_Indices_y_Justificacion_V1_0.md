# Índices y su justificación

**Sistema de Control de Jornada**
Folio SCJ-IDX-01 · Versión 1.0 · 25 de septiembre de 2026

Cada índice creado, la consulta que lo justifica, y la medición antes y después.

> **Un índice sin una consulta que lo justifique es peso muerto:** ocupa espacio, hace más lentas
> las escrituras y no acelera nada. Todo índice de este documento tiene una consulta con nombre.

---

## I. Catálogo

| Índice | Tabla | Columnas | Tipo | Consulta que lo justifica | Antes | Después |
|---|---|---|---|---|---:|---:|
| `ix_marca_persona_fecha` | `marca` | `persona_id`, `hora_terminal` | btree | `01_horas_por_periodo` | | |
| `uq_marca_terminal_secuencia` | `marca` | `terminal_id`, `secuencia` | btree único | Idempotencia del envío | | |
| | | | | | | |

*(tiempos en milisegundos, medidos sobre el escenario ×100)*

---

## II. Índice por índice

### `ix_marca_persona_fecha`

**Consulta que lo justifica**

```sql
-- db/consultas/reporte/01_resumen_persona_periodo.sql
```

**Plan sin el índice:** *(pegar el `EXPLAIN ANALYZE`)*
**Plan con el índice:** *(pegar el `EXPLAIN ANALYZE`)*
**Por qué el orden de las columnas es ése:** *(completar)*

---

*(una sección por índice)*

---

## III. Índices considerados y descartados

**Tan importante como los que se crearon.**

| Índice candidato | Por qué se descartó |
|---|---|
| | |

Motivos típicos: la tabla es demasiado pequeña para que importe · la selectividad de la columna es
baja · el índice de la clave primaria ya lo cubre · penaliza escrituras más de lo que acelera
lecturas.

---

## IV. Costo de escritura

Los índices se pagan en cada inserción. Con 32 marcas al día el costo es irrelevante, pero se mide
para poder afirmarlo:

| Escenario | Inserción de un lote de 8 marcas | |
|---|---:|---|
| Sin índices | | |
| Con todos los índices | | |

---

*Índices y su justificación · Folio SCJ-IDX-01 · V1.0*
