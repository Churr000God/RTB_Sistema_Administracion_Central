# Registro de decisiones de diseño

**Sistema de Control de Jornada**
Folio SCJ-DEC-00 · Versión 1.0 · Agosto de 2026

Índice del registro y plantilla del formato. Entregable E4 de `SCJ-ESP-01`.

> **No basta con decir qué se eligió.** Cada decisión lleva las opciones consideradas, los
> argumentos de los dos lados, la elección y sus consecuencias. Las decisiones que se revierten al
> construir son las más valiosas del registro: se anotan, no se esconden.

---

## I. Índice

| # | Pregunta | Estado | Última revisión |
|---|---|---|---|
| `SCJ-DEC-01` | ¿La paridad se valida con restricción, disparador o aplicación? | Aceptada | 2026-09-02 |
| `SCJ-DEC-02` | ¿El saldo del banco de horas se calcula al vuelo o se materializa? | Aceptada | 2026-09-02 |
| `SCJ-DEC-03` | ¿Versionado, auditoría o eventos para las correcciones? | Aceptada | 2026-09-02 |
| `SCJ-DEC-04` | ¿Cómo se representan las vigencias y se evita el traslape? | Aceptada | 2026-09-02 |
| `SCJ-DEC-05` | ¿Cómo se modela un flujo de autorización de pasos variables? | Aceptada | 2026-09-02 |
| `SCJ-DEC-06` | ¿El día es entidad materializada con estado propio, o estado derivado de sus marcas? | Aceptada | 2026-09-02 |
| `SCJ-DEC-07` | ¿`requiere_revision`/`motivo_revision` como atributos de la marca, o entidad de excepción? | Aceptada | 2026-09-02 |
| `SCJ-DEC-08` | ¿`evento_id` es clave primaria de la marca, o alterna junto a una subrogada? | Aceptada | 2026-09-02 |
| `SCJ-DEC-09` | ¿Cómo se aplica la unicidad de `terminal_id` + `secuencia_local`, condicional a `origen`? | Aceptada | 2026-09-02 |
| `SCJ-DEC-10` | ¿Cómo se calcula la alerta de retardo por jornada normal? | Aceptada | 2026-09-07 |

### Estados

| Estado | Significa |
|---|---|
| **Propuesta** | Escrita, aún no acordada |
| **Aceptada** | Acordada y en implementación |
| **Revisada tras implementar** | Se construyó y la decisión se confirmó |
| **Revertida** | Se construyó y se cambió. **La más interesante** |

---

## II. Plantilla

```markdown
# SCJ-DEC-0N · [Pregunta en una línea]

**Estado:** Propuesta
**Fecha de la decisión:** AAAA-MM-DD
**Última revisión:** —

## Contexto
Qué requisito de SCJ-ESP-01 obliga a decidir esto, y por qué no hay respuesta obvia.

## Opciones consideradas

### Opción A — [nombre]
**A favor:**
**En contra:**

### Opción B — [nombre]
**A favor:**
**En contra:**

## Decisión
Cuál se eligió.

## Por qué
El argumento que inclinó la balanza. Uno solo, si es posible.

## Consecuencias
Qué se vuelve fácil. Qué se vuelve difícil. Qué queda cerrado para siempre.

## Cómo se verifica
La consulta o prueba que demuestra que la decisión funciona.

## Revisión posterior a la implementación
*(se llena al construir, no antes)*
Qué se aprendió. Si se revirtió, por qué.
```

---

*Registro de decisiones · Folio SCJ-DEC-00 · V1.0*
