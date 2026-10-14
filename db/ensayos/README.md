# Ensayos de migraciones (BEGIN … ROLLBACK)

Scripts que `db` escribió para ensayar cada migración **contra Supabase real dentro de una transacción
que siempre termina en `ROLLBACK`**, con personas, marcas y días sintéticos (el usuario administrador real
sólo actúa como *caller*). Se conservan porque son la evidencia y el banco de pruebas de los cortes
`80_` a `92_` (ver `docs/07-procesos/PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md`).

| Archivo | Prueba | Resultado histórico |
|---|---|---|
| `ensayo_80_81.sql` (+ `verificar_terminal.sql`) | `80_`, `81_` | 61/61 PASS |
| `ensayo_82_84.sql` | `82_`, `83_`, `84_` | 230/230 PASS |
| `ensayo_85.sql` (+ `verificar_85.sql`) | `85_` | 31/31 PASS |
| `ensayo_86.sql` (+ `verificar_86.sql`) | `86_` | 100/100 PASS |
| `ensayo_87.sql` (+ `verificar_87.sql`) | `87_` | 47/47 PASS |
| `ensayo_88.sql` (+ `verificar_88.sql`) | `88_` (consentimiento versionado, `SCJ16`, reconsentimiento, auto-asignación y auto-reconsentimiento) | 143/143 PASS (8-oct-2026, `ROLLBACK`, sin residuo) — evidencia histórica no re-ejecutable |
| `ensayo_89.sql` (+ `verificar_89.sql`) | `88_` + `89_` (claves `terminal_*`, edición con regla cruzada, guard `SCJ17`) | 60/60 PASS (8-oct-2026) — evidencia histórica no re-ejecutable |
| `ensayo_90.sql` (+ `verificar_90.sql`) | `88_` + `90_` (`fn_terminal_anomalias`) | 21/21 PASS (8-oct-2026) — evidencia histórica no re-ejecutable |
| `ensayo_91.sql` (+ `verificar_91.sql`) | `88_` + `91_` (autor de la baja por persona inactiva, detalle del Pi sin invisibles) | 22/22 PASS (8-oct-2026, `ROLLBACK`, sobre `88_` ya aplicada) — no re-ejecutable ahora que `91_` está aplicada |
| `ensayo_92.sql` (+ `verificar_92.sql`) | `92_` (policy y hora de la bitácora de personas, limpieza de invisibles del detalle de terminal) | 38/38 PASS (8-oct-2026, `ROLLBACK`) — evidencia histórica no re-ejecutable (`92_` ya aplicada) |
| `ensayo_93.sql` (+ `verificar_93.sql`) | `93_` (retiro del rol/policy `terminal_checador`; camino PostgREST `SET ROLE`, privilegios residuales, RPC y captura manual intactos) | 19/19 PASS (9-oct-2026, `ROLLBACK`, sin residuo) — evidencia histórica no re-ejecutable (`93_` aplicada el 9-oct-2026; `verificar_ddl.sql` completo en 0 filas) |
| `ensayo_94.sql` (+ `verificar_94.sql`) | `94_` (huella sin conteo: huella_confirmada_manual, huella_inferida, huella_evidencia, caducidad con tres evidencias, anomalías nuevas) | **escrito, sin correr** (a la espera de revisión de `security` y OK del usuario) |
| `ensayo_95.sql` (+ `ensayo_95_concurrencia.sh`) | `94_` + `95_` (activación por la primera marca por huella dentro de `fn_marca_terminal_registrar`, regresión de todos sus códigos) y concurrencia con 2 conexiones | **escrito, sin correr** |
| `ensayo_97.sql` | `97_` (interruptor de la activación por huella: siembra de las dos claves, CHECK, bitácora de configuración, trigger de auditoría, función dedicada, lector de estado efectivo, `fn_terminal_config_actualizar` rechazando las claves) | **corrido 121/121 y APLICADO el 10-oct-2026** (diseño: `DISENO_interruptor_inferir_huella.md`) |
| `ensayo_98.sql` | `98_` (`fn_marca_terminal_registrar` respeta el interruptor): regresión completa de `ensayo_95` con el interruptor encendido más apagado, vencido, solapado, ausente, corrupto, lectura fallida, medianoche UTC y la integración con la función dedicada | **corrido 92/92 y APLICADO el 10-oct-2026** (`97_` ya aplicado; aplica solo `98_`) |
| `ensayo_99.sql` | `99_` (campo opcional `tiempo.terminal.ingesta_detenida` y `fn_terminal_latido` de 7 argumentos: sin overload ambiguo, compatibilidad con la llamada de 6 argumentos por nombre, sobrescritura con NULL, privilegios de columna, SCJ12 con mensaje fijo, sección 62 del verificador) | **corrido 30/30 y APLICADO el 10-oct-2026** (diff de lo vigente: `diff_99_latido.diff`, `vigente_99_latido_83.sql`) |
| `ensayo_100.sql` | `100_` (REVOKE ALL a `anon` sobre toda relación/secuencia de `tiempo` y TRUNCATE/REFERENCES/TRIGGER a `authenticated`/`service_role`, por catálogo, más `ALTER DEFAULT PRIVILEGES`): foto de privilegios antes/después (no agrega nada, solo quita lo previsto), `anon` con `SET ROLE` sin acceso, `authenticated`/`service_role` intactos, tabla nueva sin `GRANT ALL`, reversa exacta e idempotencia, sección 63 del verificador | **corrido 45/45 (3 rondas) y APLICADO el 13-oct-2026** (inventario: `BORRADOR_inventario_anon.md`) |
| `ensayo_101.sql` | `101_` (`fn_bitacora_terminal_usuario_aplica` sin identificadores en el mensaje de 7 `RAISE EXCEPTION`; mismos ERRCODE/HINT): atributos, ACL, triggers y comentario intactos, 3 rechazos sintéticos, sección 64 | **corrido 15/15 el 14-oct-2026; sin aplicar** (diff: `diff_101_bitacora_aplica.diff`, vigente: `vigente_101_bitacora_aplica_94.sql`) |
| `ensayo_102.sql` | `102_` (REVOKE por catálogo en `personas`: todo a `anon` salvo SELECT sobre `personas.permiso`, y TRUNCATE/REFERENCES/TRIGGER/MAINTAIN a `authenticated`/`service_role`; defaults del esquema; guarda PG17): foto antes/después de `personas` y de `tiempo` (tiempo no cambia), `anon` con `SET ROLE`, bitácoras por catálogo (no se escribe en ellas), reversa exacta e idempotencia, sección 66 del verificador | **corrido 45/45 y APLICADO el 14-oct-2026** |
| `ensayo_103.sql` | `103_` (REVOKE SELECT de `anon` sobre `personas.permiso`; UPDATE/DELETE de `service_role` sobre `personas.bitacora_movimiento_persona`; UPDATE/DELETE de `authenticated` sin uso en 6 tablas de `tiempo` y DELETE en 4; DELETE de `service_role` sobre `tiempo.parametro`): la foto antes/después quita EXACTAMENTE la lista esperada (conjunto igual), `SET ROLE`, lo que se conserva, reversa exacta e idempotencia, sección 67 del verificador. Fuera de alcance y con razón: grupo E y `banco_de_horas` (trigger INVOKER) | **corrido 27/27 y APLICADO el 14-oct-2026** |
| `ensayo_104.sql` | `104_` (`fn_movimiento_de_saldo_actualiza_banco` a `SECURITY DEFINER` con UPDATE atómico y `SCJ18`; se elimina la policy `movimiento_de_saldo_insert_manual` y el INSERT de authenticated; `fn_movimiento_de_saldo_manual_registrar` a `SECURITY DEFINER` con autorización propia, `42501`, `FOR UPDATE`): reproduce el defecto ANTES (banco 10 / ledger 7), tres tipos manuales, batch, cada forma de abuso por INSERT directo => 42501, suspendida, solo lectura, anon, usuario no admin; secciones 68 (banco = Σ ledger) y 69 | **corrido 54/54 y APLICADO el 14-oct-2026** (diff: `diff_104_*.diff`; vigente: `vigente_104_*.sql`) |
| `ensayo_105.sql` | `105_` (REVOKE EXECUTE de 13 funciones de trigger a todos los roles de la API; `fn_caller_activo`/`fn_caller_tiene_permiso` sin PUBLIC ni anon, con GRANT explícito a authenticated/service_role; `fn_terminal_config_catalogo` sin authenticated/service_role): foto de EXECUTE efectivo y proconfig de las 81 funciones antes/después (cambia EXACTAMENTE lo listado), disparo real de los 13 triggers (`track_functions` + `pg_stat_get_xact_function_calls`; los 2 inmutables por su mensaje, porque una función que termina en error no cuenta; el trigger deferrable con `SET CONSTRAINTS ALL IMMEDIATE`), lecturas con RLS como authenticated en 13 tablas, RPC con claims, anon/authenticated/service_role => 42501, reversa, sección 70 | **corrido 64/64 el 14-oct-2026; sin aplicar** |
| `ensayo_106.sql` | `106_` (`ALTER FUNCTION personas.fn_caller_tiene_permiso(text) SET search_path = personas, pg_temp`): solo cambia el proconfig de una función, plan no inlineable antes ni después, `EXPLAIN (ANALYZE, BUFFERS)` de 7 consultas con RLS (5 repeticiones, mediana) sin regresión, mismo resultado de la función, `RESET search_path` exacto, sección 71 | **corrido 20/20 el 14-oct-2026; sin aplicar** |
| `ensayo_correccion.sql` | comportamiento de corregir una marca en un tramo (confirmó la inconsistencia que motivó `87_`) | inferencia confirmada |
| `ensayo_78.sql` | comportamiento de `78_` | **obsoleto, nunca corrido** (`86_` lo reemplaza) |

## Estado a partir del 8-oct-2026
`88_`, `89_`, `90_`, `91_` y `92_` ya están **aplicadas** en la base real (verificado en solo lectura, `db/verificar_ddl.sql` completo en 0 filas). Por eso `ensayo_88`, `ensayo_89` y
`ensayo_90` son **evidencia histórica no re-ejecutable**: aplican su migración dentro de la transacción y ahora fallarían por "ya existe". `ensayo_91.sql` se adaptó
(aplica sólo `91_` sobre `88_` ya aplicada) y corrió 22/22 antes de que `91_` se aplicara; tampoco se puede repetir ahora. Para ensayar una migración futura
(`92_` en adelante) se parte de una base que ya las trae.

## Cómo usarlos
- Cada uno **exige OK explícito del usuario** antes de correrse contra la base real, y la sesión que lo corre
  lo confirma con el usuario en su propio chat.
- Conexión **directa** (puerto 5432), no el pooler: `psql -X "$DATABASE_URL_DIRECTA" -v ON_ERROR_STOP=1 -f
  db/ensayos/ensayo_NN.sql` (sin `-1`; el script abre `BEGIN` y termina en `ROLLBACK`; trae `SET LOCAL`
  de `lock_timeout`, `statement_timeout` e `idle_in_transaction_session_timeout`).
- Las líneas `\ir` apuntan a **rutas absolutas** del scratchpad original y del repo
  (`/tmp/claude-1000/...` y `/home/diego/Proyectos/RTB-CRM-APP/db/ddl/...`): ajustarlas a `db/ensayos/` y
  `db/ddl/` antes de reutilizarlos. Los `verificar_*.sql` son extractos generados de
  `db/verificar_ddl.sql` (secciones acumuladas hasta cada migración); la fuente vigente es
  `db/verificar_ddl.sql`.
- Los ensayos de `82_` a `87_` aplican la migración **dentro** de la transacción sobre una base que ya
  tiene las anteriores; si la migración ya está aplicada, `\ir` del `.sql` fallará por objetos existentes
  (los de `80_`/`81_` y los demás son históricos: ya están aplicados).
- Limitaciones conocidas: no simulan concurrencia entre dos sesiones ni el camino HTTP/`COMMIT` real de los
  constraint triggers diferidos; las secuencias *identity* avanzan aunque haya `ROLLBACK` (huecos de `id`).
- Desde `88_` los ensayos usan rutas **relativas** (`\ir ../ddl/...`, `\ir verificar_NN.sql`), que psql resuelve respecto del directorio del script.
- Los ensayos de `82_` a `87_` **no son compatibles con una base posterior a `88_`**: sus `asignado` no traen `consentimiento_id`
  (hoy `SCJ16`). Sirvieron para su migración y no se vuelven a correr.
- Los `verificar_NN.sql` son extractos de `db/verificar_ddl.sql` hasta la sección de su migración (88: 41 a 50; 89: 41 a 52; 90: 41 a 50
  y 53); si cambia el verificador hay que regenerarlos. La fuente vigente, con todas las secciones, es `db/verificar_ddl.sql`.
- `ensayo_88/89/90` aplican la migración **dentro** de la transacción: fallan por "ya existe" si esa migración ya está aplicada; también `88_` aborta
  (a propósito) si `terminal_usuario` o la bitácora tienen filas. Los tres reinician la secuencia del `employee_no` con `ALTER SEQUENCE ... RESTART`
  transaccional.

## Pendiente propuesto (sin DDL todavía): `96_` de endurecimiento de `anon`
Propuesta de `security` tras el retiro de `terminal_checador` (`93_`), **no escrita ni aplicada**: `tiempo.marca` (y por el mismo patrón el resto de las
tablas de `tiempo`, por el `GRANT ALL` schema-wide de `38_tiempo_permisos.sql`) sigue con privilegios de tabla para `anon` (`arDxtm`: SELECT, INSERT, UPDATE,
DELETE, TRUNCATE, REFERENCES, TRIGGER) y `authenticated`; la barrera real es RLS deny-by-default (sin policy para `anon`, el ensayo `93_` caso 24 lo confirmó:
`anon` no inserta). Un `96_` (renumerado: `94_` y `95_` son ahora la huella sin conteo) haría `REVOKE ALL` explícito a `anon` sobre las tablas de `tiempo` que ninguna ruta pública usa y `REVOKE TRUNCATE, REFERENCES,
TRIGGER` a `anon` y `authenticated` (`TRUNCATE` no está sujeto a RLS). Antes de escribirlo: inventario por tabla de qué rol necesita qué (`verificar_ddl.sql` ya
lista los casos especiales) y ensayo `BEGIN … ROLLBACK`; avisar a `backend` por `orchestrator` (los routers con `get_caller_client` dependen de los GRANT de `authenticated`).

## Pendiente anotado (sin hacer): mensajes de `RAISE EXCEPTION` que interpolan valores
Segundo paso de la regla «nunca identidad en logs» (security, 9-oct-2026). Los `RAISE EXCEPTION` de `fn_bitacora_terminal_usuario_aplica` que interpolan valores
(«employee_no % no coincide con el de la alta %», «La persona % ya tiene un alta vigente en la terminal %», «terminal_usuario % no existe», «terminal_id/persona_id
no coinciden…») terminan en el log del servidor aunque el backend no los muestre. Recomendación: mensajes fijos + `HINT` estable, aplicándolo en el próximo corte
que toque cada función (no en 94_/95_). Los `RAISE WARNING` ya están cubiertos: 95_ (`fn_marca_terminal_registrar`), 96_ (`fn_terminal_rechazo_registrar` y
`fn_terminal_baja_por_persona_inactiva`) y la consulta estática 59 de `verificar_ddl.sql`.

## Siguientes cortes anotados (12-oct-2026, de la revisión de `security` de `100_`/`101_`; no mezclar con ellos)
- **Mismo REVOKE por catálogo para `personas`** (`08_personas_permisos.sql` da GRANT ALL a `anon`; ahí viven CURP/RFC/NSS: prioridad): archivo propio, ensayo con `SET ROLE anon` y sección nueva del verificador.
- **Inventario de `EXECUTE`** en `tiempo` y `personas`: funciones con `prosecdef` y `has_function_privilege('anon', …)`, con decisión una por una (nacen con `EXECUTE` para `PUBLIC`).
- Si el ensayo de `100_` muestra un default GLOBAL de Supabase que otorga algo a `anon` (D0/D1), se reporta antes de tocar nada: `ALTER DEFAULT PRIVILEGES IN SCHEMA` no retira un default global.

## Documentos de diseño (texto, sin SQL)
- `DISENO_interruptor_inferir_huella.md` — diseño v4 del interruptor de la activación por huella (`97_`/`98_`).
- `BORRADOR_inventario_anon.md` — borrador de inventario del endurecimiento de `anon` (parte B); sin SQL ni consulta a la base.

## Regla de funciones (desde `105_`)
- **Toda migración que CREE una función hace su `REVOKE EXECUTE … FROM PUBLIC` y concede lo mínimo** (típicamente `GRANT EXECUTE … TO authenticated` o `TO service_role`; las funciones de trigger no se conceden a nadie).
  **Patrón estándar completo** (en este orden, en el MISMO archivo que crea la función, con su firma exacta):
  `REVOKE EXECUTE ON FUNCTION esquema.fn(args) FROM PUBLIC, anon, authenticated, service_role;` y DESPUÉS solo el GRANT mínimo, p. ej. `GRANT EXECUTE ON FUNCTION esquema.fn(args) TO authenticated;`.
  Se revoca a los cuatro, no solo a PUBLIC: en `public` y en los esquemas con defaults de Supabase, `anon` (y los demás roles de la API) pueden tener un `EXECUTE` EXPLÍCITO además del de PUBLIC, y revocar solo PUBLIC no lo quita.
  `ALTER DEFAULT PRIVILEGES … ON FUNCTIONS … IN SCHEMA` NO sirve para esto: PostgreSQL concede `EXECUTE` a PUBLIC a toda función nueva y un default por esquema no lo quita (además existen defaults de `postgres`
  y `supabase_admin` en `public`/`storage`). La sección 70 de `verificar_ddl.sql` hace cumplir la regla: ninguna función propia con `EXECUTE` para PUBLIC o anon (excepción documentada: `public.rls_auto_enable`),
  ninguna función de trigger con `EXECUTE` para nadie, toda `SECURITY DEFINER` con `search_path` fijo, dueño `postgres` y no `LEAKPROOF`, y lista cerrada de funciones con `EXECUTE` para `authenticated`.
- **Revocar PUBLIC sin GRANT explícito deja sin `EXECUTE` a quien lo tenía solo por PUBLIC** (le pasa a `fn_caller_activo`/`fn_caller_tiene_permiso`, con ACL NULL): conceder authenticated/service_role en el mismo archivo.
- **Cambiar un atributo de una función ya existente: `ALTER FUNCTION … SET/RESET`, no `CREATE OR REPLACE`** (este último resetea `SECURITY DEFINER`, `search_path` y la ACL si no se repiten).
- Una función de trigger que SIEMPRE levanta excepción (las «inmutables») no cuenta en `pg_stat_get_xact_function_calls`: probarla por el mensaje de su excepción. Un constraint trigger `DEFERRABLE INITIALLY DEFERRED` no
  dispara bajo `ROLLBACK` si no se fuerza con `SET CONSTRAINTS ALL IMMEDIATE`.
- **Una `SECURITY DEFINER` que sustituye a una policy o a una RLS debe repetir DENTRO la autorización** (persona activa + permiso: `personas.fn_caller_activo() AND personas.fn_caller_tiene_permiso(…)`), **tomar el autor
  de `auth.uid()` y fijar lo que el cliente no debe controlar** (por ejemplo `creado_en`, el banco o el signo del monto): la policy no se hereda. Lección de `104_`: al volver `DEFINER` el trigger que actualiza
  `banco_de_horas`, la policy de INSERT de `movimiento_de_saldo` (sin límites de monto, banco ni fecha) habría dejado mover el saldo por PostgREST con solo el permiso; se cerró la vía directa y la autorización pasó al RPC.
- **Lista cerrada de la sección 70(d):** añadir una RPC ejecutable por `authenticated` exige agregar su nombre a la lista de `verificar_ddl.sql` (sección 70, bloque `NOT IN (…)`) **en el MISMO commit**, con su
  llamador (archivo:línea y cliente: caller o service_role) en el mensaje del commit o en el encabezado de la migración. Sin esa entrada, la sección 70 da una fila y la migración no cierra.
- **Nota:** `personas.fn_caller_persona_id` y `personas.fn_caller_es_administrador_generico` solo las llama `tiempo.fn_terminal_reconsentir` (INVOKER, ejecutada por `authenticated`); es aceptable porque devuelven
  datos propios del caller, pero son candidatas a NO exponerse a authenticated si esa función se reescribe como `SECURITY DEFINER`.
