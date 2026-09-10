# Diccionario de datos

**Sistema de Control de Jornada · Esquema `tiempo`**
Folio SCJ-DIC-01 · Versión 1.0 · 25 de septiembre de 2026

Cada tabla, cada columna, su tipo, su dominio y su propósito. Se cierra con el congelamiento del
esquema.

> **Se genera parcialmente desde la base.** Ver `tools/generar_diccionario.sql`. Los comentarios de
> `COMMENT ON` del DDL son la fuente; este documento los presenta.

> **Nota (2026-09-02, no sube de versión — `tools/generar_diccionario.sql` sigue sin existir):**
> `02_tiempo.sql` ya tiene las 14 tablas con `COMMENT ON` completo (ver el archivo directamente
> para el detalle columna por columna mientras el generador no exista). Sólo se actualiza aquí el
> resumen del esquema, que faltaba reflejar las tablas nuevas.

> **Nota (2026-09-05, no sube de versión, mismo motivo):** `02_tiempo.sql` ahora tiene **15 tablas**
> — se agregó `tiempo.aprobacion_ausencia` (`SCJ-DEC-05`, aceptada). Sección `III. Enumerados` ya
> refleja `origen_marca` a 2 valores y el nuevo `estado_reloj`.

> **Nota (2026-09-05, más tarde el mismo día, mismo motivo):** `02_tiempo.sql` ahora tiene **16
> tablas** — se agregó `tiempo.corrida_batch` (`SCJ-PRO-12`).

---

## I. Resumen del esquema

| Tabla | Filas esperadas (6 meses, 8 personas) | Propósito |
|---|---|---|
| `persona` | 8 | Stub de la frontera |
| `marca` | ~5,800 | Eventos crudos del terminal |
| `dia` | ~1,450 | Marcas de una persona en una fecha, con estado |
| `tramo` | ~2,900 | Pares de marcas |
| `clasificacion_de_tiempo` | ~2,900 | Ordinario/reposición/extra por tramo |
| `jornada_asignada` | ~15 | Vigencias de jornada |
| `patron_semanal` | ~50 | Días/horario por jornada asignada |
| `tope_legal` | ~2 | Máximos semanales por vigencia |
| `dia_festivo` | ~15 | Catálogo de festivos (6 meses) |
| `banco_de_horas` | 8 | Un renglón acumulador por persona |
| `movimiento_de_saldo` | ~100 | Libro de movimientos del saldo |
| `correccion` | ~20 | Correcciones sobre marcas |
| `ausencia` | ~60 | |
| `parametro` | ~20 | |
| `excepcion` | ~40 | |

---

## II. Tablas

### `tiempo.persona`

> Stub. Identificador opaco. Ningún atributo de identidad. Ver `SCJ-FRO-01`.

| Columna | Tipo | Nulo | Predeterminado | Dominio | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | — | > 0 | Identificador opaco de la persona |

**Claves:** PK `id`
**Índices:** —
**Referenciada por:** `marca`, `jornada_asignada`, `ausencia`, `banco_de_horas`

---

### `tiempo.marca`

| Columna | Tipo | Nulo | Predeterminado | Dominio | Descripción |
|---|---|---|---|---|---|
| | | | | | |

**Claves:** · **Restricciones:** · **Índices:** · **Referenciada por:**

---

*(una sección por tabla)*

---

## III. Enumerados

| Enumerado | Valores | Usado en |
|---|---|---|
| `origen_marca` | `terminal`, `captura_manual` | `marca.origen` |
| `estado_reloj` | `sincronizado`, `deriva`, `sin_sincronizar` | `marca.estado_reloj` |
| `tipo_de_tiempo` | `ordinario`, `reposicion`, `extra` | |
| `tipo_de_ausencia` | `vacaciones`, `permiso_con_goce`, `permiso_sin_goce`, `incapacidad`, `falta` | |
| `salida_de_saldo` | `cubrir`, `arrastrar`, `descontar`, `condonar` | |
| `tipo_batch` | `cierre_dia`, `corte_quincenal`, `de_confianza` | `corrida_batch.tipo_batch` |
| `estado_batch` | `en_progreso`, `exitosa`, `fallida` | `corrida_batch.estado` |

---

## IV. Parámetros del sistema

Todos los valores son **de ejemplo**. Ver `SCJ-ESP-01 §VI.9`.

| Clave | Tipo | Valor de ejemplo | Qué controla |
|---|---|---|---|
| `tolerancia_retardo_min` | entero | 10 | Minutos antes de considerar retardo |
| `hora_corte_dia` | hora | 00:00 | A qué hora se considera cerrado un día |
| `ventana_banco_meses` | entero | 6 | Duración de la ventana de resolución |
| `umbral_aviso_pct` | entero | 100 | Porcentaje de la jornada semanal para avisar |
| `umbral_escalamiento_pct` | entero | 200 | Porcentaje para escalar |
| `descuento_pausa_no_registrada_min` | entero | 60 | Descuento fijo cuando la pausa no se marca |
| `dias_habiles_correccion_marca` | entero | 30 | Ventana para corregir una marca, contada en días hábiles (`SCJ-PRO-10`) |
| `hora_corrida_cierre_dia` | hora | 03:00 | Colchón tras `hora_corte_dia` antes de correr el batch de cierre, para dar tiempo a que sincronicen los terminales (`SCJ-PRO-12`) |

---

*Diccionario de datos · Folio SCJ-DIC-01 · V1.0*
