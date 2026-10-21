# Modelo físico — Subsistema de Tiempo

**Sistema de Control de Jornada · PostgreSQL 16**
Folio SCJ-MOD-03 · Versión 1.10 · 21 de octubre de 2026

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

> **Cambio de versión (V1.8 → V1.9, menor):** se agregan las restricciones de los scripts `88` a `92`
> (configuración de terminales, consentimiento biométrico versionado y tablero de anomalías; no se contradice nada de lo
> anterior): la tabla de versiones `tiempo.terminal_consentimiento` (de sólo inserción, inmutable en 3
> capas, con la versión 1 provisional sembrada), la columna `consentimiento_id` en la bitácora de
> enrolamiento y en la tabla viva (`asignado` y el movimiento nuevo `reconsentido` exigen la versión
> vigente, `SCJ16`), el permiso `terminal_config_edicion` (no heredable, sólo TI y Gerente General), las 5
> claves `terminal_*` de `tiempo.parametro` con su regla cruzada y el guard `SCJ17` de la pantalla genérica
> de Parámetros. El detalle de columnas y funciones está en `SCJ-DIC-01` V1.4. Estas restricciones
> se ensayaron con `BEGIN … ROLLBACK` (`db/ensayos/ensayo_88.sql`, `ensayo_89.sql`) y se contrastaron con la
> base real el 2026-10-08, ya aplicadas, sin diferencias.

> **Cambio de versión (V1.7 → V1.8, menor):** se agregan las restricciones activas de los scripts `82` a `85`
> (`SCJ-DEC-12`, autenticación de la terminal, ruta de marcas y caducidad de altas): la credencial de la
> terminal (`tiempo.terminal_credencial`), los triggers `SCJ13` (desactivación) y `SCJ14` (revocación
> irreversible), `tiempo.marca_rechazada` como excepción deliberada a la inmutabilidad, y las 11 funciones
> nuevas `SECURITY DEFINER` con su ACL; y se aclaran dos filas de V1.7 (el trigger de la bitácora ahora toma la
> terminal `FOR SHARE` en `asignado`). Lo escrito se contrastó con la base real de Supabase en solo lectura
> (privilegios, `EXECUTE`, `search_path`, triggers, índices, restricciones). No se contradice nada de lo anterior.
> Hallazgo del contraste, cerrado: el script `78_` no estaba aplicado en esa base el 6-oct-2026; el usuario lo
> aplicó el 7-oct sin ensayo previo, pero cubría únicamente el `UPDATE` suelto de una excepción `dia_cerrado` y
> `security` identificó dos evasiones. El script `86_tiempo_excepcion_protege_dia_cerrado_v2.sql` (ensayado, revisado
> y aplicado el 7-oct-2026) las cierra: protege las columnas de `excepcion`, exige revisar el día en la misma
> transacción o un descarte auditado (`tiempo.excepcion_descarte`, permiso `excepcion_dia_cerrado_descarte`), y valida
> la coherencia de `tramo` (`SCJ15`). Residual aceptado: `dia_update_revision` deja a quien tenga
> `dia_revision_edicion` pasar un día a `revisado` sin armar tramos (auditado; revisar al endurecer `tiempo.dia`).
> Ver `SCJ-DIC-01` V1.3, nota de método.

> **Cambio de versión (V1.9 → V1.10, menor, 21-oct-2026):** el documento deja de detenerse en el script `92` y recoge lo que dejaron `93` a `125` (**126 scripts**, `00` a `125`; sin contradecir ninguna decisión de diseño, aunque aclara dos filas: el recálculo del tramo tras corregir ya no se alcanza desde `87_`, y la policy del rol `terminal_checador` se retiró en `93_`). Se agregan: el retiro de `terminal_checador` (`93`); la activación por huella «sin conteo» y su interruptor en el servidor (`94`-`99`); el endurecimiento de privilegios y de `EXECUTE` (`100`-`106`), con el saldo del banco movido solo por un disparador `SECURITY DEFINER` (`104`); la lectura del padrón por permiso, la identidad separada del nombre y el alta atómica de persona (`107`-`112`); las reglas de asignaciones y el límite de plazas (`113`-`115`); la edición parcial de expediente (`116`); la corrección de la policy de INSERT de `tiempo.correccion` (`117`); y los cortes de octubre sobre el cálculo de tiempo: jornada neta de la ausencia (`118`), idempotencia del corte (`119`), compensación auditada del ledger (`120`), tipo de ausencia inmutable (`121`), nadie resuelve la propia ausencia (`122`), coherencia de los tiempos del tramo (`123`), cierre de día atómico (`124`) y descarte auditado de alertas de horario (`125`). El detalle columna por columna, las policies y las funciones viven en `SCJ-DIC-01` **V1.6** (regenerado contra la base real el 21-oct-2026); los procesos, en `SCJ-PRO-01` a `SCJ-PRO-15`.

Correspondencia entre el modelo lógico y el DDL: tipos elegidos, restricciones activas y su
justificación. Entregable E3 de `SCJ-ESP-01`.

> **Este documento no repite el DDL.** El DDL vive en `db/ddl/` y es la fuente de verdad. Aquí se
> explica **por qué** es como es.

> **Alcance (V1.10).** Este documento explica las decisiones del subsistema de **Tiempo**. El
> esquema `personas` (11 tablas), las policies RLS (76 a 21-oct-2026), las funciones/RPC y los triggers están
> descritos en `SCJ-DIC-01` V1.6 y en los documentos de proceso `SCJ-PRO-01` a `SCJ-PRO-15`.

---

## I. Organización de los archivos

| Archivo | Contenido |
|---|---|
| `db/ddl/00_esquemas.sql` | Esquemas `personas` y `tiempo` |
| `db/ddl/01_persona_stub.sql` | El stub de la frontera |
| `db/ddl/02_tiempo.sql` | Tablas del subsistema de Tiempo |
| `db/ddl/03_parametros_ejemplo.sql` | Parámetros con **valores de ejemplo** |
| `db/ddl/04` a `36` | *(V1.6)* Esquema `personas`: personas, estructura organizacional, asignaciones, permisos y bitácoras |
| `db/ddl/37` a `79` | *(V1.6)* RLS, permisos y funciones de Tiempo, y las correcciones posteriores (los scripts son acumulativos: el estado final es la suma de los 126, `00` a `125`) |
| `db/ddl/80` y `81` | *(V1.7)* Terminal biométrica: `tiempo.terminal` y `tiempo.terminal_usuario` con la secuencia del `employeeNo` y los permisos `terminal_usuario_lectura`/`terminal_usuario_edicion` (`80`), y la bitácora inmutable con su trigger de transiciones (`81`). `SCJ-DEC-11` |
| `db/ddl/93` a `99` | *(V1.10)* `93`: retiro de `terminal_checador` (sin policy, sin `INSERT`, sin `USAGE`, sin membresía en `authenticator`; el rol queda vacío y `NOLOGIN`). `94`-`99`: activación por huella «sin conteo» y su interruptor en el servidor (`terminal_inferir_huella_*` en `tiempo.parametro`, `tiempo.bitacora_config_terminal` inmutable, trigger de auditoría estrecho y bloqueo de `TRUNCATE`), `terminal.ingesta_detenida` y `fn_terminal_latido` de 7 argumentos |
| `db/ddl/100` a `106` | *(V1.10)* Endurecimiento: `REVOKE` a `anon` sobre todo `tiempo` y `personas`, sin `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN` para la API, `UPDATE`/`DELETE` inmutables en bitácoras y ledger (`100`-`103`); `fn_movimiento_de_saldo_actualiza_banco` pasa a `SECURITY DEFINER` y la escritura manual del ledger queda solo por `fn_movimiento_de_saldo_manual_registrar` (`104`); 13 funciones de trigger sin `EXECUTE` y `search_path` fijo en los ayudantes de RLS (`105`, `106`) |
| `db/ddl/107` a `116` | *(V1.10)* `personas`: alta atómica (`fn_persona_crear`), padrón y bitácoras legibles solo por permiso, identidad separada del nombre (`fn_persona_identidad`, `GRANT` de columnas), `fn_caller_tiene_permiso` a `SECURITY DEFINER` (`107`-`112`); reglas de asignaciones (`SCJ19`-`SCJ21`, `113`-`115`); edición parcial de expediente (`SCJ22`, `116`) |
| `db/ddl/117` a `125` | *(V1.10)* `117`: policy de INSERT de `correccion`. `118`: jornada neta de la ausencia. `119`: `corte_quincenal_aplicado` y la nueva firma del corte (`SCJ23`). `120`: compensación del ledger (`SCJ24`). `121`: tipo de ausencia inmutable (`SCJ25`). `122`: nadie resuelve la propia ausencia (`SCJ26`). `123`: tiempos del tramo coherentes con sus marcas. `124`: `fn_cierre_dia_armar` (`SCJ27`). `125`: descarte auditado de alertas de horario (`SCJ28`) |
| `db/ddl/92` | *(V1.9)* Endurecimiento del INSERT humano en `personas.bitacora_movimiento_persona` (policy: autor atado a `auth.uid()` y sólo los tipos suspension/reactivacion/baja_definitiva; trigger que fija `creado_en = now()` y acota `fecha_efectiva` para llamadores de la API) y limpieza de invisibles en el detalle de la bitácora de enrolamiento (trigger `a0_`, antes del de transiciones) |
| `db/ddl/91` | *(V1.9)* Endurecimientos de dos RPC del Pi: el autor de la baja automática por persona inactiva sale del último movimiento registrado (`creado_en`), y el detalle del Pi pierde los caracteres de formato Unicode invisibles o de reordenamiento |
| `db/ddl/90` | *(V1.9)* `fn_terminal_anomalias`: tres categorías del tablero de anomalías de marcas (marcas posteriores a la baja, picos de tasa, huecos de secuencia) como función de sólo lectura, `SECURITY INVOKER`, `EXECUTE` sólo `service_role`, que filtra por la terminal pedida y devuelve `persona_id` (nunca nombres) |
| `db/ddl/88` y `89` | *(V1.9)* Configuración de terminales: `88` (permiso `terminal_config_edicion`, `tiempo.terminal_consentimiento` con la versión 1 provisional, columna `consentimiento_id`, movimiento `reconsentido`, `SCJ16`, publicar y reconsentir en lote) y `89` (5 claves `terminal_*` de `tiempo.parametro`, edición con regla cruzada, lector tolerante, guard `SCJ17`) |
| `db/ddl/87` | *(V1.8)* Trigger `BEFORE INSERT` en `tiempo.correccion` que rechaza (`SCJ15` / `marca_en_tramo`) la corrección de una marca que ya es apertura o cierre de un tramo; función `SECURITY DEFINER` sin `EXECUTE` para la API |
| `db/ddl/86` | *(V1.8)* Cierre del hallazgo sobre `78_`: trigger de columnas de `excepcion`, constraint trigger `dia_cerrado` recreado (revisión en la misma transacción o descarte), trigger de coherencia de `tramo`, tabla inmutable `excepcion_descarte`, RPC `fn_excepcion_dia_cerrado_descartar`, permiso `excepcion_dia_cerrado_descarte` (`SCJ15`) |
| `db/ddl/82` a `85` | *(V1.8)* Autenticación de la terminal y ruta de marcas: `terminal_credencial` y 4 columnas de estado en `terminal` (`82`); los RPC del puente, el trigger `SCJ13` de desactivación, el trigger `SCJ14` de revocación y el reemplazo de `fn_bitacora_terminal_usuario_aplica` con `FOR SHARE` (`83`); `marca_rechazada` y su purga (`84`); la caducidad de altas en `esperando_huella` (`85`). `SCJ-DEC-12` |
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
| Recálculo acotado de `tramo`/`dia` tras corregir | `tramo`, `dia` | `fn_correccion_recalcula_tramo` (`AFTER INSERT`) — sólo el tramo que usa la marca corregida, nunca el histórico completo. *(V1.10)* Desde `87_` no se alcanza: corregir una marca que ya está en un tramo se rechaza (`SCJ15` / `marca_en_tramo`), así que la corrección solo ocurre antes del cierre | `SCJ-PRO-10` V2.0 |
| Cálculo de `requiere_revision`/`motivo_revision` al insertar una marca | `marca`, `excepcion` | `fn_marca_valida_revision` (`AFTER INSERT`, `SECURITY DEFINER`). *(V1.6)* Genera excepción por `reloj_no_sincronizado`, `persona_inactiva`, `dia_cerrado` y `fuera_de_horario`. `72_*.sql` corrigió que `fuera_de_horario` se generaba aunque la jornada tuviera `genera_alerta_horario = false` (flexible o de confianza); ahora respeta esa columna | `SCJ-PRO-11` |
| Identidad y alcance mínimo del checador físico | `marca` | Rol `terminal_checador` (no `service_role`), RLS sólo `INSERT` con `origen='terminal'` forzado — primera RLS de todo el esquema `tiempo`. *(V1.7)* El rol y su policy siguen sin cambio, pero el puente de la terminal Hikvision no los usa: el Pi sólo habla con el backend, que inserta las marcas | `SCJ-PRO-11` (V2.0), `SCJ-DEC-11` *(V1.10)* `93_` retiró la policy, el `INSERT` y la membresía: el rol quedó vacío y `NOLOGIN`. |
| Materializar `dia` al resolver una ausencia | `ausencia`, `dia` | `fn_ausencia_resuelve_excepcion` extendido — `ON CONFLICT ... WHERE estado='abierto'`, nunca pisa un día ya resuelto por otra vía | `SCJ-PRO-12` (`SCJ-PRA-01 #13`) |
| Un `employeeNo` por persona y terminal, nunca reutilizado *(V1.7)* | `terminal_usuario` | `UNIQUE (terminal_id, employee_no)`; índice único parcial `uq_terminal_usuario_persona_vigente (terminal_id, persona_id) WHERE estado <> 'baja'` (un alta vigente por persona y terminal); el número sale de `tiempo.seq_terminal_employee_no` (`MINVALUE 1`, `MAXVALUE 99999999`, `NO CYCLE`; primera secuencia explícita del proyecto, sin privilegios para ningún rol de la API) | `SCJ-DEC-11` |
| Mapeo de enrolamiento sólo derivado de una bitácora *(V1.7)* | `terminal_usuario` ← `bitacora_movimiento_terminal_usuario` | La tabla viva no tiene `INSERT`/`UPDATE`/`DELETE` para ningún rol de la API; la escribe sólo `trg_bitacora_terminal_usuario_aplica` (`BEFORE INSERT`, `SECURITY DEFINER`, `search_path` fijo), que valida las 6 transiciones de estado y falla con `SCJ11`/`SCJ12` y un `HINT` estable. `BEFORE` y no `AFTER` porque en `asignado` crea la fila viva y completa `terminal_usuario_id`/`employee_no` antes de evaluar `NOT NULL` y la FK | `SCJ-DEC-11` |
| Inmutabilidad de la bitácora de terminal *(V1.7)* | `bitacora_movimiento_terminal_usuario` | 3 capas: (1) `REVOKE ALL` y `GRANT SELECT, INSERT` explícito (no se confía en que el `GRANT ALL` schema-wide de `38_*.sql` "no concedió" `UPDATE`/`DELETE`/`TRUNCATE`); (2) RLS sin policies de `UPDATE`/`DELETE`; (3) triggers `BEFORE UPDATE OR DELETE` por fila y `BEFORE TRUNCATE` por statement. Residual aceptado: el dueño de la base aún puede `DROP`/`DISABLE TRIGGER`. `CHECK`s de coherencia: `origen = 'web'` sí y sólo si el movimiento es `asignado`/`baja_solicitada`; autor obligatorio sí y sólo si `origen = 'web'`; conteo de huellas 1-10 sólo en `huella_capturada`; `detalle` obligatorio en `error` y de máx. 500 caracteres | `SCJ-DEC-11` |
| Autoría atada al propio usuario en el alta/baja web *(V1.7)* | `bitacora_movimiento_terminal_usuario` | Policy `INSERT` exige `terminal_usuario_edicion` (no heredable), `origen = 'web'`, `tipo_movimiento IN ('asignado','baja_solicitada')` y `registrado_por = auth.uid()` (anti-suplantación, mismo criterio que `62_*.sql` y `68_*.sql`). Los movimientos `origen = 'terminal'` los inserta sólo `service_role` | `SCJ-DEC-11` |/
| Llave del puente sólo como hash, y revocación irreversible *(V1.8)* | `terminal_credencial` | `hash char(64)` con `CHECK (hash ~ '^[0-9a-f]{64}$')` y `UNIQUE (hash)`; RLS habilitada **sin policies** y privilegios `REVOKE ALL` + `GRANT` mínimo: `service_role` sólo `SELECT`, `INSERT` y `UPDATE` de `revocada_en`, `expira_en` y `etiqueta` (`hash`, `ultimo_uso_en`, `ultima_ip` e `ip_cambiada_en` los escribe sólo `fn_terminal_autenticar`); sin `DELETE`/`TRUNCATE`. `trg_terminal_credencial_revocacion_inmutable` (`BEFORE UPDATE OF revocada_en`, `WHEN` el valor anterior no es `NULL` y cambia): una revocación no se deshace ni se mueve (`SCJ14`). Una llave se sustituye por otra (rotación con traslape), nunca se reactiva. Sin vencimiento por defecto | `SCJ-DEC-12` §1 |
| No desactivar una terminal con altas vigentes *(V1.8)* | `terminal` | `trg_terminal_valida_desactivacion` (`BEFORE UPDATE OF activa ... WHEN (OLD.activa AND NOT NEW.activa)`, `SECURITY DEFINER`): `SCJ13` si hay altas no-`baja`; toma la terminal `FOR UPDATE` antes de contar, y `asignado` la toma `FOR SHARE` (reemplazo de `fn_bitacora_terminal_usuario_aplica` en `83_`), así que la asignación ve la terminal inactiva o la desactivación ve el alta. Lo bloquea cualquier `UPDATE`, incluso directo de `service_role` | `SCJ-DEC-12` §6 |
| Evidencia de rechazos sin inmutabilidad por trigger *(V1.8, excepción deliberada)* | `marca_rechazada` | A diferencia de la bitácora de enrolamiento, esta tabla debe poder borrarse (retención de 90 días), así que **no lleva** triggers de inmutabilidad: la garantía es de **privilegios**. `REVOKE ALL` y `GRANT SELECT` sólo (a `authenticated` y `service_role`); **nadie de la API inserta**: la única escritura es `fn_terminal_rechazo_registrar` (`SECURITY DEFINER`, sin `EXECUTE` para la API) y el único borrado es `fn_marca_rechazada_purgar` (retención mínima de 7 días). `CHECK` de lista cerrada de 5 códigos, `UNIQUE (terminal_id, evento_id)` con `ON CONFLICT DO NOTHING`, sin texto libre (cada campo se guarda sólo si cumple su formato) y tope de 5 000 filas por terminal en 24 h | `SCJ-DEC-12` §6 |
| Ruta de marcas por RPC *(V1.8)* | `marca` ← `fn_marca_terminal_registrar(bigint, jsonb)` | `SECURITY DEFINER`, `SET search_path = tiempo, personas, pg_temp`, `EXECUTE` sólo `service_role`: el Pi manda `employee_no` y la base resuelve `persona_id` (nunca sale); fija `origen='terminal'` y `requiere_revision=false` sin leerlos del evento; valida forma (ISO 8601 con zona, desfase `-12:00..+14:00`), absurdos de fecha, `secuencia_local` acotada, `no_enrolado` (sin alta, alta en `pendiente_alta`, alta en `baja` con marca posterior a la baja +1 h, o marca anterior a la alta -1 h), degradación de `estado_reloj` (sólo empeora), topes de tasa (valores ajustables como constantes) e idempotencia por `evento_id` (desambigua el `23505` por nombre de restricción). Un lote a la vez por terminal (advisory lock). Sólo devuelve códigos de lista cerrada, nunca texto de excepción | `SCJ-DEC-12` §2 |
| Funciones del puente con alcance por terminal *(V1.8)* | `fn_terminal_autenticar`, `fn_terminal_mapa`, `fn_terminal_movimiento_registrar`, `fn_terminal_latido` | Todas reciben `p_terminal_id` (la fija el servidor desde la credencial) y validan pertenencia dentro de la función: un movimiento sobre una alta de otra terminal responde igual que uno inexistente. El mapa no incluye `persona_id` ni nombres. Un `error` más de 20 veces por alta y hora devuelve `limitado` sin insertar (la bitácora es inmutable) | `SCJ-DEC-12` §3 |
| Bajas automáticas con autor derivado *(V1.8)* | `bitacora_movimiento_terminal_usuario` ← `fn_terminal_baja_por_persona_inactiva`, `fn_terminal_baja_por_caducidad` | Emiten `baja_solicitada` (`origen='web'`) con el autor del acto original (el último movimiento de suspensión/baja de la persona, o el de la asignación): no hay usuario "sistema" ni origen nuevo. La caducidad (`esperando_huella` con más de `p_horas` horas desde el `usuario_creado` de la bitácora; defecto 24, piso 4, máximo 50 bajas por corrida) re-lee cada alta `FOR UPDATE` para no dar de baja a quien acaba de enrolar. Idempotentes (ignoran `SCJ11`/`SCJ12`) | `SCJ-DEC-12` §5, §12.7 |
| Toda función nueva es `SECURITY DEFINER` con `search_path` fijo y `EXECUTE` acotado *(V1.8)* | 11 funciones de `83_`/`84_`/`85_` | `proconfig = {search_path=tiempo, personas, pg_temp}` en todas (contrastado en la base real); `EXECUTE` nace en `PUBLIC` y cada función lo revoca a `PUBLIC`, `anon` y `authenticated` en su mismo archivo: las 8 que llama el backend (`fn_terminal_autenticar`, `fn_terminal_mapa`, `fn_terminal_movimiento_registrar`, `fn_terminal_latido`, `fn_marca_terminal_registrar`, `fn_terminal_baja_por_persona_inactiva`, `fn_marca_rechazada_purgar`, `fn_terminal_baja_por_caducidad`) las ejecuta sólo `service_role`; la interna `fn_terminal_rechazo_registrar` y las 2 de trigger (`SCJ13`, `SCJ14`) no las ejecuta ningún rol de la API. Un `CREATE OR REPLACE` futuro debe repetir `SECURITY DEFINER` y `SET search_path`. `db/verificar_ddl.sql` (secciones 29, 30, 36, 37 y 40) lo comprueba con 0 filas esperadas | `SCJ-DEC-12` §8.3 |
| Versionado inmutable del texto de consentimiento *(V1.9)* | `terminal_consentimiento` | Tabla de sólo inserción sin `vigente_hasta` (la vigente es la de mayor `version`); `UNIQUE (version)`; `CHECK` de texto (1 a 4000 caracteres, sin control salvo `\n`), de hash (`texto_sha256` = SHA-256 del texto) y de autor (`creado_por` NULL sólo en la versión 1 provisional); RLS con una policy `SELECT` por permiso específico; 3 capas de inmutabilidad (`REVOKE`, sin policy de escritura, triggers `BEFORE UPDATE OR DELETE` y `BEFORE TRUNCATE`); la escribe sólo `fn_terminal_consentimiento_publicar` | decisión del usuario 2026-10-08, `SCJ-PRO-15 §IV.7` |
| Cada alta ligada a la versión del consentimiento *(V1.9)* | `bitacora_movimiento_terminal_usuario`, `terminal_usuario` | Columna `consentimiento_id` (FK): `CHECK ((tipo_movimiento IN ('asignado','reconsentido')) = (consentimiento_id IS NOT NULL))`; el trigger exige que sea la versión VIGENTE (`SCJ16` / `consentimiento_desactualizado`), tomando la tabla de versiones en `ROW EXCLUSIVE` (choca con el `SHARE ROW EXCLUSIVE` de la publicación); la tabla viva guarda la versión aceptada más reciente | decisión del usuario 2026-10-08 |
| Autor y hora de los movimientos de persona atados a la base *(V1.9)* | `bitacora_movimiento_persona` | Policy de INSERT: `registrado_por = auth.uid()`, tipo limitado a suspension/reactivacion/baja_definitiva, `cambio_estado_persona`; trigger BEFORE INSERT `trg_bitacora_persona_fija_hora` (INVOKER): para anon/authenticated `creado_en := now()` y `fecha_efectiva` en [now() − 90 días, now() + 5 min] (`22023` / `fecha_efectiva_invalida`); `service_role` y el dueño no se tocan (alta automática, bootstrap). Requisito: el INSERT en `personas.usuario` se hace siempre con `service_role` | revisión de `security` 2026-10-08 (M1/B2) |
| Auto-asignación prohibida salvo el administrador genérico *(V1.9)* | `bitacora_movimiento_terminal_usuario` | El trigger `fn_bitacora_terminal_usuario_aplica` rechaza con `SCJ12` / `auto_asignacion_prohibida` un `asignado` cuya persona es la del propio llamador salvo que éste ocupe un puesto con `es_administrador_generico` (`personas.fn_usuario_es_administrador_generico`, sobre el actor `NEW.registrado_por` que la policy ata a `auth.uid()`); antes sólo la aplicaba el backend y la policy dejaba a cualquiera con `terminal_usuario_edicion` asignarse por PostgREST. La misma regla y excepción alcanzan al `reconsentido` de la alta propia (`SCJ12` / `auto_reconsentimiento_prohibido`; en el lote la alta propia se omite con motivo `alta_propia`); pedir la propia baja sigue permitido | decisión del usuario 2026-10-06, `SCJ-PRO-15 §V.3` |
| Sin oráculo del trigger para quien no puede escribir *(V1.9)* | `bitacora_movimiento_terminal_usuario` | El trigger (`SECURITY DEFINER`) corre antes del `WITH CHECK` de la RLS: un llamador `anon`/`authenticated` sin `terminal_usuario_edicion`, con un movimiento que no es web o sin `sub`, recibe NEW de vuelta sin errores ni efectos del trigger y la RLS responde `42501` (mismo patrón que `87_`) | revisión de `security` 2026-10-08 |
| Reconsentimiento que no bloquea marcas *(V1.9)* | `bitacora_movimiento_terminal_usuario`, `terminal_usuario.usuario_creado_en` | Movimiento `reconsentido` (origen web, `terminal_usuario_edicion`): no cambia estado ni huellas y conserva `error_detalle`; "pendiente" se calcula al leer (`fn_terminal_reconsentimiento_pendiente_ids`: pendiente_alta, esperando_huella o activo con versión menor que la última con `cambio_material`); ninguna función de marcas lo consulta | decisión del usuario 2026-10-08 |
| Configuración de terminales con permiso propio *(V1.9)* | `parametro` | Claves `terminal_*` editables sólo con `fn_terminal_config_actualizar` (`SECURITY DEFINER`, gate `terminal_config_edicion` dentro, lista blanca y rangos, regla `traslape*2 <= antigüedad_meses*30`); `fn_parametro_actualizar_valor` las rechaza con `SCJ17`; los topes de seguridad (50 bajas por corrida, 5 000 rechazos por día, topes por hora) siguen fijos | decisión del usuario 2026-10-08 |
| Interruptor de la activación por huella *(V1.10)* | `parametro`, `bitacora_config_terminal` | Dos claves fuera del catálogo editable, `CHECK` de formato (0/1; ISO con zona), trigger de auditoría estrecho y `BEFORE TRUNCATE` bloqueado; solo se enciende con `fn_terminal_inferir_huella_cambiar` (nota, vencimiento ≤ 30 días, consentimiento publicado) | `SCJ-DEC-11`/`SCJ-DEC-12`, `97_` |
| Sin acceso de `anon` y libros inmutables *(V1.10)* | Las 37 tablas | `REVOKE ALL` a `anon`; sin `TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN` para la API; sin `UPDATE`/`DELETE` para `authenticated` y `service_role` en bitácoras, ledger y auditorías | `100_`-`103_` |
| Saldo del banco movido solo por el disparador *(V1.10)* | `banco_de_horas`, `movimiento_de_saldo` | `fn_movimiento_de_saldo_actualiza_banco` `SECURITY DEFINER` con un `UPDATE` atómico y `SCJ18`; el ledger se escribe a mano solo con `fn_movimiento_de_saldo_manual_registrar` (autor por `auth.uid()`) | `SCJ-DEC-02`, `104_` |
| Padrón por permiso e identidad separada del nombre *(V1.10)* | `persona`, `expediente`, `usuario`, `asignacion` y bitácoras | Policies de `SELECT` con `fn_caller_ve_padron`/`fn_caller_ve_identidad` (`DEFINER`); `authenticated` sin `SELECT` de tabla en `persona`, solo columnas de nombre; `fn_persona_identidad` para el resto | `SCJ-PRO-01`, `108_`-`112_` |
| Reglas de asignaciones *(V1.10)* | `asignacion` | `trg_asignacion_valida_reglas` (no autoasignarse, no vigencia futura; `SCJ19`, `SCJ20`) y `trg_asignacion_valida_plazas` (límite de plazas con candado consultivo por puesto; `SCJ21`) | `SCJ-PRO-04`, `113_`-`115_` |
| Alta y edición de persona atómicas *(V1.10)* | `persona`, `expediente` | `fn_persona_crear` en una transacción; `fn_persona_actualizar_datos` sin `ON CONFLICT` (`SCJ22` si falta un dato del expediente); trigger de columnas de identidad | `SCJ-PRO-01`, `70_`, `107_`, `116_` |
| Policy de INSERT de `correccion` con la fila nueva calificada *(V1.10)* | `correccion` | `correccion_edicion` y, si la excepción ya estaba resuelta, también `excepcion_reapertura` | `SCJ-PRO-10`, `48_`, `117_` |
| Jornada neta de la ausencia *(V1.10)* | `ausencia`, `dia` | `fn_ausencia_resuelve_excepcion` suma por fila de `patron_semanal` `hora_salida − hora_entrada − minutos_comida` | `SCJ-PRO-08`, `118_` |
| Corte quincenal idempotente por persona y periodo *(V1.10)* | `corte_quincenal_aplicado` | `UNIQUE (persona_id, periodo_desde)`, `CHECK` de periodo y horas, RLS sin policies (solo `service_role`); `fn_corte_quincenal_aplicar_persona` de 8 argumentos rechaza un duplicado con `SCJ23` | `SCJ-PRO-13`, `119_` |
| Compensación auditada del ledger *(V1.10)* | `movimiento_de_saldo` | Tipo `compensacion` con `compensa_movimiento_id`, índice único parcial (una vez por movimiento), `CHECK` de forma y trigger `DEFINER` (mismo banco, monto opuesto exacto, saldo no negativo); RPC con permiso no heredable `movimiento_de_saldo_compensar` | `SCJ-DEC-02`, `120_` |
| Tipo de ausencia inmutable una vez resuelta *(V1.10)* | `ausencia` | Policy de `UPDATE` solo con la ausencia pendiente y trigger `BEFORE UPDATE OF tipo_de_ausencia` (`SCJ25`), también para `service_role` | `SCJ-PRO-08`, `121_` |
| Nadie resuelve su propia ausencia *(V1.10)* | `aprobacion_ausencia`, `ausencia` | Policy de `INSERT` (aprobador = persona de la sesión, ausencia ajena), trigger `DEFINER` (`SCJ26`), `fn_ausencia_resolver` y la policy de `UPDATE` que impide editar el tipo de la propia ausencia | `SCJ-DEC-05`, `122_` |
| Tiempos del tramo coherentes con sus marcas *(V1.10)* | `tramo`, `correccion` | `trg_tramo_valida_tiempos` (`inicio`/`fin`/`minutos_trabajados` = momentos efectivos; `SCJ15`/`tramo_tiempos_incoherentes`) y `uq_correccion_marca_creado_en` (el «más reciente» de una marca es único) | `SCJ-PRO-12`, `123_` |
| Cierre de día atómico *(V1.10)* | `dia`, `tramo`, `excepcion` | `fn_cierre_dia_armar` crea día, tramos y excepción de paridad en una transacción (`SCJ27`); `EXECUTE` solo `service_role` | `SCJ-PRO-12`, `124_` |
| Descarte auditado de alertas de horario *(V1.10)* | `excepcion`, `excepcion_descarte` | `fn_excepcion_horario_descartar` (permiso no heredable, autor por sesión, motivo de 10 a 500 caracteres, nunca la alerta propia; `SCJ28`) | `SCJ-PRO-10` V2.0, `125_` |

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
| Generar, entregar y rotar la llave del puente *(V1.8)* | Script de TI con `service_role`, fuera de la base | La base sólo guarda el hash SHA-256; la llave en claro se muestra una única vez al generarla y nunca pasa por una policy ni por un endpoint web (`SCJ-DEC-12` §1) |
| Valores de los topes de tasa, ventanas de reloj, retenciones y tope de bajas *(V1.8)* | Constantes con nombre, comentadas, dentro de cada función (`fn_marca_terminal_registrar`, `fn_terminal_rechazo_registrar`, `fn_marca_rechazada_purgar`, `fn_terminal_baja_por_caducidad`) | Son defensas del puente y valores iniciales ajustables, no reglas de negocio de Recursos Humanos: no se agregan a `tiempo.parametro` (el catálogo de ocho claves tiene consumidor real cada una). Cambiarlas exige un `CREATE OR REPLACE` revisado que repita `SECURITY DEFINER` y `search_path` |
| Estado de contacto de la terminal y tablero de anomalías *(V1.8)* | Backend, calculado al leer (`SCJ-DEC-12` §6) | No hay estado persistido que pueda quedar desactualizado; las 4 columnas de telemetría de `tiempo.terminal` sólo guardan lo que reportó el último latido |

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
| *(V1.8)* `tiempo.terminal` agrega 4 columnas de telemetría (`reloj_desfase_seg`, `terminal_alcanzable`, `version_pi`, `marcas_pendientes`) que **ninguna escritura directa de la API puede tocar** | Las llena sólo `fn_terminal_latido` (`SECURITY DEFINER`); el `UPDATE` de columna de `service_role` sigue acotado a 4 columnas de configuración (contrastado en la base real) | `SCJ-DIC-01` §II |
| *(V1.10)* `movimiento_de_saldo.tipo` admite `compensacion` y la tabla agrega `compensa_movimiento_id` | `SCJ-DEC-02` fijaba los movimientos del corte y los manuales; hacía falta una vía auditada para deshacer un error del sistema sin editar un libro de solo inserción | `SCJ-DEC-02` V1.1, `SCJ-DIC-01` V1.6 |
| *(V1.10)* `fn_dia_revisar` también revisa un día `cerrado`, no solo `bloqueado` | Marcas tardías llegadas después del cierre necesitaban armarse en tramos sin reabrir el día | `SCJ-DEC-06` V1.1 |
| *(V1.10)* Las excepciones `fuera_de_horario` de un día cerrado o revisado tienen descarte auditado propio | La corrección de la marca se bloquea cuando ya está en un tramo (`87_`) y la excepción quedaba pendiente para siempre | `SCJ-DEC-07` V1.1, `SCJ-PRO-10` V2.0 |

---

*Modelo físico · Folio SCJ-MOD-03 · V1.10*
