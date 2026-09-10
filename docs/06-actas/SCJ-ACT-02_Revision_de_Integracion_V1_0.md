# Acta — Revisión de integración entre subsistemas

**Sistema de Control de Jornada**
Folio SCJ-ACT-02 · Versión 1.0 · 11 de septiembre de 2026

Primera revisión conjunta con ambos subsistemas construidos. Corresponde a la tarea J2.1 del plan.

---

## I. Datos de la sesión

| | |
|---|---|
| Fecha | 11 de septiembre de 2026 |
| Participantes | |

---

## II. Qué se revisa

| # | Verificación | Resultado |
|---|---|---|
| 1 | Los dos esquemas conviven en la misma base sin conflicto | |
| 2 | **La frontera de `SCJ-FRO-01` sigue intacta** | |
| 3 | El stub `persona` se puebla correctamente | |
| 4 | El motor de cálculo corre sobre las tablas del subsistema de Tiempo | |
| 5 | El endpoint de recepción de marcas escribe conforme a `SCJ-CDT-01` | |
| 6 | Reenviar un lote tres veces no genera marcas duplicadas | |

---

## III. Verificación de la frontera

**La revisión más importante del acta.** Se ejecuta y se pega el resultado:

```sql
-- Ninguna columna del esquema tiempo debe contener atributos de identidad
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'tiempo'
  AND column_name ~* 'nombre|apellido|curp|rfc|nss|salario|sueldo|correo|telefono|domicilio';
-- Resultado esperado: 0 filas
```

**Resultado:** *(pegar)*

---

## IV. Problemas encontrados

| # | Problema | Lado afectado | Cómo se resuelve | Para cuándo |
|---|---|---|---|---|
| | | | | |

---

## V. Cambios de esquema acordados

**Última oportunidad de cambiar estructura antes del congelamiento del 25 de septiembre.**

| Cambio | Motivo | Quién lo hace |
|---|---|---|
| | | |

---

*Acta · Folio SCJ-ACT-02 · V1.0*
