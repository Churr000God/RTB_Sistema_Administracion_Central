# Convenciones del repositorio

**Acordadas entre ambos integrantes. Un cambio aquí se discute, no se hace de forma unilateral.**

---

## I. Nombres de documentos

```
SCJ-XXX-NN_Nombre_Con_Guiones_Bajos_VM_m.md
```

| Parte | Regla |
|---|---|
| `XXX` | Tres letras del tipo de documento |
| `NN` | Consecutivo dentro del tipo, dos dígitos |
| `VM_m` | Versión mayor y menor. `V1_0` en la primera emisión |

**La versión del nombre del archivo y la del encabezado siempre coinciden.** Si discrepan, el
documento está mal y se corrige antes de seguir.

### Tipos

| Prefijo | Tipo | | Prefijo | Tipo |
|---|---|---|---|---|
| `CTX` | Contexto y alcance | | `GEN` | Generador de datos |
| `ESP` | Especificación funcional | | `CVA` | Consultas de validación |
| `CDT` | Contrato de datos | | `CRP` | Consultas de reporte |
| `FRO` | Contrato de frontera | | `VOL` | Pruebas de volumen |
| `ANO` | Reglas de anonimización | | `IDX` | Índices |
| `MOD` | Modelo de datos | | `TRZ` | Matriz de trazabilidad |
| `DEC` | Decisión de diseño | | `ACT` | Acta de sesión |
| `DIC` | Diccionario de datos | | `ENT` | Entrega final |
| `NRM` | Normalización | | `GLO` | Glosario |
| `PRA` | Preguntas abiertas | | | |

### Cuándo sube la versión

| Cambio | Versión |
|---|---|
| Corrección de redacción, sin cambio de contenido | No sube |
| Se agrega o precisa algo sin contradecir lo anterior | Menor: `V1_0` → `V1_1` |
| Se contradice o se elimina algo ya escrito | Mayor: `V1_1` → `V2_0` |

Todo cambio mayor lleva una nota al inicio del documento diciendo **qué cambió y por qué**.

---

## II. Nombres en la base de datos

| Elemento | Regla | Ejemplo |
|---|---|---|
| Esquemas | Minúsculas, singular | `tiempo`, `personas` |
| Tablas | Minúsculas, **singular**, con guion bajo | `marca`, `banco_de_horas` |
| Columnas | Minúsculas, con guion bajo | `hora_terminal`, `persona_id` |
| Clave primaria | `id` | `id` |
| Clave foránea | `<tabla>_id` | `marca_id`, `persona_id` |
| Restricción única | `uq_<tabla>_<columnas>` | `uq_marca_terminal_secuencia` |
| Restricción de verificación | `ck_<tabla>_<qué>` | `ck_tramo_fin_posterior_a_inicio` |
| Clave foránea | `fk_<tabla>_<tabla_destino>` | `fk_tramo_jornada` |
| Índice | `ix_<tabla>_<columnas>` | `ix_marca_persona_fecha` |
| Vigencias | `vigente_desde`, `vigente_hasta` | |
| Auditoría | `creado_en`, `creado_por` | |

**Todo en español.** Nombres de tablas, columnas, restricciones y comentarios. El código de las
herramientas también.

### Tipos

| Dato | Tipo |
|---|---|
| Instantes | `timestamptz` — **siempre con zona horaria** |
| Fechas de calendario | `date` |
| Duraciones | `interval`, o entero de minutos si la decisión lo justifica |
| Rangos de vigencia | `vigente_desde date NOT NULL` + `vigente_hasta date` (`NULL` = vigente), traslape validado en la aplicación — no `EXCLUDE GIST` (`SCJ-DEC-04`, Opción A) |
| Identificadores | `bigint` generado por identidad, salvo justificación |
| Dinero | `numeric(12,2)` — **nunca** `float` |

---

## III. Archivos SQL

Numerados por orden de ejecución: `00_esquemas.sql`, `01_persona_stub.sql`, `02_tiempo.sql`.

Cada archivo abre con un comentario de cabecera: qué crea, de qué depende, y qué documento lo
justifica.

```sql
-- 02_tiempo.sql
-- Crea las tablas del subsistema de Tiempo.
-- Depende de: 00_esquemas.sql, 01_persona_stub.sql
-- Justificación: SCJ-MOD-03 §III · Decisiones SCJ-DEC-01, SCJ-DEC-04
```

---

## IV. Commits

```
<tipo>: <qué cambió>
```

Tipos: `docs`, `ddl`, `consulta`, `generador`, `diagrama`, `fix`, `acta`.

```
ddl: agrega restricción de exclusión en jornada_asignada
docs: SCJ-DEC-02 pasa a Aceptada, se elige saldo materializado
```

Mensajes en español, en presente, sin punto final.

---

## V. Diagramas

**El diagrama se escribe como texto** —Mermaid o PlantUML— en `diagramas/fuente/`. La imagen
exportada va en `diagramas/export/` con el mismo nombre.

Razón: un archivo de texto se versiona y se puede comparar entre versiones. Un binario de
herramienta gráfica no. El diagrama conceptual de agosto tiene que poder compararse con el de
septiembre.

---

## VI. Qué nunca se sube

Ver `SCJ-ANO-01`. En resumen: ningún dato real, ninguna credencial, ningún nombre de empresa o
persona verdadera, ningún documento con folio ajeno a `SCJ-`.
