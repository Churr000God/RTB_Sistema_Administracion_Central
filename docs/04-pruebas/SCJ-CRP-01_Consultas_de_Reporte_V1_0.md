# Consultas de reporte

**Sistema de Control de Jornada**
Folio SCJ-CRP-01 · Versión 1.0 · 22 de septiembre de 2026

Consultas que el sistema necesita para operar, distintas de las de validación: aquéllas prueban el
modelo, éstas lo usan.

---

## I. Los cuatro ejes

| Eje | Pregunta que responde |
|---|---|
| **Por persona** | ¿Cómo le fue a esta persona este mes? |
| **Por periodo** | ¿Cómo estuvo la semana pasada? |
| **Por área o grupo** | ¿Cómo está almacén contra administración? |
| **Por tipo de tiempo** | ¿Cuántas horas extra se generaron y en qué días? |

> **Los reportes por área usan el grupo propio del subsistema de Tiempo**, no el organigrama, que
> vive del otro lado de la frontera. Ver `SCJ-FRO-01 §IV`.

---

## II. Catálogo

| # | Archivo | Reporte | Salida |
|---|---|---|---|
| 1 | `01_resumen_persona_periodo.sql` | Resumen de una persona en un periodo | Una fila |
| 2 | `02_incidencia_periodo.sql` | **Paquete de incidencia**: horas, faltas, retardos, extra, vacaciones, saldo | Una fila por persona |
| 3 | `03_asistencia_diaria.sql` | Marcas por día, para detectar quién dejó de marcar | Una fila por persona-día |
| 4 | `04_excepciones_pendientes.sql` | Cola de excepciones sin resolver, por antigüedad | |
| 5 | `05_saldos_y_alertas.sql` | Saldos del banco con su umbral y su antigüedad en la ventana | |
| 6 | `06_traslape_de_ausencias.sql` | Ausencias que se traslapan dentro de un grupo | |

---

## III. El paquete de incidencia

Es el reporte que justifica el sistema entero: lo que se entrega a quien calcula la nómina.

| Columna | Origen |
|---|---|
| Horas ordinarias | Suma de tramos clasificados como ordinario |
| Faltas | Ausencias de tipo falta |
| Retardos | Entradas posteriores a la hora pactada más la tolerancia |
| Horas extra por tipo | Tramos clasificados como extra |
| Días de vacaciones tomados | Ausencias de tipo vacaciones autorizadas |
| Incapacidades | Ausencias de tipo incapacidad |
| Saldo del banco de horas | `SCJ-DEC-02` |

**Ninguna columna lleva monto.** El subsistema de Tiempo entrega horas; el dinero lo calcula quien
tiene el salario. Ver `SCJ-FRO-01`.

---

*Consultas de reporte · Folio SCJ-CRP-01 · V1.0*
