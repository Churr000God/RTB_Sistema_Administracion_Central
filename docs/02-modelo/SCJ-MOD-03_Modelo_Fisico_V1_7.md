# Modelo físico — Subsistema de Tiempo

**Sistema de Control de Jornada · PostgreSQL 16**
Folio SCJ-MOD-03 · Versión 1.7 · 6 de octubre de 2026

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

> **Cambio de versión (V1.5 → V1.6, menor):** se corrige contra el esquema real que dejan los
> scripts `db/ddl/00` a `79`, con las 14 discrepancias que anotó `SCJ-DIC-01` V1.1 (5 de octubre
> de 2026). No cambia ninguna decisión: se actualiza lo que el DDL ya hacía distinto de lo escrito
> aquí. Ver los renglones marcados *(V1.6)*. El detalle columna por columna, las policies RLS, las
> funciones y el esquema `personas` viven en `SCJ-DIC-01`, no se repiten aquí.

> **Cambio de versión (V1.6 → V1.7, menor):** se agregan las 3 tablas de la terminal biométrica
> Hikvision (`tiempo.terminal`, `tiempo.terminal_usuario`, `tiempo.bitacora_movimiento_terminal_usuario`,
> scripts `80` y `81`, `SCJ-DEC-11`) con sus restricciones activas: la bitácora inmutable en 3 capas,
> el trigger que valida transiciones y deriva la tabla viva, la secuencia del `employeeNo` y las
> unicidades. Se precisa la fila del rol `terminal_checador` de §IV: el rol sigue existiendo, pero el
> puente Hikvision ya no lo usa (`SCJ-PRO-11` V2.0). No se contradice ninguna decisión anterior. De
> paso se corrige el nombre del archivo, que seguía en `V1_5` aunque el encabezado decía 1.6
> (`CONVENCIONES.md §I`).

Correspondencia entre el modelo lógico y el DDL: tipos elegidos, restricciones activas y su
justificación. Entregable E3 de `SCJ-ESP-01`.

> **Este documento no repite el DDL.** El DDL vive en `db/ddl/` y es la fuente de verdad. Aquí se
> explica **por qué** es como es.

> **Alcance (V1.7).** Este documento explica las decisiones del subsistema de **Tiempo**. El
> esquema `personas` (11 tablas), las policies RLS (74), las funciones/RPC y los triggers están
> descritos en `SCJ-DIC-01` y en los documentos de proceso `SCJ-PRO-01` a `SCJ-PRO-14`.

---

## I. Organización de los archivos

| Archivo | Contenido |
|---|---|
| `db/ddl/00_esquemas.sql` | Esquemas `personas` y `tiempo` |
| `db/ddl/01_persona_stub.sql` | El stub de la frontera |
| `db/ddl/02_tiempo.sql` | Tablas del subsistema de Tiempo |
| `db/ddl/03_parametros_ejemplo.sql` | Parámetros con **valores de ejemplo** |
| `db/ddl/04` a `36` | *(V1.6)* Esquema `personas`: personas, estructura organizacional, asignaciones, permisos y bitácoras |
| `db/ddl/37` a `79` | *(V1.6)* RLS, permisos y funciones de Tiempo, y las correcciones posteriores (los scripts son acumulativos: el estado final es la suma de los 82) |
| `db/ddl/80` y `81` | *(V1.7)* Terminal biométrica: `tiempo.terminal` y `tiempo.terminal_usuario` con la secuencia del `employeeNo` y los permisos `terminal_usuario_lectura`/`terminal_usuario_edicion` (`80`), y la bitácora inmutable con su trigger de transiciones (`81`). `SCJ-DEC-11` |
| `db/ddl/30_indices_fk.sql` | *(V1.6)* Índices de llaves foráneas |
| `db/indices/01_indices.sql` | Índices del subsistema de Tiempo. *(El documento `SCJ-IDX-01`, que iba a justificarlos, se quitó el 5-oct-2026: ya no hay un documento aparte para esto)* |

---

## II. Extensiones requeridas

| Extensión | Para qué |
|---|---|
| *(ninguna)* | *(V1.6)* Ningún script ejecuta `CREATE EXTENSION`. `btree_gist` estaba prevista para restricciones de exclusión sobre vigencias, pero no hay ninguna restricción `EXCLUDE`: las vigencias son dos columnas de fecha (ver §III) y se protegen con triggers |

---

## III. Decisiones de tipo

| Concepto | Tipo elegido | Alternativa descartada | Por qué |
|---|---|---|---|
| Instantes | `timestamptz` | `timestamp` | Sin zona no se puede razonar sobre el cambio de horario |
| Vigencias | Dos columnas de fecha (`vigente_desde`/`vigente_hasta`) | `daterange` + `EXCLUDE gist` | Simplicidad y portabilidad. Traslape: `SCJ-DEC-04` (Opción A) lo dejó en la aplicación; *(V1.6)* `jornada_asignada` hoy también lo protege en la base (§IV). `tope_legal` sigue sin esa protección |
| Duraciones | `numeric` en horas/minutos: `numeric(6,2)` como base; *(V1.6)* `dia.horas_totales` y `patron_semanal.horas_efectivas` son `numeric(5,2)`, y `banco_de_horas.monto` y `movimiento_de_saldo.monto` son `numeric(8,2)` | `interval` | Más simple de sumar y comparar contra `tope_legal`; se documenta como desviación de `CONVENCIONES.md §II`. La precisión varía según el máximo posible de cada columna |
| Enumerados | `varchar(N)` + `CHECK` | Tipo `ENUM` nativo | Agregar un valor no requiere `ALTER TYPE`; el `CHECK` es la restricción, no el tipo |
| Identificadores | `bigint GENERATED ALWAYS AS IDENTITY` en las tablas de Tiempo | `uuid` | Convención del repo: PK siempre `id`. `tiempo.persona.id` es la excepción dentro de Tiempo — `uuid`, porque cruza la frontera con `personas.persona` (`SCJ-FRO-01`). *(V1.6)* En el esquema `personas`, todas las tablas usan `uuid` (`gen_random_uuid()`), salvo `personas.permiso`, cuya PK es `codigo` |
| Dinero | *(no aplica en Tiempo — vive en `personas`/nómina)* | | |

---

## IV. Restricciones activas

Las que se implementan en la base y no en la aplicación, con la decisión que lo justifica.

| Restricción | Tabla | Tipo | Decisión |
|---|---|---|---|
| Idempotencia por llave de negocio | `marca` | `UNIQUE (evento_id)` | `SCJ-CDT-01 §VIII` |
| Huecos de secuencia por terminal | `marca` | `UNIQUE` parcial `WHERE origen = 'terminal'` | `SCJ-DEC-09` (aceptada) |
| Inmutabilidad de la marca | `marca` | *(V1.6)* `REVOKE UPDATE, DELETE` sobre `tiempo.marca` para `anon`, `authenticated` y `service_role` (`38_tiempo_permisos.sql`); solo quedan `INSERT` y `SELECT` | `SCJ-DEC-03` (aceptada) |
| Un día, una fecha, una persona | `dia` | `UNIQUE (persona_id, fecha)` | `SCJ-DEC-06` (aceptada) |
| Excepción exclusiva marca/día | `excepcion` | `CHECK ((marca_id IS NOT NULL) <> (dia_id IS NOT NULL))` | `SCJ-DEC-07` (aceptada) |
| Saldo materializado de sólo disparador | `banco_de_horas` | Sin restricción de base que impida `UPDATE` directo a nivel de privilegio (la tabla conserva `DISU`); *(V1.6)* tiene RLS y el saldo se escribe desde el libro `movimiento_de_saldo` por disparador. Riesgo anotado en `SCJ-DEC-02` | `SCJ-DEC-02` (aceptada) |
| Cadena de aprobación de ausencia | `aprobacion_ausencia` → `ausencia.estado_autorizacion` (materializado) | Disparador recalcula el estado desde los pasos; `SCJ-DEC-05` decidió no construir tabla de "definición de flujo", no que la resolución viva fuera de la base | `SCJ-DEC-05` (aceptada, Opción C) |
| Tope legal al asignar jornada `normal` | `patron_semanal` | `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`, `AFTER INSERT OR UPDATE` *(V1.6)* (se evalúa al final de la transacción, no fila por fila) — refuerza lo que la app ya valida, porque `anon`/`authenticated` pueden pegarle directo a PostgREST. *(V1.6)* Además `trg_patron_semanal_solo_jornada_futura` impide cambiar o borrar el patrón de una jornada que ya empezó | `SCJ-PRO-09` |
| Cadena de vigencias de `jornada_asignada` *(V1.6)* | `jornada_asignada` | `trg_jornada_asignada_valida_cadena` (`CONSTRAINT TRIGGER` diferido: una sola fila abierta por persona, sin huecos ni traslapes), más `trg_jornada_asignada_protege_vigencias` (`BEFORE UPDATE`) y `trg_jornada_asignada_protege_borrado` (`BEFORE DELETE`: solo se puede eliminar una jornada futura). `75_*.sql`, `76_*.sql` | `SCJ-DEC-04`, `SCJ-PRO-09` |
| Corrección exige excepción asociada | `correccion` | `fn_correccion_valida` (`BEFORE INSERT`) — sin excepción, el sistema no tiene forma de saber que la marca necesitaba revisión | `SCJ-PRO-10` |
| Corrección no puede reordenar marcas | `correccion` | `fn_correccion_valida` — bloquea si `valor_corregido` cruza la marca anterior o siguiente de la misma persona (por momento efectivo, considerando correcciones previas) | `SCJ-PRO-10` |
| Recálculo acotado de `tramo`/`dia` tras corregir | `tramo`, `dia` | `fn_correccion_recalcula_tramo` (`AFTER INSERT`) — sólo el tramo que usa la marca corregida, nunca el histórico completo | `SCJ-PRO-10` |
| Cálculo de `requiere_revision`/`motivo_revision` al insertar una marca | `marca`, `excepcion` | `fn_marca_valida_revision` (`AFTER INSERT`, `SECURITY DEFINER`). *(V1.6)* Genera excepción por `reloj_no_sincronizado`, `persona_inactiva`, `dia_cerrado` y `fuera_de_horario`. `72_*.sql` corrigió que `fuera_de_horario` se generaba aunque la jornada tuviera `genera_alerta_horario = false` (flexible o de confianza); ahora respeta esa columna | `SCJ-PRO-11` |
| Identidad y alcance mínimo del checador físico | `marca` | Rol `terminal_checador` (no `service_role`), RLS sólo `INSERT` con `origen='terminal'` forzado — primera RLS de todo el esquema `tiempo`. *(V1.7)* El rol y su policy siguen sin cambio, pero el puente de la terminal Hikvision no los usa: el Pi sólo habla con el backend, que inserta las marcas | `SCJ-PRO-11` (V2.0), `SCJ-DEC-11` |
| Materializar `dia` al resolver una ausencia | `ausencia`, `dia` | `fn_ausencia_resuelve_excepcion` extendido — `ON CONFLICT ... WHERE estado='abierto'`, nunca pisa un día ya resuelto por otra vía | `SCJ-PRO-12` (`SCJ-PRA-01 #13`) |
| Un `employeeNo` por persona y terminal, nunca reutilizado *(V1.7)* | `terminal_usuario` | `UNIQUE (terminal_id, employee_no)`; índice único parcial `uq_terminal_usuario_persona_vigente (terminal_id, persona_id) WHERE estado <> 'baja'` (un alta vigente por persona y terminal); el número sale de `tiempo.seq_terminal_employee_no` (`MINVALUE 1`, `MAXVALUE 99999999`, `NO CYCLE`; primera secuencia explícita del proyecto, sin privilegios para ningún rol de la API) | `SCJ-DEC-11` |
| Mapeo de enrolamiento sólo derivado de una bitácora *(V1.7)* | `terminal_usuario` ← `bitacora_movimiento_terminal_usuario` | La tabla viva no tiene `INSERT`/`UPDATE`/`DELETE` para ningún rol de la API; la escribe sólo `trg_bitacora_terminal_usuario_aplica` (`BEFORE INSERT`, `SECURITY DEFINER`, `search_path` fijo), que valida las 6 transiciones de estado y falla con `SCJ11`/`SCJ12` y un `HINT` estable. `BEFORE` y no `AFTER` porque en `asignado` crea la fila viva y completa `terminal_usuario_id`/`employee_no` antes de evaluar `NOT NULL` y la FK | `SCJ-DEC-11` |
| Inmutabilidad de la bitácora de terminal *(V1.7)* | `bitacora_movimiento_terminal_usuario` | 3 capas: (1) `REVOKE ALL` y `GRANT SELECT, INSERT` explícito (no se confía en que el `GRANT ALL` schema-wide de `38_*.sql` "no concedió" `UPDATE`/`DELETE`/`TRUNCATE`); (2) RLS sin policies de `UPDATE`/`DELETE`; (3) triggers `BEFORE UPDATE OR DELETE` por fila y `BEFORE TRUNCATE` por statement. Residual aceptado: el dueño de la base aún puede `DROP`/`DISABLE TRIGGER`. `CHECK`s de coherencia: `origen = 'web'` sí y sólo si el movimiento es `asignado`/`baja_solicitada`; autor obligatorio sí y sólo si `origen = 'web'`; conteo de huellas 1-10 sólo en `huella_capturada`; `detalle` obligatorio en `error` y de máx. 500 caracteres | `SCJ-DEC-11` |
| Autoría atada al propio usuario en el alta/baja web *(V1.7)* | `bitacora_movimiento_terminal_usuario` | Policy `INSERT` exige `terminal_usuario_edicion` (no heredable), `origen = 'web'`, `tipo_movimiento IN ('asignado','baja_solicitada')` y `registrado_por = auth.uid()` (anti-suplantación, mismo criterio que `62_*.sql` y `68_*.sql`). Los movimientos `origen = 'terminal'` los inserta sólo `service_role` | `SCJ-DEC-11` |/

Tres reglas quedaron **fuera de esta tabla a propósito** — se decidieron a nivel de aplicación, no
de base:

| Regla | Tabla | Validación en aplicación | Decisión |
|---|---|---|---|
| Paridad de marcas por día | `tramo` / `dia` | Al cerrar el día: cuenta de marcas par → procesa; impar → excepción pendiente | `SCJ-DEC-01` (aceptada, Opción C) |
| No traslape de vigencias | `tope_legal` *(V1.6: `jornada_asignada` ya se protege en la base, ver §IV)* | Antes de insertar/actualizar una vigencia, valida que no exista otra traslapada. En `tope_legal` la base solo tiene `UNIQUE (vigente_desde)` y la RPC `fn_tope_legal_crear_vigencia` | `SCJ-DEC-04` (aceptada, Opción A) |
| Ventana de 30 días hábiles para corregir una marca | `correccion` | Antes de enviar, compara `hoy` contra `marca.momento_dispositivo` en días hábiles, usando `tiempo.parametro.dias_habiles_correccion_marca` | `SCJ-PRO-10` |

---

## V. Dónde se decidió **no** poner la regla en la base

Tan importante como lo anterior. Cada renglón necesita un porqué.

| Regla | Dónde vive | Por qué no en la base |
|---|---|---|
| ~~Inmutabilidad estricta de `marca`~~ *(V1.6: resuelto, ya vive en la base)* | `REVOKE UPDATE, DELETE` (`38_tiempo_permisos.sql`) | Se decidió que valía la pena la capa extra. Queda aquí como constancia de que estuvo pendiente |
| Quién debe aprobar cada paso de una `ausencia` (resolución del aprobador contra el organigrama) | Aplicación | `SCJ-DEC-05` (Opción C) decidió explícito no duplicar el organigrama de Personas dentro de Tiempo — el *registro* de la cadena ya resuelta sí vive en la base (`aprobacion_ausencia`), pero *quién* debe aprobar se resuelve en cada caso consultando `puesto_permiso`/`asignacion` |
| Clasificación de `clasificacion_de_tiempo.tipo` (ordinario/reposición/extra) | *(V1.6)* Sigue sin disparador; la clasificación entra por la RPC `fn_corte_quincenal_aplicar_persona` (`57_*.sql`) | Depende de `tope_legal` vigente y del estado de `banco_de_horas` en el momento — lógica de negocio, no invariante estructural |
| Dar de baja en la terminal a una persona que pasó a `inactivo` en `personas` *(V1.7)* | Backend: emite `baja_solicitada` para su alta en `terminal_usuario` | Un trigger que cruce de `personas` a `tiempo` violaría la frontera (`SCJ-FRO-01`: sólo `persona_id` cruza). El ingestor de marcas además señala (no rechaza) las marcas de personas inactivas (`SCJ-PRO-11`, `SCJ-DEC-11`) |

---

## VI. Diferencias respecto del modelo lógico

Lo que cambió al implementar. **Cada cambio con su motivo**, y la decisión correspondiente
actualizada.

| Qué cambió | Por qué | Documento actualizado |
|---|---|---|
| `marca` usa `id bigint` como PK física, con `evento_id uuid` como llave de negocio aparte | `CONVENCIONES.md` exige PK siempre `id`; `SCJ-DEC-08` (Opción B) confirma esto como definitivo | `SCJ-MOD-02 §II.2` |
| `banco_de_horas.monto`/`.vivo_desde` sólo se escriben por disparador, nunca por `UPDATE` de aplicación | `SCJ-DEC-02` — el total es caché del libro de movimientos, no dato propio | `SCJ-DEC-02` |
| `tiempo.dia.estado` incluye un cuarto valor, `revisado`, que las opciones de `SCJ-DEC-06` no contemplaban | Un día bloqueado que RH ya revisó necesita distinguirse de uno que nadie ha visto | `SCJ-DEC-06` |
| *(V1.6)* `parametro` agrega `vigente_hasta` y `registrado_por` (`60_*.sql`); `dia` agrega columnas de revisión (`62_*.sql`, `63_*.sql`); `jornada_asignada` agrega `genera_alerta_horario` | Parámetros con vigencia y autor; revisión de RH sobre días bloqueados; no alertar horario en jornadas flexibles o de confianza | `SCJ-DIC-01` §II |
| *(V1.6)* `tiempo.persona.id` es `uuid`, no `bigint` | Cruza la frontera con `personas.persona` (`SCJ-FRO-01`). `SCJ-MOD-02` y la V1.0 del diccionario lo decían de otra forma | `SCJ-DIC-01` |
| *(V1.7)* `tiempo.marca.terminal_id` (serie, `varchar`) no es FK a `tiempo.terminal`; `terminal_usuario` y la bitácora sí referencian la terminal por su `id` surrogate | La columna de `marca` también guarda puntos de captura manual (ej. `rh-captura-01`), que no son terminales físicas | `SCJ-DEC-11`, `SCJ-DIC-01` §II |

---

*Modelo físico · Folio SCJ-MOD-03 · V1.7*
