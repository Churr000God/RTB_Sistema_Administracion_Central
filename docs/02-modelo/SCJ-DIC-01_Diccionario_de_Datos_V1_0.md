# Diccionario de datos

**Sistema de Control de Jornada · Esquemas `personas` y `tiempo`**
Folio SCJ-DIC-01 · Versión 1.1 · 5 de octubre de 2026

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

### Esquema `tiempo` — 17 tablas

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

Total: **28 tablas** (11 + 17), coincide con lo que espera `db/verificar_ddl.sql` (personas = 11, tiempo = 17). Ninguna vista, ninguna vista materializada, ningún tipo `ENUM`. `tiempo.persona` es el stub de la frontera (`SCJ-FRO-01`); sin él, `tiempo` tendría 16 tablas propias.

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
| `momento_recepcion` | `timestamp with time zone` | No | `now()` | — | Cuándo llegó al servidor. Nunca se usa para calcular jornada — sólo mide retraso de sincronización (SCJ-CDT-01 §V.4). |
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

**Triggers:** —

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
- `trg_excepcion_protege_dia_cerrado`: AFTER UPDATE → `tiempo.fn_excepcion_protege_dia_cerrado()` (CONSTRAINT TRIGGER, DEFERRABLE)

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

No existe ningún `CREATE TYPE ... AS ENUM` en `personas` ni `tiempo` (consulta a `pg_type`: 0). Todos los dominios cerrados son `varchar(N)` con `CHECK`, como decide `SCJ-MOD-03 §III`. Los 20 reales:

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

Fuente: `db/ddl/03_parametros_ejemplo.sql` (8 filas, `vigente_desde = 2026-01-01`, `vigente_hasta` y `registrado_por` NULL). Ningún script posterior inserta ni cambia claves; `60_tiempo_parametro_vigencia_y_autor.sql` sólo agregó `vigente_hasta`/`registrado_por` y el RPC `fn_parametro_actualizar_valor`. **Todos los valores son de ejemplo**, no de operación (el propio archivo lo declara). `valor` es `text`: el tipo lógico (entero/hora) no está en la base.

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

Las columnas "backend" se apoyan en comentarios del DDL, en `CLAUDE.md` y en `SCJ-PRO-12`; no se verificó el código del backend para este documento. Otros datos que cargan los scripts (no son parámetros): catálogo `personas.permiso` (49 filas, `25`, `33`, `35`, `45`), áreas/departamentos/puestos iniciales (`11`, `13`, `15`, `16`) y el bucket `expedientes` (`07`).

---

## V. Funciones, RPC y políticas RLS

### V.1 Funciones (36)

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
| `tiempo.fn_correccion_recalcula_tramo()` | trigger | no | público | SCJ-PRO-10. |
| `tiempo.fn_correccion_valida()` | trigger | no | público | SCJ-PRO-10. |
| `tiempo.fn_corte_quincenal_aplicar_persona(p_persona_id uuid, p_clasificaciones jsonb, p_movimientos jsonb, p_motivo text)` | RPC | no | service_role | RPC transaccional de "aplicar corte quincenal a una persona" (SCJ-PRO-13): inserta todas las clasificaciones del periodo, resuelve/crea banco_de_horas, e inserta todos los movimientos de saldo corres… |
| `tiempo.fn_dia_calcular_armado_tramos(p_dia_id bigint)` | RPC | no | authenticated,service_role | Calcula (sin escribir) qué haría fn_dia_revisar al armar los tramos faltantes de un día: una fila por acción -- cerrar_existente (cierra un tramo abierto con una huérfana), nuevo (arma un tramo nuevo… |
| `tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)` | RPC | no | authenticated | RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH. |
| `tiempo.fn_excepcion_protege_dia_cerrado()` | trigger | sí | ninguno explícito (dueño) | Constraint trigger de sólo motivo dia_cerrado: bloquea (revirtiendo toda la transacción, por DEFERRABLE INITIALLY DEFERRED) cualquier pendiente -> resuelto que no sea efecto colateral real de fn_dia_… |
| `tiempo.fn_jornada_asignada_protege_borrado()` | trigger | no | ninguno explícito (dueño) | BEFORE DELETE en tiempo.jornada_asignada. |
| `tiempo.fn_jornada_asignada_protege_vigencias()` | trigger | no | ninguno explícito (dueño) | BEFORE UPDATE en tiempo.jornada_asignada. |
| `tiempo.fn_jornada_asignada_valida_cadena()` | trigger | no | ninguno explícito (dueño) | CONSTRAINT TRIGGER (DEFERRABLE INITIALLY DEFERRED) sobre tiempo.jornada_asignada -- red de seguridad final al hacer COMMIT: cada persona con al menos una jornada debe quedar con exactamente una fila … |
| `tiempo.fn_jornada_asignar_renovar(p_persona_id uuid, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer, p_confirma_cierre_vigente boolean)` | RPC | no | authenticated | RPC transaccional de "asignar/renovar jornada" (SCJ-PRO-09): si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |
| `tiempo.fn_jornada_en_curso_mover_limite(p_jornada_id bigint, p_vigente_hasta date)` | RPC | no | authenticated | RPC transaccional de "mover el límite de la jornada en curso": cambia vigente_hasta de la jornada vigente hoy a una fecha estrictamente futura, y desplaza vigente_desde de la única jornada siguiente … |
| `tiempo.fn_jornada_futura_actualizar(p_jornada_id bigint, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer)` | RPC | no | authenticated | RPC transaccional de "editar jornada futura": reemplazo TOTAL (no parcial) de tipo_jornada, vigente_desde, descuento de comida y patrón semanal completo, en una sola transacción. |
| `tiempo.fn_jornada_futura_eliminar(p_jornada_id bigint)` | RPC | no | authenticated | RPC transaccional de "eliminar jornada futura": borra el patron_semanal y la fila de jornada_asignada, y si existe una predecesora la reabre (vigente_hasta = NULL). |
| `tiempo.fn_marca_valida_revision()` | trigger | sí | público | SCJ-PRO-11. |
| `tiempo.fn_movimiento_de_saldo_actualiza_banco()` | trigger | no | público | Única vía de escritura de banco_de_horas.monto y .vivo_desde. |
| `tiempo.fn_movimiento_de_saldo_manual_registrar(p_persona_id uuid, p_tipo character varying, p_monto numeric, p_motivo text)` | RPC | no | authenticated | RPC de registro manual de movimiento_de_saldo (SCJ-DEC-02): arrastrar inserta 2 filas (-monto/+monto, mismo motivo, mismo creado_en) para renovar antigüedad sin cambiar el saldo total -- descontar/co… |
| `tiempo.fn_parametro_actualizar_valor(p_clave character varying, p_valor text, p_registrado_por uuid)` | RPC | no | service_role | RPC transaccional de "actualizar valor de parámetro": si no hay vigencia activa con esa clave, señaliza con RAISE EXCEPTION ... |
| `tiempo.fn_patron_semanal_solo_jornada_futura()` | trigger | no | ninguno explícito (dueño) | BEFORE UPDATE OR DELETE en tiempo.patron_semanal. |
| `tiempo.fn_patron_semanal_valida_tope_legal()` | trigger | no | público | SCJ-PRO-09. |
| `tiempo.fn_tope_legal_crear_vigencia(p_vigente_desde date, p_maximo_semanal numeric, p_maximo_extra numeric, p_confirma_cierre_vigente boolean)` | RPC | no | service_role | RPC transaccional de "crear vigencia de tope legal": si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |

Las funciones con `público` = no revocado incluyen triggers (no se invocan directo) y `fn_caller_activo` / `fn_caller_tiene_permiso`, que las policies RLS necesitan. Las RPC con `EXECUTE` revocado a `PUBLIC` se ejecutan sólo por el rol indicado.

### V.2 Políticas RLS

Las 28 tablas tienen RLS habilitada y ninguna la tiene forzada (`FORCE`). El detalle de cada policy (comando, roles, condición, truncada a 260 caracteres) está en la sección de su tabla en II. Resumen:

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

- Sin policy (deny-by-default): `tiempo.dia_festivo`, `tiempo.parametro`, `tiempo.tope_legal`. Se acceden por `service_role` o por RPC.
- Privilegios de tabla: `tiempo.marca`, `tiempo.correccion`, `tiempo.movimiento_de_saldo` y las dos bitácoras (`personas.bitacora_movimiento_*`) sólo tienen `INSERT`/`SELECT` (sin `UPDATE`/`DELETE`) para `anon`/`authenticated`; `personas.bitacora_movimiento_persona` y `bitacora_movimiento_puesto_permiso` además están protegidas por triggers de inmutabilidad. `tiempo.excepcion` no tiene privilegios para `anon`. `terminal_checador` sólo tiene `INSERT` sobre `tiempo.marca`.
- El resto de las tablas conserva `DISU` para `anon`/`authenticated` a nivel de privilegio (la barrera real es RLS).
- Roles de plataforma esperados (no creados por el DDL): `anon`, `authenticated`, `service_role`, `authenticator`; el DDL crea `terminal_checador`.

---

## Nota de método

1. Se leyeron los 80 scripts de `db/ddl/` (`00_esquemas.sql` a `79_*.sql`), `db/verificar_ddl.sql`, `SCJ-MOD-02`, `SCJ-MOD-03`, `CLAUDE.md` y `docs/03-decisiones/`.
2. Se levantó un contenedor PostgreSQL 16 nuevo y efímero (nombre propio, puerto 55439, borrado al terminar) con stubs mínimos de Supabase: roles `anon`, `authenticated`, `service_role` (BYPASSRLS), `authenticator`; esquema `auth` (`users`, `uid()`, `role()`) y `storage` (`buckets`, `objects`). Los 80 scripts corrieron en orden sin un solo error. Resultado: personas = 11, tiempo = 17, 49 permisos, 8 parámetros: coincide con `db/verificar_ddl.sql`. No se tocó ninguna base real, servidor ni Supabase.
3. Un script Python consultó `pg_catalog` (columnas, restricciones, índices, triggers, policies, privilegios, funciones) y generó las secciones II a V. Las descripciones son los `COMMENT ON` textuales; las columnas sin comentario se marcan como tales.
4. **No se verificó contra una BD viva** (producción/dev): el estado es el que produce el DDL, no el de la base real. Los stubs de Supabase pueden diferir de la plataforma (privilegios por omisión de `anon`/`authenticated` en esquemas nuevos, `search_path`, extensiones). Los privilegios por tabla reportados son los del contenedor de prueba tras aplicar los scripts. No se leyó el código del backend: las notas de "consumo en backend" vienen de comentarios y documentos. Las expresiones `CHECK`/`USING` se muestran simplificadas (se quitaron casts).

### Discrepancias entre el DDL y SCJ-MOD-03 (V1.5)

1. **Alcance:** `SCJ-MOD-03` sólo cubre `tiempo` y llega a `02`/`03`; no menciona el esquema `personas` (11 tablas), RLS (70 policies), las RPC ni los scripts `04` a `79`. Su pie dice "V1.1" aunque el encabezado dice V1.5.
2. **§I archivos:** lista `00`-`03` y `db/indices/01_indices.sql`; el DDL real son 80 scripts, y los índices de FK están además en `30_indices_fk.sql`.
3. **§II `btree_gist`:** se declara extensión requerida, pero ningún script ejecuta `CREATE EXTENSION` (el comentario de `00_esquemas.sql` dice "y las extensiones requeridas", sin crearlas) y no hay ninguna restricción `EXCLUDE`.
4. **§III identificadores:** dice que `tiempo.persona.id` es la única excepción a `bigint IDENTITY`; en realidad todas las tablas de `personas` usan `uuid` (`gen_random_uuid()`) y `personas.permiso` usa `codigo` como PK.
5. **§III duraciones:** "`numeric(6,2)`" no es uniforme: `dia.horas_totales` y `patron_semanal.horas_efectivas` son `numeric(5,2)`; `banco_de_horas.monto` y `movimiento_de_saldo.monto` son `numeric(8,2)`.
6. **§IV/§V traslape de vigencias (`SCJ-DEC-04`, "en la aplicación"):** hoy la base también protege `jornada_asignada`: `trg_jornada_asignada_valida_cadena` (CONSTRAINT TRIGGER diferido: una sola fila abierta, sin huecos ni traslapes), `protege_vigencias` y `protege_borrado`. `tope_legal` sigue sin protección de traslape en la base (sólo UK en `vigente_desde`; hay RPC `fn_tope_legal_crear_vigencia`).
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

*Diccionario de datos · Folio SCJ-DIC-01 · V1.1*
