# 2026-10-05 · [SCJ-PRO-11] — Terminal Hikvision: auditoría y modelo de datos del mapeo

**Participantes:** Diego (usuario), `orchestrator` + `db` + `security` vía `team-orchestrator`.
**Duración:** una jornada, en varios cortes: auditoría de la terminal, plan, DDL (`80`/`81`), revisión
de seguridad, ensayo con `ROLLBACK`, aplicación y documentación.

---

## Qué se hizo

### 1. Auditoría de la terminal Hikvision DS-K1A8503EF-B

La terminal reemplaza al lector R503Pro como aparato de registro. Se auditó por red local con la
interfaz ISAPI (autenticación Digest). Lo que se encontró:

- **ISAPI funciona** con autenticación Digest: CRUD de usuarios, hasta 10 huellas por usuario,
  consulta de eventos de acceso (`AcsEvent`) y configuración de destinos de envío (`httpHosts`).
- **Firmware V1.3.0.**
- **Hora configurada a mano** en zona CST-8, **sin NTP**: la terminal puede desfasarse con el
  tiempo. Afecta `estado_reloj` y `fuera_de_horario` de las marcas (`SCJ-PRO-11 §IV`).
- **DHCP activo**: la dirección de la terminal puede cambiar. El puente no debe asumir una IP fija.
- **Sin HTTPS**: el tráfico entre el Pi y la terminal va en claro dentro de la red local.
- **Push por `httpHosts` vacío**: la terminal no está configurada para enviar eventos por su
  cuenta; hoy el puente tendría que consultarlos.
- **Un solo usuario de prueba** cargado en el aparato.

### 2. Incidencias del día

- **Checador y Pi fuera de línea** al empezar: no respondían en la red.
- **SSH al Pi rechazando las llaves** que antes funcionaban.
- **La terminal estaba sin activar** (pantalla de activación inicial pendiente), por lo que no
  respondía a ISAPI hasta activarla.

Ninguna de las tres quedó con causa raíz documentada en esta sesión; se registran como hechos.

### 3. Modelo de datos del servidor (`db/ddl/80_*` y `81_*`)

`orchestrator` coordinó, `db` escribió el DDL y `security` lo revisó antes de aplicar.

- `80_tiempo_terminal_usuario.sql`: `tiempo.terminal` (el aparato), `tiempo.terminal_usuario` (la
  persona enrolada, tabla viva `[CALCULADO]`), la secuencia `tiempo.seq_terminal_employee_no` (primera
  secuencia explícita del proyecto) y los permisos `terminal_usuario_lectura` (heredable) y
  `terminal_usuario_edicion` (no heredable), otorgados por bitácora a "Responsable de Recursos
  Humanos", "Gerente General" y "Gerente o Encargado de TI" (este último, el puesto administrador,
  explícito).
- `81_tiempo_bitacora_movimiento_terminal_usuario.sql`: bitácora inmutable en 3 capas (grants
  mínimos, RLS sin `UPDATE`/`DELETE`, triggers por fila y por statement), más el trigger
  `SECURITY DEFINER` que valida las 6 transiciones y deriva `terminal_usuario`. `ERRCODE` `SCJ11`
  (transición inválida) y `SCJ12` (alta duplicada, persona no activa, terminal no válida), cada uno
  con un `HINT` estable.
- `db/verificar_ddl.sql`: `tiempo` pasa de 17 a 20 tablas; el catálogo de permisos, de 49 a 51; y se
  agregan las secciones 11 a 22, consultas de violaciones con resultado esperado de 0 filas.

**Revisión de `security`** (antes de aplicar): sin hallazgos críticos, 2 medios y varios bajos, todos
corregidos en los mismos archivos: tope de 500 caracteres en los textos libres, endurecimiento de
`verificar_ddl.sql` a consultas de violaciones, exigir terminal activa en `asignado` antes de
consumir un `employeeNo`, trigger `BEFORE TRUNCATE`, `IS DISTINCT FROM` en las comparaciones de la fila
viva, `UPDATE` de `service_role` limitado a 4 columnas de `tiempo.terminal`, y el partido de errores en
`SCJ11`/`SCJ12`.

**Ensayo contra la base real, dentro de `BEGIN … ROLLBACK`** (autorizado por el usuario): primera
corrida 59 casos con 2 fallos, ambos defectos del propio script de ensayo y no del DDL (los `CHECK` se
evalúan después de los triggers `BEFORE`, así que el trigger cortaba antes); corregido el ensayo,
segunda corrida **61 de 61 aprobados**. Las 12 consultas de violaciones dieron 0 filas dentro de la
transacción simulada, y después del `ROLLBACK` se confirmó con lecturas que la base real no quedó con
ningún objeto nuevo.

**Aplicación y verificación.** El usuario autorizó la aplicación permanente. El `psql` de escritura
de la sesión de `db` fue bloqueado por el clasificador de permisos de Claude Code, y un primer
intento con el comando `psql` ejecutado por el usuario desde su terminal no dejó nada aplicado (no se
vio su salida, causa no determinada). Finalmente el usuario pegó `80` y luego `81`, en ese orden, en el
SQL Editor de Supabase. Verificación posterior solo de lectura: `db/verificar_ddl.sql` completo sin
errores (`personas` = 11 tablas, `tiempo` = 20), las 12 consultas de violaciones en 0 filas, las 3
tablas existentes y **vacías**, `personas.permiso` = 51 y el puesto administrador con 51 permisos
activos, y los 2 permisos nuevos con la heredabilidad correcta y otorgados a los 3 puestos acordados.

### 4. Documentación

`SCJ-DEC-11` (nueva), `SCJ-PRO-11` V2.0 (versión mayor: se contradice el mecanismo de identidad de
`§III`), `SCJ-DIC-01` V1.2, `SCJ-MOD-03` V1.7, el índice de `SCJ-DEC-00`, `README.md` y
`scripts/aplicar_ddl.sh` (conteo de archivos: 82). Se corrigieron de paso los nombres de
`SCJ-DIC-01` (decía `V1_0` con encabezado 1.1) y `SCJ-MOD-03` (decía `V1_5` con encabezado 1.6), que
violaban `CONVENCIONES.md §I`.

---

## Qué se decidió

- El mapeo `employeeNo` ↔ persona **vive en el servidor**; el Pi sólo lo cachea.
- La captura de huella es **siempre presencial**, frente a la terminal.
- El Pi accede al servidor **por endpoints del backend** con una credencial propia de terminal, no
  por RLS directa ni con el secreto JWT de Supabase; las marcas también suben por el backend.
- **Una sola terminal por ahora**, con un diseño que admite varias.
- **Bitácora inmutable** de movimientos de enrolamiento como fuente de verdad de la tabla viva.
- El SQLite local del Pi se cambia **junto con el código del puente**, no en este corte.
- La terminal real se da de alta con un `INSERT` puntual, no como seed del DDL.
- `terminal_usuario_edicion` **no heredable** (permiso biométrico) y `terminal_usuario_lectura`
  heredable; no se reutilizan `persona_edicion` ni `alta_personas_usuarios`.
- La terminal activa se exige en `asignado`; `baja_solicitada` se acepta también desde
  `pendiente_alta`; una persona sin fila en `tiempo.persona` falla por FK (`23503`) en vez de
  sincronizarse sola.
- Códigos `SCJ11`/`SCJ12` con `HINT` estable.
- El total de permisos esperado es **51**, no 18 (una cifra que circuló durante la sesión confundía
  los 16 originales con el catálogo completo, que ya tenía 49).

---

## Qué quedó pendiente

- **Alta de la terminal real** en `tiempo.terminal`: un `INSERT` puntual con la serie del aparato.
  Requiere visto bueno aparte del usuario; no se hizo.
- **Diseño y construcción del backend**: credencial de terminal, endpoints del puente y de Recursos
  Humanos, mapeo de errores `23503`/`23505`/`SCJ11`/`SCJ12` a `409`/`422` sin retransmitir el texto
  al Pi, saneado y truncado de `detalle`, y la emisión de `baja_solicitada` cuando una persona pasa a
  `inactivo` más el señalamiento de marcas de personas inactivas.
- **Código del puente** en el repositorio del checador (ISAPI, caché local, procesamiento de altas y
  bajas pendientes), que reemplaza al lector R503Pro y a su SQLite anterior.
- **Bloque de hora, NTP y DHCP en la terminal**: dar de alta un servidor de hora, fijar o reservar la
  dirección, y evaluar HTTPS o aislar la red de la terminal.
- **Avisar a RTB-App** (`SCJ-DEC-11`): el esquema estaba congelado desde el 2026-09-25 y estos cambios
  son posteriores.
- **`CLAUDE.md`**: actualizar el conteo de archivos de DDL (82), de tablas y de permisos (51), y la
  entrada del módulo; lo hace `orchestrator`.

---

## Preguntas nuevas

- ¿Por qué el comando `psql` ejecutado por el usuario con `!` no aplicó nada? No se vio su salida; el
  SQL Editor sí funcionó.
- ¿Conviene revocar `UPDATE (activa)` de `service_role` en `tiempo.terminal` y dejar la activación y
  desactivación de terminales sólo para una migración? Hoy el backend puede apagarla.
- ¿Qué hace el puente si la terminal pierde la hora y empieza a reportar eventos con
  `estado_reloj` distinto de `sincronizado`? Hoy sólo se señalan.

## Nota para la retrospectiva

- **Un ensayo que simula el rechazo debe saber en qué orden se evalúan las comprobaciones.** Dos
  casos del ensayo "fallaron" porque el trigger `BEFORE` corta antes que los `CHECK`; el DDL estaba
  bien, el ensayo no. Un rechazo por la capa equivocada pasa igual que uno por la capa correcta, así
  que conviene que cada caso fije el `SQLSTATE` esperado.
- **Revocar y volver a conceder, en vez de revocar sólo lo que se sospecha.** `GRANT ALL` schema-wide
  incluye `TRUNCATE`, que ni RLS ni los triggers por fila frenan; los objetos nuevos hacen `REVOKE ALL`
  y conceden lo mínimo en el mismo archivo.
- **La autorización de una acción permanente no se hereda de la de un ensayo.** Aplicar el DDL a la
  base real se pidió y se confirmó aparte del ensayo con `ROLLBACK`, y quedó en manos del usuario
  cuando el clasificador de permisos bloqueó la escritura.
