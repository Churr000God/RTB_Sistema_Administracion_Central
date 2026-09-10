# Consultas de validación

**Sistema de Control de Jornada**
Folio SCJ-CVA-01 · Versión 1.0 · 11 de septiembre de 2026

Consultas que demuestran que el modelo responde correctamente a lo que `SCJ-ESP-01` exige.
Entregable E6.

> **Cada consulta responde a una fila de `SCJ-TRZ-01`.** Una consulta que no prueba ningún requisito
> sobra; un requisito sin consulta es una afirmación sin respaldo.

---

## I. Las cinco consultas

| # | Archivo | Qué demuestra | Requisito |
|---|---|---|---|
| 1 | `01_horas_por_periodo.sql` | Horas trabajadas por persona en un periodo | `§III.1` |
| 2 | `02_saldo_a_fecha.sql` | Saldo del banco de horas **a una fecha dada del pasado** | `§III.6` |
| 3 | `03_marcas_incompletas.sql` | Días con marcas impares y su conteo por persona | `§III.2` |
| 4 | `04_tiempo_por_tipo.sql` | Tiempo desglosado en ordinario, reposición y extra | `§III.5` |
| 5 | `05_reconstruccion_historica.sql` | **Estado de un registro corregido en un momento del pasado** | `§III.7` |

---

## II. Consulta por consulta

### 1 · Horas trabajadas en un periodo

**Qué prueba:** que las marcas se emparejan correctamente en tramos y que los tramos suman la
jornada, incluyendo días con dos y tres pausas.

**Resultado esperado:** *(completar tras ejecutar)*

---

### 2 · Saldo del banco de horas a una fecha pasada

**Qué prueba:** `SCJ-DEC-02`. Es la consulta que decide si la decisión de materializar o calcular al
vuelo fue la correcta.

**Prueba de estabilidad:** se ejecuta hoy y se vuelve a ejecutar después de haber cargado tres meses
más de datos. **El resultado para la misma fecha debe ser idéntico.**

---

### 3 · Días con marcas incompletas

**Qué prueba:** la detección de paridad y el requisito de conteo por persona y periodo, que es lo
que permite detectar patrones.

---

### 4 · Tiempo desglosado por tipo

**Qué prueba:** la regla de asignación automática — si hay deuda el excedente es reposición, si no,
es extra — y que una porción de tiempo puede cambiar de clasificación sin perder su historia.

---

### 5 · Reconstrucción del estado histórico

**La más exigente.** Demuestra que el modelo de correcciones funciona y es el requisito que la
legislación exigirá a partir de enero de 2027.

**Qué debe devolver:** el estado de una marca corregida tal como era en una fecha dada, más la
cadena completa de correcciones que se le aplicaron, con motivo, autor y momento de cada una.

---

## III. Cómo se ejecutan todas

```bash
for f in db/consultas/validacion/*.sql; do
  echo "== $f"
  psql -d scj -f "$f"
done
```

---

*Consultas de validación · Folio SCJ-CVA-01 · V1.0*
