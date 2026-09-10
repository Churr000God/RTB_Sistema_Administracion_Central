# Pruebas de volumen

**Sistema de Control de Jornada**
Folio SCJ-VOL-01 · Versión 1.0 · 22 de septiembre de 2026

Método, volúmenes probados, tiempos medidos y dónde estaría el límite del modelo.

---

## I. Una nota honesta sobre el volumen

**Con ocho personas el volumen es trivial:** unos 32 eventos al día, unas 5,800 marcas en seis
meses. Cualquier modelo razonable responde en milisegundos.

**Las pruebas de volumen no son para este caso.** Son para saber dónde estaría el límite si la
plantilla creciera diez o cien veces, y para poder afirmar con datos —no con intuición— cuáles
consultas escalan y cuáles no.

> Vale la pena hacerlas bien, pero sin fingir que el rendimiento es un problema real en el caso de
> estudio. **Decirlo así es más sólido que inventar un problema que no existe.**

---

## II. Método

### Volúmenes probados

| Escenario | Personas | Meses | Marcas aproximadas |
|---|---:|---:|---:|
| Caso real | 8 | 6 | 5,800 |
| ×10 | 80 | 6 | 58,000 |
| ×100 | 800 | 12 | 1,160,000 |
| ×1000 | 8,000 | 24 | 23,200,000 |

Todos generados con `tools/generador/generar.py`, con la misma proporción de casos difíciles.

### Cómo se mide

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <consulta>;
```

- Cada consulta se ejecuta **cinco veces**; se reporta la mediana
- Se ejecuta `ANALYZE` sobre las tablas antes de medir
- Se reporta el plan, no sólo el tiempo: **un plan con recorrido secuencial que hoy tarda 3 ms es el
  que va a tardar 3 segundos con cien veces más datos**

---

## III. Resultados

| Consulta | Caso real | ×10 | ×100 | ×1000 | Crecimiento |
|---|---:|---:|---:|---:|---|
| `01_horas_por_periodo` | | | | | |
| `02_saldo_a_fecha` | | | | | |
| `03_marcas_incompletas` | | | | | |
| `04_tiempo_por_tipo` | | | | | |
| `05_reconstruccion_historica` | | | | | |
| `02_incidencia_periodo` | | | | | |

*(tiempos en milisegundos, mediana de cinco ejecuciones)*

---

## IV. Lectura de los resultados

### Qué escala bien

*(completar)*

### Qué no escala

*(completar)*

### Dónde estaría el límite

*(completar)* — a partir de qué volumen alguna consulta deja de ser aceptable, y qué habría que
cambiar: índice, materialización, o partición por fecha.

---

## V. Efecto de las decisiones de diseño en el rendimiento

La comparación más interesante del documento:

| Decisión | Efecto medido |
|---|---|
| `SCJ-DEC-02` — saldo al vuelo vs. materializado | |
| `SCJ-DEC-03` — reconstrucción histórica | |
| `SCJ-DEC-04` — rangos con exclusión GiST | |

> **Si una decisión se tomó por integridad y resulta cara en rendimiento, decirlo.** Es más honesto
> que ajustar la narrativa para que todo haya salido bien.

---

*Pruebas de volumen · Folio SCJ-VOL-01 · V1.0*
