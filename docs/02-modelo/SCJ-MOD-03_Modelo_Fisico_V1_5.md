# Modelo físico — Subsistema de Tiempo

**Sistema de Control de Jornada · PostgreSQL 16**
Folio SCJ-MOD-03 · Versión 1.5 · 5 de septiembre de 2026

> **Cambio de versión (V1.0 → V1.1, menor):** `02_tiempo.sql` pasa de "pendiente" a implementado.
> Se llenan las secciones III-VI con lo que el DDL real decidió. No se contradice nada de lo ya
> escrito — se precisa.

> **Cambio de versión (V1.1 → V1.2, menor):** se agregan 2 restricciones activas —
> `aprobacion_ausencia` (`SCJ-DEC-05`, ya aceptada desde el 2 de septiembre pero nunca reflejada
> aquí) y el `CONSTRAINT TRIGGER` de tope legal al asignar jornada (`SCJ-PRO-09`). Se precisa la
> fila de §V sobre el flujo de autorización de ausencia, que seguía redactada como si `SCJ-DEC-05`
> siguiera sin resolver.

> **Cambio de versión (V1.2 → V1.3, menor):** se agregan las 2 restricciones de `correccion`
> (exige excepción asociada, no reordena marcas) y el recálculo acotado de `tramo`/`dia`, más la
> ventana de 30 días hábiles que se quedó en aplicación — todas de `SCJ-PRO-10`.

> **Cambio de versión (V1.3 → V1.4, menor):** se agrega el cálculo centralizado de
> `requiere_revision`/`motivo_revision` (`fn_marca_valida_revision`) y la primera RLS de todo el
> esquema `tiempo` (rol `terminal_checador`, sólo `INSERT` en `marca`) — ambas de `SCJ-PRO-11`.

> **Cambio de versión (V1.4 → V1.5, menor):** se agrega `corrida_batch` (estado visible de los
> batches de orquestación) y se extiende `fn_ausencia_resuelve_excepcion` para materializar
> `tiempo.dia` al resolver una ausencia — cerraba la excepción pero dejaba el día `abierto` para
> siempre. Ambas de `SCJ-PRO-12` (`SCJ-PRA-01 #13`).

Correspondencia entre el modelo lógico y el DDL: tipos elegidos, restricciones activas y su
justificación. Entregable E3 de `SCJ-ESP-01`.

> **Este documento no repite el DDL.** El DDL vive en `db/ddl/` y es la fuente de verdad. Aquí se
> explica **por qué** es como es.

---

## I. Organización de los archivos

| Archivo | Contenido |
|---|---|
| `db/ddl/00_esquemas.sql` | Esquemas `personas` y `tiempo`, extensiones |
| `db/ddl/01_persona_stub.sql` | El stub de la frontera |
| `db/ddl/02_tiempo.sql` | Tablas del subsistema de Tiempo |
| `db/ddl/03_parametros_ejemplo.sql` | Parámetros con **valores de ejemplo** |
| `db/indices/01_indices.sql` | Índices, con su justificación en `SCJ-IDX-01` |

---

## II. Extensiones requeridas

| Extensión | Para qué |
|---|---|
| `btree_gist` | Restricciones de exclusión sobre vigencias que combinan `persona_id` con un rango |

---

## III. Decisiones de tipo

| Concepto | Tipo elegido | Alternativa descartada | Por qué |
|---|---|---|---|
| Instantes | `timestamptz` | `timestamp` | Sin zona no se puede razonar sobre el cambio de horario |
| Vigencias | Dos columnas de fecha (`vigente_desde`/`vigente_hasta`) | `daterange` + `EXCLUDE gist` | Simplicidad y portabilidad; traslape validado en la aplicación (`SCJ-DEC-04`, Opción A) |
| Duraciones | `numeric(6,2)` en horas/minutos | `interval` | Más simple de sumar y comparar contra `tope_legal`; se documenta como desviación de `CONVENCIONES.md §II` |
| Enumerados | `varchar(N)` + `CHECK` | Tipo `ENUM` nativo | Agregar un valor no requiere `ALTER TYPE`; el `CHECK` es la restricción, no el tipo |
| Identificadores | `bigint GENERATED ALWAYS AS IDENTITY` | `uuid` | Convención del repo: PK siempre `id`. `tiempo.persona.id` es la única excepción — `uuid`, porque cruza la frontera con `personas.persona` (`SCJ-FRO-01`) |
| Dinero | *(no aplica en Tiempo — vive en `personas`/nómina)* | | |

---

## IV. Restricciones activas

Las que se implementan en la base y no en la aplicación, con la decisión que lo justifica.

| Restricción | Tabla | Tipo | Decisión |
|---|---|---|---|
| Idempotencia por llave de negocio | `marca` | `UNIQUE (evento_id)` | `SCJ-CDT-01 §VIII` |
| Huecos de secuencia por terminal | `marca` | `UNIQUE` parcial `WHERE origen = 'terminal'` | `SCJ-DEC-09` (aceptada) |
| Inmutabilidad de la marca | `marca` | Sin `UPDATE`/`DELETE` en ningún flujo de aplicación (no hay restricción de base que lo impida a nivel de permisos todavía) | `SCJ-DEC-03` (aceptada) |
| Un día, una fecha, una persona | `dia` | `UNIQUE (persona_id, fecha)` | `SCJ-DEC-06` (aceptada) |
| Excepción exclusiva marca/día | `excepcion` | `CHECK ((marca_id IS NOT NULL) <> (dia_id IS NOT NULL))` | `SCJ-DEC-07` (aceptada) |
| Saldo materializado de sólo disparador | `banco_de_horas` | Sin restricción de base que impida `UPDATE` directo — depende de disciplina de aplicación, riesgo anotado en `SCJ-DEC-02` | `SCJ-DEC-02` (aceptada) |
| Cadena de aprobación de ausencia | `aprobacion_ausencia` → `ausencia.estado_autorizacion` (materializado) | Disparador recalcula el estado desde los pasos; `SCJ-DEC-05` decidió no construir tabla de "definición de flujo", no que la resolución viva fuera de la base | `SCJ-DEC-05` (aceptada, Opción C) |
| Tope legal al asignar jornada `normal` | `patron_semanal` | `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED` (se evalúa al final de la transacción, no fila por fila) — refuerza lo que la app ya valida, porque `anon`/`authenticated` pueden pegarle directo a PostgREST | `SCJ-PRO-09` |
| Corrección exige excepción asociada | `correccion` | `fn_correccion_valida` (`BEFORE INSERT`) — sin excepción, el sistema no tiene forma de saber que la marca necesitaba revisión | `SCJ-PRO-10` |
| Corrección no puede reordenar marcas | `correccion` | `fn_correccion_valida` — bloquea si `valor_corregido` cruza la marca anterior o siguiente de la misma persona (por momento efectivo, considerando correcciones previas) | `SCJ-PRO-10` |
| Recálculo acotado de `tramo`/`dia` tras corregir | `tramo`, `dia` | `fn_correccion_recalcula_tramo` (`AFTER INSERT`) — sólo el tramo que usa la marca corregida, nunca el histórico completo | `SCJ-PRO-10` |
| Cálculo de `requiere_revision`/`motivo_revision` al insertar una marca | `marca`, `excepcion` | `fn_marca_valida_revision` (`AFTER INSERT`, `SECURITY DEFINER`) — 4 de los 5 motivos, sin importar el origen | `SCJ-PRO-11` |
| Identidad y alcance mínimo del checador físico | `marca` | Rol `terminal_checador` (no `service_role`), RLS sólo `INSERT` con `origen='terminal'` forzado — primera RLS de todo el esquema `tiempo` | `SCJ-PRO-11` |
| Materializar `dia` al resolver una ausencia | `ausencia`, `dia` | `fn_ausencia_resuelve_excepcion` extendido — `ON CONFLICT ... WHERE estado='abierto'`, nunca pisa un día ya resuelto por otra vía | `SCJ-PRO-12` (`SCJ-PRA-01 #13`) |

Tres reglas quedaron **fuera de esta tabla a propósito** — se decidieron a nivel de aplicación, no
de base:

| Regla | Tabla | Validación en aplicación | Decisión |
|---|---|---|---|
| Paridad de marcas por día | `tramo` / `dia` | Al cerrar el día: cuenta de marcas par → procesa; impar → excepción pendiente | `SCJ-DEC-01` (aceptada, Opción C) |
| No traslape de vigencias | `jornada_asignada`, `tope_legal` | Antes de insertar/actualizar una vigencia, valida que no exista otra traslapada | `SCJ-DEC-04` (aceptada, Opción A) |
| Ventana de 30 días hábiles para corregir una marca | `correccion` | Antes de enviar, compara `hoy` contra `marca.momento_dispositivo` en días hábiles, usando `tiempo.parametro.dias_habiles_correccion_marca` | `SCJ-PRO-10` |

---

## V. Dónde se decidió **no** poner la regla en la base

Tan importante como lo anterior. Cada renglón necesita un porqué.

| Regla | Dónde vive | Por qué no en la base |
|---|---|---|
| Inmutabilidad estricta de `marca` (bloqueo de `UPDATE`/`DELETE` a nivel de permisos) | Convención de aplicación | Postgres no tiene una forma declarativa simple de prohibir `UPDATE`/`DELETE` salvo revocar privilegios por rol — pendiente de decidir si vale la pena esa capa extra |
| Quién debe aprobar cada paso de una `ausencia` (resolución del aprobador contra el organigrama) | Aplicación | `SCJ-DEC-05` (Opción C) decidió explícito no duplicar el organigrama de Personas dentro de Tiempo — el *registro* de la cadena ya resuelta sí vive en la base (`aprobacion_ausencia`), pero *quién* debe aprobar se resuelve en cada caso consultando `puesto_permiso`/`asignacion` |
| Clasificación de `clasificacion_de_tiempo.tipo` (ordinario/reposición/extra) | Disparador pendiente de programar | Depende de `tope_legal` vigente y del estado de `banco_de_horas` en el momento — lógica de negocio, no invariante estructural |

---

## VI. Diferencias respecto del modelo lógico

Lo que cambió al implementar. **Cada cambio con su motivo**, y la decisión correspondiente
actualizada.

| Qué cambió | Por qué | Documento actualizado |
|---|---|---|
| `marca` usa `id bigint` como PK física, con `evento_id uuid` como llave de negocio aparte | `CONVENCIONES.md` exige PK siempre `id`; `SCJ-DEC-08` (Opción B) confirma esto como definitivo | `SCJ-MOD-02 §II.2` |
| `banco_de_horas.monto`/`.vivo_desde` sólo se escriben por disparador, nunca por `UPDATE` de aplicación | `SCJ-DEC-02` — el total es caché del libro de movimientos, no dato propio | `SCJ-DEC-02` |
| `tiempo.dia.estado` incluye un cuarto valor, `revisado`, que las opciones de `SCJ-DEC-06` no contemplaban | Un día bloqueado que RH ya revisó necesita distinguirse de uno que nadie ha visto | `SCJ-DEC-06` |

---

*Modelo físico · Folio SCJ-MOD-03 · V1.1*
