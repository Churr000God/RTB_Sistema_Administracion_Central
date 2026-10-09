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

## Pendiente propuesto (sin DDL todavía): `94_` de endurecimiento de `anon`
Propuesta de `security` tras el retiro de `terminal_checador` (`93_`), **no escrita ni aplicada**: `tiempo.marca` (y por el mismo patrón el resto de las
tablas de `tiempo`, por el `GRANT ALL` schema-wide de `38_tiempo_permisos.sql`) sigue con privilegios de tabla para `anon` (`arDxtm`: SELECT, INSERT, UPDATE,
DELETE, TRUNCATE, REFERENCES, TRIGGER) y `authenticated`; la barrera real es RLS deny-by-default (sin policy para `anon`, el ensayo `93_` caso 24 lo confirmó:
`anon` no inserta). Un `94_` haría `REVOKE ALL` explícito a `anon` sobre las tablas de `tiempo` que ninguna ruta pública usa y `REVOKE TRUNCATE, REFERENCES,
TRIGGER` a `anon` y `authenticated` (`TRUNCATE` no está sujeto a RLS). Antes de escribirlo: inventario por tabla de qué rol necesita qué (`verificar_ddl.sql` ya
lista los casos especiales) y ensayo `BEGIN … ROLLBACK`; avisar a `backend` por `orchestrator` (los routers con `get_caller_client` dependen de los GRANT de `authenticated`).
