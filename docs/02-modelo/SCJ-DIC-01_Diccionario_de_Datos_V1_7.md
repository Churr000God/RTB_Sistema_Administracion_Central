# Diccionario de datos

**Sistema de Control de Jornada · Esquemas `personas` y `tiempo`**
Folio SCJ-DIC-01 · Versión 1.7 · 28 de octubre de 2026

> **Cambio de versión (V1.6 → V1.7, menor, 28-oct-2026):** cambio sobre el esquema congelado (`SCJ-ACT-03` V1.2 §V, P-055 con P-182 fusionada), aprobado por Diego el 28-oct-2026. Recoge los scripts `127_`, `128_` y `129_`, aplicados ese día y verificados en solo lectura contra la base real (`db/verificar_ddl.sql`: secciones 55, 89, 90 y 91 en 0 filas, y la 92, informativa, también en 0). **No cambia ninguna estructura** (tablas, columnas, restricciones, índices, permisos y claves de parámetro iguales) ni ninguna cifra: **37 tablas**, **97 funciones propias** (45 `SECURITY DEFINER`, 45 de trigger), **76 policies RLS**, **54 permisos** (27 no heredables), **15 claves** de `tiempo.parametro`; los scripts pasan a **130 (`00` a `129`)**. Lo que cambia es el comportamiento de 11 funciones y 1 policy:
> - **`127_` — «hoy» es la fecha de México.** La base corre con `TimeZone = UTC`, así que `CURRENT_DATE` adelantaba un día entre las 18:00 y las 24:00 de CDMX. Las 10 funciones que lo usaban como «hoy» pasan a `personas.fn_hoy_mexico()` (`113_`) sin otro cambio de cuerpo, atributos ni `EXECUTE`: `personas.fn_persona_sincroniza_baja`, `tiempo.fn_jornada_asignada_protege_borrado`, `tiempo.fn_jornada_asignada_protege_vigencias`, `tiempo.fn_patron_semanal_solo_jornada_futura`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar`, `tiempo.fn_jornada_futura_eliminar`, `tiempo.fn_parametro_actualizar_valor`, `tiempo.fn_terminal_config_actualizar` y `tiempo.fn_terminal_config_valor`. Regla vigente: ninguna función de `tiempo`/`personas` usa `CURRENT_DATE`, `LOCALTIMESTAMP` ni `now()::date` (sección 89). Excepción deliberada: `fn_terminal_inferir_huella_cambiar`/`_estado` siguen con fecha UTC explícita (`97_`, decisión de Diego del 28-oct).
> - **`128_` — la baja por la bitácora toma la fecha en México del instante.** `personas.fn_bitacora_sincroniza_persona` calculaba `fecha_baja` y el cierre de asignaciones con `fecha_efectiva::date` (zona de la sesión); ahora con `personas.fn_hoy_mexico(NEW.fecha_efectiva)`. Sigue `SECURITY INVOKER`, sin `search_path` y sin `EXECUTE` para la API (sección 90).
> - **`129_` — la baja definitiva exige también `asignacion_edicion`.** La policy `bitacora_insert_requiere_permiso` de `personas.bitacora_movimiento_persona` suma `CASE WHEN tipo_movimiento = 'baja_definitiva' THEN fn_caller_tiene_permiso('asignacion_edicion') ELSE true END` (sin `OR`, por la sección 55). Antes, quien tuviera solo `cambio_estado_persona` daba la baja y las asignaciones quedaban abiertas (el cierre del trigger INVOKER lo filtraba la RLS de `asignacion`). Fallo: `42501` sin `HINT` (sección 91; la 92 lista los puestos que quedarían sin poder dar bajas).

> **Cambio de versión (V1.5 → V1.6, menor, 21-oct-2026):** el diccionario se **regenera contra la base real** (solo lectura: `pg_catalog` e `information_schema`, sin leer datos de tablas) y recoge todo lo que dejaron los scripts `94` a `125`, que V1.5 no reflejaba (cierra el pendiente P-136, «diccionario V1.6 completo»). Cifras vigentes: **37 tablas** (11 en `personas`, 26 en `tiempo`), **97 funciones propias** en esos dos esquemas (45 `SECURITY DEFINER`, 45 de trigger), **76 policies RLS**, **54 permisos** (27 no heredables), **15 claves** de `tiempo.parametro` y **126 scripts (`00` a `125`)**. Por qué es menor y no mayor: no cambia ninguna decisión de diseño; lo que se corrige son descripciones de V1.5 que el DDL posterior dejó falsas (sobre todo los privilegios de tabla, que `100_`, `102_`, `103_` y `104_` restringieron: `anon` ya no tiene ninguno).
>
> **Qué entra, por script:** `94`-`99` activación por huella «sin conteo» y su interruptor (`tiempo.bitacora_config_terminal`, `terminal.ingesta_detenida`, 2 claves `terminal_inferir_huella_*`); `100`-`106` endurecimiento de privilegios y de `EXECUTE` (`anon` fuera de ambos esquemas, `UPDATE`/`DELETE` inmutables, funciones de trigger sin `EXECUTE`), con el defecto del saldo del banco corregido en `104_` (`fn_movimiento_de_saldo_actualiza_banco` pasa a `SECURITY DEFINER`); `107`-`112` alta atómica de persona (`personas.fn_persona_crear`), padrón y bitácoras legibles solo por permiso, identidad separada del nombre (`fn_persona_identidad`, `GRANT SELECT` de columnas en `personas.persona`) y `fn_caller_tiene_permiso` a `SECURITY DEFINER`; `113`-`115` reglas de asignaciones y límite de plazas (`SCJ19`-`SCJ21`); `116` edición parcial de expediente (`SCJ22`); `117` corrección de la policy de INSERT de `tiempo.correccion`; `118` jornada neta de la ausencia con `minutos_comida`; `119` `tiempo.corte_quincenal_aplicado` y la nueva firma de `fn_corte_quincenal_aplicar_persona` (`SCJ23`); `120` el tipo `compensacion` del ledger (`compensa_movimiento_id`, índice único parcial, CHECK, `trg_movimiento_compensacion_valida`, `fn_movimiento_de_saldo_compensar`, permiso `movimiento_de_saldo_compensar`, `SCJ24`); `121` tipo de ausencia inmutable una vez resuelta (`SCJ25`); `122` nadie resuelve su propia ausencia (`SCJ26`, y la policy de UPDATE de `ausencia` que impide editar el tipo de la propia); `123` coherencia de `inicio`/`fin`/`minutos_trabajados` de `tiempo.tramo` con sus marcas (`trg_tramo_valida_tiempos`, `fn_marca_momento_efectivo`, índice único `uq_correccion_marca_creado_en`); `124` `fn_cierre_dia_armar`, el cierre de día atómico (`SCJ27`); `125` `fn_excepcion_horario_descartar`, el descarte auditado de alertas de horario (`SCJ28`).
>
> **Método y alcance de la regeneración:** las secciones I, II, III, V.1, V.2 y V.3 se generaron con un script que consultó el catálogo real; las descripciones son los `COMMENT ON` textuales. **Las anotaciones manuales de versiones anteriores dentro de cada tabla** (las marcas `*(V1.x)*` y los párrafos sueltos al final de la línea de RLS) **se descartaron** porque eran redundantes con el catálogo o habían quedado obsoletas; su historia sigue en las notas de versión de abajo. Las secciones IV (parámetros), la nota de método y las discrepancias con `SCJ-MOD-03` se editaron a mano. La numeración de hints de la sección V.3 sale de los `RAISE EXCEPTION … USING ERRCODE/HINT` literales del DDL (regla vigente: el `HINT` es siempre un literal fijo).

> **Cambio de versión (V1.4 → V1.5, menor):** se agrega el script `93_tiempo_retira_terminal_checador.sql` (aplicado en la base real el 9-oct-2026, con ensayo 19/19 y `db/verificar_ddl.sql` completo en 0 filas salvo el huérfano de `auth.users` ajeno al DDL): retira del rol `terminal_checador` su policy `terminal_inserta_su_origen`, el `INSERT` en `tiempo.marca`, el `USAGE` del esquema `tiempo` y su membresía en `authenticator`; el rol sigue existiendo, vacío y `NOLOGIN`. No se agregan tablas, columnas ni funciones. Se recalcula: **35 tablas**, **72 funciones**, **76 policies RLS** (una menos), 53 permisos, 13 parámetros y **94 scripts (`00` a `93`)**. Contrastado con el catálogo real el 2026-10-09 (solo lectura): `pg_policies` (76 en `personas` y `tiempo`; 2 en `tiempo.marca`), `pg_auth_members` y la ACL de `tiempo.marca`.

> **Cambio de versión (V1.3 → V1.4, menor):** se agregan los scripts `88` a `92` (configuración de terminales, consentimiento biométrico versionado, tablero de anomalías, dos endurecimientos de RPC del Pi y el endurecimiento del INSERT humano en la bitácora de personas; sin contradecir lo escrito, aunque `92` hace más estricta la policy de INSERT de `personas.bitacora_movimiento_persona`): la tabla `tiempo.terminal_consentimiento` (versiones del texto de consentimiento, de sólo inserción, con la versión 1 provisional sembrada); la columna `consentimiento_id` en `tiempo.bitacora_movimiento_terminal_usuario` y en `tiempo.terminal_usuario`; el tipo de movimiento `reconsentido`; el permiso `terminal_config_edicion` (no heredable, sólo TI y Gerente General); 5 claves `terminal_*` en `tiempo.parametro`; 15 funciones nuevas (publicar el texto, lista única de reconsentimientos pendientes, reconsentimiento en lote, 2 de trigger, editar configuración, lector tolerante, catálogo de rangos, `fn_terminal_anomalias` de sólo lectura y 4 ayudas en `personas`: 2 internas del trigger y 2 del llamador para el lote) y la reescritura de `fn_bitacora_terminal_usuario_aplica` y `fn_parametro_actualizar_valor`; y los códigos `SCJ16` y `SCJ17`. Se recalcula: **35 tablas** (11 en `personas`, 24 en `tiempo`), **72 funciones**, 77 policies RLS, 53 permisos, 13 parámetros y **93 scripts (`00` a `92`)**. Lo documentado de `88` a `91` sale de los scripts y de sus `COMMENT ON` y se **contrastó con el catálogo real el 2026-10-08, ya aplicados** (solo lectura): columnas, tipos y predeterminados de `terminal_consentimiento` y de las columnas nuevas; restricciones, índices y triggers; privilegios de tabla y de secuencia; `SECURITY DEFINER`/`INVOKER`, volatilidad, `proconfig` y `EXECUTE` por rol de las 17 funciones tocadas; policies; las 5 claves `terminal_*` y el permiso `terminal_config_edicion`; y `db/verificar_ddl.sql` completo (45 secciones en 0 filas, tras aplicar `92_`). No hubo diferencias respecto de lo escrito.
> **Cambio de versión (V1.2 → V1.3, menor):** se agregan lo que dejan los scripts `82` a `85` (`SCJ-DEC-12`, autenticación de la terminal, ruta de marcas y caducidad de altas): las tablas `tiempo.terminal_credencial` y `tiempo.marca_rechazada`, las 4 columnas de estado de `tiempo.terminal` (`reloj_desfase_seg`, `terminal_alcanzable`, `version_pi`, `marcas_pendientes`), 11 funciones nuevas (6 RPC para el puente, 1 de purga, 1 de caducidad, 1 interna de rechazos y 2 de trigger), 3 triggers de seguridad (`SCJ13`, `SCJ14`) y 1 policy; y se recalcula: **34 tablas** (11 en `personas`, 23 en `tiempo`), 24 columnas con dominio cerrado por `CHECK`, **57 funciones (coinciden los scripts y la base real)**, 76 policies RLS, 52 permisos y **88 scripts (`00` a `87`)**. El script `86` (cierre del hallazgo de `security` sobre `78_`, aplicado el 7-oct-2026) suma la tabla `tiempo.excepcion_descarte`, 6 funciones, 4 triggers, 1 policy, el permiso `excepcion_dia_cerrado_descarte` y el código `SCJ15`. El script `87` (aplicado el 7-oct-2026) suma 1 función y 1 trigger que impiden corregir la hora de una marca que ya está en un tramo (hint `marca_en_tramo`). Esta vez lo documentado se contrastó contra la base real de Supabase en solo lectura (columnas, restricciones, índices, triggers, privilegios y EXECUTE por función), no sólo contra los archivos. No se contradice nada de lo ya escrito.
> **Cambio de versión (V1.1 → V1.2, menor):** se agregan las 3 tablas de la terminal biométrica Hikvision (`tiempo.terminal`, `tiempo.terminal_usuario`, `tiempo.bitacora_movimiento_terminal_usuario`, scripts `80` y `81`, `SCJ-DEC-11`): 31 tablas en total (11 en `personas`, 20 en `tiempo`), 23 columnas con dominio cerrado por `CHECK`, 39 funciones, 74 policies RLS y 51 permisos. No se contradice nada de lo ya escrito. Además se corrige el nombre del archivo, que seguía en `V1_0` aunque el encabezado decía 1.1 (`CONVENCIONES.md §I`).

> **Cambio de versión (V1.0 → V1.1, menor):** el diccionario deja de documentar sólo `tiempo.persona` y se reconstruye contra el esquema real que dejan los scripts `db/ddl/00` a `79`: 28 tablas (11 en `personas`, 17 en `tiempo`), sin enumerados nativos (20 columnas con dominio cerrado por `CHECK`), 8 parámetros, 36 funciones y 70 policies RLS. Se elimina la columna "filas esperadas de 6 meses" (era del proyecto escolar) y se agrega la lista de discrepancias contra `SCJ-MOD-03`.

Cada tabla, cada columna, su tipo, su dominio y su propósito. Los `COMMENT ON` del DDL son la fuente de las descripciones; donde una columna no tiene `COMMENT ON` se indica así, sin inventar descripción.

> **Cómo se generó:** ver la nota de método al final. Tipos, nulos, predeterminados, restricciones, índices, triggers, policies y privilegios salieron del catálogo de la base real de Supabase (solo lectura, 21-oct-2026); las descripciones son los `COMMENT ON` textuales.

---

## I. Resumen del esquema

### Esquema `personas` — 11 tablas

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
| `puesto_permiso` | 6 | 4 | Estado vigente de "qué permiso tiene cada puesto" — snapshot derivado y mantenido por trg_puesto_permiso_sincroniza (24_puesto_permiso_trigger.sql) a partir de bitacora_movimiento_puesto_permiso, la fuente de verdad real. |
| `bitacora_movimiento_puesto_permiso` | 8 | 2 | Fuente de verdad de puesto_permiso.activo (SCJ-PRO-05). |

### Esquema `tiempo` — 26 tablas

| Tabla | Columnas | Policies RLS | Propósito (primera frase del `COMMENT ON`) |
|---|---|---|---|
| `persona` | 1 | 1 | Stub. Identificador opaco. Ningún atributo de identidad vive aquí: ni nombre, ni CURP, ni RFC, ni NSS, ni salario. Si un requisito parece necesitarlos, el requisito está mal planteado. Ver SCJ-FRO-01. |
| `tope_legal` | 5 | 0 | Máximo semanal y de horas extra, con vigencia. |
| `dia_festivo` | 3 | 0 | Catálogo de días festivos. |
| `parametro` | 6 | 0 | Valor de regla de negocio, configurable. |
| `jornada_asignada` | 9 | 4 | Qué jornada tuvo una persona, con vigencia. |
| `patron_semanal` | 7 | 4 | Qué días, con qué horario y con qué pausa de comida. |
| `marca` | 12 | 2 | Evento crudo producido por el terminal o por captura manual. |
| `dia` | 8 | 2 | Marcas de una persona en una fecha, con estado. |
| `tramo` | 7 | 3 | Par de marcas: la impar abre, la par cierra. |
| `clasificacion_de_tiempo` | 3 | 1 | Ordinario, reposición o extra, sobre un tramo — cronológica y acumulada dentro del periodo quincenal, nunca por día ni por proporción; el mismo tramo nunca se parte entre dos clasificaciones. |
| `banco_de_horas` | 5 | 1 | Deuda de horas acumulada de una persona. |
| `movimiento_de_saldo` | 9 | 1 | Libro de movimientos del banco de horas — única fuente de verdad, banco_de_horas.monto es caché derivado. |
| `correccion` | 6 | 2 | Registro nuevo que apunta a una marca anterior — nunca se sobrescribe momento_dispositivo. |
| `ausencia` | 7 | 2 | Periodo no trabajado, con naturaleza y autorización. |
| `aprobacion_ausencia` | 7 | 2 | Cadena de aprobación de una ausencia, congelada al crear la solicitud — SCJ-DEC-05 (aceptada), Opción C. |
| `excepcion` | 6 | 2 | Marca o día apartado para revisión humana — nunca ambos, nunca ninguno (ck_excepcion_marca_o_dia). |
| `corrida_batch` | 8 | 1 | Estado visible de cada corrida de batch — de dónde lee la app "última corrida: exitosa/fallida, N pendientes" (SCJ-PRO-12). |
| `terminal` | 12 | 1 | Terminal biométrica física (SCJ-DEC-11). |
| `terminal_usuario` | 12 | 1 | [CALCULADO] Persona enrolada en una terminal y estado de su enrolamiento (SCJ-DEC-11). |
| `bitacora_movimiento_terminal_usuario` | 13 | 2 | Fuente de verdad de tiempo.terminal_usuario (SCJ-DEC-11). |
| `terminal_credencial` | 10 | 0 | Llave opaca del puente de una terminal (SCJ-DEC-12 §1): formato scjt_ + 43 caracteres URL-safe, guardada sólo como hash SHA-256 hex. |
| `marca_rechazada` | 10 | 1 | Evidencia de un rechazo DEFINITIVO de fn_marca_terminal_registrar (SCJ-DEC-12 §6): la marca no entró a tiempo.marca. |
| `excepcion_descarte` | 6 | 1 | Auditoría de fn_excepcion_dia_cerrado_descartar (86_): quién descartó una marca tardía sobre un día ya revisado, cuándo y por qué. |
| `terminal_consentimiento` | 9 | 1 | Versiones del texto de consentimiento biométrico y aviso de privacidad (SCJ-PRO-15 §IV.7). |
| `corte_quincenal_aplicado` | 8 | 0 | Un registro por persona y periodo al que ya se aplicó el corte quincenal (119_). |
| `bitacora_config_terminal` | 17 | 1 | Rastro inmutable de los cambios al interruptor de la activación por huella (terminal_inferir_huella_*): valor anterior y nuevo, nota, autor, rol del JWT, usuario de sesión, hora y txid. |

---

## II. Tablas

Orden: primero `tiempo`, luego `personas`. Columnas: tipo, nulos, predeterminado, dominio (FK o CHECK de una columna) y descripción.

---

### `tiempo.persona`

> Stub. Identificador opaco. Ningún atributo de identidad vive aquí: ni nombre, ni CURP, ni RFC, ni NSS, ni salario. Si un requisito parece necesitarlos, el requisito está mal planteado. Ver SCJ-FRO-01.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | — | — | Identificador opaco, mismo valor que personas.persona.id (uuid). En operación se sincroniza desde personas.persona; en este proyecto lo puebla el generador de datos sintéticos. |

**Claves:**

- PK `id`

**Índices** (sin contar PK):

—

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `tiempo.aprobacion_ausencia`.`aprobador_id`, `tiempo.ausencia`.`persona_id`, `tiempo.banco_de_horas`.`persona_id`, `tiempo.bitacora_movimiento_terminal_usuario`.`persona_id`, `tiempo.correccion`.`autor_id`, `tiempo.corte_quincenal_aplicado`.`persona_id`, `tiempo.dia`.`persona_id`, `tiempo.dia`.`revisado_por`, `tiempo.excepcion_descarte`.`persona_id`, `tiempo.jornada_asignada`.`persona_id`, `tiempo.marca`.`persona_id`, `tiempo.movimiento_de_saldo`.`autor_id`, `tiempo.terminal_consentimiento`.`creado_por`, `tiempo.terminal_usuario`.`persona_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `persona_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

Sin policy: acceso denegado por omisión a los roles sujetos a RLS.

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

Sin policy: acceso denegado por omisión a los roles sujetos a RLS.

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

**Restricciones CHECK de varias columnas:** 
- `ck_parametro_inferir_huella_activa`: `((((clave)::text <> 'terminal_inferir_huella_activa'::text) OR (valor = ANY (ARRAY['0'::text, '1'::text]))))`
- `ck_parametro_inferir_huella_hasta`: `((((clave)::text <> 'terminal_inferir_huella_hasta'::text) OR (valor ~ '^[0-9]{4}-(0[1-9]\|1[0-2])-(0[1-9]\|[12][0-9]\|3[01])T([01][0-9]\|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z\|[+-]([01][0-9]\|2[0-3]):[0-5][0-9])$'::text)))`

**Triggers:** 
- `trg_parametro_inferir_huella_audita`: AFTER INSERT OR DELETE OR UPDATE, por fila → `tiempo.fn_parametro_inferir_audita()` *(SECURITY DEFINER)*
- `trg_parametro_truncate_bloqueado`: BEFORE TRUNCATE, por sentencia → `tiempo.fn_parametro_truncate_bloqueado()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:ISU

Sin policy: acceso denegado por omisión a los roles sujetos a RLS.

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
- `ck_jornada_asignada_descuento_fijo`: `((descuento_comida_fija = (minutos_descuento_comida_fija IS NOT NULL)))`
- `ck_jornada_asignada_vigencia`: `(((vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)))`

**Triggers:** 
- `trg_jornada_asignada_protege_borrado`: BEFORE DELETE, por fila → `tiempo.fn_jornada_asignada_protege_borrado()`
- `trg_jornada_asignada_protege_vigencias`: BEFORE UPDATE, por fila → `tiempo.fn_jornada_asignada_protege_vigencias()`
- `trg_jornada_asignada_valida_cadena`: AFTER INSERT OR DELETE OR UPDATE, por fila → `tiempo.fn_jornada_asignada_valida_cadena()` — CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED

**Referenciada por:** `tiempo.patron_semanal`.`jornada_asignada_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `jornada_asignada_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'::text)))` |
| `jornada_asignada_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'::text)))` |
| `jornada_asignada_select_requiere_permiso` | SELECT | public | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('jornada_asignada_lectura'::text) OR personas.fn_caller_tiene_permiso('jornada_asignada_edicion'::text))))` |
| `jornada_asignada_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('jornada_asignada_edicion'::text)))` |

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
- `ck_patron_semanal_horario`: `((hora_salida > hora_entrada))`

**Triggers:** 
- `trg_patron_semanal_solo_jornada_futura`: BEFORE DELETE OR UPDATE, por fila → `tiempo.fn_patron_semanal_solo_jornada_futura()`
- `trg_patron_semanal_valida_tope_legal`: AFTER INSERT OR UPDATE, por fila → `tiempo.fn_patron_semanal_valida_tope_legal()` — CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `patron_semanal_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'::text)))` |
| `patron_semanal_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'::text)))` |
| `patron_semanal_select_requiere_permiso` | SELECT | public | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('patron_semanal_lectura'::text) OR personas.fn_caller_tiene_permiso('patron_semanal_edicion'::text))))` |
| `patron_semanal_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('patron_semanal_edicion'::text)))` |

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
| `desfase_local` | `character varying(6)` | No | — | `desfase_local)::text ~ '^[+-][0-9]{2}:[0-9]{2}$'::text` (`ck_marca_desfase_local`) | Desfase respecto de UTC vigente en el instante de momento_dispositivo, formato ±HH:MM. Junto con momento_dispositivo permite reconstruir la hora local sin almacenarla — SCJ-ESP-01 §VII.3. |
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
- `uq_marca_terminal_secuencia` (UNIQUE): `(terminal_id, secuencia_local)` WHERE `((origen)::text = 'terminal'::text)`

**Restricciones CHECK de varias columnas:** 
- `ck_marca_secuencia_solo_terminal`: `((((origen)::text = 'terminal'::text) = (secuencia_local IS NOT NULL)))`

**Triggers:** 
- `trg_marca_valida_revision`: AFTER INSERT, por fila → `tiempo.fn_marca_valida_revision()` *(SECURITY DEFINER)*

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario`.`marca_id`, `tiempo.correccion`.`marca_id`, `tiempo.excepcion`.`marca_id`, `tiempo.tramo`.`marca_apertura_id`, `tiempo.tramo`.`marca_cierre_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `marca_insert_captura_manual` | INSERT | authenticated | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('captura_manual_edicion'::text) AND ((origen)::text = 'captura_manual'::text) AND (momento_dispositivo <= now()) AND (momento_dispositivo >= (now() - '90 days'::interval)) AND ((estado_reloj)::text = 'sincronizado'::text)))` |
| `marca_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('marca_lectura'::text) OR personas.fn_caller_tiene_permiso('captura_manual_edicion'::text))))` |

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

**Referenciada por:** `tiempo.excepcion`.`dia_id`, `tiempo.excepcion_descarte`.`dia_id`, `tiempo.tramo`.`dia_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:ISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `dia_select_requiere_permiso` | SELECT | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_lectura'::text)))` |
| `dia_update_revision` | UPDATE | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion'::text) AND ((estado)::text = ANY ((ARRAY['bloqueado'::character varying, 'cerrado'::character varying])::text[])))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion'::text) AND ((estado)::text = 'revisado'::text) AND (revisado_en IS NOT NULL) AND (revisado_en <= now()) AND (revisado_por = ( SELECT u.persona_id FROM personas.usuario u WHERE (u.auth_user_id = auth.uid())))))` |

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
- `ck_tramo_fin_posterior_a_inicio`: `(((fin IS NULL) OR (fin > inicio)))`

**Triggers:** 
- `trg_tramo_valida_coherencia`: BEFORE INSERT OR UPDATE, por fila → `tiempo.fn_tramo_valida_coherencia()` *(SECURITY DEFINER)*
- `trg_tramo_valida_tiempos`: BEFORE INSERT OR UPDATE OF inicio, fin, minutos_trabajados, marca_apertura_id, marca_cierre_id, por fila → `tiempo.fn_tramo_valida_tiempos()` *(SECURITY DEFINER)*

**Referenciada por:** `tiempo.clasificacion_de_tiempo`.`tramo_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:ISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `tramo_insert_revision` | INSERT | authenticated | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion'::text) AND (marca_cierre_id IS NOT NULL) AND (fin IS NOT NULL) AND (fin > inicio)))` |
| `tramo_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('tramo_lectura'::text)))` |
| `tramo_update_revision` | UPDATE | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion'::text) AND (marca_cierre_id IS NULL))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('dia_revision_edicion'::text) AND (marca_cierre_id IS NOT NULL) AND (fin IS NOT NULL) AND (fin > inicio)))` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `clasificacion_de_tiempo_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('clasificacion_de_tiempo_lectura'::text)))` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `banco_de_horas_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('banco_de_horas_lectura'::text)))` |

---

### `tiempo.movimiento_de_saldo`

> Libro de movimientos del banco de horas — única fuente de verdad, banco_de_horas.monto es caché derivado. Ver SCJ-DEC-02.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `banco_de_horas_id` | `bigint` | No | — | FK → tiempo.banco_de_horas | — (sin `COMMENT ON` en el DDL) |
| `clasificacion_de_tiempo_id` | `bigint` | Sí | — | FK → tiempo.clasificacion_de_tiempo | — (sin `COMMENT ON` en el DDL) |
| `tipo` | `character varying(20)` | No | — | `generado_quincena` / `cubrir` / `arrastrar` / `descontar` / `condonar` / `compensacion` | generado_quincena: +monto, automático al corte quincenal, sólo si horas_esperadas > horas_trabajadas (nunca genera saldo a favor). cubrir: -monto, automático desde una clasificacion_de_tiempo tipo reposicion. arrastrar: par -monto/+monto (renueva antigüedad), manual RH. descontar/condonar: -monto, manual. compensacion (120_): -monto exacto del generado_quincena que corrige, ligado en compensa_movimiento_id, con motivo y autor obligatorios. |
| `monto` | `numeric(8,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `motivo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `autor_id` | `uuid` | Sí | — | FK → tiempo.persona | NULL cuando el movimiento lo genera el sistema (generado_quincena, cubrir automático desde reposición). No nulo para arrastrar/descontar/condonar, siempre decisión humana. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `compensa_movimiento_id` | `bigint` | Sí | — | FK → tiempo.movimiento_de_saldo | Solo para tipo = compensacion: el generado_quincena que revierte (120_). UNIQUE parcial: un movimiento se compensa una sola vez. |

**Claves:**

- PK `id`
- FK `movimiento_de_saldo_autor_id_fkey` (`autor_id`) → `tiempo.persona(id)`
- FK `movimiento_de_saldo_banco_de_horas_id_fkey` (`banco_de_horas_id`) → `tiempo.banco_de_horas(id)`
- FK `movimiento_de_saldo_clasificacion_de_tiempo_id_fkey` (`clasificacion_de_tiempo_id`) → `tiempo.clasificacion_de_tiempo(id)`
- FK `movimiento_de_saldo_compensa_movimiento_id_fkey` (`compensa_movimiento_id`) → `tiempo.movimiento_de_saldo(id)`

**Índices** (sin contar PK):

- `ix_movimiento_de_saldo_autor_id`: `(autor_id)`
- `ix_movimiento_de_saldo_banco_de_horas_id`: `(banco_de_horas_id)`
- `ix_movimiento_de_saldo_clasificacion_de_tiempo_id`: `(clasificacion_de_tiempo_id)`
- `uq_movimiento_de_saldo_compensa` (UNIQUE): `(compensa_movimiento_id)` WHERE `(compensa_movimiento_id IS NOT NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_movimiento_de_saldo_compensacion`: `(((((tipo)::text = 'compensacion'::text) = (compensa_movimiento_id IS NOT NULL)) AND (((tipo)::text <> 'compensacion'::text) OR ((monto < (0)::numeric) AND (autor_id IS NOT NULL) AND (length(btrim(COALESCE(motivo, ''::text))) > 0) AND (length(motivo) <= 500)))))`

**Triggers:** 
- `trg_movimiento_compensacion_valida`: BEFORE INSERT, por fila, WHEN `((new.tipo)::text = 'compensacion'::text)` → `tiempo.fn_movimiento_compensacion_valida()` *(SECURITY DEFINER)*
- `trg_movimiento_de_saldo_actualiza_banco`: AFTER INSERT, por fila → `tiempo.fn_movimiento_de_saldo_actualiza_banco()` *(SECURITY DEFINER)*

**Referenciada por:** `tiempo.movimiento_de_saldo`.`compensa_movimiento_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `movimiento_de_saldo_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('movimiento_de_saldo_lectura'::text) OR personas.fn_caller_tiene_permiso('movimiento_de_saldo_edicion'::text))))` |

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
- `uq_correccion_marca_creado_en` (UNIQUE): `(marca_id, creado_en)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_correccion_bloquea_marca_en_tramo`: BEFORE INSERT, por fila → `tiempo.fn_correccion_bloquea_marca_en_tramo()` *(SECURITY DEFINER)*
- `trg_correccion_recalcula_tramo`: AFTER INSERT, por fila → `tiempo.fn_correccion_recalcula_tramo()`
- `trg_correccion_valida`: BEFORE INSERT, por fila → `tiempo.fn_correccion_valida()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `correccion_insert_requiere_permiso` | INSERT | authenticated | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('correccion_edicion'::text) AND ((NOT (EXISTS ( SELECT 1 FROM tiempo.excepcion e WHERE ((e.marca_id = correccion.marca_id) AND ((e.estado)::text = 'resuelto'::text))))) OR personas.fn_caller_tiene_permiso('excepcion_reapertura'::text))))` |
| `correccion_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('correccion_lectura'::text) OR personas.fn_caller_tiene_permiso('correccion_edicion'::text))))` |

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
- `uq_ausencia_falta_persona_fecha` (UNIQUE): `(persona_id, fecha_inicio, fecha_fin)` WHERE `((tipo_de_ausencia)::text = 'falta'::text)`

**Restricciones CHECK de varias columnas:** 
- `ck_ausencia_fechas`: `((fecha_fin >= fecha_inicio))`

**Triggers:** 
- `trg_ausencia_bloquea_cambio_tipo_resuelta`: BEFORE UPDATE OF tipo_de_ausencia, por fila, WHEN `((old.estado_autorizacion)::text <> 'pendiente'::text)` → `tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta()`
- `trg_ausencia_resuelve_excepcion`: AFTER INSERT OR UPDATE OF estado_autorizacion, por fila → `tiempo.fn_ausencia_resuelve_excepcion()` *(SECURITY DEFINER)*

**Referenciada por:** `tiempo.aprobacion_ausencia`.`ausencia_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `ausencia_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('ausencia_lectura'::text) OR personas.fn_caller_tiene_permiso('ausencia_edicion'::text))))` |
| `ausencia_update_requiere_permiso` | UPDATE | authenticated | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'::text) AND ((estado_autorizacion)::text = 'pendiente'::text) AND (persona_id <> ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id)))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('ausencia_edicion'::text) AND ((estado_autorizacion)::text = 'pendiente'::text) AND (persona_id <> ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id))))` |

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
- `ck_aprobacion_ausencia_decidido`: `((((decision)::text = 'pendiente'::text) = (decidido_en IS NULL)))`

**Triggers:** 
- `trg_aprobacion_ausencia_actualiza_ausencia`: AFTER INSERT OR UPDATE OF decision, por fila → `tiempo.fn_aprobacion_ausencia_actualiza_ausencia()` *(SECURITY DEFINER)*
- `trg_aprobacion_ausencia_bloquea_propia`: BEFORE INSERT, por fila → `tiempo.fn_aprobacion_ausencia_bloquea_propia()` *(SECURITY DEFINER)*

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `aprobacion_ausencia_insert_requiere_permiso` | INSERT | authenticated | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion'::text) AND (aprobador_id = ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id)) AND (NOT (EXISTS ( SELECT 1 FROM tiempo.ausencia a WHERE ((a.id = aprobacion_ausencia.ausencia_id) AND (a.persona_id = aprobacion_ausencia.aprobador_id)))))))` |
| `aprobacion_ausencia_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('aprobacion_ausencia_lectura'::text) OR personas.fn_caller_tiene_permiso('aprobacion_ausencia_edicion'::text))))` |

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
- `ck_excepcion_marca_o_dia`: `(((marca_id IS NOT NULL) <> (dia_id IS NOT NULL)))`

**Triggers:** 
- `trg_excepcion_protege_columnas`: BEFORE UPDATE, por fila → `tiempo.fn_excepcion_protege_columnas()`
- `trg_excepcion_protege_dia_cerrado`: AFTER UPDATE, por fila, WHEN `((old.motivo_revision ~~ 'dia\_cerrado%'::text) AND ((old.estado)::text = 'pendiente'::text) AND ((new.estado)::text = 'resuelto'::text))` → `tiempo.fn_excepcion_protege_dia_cerrado()` *(SECURITY DEFINER)* — CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED

**Referenciada por:** `tiempo.excepcion_descarte`.`excepcion_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:ISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `excepcion_select_requiere_permiso` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('excepcion_lectura'::text) OR personas.fn_caller_tiene_permiso('excepcion_edicion'::text))))` |
| `excepcion_update_requiere_permiso` | UPDATE | authenticated | `USING ((personas.fn_caller_activo() AND ((((estado)::text = 'pendiente'::text) AND personas.fn_caller_tiene_permiso('excepcion_edicion'::text)) OR (((estado)::text = 'resuelto'::text) AND personas.fn_caller_tiene_permiso('excepcion_reapertura'::text))))) ; CHECK ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('excepcion_edicion'::text) OR personas.fn_caller_tiene_permiso('excepcion_reapertura'::text))))` |

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
- `ck_corrida_batch_terminado`: `((((estado)::text = 'en_progreso'::text) = (terminado_en IS NULL)))`

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `corrida_batch_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |

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
| `marcas_pendientes` | `integer` | Sí | — | `marcas_pendientes IS NULL) OR (marcas_pendientes >= 0` (`ck_terminal_marcas_pendientes`) | Marcas que el Pi tiene en cola sin sincronizar (último latido). Condición del procedimiento de desactivación de una terminal (SCJ-DEC-12 §6): debe ser 0 antes de apagarla. |
| `ingesta_detenida` | `boolean` | Sí | — | — | 99_. Telemetría del último latido: true = algún lazo de ingesta del puente quedó DETENIDO esperando a una persona (p. ej. tras un 403 o una redirección); false = el puente lo reporta y todo corre; NULL = el puente no lo reportó en ese latido. La escribe solo fn_terminal_latido (SECURITY DEFINER); nadie tiene UPDATE de esta columna. |

**Claves:**

- PK `id`
- UK `uq_terminal_terminal_id` (`terminal_id`)

**Índices** (sin contar PK):

- `uq_terminal_terminal_id` (UNIQUE): `(terminal_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_terminal_valida_desactivacion`: BEFORE UPDATE OF activa, por fila, WHEN `(old.activa AND (NOT new.activa))` → `tiempo.fn_terminal_valida_desactivacion()` *(SECURITY DEFINER)*

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario`.`terminal_id`, `tiempo.marca_rechazada`.`terminal_id`, `tiempo.terminal_credencial`.`terminal_id`, `tiempo.terminal_usuario`.`terminal_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text))))` |

---

### `tiempo.terminal_usuario`

> [CALCULADO] Persona enrolada en una terminal y estado de su enrolamiento (SCJ-DEC-11). La deriva sólo trg_bitacora_terminal_usuario_aplica (81_*.sql) desde bitacora_movimiento_terminal_usuario; ningún rol de la API tiene INSERT/UPDATE/DELETE.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | FK a tiempo.terminal(id) (surrogate, no la serie). |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | Persona vía frontera SCJ-FRO-01 (tiempo.persona). Ningún dato de identidad vive acá. |
| `employee_no` | `integer` | No | — | `employee_no >= 1) AND (employee_no <= 99999999` (`ck_terminal_usuario_employee_no`) | employeeNo en la terminal. Sale de seq_terminal_employee_no, entre 1 y 99999999, nunca se reutiliza. Único por terminal. |
| `estado` | `character varying(20)` | No | — | `pendiente_alta` / `esperando_huella` / `activo` / `pendiente_baja` / `baja` | pendiente_alta (asignado en el servidor, falta crearlo en el aparato) -> esperando_huella (usuario creado, sin huella) -> activo (>=1 huella) -> pendiente_baja -> baja. Transiciones validadas por el trigger de 81_*.sql. |
| `huellas_capturadas` | `smallint` | No | `0` | `huellas_capturadas >= 0) AND (huellas_capturadas <= 10` (`ck_terminal_usuario_huellas`) | Huellas registradas en el aparato (0-10, tope del DS-K1A8503EF-B). Lo fija huella_capturada. |
| `error_detalle` | `text` | Sí | — | `error_detalle IS NULL) OR (char_length(error_detalle) <= 500` (`ck_terminal_usuario_error_detalle_len`) | Último error reportado por el Pi. Se limpia con el siguiente movimiento válido distinto de error. Sin datos sensibles. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | Lo fija el trigger en cada movimiento. |
| `consentimiento_id` | `bigint` | No | — | FK → tiempo.terminal_consentimiento | [CALCULADO] Versión del texto de consentimiento aceptada más reciente de esta alta (la fija el trigger en 'asignado' y en 'reconsentido'). Reconsentimiento pendiente = alta en pendiente_alta, esperando_huella o activo con una versión menor que la última con cambio_material. |
| `usuario_creado_en` | `timestamp with time zone` | Sí | — | — | [CALCULADO] Momento del movimiento 'usuario_creado' (el Pi creó el usuario en el aparato); NULL mientras sigue en pendiente_alta. Sólo la fija el trigger. Plazo de la caducidad de altas sin huella y de la anomalía de altas atascadas. |
| `huella_evidencia` | `character varying(10)` | Sí | — | `conteo` / `inferida` / `manual` (o NULL) | [CALCULADO] Cómo se supo que la huella está enrolada: conteo (el aparato reportó el conteo, huella_capturada), inferida (primera marca verificada por huella, huella_inferida) o manual (una persona la confirmó en la web, huella_confirmada_manual). NULL mientras no hay evidencia. Sólo la fija el trigger; sólo sube (conteo > inferida > manual). huellas_capturadas = 0 con estado activo significa "enrolada, conteo desconocido": no leer 0 como "sin huellas". |

**Claves:**

- PK `id`
- UK `uq_terminal_usuario_employee_no` (`terminal_id`, `employee_no`)
- FK `terminal_usuario_consentimiento_id_fkey` (`consentimiento_id`) → `tiempo.terminal_consentimiento(id)`
- FK `terminal_usuario_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`
- FK `terminal_usuario_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`

**Índices** (sin contar PK):

- `ix_terminal_usuario_consentimiento_id`: `(consentimiento_id)`
- `ix_terminal_usuario_persona_id`: `(persona_id)`
- `uq_terminal_usuario_employee_no` (UNIQUE): `(terminal_id, employee_no)`
- `uq_terminal_usuario_persona_vigente` (UNIQUE): `(terminal_id, persona_id)` WHERE `((estado)::text <> 'baja'::text)`

**Restricciones CHECK de varias columnas:** 
- `ck_terminal_usuario_evidencia_conteo`: `((COALESCE(((huella_evidencia)::text = 'conteo'::text), false) = (huellas_capturadas > 0)))`

**Triggers:** —

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario`.`terminal_usuario_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:S

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_usuario_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text))))` |

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
| `tipo_movimiento` | `character varying(30)` | No | — | `asignado` / `usuario_creado` / `huella_capturada` / `baja_solicitada` / `baja_confirmada` / `error` / `reconsentido` / `huella_confirmada_manual` / `huella_inferida` | asignado \| usuario_creado \| huella_capturada \| baja_solicitada \| baja_confirmada \| error. Tabla de transiciones en fn_bitacora_terminal_usuario_aplica. |
| `huellas_capturadas` | `smallint` | Sí | — | — | Total de huellas del usuario tras este movimiento (1-10). Sólo en huella_capturada. |
| `detalle` | `text` | Sí | — | `detalle IS NULL) OR (char_length(detalle) <= 500` (`ck_bitacora_terminal_usuario_detalle_len`) | Motivo o mensaje de error (obligatorio en 'error'), máx. 500 caracteres. El backend sanea y trunca; nunca cuerpos crudos de ISAPI ni headers. |
| `origen` | `character varying(10)` | No | — | `web` / `terminal` | web (RH desde la app) o terminal (reporte del Pi vía backend, service_role). |
| `registrado_por` | `uuid` | Sí | — | FK → personas.usuario | auth_user_id de quien hizo el movimiento web; NULL cuando origen='terminal'. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `consentimiento_id` | `bigint` | Sí | — | FK → tiempo.terminal_consentimiento | Versión del texto de consentimiento que se aceptó. Obligatoria en 'asignado' y 'reconsentido', NULL en el resto (ck_bitacora_terminal_usuario_consentimiento). Debe ser la versión vigente al insertar (SCJ16 si no). |
| `marca_id` | `bigint` | Sí | — | FK → tiempo.marca | Marca (tiempo.marca) que sirvió de evidencia en un huella_inferida; NULL en los demás tipos. FK sin borrado en cascada (la marca es inmutable). Una marca sólo puede servir de evidencia una vez (índice único parcial). |

**Claves:**

- PK `id`
- FK `bitacora_movimiento_terminal_usuario_consentimiento_id_fkey` (`consentimiento_id`) → `tiempo.terminal_consentimiento(id)`
- FK `bitacora_movimiento_terminal_usuario_marca_id_fkey` (`marca_id`) → `tiempo.marca(id)`
- FK `bitacora_movimiento_terminal_usuario_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`
- FK `bitacora_movimiento_terminal_usuario_registrado_por_fkey` (`registrado_por`) → `personas.usuario(auth_user_id)`
- FK `bitacora_movimiento_terminal_usuario_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`
- FK `bitacora_movimiento_terminal_usuario_terminal_usuario_id_fkey` (`terminal_usuario_id`) → `tiempo.terminal_usuario(id)`

**Índices** (sin contar PK):

- `ix_bitacora_terminal_usuario_consentimiento_id`: `(consentimiento_id)`
- `ix_bitacora_terminal_usuario_persona_id`: `(persona_id)`
- `ix_bitacora_terminal_usuario_registrado_por`: `(registrado_por)`
- `ix_bitacora_terminal_usuario_terminal_id`: `(terminal_id)`
- `ix_bitacora_terminal_usuario_terminal_usuario_id`: `(terminal_usuario_id)`
- `uq_bitacora_terminal_usuario_marca` (UNIQUE): `(marca_id)` WHERE `(marca_id IS NOT NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_bitacora_terminal_usuario_autor`: `(((registrado_por IS NOT NULL) = ((origen)::text = 'web'::text)))`
- `ck_bitacora_terminal_usuario_consentimiento`: `((((tipo_movimiento)::text = ANY (ARRAY[('asignado'::character varying)::text, ('reconsentido'::character varying)::text])) = (consentimiento_id IS NOT NULL)))`
- `ck_bitacora_terminal_usuario_error_detalle`: `((((tipo_movimiento)::text <> 'error'::text) OR (detalle IS NOT NULL)))`
- `ck_bitacora_terminal_usuario_huellas`: `( CASE WHEN ((tipo_movimiento)::text = 'huella_capturada'::text) THEN ((huellas_capturadas IS NOT NULL) AND ((huellas_capturadas >= 1) AND (huellas_capturadas <= 10))) ELSE (huellas_capturadas IS NULL) END)`
- `ck_bitacora_terminal_usuario_marca`: `(((marca_id IS NOT NULL) = ((tipo_movimiento)::text = 'huella_inferida'::text)))`
- `ck_bitacora_terminal_usuario_origen_tipo`: `((((origen)::text = 'web'::text) = ((tipo_movimiento)::text = ANY ((ARRAY['asignado'::character varying, 'baja_solicitada'::character varying, 'reconsentido'::character varying, 'huella_confirmada_manual'::character varying])::text[]))))`

**Triggers:** 
- `trg_bitacora_terminal_usuario_a0_limpia_detalle`: BEFORE INSERT, por fila → `tiempo.fn_bitacora_terminal_usuario_limpia_detalle()`
- `trg_bitacora_terminal_usuario_aplica`: BEFORE INSERT, por fila → `tiempo.fn_bitacora_terminal_usuario_aplica()` *(SECURITY DEFINER)*
- `trg_bitacora_terminal_usuario_inmutable`: BEFORE DELETE OR UPDATE, por fila → `tiempo.fn_bitacora_terminal_usuario_inmutable()`
- `trg_bitacora_terminal_usuario_truncate`: BEFORE TRUNCATE, por sentencia → `tiempo.fn_bitacora_terminal_usuario_truncate()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_terminal_usuario_insert_web` | INSERT | authenticated | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text) AND ((origen)::text = 'web'::text) AND ((tipo_movimiento)::text = ANY ((ARRAY['asignado'::character varying, 'baja_solicitada'::character varying, 'reconsentido'::character varying, 'huella_confirmada_manual'::character varying])::text[])) AND (registrado_por = auth.uid())))` |
| `bitacora_terminal_usuario_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text))))` |

---

### `tiempo.terminal_credencial`

> Llave opaca del puente de una terminal (SCJ-DEC-12 §1): formato scjt_ + 43 caracteres URL-safe, guardada sólo como hash SHA-256 hex. Acceso válido si revocada_en IS NULL, expira_en IS NULL o futuro, y tiempo.terminal.activa. Se da de alta sólo por script de TI con service_role (sin endpoint web). Sin DELETE: una llave retirada se revoca.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `terminal_id` | `bigint` | No | — | FK → tiempo.terminal | FK a tiempo.terminal(id) (surrogate, no la serie). Todo valor de terminal que se escriba lo fija el servidor desde esta fila, nunca el cliente. |
| `hash` | `character(64)` | No | — | `hash ~ '^[0-9a-f]{64}$'::text` (`ck_terminal_credencial_hash`) | SHA-256 hex (64 caracteres en minúscula) de la llave completa. Nunca la llave. UNIQUE: la búsqueda es por igualdad. No se actualiza nunca. |
| `etiqueta` | `character varying(60)` | Sí | — | — | Nombre legible para TI (ej. "llave 2026-10"). Sin datos sensibles. |
| `creada_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `expira_en` | `timestamp with time zone` | Sí | — | — | Opcional. NULL = sin vencimiento (aparato desatendido: un vencimiento automático lo apagaría en silencio). La rotación es manual, recomendada cada 12 meses. |
| `revocada_en` | `timestamp with time zone` | Sí | — | — | Momento de la revocación; NULL = vigente. Una rotación deja ambas llaves vigentes (el traslape) hasta revocar la vieja. |
| `ultimo_uso_en` | `timestamp with time zone` | Sí | — | — | Última petición autenticada con esta llave. Lo escribe sólo fn_terminal_autenticar, con una escritura como máximo cada 30 segundos. |
| `ultima_ip` | `inet` | Sí | — | — | IP de la última petición autenticada. Un cambio respecto de la anterior es una alarma (tablero), no un bloqueo: un Pi con DHCP cambiante da falsos positivos. |
| `ip_cambiada_en` | `timestamp with time zone` | Sí | — | — | Momento del último cambio de IP detectado. |

**Claves:**

- PK `id`
- UK `uq_terminal_credencial_hash` (`hash`)
- FK `terminal_credencial_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`

**Índices** (sin contar PK):

- `ix_terminal_credencial_terminal_id`: `(terminal_id)`
- `uq_terminal_credencial_hash` (UNIQUE): `(hash)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_terminal_credencial_revocacion_inmutable`: BEFORE UPDATE OF revocada_en, por fila, WHEN `((old.revocada_en IS NOT NULL) AND (new.revocada_en IS DISTINCT FROM old.revocada_en))` → `tiempo.fn_terminal_credencial_revocacion_inmutable()` *(SECURITY DEFINER)*

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:— service_role:IS

Sin policy: acceso denegado por omisión a los roles sujetos a RLS.

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
| `codigo` | `character varying(30)` | No | — | `forma_invalida` / `no_enrolado` / `secuencia_duplicada` / `secuencia_fuera_de_rango` / `conflicto_evento` | Código del rechazo, de lista cerrada: forma_invalida, no_enrolado, secuencia_duplicada, secuencia_fuera_de_rango, conflicto_evento (SCJ-CDT-01 §IX.6). |
| `creada_en` | `timestamp with time zone` | No | `now()` | — | Cuándo se registró el rechazo. Base de la retención. |

**Claves:**

- PK `id`
- UK `uq_marca_rechazada_terminal_evento` (`terminal_id`, `evento_id`)
- FK `marca_rechazada_terminal_id_fkey` (`terminal_id`) → `tiempo.terminal(id)`

**Índices** (sin contar PK):

- `ix_marca_rechazada_creada_en`: `(creada_en)`
- `uq_marca_rechazada_terminal_evento` (UNIQUE): `(terminal_id, evento_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:S

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `marca_rechazada_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text))))` |

---

### `tiempo.excepcion_descarte`

> Auditoría de fn_excepcion_dia_cerrado_descartar (86_): quién descartó una marca tardía sobre un día ya revisado, cuándo y por qué. Sólo la escribe el RPC; sin INSERT/UPDATE/DELETE/TRUNCATE para la API. El constraint trigger de dia_cerrado acepta la resolución de una excepción si hay aquí un descarte de ella creado en la misma transacción.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `excepcion_id` | `bigint` | No | — | FK → tiempo.excepcion | Excepción descartada. Sin UNIQUE: una excepción reabierta y descartada otra vez deja una fila nueva por cada descarte. |
| `dia_id` | `bigint` | No | — | FK → tiempo.dia | Día (revisado) al que pertenece la marca tardía. |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | Quien descartó (vía frontera SCJ-FRO-01, tiempo.persona), derivado de auth.uid() dentro del RPC; nunca un parámetro. |
| `motivo` | `character varying(500)` | No | — | `char_length(btrim((motivo)::text)) >= 1` (`ck_excepcion_descarte_motivo`) | Motivo saneado (sin caracteres de control), 1 a 500 caracteres. |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | Inicio de la transacción del descarte (now()); el constraint trigger lo compara con now() para exigir que sea de ESTA transacción. |

**Claves:**

- PK `id`
- FK `excepcion_descarte_dia_id_fkey` (`dia_id`) → `tiempo.dia(id)`
- FK `excepcion_descarte_excepcion_id_fkey` (`excepcion_id`) → `tiempo.excepcion(id)`
- FK `excepcion_descarte_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK):

- `ix_excepcion_descarte_dia_id`: `(dia_id)`
- `ix_excepcion_descarte_excepcion_id`: `(excepcion_id)`
- `ix_excepcion_descarte_persona_id`: `(persona_id)`

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_excepcion_descarte_inmutable`: BEFORE DELETE OR UPDATE, por fila → `tiempo.fn_excepcion_descarte_inmutable()`
- `trg_excepcion_descarte_truncate`: BEFORE TRUNCATE, por sentencia → `tiempo.fn_excepcion_descarte_truncate()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:S

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `excepcion_descarte_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('excepcion_lectura'::text) OR personas.fn_caller_tiene_permiso('excepcion_edicion'::text))))` |

---

### `tiempo.terminal_consentimiento`

> Versiones del texto de consentimiento biométrico y aviso de privacidad (SCJ-PRO-15 §IV.7). Sólo inserción, inmutable en 3 capas. La versión vigente es la de mayor version. Sólo la escribe fn_terminal_consentimiento_publicar; la versión 1 es una semilla provisional sin autor.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `version` | `integer` | No | — | `version >= 1` (`ck_terminal_consentimiento_version`) | Número consecutivo (1, 2, 3...) que asigna el RPC bajo lock de tabla; UNIQUE como respaldo. |
| `texto` | `text` | No | — | `texto = btrim(texto, ' '::text)) AND ((char_length(texto) >= 1) AND (char_length(texto) <= 4000)) AND (translate(texto, ' '::text, ''::text) !~ '[[:cntrl:]]'::text) AND (texto !~ '[\u00AD\u061C\u200B-\u200F\u2028-\u202E\u2060-\u2064\u2066-\u2069\uFEFF\U000E0000-\U000E007F]'::text` (`ck_terminal_consentimiento_texto`) | Texto plano (sin HTML), 1 a 4000 caracteres, sin espacios ni saltos de línea en los extremos, sin caracteres de control salvo salto de línea ni caracteres de formato Unicode invisibles. La interfaz debe mostrarlo como texto, nunca como HTML. |
| `texto_sha256` | `character(64)` | No | — | — | SHA-256 hex del texto en UTF-8; sirve para citar la versión en el documento impreso. Lo valida un CHECK. |
| `provisional` | `boolean` | No | `false` | — | true sólo en la semilla (versión 1). Dejar de ser provisional = publicar una versión nueva. |
| `cambio_material` | `boolean` | No | `false` | — | true = los ya enrolados con una versión anterior deben reconsentir. El RPC lo fuerza cuando la versión anterior era provisional. |
| `nota` | `character varying(200)` | Sí | — | — | Motivo del cambio, opcional, hasta 200 caracteres. |
| `creado_por` | `uuid` | Sí | — | FK → tiempo.persona | Persona que publicó (frontera SCJ-FRO-01). NULL sólo en la semilla provisional (la interfaz lo muestra como "Sistema"). |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`
- UK `uq_terminal_consentimiento_version` (`version`)
- FK `terminal_consentimiento_creado_por_fkey` (`creado_por`) → `tiempo.persona(id)`

**Índices** (sin contar PK):

- `ix_terminal_consentimiento_creado_por`: `(creado_por)`
- `uq_terminal_consentimiento_version` (UNIQUE): `(version)`

**Restricciones CHECK de varias columnas:** 
- `ck_terminal_consentimiento_autor`: `(((creado_por IS NOT NULL) OR ((version = 1) AND provisional)))`
- `ck_terminal_consentimiento_hash`: `(((texto_sha256)::text = encode(sha256(convert_to(texto, 'UTF8'::name)), 'hex'::text)))`
- `ck_terminal_consentimiento_provisional`: `(((NOT provisional) OR (version = 1)))`

**Triggers:** 
- `trg_terminal_consentimiento_inmutable`: BEFORE DELETE OR UPDATE, por fila → `tiempo.fn_terminal_consentimiento_inmutable()`
- `trg_terminal_consentimiento_truncate`: BEFORE TRUNCATE, por sentencia → `tiempo.fn_terminal_consentimiento_truncate()`

**Referenciada por:** `tiempo.bitacora_movimiento_terminal_usuario`.`consentimiento_id`, `tiempo.terminal_usuario`.`consentimiento_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:S

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `terminal_consentimiento_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text) OR personas.fn_caller_tiene_permiso('terminal_config_edicion'::text))))` |

---

### `tiempo.corte_quincenal_aplicado`

> Un registro por persona y periodo al que ya se aplicó el corte quincenal (119_). UNIQUE (persona_id, periodo_desde) es la idempotencia real del corte: un periodo sin tramos también queda registrado (resultado_horas = 0). Append-only por privilegios; solo service_role lo escribe, dentro de fn_corte_quincenal_aplicar_persona.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → tiempo.persona | — (sin `COMMENT ON` en el DDL) |
| `periodo_desde` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `periodo_hasta` | `date` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `aplicado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `horas_esperadas` | `numeric(8,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `horas_trabajadas` | `numeric(8,2)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `resultado_horas` | `numeric(8,2)` | No | — | — | Deuda generada por el corte en ese momento (suma de los movimientos generado_quincena de la llamada); 0 si no generó deuda. No se reescribe al compensar (120_). |

**Claves:**

- PK `id`
- UK `uq_corte_quincenal_aplicado_persona_periodo` (`persona_id`, `periodo_desde`)
- FK `corte_quincenal_aplicado_persona_id_fkey` (`persona_id`) → `tiempo.persona(id)`

**Índices** (sin contar PK):

- `uq_corte_quincenal_aplicado_persona_periodo` (UNIQUE): `(persona_id, periodo_desde)`

**Restricciones CHECK de varias columnas:** 
- `ck_corte_quincenal_aplicado_horas`: `(((horas_esperadas >= (0)::numeric) AND (horas_trabajadas >= (0)::numeric) AND (resultado_horas >= (0)::numeric)))`
- `ck_corte_quincenal_aplicado_periodo`: `((periodo_hasta >= periodo_desde))`

**Triggers:** —

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:— service_role:IS

Sin policy: acceso denegado por omisión a los roles sujetos a RLS.

---

### `tiempo.bitacora_config_terminal`

> Rastro inmutable de los cambios al interruptor de la activación por huella (terminal_inferir_huella_*): valor anterior y nuevo, nota, autor, rol del JWT, usuario de sesión, hora y txid. La escribe SOLO el trigger de tiempo.parametro (como dueño); un cambio directo con service_role también deja fila (sin nota, via_funcion = false). registrado_por no lleva clave foránea a propósito (una bitácora inmutable con FK impediría borrar cuentas). Diseño: DISENO_interruptor_inferir_huella.md.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `bigint` | No | `IDENTITY (GENERATED ALWAYS)` | — | — (sin `COMMENT ON` en el DDL) |
| `clave` | `text` | No | — | `terminal_inferir_huella_activa` / `terminal_inferir_huella_hasta` | — (sin `COMMENT ON` en el DDL) |
| `operacion` | `text` | No | — | `INSERT` / `UPDATE` / `UPDATE_VIGENCIA` / `DELETE` | INSERT \| UPDATE (cambia el valor o la clave) \| UPDATE_VIGENCIA (cambia solo vigente_desde/vigente_hasta: cerrar una vigencia, o REABRIR una fila histórica) \| DELETE. fila_id = tiempo.parametro.id de la fila afectada; las columnas vigente_* guardan la vigencia anterior y la nueva. |
| `fila_id` | `bigint` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `valor_anterior` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `valor_nuevo` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde_anterior` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_hasta_anterior` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_desde_nuevo` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `vigente_hasta_nuevo` | `date` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `nota` | `text` | Sí | — | `nota IS NULL) OR (char_length(nota) <= 500` (`ck_bitacora_config_terminal_nota_len`) | — (sin `COMMENT ON` en el DDL) |
| `registrado_por` | `uuid` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `rol_jwt` | `text` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `usuario_sesion` | `text` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `via_funcion` | `boolean` | No | — | — | true solo si el cambio ocurrió dentro de fn_terminal_inferir_huella_cambiar (la variable de transacción con txid_current() coincide). Calculado por el trigger, no recibido. |
| `txid` | `bigint` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |

**Claves:**

- PK `id`

**Índices** (sin contar PK):

—

**Restricciones CHECK de varias columnas:** —

**Triggers:** 
- `trg_bitacora_config_terminal_inmutable`: BEFORE DELETE OR UPDATE, por fila → `tiempo.fn_bitacora_config_terminal_inmutable()`
- `trg_bitacora_config_terminal_truncate`: BEFORE TRUNCATE, por sentencia → `tiempo.fn_bitacora_config_terminal_truncate()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:S service_role:S

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_config_terminal_select_lectura` | SELECT | authenticated | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('terminal_config_edicion'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_lectura'::text) OR personas.fn_caller_tiene_permiso('terminal_usuario_edicion'::text))))` |

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
- `ck_persona_baja_consistente`: `((((estado)::text = 'baja_definitiva'::text) = (fecha_baja IS NOT NULL)))`

**Triggers:** 
- `trg_persona_protege_columnas_identidad`: BEFORE UPDATE, por fila, WHEN `(((old.curp)::text IS DISTINCT FROM (new.curp)::text) OR ((old.rfc)::text IS DISTINCT FROM (new.rfc)::text) OR ((old.nss)::text IS DISTINCT FROM (new.nss)::text) OR ((old.primer_nombre)::text IS DISTINCT FROM (new.primer_nombre)::text) OR ((old.segundo_nombre)::text IS DISTINCT FROM (new.segundo_nombre)::text) OR ((old.apellido_paterno)::text IS DISTINCT FROM (new.apellido_paterno)::text) OR ((old.apellido_materno)::text IS DISTINCT FROM (new.apellido_materno)::text) OR (old.fecha_nacimiento IS DISTINCT FROM new.fecha_nacimiento) OR (old.fecha_ingreso IS DISTINCT FROM new.fecha_ingreso))` → `personas.fn_persona_protege_columnas_identidad()`
- `trg_persona_sincroniza_baja`: BEFORE INSERT OR UPDATE, por fila → `personas.fn_persona_sincroniza_baja()`
- `trg_persona_sincroniza_tiempo`: AFTER INSERT, por fila → `personas.fn_persona_sincroniza_tiempo()` *(SECURITY DEFINER)*

**Referenciada por:** `personas.asignacion`.`persona_id`, `personas.bitacora_movimiento_persona`.`persona_id`, `personas.expediente`.`persona_id`, `personas.usuario`.`persona_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DIU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `persona_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona'::text)))` |
| `persona_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |
| `persona_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND ((id = ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id)) OR ( SELECT personas.fn_caller_ve_padron() AS fn_caller_ve_padron))))` |
| `persona_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('cambio_estado_persona'::text) OR personas.fn_caller_tiene_permiso('persona_edicion'::text)))) ; CHECK ((personas.fn_caller_activo() AND (personas.fn_caller_tiene_permiso('cambio_estado_persona'::text) OR personas.fn_caller_tiene_permiso('persona_edicion'::text))))` |

---

### `personas.expediente`

> Referencia al expediente físico/digital de la persona. documento_ref es la única referencia (folio) — el archivo real vive en el bucket de Storage "expedientes", no en esta tabla.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `persona_id` | `uuid` | No | — | FK → personas.persona | — (sin `COMMENT ON` en el DDL) |
| `tipo_contrato` | `character varying(30)` | No | — | `indefinido` / `prestacion_servicios` / `por_proyecto` | — (sin `COMMENT ON` en el DDL) |
| `fecha_firma` | `timestamp with time zone` | Sí | — | — | — (sin `COMMENT ON` en el DDL) |
| `documento_ref` | `character varying(50)` | No | — | `documento_ref)::text ~ '^RTB-RH-EIT-[0-9]{4}-[0-9]+$'::text` (`ck_expediente_documento_ref_formato`) | Folio formato RTB-RH-EIT-<año vigente>-<número de expediente>, ej. RTB-RH-EIT-2026-06. Único por persona (uq_expediente_persona: una persona, un expediente). Ver 71_*.sql. |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `expediente_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |
| `expediente_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |
| `expediente_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND ((persona_id = ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id)) OR ( SELECT personas.fn_caller_ve_identidad() AS fn_caller_ve_identidad))))` |
| `expediente_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('persona_edicion'::text)))` |

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
- `trg_usuario_bitacora_alta`: AFTER INSERT, por fila, WHEN `(new.persona_id IS NOT NULL)` → `personas.fn_usuario_bitacora_alta()`

**Referenciada por:** `personas.bitacora_movimiento_persona`.`registrado_por`, `personas.bitacora_movimiento_puesto_permiso`.`registrado_por`, `tiempo.bitacora_movimiento_terminal_usuario`.`registrado_por`, `tiempo.parametro`.`registrado_por`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `usuario_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |
| `usuario_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |
| `usuario_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND ((auth_user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT personas.fn_caller_ve_padron() AS fn_caller_ve_padron))))` |
| `usuario_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text)))` |

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
- `trg_bitacora_inmutable`: BEFORE DELETE OR UPDATE, por fila → `personas.fn_bitacora_inmutable()`
- `trg_bitacora_persona_fija_hora`: BEFORE INSERT, por fila → `personas.fn_bitacora_persona_fija_hora()`
- `trg_bitacora_sincroniza_persona`: AFTER INSERT, por fila → `personas.fn_bitacora_sincroniza_persona()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('cambio_estado_persona'::text) AND (registrado_por = auth.uid()) AND ((tipo_movimiento)::text = ANY ((ARRAY['suspension'::character varying, 'reactivacion'::character varying, 'baja_definitiva'::character varying])::text[])) AND CASE WHEN ((tipo_movimiento)::text = 'baja_definitiva'::text) THEN personas.fn_caller_tiene_permiso('asignacion_edicion'::text) ELSE true END))` *(V1.7, 129_: la baja definitiva exige también asignacion_edicion; fallo 42501 sin HINT)* |
| `bitacora_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND (( SELECT personas.fn_caller_tiene_permiso('ver_modulo_1'::text) AS fn_caller_tiene_permiso) OR ( SELECT personas.fn_caller_tiene_permiso('cambio_estado_persona'::text) AS fn_caller_tiene_permiso) OR ( SELECT personas.fn_caller_tiene_permiso('persona_edicion'::text) AS fn_caller_tiene_permiso) OR ( SELECT personas.fn_caller_tiene_permiso('alta_personas_usuarios'::text) AS fn_caller_t…)` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `area_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'::text)))` |
| `area_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'::text)))` |
| `area_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |
| `area_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('area_edicion'::text)))` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `departamento_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'::text)))` |
| `departamento_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'::text)))` |
| `departamento_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |
| `departamento_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('departamento_edicion'::text)))` |

---

### `personas.puesto`

> Tercer nivel del módulo Estructura Organizacional (SCJ-PRO-03), hijo de personas.departamento, con jerarquía propia vía reporta_a_id. nivel es varchar+CHECK, no CREATE TYPE ENUM — ningún enum Postgres existe en el proyecto, mismo criterio que persona.estado. Sin nombre_puesto UNIQUE: SCJ-PRO-03 nunca pide validación de nombre duplicado para puesto (a diferencia de area/departamento), no se inventa. Sin validación de ciclo/recorrido en DDL: SCJ-PRO-03 §I excluye la edición de reporta_a_id de este alcance, y en el alta (siempre elige un puesto ya existente) el ciclo es imposible por construcción — sería código muerto hasta que exista ese endpoint de edición. ck_puesto_no_autoreferencia sí se agrega: defensivo, gratis, cubre incluso un UPDATE directo por SQL. La guarda de SCJ-PRO-06 DP4 (no desactivar con puesto subordinado activo) sí es construible hoy y va en el backend (ya existen todas las filas que necesita consultar). TODO SCJ-PRO-06 DP1/DP3: asignación vigente y puesto_permiso activo, tablas inexistentes.

| Columna | Tipo | Nulo | Predeterminado | Dominio / CHECK | Descripción |
|---|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | — | — (sin `COMMENT ON` en el DDL) |
| `departamento_id` | `uuid` | No | — | FK → personas.departamento | — (sin `COMMENT ON` en el DDL) |
| `nombre_puesto` | `character varying(150)` | No | — | — | — (sin `COMMENT ON` en el DDL) |
| `nivel` | `character varying(20)` | No | — | `direccion` / `gerencia` / `mando_medio` / `operativo` | Catálogo cerrado de 4 valores (ck_puesto_nivel): direccion, gerencia, mando_medio, operativo — snake_case ASCII de Dirección/Gerencia/Mando medio/Operativo. |
| `plazas_totales` | `integer` | No | `1` | `plazas_totales > 0` (`ck_puesto_plazas_positivas`) | — (sin `COMMENT ON` en el DDL) |
| `reporta_a_id` | `uuid` | Sí | — | FK → personas.puesto | NULL-able en DDL — el único NULL real es el puesto tope (Gerente General), sembrado por migración vía SQL directo, fuera del flujo normal de alta. El backend exige este campo en el POST normal: la API nunca puede crear un segundo puesto sin padre. ux_puesto_tope_unico lo garantiza también a nivel de Postgres. |
| `activo` | `boolean` | No | `true` | — | — (sin `COMMENT ON` en el DDL) |
| `creado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `actualizado_en` | `timestamp with time zone` | No | `now()` | — | — (sin `COMMENT ON` en el DDL) |
| `es_administrador_generico` | `boolean` | No | `false` | — | true sólo en el puesto de bootstrap que siembra 26_puesto_permiso_bootstrap_admin_generico.sql. Inmutable después del backfill inicial (ver trigger trg_puesto_administrador_generico_inmutable más abajo, en este mismo archivo) -- ni la app ni un UPDATE directo por PostgREST ni service_role pueden cambiarla después de sembrada. Existe para identificar el puesto administrador sin depender de nombre_puesto (editable, frágil) en las policies RLS que lo protegen de auto-bloqueo (ver bloques 3 y 4 de este archivo). |

**Claves:**

- PK `id`
- FK `puesto_departamento_id_fkey` (`departamento_id`) → `personas.departamento(id)`
- FK `puesto_reporta_a_id_fkey` (`reporta_a_id`) → `personas.puesto(id)`

**Índices** (sin contar PK):

- `ix_puesto_departamento_id`: `(departamento_id)`
- `ix_puesto_reporta_a_id`: `(reporta_a_id)`
- `ux_puesto_administrador_generico_unico` (UNIQUE): `((true))` WHERE `es_administrador_generico`
- `ux_puesto_tope_unico` (UNIQUE): `(((reporta_a_id IS NULL)))` WHERE `(reporta_a_id IS NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_puesto_no_autoreferencia`: `((id IS DISTINCT FROM reporta_a_id))`

**Triggers:** 
- `trg_puesto_administrador_generico_inmutable`: BEFORE UPDATE, por fila, WHEN `(old.es_administrador_generico IS DISTINCT FROM new.es_administrador_generico)` → `personas.fn_puesto_administrador_generico_inmutable()`

**Referenciada por:** `personas.asignacion`.`puesto_id`, `personas.bitacora_movimiento_puesto_permiso`.`puesto_id`, `personas.puesto`.`reporta_a_id`, `personas.puesto_permiso`.`puesto_id`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `puesto_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'::text)))` |
| `puesto_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'::text)))` |
| `puesto_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |
| `puesto_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_edicion'::text) AND (NOT ((activo = false) AND es_administrador_generico))))` |

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
- `ux_asignacion_vigente_persona_puesto` (UNIQUE): `(persona_id, puesto_id)` WHERE `(vigente_hasta IS NULL)`

**Restricciones CHECK de varias columnas:** 
- `ck_asignacion_vigencia`: `(((vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)))`

**Triggers:** 
- `trg_asignacion_valida_plazas`: BEFORE INSERT OR UPDATE OF puesto_id, vigente_hasta, por fila → `personas.fn_asignacion_valida_plazas()` *(SECURITY DEFINER)*
- `trg_asignacion_valida_reglas`: BEFORE INSERT OR UPDATE OF persona_id, puesto_id, vigente_desde, vigente_hasta, por fila → `personas.fn_asignacion_valida_reglas()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `asignacion_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'::text)))` |
| `asignacion_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'::text)))` |
| `asignacion_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND ((persona_id = ( SELECT personas.fn_caller_persona_id() AS fn_caller_persona_id)) OR ( SELECT personas.fn_caller_ve_padron() AS fn_caller_ve_padron))))` |
| `asignacion_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('asignacion_edicion'::text) AND (NOT ((vigente_hasta IS NOT NULL) AND (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = asignacion.puesto_id) AND pu.es_administrador_generico)))))))` |

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

**Índices** (sin contar PK):

—

**Restricciones CHECK de varias columnas:** —

**Triggers:** —

**Referenciada por:** `personas.bitacora_movimiento_puesto_permiso`.`codigo`, `personas.puesto_permiso`.`codigo`

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `permiso_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'::text)))` |
| `permiso_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'::text)))` |
| `permiso_select_caller_activo` | SELECT | public | `USING (personas.fn_caller_activo())` |
| `permiso_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('permiso_edicion'::text)))` |

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

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:DISU service_role:DISU

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `puesto_permiso_delete_requiere_permiso` | DELETE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'::text) AND (NOT (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = puesto_permiso.puesto_id) AND pu.es_administrador_generico))))))` |
| `puesto_permiso_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'::text)))` |
| `puesto_permiso_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND (( SELECT personas.fn_caller_ve_estructura_permisos() AS fn_caller_ve_estructura_permisos) OR (puesto_id IN ( SELECT personas.fn_caller_puestos_en_rama() AS fn_caller_puestos_en_rama)))))` |
| `puesto_permiso_update_requiere_permiso` | UPDATE | public | `USING ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'::text))) ; CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'::text) AND (NOT ((activo = false) AND (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = puesto_permiso.puesto_id) AND pu.es_administrador_generico)))))))` |

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
- `trg_bitacora_puesto_permiso_inmutable`: BEFORE DELETE OR UPDATE, por fila → `personas.fn_bitacora_puesto_permiso_inmutable()`
- `trg_puesto_permiso_sincroniza`: AFTER INSERT, por fila → `personas.fn_puesto_permiso_sincroniza()`

**Referenciada por:** — (ninguna FK la referencia)

**RLS:** habilitada; privilegios de tabla (D=DELETE, I=INSERT, S=SELECT, U=UPDATE) — anon:— authenticated:IS service_role:IS

| Policy | Comando | Roles | USING / WITH CHECK |
|---|---|---|---|
| `bitacora_puesto_permiso_insert_requiere_permiso` | INSERT | public | `CHECK ((personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso('puesto_permiso_edicion'::text) AND (NOT (((tipo_movimiento)::text = 'revocado'::text) AND (EXISTS ( SELECT 1 FROM personas.puesto pu WHERE ((pu.id = bitacora_movimiento_puesto_permiso.puesto_id) AND pu.es_administrador_generico)))))))` |
| `bitacora_puesto_permiso_select_caller_activo` | SELECT | public | `USING ((personas.fn_caller_activo() AND (( SELECT personas.fn_caller_ve_estructura_permisos() AS fn_caller_ve_estructura_permisos) OR (puesto_id IN ( SELECT personas.fn_caller_puestos_en_rama() AS fn_caller_puestos_en_rama)))))` |

---

## III. Enumerados

No existe ningún `CREATE TYPE ... AS ENUM` en `personas` ni `tiempo`. Todos los dominios cerrados son `varchar(N)` con `CHECK`, como decide `SCJ-MOD-03 §III`. Los 27 reales:

| Tabla.columna | Valores permitidos | Restricción |
|---|---|---|
| `personas.bitacora_movimiento_persona.tipo_movimiento` | `alta` / `suspension` / `reactivacion` / `baja_definitiva` | `ck_bitacora_tipo_movimiento` |
| `personas.bitacora_movimiento_puesto_permiso.tipo_movimiento` | `otorgado` / `revocado` | `ck_bitacora_puesto_permiso_tipo` |
| `personas.expediente.tipo_contrato` | `indefinido` / `prestacion_servicios` / `por_proyecto` | `ck_expediente_tipo_contrato` |
| `personas.persona.estado` | `activo` / `baja_definitiva` / `suspension` | `ck_persona_estado` |
| `personas.puesto.nivel` | `direccion` / `gerencia` / `mando_medio` / `operativo` | `ck_puesto_nivel` |
| `personas.usuario.estado` | `activo` / `inactivo` | `ck_usuario_estado` |
| `tiempo.aprobacion_ausencia.decision` | `pendiente` / `autorizada` / `rechazada` | `ck_aprobacion_ausencia_decision` |
| `tiempo.ausencia.estado_autorizacion` | `pendiente` / `autorizada` / `rechazada` | `ck_ausencia_estado_autorizacion` |
| `tiempo.ausencia.tipo_de_ausencia` | `vacaciones` / `permiso_con_goce` / `permiso_sin_goce` / `incapacidad` / `falta` | `ck_ausencia_tipo` |
| `tiempo.bitacora_config_terminal.clave` | `terminal_inferir_huella_activa` / `terminal_inferir_huella_hasta` | `ck_bitacora_config_terminal_clave` |
| `tiempo.bitacora_config_terminal.operacion` | `INSERT` / `UPDATE` / `UPDATE_VIGENCIA` / `DELETE` | `ck_bitacora_config_terminal_operacion` |
| `tiempo.bitacora_movimiento_terminal_usuario.origen` | `web` / `terminal` | `ck_bitacora_terminal_usuario_origen` |
| `tiempo.bitacora_movimiento_terminal_usuario.tipo_movimiento` | `asignado` / `usuario_creado` / `huella_capturada` / `baja_solicitada` / `baja_confirmada` / `error` / `reconsentido` / `huella_confirmada_manual` / `huella_inferida` | `ck_bitacora_terminal_usuario_tipo` |
| `tiempo.clasificacion_de_tiempo.tipo` | `ordinario` / `reposicion` / `extra` (o NULL) | `ck_clasificacion_de_tiempo_tipo` |
| `tiempo.corrida_batch.estado` | `en_progreso` / `exitosa` / `fallida` | `ck_corrida_batch_estado` |
| `tiempo.corrida_batch.tipo_batch` | `cierre_dia` / `corte_quincenal` / `de_confianza` | `ck_corrida_batch_tipo` |
| `tiempo.dia.estado` | `abierto` / `cerrado` / `bloqueado` / `revisado` | `ck_dia_estado` |
| `tiempo.dia.origen` | `automatico_confianza` / `ausencia_autorizada` (o NULL) | `ck_dia_origen` |
| `tiempo.excepcion.estado` | `pendiente` / `resuelto` | `ck_excepcion_estado` |
| `tiempo.jornada_asignada.tipo_jornada` | `normal` / `flexible` / `de_confianza` | `ck_jornada_asignada_tipo` |
| `tiempo.marca.estado_reloj` | `sincronizado` / `deriva` / `sin_sincronizar` | `ck_marca_estado_reloj` |
| `tiempo.marca.origen` | `terminal` / `captura_manual` | `ck_marca_origen` |
| `tiempo.marca_rechazada.codigo` | `forma_invalida` / `no_enrolado` / `secuencia_duplicada` / `secuencia_fuera_de_rango` / `conflicto_evento` | `ck_marca_rechazada_codigo` |
| `tiempo.movimiento_de_saldo.tipo` | `generado_quincena` / `cubrir` / `arrastrar` / `descontar` / `condonar` / `compensacion` | `ck_movimiento_de_saldo_tipo` |
| `tiempo.patron_semanal.dia_semana` | `lunes` / `martes` / `miercoles` / `jueves` / `viernes` / `sabado` / `domingo` | `ck_patron_semanal_dia_semana` |
| `tiempo.terminal_usuario.estado` | `pendiente_alta` / `esperando_huella` / `activo` / `pendiente_baja` / `baja` | `ck_terminal_usuario_estado` |
| `tiempo.terminal_usuario.huella_evidencia` | `conteo` / `inferida` / `manual` (o NULL) | `ck_terminal_usuario_huella_evidencia` |

---

## IV. Parámetros del sistema

Fuente: `db/ddl/03_parametros_ejemplo.sql` (8 filas, `vigente_desde = 2026-01-01`); `89_tiempo_terminal_config_parametros.sql` siembra 5 claves `terminal_*` más, y *(V1.6)* `97_tiempo_terminal_inferir_huella_interruptor.sql` siembra 2 del interruptor de la activación por huella (15 claves en total, con la misma fecha, `vigente_hasta` y `registrado_por` NULL). Ningún otro script inserta ni cambia claves; `60_tiempo_parametro_vigencia_y_autor.sql` sólo agregó `vigente_hasta`/`registrado_por` y el RPC `fn_parametro_actualizar_valor`. **Todos los valores son de ejemplo**, no de operación (el propio archivo lo declara). `valor` es `text`: el tipo lógico (entero/hora) no está en la base.

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
| `terminal_inferir_huella_activa` *(97_)* | `0` (0 o 1) | Interruptor de la activación por huella (vía B de `94_`/`95_`), APAGADO por omisión; solo se enciende con `fn_terminal_inferir_huella_cambiar` | Sí: `fn_marca_terminal_registrar` (`98_`) y `fn_terminal_inferir_huella_estado` (`97_`) |
| `terminal_inferir_huella_hasta` *(97_)* | `1970-01-01T00:00:00Z` (ISO con zona) | Vencimiento del interruptor (hasta 30 días); el centinela ya vencido lo deja inerte | Sí: `fn_terminal_inferir_huella_estado` (`97_`) |

Las claves `terminal_*` sólo se editan con `fn_terminal_config_actualizar` (permiso `terminal_config_edicion`; las dos del interruptor, solo con `fn_terminal_inferir_huella_cambiar`); `fn_parametro_actualizar_valor` las rechaza con `SCJ17` / `clave_reservada`. *(V1.6)* Cada cambio del interruptor deja una fila en `tiempo.bitacora_config_terminal` (inmutable) y un `TRUNCATE` de `tiempo.parametro` está bloqueado (`P0001` / `parametro_truncate_bloqueado`).

Las columnas "backend" se apoyan en comentarios del DDL, en `CLAUDE.md` y en `SCJ-PRO-12`; no se verificó el código del backend para este documento. Otros datos que cargan los scripts (no son parámetros): catálogo `personas.permiso` (54 filas, `25`, `33`, `35`, `45`, `62`, `69`, `80`, entre otros), áreas/departamentos/puestos iniciales (`11`, `13`, `15`, `16`) y el bucket `expedientes` (`07`).

---

## V. Funciones, RPC y políticas RLS

### V.1 Funciones (97)

Ejecutable por: roles con `EXECUTE` entre `anon`, `authenticated`, `service_role`; `público` = el privilegio por omisión de `PUBLIC` sigue activo. SD = `SECURITY DEFINER`. Tipo: trigger = función de trigger; RPC = con `EXECUTE` para `authenticated` o `service_role`; auxiliar = el resto (la llaman otras funciones o las policies).

| Función | Tipo | SD | Ejecutable por | Descripción (resumen del `COMMENT ON`) |
|---|---|---|---|---|
| `personas.fn_asignacion_cambiar_puesto(p_asignacion_id uuid, p_puesto_nuevo_id uuid, p_fecha date)` | RPC | no | authenticated | RPC transaccional de "cambiar de puesto" (SCJ-PRO-04 §VII): cierra la asignación vigente p_asignacion_id y abre una nueva para el mismo persona_id en p_puesto_nuevo_id, ambas escrituras en una sola transacción. |
| `personas.fn_asignacion_valida_plazas()` | trigger | sí | — | Trigger de personas.asignacion (115_): una asignación vigente nueva, reabierta o movida de puesto no puede dejar el puesto por encima de plazas_totales (SCJ21, hint plazas_llenas). |
| `personas.fn_asignacion_valida_reglas()` | trigger | no | — | Trigger de personas.asignacion (113_/114_): rechaza autoasignación y REAPERTURA de la propia asignación cerrada (SCJ19, hint autoasignacion_no_permitida) y vigente_desde posterior a hoy en México (SCJ20, hint vigencia_futura_no_permitida). |
| `personas.fn_bitacora_inmutable()` | trigger | no | — | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role (que salta RLS y conserva el GRANT de 08_personas_permisos.sql hasta que se revoque explícitamente). |
| `personas.fn_bitacora_persona_fija_hora()` | trigger | no | — | 92_. BEFORE INSERT en personas.bitacora_movimiento_persona: para llamadores de la API (anon/authenticated) fija creado_en = now() y exige fecha_efectiva entre now() - 90 días y now() + 5 minutos (22023 / fecha_efectiva_invalida). service_role y el dueño no se tocan. SECURITY INVOKER, search_path = personas, pg_temp; s… |
| `personas.fn_bitacora_puesto_permiso_inmutable()` | trigger | no | — | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role. |
| `personas.fn_bitacora_sincroniza_persona()` | trigger | no | — | Implementa SCJ-PRO-02 (sincroniza persona.estado/fecha_baja) y, desde este archivo, además SCJ-PRO-04 §VI: en baja_definitiva cierra todas las asignaciones vigentes de la persona con vigente_hasta = fecha_efectiva de la baja. *(V1.7, 128_: fecha_baja y cierre de asignaciones con `personas.fn_hoy_mexico(NEW.fecha_efectiva)`)* |
| `personas.fn_caller_activo()` | RPC | sí | authenticated,service_role | true si el usuario autenticado (auth.uid()) tiene una persona activa detrás. |
| `personas.fn_caller_es_administrador_generico()` | RPC | sí | authenticated | 88_. true si el llamador ocupa HOY (asignación vigente, sin herencia) un puesto con es_administrador_generico. Sólo datos propios; la usa fn_terminal_reconsentir. SECURITY DEFINER, search_path = personas, pg_temp; EXECUTE sólo authenticated. |
| `personas.fn_caller_persona_id()` | RPC | sí | authenticated | 88_. Persona del llamador (por auth.uid()); NULL si no tiene usuario. Sólo datos propios; la usa fn_terminal_reconsentir. SECURITY DEFINER, search_path = personas, pg_temp; EXECUTE sólo authenticated. |
| `personas.fn_caller_puestos_en_rama()` | RPC | sí | authenticated,service_role | Puestos vigentes del caller y sus descendientes (109_): filas de puesto_permiso que cada persona conserva para resolver su herencia. |
| `personas.fn_caller_tiene_permiso(p_codigo text)` | RPC | sí | authenticated,service_role | Permiso del PROPIO caller (auth.uid()), con herencia jerárquica y solo si la persona está activa (112_). |
| `personas.fn_caller_ve_estructura_permisos()` | RPC | sí | authenticated,service_role | Policies SELECT de puesto_permiso y su bitácora (109_): activo y con algún permiso de estructura. |
| `personas.fn_caller_ve_identidad()` | RPC | sí | authenticated,service_role | Conjunto estricto que puede leer la IDENTIDAD de una persona (110_): activo y con ver_modulo_1, alta_personas_usuarios, persona_edicion o cambio_estado_persona (con herencia). |
| `personas.fn_caller_ve_padron()` | RPC | sí | authenticated,service_role | true si el caller está activo y tiene alguno de los permisos de la lista cerrada del cuerpo (módulos 1-3, personas, estructura, Tiempo que lee nombres, Terminales): puede leer el padrón (personas.persona/expediente/usuario/asignacion ajenos). |
| `personas.fn_hoy_mexico(p_ahora timestamp with time zone)` | RPC | no | authenticated,service_role | Fecha de HOY en hora de México (America/Mexico_City), no la de UTC (113_). *(V1.7: la usan las 10 funciones de 127_ y fn_bitacora_sincroniza_persona, 128_)* |
| `personas.fn_persona_actualizar_datos(p_persona_id uuid, p_curp character varying, p_rfc character varying, p_nss character varying, p_primer_nombre character varying, p_segundo_nombre character varying, p_apellido_paterno character varying, p_apellido_materno character varying, p_fecha_nacimiento date, p_fecha_ingreso date, p_tipo_contrato character varying, p_documento_ref character varying)` | RPC | no | authenticated | RPC transaccional de edición de datos de persona/expediente (persona_edicion). |
| `personas.fn_persona_crear(p_primer_nombre character varying, p_apellido_paterno character varying, p_curp character varying, p_rfc character varying, p_nss character varying, p_fecha_nacimiento date, p_fecha_ingreso date, p_tipo_contrato character varying, p_documento_ref character varying, p_segundo_nombre character varying, p_apellido_materno character varying)` | RPC | no | authenticated | SCJ-PRO-01 A1: inserta personas.persona y personas.expediente en UNA transacción y devuelve la fila de persona (incluye id). |
| `personas.fn_persona_de_usuario(p_auth_user_id uuid)` | auxiliar | no | — | 88_. Persona de un usuario (auth_user_id); NULL si no tiene. Interna del trigger de la bitácora de enrolamiento; sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp. |
| `personas.fn_persona_identidad(p_persona_id uuid)` | RPC | sí | authenticated,service_role | Identidad de una persona (curp, rfc, nss, fecha_nacimiento) y su expediente (110_). |
| `personas.fn_persona_protege_columnas_identidad()` | trigger | no | — | Cierra el hueco de que persona_update_requiere_permiso (69_personas_edicion.sql) no puede distinguir columnas: RLS WITH CHECK sólo ve la fila NUEVA, no la anterior. |
| `personas.fn_persona_sincroniza_baja()` | trigger | no | — | Sincroniza estado y fecha_baja en ambos sentidos. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `personas.fn_persona_sincroniza_tiempo()` | trigger | sí | — | Crea el ancla tiempo.persona(id) al dar de alta una personas.persona -- sólo el id, ningún atributo de identidad cruza la frontera (SCJ-FRO-01). |
| `personas.fn_puesto_administrador_generico_inmutable()` | trigger | no | — | Aborta cualquier UPDATE que cambie es_administrador_generico, incluido service_role. |
| `personas.fn_puesto_permiso_sincroniza()` | trigger | no | — | Implementa SCJ-PRO-05 G8 ("crea o reactiva la fila"): ON CONFLICT (puesto_id, codigo) DO UPDATE resuelve en una sola sentencia el caso de otorgar un permiso ya revocado antes, apoyado en uq_puesto_permiso_puesto_codigo (22_personas_puesto_permiso.sql). |
| `personas.fn_usuario_bitacora_alta()` | trigger | no | — | Implementa SCJ-PRO-01 paso A3. |
| `personas.fn_usuario_es_administrador_generico(p_auth_user_id uuid)` | auxiliar | no | — | 88_. true si el usuario ocupa HOY (asignación vigente, sin herencia) un puesto con es_administrador_generico. Excepción de la regla de auto-asignación a una terminal (SCJ-PRO-15 §V.3). Interna del trigger; sin EXECUTE para la API. SECURITY INVOKER, search_path = personas, pg_temp. |
| `tiempo.fn_aprobacion_ausencia_actualiza_ausencia()` | trigger | sí | — | Recalcula ausencia.estado_autorizacion desde su cadena de pasos: cualquier rechazo cierra en 'rechazada'; todos los pasos en 'autorizada' cierra en 'autorizada'; cualquier otro caso se queda 'pendiente'. |
| `tiempo.fn_aprobacion_ausencia_bloquea_propia()` | trigger | sí | — | Trigger BEFORE INSERT de tiempo.aprobacion_ausencia (122_): nadie aprueba ni rechaza su propia ausencia (SCJ26 / ausencia_propia), sea cual sea el rol, incluso service_role y el dueño. |
| `tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta()` | trigger | no | — | Trigger BEFORE UPDATE OF tipo_de_ausencia de tiempo.ausencia (121_): si la ausencia ya no está pendiente, cambiar su tipo levanta SCJ25 / ausencia_resuelta_tipo_inmutable, también para service_role y el dueño. |
| `tiempo.fn_ausencia_resolver(p_ausencia_id bigint, p_decision character varying, p_tipo_de_ausencia character varying, p_motivo text)` | RPC | no | authenticated | RPC transaccional de "resolver ausencia" (SCJ-PRO-08): si decision=autorizada, reclasifica tipo_de_ausencia; siempre inserta el paso 1 de aprobacion_ausencia con el resultado -- ambas escrituras en una sola transacción. |
| `tiempo.fn_ausencia_resuelve_excepcion()` | trigger | sí | — | Si una ausencia se carga, se autoriza o se rechaza después de que ya se generó una excepcion por día sin checada, la resuelve sola. |
| `tiempo.fn_bitacora_config_terminal_inmutable()` | trigger | no | — | 97_. Aborta UPDATE/DELETE sobre tiempo.bitacora_config_terminal, incluido service_role y el dueño. Mensaje fijo + HINT estable. Sin EXECUTE para la API. |
| `tiempo.fn_bitacora_config_terminal_truncate()` | trigger | no | — | 97_. Aborta TRUNCATE sobre tiempo.bitacora_config_terminal (trigger por statement). Mensaje fijo + HINT estable. Sin EXECUTE para la API. |
| `tiempo.fn_bitacora_terminal_usuario_aplica()` | trigger | sí | — | Valida la transición de estado del enrolamiento y sincroniza tiempo.terminal_usuario [CALCULADO] desde cada fila de la bitácora (SCJ-DEC-11). |
| `tiempo.fn_bitacora_terminal_usuario_inmutable()` | trigger | no | — | Aborta cualquier UPDATE/DELETE sobre la bitácora, incluido service_role y el dueño. |
| `tiempo.fn_bitacora_terminal_usuario_limpia_detalle()` | trigger | no | — | 92_ (B2 de security). BEFORE INSERT en la bitácora de enrolamiento: quita del detalle los caracteres de formato Unicode invisibles o de reordenamiento (U+00AD, U+061C, U+200B-200F, U+2028-202E, U+2060-2064, U+2066-2069, U+FEFF, U+E0000-E007F) y pasa U+2028/2029 a espacio. Corre ANTES de fn_bitacora_terminal_usuario_ap… |
| `tiempo.fn_bitacora_terminal_usuario_truncate()` | trigger | no | — | Aborta TRUNCATE sobre la bitácora (trigger por statement, sin OLD). |
| `tiempo.fn_cierre_dia_armar(p_persona_id uuid, p_fecha date, p_estado character varying, p_horas_totales numeric, p_tramos jsonb, p_motivo_excepcion_dia text)` | RPC | sí | service_role | RPC transaccional del cierre de día (124_, SCJ-PRO-12): crea tiempo.dia, todos sus tramos (en el orden de p_tramos) y, si el día es bloqueado, la excepción de día, en UNA transacción: un fallo de cualquier trigger o de la propia validación revierte todo y no deja un día sin tramos. |
| `tiempo.fn_correccion_bloquea_marca_en_tramo()` | trigger | sí | — | 87_. BEFORE INSERT en tiempo.correccion: rechaza con SCJ15 / marca_en_tramo la corrección de una marca que es apertura o cierre de cualquier tramo (el recálculo de fn_correccion_recalcula_tramo no se refleja para nadie: 0 filas por RLS para el caller, o pisa las horas de RH para dueño/service_role). Corre para todos l… |
| `tiempo.fn_correccion_recalcula_tramo()` | trigger | no | — | SCJ-PRO-10. Recalcula únicamente el tramo (y el horas_totales del día) que involucra a la marca corregida — nunca el histórico completo. Cierra sola la excepcion pendiente asociada, mismo patrón que trg_ausencia_resuelve_excepcion. |
| `tiempo.fn_correccion_valida()` | trigger | no | — | SCJ-PRO-10. Exige que la marca ya tenga una excepcion (cualquier estado) y bloquea toda corrección que dejaría el valor corregido fuera del hueco entre la marca anterior y la siguiente de la misma persona — la corrección ajusta la hora, nunca el orden. |
| `tiempo.fn_corte_quincenal_aplicar_persona(p_persona_id uuid, p_periodo_desde date, p_periodo_hasta date, p_horas_esperadas numeric, p_horas_trabajadas numeric, p_clasificaciones jsonb, p_movimientos jsonb, p_motivo text)` | RPC | no | service_role | RPC transaccional de «aplicar corte quincenal a una persona» (SCJ-PRO-13, 119_): registra el periodo en corte_quincenal_aplicado (UNIQUE persona+periodo; SCJ23/periodo_ya_aplicado si ya existe), inserta las clasificaciones y los movimientos de saldo y crea banco_de_horas solo si hay movimientos, todo en una transacció… |
| `tiempo.fn_dia_calcular_armado_tramos(p_dia_id bigint)` | RPC | no | authenticated,service_role | Calcula (sin escribir) qué haría fn_dia_revisar al armar los tramos faltantes de un día: una fila por acción -- cerrar_existente (cierra un tramo abierto con una huérfana), nuevo (arma un tramo nuevo con un par de huérfanas), huerfana_sin_pareja (marca que quedaría sin pareja -- fn_dia_revisar bloquea con SCJ09 si apa… |
| `tiempo.fn_dia_revisar(p_dia_id bigint, p_horas_totales numeric)` | RPC | no | authenticated | RPC de "marcar día como revisado" (SCJ-DEC-06), con horas trabajadas capturadas a mano por RH. |
| `tiempo.fn_excepcion_descarte_inmutable()` | trigger | no | — | Aborta UPDATE/DELETE sobre tiempo.excepcion_descarte, incluido service_role y el dueño. |
| `tiempo.fn_excepcion_descarte_truncate()` | trigger | no | — | Aborta TRUNCATE sobre tiempo.excepcion_descarte (trigger por statement). |
| `tiempo.fn_excepcion_dia_cerrado_descartar(p_excepcion_id bigint, p_motivo text)` | RPC | sí | authenticated | 86_. Descarta una marca tardía sobre un día YA revisado: exige persona activa y el permiso de acción excepcion_dia_cerrado_descarte (no heredable) DENTRO de la función, deriva quién descarta de auth.uid(), registra quién/cuándo/por qué en tiempo.excepcion_descarte y resuelve la excepción con el sufijo ' — descartada p… |
| `tiempo.fn_excepcion_horario_descartar(p_excepcion_id bigint, p_motivo text)` | RPC | sí | authenticated | 125_. Descarta con constancia una alerta fuera_de_horario pendiente de una marca ajena cuyo día está cerrado o revisado: exige persona activa con excepcion_dia_cerrado_descarte (no heredable) DENTRO de la función, autor por auth.uid(), motivo de 10 a 500 caracteres, registra en tiempo.excepcion_descarte y resuelve la… |
| `tiempo.fn_excepcion_protege_columnas()` | trigger | no | — | 86_ (security ALTO-1). marca_id, dia_id y creado_en inmutables; motivo_revision sólo puede cambiar agregando un sufijo ' — ...' junto con pendiente -> resuelto. Error SCJ15 (excepcion_columna_inmutable \| excepcion_motivo_inmutable). SECURITY INVOKER con search_path fijo; sin EXECUTE para la API. |
| `tiempo.fn_excepcion_protege_dia_cerrado()` | trigger | sí | — | Constraint trigger de motivo dia_cerrado% (86_, reemplaza el de 78_): bloquea, al COMMIT (DEFERRABLE INITIALLY DEFERRED), cualquier pendiente -> resuelto que no sea (a) una revisión del día hecha en la misma transacción -- tramo que contiene la marca, del mismo día y persona de la marca, día revisado con revisado_en =… |
| `tiempo.fn_jornada_asignada_protege_borrado()` | trigger | no | — | BEFORE DELETE en tiempo.jornada_asignada. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_jornada_asignada_protege_vigencias()` | trigger | no | — | BEFORE UPDATE en tiempo.jornada_asignada. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_jornada_asignada_valida_cadena()` | trigger | no | — | CONSTRAINT TRIGGER (DEFERRABLE INITIALLY DEFERRED) sobre tiempo.jornada_asignada -- red de seguridad final al hacer COMMIT: cada persona con al menos una jornada debe quedar con exactamente una fila abierta (vigente_hasta NULL) y sin huecos/traslapes entre vigencias consecutivas. |
| `tiempo.fn_jornada_asignar_renovar(p_persona_id uuid, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer, p_confirma_cierre_vigente boolean)` | RPC | no | authenticated | RPC transaccional de "asignar/renovar jornada" (SCJ-PRO-09): si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |
| `tiempo.fn_jornada_en_curso_mover_limite(p_jornada_id bigint, p_vigente_hasta date)` | RPC | no | authenticated | RPC transaccional de "mover el límite de la jornada en curso": cambia vigente_hasta de la jornada vigente hoy a una fecha estrictamente futura, y desplaza vigente_desde de la única jornada siguiente para que la cadena quede sin hueco ni traslape. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_jornada_futura_actualizar(p_jornada_id bigint, p_tipo_jornada character varying, p_vigente_desde date, p_patron_semanal jsonb, p_descuento_comida_fija boolean, p_minutos_descuento_comida_fija integer)` | RPC | no | authenticated | RPC transaccional de "editar jornada futura": reemplazo TOTAL (no parcial) de tipo_jornada, vigente_desde, descuento de comida y patrón semanal completo, en una sola transacción. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_jornada_futura_eliminar(p_jornada_id bigint)` | RPC | no | authenticated | RPC transaccional de "eliminar jornada futura": borra el patron_semanal y la fila de jornada_asignada, y si existe una predecesora la reabre (vigente_hasta = NULL). *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_marca_fecha_local(p_marca_id bigint)` | auxiliar | no | — | Interna (86_). Fecha local EFECTIVA de la marca: valor de la corrección más reciente si existe, si no momento_dispositivo, más desfase_local. Mismo criterio que fn_dia_calcular_armado_tramos y el batch de cierre de día. Sin EXECUTE para la API: la usan funciones SECURITY DEFINER y triggers. |
| `tiempo.fn_marca_momento_efectivo(p_marca_id bigint)` | auxiliar | no | — | Interna (123_). Momento EFECTIVO de una marca: el valor de la corrección más reciente (creado_en desc, id desc) si existe, si no momento_dispositivo. Misma definición que fn_marca_fecha_local, fn_dia_calcular_armado_tramos y cierre_dia.py. Sin EXECUTE para la API: la usan funciones DEFINER y triggers. |
| `tiempo.fn_marca_rechazada_purgar(p_dias integer)` | RPC | sí | service_role | SCJ-DEC-12 §6. Único camino de borrado de tiempo.marca_rechazada: elimina las filas con más de p_dias días (por defecto 90, mínimo 7) y devuelve cuántas. SECURITY DEFINER, search_path fijo, EXECUTE sólo service_role (job del scheduler). |
| `tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)` | RPC | sí | service_role | SCJ-DEC-12 §3/§6. Ruta de marcas del puente: recibe un lote de eventos de UNA terminal (p_eventos jsonb) y devuelve {momento_recepcion, resultados:[{indice, evento_id, estado, codigo?}]}. Resuelve employee_no a persona_id en la base (nunca sale del servidor), fija origen=terminal, degrada estado_reloj, aplica topes de… |
| `tiempo.fn_marca_valida_revision()` | trigger | sí | — | SCJ-PRO-11. Calcula reloj_no_sincronizado, persona_inactiva, dia_cerrado y fuera_de_horario al llegar una marca — el quinto motivo, plantilla_desconocida, nace en Operación y no se calcula aquí. SECURITY DEFINER: terminal_checador sólo tiene INSERT en tiempo.marca, esta función necesita más lectura de la que ese rol d… |
| `tiempo.fn_movimiento_compensacion_valida()` | trigger | sí | — | Trigger BEFORE INSERT de tiempo.movimiento_de_saldo (120_): una compensación debe apuntar a un generado_quincena del mismo banco por el monto exacto en negativo. |
| `tiempo.fn_movimiento_de_saldo_actualiza_banco()` | trigger | sí | — | Única vía de escritura de banco_de_horas.monto y .vivo_desde (SCJ-DEC-02). |
| `tiempo.fn_movimiento_de_saldo_compensar(p_movimiento_id bigint, p_motivo text)` | RPC | sí | authenticated | Compensa un movimiento generado_quincena erróneo con el movimiento opuesto ligado (120_). |
| `tiempo.fn_movimiento_de_saldo_manual_registrar(p_persona_id uuid, p_tipo character varying, p_monto numeric, p_motivo text)` | RPC | sí | authenticated | RPC de registro manual de movimiento_de_saldo (SCJ-DEC-02): arrastrar inserta 2 filas (-monto/+monto, mismo motivo, mismo creado_en) para renovar antigüedad sin cambiar el saldo total; descontar/condonar insertan 1 sola fila (-monto). |
| `tiempo.fn_parametro_actualizar_valor(p_clave character varying, p_valor text, p_registrado_por uuid)` | RPC | no | service_role | RPC transaccional de "actualizar valor de parámetro": si no hay vigencia activa con esa clave, señaliza con RAISE EXCEPTION ... *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_parametro_inferir_audita()` | trigger | sí | — | 97_. Trigger de auditoría del interruptor de la activación por huella: registra en tiempo.bitacora_config_terminal TODO cambio de valor (o alta/baja de fila) de las claves terminal_inferir_huella_activa y terminal_inferir_huella_hasta, venga de donde venga (función dedicada, service_role directo, psql). La nota solo s… |
| `tiempo.fn_parametro_inferir_escribe(p_clave text, p_valor text, p_hoy date, p_actor uuid)` | auxiliar | sí | — | 97_. Interna de fn_terminal_inferir_huella_cambiar: escribe una clave del interruptor con versionado por vigencia (borde inclusivo; el mismo día corrige en sitio). Devuelve true si cambió el valor. SECURITY DEFINER, search_path = tiempo, pg_temp, EXECUTE para nadie. |
| `tiempo.fn_parametro_truncate_bloqueado()` | trigger | no | — | 97_. Aborta TRUNCATE sobre tiempo.parametro (incluido service_role y el dueño): un TRUNCATE no pasa por el trigger de auditoría por fila y vaciaría el interruptor de la activación por huella sin rastro. Mensaje fijo + HINT estable. SECURITY INVOKER, search_path = tiempo, pg_temp, sin EXECUTE para la API. |
| `tiempo.fn_patron_semanal_solo_jornada_futura()` | trigger | no | — | BEFORE UPDATE OR DELETE en tiempo.patron_semanal. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_patron_semanal_valida_tope_legal()` | trigger | no | — | SCJ-PRO-09. Suma las horas reales del patrón semanal completo de la jornada y la compara contra tope_legal.maximo_semanal vigente en jornada_asignada.vigente_desde. Sólo revienta para tipo_jornada=normal. DEFERRABLE INITIALLY DEFERRED para no fallar a medio insertar las filas del patrón. |
| `tiempo.fn_terminal_anomalias(p_terminal_id bigint, p_categoria text, p_desde timestamp with time zone, p_hasta timestamp with time zone, p_limite integer, p_desplazamiento integer)` | RPC | no | service_role | 90_/94_. Una categoría del tablero de anomalías de una terminal (marcas_posteriores_a_baja \| picos_de_tasa \| huecos_de_secuencia \| huellas_inferidas_exceso \| inferida_sin_marcas \| asignador_confirmador) como {total, items} paginado (p_limite 1..200, p_desplazamiento >= 0). Filtra SIEMPRE por la terminal pedida de… |
| `tiempo.fn_terminal_autenticar(p_hash text, p_ip text)` | RPC | sí | service_role | SCJ-DEC-12 §1/§3. Busca la credencial vigente por hash SHA-256 y la terminal activa; devuelve {terminal_id, serie, credencial_id, ip_cambio} o NULL. Escribe ultimo_uso_en/ultima_ip/ultimo_contacto_en como máximo una vez cada 30 s (siempre ante un cambio de IP). SECURITY DEFINER, search_path fijo, EXECUTE sólo service_… |
| `tiempo.fn_terminal_baja_por_caducidad(p_horas integer)` | RPC | sí | service_role | SCJ-DEC-12 §12.7. Emite baja_solicitada (origen web, autor = el del movimiento asignado de la alta, detalle "baja automática: sin huella tras N horas") de las altas en esperando_huella sin ninguna evidencia de huella (huella_capturada, huella_inferida o huella_confirmada_manual, 94_) cuyo movimiento usuario_creado tie… |
| `tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid)` | RPC | sí | service_role | SCJ-DEC-12 §5. Emite baja_solicitada de las altas de una persona NO activa (suspension, baja_definitiva o inexistente) con autor = el de su último movimiento REGISTRADO de suspension/baja_definitiva (91_: orden por creado_en DESC; fecha_efectiva sólo desempata). Devuelve el número emitido, 0 si está activa o no hay al… |
| `tiempo.fn_terminal_config_actualizar(p_clave text, p_valor text)` | RPC | sí | authenticated | 89_/97_. Edita una de las 5 claves terminal_* del catálogo de tiempo.parametro: exige persona activa y terminal_config_edicion DENTRO (42501/sin_permiso), clave en la lista blanca (22023/clave_no_editable; las dos claves del interruptor de la activación por huella se rechazan siempre: solo fn_terminal_inferir_huella_c… *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_terminal_config_catalogo()` | auxiliar | no | — | 89_. Valor por defecto y rango (mínimo, máximo) de las 5 claves terminal_* de tiempo.parametro. Única fuente para fn_terminal_config_actualizar y fn_terminal_config_valor; datos no sensibles. |
| `tiempo.fn_terminal_config_valor(p_clave text)` | RPC | sí | service_role | 89_. Valor vigente de una clave terminal_* para los jobs del backend: acotado a su rango; si falta o está mal formado devuelve el valor por defecto; NULL si la clave no es del catálogo. Nunca falla por un parámetro corrupto. SECURITY DEFINER, search_path = tiempo, pg_temp; EXECUTE sólo service_role. *(V1.7, 127_: «hoy» = `personas.fn_hoy_mexico()`, no CURRENT_DATE)* |
| `tiempo.fn_terminal_consentimiento_inmutable()` | trigger | no | — | Aborta UPDATE/DELETE sobre tiempo.terminal_consentimiento, incluido service_role y el dueño. |
| `tiempo.fn_terminal_consentimiento_publicar(p_texto text, p_cambio_material boolean, p_nota text, p_base_version integer)` | RPC | sí | authenticated | 88_. Publica una versión nueva del texto de consentimiento: exige persona activa y terminal_config_edicion DENTRO (42501/sin_permiso), deriva el autor de auth.uid(), sanea el texto (1 a 4000 caracteres, 22023/texto_invalido), serializa con LOCK TABLE y numera; si se manda p_base_version y ya no es la vigente, SCJ16 /… |
| `tiempo.fn_terminal_consentimiento_truncate()` | trigger | no | — | Aborta TRUNCATE sobre tiempo.terminal_consentimiento (trigger por statement). |
| `tiempo.fn_terminal_credencial_revocacion_inmutable()` | trigger | sí | — | SCJ-DEC-12 (revisión de security M3). |
| `tiempo.fn_terminal_inferir_huella_cambiar(p_activa boolean, p_nota text, p_hasta timestamp with time zone)` | RPC | sí | authenticated | 97_. Única ruta para encender/apagar el interruptor de la activación por huella. Gate DENTRO: persona activa y terminal_config_edicion (42501/sin_permiso). Encender exige nota de 10 a 500 caracteres saneados (22023/nota_requerida), p_hasta futuro y a lo más a 30 días (22023/hasta_invalido), consentimiento vigente publ… |
| `tiempo.fn_terminal_inferir_huella_estado()` | RPC | sí | service_role | 97_. Estado EFECTIVO del interruptor de la activación por huella: {activo, vencido, motivo, valor, hasta, encendido_por, encendido_en, ultimo_cambio_via_funcion, sin_registro} (quién y cuándo salen de la última fila de bitácora de la vigencia actual). UNA sola definición para el RPC de marcas (98_), el backend y el ta… |
| `tiempo.fn_terminal_latido(p_terminal_id bigint, p_hora_terminal timestamp with time zone, p_alcanzable boolean, p_reloj_sincronizado boolean, p_version_pi text, p_marcas_pendientes integer, p_ingesta_detenida boolean)` | RPC | sí | service_role | SCJ-DEC-12 §3. Guarda terminal_alcanzable, reloj_desfase_seg (terminal menos servidor), version_pi, marcas_pendientes e (99_) ingesta_detenida en tiempo.terminal y devuelve {hora_servidor, desfase_reloj_seg, ultima_secuencia_recibida}. p_reloj_sincronizado se recibe pero no se persiste. p_ingesta_detenida es opcional… |
| `tiempo.fn_terminal_mapa(p_terminal_id bigint)` | RPC | sí | service_role | SCJ-DEC-12 §3. Arreglo jsonb de las altas no-baja de la terminal: terminal_usuario_id, employee_no, estado, huellas_capturadas. Sin persona_id ni nombres. SECURITY DEFINER, EXECUTE sólo service_role. |
| `tiempo.fn_terminal_movimiento_registrar(p_terminal_id bigint, p_terminal_usuario_id bigint, p_tipo text, p_huellas integer, p_detalle text)` | RPC | sí | service_role | SCJ-DEC-12 §3. Movimiento del Pi (usuario_creado, huella_capturada, baja_confirmada, error) sobre una alta de la terminal p_terminal_id. FOR UPDATE de la alta; no_encontrado si no existe o es de otra terminal; ya_aplicado si el estado ya es el destino. Fija origen=terminal y registrado_por=NULL. Más de 20 errores de l… |
| `tiempo.fn_terminal_rechazo_registrar(p_terminal_id bigint, p_evento jsonb, p_codigo text)` | auxiliar | sí | — | Interna (SCJ-DEC-12 §6). Guarda en tiempo.marca_rechazada la evidencia de un rechazo definitivo de fn_marca_terminal_registrar, leyendo cada campo del evento de forma defensiva (sólo lo que cumple su formato). Tope de 5 000 filas por terminal en 24 h. Sin EXECUTE para la API. Al reescribirla repetir SECURITY DEFINER y… |
| `tiempo.fn_terminal_reconsentimiento_pendiente_ids()` | RPC | no | authenticated,service_role | 88_. Ids de tiempo.terminal_usuario con reconsentimiento pendiente (pendiente_alta \| esperando_huella \| activo con una versión menor que la última con cambio_material). Definición única: la usan fn_terminal_consentimiento_publicar, fn_terminal_reconsentir y el backend (tablero de anomalías, tarjeta #10). SECURITY IN… |
| `tiempo.fn_terminal_reconsentir(p_altas bigint[], p_consentimiento_id bigint, p_estricto boolean)` | RPC | no | authenticated | 88_. Registra un 'reconsentido' por cada alta del lote (hasta 200) que tenga el reconsentimiento pendiente y no sea la PROPIA del llamador (salvo el administrador genérico); las demás se devuelven en omitidas, con su motivo fijo en motivos_omision (alta_propia \| no_elegible) (con p_estricto = true se rechaza todo el… |
| `tiempo.fn_terminal_valida_desactivacion()` | trigger | sí | — | SCJ-DEC-12 §6. Aborta con SCJ13 (terminal_con_altas_vigentes) si se desactiva una terminal que aún tiene altas no-baja. Toma la fila de la terminal FOR UPDATE antes de contar (serializa con 'asignado', que la toma FOR SHARE). SECURITY DEFINER, search_path fijo, sin EXECUTE para la API. |
| `tiempo.fn_texto_sin_invisibles(p_texto text)` | auxiliar | no | — | 97_. Quita caracteres Unicode de formato/reordenamiento invisibles y convierte U+2028/U+2029 en espacio (misma regla que 92_ para el detalle de la bitácora de terminal). IMMUTABLE, search_path = pg_temp, sin EXECUTE para la API (solo la usa fn_terminal_inferir_huella_cambiar, como dueño). |
| `tiempo.fn_tope_legal_crear_vigencia(p_vigente_desde date, p_maximo_semanal numeric, p_maximo_extra numeric, p_confirma_cierre_vigente boolean)` | RPC | no | service_role | RPC transaccional de "crear vigencia de tope legal": si hay vigencia activa sin confirma_cierre_vigente, señaliza conflicto con RAISE EXCEPTION ... |
| `tiempo.fn_tramo_valida_coherencia()` | trigger | sí | — | 86_ (security ALTO-2). Las marcas de apertura y cierre de un tramo deben ser de la misma persona que el día y tener fecha local efectiva igual a la fecha del día. En UPDATE sólo se revisa si cambian dia_id o las marcas. SCJ15 / tramo_incoherente. SECURITY DEFINER SET search_path = tiempo, pg_temp; sin EXECUTE para la… |
| `tiempo.fn_tramo_valida_tiempos()` | trigger | sí | — | Trigger BEFORE INSERT OR UPDATE OF inicio, fin, minutos_trabajados, marca_apertura_id, marca_cierre_id de tiempo.tramo (123_): inicio = momento efectivo de la marca de apertura; con cierre, fin = efectivo del cierre y minutos_trabajados = (fin - inicio) en minutos (tolerancia 0.01); sin cierre, fin y minutos NULL. |

### V.2 Políticas RLS

Las 37 tablas tienen RLS habilitada y ninguna la tiene forzada (`FORCE`). El detalle de cada policy está en la sección de su tabla en II. Resumen (76 policies):

| Tabla | Policies |
|---|---|
| `tiempo.persona` | 1 (1 SELECT) |
| `tiempo.tope_legal` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.dia_festivo` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.parametro` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.jornada_asignada` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.patron_semanal` | 4 (1 DELETE, 1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.marca` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.dia` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.tramo` | 3 (1 INSERT, 1 SELECT, 1 UPDATE) |
| `tiempo.clasificacion_de_tiempo` | 1 (1 SELECT) |
| `tiempo.banco_de_horas` | 1 (1 SELECT) |
| `tiempo.movimiento_de_saldo` | 1 (1 SELECT) |
| `tiempo.correccion` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.ausencia` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.aprobacion_ausencia` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.excepcion` | 2 (1 SELECT, 1 UPDATE) |
| `tiempo.corrida_batch` | 1 (1 SELECT) |
| `tiempo.terminal` | 1 (1 SELECT) |
| `tiempo.terminal_usuario` | 1 (1 SELECT) |
| `tiempo.bitacora_movimiento_terminal_usuario` | 2 (1 INSERT, 1 SELECT) |
| `tiempo.terminal_credencial` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.marca_rechazada` | 1 (1 SELECT) |
| `tiempo.excepcion_descarte` | 1 (1 SELECT) |
| `tiempo.terminal_consentimiento` | 1 (1 SELECT) |
| `tiempo.corte_quincenal_aplicado` | 0 — sin policy: acceso denegado por omisión a roles sujetos a RLS |
| `tiempo.bitacora_config_terminal` | 1 (1 SELECT) |
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


- Sin policy (deny-by-default, a propósito): `tiempo.corte_quincenal_aplicado`, `tiempo.dia_festivo`, `tiempo.parametro`, `tiempo.terminal_credencial`, `tiempo.tope_legal`. Se acceden por `service_role` o por RPC.
- `anon` **no tiene ningún privilegio de tabla en ninguna de las 37 tablas** (`100_`, `102_`, `103_`).
- Sin `UPDATE` ni `DELETE` para `authenticated` ni `service_role` (solo inserción/lectura): `personas.bitacora_movimiento_persona`, `personas.bitacora_movimiento_puesto_permiso`, `tiempo.bitacora_config_terminal`, `tiempo.bitacora_movimiento_terminal_usuario`, `tiempo.correccion`, `tiempo.corte_quincenal_aplicado`, `tiempo.excepcion_descarte`, `tiempo.marca_rechazada`, `tiempo.marca`, `tiempo.movimiento_de_saldo`, `tiempo.terminal_consentimiento`, `tiempo.terminal_credencial`, `tiempo.terminal_usuario`, `tiempo.terminal`. Las bitácoras y `tiempo.excepcion_descarte` además están protegidas por triggers de inmutabilidad que aplican incluso al dueño.
- Nadie de la API puede ejecutar `TRUNCATE`, `REFERENCES`, `TRIGGER` ni `MAINTAIN` (`100_`, `102_`); el privilegio efectivo de cada tabla está en su sección de II.
- Roles de plataforma esperados (no creados por el DDL): `anon`, `authenticated`, `service_role`, `authenticator`. El rol `terminal_checador` (`37_`) quedó vacío y `NOLOGIN` desde `93_`; el DDL no le concede nada.

### V.3 Códigos de error propios (`ERRCODE 'SCJnn'`) *(regenerado en V1.6)*

El DDL define sus propios `SQLSTATE` para que el backend distinga el caso sin leer el texto del error. Cada excepción trae un `HINT` con un token estable y **siempre un literal fijo** (nunca armado con datos de la fila o del llamador); el mensaje tampoco lleva valores ni identificadores. Alta de un `HINT` nuevo = avisar a backend en el mismo cambio. La tabla sale de los `RAISE EXCEPTION … USING ERRCODE/HINT` literales de `db/ddl/` (las filas con *(V1.6)* tienen como «Significa» el mensaje fijo de la excepción; el resto conserva la redacción de versiones anteriores, que incluye el mapeo de backend).

| `SQLSTATE` | `HINT` | Dónde | Significa |
|---|---|---|---|
| `22023` | `categoria_invalida` | `tiempo.fn_terminal_anomalias` | Terminal inexistente, categoría fuera de las 3, ventana nula/invertida/de más de 90 días, o paginación fuera de rango. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `clave_no_editable` | `tiempo.fn_terminal_config_actualizar` | Clave fuera de la lista blanca; valor no entero, fuera de rango o que rompe traslape*2 <= antigüedad_meses*30. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `fecha_efectiva_invalida` | `personas.fn_bitacora_persona_fija_hora` | Un movimiento de persona enviado por la API con `fecha_efectiva` fuera de [now() − 90 días, now() + 5 minutos]. Backend: 422 |
| `22023` | `hasta_invalido` | `tiempo.fn_terminal_inferir_huella_cambiar` | El vencimiento debe ser futuro y a lo más a 30 días *(V1.6)* |
| `22023` | `horas_invalidas` | `tiempo.fn_terminal_baja_por_caducidad` | Horas de caducidad menores al mínimo de 4 (o NULL) |
| `22023` | `huellas_invalidas` | `tiempo.fn_terminal_movimiento_registrar` | Conteo de huellas fuera de 1-10 |
| `22023` | `lote_invalido` | `tiempo.fn_marca_terminal_registrar`, `tiempo.fn_terminal_reconsentir` | El lote no es un arreglo, está vacío o excede 200 eventos |
| `22023` | `lote_no_elegible` | `tiempo.fn_terminal_reconsentir` | Con p_estricto = true, el lote trae altas sin el reconsentimiento pendiente (ids en DETAIL). Backend: 409 |
| `22023` | `motivo_invalido` | `tiempo.fn_excepcion_dia_cerrado_descartar` | Motivo vacío. Backend: 422 |
| `22023` | `nota_invalida` | `tiempo.fn_terminal_consentimiento_publicar` | Texto fuera de 1 a 4000 caracteres, nota de más de 200, o lote de reconsentimientos vacío/NULL/de más de 200. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `nota_requerida` | `tiempo.fn_terminal_inferir_huella_cambiar` | Encender exige una nota de entre 10 y 500 caracteres *(V1.6)* |
| `22023` | `paginacion_invalida` | `tiempo.fn_terminal_anomalias` | Terminal inexistente, categoría fuera de las 3, ventana nula/invertida/de más de 90 días, o paginación fuera de rango. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `parametros_invalidos` | `tiempo.fn_terminal_inferir_huella_cambiar` | Falta indicar si se enciende o se apaga *(V1.6)* |
| `22023` | `retencion_invalida` | `tiempo.fn_marca_rechazada_purgar` | Retención menor al mínimo de 7 días |
| `22023` | `terminal_invalida` | `tiempo.fn_terminal_anomalias` | Terminal inexistente, categoría fuera de las 3, ventana nula/invertida/de más de 90 días, o paginación fuera de rango. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `terminal_no_activa` | `tiempo.fn_terminal_inferir_huella_cambiar` | No hay ninguna terminal activa *(V1.6)* |
| `22023` | `texto_invalido` | `tiempo.fn_terminal_consentimiento_publicar` | Texto fuera de 1 a 4000 caracteres, nota de más de 200, o lote de reconsentimientos vacío/NULL/de más de 200. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `valor_invalido` | `tiempo.fn_terminal_config_actualizar` | Clave fuera de la lista blanca; valor no entero, fuera de rango o que rompe traslape*2 <= antigüedad_meses*30. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `ventana_invalida` | `tiempo.fn_terminal_anomalias` | Terminal inexistente, categoría fuera de las 3, ventana nula/invertida/de más de 90 días, o paginación fuera de rango. Backend: 422 *(texto compartido por varios hints en V1.3–V1.4)* |
| `22023` | `vigencias_inconsistentes` | `tiempo.fn_parametro_inferir_escribe` | Las vigencias del interruptor son inconsistentes *(V1.6)* |
| `42501` | `sin_permiso` | `tiempo.fn_excepcion_dia_cerrado_descartar`, `tiempo.fn_excepcion_horario_descartar`, `tiempo.fn_terminal_config_actualizar`, `tiempo.fn_terminal_consentimiento_publicar`, `tiempo.fn_terminal_inferir_huella_cambiar`, `tiempo.fn_terminal_reconsentir` | Falta persona activa o terminal_config_edicion. Backend: 403 |
| `P0001` | `bitacora_inmutable` | `tiempo.fn_bitacora_config_terminal_inmutable`, `tiempo.fn_bitacora_config_terminal_truncate` | La bitácora de configuración de terminales es de solo inserción *(V1.6)* |
| `P0001` | `parametro_truncate_bloqueado` | `tiempo.fn_parametro_truncate_bloqueado` | tiempo.parametro no admite TRUNCATE *(V1.6)* |
| `SCJ11` | `transicion_invalida` | `tiempo.fn_bitacora_terminal_usuario_aplica`, `tiempo.fn_terminal_movimiento_registrar` | Transición de estado inválida, o la fila viva no coincide con el movimiento |
| `SCJ12` | `alta_duplicada` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La persona ya tiene un alta vigente en esa terminal |
| `SCJ12` | `auto_asignacion_prohibida` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La persona asignada es la del propio llamador y éste no ocupa un puesto con `es_administrador_generico`. Backend: 422 |
| `SCJ12` | `auto_confirmacion_huella_prohibida` | `tiempo.fn_bitacora_terminal_usuario_aplica` | No puedes confirmar tu propia huella; la confirma otra persona con permiso *(V1.6)* |
| `SCJ12` | `auto_reconsentimiento_prohibido` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La alta cuyo reconsentimiento se registra es la del propio llamador y éste no ocupa un puesto con `es_administrador_generico` (misma regla y excepción que la auto-asignación; pedir la propia baja sí se puede). Backend: 422 |
| `SCJ12` | `marca_no_corresponde` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La marca no corresponde a esta alta o ya se usó como evidencia *(V1.6)* |
| `SCJ12` | `misma_persona_que_asigno` | `tiempo.fn_bitacora_terminal_usuario_aplica` | Quien asignó la alta no puede confirmar su huella; la confirma otra persona con permiso *(V1.6)* |
| `SCJ12` | `nota_requerida` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La confirmación manual exige una nota de al menos % caracteres *(V1.6)* |
| `SCJ12` | `persona_no_activa` | `tiempo.fn_bitacora_terminal_usuario_aplica` | La persona no existe o no está `activo` |
| `SCJ12` | `terminal_no_valida` | `tiempo.fn_bitacora_terminal_usuario_aplica`, `tiempo.fn_marca_terminal_registrar`, `tiempo.fn_terminal_latido` | La terminal no existe o no está activa |
| `SCJ13` | `terminal_con_altas_vigentes` | `tiempo.fn_terminal_valida_desactivacion` | No se puede desactivar una terminal con altas no-`baja` |
| `SCJ14` | `credencial_revocada_inmutable` | `tiempo.fn_terminal_credencial_revocacion_inmutable` | Una revocación de llave ya fijada no se puede deshacer ni cambiar |
| `SCJ15` | `dia_cerrado_requiere_revision` | `tiempo.fn_excepcion_protege_dia_cerrado` | Una excepción `dia_cerrado` sólo se resuelve revisando el día en la misma transacción o descartando la marca tardía. Backend: 409 |
| `SCJ15` | `dia_no_revisado` | `tiempo.fn_excepcion_dia_cerrado_descartar` | El día de la marca no está revisado, o la excepción no es una `dia_cerrado` de marca pendiente (o ya está resuelta por otra vía). Backend: 409 *(texto compartido por varios hints en V1.3–V1.4)* |
| `SCJ15` | `excepcion_columna_inmutable` | `tiempo.fn_excepcion_protege_columnas` | Se intentó cambiar `marca_id`/`dia_id`/`creado_en`, o el motivo de otra forma que agregando un sufijo al resolver *(texto compartido por varios hints en V1.3–V1.4)* |
| `SCJ15` | `excepcion_motivo_inmutable` | `tiempo.fn_excepcion_protege_columnas` | Se intentó cambiar `marca_id`/`dia_id`/`creado_en`, o el motivo de otra forma que agregando un sufijo al resolver *(texto compartido por varios hints en V1.3–V1.4)* |
| `SCJ15` | `excepcion_no_descartable` | `tiempo.fn_excepcion_dia_cerrado_descartar` | El día de la marca no está revisado, o la excepción no es una `dia_cerrado` de marca pendiente (o ya está resuelta por otra vía). Backend: 409 *(texto compartido por varios hints en V1.3–V1.4)* |
| `SCJ15` | `marca_en_tramo` | `tiempo.fn_correccion_bloquea_marca_en_tramo` | Se intentó corregir la hora de una marca que ya es apertura o cierre de un tramo (cerrado o abierto). Backend: 409 |
| `SCJ15` | `tramo_incoherente` | `tiempo.fn_tramo_valida_coherencia` | Un tramo con marcas de otra persona o de otra fecha local efectiva que su día. Backend: 422 |
| `SCJ15` | `tramo_tiempos_incoherentes` | `tiempo.fn_tramo_valida_tiempos` | Los tiempos del tramo no coinciden con sus marcas. *(V1.6)* |
| `SCJ16` | `consentimiento_desactualizado` | `tiempo.fn_bitacora_terminal_usuario_aplica`, `tiempo.fn_terminal_reconsentir` | La versión enviada en 'asignado'/'reconsentido' no es la vigente. Backend: 409, mensaje fijo "El texto de consentimiento cambió; vuelve a leerlo" y devolver el texto vigente |
| `SCJ16` | `consentimiento_requerido` | `tiempo.fn_bitacora_terminal_usuario_aplica` | 'asignado'/'reconsentido' sin consentimiento_id. Backend: 422 |
| `SCJ16` | `sin_consentimiento_vigente` | `tiempo.fn_terminal_inferir_huella_cambiar` | No hay un texto de consentimiento biométrico vigente publicado *(V1.6)* |
| `SCJ16` | `version_base_desactualizada` | `tiempo.fn_terminal_consentimiento_publicar` | Se mandó p_base_version y otra persona publicó una versión nueva mientras tanto (publicación concurrente). Backend: 409 |
| `SCJ17` | `clave_reservada` | `tiempo.fn_parametro_actualizar_valor` | Clave terminal_% por la ruta genérica de Parámetros; sólo `fn_terminal_config_actualizar`. Backend: 409 |
| `SCJ18` | `banco_inexistente` | `tiempo.fn_movimiento_de_saldo_actualiza_banco` | El banco de horas del movimiento no existe *(V1.6)* |
| `SCJ19` | `autoasignacion_no_permitida` | `personas.fn_asignacion_valida_reglas` | No puede asignarse ni recolocarse a sí mismo en un puesto. *(V1.6)* |
| `SCJ20` | `vigencia_futura_no_permitida` | `personas.fn_asignacion_valida_reglas` | La asignación no puede tener una fecha de inicio futura. *(V1.6)* |
| `SCJ21` | `plazas_llenas` | `personas.fn_asignacion_valida_plazas` | El puesto no tiene plazas libres. *(V1.6)* |
| `SCJ22` | `expediente_incompleto` | `personas.fn_persona_actualizar_datos` | Para crear el expediente se requieren tipo de contrato y folio. *(V1.6)* |
| `SCJ23` | `periodo_ya_aplicado` | `tiempo.fn_corte_quincenal_aplicar_persona` | El corte quincenal de este periodo ya se aplicó a esta persona. *(V1.6)* |
| `SCJ24` | `compensacion_no_coincide` | `tiempo.fn_movimiento_compensacion_valida` | La compensación debe ser del mismo banco y por el monto exacto, en negativo. *(V1.6)* |
| `SCJ24` | `compensacion_propia` | `tiempo.fn_movimiento_de_saldo_compensar` | No puedes compensar movimientos de tu propio banco de horas. *(V1.6)* |
| `SCJ24` | `motivo_demasiado_largo` | `tiempo.fn_movimiento_de_saldo_compensar` | El motivo no puede exceder 500 caracteres. *(V1.6)* |
| `SCJ24` | `motivo_obligatorio` | `tiempo.fn_movimiento_de_saldo_compensar` | El motivo es obligatorio. *(V1.6)* |
| `SCJ24` | `movimiento_inexistente` | `tiempo.fn_movimiento_compensacion_valida`, `tiempo.fn_movimiento_de_saldo_compensar` | El movimiento a compensar no existe. *(V1.6)* |
| `SCJ24` | `no_compensable` | `tiempo.fn_movimiento_compensacion_valida`, `tiempo.fn_movimiento_de_saldo_compensar` | Solo se puede compensar un movimiento generado por el corte quincenal. *(V1.6)* |
| `SCJ24` | `saldo_insuficiente` | `tiempo.fn_movimiento_compensacion_valida`, `tiempo.fn_movimiento_de_saldo_compensar` | La compensación dejaría el saldo por debajo de cero. *(V1.6)* |
| `SCJ24` | `ya_compensado` | `tiempo.fn_movimiento_de_saldo_compensar` | Este movimiento ya fue compensado. *(V1.6)* |
| `SCJ25` | `ausencia_resuelta_tipo_inmutable` | `tiempo.fn_ausencia_bloquea_cambio_tipo_resuelta` | No se puede cambiar el tipo de una ausencia que ya no está pendiente. *(V1.6)* |
| `SCJ26` | `ausencia_propia` | `tiempo.fn_aprobacion_ausencia_bloquea_propia`, `tiempo.fn_ausencia_resolver` | No puedes resolver tu propia ausencia. *(V1.6)* |
| `SCJ27` | `dia_ya_existe` | `tiempo.fn_cierre_dia_armar` | Ya existe el día de esta persona y fecha. *(V1.6)* |
| `SCJ27` | `estado_invalido` | `tiempo.fn_cierre_dia_armar` | El estado del día debe ser cerrado o bloqueado. *(V1.6)* |
| `SCJ27` | `horas_fuera_de_rango` | `tiempo.fn_cierre_dia_armar` | Las horas del día deben estar entre 0 y 24. *(V1.6)* |
| `SCJ27` | `tramos_inconsistentes` | `tiempo.fn_cierre_dia_armar` | El cierre del día necesita al menos un tramo. *(V1.6)* |
| `SCJ28` | `alerta_propia` | `tiempo.fn_excepcion_horario_descartar` | No puedes descartar tu propia alerta de horario. *(V1.6)* |
| `SCJ28` | `dia_no_cerrado` | `tiempo.fn_excepcion_horario_descartar` | El día de la marca no está cerrado ni revisado; se resuelve corrigiendo la marca o revisando el día. *(V1.6)* |
| `SCJ28` | `excepcion_inexistente` | `tiempo.fn_excepcion_horario_descartar` | La excepción no existe. *(V1.6)* |
| `SCJ28` | `motivo_corto` | `tiempo.fn_excepcion_horario_descartar` | El motivo del descarte es demasiado corto. *(V1.6)* |
| `SCJ28` | `motivo_largo` | `tiempo.fn_excepcion_horario_descartar` | El motivo del descarte es demasiado largo. *(V1.6)* |
| `SCJ28` | `motivo_obligatorio` | `tiempo.fn_excepcion_horario_descartar` | El motivo del descarte es obligatorio. *(V1.6)* |
| `SCJ28` | `no_es_alerta_de_horario` | `tiempo.fn_excepcion_horario_descartar` | La excepción no es una alerta de horario. *(V1.6)* |
| `SCJ28` | `ya_resuelta` | `tiempo.fn_excepcion_horario_descartar` | La excepción ya está resuelta. *(V1.6)* |

`22023` (`invalid_parameter_value`), `23514` (`check_violation`), `42501` (`insufficient_privilege`) y `P0001` (`raise_exception`) son códigos estándar, no propios; se listan porque el backend distingue por su `HINT`. Los códigos de resultado por evento de `fn_marca_terminal_registrar` (`confirmado`, `duplicado`, `rechazo_definitivo`/`rechazo_transitorio` con su `codigo`) no son errores SQL: viajan en el `jsonb` de respuesta (`SCJ-CDT-01 §IX.6`).

**Códigos propios sin `HINT`** (anteriores; el backend los distingue solo por el `SQLSTATE`):

| `SQLSTATE` | Dónde |
|---|---|
| `23514` | `tiempo.fn_jornada_asignada_protege_borrado`, `tiempo.fn_jornada_asignada_protege_vigencias`, `tiempo.fn_jornada_asignada_valida_cadena`, `tiempo.fn_patron_semanal_solo_jornada_futura` |
| `42501` | `personas.fn_persona_actualizar_datos`, `personas.fn_persona_identidad`, `personas.fn_persona_protege_columnas_identidad`, `tiempo.fn_excepcion_protege_dia_cerrado`, `tiempo.fn_movimiento_de_saldo_compensar`, `tiempo.fn_movimiento_de_saldo_manual_registrar` |
| `SCJ01` | `tiempo.fn_jornada_asignar_renovar`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar`, `tiempo.fn_jornada_futura_eliminar`, `tiempo.fn_movimiento_de_saldo_manual_registrar`, `tiempo.fn_tope_legal_crear_vigencia` |
| `SCJ02` | `tiempo.fn_ausencia_resolver`, `tiempo.fn_jornada_asignar_renovar`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar`, `tiempo.fn_jornada_futura_eliminar`, `tiempo.fn_movimiento_de_saldo_manual_registrar`, `tiempo.fn_parametro_actualizar_valor`, `tiempo.fn_parametro_inferir_escribe`, `tiempo.fn_terminal_config_actualizar` |
| `SCJ03` | `tiempo.fn_ausencia_resolver`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar`, `tiempo.fn_jornada_futura_eliminar`, `tiempo.fn_movimiento_de_saldo_manual_registrar` |
| `SCJ04` | `tiempo.fn_ausencia_resolver`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar`, `tiempo.fn_movimiento_de_saldo_manual_registrar` |
| `SCJ05` | `tiempo.fn_corte_quincenal_aplicar_persona`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar` |
| `SCJ06` | `tiempo.fn_dia_revisar`, `tiempo.fn_jornada_en_curso_mover_limite`, `tiempo.fn_jornada_futura_actualizar` |
| `SCJ07` | `tiempo.fn_dia_revisar` |
| `SCJ08` | `tiempo.fn_dia_revisar` |
| `SCJ09` | `tiempo.fn_dia_revisar` |
| `SCJ10` | `personas.fn_persona_actualizar_datos` |

---

## Nota de método

**V1.6 (21-oct-2026):**

1. Se leyeron los scripts de `db/ddl/` (`00_esquemas.sql` a `125_*.sql`) y `db/verificar_ddl.sql`, y se contrastó contra la **base real de Supabase**, en **solo lectura** (`SET default_transaction_read_only = on`): `pg_class`, `pg_attribute`, `pg_constraint`, `pg_indexes`, `pg_trigger`, `pg_policies`, `pg_proc` (incluidos `prosecdef`, `proconfig` y `proacl`), `has_table_privilege`/`has_function_privilege` para `anon`, `authenticated` y `service_role`, y los catálogos `personas.permiso` y `tiempo.parametro`. No se leyó ningún dato de las tablas de negocio.
2. Un script efímero (fuera del repositorio) volcó ese catálogo a JSON y generó las secciones I, II, III, V.1, V.2 y V.3. Los tipos, nulos, predeterminados, restricciones, índices, triggers, policies y privilegios son los de la base viva; las descripciones son los `COMMENT ON`.
3. Los `ERRCODE`/`HINT` de V.3 se extrajeron de los `RAISE EXCEPTION … USING` literales del DDL y se asociaron a la función que los levanta.
4. Límites: los privilegios por tabla son los efectivos para los tres roles de la API; no se listan los privilegios de columna (hay `GRANT` de columnas en `personas.persona`, `tiempo.ausencia`, `tiempo.terminal` y `tiempo.terminal_credencial`; ver `db/verificar_ddl.sql`). El cuerpo íntegro de las funciones no se transcribe: solo su primera frase de `COMMENT ON`. La columna «Ejecutable por» de V.1 refleja `EXECUTE` de `anon`, `authenticated` y `service_role` (y `PUBLIC` si lo conserva).

**Historial de método (V1.0 a V1.5):**

1. Se leyeron los 80 scripts de `db/ddl/` (`00_esquemas.sql` a `79_*.sql`), `db/verificar_ddl.sql`, `SCJ-MOD-02`, `SCJ-MOD-03`, `CLAUDE.md` y `docs/03-decisiones/`.
2. Se levantó un contenedor PostgreSQL 16 nuevo y efímero (nombre propio, puerto 55439, borrado al terminar) con stubs mínimos de Supabase: roles `anon`, `authenticated`, `service_role` (BYPASSRLS), `authenticator`; esquema `auth` (`users`, `uid()`, `role()`) y `storage` (`buckets`, `objects`). Los 80 scripts corrieron en orden sin un solo error. Resultado: personas = 11, tiempo = 17, 49 permisos, 8 parámetros: coincide con `db/verificar_ddl.sql`. No se tocó ninguna base real, servidor ni Supabase.
3. Un script Python consultó `pg_catalog` (columnas, restricciones, índices, triggers, policies, privilegios, funciones) y generó las secciones II a V. Las descripciones son los `COMMENT ON` textuales; las columnas sin comentario se marcan como tales.
4. **No se verificó contra una BD viva** (producción/dev): el estado es el que produce el DDL, no el de la base real. Los stubs de Supabase pueden diferir de la plataforma (privilegios por omisión de `anon`/`authenticated` en esquemas nuevos, `search_path`, extensiones). Los privilegios por tabla reportados son los del contenedor de prueba tras aplicar los scripts. No se leyó el código del backend: las notas de "consumo en backend" vienen de comentarios y documentos. Las expresiones `CHECK`/`USING` se muestran simplificadas (se quitaron casts).

5. **V1.2 (6-oct-2026):** las secciones de `tiempo.terminal`, `tiempo.terminal_usuario` y `tiempo.bitacora_movimiento_terminal_usuario` se escribieron a partir de los scripts `80` y `81` y de sus `COMMENT ON`, y se contrastaron con la base real de Supabase (no con un contenedor desechable) mediante `db/verificar_ddl.sql` y un ensayo con `ROLLBACK` (61 casos, 61 aprobados); el resto del diccionario no se regeneró y conserva el método de V1.1. Los conteos globales (39 funciones, 74 policies, 23 dominios cerrados, 51 permisos) suman lo que aportan `80` y `81` a los de V1.1.
6. **V1.3 (6-oct-2026):** las secciones de `tiempo.terminal_credencial` y `tiempo.marca_rechazada`, las 4 columnas nuevas de `tiempo.terminal` y las 11 funciones nuevas se escribieron a partir de los scripts `82` a `85` Y se contrastaron contra la base real de Supabase en solo lectura: columnas, tipos, nulos y predeterminados (`information_schema`), restricciones, índices y triggers (`pg_constraint`, `pg_indexes`, `pg_trigger`), privilegios de tabla y de columna (`has_table_privilege`, `has_column_privilege`), `EXECUTE`, `SECURITY DEFINER` y `proconfig` por función (`pg_proc`), y las 75 policies (`pg_policies`). Las descripciones de columnas y funciones son los `COMMENT ON` leídos de la base. **Hallazgo del contraste y su cierre:** el 6-oct el catálogo real tenía 49 funciones, no 50: faltaba `78_tiempo_excepcion_protege_dia_cerrado.sql`, que el usuario aplicó el 7-oct sin ensayo; cubría sólo el `UPDATE` suelto de una excepción `dia_cerrado` y `security` identificó dos evasiones (cambiar primero el motivo y resolver después; sembrar un tramo falso por la vía de escritura de `tramo`). El cierre es `86_tiempo_excepcion_protege_dia_cerrado_v2.sql`: ensayado con `BEGIN … ROLLBACK` (100 casos, 100 aprobados), revisado por `security` y aplicado por el usuario el 7-oct-2026; tras aplicarlo, `db/verificar_ddl.sql` completo dio 0 filas en todas las secciones y el diagnóstico de solo lectura dio 0 `dia_cerrado` resueltas sin tramo ni descarte y 0 motivos alterados. **Residuales aceptados (B2 de `security`):** `dia_update_revision` (`62_`/`77_`) deja a quien tenga `dia_revision_edicion` pasar un día bloqueado/cerrado a `revisado` por PostgREST directo sin armar tramos; quien tenga además `excepcion_dia_cerrado_descarte` puede marcar el día revisado y descartar la marca tardía. Queda auditado (`revisado_por`/`revisado_en` y la fila de `excepcion_descarte`) y exige dos permisos explícitos; revisar cuando se endurezca `tiempo.dia`. Además, una marca con DOS excepciones pendientes (p. ej. `reloj_no_sincronizado` y `dia_cerrado`) no se puede corregir hasta revisar el día. Conteos finales tras `87_`: 34 tablas, 57 funciones, 76 policies, 52 permisos, 88 scripts. **`87_`** (ensayo 47/47 con `ROLLBACK`, revisado por `security`) bloquea en la base la corrección de una marca ya incluida en un tramo, porque por la API el recálculo de `fn_correccion_recalcula_tramo` (INVOKER) afectaba 0 filas por RLS en tramos cerrados y fallaba con 42501 en abiertos, mientras que como dueño o `service_role` pisaba las horas manuales de RH y el descuento de pausa. Consecuencia de producto: después de `cierre_dia` casi ninguna marca es corregible por esta vía hasta que exista un RPC dedicado. El resto del diccionario no se regeneró y conserva el método de V1.1. Las 24 columnas con dominio cerrado suman la nueva de `marca_rechazada.codigo` a las 23 de V1.2.

### Discrepancias entre el DDL y SCJ-MOD-03 (heredado de V1.5; `SCJ-MOD-03` hoy V1.9, ver nota de estado)

> **Estado (5-oct-2026):** las discrepancias 1 a 12 se corrigieron en `SCJ-MOD-03` V1.6. Siguen abiertas la 13 (cuenta de tablas en `SCJ-MOD-02`) y la 14 (los `COMMENT ON` obsoletos viven en el DDL: corregirlos exige un script nuevo).

1. **Alcance:** `SCJ-MOD-03` sólo cubre `tiempo` y llega a `02`/`03`; no menciona el esquema `personas` (11 tablas), RLS (70 policies), las RPC ni los scripts `04` a `79`. Su pie dice "V1.1" aunque el encabezado dice V1.5.
2. **§I archivos:** lista `00`-`03` y `db/indices/01_indices.sql`; el DDL real son 80 scripts, y los índices de FK están además en `30_indices_fk.sql`.
3. **§II `btree_gist`:** se declara extensión requerida, pero ningún script ejecuta `CREATE EXTENSION` (el comentario de `00_esquemas.sql` dice "y las extensiones requeridas", sin crearlas) y no hay ninguna restricción `EXCLUDE`.
4. **§III identificadores:** dice que `tiempo.persona.id` es la única excepción a `bigint IDENTITY`; en realidad todas las tablas de `personas` usan `uuid` (`gen_random_uuid()`) y `personas.permiso` usa `codigo` como PK.
5. **§III duraciones:** "`numeric(6,2)`" no es uniforme: `dia.horas_totales` y `patron_semanal.horas_efectivas` son `numeric(5,2)`; `banco_de_horas.monto` y `movimiento_de_saldo.monto` son `numeric(8,2)`.
6. **§IV/§V traslape de vigencias (`SCJ-DEC-04`, "en la aplicación"):** hoy la base también protege `jornada_asignada`: `trg_jornada_asignada_valida_cadena` (CONSTRAINT TRIGGER diferido: una sola fila abierta, sin huecos ni traslapes), `protege_vigencias` y `protege_borrado`. `tope_legal` sigue sin protección de traslape en la base (sólo UK en `vigente_desde`; hay RPC `fn_tope_legal_crear_vigencia`).
6b. **V1.4 (8-oct-2026):** las secciones y filas de `88_` a `92_` (tabla `tiempo.terminal_consentimiento`, columna `consentimiento_id` en la bitácora y en la tabla viva, tipo `reconsentido`, 5 claves `terminal_*`, 9 funciones nuevas, columna `usuario_creado_en`, `SCJ16`/`SCJ17`, permiso `terminal_config_edicion`) se escribieron a partir de los scripts y de sus `COMMENT ON`, ensayados con `BEGIN … ROLLBACK` el 8-oct-2026 (`db/ensayos/ensayo_88.sql` 143/143, `ensayo_89.sql` 60/60 y `ensayo_90.sql` 21/21) **antes** de aplicarse; se contrastaron contra el catálogo real el 2026-10-08, una vez aplicados, sin diferencias (`db/verificar_ddl.sql` completo: secciones 46 a 55 en 0 filas).
7. **§IV/§V inmutabilidad de `marca`:** dice que no hay restricción por permisos; hoy `marca` no tiene `UPDATE`/`DELETE` para `anon`/`authenticated`/`service_role` (sólo `IS`).
8. **§IV `banco_de_horas`:** "sin restricción de base" sigue siendo cierto a nivel de privilegio (`DISU`), pero la tabla tiene RLS y trigger único de escritura vía `movimiento_de_saldo`.
9. **§IV tope legal:** el CONSTRAINT TRIGGER está en `patron_semanal` y es `AFTER INSERT OR UPDATE`; además existe `trg_patron_semanal_solo_jornada_futura` (no documentado).
10. **§V `clasificacion_de_tiempo.tipo`:** "disparador pendiente de programar": sigue sin trigger; la clasificación entra por la RPC `fn_corte_quincenal_aplicar_persona` (`57`), no documentada en `MOD-03`.
11. **§IV `fn_marca_valida_revision`:** `72` agrega el motivo `fuera_de_horario` (alerta de horario, `genera_alerta_horario`); `MOD-03` sólo describe 4 de 5 motivos sin nombrarlos.
12. **Columnas posteriores no reflejadas:** `parametro.vigente_hasta`/`registrado_por` (`60`), columnas de revisión en `dia` (`62`, `63`), `jornada_asignada.genera_alerta_horario` y otras (ver sección II de cada tabla).
13. **Cuenta de tablas:** `SCJ-MOD-02` V2.2 y las notas de la V1.0 de este diccionario hablaban de 16 tablas; hoy hay 26 en `tiempo` y 11 en `personas` (37 en total) *(estado 21-oct-2026: sigue abierta en `SCJ-MOD-02`)*.
14. **Comentarios obsoletos en el DDL:** el `COMMENT` de `tiempo.parametro` (`03`) remite a "el comentario completo en `02_tiempo.sql`" y a "`SCJ-DIC-01 §IV`", pero el de `03` sobrescribió al de `02`; el de `tiempo.persona` dice "en este proyecto lo puebla el generador de datos sintéticos", del proyecto escolar. La V1.0 de este diccionario decía además `tiempo.persona.id bigint`; es `uuid`.


### No determinado

- Descripción de las columnas sin `COMMENT ON` (la mayoría de las columnas simples; marcadas en cada tabla).
- Motivos de revisión de excepciones de día (`dia_id`): hoy el batch de cierre escribe `paridad_impar` (ahora desde `fn_cierre_dia_armar`, `124_`).
- Consumo real de los parámetros en el backend (la columna «Consumo» de IV se apoya en el DDL y en `CLAUDE.md`).
- Cuerpo íntegro de las funciones (sólo se resumen sus comentarios).


---

*Diccionario de datos · Folio SCJ-DIC-01 · V1.6*
