# Diccionario de datos

**Sistema de Control de Jornada · Esquemas `personas` y `tiempo`**
Folio SCJ-DIC-01 · Versión 1.4 · 8 de octubre de 2026

> **Cambio de versión (V1.3 → V1.4, menor):** se agregan los scripts `88`, `89` y `90` (configuración de terminales, consentimiento biométrico versionado y tablero de anomalías; sin contradecir lo escrito): la tabla `tiempo.terminal_consentimiento` (versiones del texto de consentimiento, de sólo inserción, con la versión 1 provisional sembrada); la columna `consentimiento_id` en `tiempo.bitacora_movimiento_terminal_usuario` y en `tiempo.terminal_usuario`; el tipo de movimiento `reconsentido`; el permiso `terminal_config_edicion` (no heredable, sólo TI y Gerente General); 5 claves `terminal_*` en `tiempo.parametro`; 13 funciones nuevas (publicar el texto, lista única de reconsentimientos pendientes, reconsentimiento en lote, 2 de trigger, editar configuración, lector tolerante, catálogo de rangos, `fn_terminal_anomalias` de sólo lectura y 4 ayudas en `personas`: 2 internas del trigger y 2 del llamador para el lote) y la reescritura de `fn_bitacora_terminal_usuario_aplica` y `fn_parametro_actualizar_valor`; y los códigos `SCJ16` y `SCJ17`. Se recalcula: **35 tablas** (11 en `personas`, 24 en `tiempo`), **70 funciones**, 77 policies RLS, 53 permisos, 13 parámetros y **91 scripts (`00` a `90`)**. Lo documentado de `88`/`89` sale de los scripts y de sus `COMMENT ON`; se contrastará contra la base real en solo lectura cuando se apliquen (hasta entonces es lo que producen los archivos, no el catálogo vivo).
> **Cambio de versión (V1.2 → V1.3, menor):** se agregan lo que dejan los scripts `82` a `85` (`SCJ-DEC-12`, autenticación de la terminal, ruta de marcas y caducidad de altas): las tablas `tiempo.terminal_credencial` y `tiempo.marca_rechazada`, las 4 columnas de estado de `tiempo.terminal` (`reloj_desfase_seg`, `terminal_alcanzable`, `version_pi`, `marcas_pendientes`), 11 funciones nuevas (6 RPC para el puente, 1 de purga, 1 de caducidad, 1 interna de rechazos y 2 de trigger), 3 triggers de seguridad (`SCJ13`, `SCJ14`) y 1 policy; y se recalcula: **34 tablas** (11 en `personas`, 23 en `tiempo`), 24 columnas con dominio cerrado por `CHECK`, **57 funciones (coinciden los scripts y la base real)**, 76 policies RLS, 52 permisos y **88 scripts (`00` a `87`)**. El script `86` (cierre del hallazgo de `security` sobre `78_`, aplicado el 7-oct-2026) suma la tabla `tiempo.excepcion_descarte`, 6 funciones, 4 triggers, 1 policy, el permiso `excepcion_dia_cerrado_descarte` y el código `SCJ15`. El script `87` (aplicado el 7-oct-2026) suma 1 función y 1 trigger que impiden corregir la hora de una marca que ya está en un tramo (hint `marca_en_tramo`). Esta vez lo documentado se contrastó contra la base real de Supabase en solo lectura (columnas, restricciones, índices, triggers, privilegios y EXECUTE por función), no sólo contra los archivos. No se contradice nada de lo ya escrito.
> **Cambio de versión (V1.1 → V1.2, menor):** se agregan las 3 tablas de la terminal biométrica Hikvision (`tiempo.terminal`, `tiempo.terminal_usuario`, `tiempo.bitacora_movimiento_terminal_usuario`, scripts `80` y `81`, `SCJ-DEC-11`): 31 tablas en total (11 en `personas`, 20 en `tiempo`), 23 columnas con dominio cerrado por `CHECK`, 39 funciones, 74 policies RLS y 51 permisos. No se contradice nada de lo ya escrito. Además se corrige el nombre del archivo, que seguía en `V1_0` aunque el encabezado decía 1.1 (`CONVENCIONES.md §I`).

> **Cambio de versión (V1.0 → V1.1, menor):** el diccionario deja de documentar sólo `tiempo.persona` y se reconstruye contra el esquema real que dejan los scripts `db/ddl/00` a `79`: 28 tablas (11 en `personas`, 17 en `tiempo`), sin enumerados nativos (20 columnas con dominio cerrado por `CHECK`), 8 parámetros, 36 funciones y 70 policies RLS. Se elimina la columna "filas esperadas de 6 meses" (era del proyecto escolar) y se agrega la lista de discrepancias contra `SCJ-MOD-03`.

Cada tabla, cada columna, su tipo, su dominio y su propósito. Los `COMMENT ON` del DDL son la fuente de las descripciones; donde una columna no tiene `COMMENT ON` se indica así, sin inventar descripción.

> **Cómo se generó:** ver la nota de método al final. Tipos, nulos, predeterminados, restricciones, índices, triggers, policies y privilegios salieron del catálogo de un PostgreSQL 16 desechable donde se aplicaron los 80 scripts en orden; el estado documentado es el final (los scripts posteriores ya aplicaron sus `ALTER`/redefiniciones).

---

## I. Resumen del esquema

### Esquema `personas` — 11 tablas

Subsistema de Personas: identidad, expediente, estructura organizacional, asignaciones, usuarios, permisos y bitácoras.

| Tabla | Columnas | Policies RLS | Propósito (primera frase del `COMMENT ON`) |
|---|---|---|---|
| `persona` | 13 | 4 | Identidad civil de la persona física. |
| `expediente` | 5 | 4 | Referencia al expediente físico/digital de la persona. |
| `usuario` | 6 | 4 | Cuenta de acceso, ligada 1:1 a auth.users (Supabase Auth) y a lo más 1:1 a personas.persona. |
| `bitacora_movimiento_persona` | 8 | 2 | Fuente de verdad de persona.estado y fecha_baja (ver SCJ-PRO-02) y también registra el alta (tipo_movimiento = alta, disparado por trg_usuario_bitacora_alta). |
| `area` | 5 | 4 | Catálogo raíz del módulo Estructura Organizacional (SCJ-PRO-03). |
| `departamento` | 6 | 4 | Segundo nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.area. |
| `puesto` | 10 | 4 | Tercer nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.departamento, con jerarquía propia vía reporta_a_id. |
| `asignacion` | 7 | 4 | Vínculo persona-puesto con vigencia (SCJ-PRO-04). |
| `permiso` | 5 | 4 | Catálogo de permisos (SCJ-PRO-05). |
| `puesto_permiso` | 6 | 4 | Estado vigente de "qué permiso tiene cada puesto" — snapshot derivado y mantenido por trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) a partir de bitacora_… |
| `bitacora_movimiento_puesto_permiso` | 8 | 2 | Fuente de verdad de puesto_permiso.activo (SCJ-PRO-05). |

### Esquema `tiempo` — 24 tablas

Subsistema de Tiempo: marcas, jornadas, días, tramos, banco de horas, ausencias, excepciones y corridas de batch. Sin atributos de identidad (`SCJ-FRO-01`).

| Tabla | Columnas | Policies RLS | Propósito (primera frase del `COMMENT ON`) |
|---|---|---|---|
| `persona` | 1 | 1 | Stub. |
| `tope_legal` | 5 | 0 | Máximo semanal y de horas extra, con vigencia. |
| `dia_festivo` | 3 | 0 | Catálogo de días festivos. |
| `parametro` | 6 | 0 | Valor de regla de negocio, configurable. |
| `jornada_asignada` | 9 | 4 | Qué jornada tuvo una persona, con vigencia. |
| `patron_semanal` | 7 | 4 | Qué días, con qué horario y con qué pausa de comida. |
| `marca` | 12 | 3 | Evento crudo producido por el terminal o por captura manual. |
| `dia` | 8 | 2 | Marcas de una persona en una fecha, con estado. |
| `tramo` | 7 | 3 | Par de marcas: la impar abre, la par cierra. |
| `clasificacion_de_tiempo` | 3 | 1 | Ordinario, reposición o extra, sobre un tramo — cronológica y acumulada dentro del periodo quincenal, nunca por día ni por proporción; |
| `banco_de_horas` | 5 | 1 | Deuda de horas acumulada de una persona. |
| `movimiento_de_saldo` | 8 | 2 | Libro de movimientos del banco de horas — única fuente de verdad, banco_de_horas.monto es caché derivado. |
| `correccion` | 6 | 2 | Registro nuevo que apunta a una marca anterior — nunca se sobrescribe momento_dispositivo. |
| `ausencia` | 7 | 2 | Periodo no trabajado, con naturaleza y autorización. |
| `aprobacion_ausencia` | 7 | 2 | Cadena de aprobación de una ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), Opción C. |
| `excepcion` | 6 | 2 | Marca o día apartado para revisión humana — nunca ambos, nunca ninguno (ck_excepcion_marca_o_dia). |
| `corrida_batch` | 8 | 1 | Estado visible de cada corrida de batch — de dónde lee la app "última corrida: exitosa/fallida, N pendientes" (SCJ-PRO-12). |
| `terminal` | 11 | 1 | Terminal biométrica física (SCJ-DEC-11). |
| `terminal_usuario` | 11 | 1 | [CALCULADO] Persona enrolada en una terminal y estado de su enrolamiento (SCJ-DEC-11). |
| `bitacora_movimiento_terminal_usuario` | 12 | 2 | Fuente de verdad de tiempo.terminal_usuario (SCJ-DEC-11). Sólo inserción: inmutable en 3 capas. |
| `terminal_credencial` | 10 | 0 | Llave opaca del puente de una terminal (SCJ-DEC-12 §1): sólo el hash SHA-256. |
| `marca_rechazada` | 10 | 1 | Evidencia de un rechazo DEFINITIVO de fn_marca_terminal_registrar (SCJ-DEC-12 §6). |
| `excepcion_descarte` | 6 | 1 | Auditoría de fn_excepcion_dia_cerrado_descartar (86_): quién descartó una marca tardía sobre un día ya revisado, cuándo y por qué. |
| `terminal_consentimiento` | 9 | 1 | Versiones del texto de consentimiento biométrico y aviso de privacidad (SCJ-PRO-15 §IV.7). Sólo inserción, inmutable en 3 capas. |

Total: **35 tablas** (11 + 24), coincide con lo que espera `db/verificar_ddl.sql` (personas = 11, tiempo = 24) y con la base real. Ninguna vista, ninguna vista materializada, ningún tipo `ENUM`. `tiempo.persona` es el stub de la frontera (`SCJ-FRO-01`); sin él, `tiempo` tendría 23 tablas propias.

---

## II. Tablas

Leyenda de privilegios por rol: `D` DELETE, `I` INSERT, `S` SELECT, `U` UPDATE (privilegio de tabla, aparte de RLS). La columna Tipo es el tipo de PostgreSQL; "Nulo" = admite NULL.

### `tiempo.persona`

> Stub. Identificador opaco. Ningún atributo de identidad vive aquí: ni nombre, ni CURP, ni RFC, ni NSS, ni salario. Si un requisito parece necesitarlos, el requisito está mal planteado. Ver SCJ-FRO-01.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | — | — | Identificador opaco, mismo valor que personas.persona.id (uuid). En operación se sincroniza desde personas.persona; en este proyecto lo puebla el generador de datos sintéticos. |

**Claves:**

- PK `id`

**Índices** (sin contar PK): —

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `tiempo.aprobacion_ausencia`.`aprobador_id`, `tiempo.ausencia`.`persona_id`, `tiempo.banco_de_horas`.`persona_id`, `tiempo.correccion`.`autor_id`, `tiempo.dia`.`persona_id`, `tiempo.dia`.`revisado_por`, `tiempo.jornada_asignada`.`persona_id`, `tiempo.marca`.`persona_id`, `tiempo.movimiento_de_saldo`.`autor_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `persona_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |

---

### `tiempo.tope_legal`

> Máximo semanal y de horas extra, con vigencia. vigente_hasta NULL = vigente actual; el traslape entre vigencias se valida en la aplicación (SCJ-DEC-04, Opción A). Ver SCJ-ESP-01 §VI.4.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_hasta` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `maximo_semanal` | `numeric(6,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `maximo_extra` | `numeric(6,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_tope_legal_vigente_desde` (`vigente_desde`)

**Índices** (sin contar PK): 

- `uq_tope_legal_vigente_desde` (UNIQUE): `(vigente_desde)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

**Policies:** ninguna (con RLS habilitada y sin policy, el acceso queda denegado por omisión a roles sin BYPASSRLS).

---

### `tiempo.dia_festivo`

> Catálogo de días festivos. No calculable por fórmula (festivos móviles) — se carga a mano. Domingo no necesita catálogo: se deriva de la fecha. Usado para separar, al corte quincenal, las horas trabajadas en domingo o festivo con su concepto de pago — sin importar si esas horas fueron ordinarias, de reposición o extra.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `fecha` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `nombre` | `character varying(100)` | No | — | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_dia_festivo_fecha` (`fecha`)

**Índices** (sin contar PK): 

- `uq_dia_festivo_fecha` (UNIQUE): `(fecha)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

**Policies:** ninguna (con RLS habilitada y sin policy, el acceso queda denegado por omisión a roles sin BYPASSRLS).

---

### `tiempo.parametro`

> Valor de regla de negocio, configurable. Ver comentario completo en 02_tiempo.sql — este archivo sólo carga valores de ejemplo, nunca los reales de operación.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `clave` | `character varying(100)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `valor` | `text` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_hasta` | `date` | Sí | — | — | NULL = vigencia activa. Borde inclusivo: al abrir una vigencia nueva, la anterior se cierra con vigente_hasta = nueva.vigente_desde - 1 (mismo criterio que tiempo.tope_legal, divergente del borde semiabierto exclusivo de SCJ-DEC-04 -- ver nota de desalineación documentada ahí). Las 8 filas sembradas por 03_parametros_ejemplo.sql quedan en NULL (sin backfill, todas activas). |
| `registrado_por` | `uuid` | Sí | — | FK → personas.usuario | Autor humano del cambio (auth_user_id de personas.usuario), resuelto por el backend desde el caller autenticado. NULL en las filas sembradas por DDL -- no tienen autor humano. |

**Claves:**

- PK `id`
- UK `uq_parametro_clave_vigente` (`clave`, `vigente_desde`)
- FK `parametro_registrado_por_fkey` (`registrado_por`) → `personas.usuario(auth_user_id)`

**Índices** (sin contar PK): 

- `uq_parametro_clave_vigente` (UNIQUE): `(clave, vigente_desde)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:DISU

**Policies:** ninguna (con RLS habilitada y sin policy, el acceso queda denegado por omisión a roles sin BYPASSRLS).

---

### `tiempo.jornada_asignada`

> Qué jornada tuvo una persona, con vigencia. normal/flexible siguen el patrón semanal y registran marca; de_confianza no pasa por terminal, no maneja horas extra ni banco de horas, sólo primas dominical/festivo cuando aplique. vigente_hasta NULL = vigente actual; el traslape entre vigencias de la misma persona se valida en la aplicación, no con EXCLUDE (SCJ-DEC-04, Opción A).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `tipo_jornada` | `character varying(20)` | No | — | `normal` / `flexible` / `de_confianza` | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_hasta` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `descuento_comida_fija` | `boolean` | No | `false` | — | — (sin `COMMENT ON` en el DDL) |
| `minutos_descuento_comida_fija` | `integer` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `horas_semanales_calculadas` | `numeric(6,2)` | Sí | — | — | Derivado de patron_semanal — se recalcula al modificar el patrón. No es fuente de verdad. |
| `genera_alerta_horario` | `boolean` | No | `true` | — | SCJ-PRO-09. true para normal (alerta si llega tarde o se pasa de hora contra patron_semanal exacto); false para flexible/de_confianza (sólo importa el total de horas, no el horario exacto). La app lo fija según tipo_jornada al crear la fila — regla de negocio en un campo, no comparación de tipo_jornada regada por el código (SCJ-ESP-01 §VI.9). |

**Claves:**

- PK `id`
- FK `jornada_asignada_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK): 

- `ix_jornada_asignada_persona_id`: `(persona_id)`

**Restricciones CHECK de varias columnas:** 
- `ck_jornada_asignada_descuento_fijo`: `descuento_comida_fija = (minutos_descuento_comida_fija IS NOT NULL)`
- `ck_jornada_asignada_vigencia`: `(vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)`

**Triggers:** 
- `trg_jornada_asignada_protege_borrado`: BEFORE DELETE → `tiempo.fn_jornada_asignada_protege_borrado()`
- `trg_jornada_asignada_protege_vigencias`: BEFORE UPDATE → `tiempo.fn_jornada_asignada_protege_vigencias()`
- `trg_jornada_asignada_valida_cadena`: AFTER INSERT OR DELETE OR UPDATE → `tiempo.fn_jornada_asignada_valida_cadena()` (CONSTRAINT TRIGGER, DEFERRABLE)

**Referenciada por:** `tiempo.patron_semanal`.`jornada_asignada_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `jornada_asignada_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'))` |
| `jornada_asignada_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'))` |
| `jornada_asignada_select_requiere_permiso` | SELECT | public | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('jornada_asignada_lectura') OR personas.fn_caller_tiene_permiso('jornada_asignada_edicion')))` |
| `jornada_asignada_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'))` |

---

### `tiempo.patron_semanal`

> Qué días, con qué horario y con qué pausa de comida. Admite jornada partida vía varias filas del mismo día_semana con distinto horario si hace falta (no restringido a una fila por día).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `jornada_asignada_id` | `bigint` | No | — | FK → tiempo.jornada_asignada | — (sin `COMMENT ON` en el DDL) |
| `dia_semana` | `character varying(10)` | No | — | `lunes` / `martes` / `miercoles` / `jueves` / `viernes` / `sabado` / `domingo` | — (sin `COMMENT ON` en el DDL) |
| `hora_entrada` | `time without time zone` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `hora_salida` | `time without time zone` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `minutos_comida` | `integer` | No | `0` | — | — (sin `COMMENT ON` en el DDL) |
| `horas_efectivas` | `numeric(5,2)` | Sí | — | — | Derivado: (hora_salida - hora_entrada) - minutos_comida. No es fuente de verdad. |

**Claves:**

- PK `id`
- FK `patron_semanal_jornada_asignada_id_fkey` (`jornada_asignada_id`) → `tiempo.jornada_asignada(id)`

**Índices** (sin contar PK): 

- `ix_patron_semanal_jornada_asignada_id`: `(jornada_asignada_id)`

**Restricciones CHECK de varias columnas:** 
- `ck_patron_semanal_horario`: `hora_salida > hora_entrada`

**Triggers:** 
- `trg_patron_semanal_solo_jornada_futura`: BEFORE DELETE OR UPDATE → `tiempo.fn_patron_semanal_solo_jornada_futura()`
- `trg_patron_semanal_valida_tope_legal`: AFTER INSERT OR UPDATE → `tiempo.fn_patron_semanal_valida_tope_legal()` (CONSTRAINT TRIGGER, DEFERRABLE)

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `patron_semanal_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'))` |
| `patron_semanal_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'))` |
| `patron_semanal_select_requiere_permiso` | SELECT | public | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('patron_semanal_lectura') OR personas.fn_caller_tiene_permiso('patron_semanal_edicion')))` |
| `patron_semanal_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'))` |

---

### `tiempo.marca`

> Evento crudo producido por el terminal o por captura manual. Inmutable — ningún flujo de la aplicación emite UPDATE ni DELETE sobre esta tabla, sólo INSERT. Cualquier corrección pasa por tiempo.correccion (SCJ-DEC-03). Nunca guarda huella ni plantilla biométrica — sólo el identificador ya resuelto a persona_id. Nombres y campos cerrados por SCJ-CDT-01 §IV/§V, sin excepción.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `evento_id` | `uuid` | No | `gen_random_uuid()` | — | Llave de negocio para idempotencia global de reintentos de envío. Nace en el origen (terminal o al abrir el formulario de captura manual), nunca en el servidor. No es la PK física, por decisión confirmada — ver SCJ-DEC-08, Opción B. |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `character varying(32)` | No | — | — | Identifica el aparato o, en captura manual, el punto de captura (SCJ-ESP-01 §VII.1). No es un FK físico — el módulo de Equipos aún no existe (mismo patrón que tiempo.persona). |
| `secuencia_local` | `bigint` | Sí | — | — | Contador del terminal, nulo salvo origen = terminal. Sirve para detectar huecos: si llegan 1, 2 y 4, se perdió la 3. Ver SCJ-DEC-09. |
| `momento_dispositivo` | `timestamp with time zone` | No | — | — | Instante real del evento según el reloj del origen (terminal o, desde la hora editable de captura manual, el instante que declara quien captura). Campo autoritativo para el cálculo de jornada -- SCJ-CDT-01 §VII.3 fija que el orden de los eventos lo determina éste, no el de llegada. En captura_manual el backend valida que no sea futuro y que caiga dentro de la ventana de días hábiles de tiempo.parametro.dias_habiles_correccion_marca; esta tabla añade sólo un techo duro (90 días, no futuro) como respaldo ante un INSERT directo por PostgREST que se salte esa validación. |
| `desfase_local` | `character varying(6)` | No | — | `(desfase_local) ~ '^[+-][0-9]{2}:[0-9]{2}$'` | Desfase respecto de UTC vigente en el instante de momento_dispositivo, formato ±HH:MM. Junto con momento_dispositivo permite reconstruir la hora local sin almacenarla — SCJ-ESP-01 §VII.3. |
| `momento_recepcion` | `timestamp with time zone` | No | `now()` | — | Cuándo llegó al servidor. Nunca se usa para calcular jornada — sólo mide retraso de sincronización (SCJ-CDT-01 §VII.3). |
| `estado_reloj` | `character varying(20)` | No | — | `sincronizado` / `deriva` / `sin_sincronizar` | Estado del reloj del origen en el momento exacto de esta marca, reportado por el propio dispositivo -- no se deriva aquí. Captura retroactiva (momento_dispositivo distinto de ahora) no es deriva de reloj: el reloj del origen está bien, sólo el evento es viejo -- estado_reloj sigue sincronizado en captura_manual. |
| `version_software` | `character varying(16)` | No | — | — | Versión del software que generó el evento — del firmware del terminal, o de la aplicación web en captura_manual. |
| `origen` | `character varying(20)` | No | — | `terminal` / `captura_manual` | terminal: identificación biométrica en el aparato. captura_manual: formulario asistido por usuario aprobado (SCJ-ESP-01 §IV.2) — vía ordinaria y permanente, no una excepción; no existe un tercer valor. |
| `requiere_revision` | `boolean` | No | `false` | — | Bandera rápida, calculada como estado_reloj <> 'sincronizado' salvo que un proceso posterior la levante por otra razón. El detalle y el ciclo de vida de la revisión viven en tiempo.excepcion (SCJ-DEC-07). |

**Claves:**

- PK `id`
- UK `uq_marca_evento_id` (`evento_id`)
- FK `marca_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK): 

- `ix_marca_momento_recepcion`: `(momento_recepcion DESC)`
- `ix_marca_persona_id`: `(persona_id)`
- `uq_marca_evento_id` (UNIQUE): `(evento_id)`
- `uq_marca_terminal_secuencia` (UNIQUE): `(terminal_id, secuencia_local) WHERE ((origen)::text = 'terminal'::text)`

**Restricciones CHECK de varias columnas:** 
- `ck_marca_secuencia_solo_terminal`: `((origen) = 'terminal') = (secuencia_local IS NOT NULL)`

**Triggers:** 
- `trg_marca_valida_revision`: AFTER INSERT → `tiempo.fn_marca_valida_revision()`

**Referenciada por:** `tiempo.correccion`.`marca_id`, `tiempo.excepcion`.`marca_id`, `tiempo.tramo`.`marca_apertura_id`, `tiempo.tramo`.`marca_cierre_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:IS terminal_checador:I

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `marca_insert_captura_manual` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('captura_manual_edicion') AND ((origen) = 'captura_manual') AND (momento_dispositivo <= now()) AND (momento_dispositivo >= (now() - '90 days'::interval)) AND ((estado_reloj) = 'sincroni…` |
| `marca_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('marca_lectura') OR personas.fn_caller_tiene_permiso('captura_manual_edicion')))` |
| `terminal_inserta_su_origen` | INSERT | terminal_checador | `CHECK ((origen) = 'terminal')` |

---

### `tiempo.dia`

> Marcas de una persona en una fecha, con estado. Entidad materializada, no vista — el bloqueo es una decisión que sobrevive a marcas tardías (SCJ-DEC-06). bloqueado pasa a revisado cuando RH lo revisa; nunca vuelve a cerrado automáticamente.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `fecha` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `estado` | `character varying(20)` | No | `'abierto'::character varying` | `abierto` / `cerrado` / `bloqueado` / `revisado` | — (sin `COMMENT ON` en el DDL) |
| `horas_totales` | `numeric(5,2)` | Sí | — | — | Derivado de la suma de tramo.minutos_trabajados del día. No es fuente de verdad. |
| `origen` | `character varying(20)` | Sí | — | `automatico_confianza` / `ausencia_autorizada` (o NULL) | NULL para jornada normal/flexible cuando el día nace de marcas reales. automatico_confianza para jornada de_confianza, que no pasa por terminal — un proceso por lotes crea el día directo, sin marca ni tramo sintéticos (contaminarían marca como evidencia de jornada). ausencia_autorizada cuando el batch de cierre resuelve el día contra una ausencia en vez de marcas (SCJ-PRO-12) — corregido 2026-09-05: el CHECK traía "terminal" por error, un valor que nunca se usó (el caso de marcas reales siempre fue NULL, no "terminal"). |
| `revisado_por` | `uuid` | Sí | — | FK → tiempo.persona | Persona (vía frontera SCJ-FRO-01, tiempo.persona) que hizo clic en "Marcar como revisado". NULL mientras el día no pasó por bloqueado -> revisado. Atado al propio caller por el WITH CHECK de dia_update_revision -- nadie puede atribuirle la revisión a otra persona. |
| `revisado_en` | `timestamp with time zone` | Sí | — | — | Momento de la revisión humana (SCJ-DEC-06: "demostrar la intervención explícita de RH"). NULL mientras el día no pasó por bloqueado -> revisado. No puede ser futuro (dia_update_revision). |

**Claves:**

- PK `id`
- UK `uq_dia_persona_fecha` (`persona_id`, `fecha`)
- FK `dia_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`
- FK `dia_revisado_por_fkey` (`revisado_por`) → `tiempo.persona(id)`

**Índices** (sin contar PK): 

- `ix_dia_revisado_por`: `(revisado_por)`
- `uq_dia_persona_fecha` (UNIQUE): `(persona_id, fecha)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `tiempo.excepcion`.`dia_id`, `tiempo.tramo`.`dia_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `dia_select_requiere_permiso` | SELECT | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_lectura'))` |
| `dia_update_revision` | UPDATE | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion') AND ((estado) = ANY ((ARRAY['bloqueado', 'cerrado'])))) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion') AND ((e…` |

---

### `tiempo.tramo`

> Par de marcas: la impar abre, la par cierra. marca_cierre_id nulo es un tramo abierto (día con número impar de marcas) — no es un error de restricción, es un dato que el proceso de cierre usa para decidir el estado de tiempo.dia. Ver SCJ-ESP-01 §VI.1 y SCJ-DEC-01.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `dia_id` | `bigint` | No | — | FK → tiempo.dia | — (sin `COMMENT ON` en el DDL) |
| `marca_apertura_id` | `bigint` | No | — | FK → tiempo.marca | — (sin `COMMENT ON` en el DDL) |
| `marca_cierre_id` | `bigint` | Sí | — | FK → tiempo.marca | — (sin `COMMENT ON` en el DDL) |
| `inicio` | `timestamp with time zone` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `fin` | `timestamp with time zone` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `minutos_trabajados` | `numeric(6,2)` | Sí | — | — | Derivado de fin - inicio. Nulo mientras el tramo esté abierto. No es fuente de verdad. |

**Claves:**

- PK `id`
- UK `uq_tramo_marca_apertura` (`marca_apertura_id`)
- UK `uq_tramo_marca_cierre` (`marca_cierre_id`)
- FK `tramo_dia_id_fkey` (`dia_id`) → `tiempo.dia(id)`
- FK `tramo_marca_apertura_id_fkey` (`marca_apertura_id`) → `tiempo.marca(id)`
- FK `tramo_marca_cierre_id_fkey` (`marca_cierre_id`) → `tiempo.marca(id)`

**Índices** (sin contar PK): 

- `ix_tramo_dia_id`: `(dia_id)`
- `uq_tramo_marca_apertura` (UNIQUE): `(marca_apertura_id)`
- `uq_tramo_marca_cierre` (UNIQUE): `(marca_cierre_id)`

**Restricciones CHECK de varias columnas:** 
- `ck_tramo_fin_posterior_a_inicio`: `(fin IS NULL) OR (fin > inicio)`

**Triggers:**
- `trg_tramo_valida_coherencia`: BEFORE INSERT OR UPDATE, por fila → `tiempo.fn_tramo_valida_coherencia()` *(86_)* — las marcas de apertura y cierre deben ser de la persona del día y con fecha local efectiva igual a la del día (en UPDATE sólo si cambian `dia_id` o las marcas); `SCJ15` / `tramo_incoherente`

**Referenciada por:** `tiempo.clasificacion_de_tiempo`.`tramo_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `tramo_insert_revision` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion') AND (marca_cierre_id IS NOT NULL) AND (fin IS NOT NULL) AND (fin > inicio))` |
| `tramo_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('tramo_lectura'))` |
| `tramo_update_revision` | UPDATE | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion') AND (marca_cierre_id IS NULL)) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion') AND (marca_cierre_id IS NOT NULL…` |

---

### `tiempo.clasificacion_de_tiempo`

> Ordinario, reposición o extra, sobre un tramo — cronológica y acumulada dentro del periodo quincenal, nunca por día ni por proporción; el mismo tramo nunca se parte entre dos clasificaciones. tipo lo calcula el batch de corte quincenal (SCJ-PRO-13), no un trigger de esta base: recorre los tramos del periodo en orden acumulando contra horas_esperadas (patron_semanal vigente, excluye domingo/festivo/bloqueado) — ordinario mientras no rebase lo esperado, reposición mientras haya deuda previa en banco_de_horas, extra una vez agotada esa deuda. No compara contra tope_legal — ese valor sólo topa la jornada al asignarla (trg_patron_semanal_valida_tope_legal), no participa en esta clasificación.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `tramo_id` | `bigint` | No | — | FK → tiempo.tramo | — (sin `COMMENT ON` en el DDL) |
| `tipo` | `character varying(20)` | Sí | — | `ordinario` / `reposicion` / `extra` (o NULL) | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_clasificacion_de_tiempo_tramo` (`tramo_id`)
- FK `clasificacion_de_tiempo_tramo_id_fkey` (`tramo_id`) → `tiempo.tramo(id)`

**Índices** (sin contar PK): 

- `uq_clasificacion_de_tiempo_tramo` (UNIQUE): `(tramo_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `tiempo.movimiento_de_saldo`.`clasificacion_de_tiempo_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `clasificacion_de_tiempo_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('clasificacion_de_tiempo_lectura'))` |

---

### `tiempo.banco_de_horas`

> Deuda de horas acumulada de una persona. monto y vivo_desde nunca se escriben con UPDATE directo — sólo el disparador que reacciona a tiempo.movimiento_de_saldo los recalcula. Ver SCJ-DEC-02.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `monto` | `numeric(8,2)` | No | `0` | — | — (sin `COMMENT ON` en el DDL) |
| `vivo_desde` | `timestamp with time zone` | Sí | — | — | Fecha del movimiento que llevó monto de 0 a positivo por última vez. NULL cuando monto = 0. Permite evaluar los umbrales de SCJ-ESP-01 §VI.6 (aviso al 100%, escalamiento al 200%, cuarto mes con saldo vivo) sin recorrer el histórico de movimientos en cada consulta. |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_banco_de_horas_persona` (`persona_id`)
- FK `banco_de_horas_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK): 

- `uq_banco_de_horas_persona` (UNIQUE): `(persona_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `tiempo.movimiento_de_saldo`.`banco_de_horas_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `banco_de_horas_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('banco_de_horas_lectura'))` |

---

### `tiempo.movimiento_de_saldo`

> Libro de movimientos del banco de horas — única fuente de verdad, banco_de_horas.monto es caché derivado. Ver SCJ-DEC-02.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `banco_de_horas_id` | `bigint` | No | — | FK → tiempo.banco_de_horas | — (sin `COMMENT ON` en el DDL) |
| `clasificacion_de_tiempo_id` | `bigint` | Sí | — | FK → tiempo.clasificacion_de_tiempo | — (sin `COMMENT ON` en el DDL) |
| `tipo` | `character varying(20)` | No | — | `generado_quincena` / `cubrir` / `arrastrar` / `descontar` / `condonar` | generado_quincena: +monto, automático al corte quincenal, sólo si horas_esperadas > horas_trabajadas (nunca genera saldo a favor). cubrir: -monto, automático desde una clasificacion_de_tiempo tipo reposicion. arrastrar: 0, pasa el saldo vivo al siguiente bloque semestral, manual RH. descontar/condonar: -monto, cancelan a cero, manual Dirección + RH. |
| `monto` | `numeric(8,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `motivo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `autor_id` | `uuid` | Sí | — | FK → tiempo.persona | NULL cuando el movimiento lo genera el sistema (generado_quincena, cubrir automático desde reposición). No nulo para arrastrar/descontar/condonar, siempre decisión humana. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `movimiento_de_saldo_autor_id_fkey` (`autor_id`) → `tiempo.persona(id)`
- FK `movimiento_de_saldo_banco_de_horas_id_fkey` (`banco_de_horas_id`) → `tiempo.banco_de_horas(id)`
- FK `movimiento_de_saldo_clasificacion_de_tiempo_id_fkey` (`clasificacion_de_tiempo_id`) → `tiempo.clasificacion_de_tiempo(id)`

**Índices** (sin contar PK): 

- `ix_movimiento_de_saldo_autor_id`: `(autor_id)`
- `ix_movimiento_de_saldo_banco_de_horas_id`: `(banco_de_horas_id)`
- `ix_movimiento_de_saldo_clasificacion_de_tiempo_id`: `(clasificacion_de_tiempo_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_movimiento_de_saldo_actualiza_banco`: AFTER INSERT → `tiempo.fn_movimiento_de_saldo_actualiza_banco()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `movimiento_de_saldo_insert_manual` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion') AND ((tipo) = ANY ((ARRAY['arrastrar', 'descontar', 'condonar']))) AND (autor_id = ( SELECT u.persona_id FROM personas.usuario u WHERE (u.auth_user_id = a…` |
| `movimiento_de_saldo_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('movimiento_de_saldo_lectura') OR personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion')))` |

---

### `tiempo.correccion`

> Registro nuevo que apunta a una marca anterior — nunca se sobrescribe momento_dispositivo. Ver SCJ-DEC-03. Siempre lleva autor: una corrección es, por definición, una decisión humana tras revisar una excepción.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `marca_id` | `bigint` | No | — | FK → tiempo.marca | — (sin `COMMENT ON` en el DDL) |
| `valor_corregido` | `timestamp with time zone` | No | — | — | Asume que sólo se corrige momento_dispositivo (encaja con el caso de uso real: reloj no sincronizado detectado, RH corrige la hora tras revisar). persona_id no se corrige aquí — el identificador biométrico ya resuelto es dato único y confiable, no un valor a ajustar. |
| `motivo` | `text` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `autor_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `correccion_autor_id_fkey` (`autor_id`) → `tiempo.persona(id)`
- FK `correccion_marca_id_fkey` (`marca_id`) → `tiempo.marca(id)`

**Índices** (sin contar PK): 

- `ix_correccion_autor_id`: `(autor_id)`
- `ix_correccion_marca_id`: `(marca_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_correccion_recalcula_tramo`: AFTER INSERT → `tiempo.fn_correccion_recalcula_tramo()`
- `trg_correccion_valida`: BEFORE INSERT → `tiempo.fn_correccion_valida()`
- `trg_correccion_bloquea_marca_en_tramo`: BEFORE INSERT, por fila → `tiempo.fn_correccion_bloquea_marca_en_tramo()` *(87_)* — corre antes que `trg_correccion_valida`; `SCJ15` / `marca_en_tramo` si la marca es apertura o cierre de algún tramo

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `correccion_insert_requiere_permiso` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('correccion_edicion') AND ((NOT (EXISTS ( SELECT 1 FROM tiempo.excepcion e WHERE ((e.marca_id = e.marca_id) AND ((e.estado) = 'resuelto'))))) OR personas.fn_caller_tiene_permiso('excepc…` |
| `correccion_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('correccion_lectura') OR personas.fn_caller_tiene_permiso('correccion_edicion')))` |

---

### `tiempo.ausencia`

> Periodo no trabajado, con naturaleza y autorización. tipo_de_ausencia usa el enumerado ya documentado en SCJ-DIC-01 §III.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `tipo_de_ausencia` | `character varying(30)` | No | — | `vacaciones` / `permiso_con_goce` / `permiso_sin_goce` / `incapacidad` / `falta` | — (sin `COMMENT ON` en el DDL) |
| `fecha_inicio` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `fecha_fin` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `estado_autorizacion` | `character varying(20)` | No | `'pendiente'::character varying` | `pendiente` / `autorizada` / `rechazada` | Materializado de sólo lectura — resumen de tiempo.aprobacion_ausencia, escrito únicamente por trigger (mismo patrón que tiempo.banco_de_horas, SCJ-DEC-02). Fuente de verdad real: la cadena de pasos en aprobacion_ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), Opción C. |
| `documento_ref` | `character varying(50)` | Sí | — | — | Evidencia cargada y conservada — SCJ-ESP-01 exige que una falta justificada la tenga antes de pagarse. NULL admitido: vacaciones/incapacidad pueden no requerir documento propio si ya consta en otro expediente. |

**Claves:**

- PK `id`
- FK `ausencia_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK): 

- `ix_ausencia_persona_id`: `(persona_id)`
- `uq_ausencia_falta_persona_fecha` (UNIQUE): `(persona_id, fecha_inicio, fecha_fin) WHERE ((tipo_de_ausencia)::text = 'falta'::text)`

**Restricciones CHECK de varias columnas:** 
- `ck_ausencia_fechas`: `fecha_fin >= fecha_inicio`

**Triggers:** 
- `trg_ausencia_resuelve_excepcion`: AFTER INSERT OR UPDATE OF estado_autorizacion → `tiempo.fn_ausencia_resuelve_excepcion()`

**Referenciada por:** `tiempo.aprobacion_ausencia`.`ausencia_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DIS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `ausencia_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('ausencia_lectura') OR personas.fn_caller_tiene_permiso('ausencia_edicion')))` |
| `ausencia_update_requiere_permiso` | UPDATE | authenticated | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'))` |

---

### `tiempo.aprobacion_ausencia`

> Cadena de aprobación de una ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), Opción C. La aplicación resuelve quién aprueba cada paso consultando personas.puesto_permiso/asignacion (permiso atómico de autorización, heredable jerárquicamente) en el momento de crear la ausencia, e inserta una fila pendiente por paso — no hay tabla de "definición de flujo" ni "instancia" en Tiempo, sólo el registro de lo ya resuelto. Un rechazo en cualquier paso detiene la cadena.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `ausencia_id` | `bigint` | No | — | FK → tiempo.ausencia | — (sin `COMMENT ON` en el DDL) |
| `numero_paso` | `smallint` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `aprobador_id` | `uuid` | No | — | FK → tiempo.persona | Persona específica congelada al crear la solicitud, no un rol. Si el permiso cambia de dueño mientras la ausencia sigue pendiente, este renglón no se recalcula (SCJ-DEC-05, misma lógica que SCJ-DEC-04). |
| `decision` | `character varying(20)` | No | `'pendiente'::character varying` | `pendiente` / `autorizada` / `rechazada` | — (sin `COMMENT ON` en el DDL) |
| `motivo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `decidido_en` | `timestamp with time zone` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_aprobacion_ausencia_paso` (`ausencia_id`, `numero_paso`)
- FK `aprobacion_ausencia_aprobador_id_fkey` (`aprobador_id`) → `tiempo.persona(id)`
- FK `aprobacion_ausencia_ausencia_id_fkey` (`ausencia_id`) → `tiempo.ausencia(id)`

**Índices** (sin contar PK): 

- `uq_aprobacion_ausencia_paso` (UNIQUE): `(ausencia_id, numero_paso)`

**Restricciones CHECK de varias columnas:** 
- `ck_aprobacion_ausencia_decidido`: `((decision) = 'pendiente') = (decidido_en IS NULL)`

**Triggers:** 
- `trg_aprobacion_ausencia_actualiza_ausencia`: AFTER INSERT OR UPDATE OF decision → `tiempo.fn_aprobacion_ausencia_actualiza_ausencia()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `aprobacion_ausencia_insert_requiere_permiso` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion'))` |
| `aprobacion_ausencia_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('aprobacion_ausencia_lectura') OR personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion')))` |

---

### `tiempo.excepcion`

> Marca o día apartado para revisión humana — nunca ambos, nunca ninguno (ck_excepcion_marca_o_dia). Ver SCJ-DEC-07. Casos: reloj no sincronizado (marca_id), día sin checada y sin ausencia que lo justifique (dia_id), jornada ordinaria en domingo/festivo sin autorización previa (dia_id).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `marca_id` | `bigint` | Sí | — | FK → tiempo.marca | — (sin `COMMENT ON` en el DDL) |
| `dia_id` | `bigint` | Sí | — | FK → tiempo.dia | — (sin `COMMENT ON` en el DDL) |
| `motivo_revision` | `text` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `estado` | `character varying(20)` | No | `'pendiente'::character varying` | `pendiente` / `resuelto` | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `excepcion_dia_id_fkey` (`dia_id`) → `tiempo.dia(id)`
- FK `excepcion_marca_id_fkey` (`marca_id`) → `tiempo.marca(id)`

**Índices** (sin contar PK): 

- `ix_excepcion_dia_id`: `(dia_id)`
- `ix_excepcion_marca_id`: `(marca_id)`

**Restricciones CHECK de varias columnas:** 
- `ck_excepcion_marca_o_dia`: `(marca_id IS NOT NULL) <> (dia_id IS NOT NULL)`

**Triggers:** 
- `trg_excepcion_protege_columnas`: BEFORE UPDATE, por fila → `tiempo.fn_excepcion_protege_columnas()` *(86_)* — `marca_id`, `dia_id` y `creado_en` inmutables; `motivo_revision` sólo cambia al resolver y sólo agregando un sufijo ` — …` al motivo anterior (`SCJ15`: `excepcion_columna_inmutable` | `excepcion_motivo_inmutable`)
- `trg_excepcion_protege_dia_cerrado`: AFTER UPDATE → `tiempo.fn_excepcion_protege_dia_cerrado()` (CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED, `WHEN (OLD.motivo_revision LIKE 'dia\_cerrado%' AND pendiente → resuelto)`) — *(86_ reemplaza al de `78_`)* sólo acepta la resolución si el día de la marca se revisó en la MISMA transacción (con un tramo que contiene la marca, de la misma persona y fecha local efectiva) o si hay un descarte de esa excepción creado en esa transacción; si no, `SCJ15` / `dia_cerrado_requiere_revision` al `COMMIT`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `excepcion_select_requiere_permiso` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('excepcion_lectura') OR personas.fn_caller_tiene_permiso('excepcion_edicion')))` |
| `excepcion_update_requiere_permiso` | UPDATE | authenticated | `USING (personas.fn_caller_activo() AND ((((estado) = 'pendiente') AND personas.fn_caller_tiene_permiso('excepcion_edicion')) OR (((estado) = 'resuelto') AND personas.fn_caller_tiene_permiso('excepcion_reapertura')))) ; CHECK (personas.fn_caller_activo() AND…` |

---

### `tiempo.corrida_batch`

> Estado visible de cada corrida de batch — de dónde lee la app "última corrida: exitosa/fallida, N pendientes" (SCJ-PRO-12). El job automático y el botón manual son la misma invocación; reintentar es re-ejecutar el batch (idempotente por persona) e incrementar 'intentos' en la misma fila via UPSERT sobre (tipo_batch, fecha).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `tipo_batch` | `character varying(20)` | No | — | `cierre_dia` / `corte_quincenal` / `de_confianza` | — (sin `COMMENT ON` en el DDL) |
| `fecha` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `estado` | `character varying(20)` | No | `'en_progreso'::character varying` | `en_progreso` / `exitosa` / `fallida` | — (sin `COMMENT ON` en el DDL) |
| `intentos` | `smallint` | No | `1` | — | — (sin `COMMENT ON` en el DDL) |
| `iniciado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `terminado_en` | `timestamp with time zone` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `detalle` | `text` | Sí | — | — | Resumen legible del resultado — ej. qué personas quedaron pendientes tras 3 intentos. No reemplaza logs, es para que RH/Dirección vea el estado sin entrar a Supabase. |

**Claves:**

- PK `id`
- UK `uq_corrida_batch_tipo_fecha` (`tipo_batch`, `fecha`)

**Índices** (sin contar PK): 

- `uq_corrida_batch_tipo_fecha` (UNIQUE): `(tipo_batch, fecha)`

**Restricciones CHECK de varias columnas:** 
- `ck_corrida_batch_terminado`: `((estado) = 'en_progreso') = (terminado_en IS NULL)`

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `corrida_batch_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |

---

### `tiempo.terminal`

> Terminal biométrica física (SCJ-DEC-11). Una fila por aparato. La escribe sólo service_role (alta puntual y ultimo_contacto_en); sin DELETE para nadie, una terminal fuera de servicio se marca activa=false.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `character varying(32)` | No | — | — | Serie del aparato; MISMO valor que tiempo.marca.terminal_id cuando la marca viene de esta terminal. Sin FK desde marca (esa columna también guarda puntos de captura manual). |
| `nombre` | `character varying(100)` | No | — | — | Nombre legible para la UI (ej. "Entrada principal"). |
| `modelo` | `character varying(50)` | Sí | — | — | Modelo del aparato (ej. DS-K1A8503EF-B). Opcional. |
| `activa` | `boolean` | No | `true` | — | false = fuera de servicio. No se borra nunca. |
| `ultimo_contacto_en` | `timestamp with time zone` | Sí | — | — | Última vez que el Pi (puente) llamó al backend para esta terminal. Lo actualiza el backend con service_role; NULL si nunca ha contactado. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `reloj_desfase_seg` | `integer` | Sí | — | — | Segundos que adelanta (+) o atrasa (-) el reloj de la terminal respecto del servidor, calculado por fn_terminal_latido con la hora que reporta el Pi. NULL = nunca reportado. |
| `terminal_alcanzable` | `boolean` | Sí | — | — | true si el Pi ve a la terminal (ISAPI responde); false = el Pi habla pero no ve el aparato. NULL = nunca reportado. |
| `version_pi` | `character varying(16)` | Sí | — | — | Versión del software del puente que reportó el último latido (máx. 16 caracteres). |
| `marcas_pendientes` | `integer` | Sí | — | `>= 0` (`ck_terminal_marcas_pendientes`) | Marcas que el Pi tiene en cola sin sincronizar (último latido). Condición del procedimiento de desactivación de una terminal (SCJ-DEC-12 §6): debe ser 0 antes de apagarla. |

**Claves:**

- PK `id`
- UK `uq_terminal_terminal_id` (`terminal_id`)

**Índices** (sin contar PK):

- `uq_terminal_terminal_id` (UNIQUE): `(terminal_id)`

**Restricciones CHECK de varias columnas:** — (`ck_terminal_marcas_pendientes` es de una sola columna y está en su fila)

**Triggers:**

- `trg_terminal_valida_desactivacion` — `BEFORE UPDATE OF activa`, por fila, `WHEN (OLD.activa AND NOT NEW.activa)`, `SECURITY DEFINER`: no se puede desactivar una terminal con altas no-`baja` (`SCJ13`, hint `terminal_con_altas_vigentes`); toma la fila de la terminal `FOR UPDATE` antes de contar, y `asignado` la toma `FOR SHARE`.

**Referenciada por:** `tiempo.terminal_usuario.terminal_id`, `tiempo.bitacora_movimiento_terminal_usuario.terminal_id`, `tiempo.terminal_credencial.terminal_id`, `tiempo.marca_rechazada.terminal_id`

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:S service_role:IS, más `UPDATE` sólo de las columnas `ultimo_contacto_en`, `activa`, `nombre` y `modelo` (contrastado con `has_column_privilege` en la base real; las 4 columnas de estado de `82_` quedan fuera: las escribe sólo `fn_terminal_latido`) (nunca `id`, `terminal_id` ni `creado_en`); nadie tiene `DELETE`. Creada en `80_tiempo_terminal_usuario.sql`.

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura') OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')))` |

---

### `tiempo.terminal_usuario`

> [CALCULADO] Persona enrolada en una terminal y estado de su enrolamiento (SCJ-DEC-11). La deriva sólo trg_bitacora_terminal_usuario_aplica (81_*.sql) desde bitacora_movimiento_terminal_usuario; ningún rol de la API tiene INSERT/UPDATE/DELETE.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | FK a tiempo.terminal(id) (surrogate, no la serie). |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | Persona vía frontera SCJ-FRO-01 (tiempo.persona). Ningún dato de identidad vive acá. |
| `employee_no` | `integer` | No | — | entre 1 y 99999999 (`ck_terminal_usuario_employee_no`) | employeeNo en la terminal. Sale de seq_terminal_employee_no, entre 1 y 99999999, nunca se reutiliza. Único por terminal. |
| `estado` | `character varying(20)` | No | — | `pendiente_alta` / `esperando_huella` / `activo` / `pendiente_baja` / `baja` | pendiente_alta (asignado en el servidor, falta crearlo en el aparato) -> esperando_huella (usuario creado, sin huella) -> activo (>=1 huella) -> pendiente_baja -> baja. Transiciones validadas por el trigger de 81_*.sql. |
| `huellas_capturadas` | `smallint` | No | `0` | entre 0 y 10 (`ck_terminal_usuario_huellas`) | Huellas registradas en el aparato (0-10, tope del DS-K1A8503EF-B). Lo fija huella_capturada. |
| `error_detalle` | `text` | Sí | — | máx. 500 caracteres (`ck_terminal_usuario_error_detalle_len`) | Último error reportado por el Pi. Se limpia con el siguiente movimiento válido distinto de error. Sin datos sensibles. |
| `consentimiento_id` | `bigint` | No | — | FK → tiempo.terminal_consentimiento *(88_)* | [CALCULADO] Versión del texto de consentimiento aceptada más reciente de esta alta (la fija el trigger en 'asignado' y en 'reconsentido'). Reconsentimiento pendiente = alta en pendiente_alta, esperando_huella o activo con una versión menor que la última con cambio_material. |
| `usuario_creado_en` | `timestamp with time zone` | Sí | — | — | [CALCULADO] *(88_)* Momento del movimiento 'usuario_creado' (el Pi creó el usuario en el aparato); NULL mientras sigue en pendiente_alta. Sólo la fija el trigger. Plazo de la caducidad de altas sin huella y de la anomalía de altas atascadas. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | Lo fija el trigger en cada movimiento. |

**Claves:**

- PK `id`
- UK `uq_terminal_usuario_employee_no` (`terminal_id`, `employee_no`)
- FK `terminal_usuario_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`
- FK `terminal_usuario_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`
- FK `terminal_usuario_consentimiento_id_fkey` (`consentimiento_id`) → `tiempo.terminal_consentimiento(id)` *(88_)*

**Índices** (sin contar PK):

- `uq_terminal_usuario_employee_no` (UNIQUE): `(terminal_id, employee_no)`
- `uq_terminal_usuario_persona_vigente` (UNIQUE parcial, `WHERE estado <> 'baja'`): `(terminal_id, persona_id)` — una persona sólo puede tener un alta vigente por terminal
- `ix_terminal_usuario_persona_id`: `(persona_id)`
- `ix_terminal_usuario_consentimiento_id`: `(consentimiento_id)` *(88_)*

**Restricciones CHECK de varias columnas:** —

**Triggers:** ninguno propio; la escribe `trg_bitacora_terminal_usuario_aplica` (sobre la bitácora, `SECURITY DEFINER`).

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario.terminal_usuario_id`

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:S service_role:S. Ningún rol de la API escribe: el único escritor es el trigger de la bitácora. Creada en `80_tiempo_terminal_usuario.sql`.

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_usuario_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura') OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')))` |

---

### `tiempo.bitacora_movimiento_terminal_usuario`

> Fuente de verdad de tiempo.terminal_usuario (SCJ-DEC-11). Sólo inserción: inmutable en 3 capas, ver cabecera. trg_bitacora_terminal_usuario_aplica valida la transición y sincroniza la tabla viva en el mismo INSERT.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_usuario_id` | `bigint` | No | — | FK → tiempo.terminal_usuario | Fila viva afectada. En 'asignado' debe llegar NULL: el trigger crea la fila viva y lo completa. En el resto es obligatorio. |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | Terminal (tiempo.terminal.id). El trigger exige que coincida con la fila viva. |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | Persona afectada. El trigger exige que coincida con la fila viva. |
| `employee_no` | `integer` | No | — | — | employeeNo en la terminal. En 'asignado' debe llegar NULL y lo asigna el trigger desde seq_terminal_employee_no; en el resto puede llegar NULL (se completa) o igual al de la fila viva. |
| `tipo_movimiento` | `character varying(20)` | No | — | `asignado` / `usuario_creado` / `huella_capturada` / `baja_solicitada` / `baja_confirmada` / `error` / `reconsentido` *(88_)* | asignado \| usuario_creado \| huella_capturada \| baja_solicitada \| baja_confirmada \| error \| reconsentido. 'reconsentido' (88_, origen web) registra que la persona aceptó la versión vigente del texto: no cambia estado ni huellas y conserva error_detalle. Tabla de transiciones en fn_bitacora_terminal_usuario_aplica. |
| `huellas_capturadas` | `smallint` | Sí | — | obligatorio entre 1 y 10 en `huella_capturada`, NULL en el resto | Total de huellas del usuario tras este movimiento (1-10). Sólo en huella_capturada. |
| `detalle` | `text` | Sí | — | obligatorio en `error`; máx. 500 caracteres | Motivo o mensaje de error (obligatorio en 'error'), máx. 500 caracteres. El backend sanea y trunca; nunca cuerpos crudos de ISAPI ni headers. |
| `origen` | `character varying(10)` | No | — | `web` / `terminal` | web (RH desde la app) o terminal (reporte del Pi vía backend, service_role). |
| `registrado_por` | `uuid` | Sí | — | FK → personas.usuario(auth_user_id) | auth_user_id de quien hizo el movimiento web; NULL cuando origen='terminal'. |
| `consentimiento_id` | `bigint` | Sí | — | FK → tiempo.terminal_consentimiento *(88_)*; obligatorio en `asignado` y `reconsentido`, NULL en el resto | Versión del texto de consentimiento que se aceptó. Debe ser la versión vigente al insertar (SCJ16 si no). |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `bitacora_movimiento_terminal_usuario_terminal_usuario_id_fkey` (`terminal_usuario_id`) → `tiempo.terminal_usuario(id)`
- FK `bitacora_movimiento_terminal_usuario_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`
- FK `bitacora_movimiento_terminal_usuario_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`
- FK `bitacora_movimiento_terminal_usuario_registrado_por_fkey` (`registrado_por`) → `personas.usuario(auth_user_id)`
- FK `bitacora_movimiento_terminal_usuario_consentimiento_id_fkey` (`consentimiento_id`) → `tiempo.terminal_consentimiento(id)` *(88_)*

**Índices** (sin contar PK):

- `ix_bitacora_terminal_usuario_terminal_usuario_id`: `(terminal_usuario_id)`
- `ix_bitacora_terminal_usuario_terminal_id`: `(terminal_id)`
- `ix_bitacora_terminal_usuario_persona_id`: `(persona_id)`
- `ix_bitacora_terminal_usuario_registrado_por`: `(registrado_por)`
- `ix_bitacora_terminal_usuario_consentimiento_id`: `(consentimiento_id)` *(88_)*

**Restricciones CHECK de varias columnas:**
- `ck_bitacora_terminal_usuario_origen_tipo`: `(origen = 'web') = (tipo_movimiento IN ('asignado','baja_solicitada','reconsentido'))` *(88_ agrega 'reconsentido')*
- `ck_bitacora_terminal_usuario_consentimiento` *(88_)*: `(tipo_movimiento IN ('asignado','reconsentido')) = (consentimiento_id IS NOT NULL)`
- `ck_bitacora_terminal_usuario_autor`: `(registrado_por IS NOT NULL) = (origen = 'web')`
- `ck_bitacora_terminal_usuario_huellas`: conteo obligatorio de 1 a 10 si `tipo_movimiento = 'huella_capturada'`, NULL en cualquier otro caso
- `ck_bitacora_terminal_usuario_error_detalle`: `tipo_movimiento <> 'error' OR detalle IS NOT NULL`
- `ck_bitacora_terminal_usuario_detalle_len`: `detalle IS NULL OR char_length(detalle) <= 500`

**Triggers:**

- `trg_bitacora_terminal_usuario_aplica` — `BEFORE INSERT`, por fila, `SECURITY DEFINER`: valida la transición y sincroniza `tiempo.terminal_usuario` (la crea en `asignado`, la actualiza en el resto). `SCJ11`/`SCJ12`; *(88_)* `SCJ16` si falta la versión del consentimiento o ya no es la vigente (`asignado` y `reconsentido`); `SCJ12` / `auto_asignacion_prohibida` si alguien se asigna a sí mismo sin ser el administrador genérico. Un llamador de la API sin `terminal_usuario_edicion` (o con un movimiento que no es web) no obtiene nada de este trigger: devuelve NEW sin hacer nada y la RLS responde `42501`.
- `trg_bitacora_terminal_usuario_inmutable` — `BEFORE UPDATE OR DELETE`, por fila: aborta, incluido `service_role` y el dueño.
- `trg_bitacora_terminal_usuario_truncate` — `BEFORE TRUNCATE`, por statement: aborta.

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:IS service_role:IS (sin `UPDATE`, `DELETE` ni `TRUNCATE` para nadie). Creada en `81_tiempo_bitacora_movimiento_terminal_usuario.sql`.

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_terminal_usuario_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura') OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')))` |
| `bitacora_terminal_usuario_insert_web` | INSERT | authenticated | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion') AND origen = 'web' AND tipo_movimiento IN ('asignado','baja_solicitada','reconsentido') AND registrado_por = auth.uid())` *(88_ agrega 'reconsentido')* |

Los movimientos con `origen = 'terminal'` sólo los inserta `service_role` (que no pasa por RLS), después de que el backend valida la credencial de la terminal.

---

### `tiempo.terminal_credencial`

> Llave opaca del puente de una terminal (SCJ-DEC-12 §1): formato scjt_ + 43 caracteres URL-safe, guardada sólo como hash SHA-256 hex. Acceso válido si revocada_en IS NULL, expira_en IS NULL o futuro, y tiempo.terminal.activa. Se da de alta sólo por script de TI con service_role (sin endpoint web). Sin DELETE: una llave retirada se revoca.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | FK a tiempo.terminal(id) (surrogate, no la serie). Todo valor de terminal que se escriba lo fija el servidor desde esta fila, nunca el cliente. |
| `hash` | `character(64)` | No | — | `^[0-9a-f]{64}$` (`ck_terminal_credencial_hash`) | SHA-256 hex (64 caracteres en minúscula) de la llave completa. Nunca la llave. UNIQUE: la búsqueda es por igualdad. No se actualiza nunca. |
| `etiqueta` | `character varying(60)` | Sí | — | — | Nombre legible para TI (ej. "llave 2026-10"). Sin datos sensibles. |
| `creada_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `expira_en` | `timestamp with time zone` | Sí | — | — | Opcional. NULL = sin vencimiento (aparato desatendido: un vencimiento automático lo apagaría en silencio). La rotación es manual, recomendada cada 12 meses. |
| `revocada_en` | `timestamp with time zone` | Sí | — | no puede cambiar una vez fijada (trigger `SCJ14`) | Momento de la revocación; NULL = vigente. Una rotación deja ambas llaves vigentes (el traslape) hasta revocar la vieja. |
| `ultimo_uso_en` | `timestamp with time zone` | Sí | — | — | Última petición autenticada con esta llave. Lo escribe sólo fn_terminal_autenticar, con una escritura como máximo cada 30 segundos. |
| `ultima_ip` | `inet` | Sí | — | — | IP de la última petición autenticada. Un cambio respecto de la anterior es una alarma (tablero), no un bloqueo: un Pi con DHCP cambiante da falsos positivos. |
| `ip_cambiada_en` | `timestamp with time zone` | Sí | — | — | Momento del último cambio de IP detectado. |

**Claves:**

- PK `id`
- UK `uq_terminal_credencial_hash` (`hash`)
- FK `terminal_credencial_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`

**Índices** (sin contar PK):

- `uq_terminal_credencial_hash` (UNIQUE): `(hash)`
- `ix_terminal_credencial_terminal_id`: `(terminal_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:**

- `trg_terminal_credencial_revocacion_inmutable` — `BEFORE UPDATE OF revocada_en`, por fila, `WHEN (OLD.revocada_en IS NOT NULL AND NEW.revocada_en IS DISTINCT FROM OLD.revocada_en)`, `SECURITY DEFINER`: una revocación ya fijada no se deshace ni cambia (`SCJ14`, hint `credencial_revocada_inmutable`). Revocar una llave vigente (NULL → valor) sí se permite.

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada **sin ninguna policy**; privilegios de tabla — anon:— authenticated:— service_role:IS, más `UPDATE` sólo de `revocada_en`, `expira_en` y `etiqueta` (contrastado con `has_column_privilege` en la base real). `hash`, `ultimo_uso_en`, `ultima_ip` e `ip_cambiada_en` no son actualizables por la API: los escribe `fn_terminal_autenticar`. Sin `DELETE` ni `TRUNCATE` para nadie. Secuencia identity sin privilegios. Creada en `82_tiempo_terminal_credencial_y_estado.sql`.

---

### `tiempo.marca_rechazada`

> Evidencia de un rechazo DEFINITIVO de fn_marca_terminal_registrar (SCJ-DEC-12 §6): la marca no entró a tiempo.marca. Sin datos de identidad y sin texto libre (tipos acotados). Sin escritura directa para la API (sólo la inserta fn_terminal_rechazo_registrar); se purga a los 90 días con fn_marca_rechazada_purgar, el único camino de borrado (excepción deliberada a la inmutabilidad de las bitácoras: la garantía es de privilegios, no de triggers).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | FK a tiempo.terminal(id) (surrogate, no la serie). |
| `evento_id` | `uuid` | Sí | — | — | evento_id que mandó el Pi, si pudo leerse como uuid; NULL si el evento venía mal formado. Con terminal_id es único: un reintento no duplica la fila (ON CONFLICT DO NOTHING). |
| `employee_no` | `integer` | Sí | — | — | employee_no del evento, sólo si es un entero de hasta 8 dígitos; NULL si no. No se resuelve a persona. |
| `secuencia_local` | `bigint` | Sí | — | — | secuencia_local del evento, sólo si es un entero válido. |
| `momento_dispositivo` | `timestamp with time zone` | Sí | — | — | momento_dispositivo del evento, sólo si se pudo leer. |
| `desfase_local` | `character varying(6)` | Sí | — | — | desfase_local del evento, sólo si cumple el formato ±HH:MM. |
| `estado_reloj` | `character varying(20)` | Sí | — | — | estado_reloj del evento, sólo si es uno de los 3 valores válidos. |
| `codigo` | `character varying(30)` | No | — | `forma_invalida` / `no_enrolado` / `secuencia_duplicada` / `secuencia_fuera_de_rango` / `conflicto_evento` | Código del rechazo, de lista cerrada (SCJ-CDT-01 §IX.6). |
| `creada_en` | `timestamp with time zone` | No | `now()` | — | Cuándo se registró el rechazo. Base de la retención. |

**Claves:**

- PK `id`
- UK `uq_marca_rechazada_terminal_evento` (`terminal_id`, `evento_id`)
- FK `marca_rechazada_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`

**Índices** (sin contar PK):

- `uq_marca_rechazada_terminal_evento` (UNIQUE): `(terminal_id, evento_id)`
- `ix_marca_rechazada_creada_en`: `(creada_en)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** — (a propósito: ninguno de inmutabilidad, porque la propia purga los dispararía).

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:S service_role:S. **Nadie de la API inserta** (`service_role` sin `INSERT`): la única escritura es `fn_terminal_rechazo_registrar` (`SECURITY DEFINER`) y el único borrado es `fn_marca_rechazada_purgar`. Sin `UPDATE`, `DELETE` ni `TRUNCATE` para ningún rol de la API. Secuencia identity sin privilegios. Creada en `84_tiempo_marca_rechazada.sql`. **Excepción deliberada** a la inmutabilidad en 3 capas de la bitácora de enrolamiento: es evidencia diagnóstica con vida limitada (90 días), no auditoría.

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `marca_rechazada_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura') OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion')))` |

---

### `tiempo.excepcion_descarte`

> Auditoría de fn_excepcion_dia_cerrado_descartar (86_): quién descartó una marca tardía sobre un día ya revisado, cuándo y por qué. Sólo la escribe el RPC; sin INSERT/UPDATE/DELETE/TRUNCATE para la API. El constraint trigger de dia_cerrado acepta la resolución de una excepción si hay aquí un descarte de ella creado en la misma transacción.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `excepcion_id` | `bigint` | No | — | FK → tiempo.excepcion | Excepción descartada. Sin UNIQUE: una excepción reabierta y descartada otra vez deja una fila nueva por cada descarte. |
| `dia_id` | `bigint` | No | — | FK → tiempo.dia | Día (revisado) al que pertenece la marca tardía. |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | Quien descartó (vía frontera SCJ-FRO-01), derivado de auth.uid() dentro del RPC; nunca un parámetro. |
| `motivo` | `character varying(500)` | No | — | `char_length(btrim(motivo)) >= 1` (`ck_excepcion_descarte_motivo`) | Motivo saneado (sin caracteres de control), 1 a 500 caracteres. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | Inicio de la transacción del descarte (now()); el constraint trigger lo compara con now() para exigir que sea de ESTA transacción. |

**Claves:**

- PK `id`
- FK `excepcion_id` → `tiempo.excepcion(id)`; FK `dia_id` → `tiempo.dia(id)`; FK `persona_id` → `tiempo.persona(id)`

**Índices** (sin contar PK):

- `ix_excepcion_descarte_excepcion_id`, `ix_excepcion_descarte_dia_id`, `ix_excepcion_descarte_persona_id` (ninguno UNIQUE)

**Triggers:**
- `trg_excepcion_descarte_inmutable`: BEFORE UPDATE OR DELETE, por fila → aborta (incluido `service_role` y el dueño)
- `trg_excepcion_descarte_truncate`: BEFORE TRUNCATE, por sentencia → aborta

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:S service_role:S. Nadie de la API inserta, actualiza, borra ni trunca: la escribe `fn_excepcion_dia_cerrado_descartar` (`SECURITY DEFINER`, como dueño). Inmutable en 3 capas (REVOKE, RLS sin policy de escritura, triggers). Secuencia identity sin privilegios. Creada en `86_tiempo_excepcion_protege_dia_cerrado_v2.sql`.

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `excepcion_descarte_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('excepcion_lectura') OR personas.fn_caller_tiene_permiso('excepcion_edicion')))` |

---

### `tiempo.terminal_consentimiento`

> Versiones del texto de consentimiento biométrico y aviso de privacidad (SCJ-PRO-15 §IV.7). Sólo inserción, inmutable en 3 capas. La versión vigente es la de mayor version. Sólo la escribe fn_terminal_consentimiento_publicar; la versión 1 es una semilla provisional sin autor.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `version` | `integer` | No | — | `>= 1` (`ck_terminal_consentimiento_version`); UNIQUE | Número consecutivo (1, 2, 3...) que asigna el RPC bajo lock de tabla; UNIQUE como respaldo. |
| `texto` | `text` | No | — | sin espacios ni saltos de línea en los extremos (`btrim(texto, E' \n')`), 1 a 4000 caracteres, sin caracteres de control salvo salto de línea ni caracteres de formato Unicode invisibles o de reordenamiento (U+00AD, U+061C, U+200B-200F, U+2028-202E, U+2060-2064, U+2066-2069, U+FEFF, U+E0000-E007F) (`ck_terminal_consentimiento_texto`) | Texto plano (sin HTML). La interfaz debe mostrarlo como texto, nunca como HTML. |
| `texto_sha256` | `character(64)` | No | — | igual al SHA-256 hex de `texto` en UTF-8 (`ck_terminal_consentimiento_hash`) | Sirve para citar la versión en el documento impreso. |
| `provisional` | `boolean` | No | `false` | sólo puede ser `true` en la versión 1 (`ck_terminal_consentimiento_provisional`) | true sólo en la semilla. Dejar de ser provisional = publicar una versión nueva. |
| `cambio_material` | `boolean` | No | `false` | — | true = los ya enrolados con una versión anterior deben reconsentir. El RPC lo fuerza cuando la versión anterior era provisional. |
| `nota` | `character varying(200)` | Sí | — | — | Motivo del cambio, opcional, hasta 200 caracteres. |
| `creado_por` | `uuid` | Sí | — | FK → tiempo.persona; NULL sólo en la versión 1 provisional (`ck_terminal_consentimiento_autor`) | Persona que publicó (frontera SCJ-FRO-01). NULL sólo en la semilla provisional (la interfaz lo muestra como "Sistema"). |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_terminal_consentimiento_version` (`version`)
- FK `terminal_consentimiento_creado_por_fkey` (`creado_por`) → `tiempo.persona(id)`

**Índices** (sin contar PK):

- `uq_terminal_consentimiento_version` (UNIQUE): `(version)`
- `ix_terminal_consentimiento_creado_por`: `(creado_por)`

**Restricciones CHECK de varias columnas:** `ck_terminal_consentimiento_provisional`, `ck_terminal_consentimiento_autor` (ver columnas).

**Triggers:**

- `trg_terminal_consentimiento_inmutable` — `BEFORE UPDATE OR DELETE`, por fila: aborta, incluido `service_role` y el dueño.
- `trg_terminal_consentimiento_truncate` — `BEFORE TRUNCATE`, por statement: aborta.

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario.consentimiento_id`, `tiempo.terminal_usuario.consentimiento_id`

**RLS:** habilitada; privilegios de tabla — anon:— authenticated:S service_role:S. Nadie de la API inserta, actualiza, borra ni trunca: la escribe `fn_terminal_consentimiento_publicar` (`SECURITY DEFINER`, como dueño). Secuencia identity sin privilegios. Creada en `88_tiempo_terminal_consentimiento.sql`, que siembra la versión 1 (texto provisional, `provisional = true`, sin autor).

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_consentimiento_select_lectura` | SELECT | authenticated | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura') OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion') OR personas.fn_caller_tiene_permiso('terminal_config_edicion')))` |

---

### `personas.persona`

> Identidad civil de la persona física. id (uuid) es el mismo valor que tiempo.persona.id — ver SCJ-FRO-01. actualizado_en marca la versión: el registro vigente es el de mayor valor. curp, rfc y nss no se validan por formato aquí — se deja a la capa de aplicación.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | Marca de versión del registro, no historial completo: esta tabla guarda una fila por persona (mutable), no una fila por corrección. Se actualiza en cada UPDATE. |
| `curp` | `character varying(18)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `rfc` | `character varying(13)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `nss` | `character varying(11)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `primer_nombre` | `character varying(100)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `segundo_nombre` | `character varying(100)` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `apellido_paterno` | `character varying(100)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `apellido_materno` | `character varying(100)` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `fecha_nacimiento` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `fecha_ingreso` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `fecha_baja` | `date` | Sí | — | — | Se sincroniza con estado por trg_persona_sincroniza_baja: no puede haber fecha_baja con estado activo o suspension, ni estado baja_definitiva sin fecha_baja. |
| `estado` | `character varying(20)` | No | `'activo'::character varying` | `activo` / `baja_definitiva` / `suspension` | activo / baja_definitiva / suspension. Sin "incapacidad": se decidió no distinguirla como estado propio de persona (sesión 2026-08-31). |

**Claves:**

- PK `id`
- UK `uq_persona_curp` (`curp`)
- UK `uq_persona_nss` (`nss`)
- UK `uq_persona_rfc` (`rfc`)

**Índices** (sin contar PK): 

- `uq_persona_curp` (UNIQUE): `(curp)`
- `uq_persona_nss` (UNIQUE): `(nss)`
- `uq_persona_rfc` (UNIQUE): `(rfc)`

**Restricciones CHECK de varias columnas:** 
- `ck_persona_baja_consistente`: `((estado) = 'baja_definitiva') = (fecha_baja IS NOT NULL)`

**Triggers:** 
- `trg_persona_protege_columnas_identidad`: BEFORE UPDATE → `personas.fn_persona_protege_columnas_identidad()`
- `trg_persona_sincroniza_baja`: BEFORE INSERT OR UPDATE → `personas.fn_persona_sincroniza_baja()`
- `trg_persona_sincroniza_tiempo`: AFTER INSERT → `personas.fn_persona_sincroniza_tiempo()`

**Referenciada por:** `personas.asignacion`.`persona_id`, `personas.bitacora_movimiento_persona`.`persona_id`, `personas.expediente`.`persona_id`, `personas.usuario`.`persona_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `persona_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona'))` |
| `persona_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |
| `persona_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `persona_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('cambio_estado_persona') OR personas.fn_caller_tiene_permiso('persona_edicion'))) ; CHECK (personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('cambio_estado_persona') OR…` |

---

### `personas.expediente`

> Referencia al expediente físico/digital de la persona. documento_ref es la única referencia (folio) — el archivo real vive en el bucket de Storage "expedientes", no en esta tabla.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → personas.persona | — (sin `COMMENT ON` en el DDL) |
| `tipo_contrato` | `character varying(30)` | No | — | `indefinido` / `prestacion_servicios` / `por_proyecto` | — (sin `COMMENT ON` en el DDL) |
| `fecha_firma` | `timestamp with time zone` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `documento_ref` | `character varying(50)` | No | — | `(documento_ref) ~ '^RTB-RH-EIT-[0-9]{4}-[0-9]+$'` | Folio formato RTB-RH-EIT-<año vigente>-<número de expediente>, ej. RTB-RH-EIT-2026-06. Único por persona (uq_expediente_persona: una persona, un expediente). Ver 71_*.sql. |

**Claves:**

- PK `id`
- UK `uq_expediente_documento_ref` (`documento_ref`)
- UK `uq_expediente_persona` (`persona_id`)
- FK `expediente_persona_id_fkey` (`persona_id`) → `personas.persona(id)`

**Índices** (sin contar PK): 

- `uq_expediente_documento_ref` (UNIQUE): `(documento_ref)`
- `uq_expediente_persona` (UNIQUE): `(persona_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `expediente_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |
| `expediente_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |
| `expediente_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `expediente_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion'))` |

---

### `personas.usuario`

> Cuenta de acceso, ligada 1:1 a auth.users (Supabase Auth) y a lo más 1:1 a personas.persona. usuario.estado es un interruptor de la cuenta en sí (activo/inactivo), distinto de persona.estado (el candado real de acceso, ver SCJ-PRO-02) — no se usa para autorización.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `auth_user_id` | `uuid` | No | — | FK → auth.users | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | Sí | — | FK → personas.persona | — (sin `COMMENT ON` en el DDL) |
| `nombre_usuario` | `character varying(100)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `estado` | `character varying(20)` | No | `'activo'::character varying` | `activo` / `inactivo` | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `auth_user_id`
- UK `uq_usuario_persona` (`persona_id`)
- FK `usuario_auth_user_id_fkey` (`auth_user_id`) → `auth.users(id)`
- FK `usuario_persona_id_fkey` (`persona_id`) → `personas.persona(id)`

**Índices** (sin contar PK): 

- `uq_usuario_persona` (UNIQUE): `(persona_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_usuario_bitacora_alta`: AFTER INSERT → `personas.fn_usuario_bitacora_alta()`

**Referenciada por:** `personas.bitacora_movimiento_persona`.`registrado_por`, `personas.bitacora_movimiento_puesto_permiso`.`registrado_por`, `tiempo.parametro`.`registrado_por`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `usuario_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |
| `usuario_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |
| `usuario_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `usuario_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'))` |

---

### `personas.bitacora_movimiento_persona`

> Fuente de verdad de persona.estado y fecha_baja (ver SCJ-PRO-02) y también registra el alta (tipo_movimiento = alta, disparado por trg_usuario_bitacora_alta). No registra cambios de puesto/área — eso es un módulo aparte (asignacion), todavía sin diseñar.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → personas.persona | — (sin `COMMENT ON` en el DDL) |
| `tipo_movimiento` | `character varying(20)` | No | — | `alta` / `suspension` / `reactivacion` / `baja_definitiva` | — (sin `COMMENT ON` en el DDL) |
| `fecha_efectiva` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `motivo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `documento_ref` | `character varying(50)` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `registrado_por` | `uuid` | Sí | — | FK → personas.usuario | FK a personas.usuario(auth_user_id), no a persona_id: el diagrama de Lucid lo anotaba contra persona_id, pero esa columna no es única en usuario — ver bitacora/2026-09-03_*.md. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `bitacora_movimiento_persona_persona_id_fkey` (`persona_id`) → `personas.persona(id)`
- FK `bitacora_movimiento_persona_registrado_por_fkey` (`registrado_por`) → `personas.usuario(auth_user_id)`

**Índices** (sin contar PK): 

- `ix_bitacora_movimiento_persona_persona_id`: `(persona_id)`
- `ix_bitacora_movimiento_persona_registrado_por`: `(registrado_por)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_bitacora_inmutable`: BEFORE DELETE OR UPDATE → `personas.fn_bitacora_inmutable()`
- `trg_bitacora_sincroniza_persona`: AFTER INSERT → `personas.fn_bitacora_sincroniza_persona()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona'))` |
| `bitacora_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |

---

### `personas.area`

> Catálogo raíz del módulo Estructura Organizacional (SCJ-PRO-03). Sólo 5 columnas — tipo_area (línea/apoyo) del organigrama no entra, sin respaldo documental. actualizado_en lo setea el backend en el PATCH, no hay trigger de auto-refresco (ningún trigger genérico de ese tipo existe en el proyecto). TODO SCJ-PRO-06 DA1: falta la guarda que impida desactivar un area con departamento activo — no se puede escribir hasta que exista personas.departamento.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `nombre_area` | `character varying(100)` | No | — | — | Único por uq_area_nombre (exacto) y ux_area_nombre_insensible (lower()) — evita duplicados tipo "Comercial"/"comercial". |
| `activo` | `boolean` | No | `true` | — | Interruptor de SCJ-PRO-06 (desactivar/reactivar). No hay guarda todavía contra departamento hijo activo — ver TODO SCJ-PRO-06 DA1 en el comentario de tabla. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_area_nombre` (`nombre_area`)

**Índices** (sin contar PK): 

- `uq_area_nombre` (UNIQUE): `(nombre_area)`
- `ux_area_nombre_insensible` (UNIQUE): `(lower((nombre_area)::text))`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `personas.departamento`.`area_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `area_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'))` |
| `area_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'))` |
| `area_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `area_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'))` |

---

### `personas.departamento`

> Segundo nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.area. actualizado_en lo setea el backend en el PATCH, no hay trigger de auto-refresco. No hay trigger que impida crear un departamento con area inactiva — esa validación va en el backend, no en DDL. TODO SCJ-PRO-06 DD1: falta la guarda que impida desactivar un departamento con puesto activo — no se puede escribir hasta que exista personas.puesto.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `area_id` | `uuid` | No | — | FK → personas.area | — (sin `COMMENT ON` en el DDL) |
| `nombre_departamento` | `character varying(100)` | No | — | — | Único GLOBAL, no por área (SCJ-PRO-03 §V explícito) — uq_departamento_nombre no lleva area_id. ux_departamento_nombre_insensible cubre el mismo caso vía lower(). |
| `activo` | `boolean` | No | `true` | — | Interruptor de SCJ-PRO-06. No hay guarda todavía contra puesto hijo activo — ver TODO SCJ-PRO-06 DD1 en el comentario de tabla. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_departamento_nombre` (`nombre_departamento`)
- FK `departamento_area_id_fkey` (`area_id`) → `personas.area(id)`

**Índices** (sin contar PK): 

- `ix_departamento_area_id`: `(area_id)`
- `uq_departamento_nombre` (UNIQUE): `(nombre_departamento)`
- `ux_departamento_nombre_insensible` (UNIQUE): `(lower((nombre_departamento)::text))`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `personas.puesto`.`departamento_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `departamento_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'))` |
| `departamento_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'))` |
| `departamento_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `departamento_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'))` |

---

### `personas.puesto`

> Tercer nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.departamento, con jerarquía propia vía reporta_a_id. nivel es varchar+CHECK, no CREATE TYPE ENUM — ningún enum Postgres existe en el proyecto, mismo criterio que persona.estado. Sin nombre_puesto UNIQUE: SCJ-PRO-03 nunca pide validación de nombre duplicado para puesto (a diferencia de area/departamento), no se inventa. Sin validación de ciclo/recorrido en DDL: SCJ-PRO-03 §I excluye la edición de reporta_a_id de este alcance, y en el alta (siempre elige un puesto ya existente) el ciclo es imposible por construcción — sería código muerto hasta que exista ese endpoint de edición. ck_puesto_no_autoreferencia sí se agrega: defensivo, gratis, cubre incluso un UPDATE directo por SQL. La guarda de SCJ-PRO-06 DP4 (no desactivar con puesto subordinado activo) sí es construible hoy y va en el backend (ya existen todas las filas que necesita consultar). TODO SCJ-PRO-06 DP1/DP3: asignación vigente y puesto_permiso activo, tablas inexistentes.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `departamento_id` | `uuid` | No | — | FK → personas.departamento | — (sin `COMMENT ON` en el DDL) |
| `nombre_puesto` | `character varying(150)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `nivel` | `character varying(20)` | No | — | `direccion` / `gerencia` / `mando_medio` / `operativo` | Catálogo cerrado de 4 valores (ck_puesto_nivel): direccion, gerencia, mando_medio, operativo — snake_case ASCII de Dirección/Gerencia/Mando medio/Operativo. |
| `plazas_totales` | `integer` | No | `1` | `plazas_totales > 0` | — (sin `COMMENT ON` en el DDL) |
| `reporta_a_id` | `uuid` | Sí | — | FK → personas.puesto | NULL-able en DDL — el único NULL real es el puesto tope (Gerente General), sembrado por migración vía SQL directo, fuera del flujo normal de alta. El backend exige este campo en el POST normal: la API nunca puede crear un segundo puesto sin padre. ux_puesto_tope_unico lo garantiza también a nivel de Postgres. |
| `activo` | `boolean` | No | `true` | — | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `es_administrador_generico` | `boolean` | No | `false` | — | true sólo en el puesto de bootstrap que siembra 26_puesto_permiso_bootstrap_admin_generico.sql.   Inmutable después del backfill inicial (ver trigger trg_puesto_administrador_generico_inmutable   más abajo, en este mismo archivo) -- ni la app ni un UPDATE directo por PostgREST ni service_role   pueden cambiarla después de sembrada. Existe para identificar el puesto administrador sin   depender de nombre_puesto (editable, frágil) en las policies RLS que lo protegen de   auto-bloqueo (ver bloques 3 y 4 de este archivo). |

**Claves:**

- PK `id`
- FK `puesto_departamento_id_fkey` (`departamento_id`) → `personas.departamento(id)`
- FK `puesto_reporta_a_id_fkey` (`reporta_a_id`) → `personas.puesto(id)`

**Índices** (sin contar PK): 

- `ix_puesto_departamento_id`: `(departamento_id)`
- `ix_puesto_reporta_a_id`: `(reporta_a_id)`
- `ux_puesto_administrador_generico_unico` (UNIQUE): `((true)) WHERE es_administrador_generico`
- `ux_puesto_tope_unico` (UNIQUE): `(((reporta_a_id IS NULL))) WHERE (reporta_a_id IS NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_puesto_no_autoreferencia`: `id IS DISTINCT FROM reporta_a_id`

**Triggers:** 
- `trg_puesto_administrador_generico_inmutable`: BEFORE UPDATE → `personas.fn_puesto_administrador_generico_inmutable()`

**Referenciada por:** `personas.asignacion`.`puesto_id`, `personas.bitacora_movimiento_puesto_permiso`.`puesto_id`, `personas.puesto`.`reporta_a_id`, `personas.puesto_permiso`.`puesto_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `puesto_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'))` |
| `puesto_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'))` |
| `puesto_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `puesto_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion') AND (NOT ((activo = false) AND es_administrador_generico)))` |

---

### `personas.asignacion`

> Vínculo persona-puesto con vigencia (SCJ-PRO-04). Esta tabla completa — filas abiertas (vigente_hasta NULL) y cerradas — ES la bitácora de movimientos de puesto, no hay tabla aparte (SCJ-PRO-04 §V). Sin creado_por/cerrado_por: el documento no pide rastrear quién ejecutó cada acción, no se inventa (mismo criterio de los tres cortes anteriores del módulo).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → personas.persona | — (sin `COMMENT ON` en el DDL) |
| `puesto_id` | `uuid` | No | — | FK → personas.puesto | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde` | `date` | No | — | — | date, no timestamptz — fecha de vigencia de negocio, mismo criterio que fecha_nacimiento/fecha_ingreso/fecha_baja de personas.persona. |
| `vigente_hasta` | `date` | Sí | — | — | NULL = asignación vigente hoy. Se cierra con una fecha real al terminar la asignación, ya sea por PATCH .../terminar, por fn_asignacion_cambiar_puesto(), o automáticamente por trg_bitacora_sincroniza_persona en baja_definitiva (ver 18_asignacion_trigger_baja_definitiva.sql). ux_asignacion_vigente_persona_puesto garantiza a lo sumo una fila vigente por (persona, puesto). |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `asignacion_persona_id_fkey` (`persona_id`) → `personas.persona(id)`
- FK `asignacion_puesto_id_fkey` (`puesto_id`) → `personas.puesto(id)`

**Índices** (sin contar PK): 

- `ix_asignacion_persona_id`: `(persona_id)`
- `ix_asignacion_puesto_id`: `(puesto_id)`
- `ux_asignacion_vigente_persona_puesto` (UNIQUE): `(persona_id, puesto_id) WHERE (vigente_hasta IS NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_asignacion_vigencia`: `(vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)`

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `asignacion_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'))` |
| `asignacion_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'))` |
| `asignacion_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `asignacion_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion') AND (NOT ((vigente_hasta IS NOT NULL) AND (EXISTS ( SELECT 1 FROM …` |

---

### `personas.permiso`

> Catálogo de permisos (SCJ-PRO-05). Única tabla del módulo Estructura Organizacional sin uuid PRIMARY KEY — codigo es la clave, fiel a la redacción literal del documento ("UNIQUE(puesto_id, codigo)", "cuenta filas con ese código"): el propio proceso trata al código como identificador, no como un atributo más. El alta de permiso no es un proceso de usuario — se siembra por migración al integrar un módulo nuevo (SCJ-PRO-03 §I, SCJ-PRO-05 §I), nunca por la API. Sin columna nombre/label: codigo (ej. area_edicion) ya es el identificador legible, no se inventa un campo de UI adicional sin respaldo documental.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `codigo` | `character varying(50)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `heredable` | `boolean` | No | `false` | — | true = sube por reporta_a_id (SCJ-PRO-05 §IV): si un puesto lo tiene, todo puesto AL QUE ESE PUESTO REPORTA (su jefe, directo o transitivo, subiendo por reporta_a_id) lo tiene también, sin fila propia en puesto_permiso — el jefe hereda lo del subordinado, no al revés. |
| `activo` | `boolean` | No | `true` | — | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `codigo`

**Índices** (sin contar PK): —

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `personas.bitacora_movimiento_puesto_permiso`.`codigo`, `personas.puesto_permiso`.`codigo`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `permiso_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'))` |
| `permiso_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'))` |
| `permiso_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `permiso_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'))` |

---

### `personas.puesto_permiso`

> Estado vigente de "qué permiso tiene cada puesto" — snapshot derivado y mantenido por trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) a partir de bitacora_movimiento_puesto_permiso, la fuente de verdad real. No se escribe directo desde la API salvo por el bootstrap/seed (SQL directo, fuera del flujo normal).

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `puesto_id` | `uuid` | No | — | FK → personas.puesto | — (sin `COMMENT ON` en el DDL) |
| `codigo` | `character varying(50)` | No | — | FK → personas.permiso | uq_puesto_permiso_puesto_codigo (puesto_id, codigo) es literal de SCJ-PRO-05 §VI: sin ella, otorgar el mismo permiso dos veces al mismo puesto crearía dos filas y el trigger no sabría cuál actualizar al revocar. |
| `activo` | `boolean` | No | `true` | — | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_puesto_permiso_puesto_codigo` (`puesto_id`, `codigo`)
- FK `puesto_permiso_codigo_fkey` (`codigo`) → `personas.permiso(codigo)`
- FK `puesto_permiso_puesto_id_fkey` (`puesto_id`) → `personas.puesto(id)`

**Índices** (sin contar PK): 

- `uq_puesto_permiso_puesto_codigo` (UNIQUE): `(puesto_id, codigo)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:DISU authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `puesto_permiso_delete_requiere_permiso` | DELETE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion') AND (NOT (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = puesto_permiso.puesto_id) AND pu.es_administrador_generico)))))` |
| `puesto_permiso_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'))` |
| `puesto_permiso_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |
| `puesto_permiso_update_requiere_permiso` | UPDATE | public | `USING (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion')) ; CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion') AND (NOT ((activo = false) AND (EXISTS ( SELECT 1 FROM per…` |

---

### `personas.bitacora_movimiento_puesto_permiso`

> Fuente de verdad de puesto_permiso.activo (SCJ-PRO-05). Sólo inserción — inmutable desde el arranque, ver comentario de cabecera del archivo. trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) deriva puesto_permiso a partir de cada fila insertada acá.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `puesto_id` | `uuid` | No | — | FK → personas.puesto | — (sin `COMMENT ON` en el DDL) |
| `codigo` | `character varying(50)` | No | — | FK → personas.permiso | — (sin `COMMENT ON` en el DDL) |
| `tipo_movimiento` | `character varying(20)` | No | — | `otorgado` / `revocado` | — (sin `COMMENT ON` en el DDL) |
| `fecha_efectiva` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `motivo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `registrado_por` | `uuid` | Sí | — | FK → personas.usuario | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- FK `bitacora_movimiento_puesto_permiso_codigo_fkey` (`codigo`) → `personas.permiso(codigo)`
- FK `bitacora_movimiento_puesto_permiso_puesto_id_fkey` (`puesto_id`) → `personas.puesto(id)`
- FK `bitacora_movimiento_puesto_permiso_registrado_por_fkey` (`registrado_por`) → `personas.usuario(auth_user_id)`

**Índices** (sin contar PK): 

- `ix_bitacora_movimiento_puesto_permiso_puesto_id`: `(puesto_id)`
- `ix_bitacora_movimiento_puesto_permiso_registrado_por`: `(registrado_por)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_bitacora_puesto_permiso_inmutable`: BEFORE DELETE OR UPDATE → `personas.fn_bitacora_puesto_permiso_inmutable()`
- `trg_puesto_permiso_sincroniza`: AFTER INSERT → `personas.fn_puesto_permiso_sincroniza()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:IS authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_puesto_permiso_insert_requiere_permiso` | INSERT | public | `CHECK (personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion') AND (NOT (((tipo_movimiento) = 'revocado') AND (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = bitacora_movimiento_puesto_permiso.puesto_id) AND pu.…` |
| `bitacora_puesto_permiso_select_caller_activo` | SELECT | public | `USING personas.fn_caller_activo()` |

---

## III. Enumerados

No existe ningún `CREATE TYPE ... AS ENUM` en `personas` ni `tiempo` (consulta a `pg_type`: 0). Todos los dominios cerrados son `varchar(N)` con `CHECK`, como decide `SCJ-MOD-03 §III`. Los 24 reales:

| Tabla.columna | Valores permitidos | Restricción |
|---|---|---|
| `tiempo.jornada_asignada.tipo_jornada` | `normal` / `flexible` / `de_confianza` | `ck_jornada_asignada_tipo` |
| `tiempo.patron_semanal.dia_semana` | `lunes` / `martes` / `miercoles` / `jueves` / `viernes` / `sabado` / `domingo` | `ck_patron_semanal_dia_semana` |
| `tiempo.marca.estado_reloj` | `sincronizado` / `deriva` / `sin_sincronizar` | `ck_marca_estado_reloj` |
| `tiempo.marca.origen` | `terminal` / `captura_manual` | `ck_marca_origen` |
| `tiempo.dia.estado` | `abierto` / `cerrado` / `bloqueado` / `revisado` | `ck_dia_estado` |
| `tiempo.dia.origen` | `automatico_confianza` / `ausencia_autorizada` (o NULL) | `ck_dia_origen` |
| `tiempo.clasificacion_de_tiempo.tipo` | `ordinario` / `reposicion` / `extra` (o NULL) | `ck_clasificacion_de_tiempo_tipo` |
| `tiempo.movimiento_de_saldo.tipo` | `generado_quincena` / `cubrir` / `arrastrar` / `descontar` / `condonar` | `ck_movimiento_de_saldo_tipo` |
| `tiempo.ausencia.tipo_de_ausencia` | `vacaciones` / `permiso_con_goce` / `permiso_sin_goce` / `incapacidad` / `falta` | `ck_ausencia_tipo` |
| `tiempo.ausencia.estado_autorizacion` | `pendiente` / `autorizada` / `rechazada` | `ck_ausencia_estado_autorizacion` |
| `tiempo.aprobacion_ausencia.decision` | `pendiente` / `autorizada` / `rechazada` | `ck_aprobacion_ausencia_decision` |
| `tiempo.excepcion.estado` | `pendiente` / `resuelto` | `ck_excepcion_estado` |
| `tiempo.corrida_batch.tipo_batch` | `cierre_dia` / `corte_quincenal` / `de_confianza` | `ck_corrida_batch_tipo` |
| `tiempo.corrida_batch.estado` | `en_progreso` / `exitosa` / `fallida` | `ck_corrida_batch_estado` |
| `tiempo.terminal_usuario.estado` | `pendiente_alta` / `esperando_huella` / `activo` / `pendiente_baja` / `baja` | `ck_terminal_usuario_estado` |
| `tiempo.bitacora_movimiento_terminal_usuario.tipo_movimiento` | `asignado` / `usuario_creado` / `huella_capturada` / `baja_solicitada` / `baja_confirmada` / `error` | `ck_bitacora_terminal_usuario_tipo` |
| `tiempo.bitacora_movimiento_terminal_usuario.origen` | `web` / `terminal` | `ck_bitacora_terminal_usuario_origen` |
| `tiempo.marca_rechazada.codigo` | `forma_invalida` / `no_enrolado` / `secuencia_duplicada` / `secuencia_fuera_de_rango` / `conflicto_evento` | `ck_marca_rechazada_codigo` |
| `personas.persona.estado` | `activo` / `baja_definitiva` / `suspension` | `ck_persona_estado` |
| `personas.expediente.tipo_contrato` | `indefinido` / `prestacion_servicios` / `por_proyecto` | `ck_expediente_tipo_contrato` |
| `personas.usuario.estado` | `activo` / `inactivo` | `ck_usuario_estado` |
| `personas.bitacora_movimiento_persona.tipo_movimiento` | `alta` / `suspension` / `reactivacion` / `baja_definitiva` | `ck_bitacora_tipo_movimiento` |
| `personas.puesto.nivel` | `direccion` / `gerencia` / `mando_medio` / `operativo` | `ck_puesto_nivel` |
| `personas.bitacora_movimiento_puesto_permiso.tipo_movimiento` | `otorgado` / `revocado` | `ck_bitacora_puesto_permiso_tipo` |

Dominios por formato u otra expresión (no son listas):

| Columna | Regla |
|---|---|
| `tiempo.marca.desfase_local` | Formato `±HH:MM` (`ck_marca_desfase_local`) |
| `personas.expediente.documento_ref` | Formato `RTB-RH-EIT-AAAA-N` (`ck_expediente_documento_ref_formato`) |
| `tiempo.excepcion.motivo_revision` | `text` **sin CHECK**: dominio abierto. Los triggers del DDL escriben `reloj_no_sincronizado`, `persona_inactiva`, `dia_cerrado` y `fuera_de_horario` (`fn_marca_valida_revision`); `fn_ausencia_resuelve_excepcion` le agrega un sufijo de texto al resolver. El comentario del DDL menciona un quinto motivo, `plantilla_desconocida`, que nace en Operación y no se calcula en la base. Los motivos de excepciones de **día** (`dia_id`) no los escribe ningún script del DDL: no determinado. |

---

## IV. Parámetros del sistema

Fuente: `db/ddl/03_parametros_ejemplo.sql` (8 filas, `vigente_desde = 2026-01-01`; *(V1.4)* `89_tiempo_terminal_config_parametros.sql` siembra 5 claves `terminal_*` más, con la misma fecha, `vigente_hasta` y `registrado_por` NULL). Ningún script posterior inserta ni cambia claves; `60_tiempo_parametro_vigencia_y_autor.sql` sólo agregó `vigente_hasta`/`registrado_por` y el RPC `fn_parametro_actualizar_valor`. **Todos los valores son de ejemplo**, no de operación (el propio archivo lo declara). `valor` es `text`: el tipo lógico (entero/hora) no está en la base.

| Clave | Valor (ejemplo) | Qué controla | Consumo verificado en el DDL |
|---|---|---|---|
| `tolerancia_retardo_min` | `10` | Minutos de tolerancia antes de generar alerta `fuera_de_horario` por entrada tardía | Sí: `fn_marca_valida_revision` (`02`, redefinida en `72`) |
| `hora_corte_dia` | `00:00` | Hora en que se considera cerrado el día | Ninguna función del DDL la lee (la usa el backend, según `CLAUDE.md`) |
| `ventana_banco_meses` | `6` | Duración de la ventana de resolución del banco de horas | Ninguna función del DDL la lee (backend) |
| `umbral_aviso_pct` | `100` | % de la jornada semanal de deuda que dispara aviso | Ninguna función del DDL la lee (backend) |
| `umbral_escalamiento_pct` | `200` | % de la jornada semanal de deuda que dispara escalamiento | Ninguna función del DDL la lee (backend) |
| `descuento_pausa_no_registrada_min` | `60` | Minutos descontados cuando la pausa de comida no se marca | Sí: lógica de ausencias de `66_tiempo_ausencia_descuento_pausa_y_confianza.sql` |
| `dias_habiles_correccion_marca` | `30` | Ventana para corregir una marca, en días hábiles (`SCJ-PRO-10`) | No en la base: se valida en el backend (comentarios de `02` y `61`) |
| `hora_corrida_cierre_dia` | `03:00` | Colchón tras `hora_corte_dia` antes de correr el batch de cierre (`SCJ-PRO-12`) | No en la base: lo lee el scheduler del backend |
| `terminal_caducidad_alta_horas` *(89_)* | `24` (rango 4 a 168) | Horas tras `usuario_creado` para dar de baja una alta sin huella | No en la base: el job del backend la lee con `fn_terminal_config_valor` y la pasa como `p_horas` a `fn_terminal_baja_por_caducidad` (piso 4 h y tope 50 por corrida dentro de la función) |
| `terminal_llave_max_meses` *(89_)* | `12` (3 a 36) | Antigüedad máxima de una llave de la terminal | No en la base: tablero de anomalías (backend) |
| `terminal_traslape_llave_max_dias` *(89_)* | `7` (1 a 90) | Días máximos con dos llaves vigentes; no puede pasar de la mitad de la antigüedad máxima en días | No en la base: tablero de anomalías (backend) |
| `terminal_anomalias_ventana_dias` *(89_)* | `7` (1 a 90) | Ventana por omisión del tablero de anomalías | No en la base: backend |
| `terminal_retencion_rechazos_dias` *(89_)* | `90` (30 a 365) | Retención de `tiempo.marca_rechazada` | No en la base: el job del backend la pasa como `p_dias` a `fn_marca_rechazada_purgar` (piso 7 días dentro) |

Las claves `terminal_*` sólo se editan con `fn_terminal_config_actualizar` (permiso `terminal_config_edicion`); `fn_parametro_actualizar_valor` las rechaza con `SCJ17` / `clave_reservada`.

Las columnas "backend" se apoyan en comentarios del DDL, en `CLAUDE.md` y en `SCJ-PRO-12`; no se verificó el código del backend para este documento. Otros datos que cargan los scripts (no son parámetros): catálogo `personas.permiso` (51 filas, `25`, `33`, `35`, `45`, `62`, `69`, `80`, entre otros), áreas/departamentos/puestos iniciales (`11`, `13`, `15`, `16`) y el bucket `expedientes` (`07`).

---

## V. Funciones, RPC y políticas RLS

### V.1 Funciones (70)

Ejecutable por: roles con `EXECUTE` entre `anon`, `authenticated`, `service_role`, `terminal_checador`; `público` = el privilegio por omisión de `PUBLIC` sigue activo. SD = `SECURITY DEFINER`.

| Función | Tipo | SD | Ejecutable por | Descripción (resumen del `COMMENT ON`) |
|---|---|---|---|---|
| `personas.fn_asignacion_cambiar_puesto(p_asignacion_id uuid, p_puesto_nuevo_id uuid, p_fecha date)` | RPC | no | authenticated | RPC transaccional de "cambiar de puesto" (SCJ-PRO-04 §VII): cierra la asignación vigente p_asignacion_id y abre una nueva para el mismo persona_id en p_puesto_nuevo_id, ambas escrituras en una sola t… |
| `personas.fn_bitacora_inmutable()` | trigger | no | público | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role (que salta RLS y conserva el GRANT de 08_personas_permisos.sql hasta que se revoque explícitamente). |
| `personas.fn_bitacora_puesto_permiso_inmutable()` | trigger | no | público | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role. |
| `personas.fn_bitacora_sincroniza_persona()` | trigger | no | público | Implementa SCJ-PRO-02 (sincroniza persona.estado/fecha_baja) y, desde este archivo, además SCJ-PRO-04 §VI: en baja_definitiva cierra todas las asignaciones vigentes de la persona con vigente_hasta = … |
| `personas.fn_caller_activo()` | auxiliar | sí | público | true si el usuario autenticado (auth.uid()) tiene una persona activa detrás. |
| `personas.fn_caller_tiene_permiso(p_codigo text)` | auxiliar | no | público | Réplica en SQL, para uso en policies RLS, de backend/app/permisos.py::tiene_permiso() -- incluida la herencia jerárquica (el jefe hereda el permiso de cualquier subordinado, directo o transitivo, vía… |
| `personas.fn_persona_actualizar_datos(p_persona_id uuid, p_curp character varying, p_rfc character varying, p_nss character varying, p_primer_nombre character varying, p_segundo_nombre character varying, p_apellido_paterno character varying, p_apellido_materno character varying, p_fecha_nacimiento date, p_fecha_ingreso date, p_tipo_contrato character varying, p_documento_ref character varying)` | RPC | no | authenticated | RPC transaccional de edición de datos de persona/expediente (persona_edicion). |
| `personas.fn_persona_protege_columnas_identidad()` | trigger | no | ninguno explícito (dueño) | Cierra el hueco de que persona_update_requiere_permiso (69_personas_edicion.sql) no puede distinguir columnas: RLS WITH CHECK sólo ve la fila NUEVA, no la anterior. |
| `personas.fn_persona_sincroniza_baja()` | trigger | no | público | Sincroniza estado y fecha_baja en ambos sentidos. |
| `personas.fn_persona_sincroniza_tiempo()` | trigger | sí | público | Crea el ancla tiempo.persona(id) al dar de alta una personas.persona -- sólo el id, ningún atributo de identidad cruza la frontera (SCJ-FRO-01). |
| `personas.fn_puesto_administrador_generico_inmutable()` | trigger | no | ninguno explícito (dueño) | Aborta cualquier UPDATE que cambie es_administrador_generico, incluido service_role. |
| `personas.fn_puesto_permiso_sincroniza()` | trigger | no | público | Implementa SCJ-PRO-05 G8 ("crea o reactiva la fila"): ON CONFLICT (puesto_id, codigo) DO UPDATE resuelve en una sola sentencia el caso de otorgar un permiso ya revocado antes, apoyado en uq_puesto_pe… |
| `personas.fn_usuario_bitacora_alta()` | trigger | no | público | Implementa SCJ-PRO-01 paso A3. |
| `tiempo.fn_aprobacion_ausencia_actualiza_ausencia()` | trigger | sí | público | Recalcula ausencia.estado_autorizacion desde su cadena de pasos: cualquier rechazo cierra en 'rechazada'; |
| `tiempo.fn_ausencia_resolver(p_ausencia_id bigint, p_decision character varying, p_tipo_de_ausencia character varying, p_motivo text)` | RPC | no | authenticated | RPC transaccional de "resolver ausencia" (SCJ-PRO-08): si decision=autorizada, reclasifica tipo_de_ausencia; |
| `tiempo.fn_ausencia_resuelve_excepcion()` | trigger | sí | público | Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion por día sin checada, la resuelve sola — RH no tiene que cerrarla a mano. |
| `tiempo.fn_bitacora_terminal_usuario_aplica()` | trigger | sí | ninguno (dueño) | Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] desde cada fila de la bitácora (SCJ-DEC-11). SCJ11/SCJ12; *(88_)* SCJ16 si la versión del texto de consentimiento falta o no es la vigente, y rama 'reconsentido' (no cambia estado ni huellas, conserva error_detalle). En 'asignado' toma la terminal FOR SHARE (83_) y la tabla de versiones en ROW EXCLUSIVE antes de leer la vigente. SECURITY DEFINER, search_path = tiempo, personas, pg_temp. |
| `tiempo.fn_bitacora_terminal_usuario_inmutable()` | trigger | no | ninguno (dueño) | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role y el dueño. |
| `tiempo.fn_bitacora_terminal_usuario_truncate()` | trigger | no | ninguno (dueño) | Aborta TRUNCATE sobre la bitácora (trigger por statement, sin OLD). El dueño aún puede DROP/DISABLE TRIGGER: residual documentado en la cabecera. |
| `tiempo.fn_correccion_recalcula_tramo()` | trigger | no | público | SCJ-PRO-10. |
| `tiempo.fn_correccion_bloquea_marca_en_tramo()` | trigger | sí | ninguno (dueño) | 87_. BEFORE INSERT en tiempo.correccion: rechaza con SCJ15 / marca_en_tramo la corrección de una marca que es apertura o cierre de cualquier tramo (no se reflejaría en tramo, horas, corte ni banco). Corre para todos los roles; anon y el usuario sin persona activa o sin correccion_edicion no reciben respuesta (los rechaza lo siguiente: P0001 o 42501). SECURITY DEFINER, search_path = tiempo, personas, pg_temp. |
| `tiempo.fn_correccion_valida()` | trigger | no | público | SCJ-PRO-10. |
| `tiempo.fn_corte_quincenal_aplicar_persona(p_persona_id uuid, p_clasificaciones jsonb, p_movimientos jsonb, p_motivo text)` | RPC | no | service_role | RPC transaccional de "aplicar corte quincenal a una persona" (SCJ-PRO-13): inserta todas las clasificaciones del periodo, resuelve/crea banco_de_horas, e inserta todos los movimientos de saldo corres… |
| `tiempo.fn_dia_calcular_armado_tramos(p_dia_id bigint)` | RPC | no | authenticated,service_role | Calcula (sin escribir) qué haría fn_dia_revisar al armar los tramos faltantes de un día: una fila por acción -- cerrar_existente (cierra un tramo abierto con una huérfana), nuevo (arma un tramo nuevo… |
| `tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)` | RPC | no | authenticated | RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH. |
| `tiempo.fn_excepcion_protege_dia_cerrado()` | trigger | sí | ninguno (dueño) | *(86_, reemplaza a la de 78_)* Constraint trigger de sólo motivo dia_cerrado%: acepta pendiente -> resuelto únicamente con la revisión del día en esta misma transacción (tramo de la misma persona y fecha local efectiva) o con un descarte de la excepción creado en ella; si no, SCJ15 / dia_cerrado_requiere_revision. SECURITY DEFINER, search_path = tiempo, pg_temp. |
| `tiempo.fn_excepcion_dia_cerrado_descartar(p_excepcion_id bigint, p_motivo text)` | RPC | sí | authenticated | 86_. Descarta una marca tardía sobre un día YA revisado: exige persona activa y el permiso de acción excepcion_dia_cerrado_descarte (no heredable) dentro de la función, deriva quién descarta de auth.uid(), registra quién/cuándo/por qué en tiempo.excepcion_descarte y resuelve la excepción con el sufijo ' — descartada por <persona_id>: <motivo>'. Idempotente (ya_descartada). SECURITY DEFINER, search_path = tiempo, personas, pg_temp. |
| `tiempo.fn_excepcion_descarte_inmutable()` | trigger | no | ninguno (dueño) | Aborta UPDATE/DELETE sobre tiempo.excepcion_descarte, incluido service_role y el dueño. |
| `tiempo.fn_excepcion_descarte_truncate()` | trigger | no | ninguno (dueño) | Aborta TRUNCATE sobre tiempo.excepcion_descarte (trigger por statement). |
| `tiempo.fn_excepcion_protege_columnas()` | trigger | no | ninguno (dueño) | 86_. marca_id, dia_id y creado_en inmutables; motivo_revision sólo cambia al resolver agregando un sufijo ' — …'. SCJ15 (excepcion_columna_inmutable | excepcion_motivo_inmutable). |
| `tiempo.fn_marca_fecha_local(p_marca_id bigint)` | interna | no | ninguno (dueño) | 86_. Fecha local EFECTIVA de una marca (corrección más reciente si existe, si no momento_dispositivo; más desfase_local). Mismo criterio que fn_dia_calcular_armado_tramos y cierre_dia. |
| `tiempo.fn_tramo_valida_coherencia()` | trigger | sí | ninguno (dueño) | 86_. Las marcas de un tramo deben ser de la persona del día y con fecha local efectiva igual a la del día. SCJ15 / tramo_incoherente. SECURITY DEFINER, search_path = tiempo, pg_temp. |
| `tiempo.fn_jornada_asignada_protege_borrado()` | trigger | no | ninguno explícito (dueño) | BEFORE DELETE en tiempo.jornada_asignada. |
| `tiempo.fn_jornada_asignada_protege_vigencias()` | trigger | no | ninguno explícito (dueño) | BEFORE UPDATE en tiempo.jornada_asignada. |
| `tiempo.fn_jornada_asignada_valida_cadena()` | trigger | no | ninguno explícito (dueño) | CONSTRAINT TRIGGER (DEFERRABLE INITIALLY DEFERRED) sobre tiempo.jornada_asignada -- red de seguridad final al hacer COMMIT: cada persona con al menos una jornada debe quedar con exactamente una fila … |
| `tiempo.fn_jornada_asignar_renovar(p_persona_id uuid, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer, p_confirma_cierre_vigente boolean)` | RPC | no | authenticated | RPC transaccional de "asignar/renovar jornada" (SCJ-PRO-09): si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |
| `tiempo.fn_jornada_en_curso_mover_limite(p_jornada_id bigint, p_vigente_hasta date)` | RPC | no | authenticated | RPC transaccional de "mover el límite de la jornada en curso": cambia vigente_hasta de la jornada vigente hoy a una fecha estrictamente futura, y desplaza vigente_desde de la única jornada siguiente … |
| `tiempo.fn_jornada_futura_actualizar(p_jornada_id bigint, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer)` | RPC | no | authenticated | RPC transaccional de "editar jornada futura": reemplazo TOTAL (no parcial) de tipo_jornada, vigente_desde, descuento de comida y patrón semanal completo, en una sola transacción. |
| `tiempo.fn_jornada_futura_eliminar(p_jornada_id bigint)` | RPC | no | authenticated | RPC transaccional de "eliminar jornada futura": borra el patron_semanal y la fila de jornada_asignada, y si existe una predecesora la reabre (vigente_hasta = NULL). |
| `tiempo.fn_marca_rechazada_purgar(p_dias integer)` | RPC | sí | service_role | SCJ-DEC-12 §6. Único camino de borrado de tiempo.marca_rechazada: elimina las filas con más de p_dias días (por defecto 90, mínimo 7) y devuelve cuántas. SECURITY DEFINER, search_path fijo, EXECUTE só… |
| `tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)` | RPC | sí | service_role | SCJ-DEC-12 §2. Registra un lote (1-200) de marcas de la terminal p_terminal_id y devuelve {momento_recepcion, resultados:[{indice, evento_id, estado, codigo?}]}. Resuelve employee_no a persona_id en l… |
| `tiempo.fn_marca_valida_revision()` | trigger | sí | público | SCJ-PRO-11. |
| `tiempo.fn_movimiento_de_saldo_actualiza_banco()` | trigger | no | público | Única vía de escritura de banco_de_horas.monto y .vivo_desde. |
| `tiempo.fn_movimiento_de_saldo_manual_registrar(p_persona_id uuid, p_tipo character varying, p_monto numeric, p_motivo text)` | RPC | no | authenticated | RPC de registro manual de movimiento_de_saldo (SCJ-DEC-02): arrastrar inserta 2 filas (-monto/+monto, mismo motivo, mismo creado_en) para renovar antigüedad sin cambiar el saldo total -- descontar/co… |
| `tiempo.fn_parametro_actualizar_valor(p_clave character varying, p_valor text, p_registrado_por uuid)` | RPC | no | service_role | RPC transaccional de "actualizar valor de parámetro": vigencia versionada (cierra la activa con hoy - 1 e inserta la nueva; el mismo día corrige en sitio); SCJ02 si no hay vigencia activa. *(89_)* Rechaza con SCJ17 / clave_reservada las claves terminal_%. |
| `tiempo.fn_patron_semanal_solo_jornada_futura()` | trigger | no | ninguno explícito (dueño) | BEFORE UPDATE OR DELETE en tiempo.patron_semanal. |
| `tiempo.fn_patron_semanal_valida_tope_legal()` | trigger | no | público | SCJ-PRO-09. |
| `tiempo.fn_terminal_autenticar(p_hash text, p_ip text)` | RPC | sí | service_role | SCJ-DEC-12 §1/§3. Busca la credencial vigente por hash SHA-256 y la terminal activa; devuelve {terminal_id, serie, credencial_id, ip_cambio} o NULL. Escribe ultimo_uso_en/ultima_ip/ultimo_contacto_en … |
| `tiempo.fn_terminal_baja_por_caducidad(p_horas integer)` | RPC | sí | service_role | SCJ-DEC-12 §12.7. Emite baja_solicitada (origen web, autor = el del movimiento asignado de la alta, detalle "baja automática: sin huella tras N horas") de las altas en esperando_huella cuyo movimiento… |
| `tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)` | RPC | sí | service_role | SCJ-DEC-12 §5. Emite baja_solicitada de las altas de una persona NO activa (suspension, baja_definitiva o inexistente) con autor = el de su último movimiento de suspension/baja_definitiva. Devuelve el… |
| `tiempo.fn_terminal_credencial_revocacion_inmutable()` | trigger | sí | ninguno (dueño) | SCJ-DEC-12 (revisión de security M3). Aborta con SCJ14 (credencial_revocada_inmutable) cualquier cambio de revocada_en sobre una credencial ya revocada, incluido NULL. SECURITY DEFINER, search_path fi… |
| `tiempo.fn_terminal_latido(p_terminal_id bigint, p_hora_terminal timestamp with time zone, p_alcanzable boolean, p_reloj_sincronizado boolean, p_version_pi text, p_marcas_pendientes integer)` | RPC | sí | service_role | SCJ-DEC-12 §3. Guarda terminal_alcanzable, reloj_desfase_seg (terminal menos servidor), version_pi y marcas_pendientes en tiempo.terminal y devuelve {hora_servidor, desfase_reloj_seg, ultima_secuencia… |
| `tiempo.fn_terminal_mapa(p_terminal_id bigint)` | RPC | sí | service_role | SCJ-DEC-12 §3. Arreglo jsonb de las altas no-baja de la terminal: terminal_usuario_id, employee_no, estado, huellas_capturadas. Sin persona_id ni nombres. SECURITY DEFINER, EXECUTE sólo service_role. |
| `tiempo.fn_terminal_movimiento_registrar(p_terminal_id bigint, p_terminal_usuario_id bigint, p_tipo text, p_huellas integer, p_detalle text)` | RPC | sí | service_role | SCJ-DEC-12 §3. Movimiento del Pi (usuario_creado, huella_capturada, baja_confirmada, error) sobre una alta de la terminal p_terminal_id. FOR UPDATE de la alta; no_encontrado si no existe o es de otra … |
| `tiempo.fn_terminal_rechazo_registrar(p_terminal_id bigint, p_evento jsonb, p_codigo text)` | interna | sí | ninguno (dueño) | Interna (SCJ-DEC-12 §6). Guarda en tiempo.marca_rechazada la evidencia de un rechazo definitivo de fn_marca_terminal_registrar, leyendo cada campo del evento de forma defensiva (sólo lo que cumple su … |
| `tiempo.fn_terminal_valida_desactivacion()` | trigger | sí | ninguno (dueño) | SCJ-DEC-12 §6. Aborta con SCJ13 (terminal_con_altas_vigentes) si se desactiva una terminal que aún tiene altas no-baja. Toma la fila de la terminal FOR UPDATE antes de contar (serializa con 'asignado'… |
| `tiempo.fn_tope_legal_crear_vigencia(p_vigente_desde date, p_maximo_semanal numeric, p_maximo_extra numeric, p_confirma_cierre_vigente boolean)` | RPC | no | service_role | RPC transaccional de "crear vigencia de tope legal": si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |
| `tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)` | RPC | sí | authenticated | 89_. Edita una de las 5 claves terminal_* de tiempo.parametro: persona activa y terminal_config_edicion dentro (42501/sin_permiso), lista blanca (22023/clave_no_editable), entero en su rango y regla traslape*2 <= antigüedad_meses*30 (22023/valor_invalido); autor de auth.uid(); versiona por vigencia. Devuelve {resultado: actualizada \| sin_cambio, clave, valor, vigente_desde}. SECURITY DEFINER, search_path = tiempo, personas, pg_temp. |
| `tiempo.fn_terminal_config_catalogo()` | RPC | no | authenticated,service_role | 89_. Valor por defecto y rango (mínimo, máximo) de las 5 claves terminal_*; única fuente para el RPC de edición y el lector. Datos no sensibles. |
| `tiempo.fn_terminal_config_valor(p_clave text)` | RPC | sí | service_role | 89_. Valor vigente de una clave terminal_* para los jobs del backend, acotado al rango; si falta o está mal formado devuelve el valor por defecto; NULL si la clave no es del catálogo. Nunca falla por un parámetro corrupto. SECURITY DEFINER, search_path = tiempo, pg_temp. |
| `tiempo.fn_terminal_consentimiento_inmutable()` | trigger | no | ninguno (dueño) | 88_. Aborta UPDATE/DELETE sobre tiempo.terminal_consentimiento, incluido service_role y el dueño. |
| `tiempo.fn_terminal_consentimiento_publicar(p_texto text, p_cambio_material boolean, p_nota text, p_base_version integer)` | RPC | sí | authenticated | 88_. Publica una versión nueva del texto de consentimiento: persona activa y terminal_config_edicion dentro (42501/sin_permiso), autor de auth.uid(), saneado (1 a 4000 caracteres, 22023/texto_invalido), LOCK de tabla y numeración; si p_base_version no es la vigente, SCJ16 / version_base_desactualizada (publicación concurrente). 'sin_cambio' si el texto es igual al de la vigente definitiva; si la anterior era provisional fuerza cambio_material. Devuelve {resultado, id, version, cambio_material, pendientes}. SECURITY DEFINER, search_path = tiempo, personas, pg_temp. |
| `tiempo.fn_terminal_consentimiento_truncate()` | trigger | no | ninguno (dueño) | 88_. Aborta TRUNCATE sobre tiempo.terminal_consentimiento (trigger por statement). |
| `tiempo.fn_terminal_reconsentimiento_pendiente_ids()` | RPC | no | authenticated,service_role | 88_. Ids de tiempo.terminal_usuario con reconsentimiento pendiente (pendiente_alta, esperando_huella o activo con una versión menor que la última con cambio_material). Definición única; SECURITY INVOKER, la RLS de terminal_usuario sigue aplicando. |
| `tiempo.fn_terminal_reconsentir(p_altas bigint[], p_consentimiento_id bigint, p_estricto boolean)` | RPC | no | authenticated | 88_. Registra un 'reconsentido' por cada alta del lote (hasta 200) con el reconsentimiento pendiente; las demás se devuelven en omitidas, con su motivo fijo en motivos_omision (alta_propia | no_elegible) — la alta PROPIA del llamador no se reconsiente salvo que sea el administrador genérico — (con p_estricto = true se rechaza todo el lote si hay alguna: 22023 / lote_no_elegible, ids en DETAIL). Exige que p_consentimiento_id sea la vigente (SCJ16). Exige persona activa y `terminal_usuario_edicion` (42501 / sin_permiso). Todo o nada. SECURITY INVOKER: la policy de INSERT de la bitácora es la autorización real. El detalle fijo ('reconsentimiento recabado: versión N') lo pone el trigger. |
| `personas.fn_usuario_es_administrador_generico(p_auth_user_id uuid)` | interna | no | ninguno (dueño) | 88_. true si el usuario ocupa HOY (asignación vigente, sin herencia) un puesto con es_administrador_generico; excepción de la regla de auto-asignación a una terminal. Interna del trigger de la bitácora; sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp. |
| `personas.fn_caller_es_administrador_generico()` | RPC | sí | authenticated | 88_. Envoltorio sin parámetro de fn_usuario_es_administrador_generico(auth.uid()): true si el llamador ocupa HOY un puesto con es_administrador_generico. Sólo datos propios; lo usa el lote de reconsentimientos (corre como el llamador). SECURITY DEFINER, search_path = personas, pg_temp. |
| `personas.fn_caller_persona_id()` | RPC | sí | authenticated | 88_. Envoltorio sin parámetro de fn_persona_de_usuario(auth.uid()): persona del llamador; NULL si no tiene usuario. Sólo datos propios. SECURITY DEFINER, search_path = personas, pg_temp. |
| `personas.fn_persona_de_usuario(p_auth_user_id uuid)` | interna | no | ninguno (dueño) | 88_. Persona de un usuario (auth_user_id); NULL si no tiene. Interna del trigger de la bitácora (el actor sale de NEW.registrado_por, atado a auth.uid() por la policy); sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp. |
| `tiempo.fn_terminal_anomalias(p_terminal_id bigint, p_categoria text, p_desde timestamp with time zone, p_hasta timestamp with time zone, p_limite integer, p_desplazamiento integer)` | RPC | no | service_role | 90_. Una categoría del tablero de anomalías de una terminal (marcas_posteriores_a_baja, picos_de_tasa, huecos_de_secuencia) como {total, items} paginado. Filtra siempre por la terminal pedida dentro; devuelve persona_id, nunca nombres (SCJ-FRO-01). Ventana de a lo más 90 días; umbrales fijos 10 marcas/h por persona y 1 000/h por terminal. SECURITY INVOKER, STABLE, search_path = tiempo, pg_temp; EXECUTE sólo service_role. 22023: terminal_invalida, categoria_invalida, ventana_invalida, paginacion_invalida. |

Las funciones con `público` = no revocado incluyen triggers (no se invocan directo) y `fn_caller_activo` / `fn_caller_tiene_permiso`, que las policies RLS necesitan. Las RPC con `EXECUTE` revocado a `PUBLIC` se ejecutan sólo por el rol indicado.

### V.2 Políticas RLS

Las 35 tablas tienen RLS habilitada y ninguna la tiene forzada (`FORCE`). El detalle de cada policy (comando, roles, condición, truncada a 260 caracteres) está en la sección de su tabla en II. Resumen:

| Tabla | Policies |
|---|---|
| `tiempo.persona` | 1 (1 SELECT) |
| `tiempo.tope_legal` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.dia_festivo` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.parametro` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.jornada_asignada` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.patron_semanal` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.marca` | 3 (2 INSERT, 1 SELECT) |
| `tiempo.dia` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.tramo` | 3 (1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.clasificacion_de_tiempo` | 1 (1 SELECT) |
| `tiempo.banco_de_horas` | 1 (1 SELECT) |
| `tiempo.movimiento_de_saldo` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.correccion` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.ausencia` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.aprobacion_ausencia` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.excepcion` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.corrida_batch` | 1 (1 SELECT) |
| `tiempo.terminal` | 1 (1 SELECT) |
| `tiempo.terminal_usuario` | 1 (1 SELECT) |
| `tiempo.bitacora_movimiento_terminal_usuario` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.terminal_credencial` | 0 — sin policy: nadie de la API la lee (sólo `service_role`, que no pasa por RLS) |
| `tiempo.marca_rechazada` | 1 (1 SELECT) |
| `tiempo.excepcion_descarte` | 1 (1 SELECT) |
| `tiempo.terminal_consentimiento` | 1 (1 SELECT) |
| `personas.persona` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.expediente` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.usuario` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.bitacora_movimiento_persona` | 2 (1 INSERT, 1 SELECT) |
| `personas.area` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.departamento` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.puesto` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.asignacion` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.permiso` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.puesto_permiso` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `personas.bitacora_movimiento_puesto_permiso` | 2 (1 INSERT, 1 SELECT) |

Observaciones verificadas en el catálogo:

- Sin policy (deny-by-default): `tiempo.dia_festivo`, `tiempo.parametro`, `tiempo.tope_legal` y *(V1.3)* `tiempo.terminal_credencial`. Se acceden por `service_role` o por RPC.
- Privilegios de tabla: `tiempo.marca`, `tiempo.correccion`, `tiempo.movimiento_de_saldo` y las dos bitácoras (`personas.bitacora_movimiento_*`) sólo tienen `INSERT`/`SELECT` (sin `UPDATE`/`DELETE`) para `anon`/`authenticated`; `personas.bitacora_movimiento_persona` y `bitacora_movimiento_puesto_permiso` además están protegidas por triggers de inmutabilidad. `tiempo.excepcion` no tiene privilegios para `anon`. `terminal_checador` sólo tiene `INSERT` sobre `tiempo.marca`.
- *(V1.3)* Contrastado en la base real (2026-10-06): `terminal_credencial` sólo da `SELECT`, `INSERT` a `service_role` (más `UPDATE` de 3 columnas); `marca_rechazada` da `SELECT` a `authenticated` y `service_role` y **no da `INSERT` a nadie**; `terminal` da `SELECT` a `authenticated` y `SELECT`, `INSERT` a `service_role` (más `UPDATE` de 4 columnas). Ninguna de las 5 tablas de la terminal tiene `DELETE`, `TRUNCATE` ni acceso para `anon`, y `terminal_checador` (el rol del lector R503Pro) no tiene privilegios sobre ellas. Todas las funciones nuevas con `EXECUTE` lo tienen sólo `service_role`; las de trigger y la interna `fn_terminal_rechazo_registrar` no lo tienen nadie de la API.
- Las 3 tablas de la terminal (`80`/`81`) son la primera excepción deliberada al `GRANT ALL` schema-wide de `38_tiempo_permisos.sql`: cada una hace `REVOKE ALL` a `anon`, `authenticated` y `service_role` y vuelve a conceder sólo lo necesario (ver su sección en II). `anon` no tiene ningún privilegio sobre ellas; la secuencia `tiempo.seq_terminal_employee_no` y las 3 secuencias de identidad tampoco son accesibles a ningún rol de la API.
- El resto de las tablas conserva `DISU` para `anon`/`authenticated` a nivel de privilegio (la barrera real es RLS).
- Roles de plataforma esperados (no creados por el DDL): `anon`, `authenticated`, `service_role`, `authenticator`; el DDL crea `terminal_checador`.

### V.3 Códigos de error propios (`ERRCODE 'SCJnn'`) *(V1.3)*

El DDL define sus propios `SQLSTATE` para que el backend distinga el caso sin leer el texto del error (el texto nunca se retransmite al Pi). Cada excepción de la terminal trae además un `HINT` con un token estable. Los `SCJ01`-`SCJ10` son anteriores (`SCJ-PRO-07` a `SCJ-PRO-14`, `personas`); los de la terminal:

| `SQLSTATE` | `HINT` | Dónde | Significa |
|---|---|---|---|
| `SCJ11` | `transicion_invalida` | `fn_bitacora_terminal_usuario_aplica`, `fn_terminal_movimiento_registrar` | Transición de estado inválida, o la fila viva no coincide con el movimiento |
| `SCJ12` | `alta_duplicada` | `fn_bitacora_terminal_usuario_aplica` | La persona ya tiene un alta vigente en esa terminal |
| `SCJ12` | `persona_no_activa` | `fn_bitacora_terminal_usuario_aplica` | La persona no existe o no está `activo` |
| `SCJ12` | `terminal_no_valida` | `fn_bitacora_terminal_usuario_aplica`, `fn_marca_terminal_registrar`, `fn_terminal_latido` | La terminal no existe o no está activa |
| `SCJ13` | `terminal_con_altas_vigentes` | `fn_terminal_valida_desactivacion` (trigger) | No se puede desactivar una terminal con altas no-`baja` |
| `SCJ14` | `credencial_revocada_inmutable` | `fn_terminal_credencial_revocacion_inmutable` (trigger) | Una revocación de llave ya fijada no se puede deshacer ni cambiar |
| `SCJ15` | `dia_cerrado_requiere_revision` | `fn_excepcion_protege_dia_cerrado` (constraint trigger, al `COMMIT`) | Una excepción `dia_cerrado` sólo se resuelve revisando el día en la misma transacción o descartando la marca tardía. Backend: 409 |
| `SCJ15` | `excepcion_columna_inmutable` / `excepcion_motivo_inmutable` | `fn_excepcion_protege_columnas` (trigger) | Se intentó cambiar `marca_id`/`dia_id`/`creado_en`, o el motivo de otra forma que agregando un sufijo al resolver |
| `SCJ15` | `tramo_incoherente` | `fn_tramo_valida_coherencia` (trigger) | Un tramo con marcas de otra persona o de otra fecha local efectiva que su día. Backend: 422 |
| `SCJ12` | `auto_reconsentimiento_prohibido` | `fn_bitacora_terminal_usuario_aplica` (trigger) | La alta cuyo reconsentimiento se registra es la del propio llamador y éste no ocupa un puesto con `es_administrador_generico` (misma regla y excepción que la auto-asignación; pedir la propia baja sí se puede). Backend: 422 |
| `SCJ12` | `auto_asignacion_prohibida` | `fn_bitacora_terminal_usuario_aplica` (trigger) | La persona asignada es la del propio llamador y éste no ocupa un puesto con `es_administrador_generico`. Backend: 422 |
| `SCJ16` | `consentimiento_desactualizado` | `fn_bitacora_terminal_usuario_aplica` (trigger), `fn_terminal_reconsentir` | La versión enviada en 'asignado'/'reconsentido' no es la vigente. Backend: 409, mensaje fijo "El texto de consentimiento cambió; vuelve a leerlo" y devolver el texto vigente |
| `SCJ16` | `version_base_desactualizada` | `fn_terminal_consentimiento_publicar` | Se mandó p_base_version y otra persona publicó una versión nueva mientras tanto (publicación concurrente). Backend: 409 |
| `SCJ16` | `consentimiento_requerido` | `fn_bitacora_terminal_usuario_aplica` (trigger) | 'asignado'/'reconsentido' sin consentimiento_id. Backend: 422 |
| `SCJ16` | `migracion_con_filas` | guarda de `88_` | 88_ aborta si terminal_usuario o su bitácora tienen filas (la bitácora es inmutable) |
| `SCJ17` | `clave_reservada` | `fn_parametro_actualizar_valor` | Clave terminal_% por la ruta genérica de Parámetros; sólo `fn_terminal_config_actualizar`. Backend: 409 |
| `42501` | `sin_permiso` | `fn_terminal_consentimiento_publicar`, `fn_terminal_config_actualizar` | Falta persona activa o terminal_config_edicion. Backend: 403 |
| `22023` | `lote_no_elegible` | `fn_terminal_reconsentir` | Con p_estricto = true, el lote trae altas sin el reconsentimiento pendiente (ids en DETAIL). Backend: 409 |
| `22023` | `terminal_invalida` / `categoria_invalida` / `ventana_invalida` / `paginacion_invalida` | `fn_terminal_anomalias` | Terminal inexistente, categoría fuera de las 3, ventana nula/invertida/de más de 90 días, o paginación fuera de rango. Backend: 422 |
| `22023` | `texto_invalido` / `nota_invalida` / `lote_invalido` | `fn_terminal_consentimiento_publicar`, `fn_terminal_reconsentir` | Texto fuera de 1 a 4000 caracteres, nota de más de 200, o lote de reconsentimientos vacío/NULL/de más de 200. Backend: 422 |
| `22023` | `clave_no_editable` / `valor_invalido` | `fn_terminal_config_actualizar` | Clave fuera de la lista blanca; valor no entero, fuera de rango o que rompe traslape*2 <= antigüedad_meses*30. Backend: 422 |
| `SCJ15` | `marca_en_tramo` | `fn_correccion_bloquea_marca_en_tramo` (trigger) | Se intentó corregir la hora de una marca que ya es apertura o cierre de un tramo (cerrado o abierto). Backend: 409 |
| `SCJ15` | `dia_no_revisado` / `excepcion_no_descartable` | `fn_excepcion_dia_cerrado_descartar` | El día de la marca no está revisado, o la excepción no es una `dia_cerrado` de marca pendiente (o ya está resuelta por otra vía). Backend: 409 |
| `42501` | `sin_permiso` | `fn_excepcion_dia_cerrado_descartar` | Falta persona activa o el permiso `excepcion_dia_cerrado_descarte`. Backend: 403 |
| `22023` | `motivo_invalido` | `fn_excepcion_dia_cerrado_descartar` | Motivo vacío. Backend: 422 |
| `22023` | `lote_invalido` | `fn_marca_terminal_registrar` | El lote no es un arreglo, está vacío o excede 200 eventos |
| `22023` | `huellas_invalidas` | `fn_terminal_movimiento_registrar` | Conteo de huellas fuera de 1-10 |
| `22023` | `retencion_invalida` | `fn_marca_rechazada_purgar` | Retención menor al mínimo de 7 días |
| `22023` | `horas_invalidas` | `fn_terminal_baja_por_caducidad` | Horas de caducidad menores al mínimo de 4 (o NULL) |

`22023` es el código estándar `invalid_parameter_value`, no uno propio; se lista aquí porque el backend lo distingue por su `HINT`. Los códigos de resultado por evento de `fn_marca_terminal_registrar` (`confirmado`, `duplicado`, `rechazo_definitivo`/`rechazo_transitorio` con su `codigo`) no son errores SQL: viajan en el `jsonb` de respuesta (`SCJ-CDT-01 §IX.6`).

---

## Nota de método

1. Se leyeron los 80 scripts de `db/ddl/` (`00_esquemas.sql` a `79_*.sql`), `db/verificar_ddl.sql`, `SCJ-MOD-02`, `SCJ-MOD-03`, `CLAUDE.md` y `docs/03-decisiones/`.
2. Se levantó un contenedor PostgreSQL 16 nuevo y efímero (nombre propio, puerto 55439, borrado al terminar) con stubs mínimos de Supabase: roles `anon`, `authenticated`, `service_role` (BYPASSRLS), `authenticator`; esquema `auth` (`users`, `uid()`, `role()`) y `storage` (`buckets`, `objects`). Los 80 scripts corrieron en orden sin un solo error. Resultado: personas = 11, tiempo = 17, 49 permisos, 8 parámetros: coincide con `db/verificar_ddl.sql`. No se tocó ninguna base real, servidor ni Supabase.
3. Un script Python consultó `pg_catalog` (columnas, restricciones, índices, triggers, policies, privilegios, funciones) y generó las secciones II a V. Las descripciones son los `COMMENT ON` textuales; las columnas sin comentario se marcan como tales.
4. **No se verificó contra una BD viva** (producción/dev): el estado es el que produce el DDL, no el de la base real. Los stubs de Supabase pueden diferir de la plataforma (privilegios por omisión de `anon`/`authenticated` en esquemas nuevos, `search_path`, extensiones). Los privilegios por tabla reportados son los del contenedor de prueba tras aplicar los scripts. No se leyó el código del backend: las notas de "consumo en backend" vienen de comentarios y documentos. Las expresiones `CHECK`/`USING` se muestran simplificadas (se quitaron casts).

5. **V1.2 (6-oct-2026):** las secciones de `tiempo.terminal`, `tiempo.terminal_usuario` y `tiempo.bitacora_movimiento_terminal_usuario` se escribieron a partir de los scripts `80` y `81` y de sus `COMMENT ON`, y se contrastaron con la base real de Supabase (no con un contenedor desechable) mediante `db/verificar_ddl.sql` y un ensayo con `ROLLBACK` (61 casos, 61 aprobados); el resto del diccionario no se regeneró y conserva el método de V1.1. Los conteos globales (39 funciones, 74 policies, 23 dominios cerrados, 51 permisos) suman lo que aportan `80` y `81` a los de V1.1.
6. **V1.3 (6-oct-2026):** las secciones de `tiempo.terminal_credencial` y `tiempo.marca_rechazada`, las 4 columnas nuevas de `tiempo.terminal` y las 11 funciones nuevas se escribieron a partir de los scripts `82` a `85` Y se contrastaron contra la base real de Supabase en solo lectura: columnas, tipos, nulos y predeterminados (`information_schema`), restricciones, índices y triggers (`pg_constraint`, `pg_indexes`, `pg_trigger`), privilegios de tabla y de columna (`has_table_privilege`, `has_column_privilege`), `EXECUTE`, `SECURITY DEFINER` y `proconfig` por función (`pg_proc`), y las 75 policies (`pg_policies`). Las descripciones de columnas y funciones son los `COMMENT ON` leídos de la base. **Hallazgo del contraste y su cierre:** el 6-oct el catálogo real tenía 49 funciones, no 50: faltaba `78_tiempo_excepcion_protege_dia_cerrado.sql`, que el usuario aplicó el 7-oct sin ensayo; cubría sólo el `UPDATE` suelto de una excepción `dia_cerrado` y `security` identificó dos evasiones (cambiar primero el motivo y resolver después; sembrar un tramo falso por la vía de escritura de `tramo`). El cierre es `86_tiempo_excepcion_protege_dia_cerrado_v2.sql`: ensayado con `BEGIN … ROLLBACK` (100 casos, 100 aprobados), revisado por `security` y aplicado por el usuario el 7-oct-2026; tras aplicarlo, `db/verificar_ddl.sql` completo dio 0 filas en todas las secciones y el diagnóstico de solo lectura dio 0 `dia_cerrado` resueltas sin tramo ni descarte y 0 motivos alterados. **Residuales aceptados (B2 de `security`):** `dia_update_revision` (`62_`/`77_`) deja a quien tenga `dia_revision_edicion` pasar un día bloqueado/cerrado a `revisado` por PostgREST directo sin armar tramos; quien tenga además `excepcion_dia_cerrado_descarte` puede marcar el día revisado y descartar la marca tardía. Queda auditado (`revisado_por`/`revisado_en` y la fila de `excepcion_descarte`) y exige dos permisos explícitos; revisar cuando se endurezca `tiempo.dia`. Además, una marca con DOS excepciones pendientes (p. ej. `reloj_no_sincronizado` y `dia_cerrado`) no se puede corregir hasta revisar el día. Conteos finales tras `87_`: 34 tablas, 57 funciones, 76 policies, 52 permisos, 88 scripts. **`87_`** (ensayo 47/47 con `ROLLBACK`, revisado por `security`) bloquea en la base la corrección de una marca ya incluida en un tramo, porque por la API el recálculo de `fn_correccion_recalcula_tramo` (INVOKER) afectaba 0 filas por RLS en tramos cerrados y fallaba con 42501 en abiertos, mientras que como dueño o `service_role` pisaba las horas manuales de RH y el descuento de pausa. Consecuencia de producto: después de `cierre_dia` casi ninguna marca es corregible por esta vía hasta que exista un RPC dedicado. El resto del diccionario no se regeneró y conserva el método de V1.1. Las 24 columnas con dominio cerrado suman la nueva de `marca_rechazada.codigo` a las 23 de V1.2.

### Discrepancias entre el DDL y SCJ-MOD-03 (V1.5; hoy V1.9, ver nota de estado)

> **Estado (5-oct-2026):** las discrepancias 1 a 12 se corrigieron en `SCJ-MOD-03` V1.6. Siguen abiertas la 13 (cuenta de tablas en `SCJ-MOD-02`) y la 14 (los `COMMENT ON` obsoletos viven en el DDL: corregirlos exige un script nuevo).

1. **Alcance:** `SCJ-MOD-03` sólo cubre `tiempo` y llega a `02`/`03`; no menciona el esquema `personas` (11 tablas), RLS (70 policies), las RPC ni los scripts `04` a `79`. Su pie dice "V1.1" aunque el encabezado dice V1.5.
2. **§I archivos:** lista `00`-`03` y `db/indices/01_indices.sql`; el DDL real son 80 scripts, y los índices de FK están además en `30_indices_fk.sql`.
3. **§II `btree_gist`:** se declara extensión requerida, pero ningún script ejecuta `CREATE EXTENSION` (el comentario de `00_esquemas.sql` dice "y las extensiones requeridas", sin crearlas) y no hay ninguna restricción `EXCLUDE`.
4. **§III identificadores:** dice que `tiempo.persona.id` es la única excepción a `bigint IDENTITY`; en realidad todas las tablas de `personas` usan `uuid` (`gen_random_uuid()`) y `personas.permiso` usa `codigo` como PK.
5. **§III duraciones:** "`numeric(6,2)`" no es uniforme: `dia.horas_totales` y `patron_semanal.horas_efectivas` son `numeric(5,2)`; `banco_de_horas.monto` y `movimiento_de_saldo.monto` son `numeric(8,2)`.
6. **§IV/§V traslape de vigencias (`SCJ-DEC-04`, "en la aplicación"):** hoy la base también protege `jornada_asignada`: `trg_jornada_asignada_valida_cadena` (CONSTRAINT TRIGGER diferido: una sola fila abierta, sin huecos ni traslapes), `protege_vigencias` y `protege_borrado`. `tope_legal` sigue sin protección de traslape en la base (sólo UK en `vigente_desde`; hay RPC `fn_tope_legal_crear_vigencia`).
6b. **V1.4 (8-oct-2026):** las secciones y filas de `88_`, `89_` y `90_` (tabla `tiempo.terminal_consentimiento`, columna `consentimiento_id` en la bitácora y en la tabla viva, tipo `reconsentido`, 5 claves `terminal_*`, 9 funciones nuevas, columna `usuario_creado_en`, `SCJ16`/`SCJ17`, permiso `terminal_config_edicion`) se escribieron a partir de los scripts y de sus `COMMENT ON`, ensayados con `BEGIN … ROLLBACK` el 8-oct-2026 (`db/ensayos/ensayo_88.sql` 143/143, `ensayo_89.sql` 60/60 y `ensayo_90.sql` 21/21) **antes** de aplicarse; no se contrastaron aún contra el catálogo real. Al aplicar se corrige este documento con lo que muestre `db/verificar_ddl.sql` (secciones 46 a 53).
7. **§IV/§V inmutabilidad de `marca`:** dice que no hay restricción por permisos; hoy `marca` no tiene `UPDATE`/`DELETE` para `anon`/`authenticated`/`service_role` (sólo `IS`).
8. **§IV `banco_de_horas`:** "sin restricción de base" sigue siendo cierto a nivel de privilegio (`DISU`), pero la tabla tiene RLS y trigger único de escritura vía `movimiento_de_saldo`.
9. **§IV tope legal:** el CONSTRAINT TRIGGER está en `patron_semanal` y es `AFTER INSERT OR UPDATE`; además existe `trg_patron_semanal_solo_jornada_futura` (no documentado).
10. **§V `clasificacion_de_tiempo.tipo`:** "disparador pendiente de programar": sigue sin trigger; la clasificación entra por la RPC `fn_corte_quincenal_aplicar_persona` (`57`), no documentada en `MOD-03`.
11. **§IV `fn_marca_valida_revision`:** `72` agrega el motivo `fuera_de_horario` (alerta de horario, `genera_alerta_horario`); `MOD-03` sólo describe 4 de 5 motivos sin nombrarlos.
12. **Columnas posteriores no reflejadas:** `parametro.vigente_hasta`/`registrado_por` (`60`), columnas de revisión en `dia` (`62`, `63`), `jornada_asignada.genera_alerta_horario` y otras (ver sección II de cada tabla).
13. **Cuenta de tablas:** `SCJ-MOD-02` V2.2 y las notas de la V1.0 de este diccionario hablaban de 16 tablas; hay 17 en `tiempo` con el stub (16 sin él).
14. **Comentarios obsoletos en el DDL:** el `COMMENT` de `tiempo.parametro` (`03`) remite a "el comentario completo en `02_tiempo.sql`" y a "`SCJ-DIC-01 §IV`", pero el de `03` sobrescribió al de `02`; el de `tiempo.persona` dice "en este proyecto lo puebla el generador de datos sintéticos", del proyecto escolar. La V1.0 de este diccionario decía además `tiempo.persona.id bigint`; es `uuid`.

### No determinado

- Descripción de las columnas sin `COMMENT ON` (la mayoría de las columnas simples; marcadas en cada tabla).
- Motivos de revisión de excepciones de día (`dia_id`) y el valor exacto de `motivo_revision` que escribe el backend.
- Estado real de privilegios y policies en la base viva; consumo real de los parámetros en el backend.
- Cuerpo íntegro de las funciones (sólo se resumen sus comentarios).

---

*Diccionario de datos · Folio SCJ-DIC-01 · V1.4*
