# Borrador de inventario — endurecimiento de `anon` (parte B de la propuesta de `security`)

**Estado:** BORRADOR de texto. No contiene SQL aplicable, no se ha consultado la base real y no hay ningún archivo `.sql` asociado. Sirve para decidir el alcance antes de escribir un archivo de DDL, ensayarlo y pedir autorización.
**Fecha:** 10 de octubre de 2026. **Autor:** sesión `db`. **Origen:** propuesta de `security` tras el retiro de `terminal_checador` (`93_`), anotada en `db/ensayos/README.md`.

---

## 1. Qué se quiere endurecer y por qué

- `38_tiempo_permisos.sql` (y `08_personas_permisos.sql` para `personas`) conceden `GRANT ALL` schema-wide a `anon`, `authenticated` y `service_role`, y su `ALTER DEFAULT PRIVILEGES` hace lo mismo con toda tabla nueva. Resultado: `anon` conserva **todos** los privilegios de tabla (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`) sobre las tablas que no revocaron a mano (lo confirmó la lectura de `relacl` de `tiempo.marca` el 9-oct-2026: `anon=arDxtm`).
- Hoy la barrera real es **RLS deny-by-default**: sin policy para `anon`, un `SELECT`/`INSERT`/`UPDATE`/`DELETE` de `anon` no afecta filas (el ensayo de `93_`, caso 24, lo comprobó con `INSERT` en `tiempo.marca`). Pero **`TRUNCATE` no está sujeto a RLS**, y `REFERENCES` y `TRIGGER` son privilegios de estructura que `anon` no debería tener nunca.
- Propuesta de `security`: (a) `REVOKE ALL` explícito a `anon` sobre las tablas de `tiempo` (y `personas`) que ninguna ruta pública usa; (b) `REVOKE TRUNCATE, REFERENCES, TRIGGER` a `anon` y a `authenticated` en todas las tablas; (c) cambiar el `ALTER DEFAULT PRIVILEGES` para que las tablas nuevas ya no nazcan con `GRANT ALL`.

## 2. Hechos conocidos (de los archivos de DDL, sin consultar la base)

- Los DDL contienen 36 `CREATE TABLE` entre `tiempo` y `personas` (incluye el stub `tiempo.persona` y la tabla nueva `tiempo.bitacora_config_terminal` de `97_`); la base real tiene 11 tablas en `personas` y 24 en `tiempo` según `SCJ-DIC-01` (la de `97_` sería la 25.ª de `tiempo`).
- Todas tienen RLS habilitada. Cuatro tablas de `tiempo` quedan **sin ninguna policy** a propósito: `dia_festivo`, `parametro`, `tope_legal` (acceso solo por `service_role`) y `terminal_credencial`.
- El backend usa dos clientes: `get_caller_client` (anon key + JWT del usuario: **`authenticated`**, sujeto a RLS) y `get_service_client` (`service_role`). **Nunca** usa `anon` con sesión; `anon` solo existe para peticiones sin login.
- Excepciones ya hechas a mano (el patrón correcto, que habría que generalizar): `80_`/`81_`/`82_`/`84_`/`88_` hacen `REVOKE ALL` a `anon`, `authenticated` y `service_role` y vuelven a conceder lo mínimo; `93_` retiró todo a `terminal_checador`; `97_` hace lo mismo con su bitácora de configuración.

## 3. Inventario preliminar por tabla (APROXIMADO: sale de buscar `CREATE POLICY` y `.table("...")` en el repositorio; hay que verificarlo contra el catálogo real)

Columnas: **policies definidas en el DDL** (puede incluir policies que luego se reemplazaron), **uso en el backend** (cuántos archivos y con qué cliente), y **propuesta preliminar para `anon`**.

| Tabla | Policies (DDL) | Backend | `anon` |
|---|---|---|---|
| `tiempo.persona` | select (caller activo) | 15 archivos, caller y service | revocar todo |
| `tiempo.tope_legal` | ninguna | 2, service | revocar todo |
| `tiempo.dia_festivo` | ninguna | 4, service | revocar todo |
| `tiempo.parametro` | ninguna | 10, service | revocar todo |
| `tiempo.jornada_asignada` | select, insert, update, delete (con permiso) | 8, caller y service | revocar todo |
| `tiempo.patron_semanal` | select, insert, update, delete (con permiso) | 4, caller y service | revocar todo |
| `tiempo.marca` | insert captura manual, select (con permiso) (y la del rol retirado, ya borrada por `93_`) | 7, caller y service | revocar todo |
| `tiempo.dia` | select, update (revisión) | 8, caller y service | revocar todo |
| `tiempo.tramo` | select, insert y update (revisión) | 6, caller y service | revocar todo |
| `tiempo.clasificacion_de_tiempo` | select (con permiso) | 3 | revocar todo |
| `tiempo.banco_de_horas` | select (con permiso) | 2 | revocar todo |
| `tiempo.movimiento_de_saldo` | select, insert manual (con permiso) | 1 | revocar todo |
| `tiempo.correccion` | select, insert (con permiso) | 5 | revocar todo |
| `tiempo.ausencia` | select, update (con permiso) | 2 | revocar todo |
| `tiempo.aprobacion_ausencia` | select, insert (con permiso) | 1 | revocar todo |
| `tiempo.excepcion` | select, update (con permiso) | 5 | revocar todo |
| `tiempo.corrida_batch` | select (caller activo) | 2 | revocar todo |
| `tiempo.terminal` | select (lectura) | 2 | ya revocado por `80_` (verificar) |
| `tiempo.terminal_usuario` | select (lectura) | 6 | ya revocado por `80_` (verificar) |
| `tiempo.bitacora_movimiento_terminal_usuario` | select, insert web | 2 | ya revocado por `81_` (verificar) |
| `tiempo.terminal_credencial` | ninguna | 1, service | ya revocado por `82_` (verificar) |
| `tiempo.marca_rechazada` | select (lectura) | 1, service | ya revocado por `84_` (verificar) |
| `tiempo.excepcion_descarte` | select (lectura) | 0 | ya revocado por `86_` (verificar) |
| `tiempo.terminal_consentimiento` | select (lectura) | 4 | ya revocado por `88_` (verificar) |
| `tiempo.bitacora_config_terminal` | select (lectura) | 0 (aún) | ya revocado por `97_` |
| `personas.persona`, `.expediente`, `.usuario`, `.bitacora_movimiento_persona` | select/insert/update/delete con permiso | varios, caller y service | revocar todo |
| `personas.area`, `.departamento`, `.puesto`, `.asignacion`, `.permiso`, `.puesto_permiso`, `.bitacora_movimiento_puesto_permiso` | select/insert/update/delete con permiso | solo caller | revocar todo |

Lectura preliminar: **ninguna tabla necesita ningún privilegio para `anon`**. Si la lectura real del catálogo lo confirma, `REVOKE ALL` a `anon` sobre todas las tablas, secuencias y funciones expuestas es seguro desde el punto de vista del backend (que no usa `anon` con sesión), y el único riesgo es **PostgREST sin login** (por ejemplo la comprobación de humo de `README.md` §"Cómo levantar el proyecto", que hace una petición con la anon key y espera `200` con cuerpo `[]` por RLS: con `REVOKE ALL` pasaría a `403`/`42501`; el verificador y esa comprobación de humo deberían ajustarse).

## 4. Lo que falta antes de escribir SQL

1. **Lectura de solo catálogo** (requiere autorización del usuario, como las anteriores): `relacl` de las 36 tablas y secuencias, `pg_policies` de ambos esquemas, privilegios por defecto (`pg_default_acl`) y funciones con `EXECUTE` para `PUBLIC`/`anon`. Con eso se reemplaza la columna «Policies (DDL)» de la tabla por el estado real.
2. **Decisión sobre `authenticated`:** `REVOKE TRUNCATE, REFERENCES, TRIGGER` es seguro (el backend no los usa). Revocar también `UPDATE`/`DELETE` donde la bitácora es inmutable ya está hecho por tabla; el resto depende de las policies y del uso (los routers con `get_caller_client` necesitan los privilegios de tabla correspondientes además de RLS).
3. **`ALTER DEFAULT PRIVILEGES`:** cambiar el privilegio por defecto de tablas futuras (quitar `GRANT ALL` a `anon` y a `authenticated` y dejar lo mínimo) afecta a **toda** migración futura; hay que decidirlo y documentarlo en `CLAUDE.md` (la regla actual «cada tabla nueva hace `REVOKE ALL` explícito» pasaría a ser la red de seguridad, no la única barrera).
4. **Funciones:** `EXECUTE` nace en `PUBLIC`; el verificador ya exige `REVOKE` explícito en cada función del módulo de terminales. Falta inventariar las funciones de `personas` y de los módulos anteriores (`fn_caller_*`, RPC de jornada, ausencias, corte quincenal, etc.).
5. **Efectos sobre PostgREST/Data API:** probar con la anon key que las peticiones sin sesión fallan con `401/403` (y no con datos) y que el backend, el frontend y los despliegues (Pi de pruebas) siguen funcionando.
6. **Procedimiento:** ensayo `BEGIN … ROLLBACK` sobre la base real (como los anteriores), `verificar_ddl.sql` con una sección nueva (ningún privilegio de `anon` en tablas, secuencias ni funciones del esquema; `TRUNCATE`/`REFERENCES`/`TRIGGER` ausentes para `anon` y `authenticated`), aplicación con `--single-transaction`, y aviso previo a `backend` por `orchestrator`.

## 5. Riesgos

- Revocar de más rompe el backend en producción de forma silenciosa si algún router usa `authenticated` con un privilegio que se quita: el ensayo debe correr la suite de pruebas de backend contra un entorno equivalente, no solo el verificador.
- Cambiar los privilegios por defecto sin ensayar puede dejar sin acceso a tablas futuras de forma confusa (`permission denied`) hasta que la migración correspondiente conceda lo necesario.
- `TRUNCATE` solo se puede ensayar dentro de una transacción con `ROLLBACK`; no hay forma de probarlo sin riesgo en una base compartida.

## 6. Numeración

`97_` y `98_` (interruptor de la activación por huella) preceden a este endurecimiento; si se aprueba, sería `99_` (o el siguiente libre), independiente de ellos y sin dependencias de esquema.
