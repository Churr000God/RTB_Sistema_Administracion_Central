# Ensayos de migraciones (BEGIN … ROLLBACK)

Scripts que `db` escribió para ensayar cada migración **contra Supabase real dentro de una transacción
que siempre termina en `ROLLBACK`**, con personas, marcas y días sintéticos (el usuario administrador real
sólo actúa como *caller*). Se conservan porque son la evidencia y el banco de pruebas de los cortes
`80_` a `87_` (ver `docs/07-procesos/PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md`).

| Archivo | Prueba | Resultado histórico |
|---|---|---|
| `ensayo_80_81.sql` (+ `verificar_terminal.sql`) | `80_`, `81_` | 61/61 PASS |
| `ensayo_82_84.sql` | `82_`, `83_`, `84_` | 230/230 PASS |
| `ensayo_85.sql` (+ `verificar_85.sql`) | `85_` | 31/31 PASS |
| `ensayo_86.sql` (+ `verificar_86.sql`) | `86_` | 100/100 PASS |
| `ensayo_87.sql` (+ `verificar_87.sql`) | `87_` | 47/47 PASS |
| `ensayo_correccion.sql` | comportamiento de corregir una marca en un tramo (confirmó la inconsistencia que motivó `87_`) | inferencia confirmada |
| `ensayo_78.sql` | comportamiento de `78_` | **obsoleto, nunca corrido** (`86_` lo reemplaza) |

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
