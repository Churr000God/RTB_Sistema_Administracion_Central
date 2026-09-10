# Generador de datos sintéticos

**Sistema de Control de Jornada**
Folio SCJ-GEN-01 · Versión 1.0 · 8 de septiembre de 2026

Diseño del generador: qué produce, cómo se ejecuta y **el catálogo de casos difíciles que debe
incluir a propósito**. Entregable E5 de `SCJ-ESP-01`.

> **Los datos sintéticos son el único conjunto de datos con el que se trabaja.** Nombres inventados,
> identificadores arbitrarios. Ver `SCJ-ANO-01`.

---

## I. Qué produce

**Ocho personas ficticias con seis meses de marcas verosímiles.** Aproximadamente 5,800 marcas.

| Salida | Archivo |
|---|---|
| Personas y jornadas | `db/seeds/datos_sinteticos.sql` |
| Marcas, tramos y correcciones | idem |
| Ausencias | idem |
| Resumen de lo generado | `db/seeds/resumen.md` |

---

## II. Ejecución

```bash
cd tools/generador
python generar.py --personas 8 --meses 6 --semilla 42 --salida ../../db/seeds/
```

| Opción | Descripción | Predeterminado |
|---|---|---|
| `--personas` | Número de personas | 8 |
| `--meses` | Meses de historia | 6 |
| `--semilla` | Semilla del generador aleatorio | 42 |
| `--desde` | Fecha de inicio | Hoy menos `--meses` |

**La semilla fija hace el conjunto reproducible.** La misma semilla produce siempre los mismos
datos, y por eso un renglón raro se puede investigar sin dudar de si es un artefacto del azar.

---

## III. Los casos difíciles

**No basta con datos bonitos.** El generador debe producir estos siete casos a propósito, en
cantidad suficiente para que las consultas de validación tengan qué encontrar.

| # | Caso | Frecuencia objetivo | Prueba qué |
|---|---|---|---|
| 1 | **Días con número impar de marcas** | ~2% de los días | `SCJ-ESP-01 §VI.2` · `SCJ-DEC-01` |
| 2 | **Jornadas personalizadas con horario partido** | 1 persona (`P07`) | `§III.3` |
| 3 | **Deuda acumulada y episodios de reposición** | 2 personas | `§III.5`, `§III.6` · `SCJ-DEC-02` |
| 4 | **Marcas que llegan fuera de orden** | ~5% de los lotes | `§IV` |
| 5 | **Marcas con reloj no sincronizado** | ~1% de las marcas | `§IV` |
| 6 | **Correcciones sobre marcas existentes** | ~30 en total | `§III.7` · `SCJ-DEC-03` |
| 7 | **Ausencias de cada tipo, incluyendo traslapes** | Al menos 2 traslapes | `§III.8` |

### Casos adicionales que conviene generar

| Caso | Por qué |
|---|---|
| Un cambio de jornada a mitad del periodo | Prueba el cálculo histórico de `SCJ-DEC-04` |
| Una persona con pausa nunca registrada (`P06`) | Prueba el descuento fijo configurable |
| Un lote enviado dos veces | Prueba la idempotencia de `SCJ-CDT-01 §VIII` |
| Un cruce de año | Prueba el cambio de tope legal de 48 h a 46 h |

---

## IV. Verosimilitud

Los datos deben parecerse a lo que produce una empresa real, o las pruebas no prueban nada:

- **Las horas de entrada se distribuyen alrededor de la hora pactada**, no la clavan
- Los lunes y los días después de puente tienen más retardos
- Las marcas de salida se agrupan cerca de la hora de salida
- Nadie marca de madrugada salvo por error
- Los sábados tienen jornada más corta

---

## V. Restricción

**Nombres inventados de una lista fija, identificadores arbitrarios. Ningún dato real, en ningún
momento.** El generador no lee de ninguna fuente externa.

---

## VI. Resumen de lo generado

Cada ejecución escribe `db/seeds/resumen.md` con los conteos reales, para poder afirmar en la
defensa cuántos casos de cada tipo hay.

| Concepto | Cantidad |
|---|---|
| Personas | |
| Marcas | |
| Días con marcas impares | |
| Correcciones | |
| Ausencias | |
| Traslapes de ausencia | |

---

*Generador de datos sintéticos · Folio SCJ-GEN-01 · V1.0*
