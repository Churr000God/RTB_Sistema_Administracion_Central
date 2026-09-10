# Justificación de normalización

**Sistema de Control de Jornada**
Folio SCJ-NRM-01 · Versión 1.0 · 28 de agosto de 2026

Forma normal alcanzada por cada relación, y **dónde se decidió no normalizar y por qué**. Parte del
entregable E2 de `SCJ-ESP-01`.

---

## I. Nivel objetivo

El modelo apunta a **tercera forma normal (3FN)**, con las excepciones deliberadas del §III.

---

## II. Análisis por relación

Para cada una: dependencias funcionales, clave candidata, forma normal alcanzada.

### `marca`

**Dependencias funcionales**

```
(terminal_id, secuencia_local) → persona_id, momento_dispositivo, estado_reloj, origen
id                       → todo
```

**Clave candidata:** `(terminal_id, secuencia)` · **Clave primaria elegida:** `id` · **Forma
normal:** *(completar)*

*(repetir para cada relación)*

---

## III. Dónde no se normaliza, y por qué

**El apartado que importa.** Cada desnormalización necesita un motivo escrito, no una comodidad.

| Relación | Qué se desnormaliza | Motivo | Riesgo aceptado | Cómo se controla |
|---|---|---|---|---|
| | | | | |

### Candidatos previstos

| Candidato | Argumento a favor de desnormalizar | Argumento en contra |
|---|---|---|
| Saldo del banco de horas materializado | Evita recalcular seis meses de marcas en cada consulta | Puede quedar inconsistente con las marcas → `SCJ-DEC-02` |
| Jornada pactada copiada en el día calculado | Congela el histórico aunque la vigencia cambie | Duplica un dato que ya existe en `jornada_asignada` |
| Total de horas por día precalculado | Reportes inmediatos | Se invalida con cada corrección |

> **Con ocho personas y 32 eventos al día, el argumento de rendimiento es débil.** Si se
> desnormaliza, que sea por integridad histórica —congelar un valor que después cambia— y no por
> velocidad. Decirlo así en la defensa vale más que fingir un problema de rendimiento que no existe.

---

## IV. Anomalías que la normalización previene en este modelo

| Anomalía | Ejemplo concreto en este sistema |
|---|---|
| Actualización | |
| Inserción | |
| Borrado | |

---

*Justificación de normalización · Folio SCJ-NRM-01 · V1.0*
