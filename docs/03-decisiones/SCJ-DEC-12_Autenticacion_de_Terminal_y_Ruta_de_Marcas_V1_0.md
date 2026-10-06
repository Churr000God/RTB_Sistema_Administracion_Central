# SCJ-DEC-12 · ¿Cómo se autentica el puente de la terminal ante el backend, y por qué ruta suben las marcas y los movimientos de enrolamiento?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-10-06
**Última revisión:** 2026-10-06 (de "Propuesta" a "Aceptada" el mismo día: incorpora la revisión de security, las decisiones del usuario y la verificación de `db` contra el DDL real; ver §10 y §11)

---

## Contexto

`SCJ-DEC-11` decidió que el Raspberry Pi **no toca la base**: llama a endpoints del backend con una
**credencial propia de terminal** (no el secreto JWT de Supabase) y las marcas también suben por el
backend. Quedaban abiertas las preguntas de implementación, que este documento cierra:

1. Qué es esa credencial, dónde vive, cómo se rota y se revoca, y qué pasa si el Pi se compromete.
2. Cómo se registran las marcas: con qué privilegio y con qué contrato por marca.
3. Qué ve el Pi, qué ve Recursos Humanos, y cómo se traducen los errores sin retransmitir texto crudo.
4. Cómo se emite `baja_solicitada` cuando una persona deja de estar activa.
5. Cómo se detecta que el Pi o la terminal dejaron de reportar, y cómo se desactiva una terminal.

No hay respuesta obvia porque chocan tres lecciones de `CLAUDE.md`: (a) con `service_role` la RLS
no corre y la autorización pasa a ser código; (b) un aparato de pared es mucho más fácil de
comprometer que un servidor; (c) toda tabla o función nueva en `tiempo` nace con privilegios
amplios (`GRANT ALL`, `EXECUTE` a `PUBLIC`) que hay que revocar en el mismo corte.

**Alcance del aparato (decisión del usuario, 2026-10-06):** la terminal es **sólo de asistencia**.
No controla puerta ni relé. Lo peor que logra quien compromete el sistema es **falsear asistencia**,
no abrir un acceso físico; por eso el hallazgo M4 de security queda en severidad **media**.

**Esquema congelado (`SCJ-ACT-03`):** este diseño necesita tablas, funciones y columnas nuevas
(§9). RTB-App debe enterarse antes de copiar el DDL.

**Insumos leídos:** `SCJ-DEC-11`, `SCJ-PRO-11 V2.0`, `SCJ-CDT-01 V2.0` (§II, §V, §VII–§IX, §XI,
§XV), `db/ddl/37_*`, `80_*`, `81_*`, `02_tiempo.sql` (`tiempo.marca`, `fn_marca_valida_revision`),
`backend/app/{deps,config,permisos,errores,scheduler,main}.py`, `routers/{marcas,movimientos,
asignaciones}.py`, y (sólo lectura) `checador-fisico/backend/app/{jwt_terminal,sync}.py`.

---

## 1. Credencial propia del Pi

### Opciones consideradas

**A — JWT firmado con un secreto propio del backend.** *En contra:* un JWT autocontenido no se
revoca sin consultar la base, y el backend **debe** consultar `terminal.activa` en cada llamada, así
que no ahorra nada; el secreto compartido falsifica cualquier terminal.

**B — API key opaca por terminal, hash en base** *(elegida).* *A favor:* revocación inmediata y por
llave; una filtración de la base no entrega llaves utilizables; rotación con traslape sin
reiniciar; la identidad sale de la fila encontrada, nunca del cliente.

**C — Hash en variable de entorno.** *En contra:* rotar o revocar exige redeploy; sin historia de
uso. Plan B sólo si el DDL se retrasa.

**D — mTLS / Digest.** Descartadas: infraestructura de certificados inexistente, sin mejorar el
modelo de amenaza frente a B.

### Decisión

- **Formato:** `scjt_` + `secrets.token_urlsafe(32)` (43 caracteres URL-safe, 256 bits). El prefijo
  lo hace detectable por escáneres de secretos. Viaja como `Authorization: Bearer scjt_…`.
- **Validación de formato antes de tocar la base** (M5): `^scjt_[A-Za-z0-9_-]{43}$`. Lo que no
  cumpla da `401` sin consulta.
- **Hash:** SHA-256 hex. Bcrypt/argon2 no aportan nada con 256 bits de entropía. La búsqueda es por
  igualdad del hash en SQL; no hay comparación de secretos en Python (si alguna vez la hubiera,
  `hmac.compare_digest`).
- **Dónde vive:** en el Pi, archivo `.env` con permisos `600`, propiedad del usuario del servicio;
  nunca en SQLite ni en el repositorio. En el servidor sólo el hash.
- **Ligadura al aparato:** la credencial es una fila de `tiempo.terminal_credencial` que apunta a
  `tiempo.terminal.id`. Todo valor de `terminal` que se escriba lo fija el servidor desde esa fila.
  Si el cuerpo trae `terminal_id` (la serie), debe coincidir: si no, `403 terminal_incoherente`.
- **Sin caché de validación** (M6): cada petición revalida contra la base, así una revocación corta
  la siguiente llamada. (Con una terminal y 1 petición/min es irrelevante; si algún día hiciera
  falta cachear, TTL ≤ 30 s.)
- **Expiración:** sin vencimiento por defecto (aparato desatendido; un vencimiento automático lo
  apagaría en silencio). `expira_en` opcional. Rotación **manual**, recomendada cada 12 meses y ante
  cualquier sospecha.
- **Rotación:** crear llave nueva (ambas vigentes: es el traslape), configurar el Pi, revocar la
  vieja. El tablero (§6) lista las llaves con **traslape abierto** y las **viejas** para que no
  queden vigentes por olvido.
- **Revocación:** acceso válido sólo si `revocada_en IS NULL` **y** (`expira_en IS NULL OR expira_en
  > now()`) **y** `terminal.activa`. `terminal.activa=false` corta toda la terminal; revocar una
  fila corta sólo esa llave.
- **Telemetría de uso** (M6): `ultimo_uso_en` y `ultima_ip` por llave. Un cambio de IP respecto de
  `ultima_ip` genera `WARNING` y aparece en el tablero. (Un Pi con IP DHCP cambiante dará falsos
  positivos; es una alarma, no un bloqueo.)
- **Alta de la llave** (B4, Q1): **sólo por script de TI** (`service_role`), que la muestra una única
  vez. **Sin endpoint web.** Si algún día se quiere web, que sea un permiso nuevo, nunca
  `terminal_usuario_edicion`.
- **Fallo:** `401` genérico con `WWW-Authenticate: Bearer`, sin distinguir llave desconocida,
  revocada, vencida o terminal inactiva.
- **Aislamiento entre mundos:** `/api/terminal/*` sólo acepta `scjt_`; los endpoints web siguen
  validando el JWT de Supabase y rechazan una llave de terminal por construcción.

### Si el Pi se compromete (terminal sólo de asistencia: severidad media)

| Qué puede hacer con la llave | Contención |
|---|---|
| Subir marcas falsas **de esa terminal**, para cualquier `employee_no` que resuelva (hasta uno de una alta ya en `baja`: resuelven siempre) | El servidor fija `terminal_id` y `origen`; degrada relojes absurdos y limita la tasa (§2); el **tablero** detecta marcas posteriores a `baja_confirmada` y picos (§6). Se corrige con **revocar + rotar**; las marcas ya insertadas son inmutables (`SCJ-DEC-03`), se corrigen con `tiempo.correccion` delimitando por `terminal_id` + `momento_recepcion` |
| Reportar transiciones (`usuario_creado`, `huella_capturada`, `baja_confirmada`, `error`) | Sólo sobre altas **de su terminal** (el RPC lo valida) y sólo las que valida el trigger. No puede `asignado` ni `baja_solicitada`. Un `baja_confirmada` falso se repara con un `asignado` nuevo |
| Leer el mapa de **su** terminal | Obtiene `employee_no`, estado y conteo de huellas. **Ya no obtiene `persona_id` ni nombres** (§3): un Pi comprometido no puede unir un `employee_no` con una persona |
| Todo lo demás (otras terminales, `personas`, la base) | **No puede.** La llave sólo llega a `/api/terminal/*`, que sólo llama a los RPC de §3, todos con `p_terminal_id` fijado por el servidor |
| Abrir una puerta | No aplica: terminal de sólo asistencia |

---

## 2. Ruta de marcas: RPC `tiempo.fn_marca_terminal_registrar`

### Opciones consideradas

**A — `INSERT` con `service_role`.** *En contra:* la RLS no corre; `origen='terminal'`, el cruce con
persona y el límite por terminal serían convenciones del código.

**B — El backend mintea un JWT de 60 s con `role=terminal_checador`.** Conserva la RLS y el trigger.
*Descartada por el usuario:* obliga a guardar `SUPABASE_JWT_SECRET` en el backend (el secreto con
el que se firma cualquier rol) y agrega PyJWT; además, sin `SELECT`, el rol no puede ni leer el
`RETURNING` ni resolver `employee_no`. El rol `terminal_checador` **sigue existiendo** (`37_*.sql`,
sin cambios) pero el puente ya no lo usa.

**C — RPC `SECURITY DEFINER`** *(elegida por el usuario).*
`tiempo.fn_marca_terminal_registrar(p_terminal_id bigint, p_eventos jsonb)`. *A favor:* el
backend no gana secretos; el rol de API sólo tiene `EXECUTE` sobre una función cuyo código fija
`origen`, valida la terminal y resuelve la identidad; el procesamiento es **por evento** dentro de la
base (sin 200 viajes HTTP, con un sub-bloque por evento para que uno malo no tumbe el lote). *En
contra:* lógica de negocio en SQL: se prueba con ensayos `BEGIN … ROLLBACK` (como `SCJ-DEC-11`) y no
con mocks de pytest; es una función grande que exige revisión de `db`+`security`.

### Contrato del endpoint

`POST /api/terminal/marcas` (credencial de terminal). Cuerpo:

```json
{
  "terminal_id": "SERIE-DE-LA-TERMINAL",
  "version_software": "1.0.0",
  "eventos": [
    {"evento_id": "uuid", "employee_no": 17, "secuencia_local": 4417,
     "momento_dispositivo": "2026-10-06T15:03:00Z", "desfase_local": "-06:00",
     "estado_reloj": "sincronizado"}
  ]
}
```

Respuesta `200` cuando la credencial es válida y el lote respeta el tope (confirmación
**individual**, `SCJ-CDT-01 §IX.2`):

```json
{"momento_recepcion": "…", "resultados": [
  {"indice": 0, "evento_id": "uuid", "estado": "confirmado"},
  {"indice": 1, "evento_id": "uuid", "estado": "duplicado"},
  {"indice": 2, "evento_id": "uuid", "estado": "rechazo_definitivo", "codigo": "no_enrolado"},
  {"indice": 3, "evento_id": "uuid", "estado": "rechazo_transitorio", "codigo": "tope_terminal"}
]}
```

- **El Pi manda `employee_no`, no `persona_id`.** El `persona_id` **nunca sale del servidor**
  (§3). El RPC lo resuelve con `(p_terminal_id, employee_no)` sobre `tiempo.terminal_usuario`.
  Como el `employee_no` nunca se reutiliza (`SCJ-DEC-11`), esa resolución es **inequívoca incluso
  para altas ya en `baja`**: una marca legítima encolada antes de la baja se atribuye a la persona
  correcta. `tiempo.marca.persona_id` sigue `NOT NULL`: lo llena el RPC. **`employee_no` no se
  persiste en `tiempo.marca`.**
- **Tope 200:** más de 200 eventos o lote vacío → `422` del lote entero (violación de protocolo).
  También lo valida el RPC (defensa en profundidad).
- El backend reconstruye cada evento con **lista blanca de claves** (descarta `origen`,
  `requiere_revision`, `persona_id` y cualquier otra), inyecta `version_software` en cada uno y
  pasa el `jsonb` al RPC con `p_terminal_id` tomado de la credencial. `terminal_id` del cuerpo sólo
  se compara con la credencial.
- Error de **lote** (credencial → `401`/`403`; terminal inactiva en el RPC → `403`; tope → `422`;
  conexión/Supabase caído → **`503`**, no un `200` con 200 transitorios: el Pi trata cualquier no-2xx
  como "reintentar", que es lo correcto).
- `momento_recepcion` lo pone el default `now()`.

### Lo que hace el RPC

Cabecera obligatoria: `SECURITY DEFINER`, `SET search_path = tiempo, personas, pg_temp`,
`REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`, `GRANT EXECUTE … TO service_role` (y repetir
esas cláusulas en cualquier `CREATE OR REPLACE` futuro, gotcha de `CLAUDE.md`).

1. **Terminal válida:** `p_terminal_id` existe y `activa`; si no, `RAISE` `SCJ12`/`terminal_no_valida`
   (el mismo código de `81_*.sql`). Resuelve `terminal.terminal_id` (la serie) para escribir en
   `tiempo.marca.terminal_id`.
2. **Por evento**, en un sub-bloque `BEGIN … EXCEPTION … END` (savepoint), en orden de
   `secuencia_local`:
   1. **Forma** (todo cast y rango dentro del sub-bloque): `evento_id` uuid; `employee_no` entero
      1–99999999; `secuencia_local` entero ≥ 0; `momento_dispositivo` timestamptz con zona;
      `desfase_local` con `^[+-]\d{2}:\d{2}$` (el `CHECK` real de `tiempo.marca`) **y**, como
      validación **nueva del RPC**, rango real (−12:00…+14:00, minutos 00–59); `estado_reloj` en los
      3 valores; `version_software` 1–16 (`varchar(16)`); `secuencia_local` obligatoria
      (`NOT NULL` si `origen='terminal'`). Falla → `rechazo_definitivo`/`forma_invalida`.
   2. **Absurdos** (A2): `momento_dispositivo` anterior a `2024-01-01` o posterior a `now() + 1 año`
      → `rechazo_definitivo`/`forma_invalida`. **Es el único rechazo por tiempo** (Q7).
   3. **`secuencia_local` acotada** (A2): ≤ `max(secuencia_local de la terminal) + 1 000 000` → si
      no, `rechazo_definitivo`/`secuencia_fuera_de_rango`.
   4. **Resolución:** `SELECT persona_id, estado FROM terminal_usuario WHERE terminal_id =
      p_terminal_id AND employee_no = …` (único sin condición de estado: resuelve también altas en
      `baja`). **Sin fila, o con el alta en `pendiente_alta`** → `rechazo_definitivo`/`no_enrolado`
      (ver abajo: un usuario que aún no existe en el aparato no puede haber generado una marca).
   5. **Degradación del reloj** (A2): si el evento declara `sincronizado` pero
      `momento_dispositivo > now() + 5 min` o `< now() − 7 días`, se inserta como `deriva`. El
      trigger `trg_marca_valida_revision` entonces crea la excepción `reloj_no_sincronizado` (el
      Pi no lo ve ni importa). No se rechaza: la evidencia se conserva y se revisa.
   6. **Topes** (A2): por **persona**, > 10 marcas recibidas en la última hora → se inserta pero se
      cuenta como **alarma**; por **terminal**, > 1 000/h es alarma y > 5 000/h →
      `rechazo_transitorio`/`tope_terminal` (el Pi reintenta con backoff y se drena sin perder nada;
      sólo frena una inundación). Valores propuestos, ajustables (Pregunta Q10).
   7. **Duplicado / conflicto** (M3, M7): si ya existe una marca con ese `evento_id`:
      comparar `(terminal_id, persona_id resuelto, momento_dispositivo, secuencia_local)`; todos
      iguales → `duplicado` (éxito idempotente); alguno distinto → `rechazo_definitivo`/
      `conflicto_evento` (con `RAISE WARNING` en el log de la base; el backend lo reemite como
      `ERROR`). Si no existe, `INSERT` con **`origen='terminal'` fijado por la función**,
      `requiere_revision=false`, `terminal_id` = la **serie** (`tiempo.terminal.terminal_id`,
      `varchar(32)`; no el `bigint` `id`). **Un `23505` no siempre es `secuencia_duplicada`:** el
      sub-bloque lee `GET STACKED DIAGNOSTICS … CONSTRAINT_NAME`; `uq_marca_evento_id` (carrera: otro
      lote insertó el mismo evento entre el `SELECT` y el `INSERT`) → se **re-lee** por `evento_id` y
      se responde `duplicado` o `conflicto_evento` con la misma comparación; **sólo**
      `uq_marca_terminal_secuencia` → `rechazo_definitivo`/`secuencia_duplicada`. *El
      `SELECT` previo por `evento_id` se conserva además del diagnóstico: si ambas únicas chocaran a
      la vez, Postgres reportaría la que revise primero y un duplicado legítimo se vería como
      `secuencia_duplicada`.*
   8. **Errores no previstos** (B7): `WHEN data_exception` (clase 22), `not_null_violation`
      (23502) y `check_violation` (23514) → `rechazo_definitivo`/`forma_invalida`;
      `WHEN OTHERS` → `rechazo_transitorio`/`error_interno` y `RAISE WARNING` con el SQLSTATE (no
      con `SQLERRM`). **Regla:** sólo se declara definitivo un error de datos que se reconoce por
      clase; todo lo desconocido es transitorio.
3. **El RPC sólo devuelve códigos de una lista cerrada, nunca texto de excepción.**

**Códigos de `rechazo_definitivo`:** `forma_invalida`, `no_enrolado`, `secuencia_duplicada`,
`secuencia_fuera_de_rango`, `conflicto_evento`. **`rechazo_transitorio`:** `tope_terminal`,
`error_interno`.

### `no_enrolado`: ¿rechazar o insertar con revisión forzada? **Decisión del usuario: rechazar.**

Insertar con revisión forzada es **imposible sin falsear la identidad**: `tiempo.marca.persona_id`
es `NOT NULL` con FK a `tiempo.persona`, así que habría que atribuir la marca a una persona
inventada. Eso viola `SCJ-FRO-01` y contaminaría la paridad del día de alguien. El principio de
`SCJ-CDT-01 §II.5` ("la evidencia nunca se pierde") se cumple **conservando la evidencia fuera de
Tiempo**: el Pi la deja en `pendiente_intervencion` y el servidor la registra en
`tiempo.marca_rechazada` (§6, corte `84_*.sql`; hasta entonces, log estructurado). Si el
`employee_no` nunca existió, es un aparato mal sincronizado o un intento de falsificación — justo lo
que debe quedar en el tablero, no en el día de una persona.

**Caso `pendiente_alta` (decidido con `db`, 2026-10-06):** un `employee_no` cuya alta está en
`pendiente_alta` también se **rechaza** como `no_enrolado`. El aparato **no pudo haber creado ese
usuario** (el Pi aún no reportó `usuario_creado`), así que una marca con ese número es, con alta
probabilidad, una falsificación o un número adivinado, no un evento real; aceptarla permitiría marcar
con un `employee_no` que acaba de asignarse y aún no existe en el aparato. Los estados
`esperando_huella`, `activo` y `pendiente_baja` sí resuelven (el usuario existe en el aparato, o
existió hasta ahora), y `baja` también (marca legítima encolada antes de la baja).

### Persona inactiva

No se rechaza ni se filtra: se inserta y el trigger crea `persona_inactiva` (`SCJ-DEC-11` riesgo 1).
El Pi recibe `confirmado`.

### Humo no destructivo del primer despliegue

Ningún caso de éxito se puede deshacer en esta base (`Prefer: tx=rollback` se ignora). La prueba de
humo es un evento con `employee_no` **inexistente**: `no_enrolado` prueba credencial → backend →
RPC → permisos de `EXECUTE` **sin insertar nada**. Un ensayo del camino de éxito se hace sólo en
`psql` dentro de `BEGIN … ROLLBACK` (`db`).

---

## 3. Endpoints del lado de la terminal (credencial de terminal)

Router `backend/app/routers/terminal.py`, prefijo `/api/terminal`, todos con `get_terminal_actual`.
**Aislamiento entre terminales dentro de SQL** (M2): el backend no consulta tablas con un `.eq
("terminal_id", …)` que un descuido omita y filtre a otra terminal; **cada lectura y cada escritura
es un RPC que recibe `p_terminal_id`** (tomado de la credencial) y la validación de pertenencia
vive en la función.

| Endpoint | RPC (todos `SECURITY DEFINER`, `EXECUTE` sólo `service_role`) | Qué hace |
|---|---|---|
| (dependencia) | `fn_terminal_autenticar(p_hash char(64), p_ip text)` | Busca la credencial vigente y la terminal activa; actualiza `ultimo_uso_en`, `ultima_ip` y `ultimo_contacto_en` (máx. una escritura por 30 s); devuelve `{terminal_id bigint, serie, ip_cambio boolean}` o nada |
| `GET /api/terminal/mapa` | `fn_terminal_mapa(p_terminal_id)` | Altas **no-`baja`** de esa terminal: `{terminal_usuario_id, employee_no, estado, huellas_capturadas}`. **Sin `persona_id`, sin `persona_activa`, sin nombres** |
| `GET /api/terminal/cola` | (misma) | Lo mismo filtrado en el backend a `pendiente_alta`, `pendiente_baja`, `esperando_huella` |
| `POST /api/terminal/movimientos` | `fn_terminal_movimiento_registrar(p_terminal_id, p_terminal_usuario_id, p_tipo, p_huellas, p_detalle)` | Reporta `usuario_creado`, `huella_capturada`, `baja_confirmada`, `error` |
| `POST /api/terminal/latido` | `fn_terminal_latido(p_terminal_id, p_hora_terminal, p_alcanzable, p_reloj_sincronizado, p_version_pi, p_marcas_pendientes)` | Guarda el estado y responde `{hora_servidor, desfase_reloj_seg, ultima_secuencia_recibida}` |
| `POST /api/terminal/marcas` | `fn_marca_terminal_registrar` (§2) | — |

**Qué cambia por quitar `persona_id`:** el Pi ya no sabe a quién pertenece cada `employee_no`.
`persona_activa` desaparece del mapa. La baja por inactividad de la persona **no** llega al Pi como
un filtro local: llega como un `pendiente_baja` (§5). Nada en el Pi necesita nombres ni UUID.

**`fn_terminal_movimiento_registrar`:** (a) `SELECT … FOR UPDATE` de la alta por id **y**
`terminal_id = p_terminal_id`; si no existe → devuelve `{resultado: "no_encontrado"}` (el backend
responde `404`, no `403`: no revelar que existe en otra terminal); (b) acepta sólo los 4 tipos del Pi
(cualquier otro, `RAISE`); (c) **idempotencia dentro de la función, sin carrera** (la fila quedó
bloqueada): si el estado ya es el destino → `{resultado: "ya_aplicado"}` sin insertar
(`usuario_creado` con alta en `esperando_huella` o `activo`; `huella_capturada` con alta `activo` y
mismo conteo; `baja_confirmada` con alta en `baja`; `error` siempre se inserta); (d) inserta en la
bitácora **con `terminal_usuario_id`, `terminal_id`, `persona_id` y `employee_no` tomados de la fila**
(el Pi sólo manda el id de la alta), `origen='terminal'`, `registrado_por=NULL`. Esto cumple lo que
las policies de INSERT de `81_*.sql` dejan a cargo del servidor: **sólo esta función garantiza
`origen='terminal'` y autor `NULL`** (los `CHECK` de la tabla lo respaldan).

**Saneo de `detalle`** (backend, antes del RPC; el RPC aplica además `left(…, 500)`): colapsar
espacios, quitar caracteres de control y marcado `<…>`, truncar a 500; se guarda `codigo: detalle`.
Es defensa en profundidad: el contrato con el Pi es **nunca** mandar cuerpos ISAPI, cabeceras ni
datos de otros usuarios (`SCJ-DEC-11` nota 4).

**`fn_terminal_latido`:** guarda `terminal_alcanzable`, `reloj_desfase_seg` (calculado en el servidor
con `p_hora_terminal`), `version_pi` y `marcas_pendientes` en `tiempo.terminal`. **`ultima_secuencia_recibida`**
(`max(secuencia_local)` de la terminal) existe por un riesgo real: si el Pi se reinstala y su contador
vuelve a 1, sus marcas chocarían con `uq_marca_terminal_secuencia` (`SCJ-DEC-09`) y serían
`secuencia_duplicada`.

**Latido sin carrera de escrituras:** `fn_terminal_autenticar` ya actualiza `ultimo_contacto_en` en
cualquier llamada autenticada (limitado a una escritura por 30 s); el latido existe para transportar
el estado del aparato.

---

## 4. Endpoints del lado web (RLS es la autorización real)

Router `backend/app/routers/terminales.py`, prefijo `/api/terminales`, `get_caller_client` +
`requiere_permiso(...)`. **Nunca `service_role`** para escribir `asignado`/`baja_solicitada`: la policy
`bitacora_terminal_usuario_insert_web` ya exige `terminal_usuario_edicion` y
`registrado_por = auth.uid()` (lección de `31_*.sql`).

| Método y ruta | Gate | Qué hace |
|---|---|---|
| `GET /api/terminales` | `terminal_usuario_lectura` o `_edicion` | Terminales con `estado_contacto` (§6) |
| `GET /api/terminales/{id}/usuarios` | ídem | Altas con estado; filtros `estado`, `persona_id`, `desde`; orden por `creado_en` desc (listado de **altas recientes**, B3); nombres con el mismo cruce que `marcas.py::_resolver_nombres_persona` |
| `POST /api/terminales/{id}/usuarios` `{persona_id}` | `terminal_usuario_edicion` | Inserta `asignado`. **Regla de auto-asignación abajo.** `201` |
| `POST /api/terminales/{id}/usuarios/{tu_id}/baja` `{motivo?}` | `terminal_usuario_edicion` | Lee la alta (RLS) e inserta `baja_solicitada` con `terminal_id`/`persona_id` de esa fila. `motivo` saneado a 500. `201` |
| `GET /api/terminales/{id}/usuarios/{tu_id}/movimientos` | lectura o edición | Bitácora con `registrado_por_nombre` (patrón de `movimientos.py`); `origen='terminal'` se muestra "Terminal" |
| `GET /api/terminales/{id}/anomalias` | ídem | Tablero (§6) |

### Auto-asignación (B3, decisión 4 del usuario)

**Prohibida: `422` si `persona_id` del asignado = persona del caller**, **excepto** cuando el caller
ocupa el **puesto administrador genérico** (`personas.puesto.es_administrador_generico`, hoy "Gerente
o Encargado de TI").

Cómo lo resuelve el backend, **reutilizando `permisos.py`** sin tablas ni endpoints nuevos:
`resolver_persona_id(db, caller)` da la persona del caller; si coincide con `datos.persona_id`, se
llama un helper nuevo `permisos.es_administrador_generico(db, persona_id)` que hace
`resolver_puestos_vigentes(db, persona_id)` y consulta `personas.puesto.select("es_administrador_
generico").in_("id", puestos)`, y devuelve `any(...)` — es la misma columna que ya lee
`routers/asignaciones.py::_validar_puesto_no_es_administrador_generico` y `routers/permisos.py`.
Se usa `get_caller_client` (el árbol de puestos ya lo lee el caller). Un solo puesto vigente con el
flag basta. Sin ese flag, el caller que se asigna a sí mismo recibe `422` con mensaje fijo.

*Por qué la excepción:* el administrador es quien en la práctica enrola el primer aparato y no hay
nadie "por encima" que pueda asignarlo; la bitácora ya deja constancia (`registrado_por`).

### Mapeo de errores — `errores.py::manejar_error_terminal_usuario(error)`

Mismo patrón que `manejar_violacion_unicidad` (`NoReturn`, desde `except APIError`; lo no reconocido
se **relanza** y cae al handler genérico de `main.py`, que **no serializa `str(exc)`**, B2).
`APIError` expone `.code`, `.hint`, `.message`, `.details`.

| Error | HTTP | `detail` fijo |
|---|---|---|
| `SCJ11` | **409** | "El movimiento no es válido para el estado actual del alta." |
| `SCJ12` + `alta_duplicada` | **409** | "La persona ya tiene un alta vigente en esta terminal." |
| `SCJ12` + `persona_no_activa` | **422** | "La persona no existe o no está activa." |
| `SCJ12` + `terminal_no_valida` | **422** | "La terminal no existe o no está activa." |
| `23503` | **422** | "La persona no está sincronizada en el esquema de tiempo; avisa a Sistemas." |
| `23505` (carrera) | **409** | "Otra asignación de esta persona ocurrió al mismo tiempo; recarga." (vía `manejar_violacion_unicidad`) |
| `42501` | **403** | "No tienes permiso para esta acción." — **siempre con `ERROR` en el log** (B2): un 42501 inesperado es una policy rota o un grant faltante, no un usuario sin permiso |
| otro | relanza | `500` genérico |

El texto original **nunca** va a la respuesta (puede traer ids internos, `SCJ-DEC-11` riesgo 3). Una
asignación rechazada por `23503` **sí quema** un `employee_no` (el `nextval` ocurre dentro del
`INSERT` que falla): hueco cosmético aceptado.

---

## 5. Baja de persona (M4)

**Hook sincrónico + job idempotente. Ambos usan un único RPC**, para que haya un solo camino y un
solo criterio de autor:

`tiempo.fn_terminal_baja_por_persona_inactiva(p_persona_id uuid) → integer` — `SECURITY DEFINER`,
`EXECUTE` sólo `service_role`.

1. Verifica que `personas.persona.estado <> 'activo'` (si está activa, no hace nada: no se puede usar
   para dar de baja a personas activas). Los valores reales de `estado` son **`'activo'`,
   `'suspension'` y `'baja_definitiva'`** (verificado por `db`; ojo: es `suspension`, no
   `suspendido`); "distinto de `'activo'`" cubre ambos y también una persona inexistente, que es
   como lo evalúa `trg_marca_valida_revision` (`72_*.sql`).
2. Deriva el **autor** del último `personas.bitacora_movimiento_persona` de esa persona con
   `tipo_movimiento IN ('suspension','baja_definitiva')` y toma su `registrado_por` — **no hay usuario
   "sistema" ni `origen='sistema'`** (Q4): la baja queda atribuida a quien dejó inactiva a la persona.
   Si no hay movimiento o su autor es `NULL`, devuelve `-1` y deja un `ERROR` en el log (no inventa autor).
3. Por cada alta de esa persona con `estado NOT IN ('pendiente_baja','baja')` inserta
   `baja_solicitada` (`origen='web'`, `registrado_por = autor`, `detalle = 'baja automática: la
   persona pasó a <estado>'`). `SCJ11` y `SCJ12` por alta se ignoran (carrera / ya hecha). Devuelve
   cuántas emitió.

- **Hook:** en `routers/movimientos.py::crear_movimiento`, tras el `INSERT` exitoso y sólo si
  `tipo_movimiento ∈ {suspension, baja_definitiva}`, llama el RPC con `service_role`. Si falla, el
  movimiento **ya está confirmado y es el acto principal**: se responde `201` con
  `advertencias: ["baja_terminal_pendiente"]` (campo nuevo opcional en `MovimientoOut`, default `[]`)
  y `ERROR` en el log.
- **Job (scheduler):** intervalo de 10 minutos en `scheduler.py` (mismo estilo que los jobs de batch:
  función Python llamada directo, sin gate HTTP). Busca personas `estado <> 'activo'` con altas
  vigentes y llama el RPC por cada una. **Idempotente:** sin altas no hace nada; `SCJ11`/`SCJ12` se
  ignoran. Es la red de seguridad del hook y reconcilia retroactivamente.
- **Por qué con `service_role` y no con el caller:** quien suspende tiene `cambio_estado_persona`,
  que **no** implica `terminal_usuario_edicion`; con la RLS del caller el `INSERT` se rechazaría y la
  persona seguiría marcando. La autorización ya ocurrió en el acto de suspender.
- **Dos escrituras, no una transacción:** cruzar `personas`→`tiempo` por trigger violaría
  `SCJ-FRO-01`. La ventana de inconsistencia (hook falló, job aún no corrió) la cubre el tablero (§6)
  y, como último respaldo, `persona_inactiva` en el trigger de marcas.
- **Reactivar no reenrola:** el alta ya está en `pendiente_baja`/`baja`; RH debe asignar de nuevo
  (`employee_no` nuevo, huella nueva presencial).
- **Varios workers:** el `BackgroundScheduler`
  embebido duplicaría el job con varios workers de uvicorn; por eso la idempotencia es requisito, no
  optimización.

---

## 6. Monitoreo, tablero de anomalías y desactivación

### Estado de contacto (calculado al leer, sin estado persistido)

`GET /api/terminales` devuelve `ultimo_contacto_en`, `segundos_sin_contacto` y un nivel: `en_linea`,
`sin_contacto`, `nunca`, `inactiva`. Latido recomendado cada **60 s**; umbral `sin_contacto`
**5 min**, por variable de entorno `TERMINAL_UMBRAL_SIN_CONTACTO_SEG` (Q5, no `tiempo.parametro`).
Con las columnas de estado: `terminal_alcanzable=false` (el Pi habla pero no ve la terminal),
`reloj_desfase_seg`, `version_pi`, `marcas_pendientes`.

### Tablero de anomalías de marcas (B5) — `GET /api/terminales/{id}/anomalias`

Todo de sólo lectura y calculado al consultar. Cada bloque se acota a un periodo (`desde`, defecto 7
días):

| # | Anomalía | Cómo se calcula |
|---|---|---|
| 1 | Marcas posteriores a la baja | `momento_dispositivo` de una marca de la persona **posterior** al `baja_confirmada` de su alta: el usuario ya no existe en el aparato, no debería poder marcar |
| 2 | Picos de tasa | Personas con > 10 marcas/hora; terminal con > 1 000/h (los umbrales del RPC) |
| 3 | Reloj degradado | Marcas con `estado_reloj='deriva'` y excepción `reloj_no_sincronizado` recientes; `reloj_desfase_seg` de la terminal |
| 4 | Huecos de secuencia | Saltos en `secuencia_local` por terminal (`SCJ-CDT-01 §VIII.1`) |
| 5 | Rechazos definitivos | Conteo por `codigo` desde `tiempo.marca_rechazada` (cuando exista) |
| 6 | Credenciales | Cambio de IP reciente, llaves de más de 12 meses, **traslape abierto** > 7 días, sin uso reciente |
| 7 | Inconsistencias de baja | Personas `estado <> 'activo'` con alta no-`baja` (el hook y el job fallaron) |
| 8 | Altas atascadas | `pendiente_alta`/`pendiente_baja`/`esperando_huella` más viejas que N horas (el Pi no procesa) |
| 9 | Altas recientes | Listado de las últimas asignaciones, quién las hizo (control de abuso, B3) |

**Corrige la referencia rota del borrador anterior:** la anomalía "marcas de la terminal de personas
sin alta" ya **no existe** como categoría: con `employee_no`, toda marca insertada tiene alta; lo que
queda sospechoso es la fila 1 (marca tras la baja).

### `tiempo.marca_rechazada` (Q3: corte siguiente; diseño breve)

Existe para **no perder la evidencia de un `rechazo_definitivo`** si el Pi se reinstala o se pierde
(`SCJ-CDT-01 §II.5`). Tabla de sólo inserción, sin datos de identidad: `id`, `terminal_id bigint FK`,
`evento_id uuid`, `employee_no integer`, `secuencia_local bigint`, `momento_dispositivo timestamptz`,
`desfase_local varchar(6)`, `estado_reloj varchar(20)`, `codigo varchar(30)` (lista cerrada),
`creada_en`; `UNIQUE (terminal_id, evento_id)` con `ON CONFLICT DO NOTHING` (un reintento no la
duplica). **Todo con tipos acotados y sin texto libre**, de modo que su tamaño por fila es fijo.
**Tope de tamaño:** el RPC inserta como máximo **5 000 filas por terminal por día**; pasado el tope
sólo cuenta y deja `ERROR` (una inundación no llena el disco). **Retención de 90 días.** Los dos
números (5 000/día, 90 días) son **valores iniciales ajustables**, con comentario en el DDL, no
constantes mudas. Hasta que exista la tabla: **log estructurado** `evento_id`, `terminal_id`,
`codigo`, `employee_no`.

**Excepción deliberada a la inmutabilidad en 3 capas de `81_*.sql` (decisión de `db`):** la bitácora
de `81_*.sql` es inmutable por `UPDATE`/`DELETE`/`TRUNCATE` incluso para `service_role` porque es
auditoría legal; `marca_rechazada` es **evidencia diagnóstica con vida limitada** y por eso **debe
poder borrarse**, pero sólo por un camino. Por tanto: `REVOKE ALL` a `anon`/`authenticated`/
`service_role` y `GRANT SELECT, INSERT` únicamente (**sin `UPDATE`/`DELETE`/`TRUNCATE` para ningún
rol de la API**, y `REVOKE ALL` de su secuencia identity); **la purga es el único camino de borrado**:
una función `SECURITY DEFINER` con `search_path` fijo, `REVOKE EXECUTE … FROM PUBLIC, anon,
authenticated` y `GRANT EXECUTE` sólo a `service_role`, llamada desde el scheduler. No lleva
triggers de inmutabilidad (la propia purga los dispararía); la garantía es de privilegios, no de
trigger. Debe quedar anotado como excepción en el encabezado del `84_*.sql` y en
`verificar_ddl.sql`.

### Relación con APScheduler

Un solo job nuevo: la reconciliación de bajas (§5). El **cálculo de contacto y del tablero no tiene
job**: se calcula al leer. No hay canal de alerta saliente en el proyecto (`SCJ-CDT-01 §IX.5`:
"tablero, no correo inmediato"). Un job de empuje de alertas se difiere.

### Desactivación de una terminal

Procedimiento obligatorio (`terminal.activa=false` **corta todo** el acceso, incluidos los reportes
de baja, así que no puede ser el primer paso):

1. Dejar de asignar (el trigger de `asignado` ya exige terminal activa; ver la carrera abajo).
2. Emitir `baja_solicitada` de **todas** las altas no-`baja` de la terminal.
3. Esperar a que el Pi reporte `baja_confirmada` de cada una y a que `marcas_pendientes` del latido
   sea `0` (si no, se pierden marcas encoladas).
4. Sólo entonces `activa=false` y revocar las credenciales.
5. **Reset físico del equipo** (restaurar de fábrica la terminal y reflashear/borrar el Pi): sin eso,
   las huellas y el `.env` siguen en el aparato.

**Aplicación en base (decisión de `db`, 2026-10-06; ambas piezas van en `83_*.sql`):**

- **B. Trigger `SCJ13`:** `BEFORE UPDATE OF activa ON tiempo.terminal ... WHEN (OLD.activa AND NOT
  NEW.activa)`, función `SECURITY DEFINER`, `SET search_path = tiempo, personas, pg_temp` y
  `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated, service_role`. Si existen altas no-`baja` de
  esa terminal, aborta con `SCJ13` (hint `terminal_con_altas_vigentes`). `SCJ13` está **libre**
  (`SCJ13`–`SCJ15` libres, el último usado es `SCJ12`; verificado por `db`). Lo bloquean así tanto la
  UI/script como cualquier `UPDATE` directo de `service_role`.
- **A. Carrera desactivación vs. `asignado`:** sin más, una asignación concurrente podría colarse
  entre el conteo de altas del trigger y el `UPDATE` de `activa`. **El trigger hace `SELECT … FOR
  UPDATE` sobre la fila de la terminal ANTES de contar altas**, y en `asignado` el chequeo de
  terminal activa pasa a **`SELECT … FOR SHARE`** (hoy es un `EXISTS` sin bloqueo), de modo que o la
  asignación ve la terminal ya inactiva, o la desactivación ve la alta ya creada. Como `81_*.sql` ya
  está **aplicado**, el cambio es un **`CREATE OR REPLACE FUNCTION
  tiempo.fn_bitacora_terminal_usuario_aplica()` en `83_*.sql`, que debe repetir `SECURITY DEFINER`
  y `SET search_path = tiempo, personas, pg_temp`** (gotcha de `CLAUDE.md`: el `CREATE OR REPLACE`
  no hereda esas cláusulas) y conservar íntegro el resto de la función. **Nunca se edita `81_*.sql`.**

La UI (cuando exista pantalla de terminales) advierte antes y muestra cuántas altas faltan. Esto no
choca con `SCJ-DEC-11` ("la terminal activa sólo se exige en `asignado`"): sigue siendo cierto que
el **trigger de la bitácora** no exige `activa` en los demás movimientos; lo nuevo es que `activa`
no se puede apagar mientras haya altas vigentes, así que nunca queda una alta atascada en
`pendiente_baja`.

---

## 7. HTTPS y exposición de red (A1, M5, B1)

- **HTTPS es un requisito, no una recomendación**: la llave viaja en cada petición.
  - El backend rechaza `/api/terminal/*` si el esquema efectivo no es `https`
    (`X-Forwarded-Proto`, que sólo se honra cuando la petición viene del proxy de confianza —
    `uvicorn --proxy-headers --forwarded-allow-ips=<IP del proxy>`; si no, un cliente podría
    falsificarlo). Falla cerrada: `TERMINAL_REQUIERE_HTTPS=true` por defecto; sólo `dev` lo apaga.
  - `Strict-Transport-Security` en toda respuesta de `/api/terminal/*` (y en nginx para todo el sitio).
  - **Nota para `devops` — quién termina TLS:** opciones (1) nginx del contenedor `frontend` con
    certificado (Let's Encrypt si hay dominio público; CA interna o `tailscale cert` si es
    sólo-tailnet) y proxy al backend; (2) `tailscale serve`. Debe elegirse una, documentarse en
    `docker-compose.prod.yml` y verificar con `curl -I` que `X-Forwarded-Proto` llega al backend.
  - **Allowlist por IP** del Pi en nginx **sólo si la IP es estable** (por ejemplo, la IP de tailnet);
    con DHCP cambiante genera caídas del checador.
- **Anti-abuso (M5):**
  - **Formato de la llave validado antes de consultar la base** (§1).
  - **nginx:** `limit_req` sobre `/api/terminal/` y `client_max_body_size` ≈ 256 KB (un lote de 200
    eventos pesa ~60 KB).
  - **Backoff por IP tras N `401`** (N=10 en 5 min → `429` creciente, en memoria por proceso;
    **no** se bloquea por llave, para que un atacante no pueda dejar fuera al Pi legítimo mandando
    llaves malas con su nombre). La IP real se toma de `X-Forwarded-For` sólo del proxy de confianza.
  - **Pydantic:** `eventos` con `max_length=200`, cadenas con longitud máxima, `detalle` ≤ 2 000 en
    la entrada (se trunca a 500).
  - **Un lote a la vez por terminal:** `threading.Lock` por `terminal_id` con `acquire(blocking=False)`;
    el segundo concurrente recibe `429 lote_en_proceso` (el Pi reintenta).
- **Logging (B1):** nunca se registra `Authorization`, la llave ni su inicio; los `401` registran sólo
  IP, `User-Agent` y razón genérica; una llave válida se identifica por `credencial_id`. nginx con
  un `log_format` que no incluya `$http_authorization` ni el cuerpo. Cualquier credencial futura en
  `Settings` como `SecretStr`.

---

## 8. Cambios previstos en `checador-fisico`, plan de pruebas y cortes

### 8.1 Cambios previstos en el repo del Pi (sólo lista; no se toca)

1. **`jwt_terminal.py`: se elimina.** El `.env` lleva `BACKEND_URL` y `TERMINAL_API_KEY` (`scjt_…`);
   desaparecen `SUPABASE_URL` y el secreto JWT.
2. **`sync.py`:** deja de `POST`ear a `…/rest/v1/marca`. Envía **lotes ≤200 ordenados por
   `secuencia_local`** a `POST {BACKEND_URL}/api/terminal/marcas`. Manda **`employee_no`**, no
   `persona_id`, ni `origen` ni `requiere_revision`. Aplica `SCJ-CDT-01 §IX.2`:
   `confirmado`/`duplicado` → sincronizada; `rechazo_transitorio` → pendiente con backoff (5 s, 15 s,
   1 min, 5 min, tope 15 min), y **tras N reintentos transitorios (50 o 24 h, lo que ocurra
   primero) pasa a `pendiente_intervencion`** (B7) para no reintentar eternamente; `rechazo_definitivo` →
   `pendiente_intervencion`, **nunca borrar**. Una respuesta `503`/de red = reintentar todo el lote.
3. **`secuencia_duplicada` (M7):** el Pi **renumera** los eventos afectados con
   `ultima_secuencia_recibida + 1 …` (del latido) y los reenvía con **el mismo `evento_id`**. El
   contador `secuencia_local` se persiste y **nunca baja**, ni siquiera tras reinstalar.
4. **`routers/personas.py` (`service_role` temporal): se elimina.** La caché pasa a ser el
   `GET /api/terminal/mapa` (`employee_no` + estado + huellas), la cola a `GET /cola`. **El Pi deja de
   tener cualquier llave de Supabase y deja de conocer `persona_id`.**
5. **Procesador de la cola:** `pendiente_alta` → crear usuario en la terminal por ISAPI con
   `employeeNo` (nombre = rótulo derivado de `employee_no`, Q6) → `usuario_creado`;
   `esperando_huella` → al detectar huellas → `huella_capturada` con el conteo; `pendiente_baja` →
   borrar el usuario (**si ya no existe, es éxito**) → `baja_confirmada`. Falla → `error` con
   `codigo` corto y `detalle` **sin cuerpos ISAPI ni cabeceras**. `200 ya_aplicado` = éxito. Ante
   `409` (`transicion_invalida`) el Pi **relee la cola** y no reintenta a ciegas.
6. **Reconciliación (M8):** periódicamente comparar los usuarios que existen en la terminal con
   `GET /mapa`; **borrar los huérfanos** (en la terminal pero no en el mapa o ya en `baja`) y
   reportar `error` con `codigo=usuario_no_mapeado` (+ `employee_no`, sin más). Detecta tanto
   residuos como usuarios creados a mano en el aparato.
7. **Latido cada 60 s** con `terminal_alcanzable`, `reloj_sincronizado`, `version_pi`, `hora_terminal`
   y `marcas_pendientes` (la cuenta de la cola local, para el procedimiento de §6).
8. **`401`:** dejar de reintentar agresivamente, registrar local, seguir con latido lento (la cola se
   conserva). **HTTPS** hacia el backend (§7).
9. **Activo más delicado del Pi (M8):** la **contraseña de administrador ISAPI** de la terminal
   (permite crear usuarios y huellas directamente). Debe vivir sólo en el `.env` (`600`), con una
   contraseña única por terminal, nunca en logs ni en el repositorio, y el reset físico de §6 la
   renueva.

### 8.2 Plan de pruebas

**Patrón actual** (`tests/test_marcas.py`, `test_gate_permisos.py`): `TestClient(app)` con
`app.dependency_overrides`, `MagicMock` encadenando `postgrest.schema(...).rpc/table(...).execute()
.data`, `APIError({"code", "hint", ...})`, **nada contra Supabase** (CI sin secrets).

- **Backend (pytest, mocks):**
  - `get_terminal_actual`: formato inválido → `401` **sin llamar la base**; RPC sin fila → `401`;
    válida → identidad; `ip_cambio` → `WARNING`; backoff por IP tras N `401` → `429`; el log **no**
    contiene la llave (`caplog`). Los endpoints de terminal sobreescriben la dependencia con una
    `TerminalIdentity` fija.
  - `POST /marcas`: lista blanca de claves (se descartan `persona_id`/`origen`); `terminal_id`
    incoherente → `403`; >200 → `422`; el RPC se mockea y se prueban **todas** las filas de la tabla
    de resultados (`confirmado`, `duplicado`, cada código definitivo/transitorio) y que el cuerpo
    hacia el Pi nunca contiene texto de excepción; excepción de red → `503`; lote concurrente →
    `429`; `conflicto_evento` → `ERROR` en el log.
  - Endpoints de mapa/cola/movimientos/latido: el RPC se invoca **siempre** con
    `p_terminal_id` de la credencial (aserción sobre los argumentos); `no_encontrado` → `404`;
    `ya_aplicado` → `200`; saneo de `detalle`.
  - Web: gate `403` sin permiso; **auto-asignación** `422`, permitida para el puesto con
    `es_administrador_generico`; mapeo **parametrizado** de `manejar_error_terminal_usuario`
    (código+hint → status+detail fijo) y aserción de que el texto de la base **no** aparece;
    `42501` → `403` + `ERROR`.
  - Hook de baja: `suspension`/`baja_definitiva` llaman el RPC; `reactivacion`/`alta` no; si el RPC
    falla, `201` con `advertencias: ["baja_terminal_pendiente"]`. El job: idempotencia (segunda
    pasada no emite), personas activas ignoradas.
  - `scheduler`: el job nuevo se registra (`test_scheduler.py` ya cubre el patrón).
- **SQL (`db`, ensayo `BEGIN … ROLLBACK` por `psql`, el patrón de los 61 casos de `SCJ-DEC-11`) —
  la lógica de los RPC no se puede cubrir con mocks:** cada código de resultado del RPC de marcas;
  resolución por `employee_no` incluso de altas en `baja`; `origen` forzado (aunque el `jsonb`
  traiga otro); degradación a `deriva` en los dos bordes (+5 min / −7 días); rechazo por
  `<2024-01-01` y `> +1 año`; tope de `secuencia_local`; duplicado idéntico vs. `conflicto_evento`;
  `secuencia_duplicada` con `evento_id` nuevo; topes por persona/terminal; ejecución como `anon`/
  `authenticated` **falla** por falta de `EXECUTE`; movimiento sobre alta de **otra** terminal →
  `no_encontrado`; el RPC de baja no actúa sobre personas activas ni inventa autor; el trigger de
  desactivación (`SCJ13`).
- **`db/verificar_ddl.sql`** (B6): secciones nuevas con **0 filas esperadas** — RLS habilitada en
  `terminal_credencial`, sin policies y sin privilegios para `anon`/`authenticated`;
  `service_role` sin `DELETE`/`TRUNCATE` y sin `UPDATE` de `hash`; `char(64)` con `CHECK ~
  '^[0-9a-f]{64}$'`; secuencia sin privilegios; cada función nueva `SECURITY DEFINER`, con
  `search_path` fijo y `EXECUTE` sólo de `service_role`.
- **Humo en el entorno real:** el de `no_enrolado` (§2). Sin pruebas de escritura contra la base
  real fuera de un `ROLLBACK` explícito, sin `Prefer: tx=rollback`.

### 8.3 Orden de implementación (¿partir `82_` y `83_`? **Sí**)

**Decisión del usuario: partir en tres archivos.** `82_*.sql` es **datos y privilegios** (tablas,
columnas, grants): rápido de revisar y de aplicar, y desbloquea el script de TI. `83_*.sql` son
**funciones**: los cinco RPC de §3, el RPC de baja de §5, el trigger `SCJ13` y el `CREATE OR REPLACE`
de `fn_bitacora_terminal_usuario_aplica` (§6) — la parte grande, con ensayo SQL propio y revisión de
`security`. Así un defecto en un RPC no obliga a rehacer el esquema ni a reabrir los grants.
`84_*.sql` (`tiempo.marca_rechazada` y su purga) es un corte posterior.

**Reglas comunes a `82_`/`83_`/`84_` (de `db`):** toda función nueva lleva, **en el mismo archivo**,
`REVOKE EXECUTE … FROM PUBLIC, anon, authenticated` y `GRANT EXECUTE … TO service_role`
(`EXECUTE` llega a `PUBLIC` por defecto); toda secuencia identity nueva (`terminal_credencial`,
`marca_rechazada`) con `REVOKE ALL` a `anon`/`authenticated`/`service_role`; todo `CREATE OR REPLACE`
de función existente repite `SECURITY DEFINER` y `SET search_path`; ningún archivo ya aplicado
(`80_`/`81_`) se edita. **Ensayo siempre con `BEGIN … ROLLBACK` por `psql`**; el humo del primer
despliegue es el del `employee_no` inexistente (§2).

**Tareas del corte de DDL que acompañan al código** (no son parte de este diseño): ampliar
`db/verificar_ddl.sql` (tablas de `tiempo` 20→21/22; secciones 11–13 y 15; sección 16 con las
funciones nuevas; sección 17 con el `search_path` de cada una; sección 18 con el trigger `SCJ13`;
sección 19 con las policies — numeración tal como la reportó `db`, a confirmar al editar el
archivo), y subir `SCJ-DIC-01` a V1.3 y `SCJ-MOD-03` a V1.8.

| # | Corte | Dueño | Contenido |
|---|---|---|---|
| 0 | **`82_*.sql`** | `db` | `tiempo.terminal_credencial` (molde de `80_`/`81_`: RLS sin policies, `REVOKE ALL`, grants mínimos, secuencia revocada, `hash char(64)` con `CHECK`); columnas de estado en `tiempo.terminal` con `GRANT UPDATE` de columna; aviso a RTB-App; alta puntual de la terminal y de la primera llave |
| 1 | **`83_*.sql`** | `db` | Los 6 RPC, el trigger `SCJ13` y el `CREATE OR REPLACE` de `fn_bitacora_terminal_usuario_aplica`; `verificar_ddl` ampliado; ensayo SQL en `BEGIN … ROLLBACK`; revisión de `security` |
| 2 | **Auth de terminal + latido** | `backend` | `terminal_auth.py`, `get_terminal_actual`, anti-abuso, `requiere_https`, script de provisión, `POST /latido` |
| 3 | **Ruta de marcas** | `backend` | `POST /api/terminal/marcas` sobre el RPC; el de mayor riesgo, por eso va antes de la cola; humo de `no_enrolado` |
| 4 | **Mapa, cola y movimientos de terminal** | `backend` | los endpoints de §3 restantes |
| 5 | **Router web** | `backend` | `routers/terminales.py`, helper de errores, auto-asignación, `es_administrador_generico` |
| 6 | **Hook + job de bajas + tablero** | `backend` | hook en `movimientos.py`, job en `scheduler.py`, `estado_contacto`, `anomalias` |
| 7 | **TLS / nginx** | `devops` | terminación de TLS, `limit_req`, `client_max_body_size`, `log_format` sin `Authorization`, HSTS; **antes** de que el Pi hable con producción |
| 8 | **Pi** | repo `checador-fisico` | los cambios de §8.1, tras 2–4 y 7 |
| 9 | **`84_*.sql` + `marca_rechazada`** | `db`+`backend` | tabla (excepción deliberada a la inmutabilidad, §6), inserción desde el RPC, función de purga + job, anomalía 5 |
| 10 | **Pantallas** | `frontend` | asignar, baja, estado de contacto, tablero |

Con 0–4 y 7 el Pi ya opera de punta a punta; 5–6 dan a RH control y visibilidad.

---

## 9. Propuesta de `82_*.sql` (no se escribe; para revisión de `db`)

> Esquema orientativo. **No es ejecutable tal cual**; `db` lo escribe con el molde de `80_`/`81_`.

```sql
-- tiempo.terminal_credencial
CREATE TABLE tiempo.terminal_credencial (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  terminal_id     bigint NOT NULL REFERENCES tiempo.terminal (id),
  hash            char(64) NOT NULL,
  etiqueta        varchar(60),
  creada_en       timestamptz NOT NULL DEFAULT now(),
  expira_en       timestamptz,
  revocada_en     timestamptz,
  ultimo_uso_en   timestamptz,
  ultima_ip       inet,
  ip_cambiada_en  timestamptz,
  CONSTRAINT uq_terminal_credencial_hash UNIQUE (hash),
  CONSTRAINT ck_terminal_credencial_hash CHECK (hash ~ '^[0-9a-f]{64}$')
);
CREATE INDEX ix_terminal_credencial_terminal_id ON tiempo.terminal_credencial (terminal_id);
ALTER TABLE tiempo.terminal_credencial ENABLE ROW LEVEL SECURITY;          -- sin policies
REVOKE ALL ON tiempo.terminal_credencial FROM anon, authenticated, service_role;
GRANT SELECT, INSERT ON tiempo.terminal_credencial TO service_role;
GRANT UPDATE (revocada_en, expira_en, etiqueta) ON tiempo.terminal_credencial TO service_role;
REVOKE ALL ON SEQUENCE tiempo.terminal_credencial_id_seq FROM anon, authenticated, service_role;
-- ultimo_uso_en / ultima_ip / ip_cambiada_en los escribe sólo fn_terminal_autenticar (definer).

-- columnas de estado en tiempo.terminal
ALTER TABLE tiempo.terminal
  ADD COLUMN reloj_desfase_seg    integer,
  ADD COLUMN terminal_alcanzable  boolean,
  ADD COLUMN version_pi           varchar(16),
  ADD COLUMN marcas_pendientes    integer;
-- las escribe sólo fn_terminal_latido (definer); authenticated ya tiene SELECT de tabla (no sensibles)

-- (el trigger SCJ13 'terminal_con_altas_vigentes' y el CREATE OR REPLACE de
--  fn_bitacora_terminal_usuario_aplica van en 83_*.sql, junto con las demás funciones)
-- inventario de RLS al final del archivo (regla de CLAUDE.md)
```

**Inventario de RLS/privilegios de `82_`+`83_`:** `terminal_credencial` (RLS on, 0 policies, sólo
`service_role`); `terminal` (sin cambios de policy; columnas nuevas legibles por RH, no sensibles);
funciones `fn_*` (todas `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`, `GRANT … TO
service_role`). Aviso: `service_role` ya no necesita `INSERT` directo en `bitacora_movimiento_terminal_usuario`
para el puente (lo hacen los RPC), pero se **conserva** su grant actual (`81_*.sql`): se retira
sólo si `security` lo pide.

---

## 10. Cambios tras la revisión de security y las decisiones del usuario (2026-10-06)

**Decisiones del usuario incorporadas:** (1) marcas por RPC `SECURITY DEFINER`, el JWT minteado
queda como alternativa descartada y el backend no guarda `SUPABASE_JWT_SECRET`; (2) el Pi manda
`employee_no`, el servidor resuelve `persona_id`, y `/mapa` ya no expone `persona_id` ni
`persona_activa`; (3) terminal sólo de asistencia: M4 en severidad media; (4) auto-asignación
prohibida salvo para el puesto administrador genérico.

**Hallazgos de security incorporados:**

| ID | Dónde |
|---|---|
| A1 HTTPS obligatorio | §7 (requisito, HSTS, `X-Forwarded-Proto`, nota a `devops`, allowlist condicionada) |
| A2 integridad de marcas | §2 (degradación a `deriva`, absurdos, `no_enrolado`, topes, cap de secuencia) |
| M2 aislamiento entre terminales en SQL | §3 (todo RPC con `p_terminal_id`) |
| M3 `conflicto_evento` | §2 punto 2.7 |
| M4 baja de persona | §5 (hook + job + RPC con autor derivado; `advertencias`) |
| M5 rate limit y tamaño | §1 y §7 |
| M6 telemetría de la llave | §1 y §6 |
| M7 `secuencia_duplicada` | §2 y §8.1 punto 3 |
| M8 reconciliación en el Pi | §8.1 puntos 6 y 9 |
| B1 logging | §7 |
| B2 `42501` | §4 |
| B3 auto-asignación y altas recientes | §4 y §6 |
| B4 provisión por script | §1 |
| B5 tablero y referencia rota | §6 |
| B6 molde de `terminal_credencial` | §9 y §8.2 |
| B7 clase 22/23502/23514 y tope de reintentos | §2 punto 2.8 y §8.1 punto 2 |
| Desactivación | §6 |

**Efectos de segundo orden de las decisiones (para `orchestrator`/`db`):**

- **Quitar `persona_id` del Pi** elimina `persona_activa` y el filtro local; la baja por inactividad
  sólo puede llegar por `pendiente_baja` (§5).
- **Sin `persona_id`, "persona desconocida" se vuelve `no_enrolado`**, y la opción "insertar con
  revisión forzada" es **inviable** por `tiempo.marca.persona_id NOT NULL` (§2).
- **Las bajas siguen resolviendo marcas** y por eso el tablero busca marcas posteriores a
  `baja_confirmada` (§6, fila 1).

---

## 11. Aceptación (2026-10-06): decisiones del usuario, contrato `SCJ-CDT-01 V3.0` y verificación de `db`

### Decisiones del usuario que cierran la propuesta

1. **`no_enrolado` se rechaza** y su evidencia se guarda en `tiempo.marca_rechazada` (`84_*.sql`).
2. **Se aprueba el cambio de contrato:** la marca de terminal lleva `employee_no` en lugar de
   `persona_id`. **Se redactó como `SCJ-CDT-01` V3.0, no V2.1**: `CONVENCIONES.md §I` manda versión
   *mayor* cuando "se contradice o se elimina algo ya escrito", y el cambio contradice §V.1 (`persona_id`
   obligatorio), §II.6 y §V.2 (sólo `persona_id` viaja; el número de plantilla no viaja en la marca) y
   §IX.4 (rechazo por `persona_id` desconocido). El archivo es
   `docs/00-contexto/SCJ-CDT-01_Contrato_de_Datos_de_la_Marca_V3_0.md` (renombrado con `git mv`, con
   nota de cambio al inicio). **`tiempo.marca` no cambia** y **`SCJ-FRO-01` queda intacta**.
3. **El DDL se parte en `82_` (datos y privilegios), `83_` (funciones) y `84_` (`marca_rechazada`).**
4. **Valores de Q10–Q14 aceptados tal cual como valores iniciales ajustables** (no se hardcodean sin
   comentario en el DDL ni en el backend): topes de **10 marcas/h por persona** y **1 000/h** (alarma) y
   **5 000/h** (rechazo transitorio) **por terminal**; **50 reintentos o 24 h** antes de
   `pendiente_intervencion`; retención de **90 días** y tope de **5 000 filas por terminal por día**
   en `marca_rechazada`; la marca posterior a `baja_confirmada` **sólo va al tablero**.
5. **Q11 (quién termina TLS) queda para `devops`.** Q4 y las demás, como se registraron en §10.

### Verificación de `db` contra el DDL real (sólo lectura, 2026-10-06)

**Confirmado:** `SCJ13`, `SCJ14` y `SCJ15` están libres (el último usado es `SCJ12`).
`personas.persona.estado` admite **`'activo'`, `'baja_definitiva'`, `'suspension'`**;
"distinto de `'activo'`" cubre ambos estados y una persona inexistente, y así lo evalúa
`trg_marca_valida_revision` (`72_*.sql`), que sigue funcionando si el RPC es `SECURITY DEFINER`.
`81_*.sql` exige terminal activa sólo en `asignado`, y `SCJ13` no choca con eso (§6). `tiempo.marca`:
`persona_id NOT NULL` con FK; `terminal_id varchar(32)` (la **serie**, no el `bigint`);
`secuencia_local NOT NULL` si `origen='terminal'`; `version_software varchar(16)`;
`desfase_local` con formato `±HH:MM` (el rango −12:00…+14:00 es validación nueva del RPC).
`terminal_usuario` tiene `UNIQUE (terminal_id, employee_no)` **sin condición de estado**, de modo
que resuelve también altas en `baja`.

**Cambios al diseño pedidos por `db` (ya incorporados arriba):**

| # | Cambio | Dónde |
|---|---|---|
| A | Carrera desactivación vs. `asignado`: `FOR SHARE` en `asignado`, `FOR UPDATE` en el trigger antes de contar; `CREATE OR REPLACE` de `fn_bitacora_terminal_usuario_aplica` en `83_*.sql` repitiendo `SECURITY DEFINER` y `SET search_path`; nunca se edita `81_*.sql` | §6 |
| B | Trigger `SCJ13`: `BEFORE UPDATE OF activa … WHEN (OLD.activa AND NOT NEW.activa)`, `SECURITY DEFINER`, `search_path` fijo, `REVOKE EXECUTE` | §6 |
| C | En el RPC un `23505` no siempre es `secuencia_duplicada`: se lee `CONSTRAINT_NAME`; `uq_marca_evento_id` → re-`SELECT` → `duplicado`/`conflicto_evento`; sólo `uq_marca_terminal_secuencia` → `secuencia_duplicada` | §2 punto 2.7 |
| D | Un `employee_no` con alta en `pendiente_alta` se **rechaza** como `no_enrolado` | §2 |
| E | `marca_rechazada` con purga de 90 días es **excepción deliberada** a la inmutabilidad en 3 capas de `81_*.sql`: `REVOKE ALL` + `GRANT SELECT, INSERT`, sin `UPDATE`/`DELETE`/`TRUNCATE` para la API; la función de purga (`SECURITY DEFINER`, `search_path` fijo, `EXECUTE` sólo `service_role`) es el único camino de borrado | §6 |

**Todavía por verificar antes de escribir `82_`/`83_`/`84_` (no se dan por cerrados por este
documento):** la numeración exacta de las secciones de `verificar_ddl.sql` (la que reportó `db` se usó
tal cual en §8.3); que el ensayo `BEGIN … ROLLBACK` del `CREATE OR REPLACE` de
`fn_bitacora_terminal_usuario_aplica` reproduzca los 61 casos de `SCJ-DEC-11` sin regresión;
y que el `FOR SHARE` de `asignado` no introduzca un interbloqueo con el `FOR UPDATE` de la alta
(`SELECT … FOR UPDATE` de `terminal_usuario`) en el ensayo concurrente.

### Choques con `SCJ-CDT-01` — resueltos en V3.0

| Punto de V2.0 | Cómo queda en V3.0 |
|---|---|
| §V.1 `persona_id` obligatorio | `persona_id` sólo en `captura_manual`; `employee_no` sólo en `terminal`; exactamente uno. `origen`, `requiere_revision` y `motivo_revision` los fija/calcula el servidor |
| §II.6 y §V.2 "sólo `persona_id` viaja"; "el número de plantilla no viaja" | Lo único que se **almacena** en Tiempo es `persona_id`; `employee_no` es identificador de **transporte**, se resuelve en el servidor y **no se persiste en `tiempo.marca`** |
| §IX.4 rechazo por `persona_id` desconocido | `employee_no` no enrolado → `no_enrolado`; lista cerrada de códigos, regla de `secuencia_duplicada` (renumerar con el mismo `evento_id`) y tope de reintentos transitorios, en el nuevo §IX.6 |
| §XI y §XV (caché con `persona_id`, `plantilla_desconocida` con `persona_id` nulo) | §XI sustituido (caché sin `persona_id`; `no_enrolado` en vez de `plantilla_desconocida`); §XV reescrito con `employee_no` y `POST /api/terminal/marcas` |
| §VII.2 `estado_reloj` | El servidor sólo puede **empeorarlo** (5 min futuro / 7 días pasado), nunca mejorarlo, y no rechaza por tiempo salvo instantes absurdos; `momento_recepcion` sigue sin entrar al **cálculo de jornada** |

**Convivencia con `tiempo.marca.persona_id NOT NULL`:** la resuelve el RPC antes del `INSERT`; la
tabla no cambia. Al no persistir `employee_no`, la marca no guarda cuál fue el `employeeNo` original;
`terminal_usuario` ya relaciona `employee_no` ↔ `persona_id` de forma permanente y, como el número
no se reutiliza, la reconstrucción es posible. Agregar una columna a `tiempo.marca` tras el
congelamiento **no se propone**.

**Documentos alineados después de la aceptación (6 de octubre de 2026):** `SCJ-ESP-01` → **V3.0**
(§I.4 reglas 1, 3 y 5, §II, §VII; estaban en tensión con `tiempo.terminal_usuario` de `SCJ-DEC-11`),
`SCJ-PRO-11` → **V3.0** (§II.1 decía que el puente entrega `persona_id` ya resuelto; §III y §IV
precisados) y `SCJ-DIC-01` (nota de `momento_recepcion`: §V.4 → §VII.3, corrección de referencia sin
subir versión). `SCJ-ESP-01` y `SCJ-PRO-07` mencionan "`SCJ-CDT-01 V2.0`" como referencia histórica;
no se modifican. El proceso de enrolamiento completo es `SCJ-PRO-15`.

---

## Decisión

- **Credencial:** API key opaca por terminal (`scjt_…`), hash SHA-256 en `tiempo.terminal_credencial`,
  revocable por llave o por `terminal.activa=false` (con procedimiento y trigger), sin vencimiento,
  rotación con traslape, alta sólo por script de TI.
- **Marcas:** RPC `tiempo.fn_marca_terminal_registrar(p_terminal_id, p_eventos jsonb)`,
  `SECURITY DEFINER`, resolución `employee_no → persona_id` en la base, `origen` fijado, degradación
  de reloj, topes y confirmación por evento. **Sin JWT minteado.**
- **Terminal → servidor:** RPC por endpoint con `p_terminal_id` de la credencial. **Web → servidor:**
  `get_caller_client` + `requiere_permiso` + RLS, con mapeo de errores fijo y regla de
  auto-asignación.
- **Baja de persona:** hook sincrónico + job idempotente, un solo RPC, autor derivado.
- **Monitoreo:** calculado al leer, con tablero de anomalías; un solo job nuevo (reconciliación).

## Por qué

Un solo argumento: **la base debe seguir diciendo que no cuando el backend se equivoque, y el
aparato más expuesto no debe saber a quién pertenece cada marca.** Un RPC `SECURITY DEFINER` con
`EXECUTE` sólo para `service_role` fija el `origen`, la terminal y la identidad dentro de la base, no
agrega un secreto al backend, y una llave opaca con hash en la base hace que "se perdió el Pi" sea
una fila revocada y no un secreto compartido.

## Consecuencias

**Se vuelve fácil:** revocar un aparato, rotar sin reiniciar, auditar qué hizo cada terminal,
agregar una segunda terminal (otra fila, otra llave), saber si el Pi está vivo y si su reloj
se desvía.

**Se vuelve difícil / costos asumidos:**
- **Más lógica en SQL** (6 funciones): se prueba con ensayos `ROLLBACK`, no con mocks, y exige
  revisión de `db`+`security` antes de cada `CREATE OR REPLACE` (repetir `SECURITY DEFINER` y
  `search_path`).
- Un 100 % de marcas por el backend: si cae, el Pi acumula (diseñado así); no hay vía directa de
  emergencia.
- **`no_enrolado` no deja marca en Tiempo** (incluye el `employee_no` con alta en `pendiente_alta`):
  sólo evidencia en el Pi + log hasta el corte de `marca_rechazada` (`84_*.sql`).
- `marca_rechazada` es una **excepción deliberada a la inmutabilidad** de las bitácoras del proyecto
  (se purga a los 90 días): la garantía es de privilegios, no de triggers (§6).
- El contrato de la marca de terminal cambia de forma incompatible (`SCJ-CDT-01 V3.0`): el código del
  Pi (`checador-fisico`) debe actualizarse en bloque (§8.1).
- Desactivar una terminal es un procedimiento de cinco pasos con reset físico; no es un interruptor.
- Un Pi con IP cambiante dará falsos positivos de "cambio de IP".

**Queda cerrado:** el Pi nunca vuelve a tocar Supabase ni conoce `persona_id`; `terminal_id` y
`origen` de toda marca de terminal los decide el servidor.

## Cómo se verifica

Las pruebas de §8.2 (pytest sin base real; ensayo SQL en `BEGIN … ROLLBACK`; `verificar_ddl.sql` con
0 filas esperadas), el humo `no_enrolado` de §2, y manual: revocar la llave → siguiente llamada `401`;
`activa=false` con altas vigentes → `SCJ13`; llave nueva en paralelo → ambas funcionan hasta revocar
la vieja.

---

## Preguntas abiertas

**Resueltas por el usuario/security el 2026-10-06:**

| # | Resolución |
|---|---|
| Q1 | Provisión de la llave **sólo por script de TI**, sin endpoint web |
| Q2 | **HTTPS obligatorio** (§7); allowlist por IP sólo si la IP del Pi es estable |
| Q3 | Log estructurado ya; `tiempo.marca_rechazada` como corte siguiente (§6) |
| Q4 | **Sin `origen='sistema'`**: el autor de la baja automática es el autor del movimiento de persona |
| Q5 | Umbral de contacto por **variable de entorno** |
| Q6 | **Sin nombres** en el aparato en v1 |
| Q7 | **Sin rechazo por tiempo**, salvo valores absurdos (§2) |
| Q8 | Resuelta: **sin JWT minteado** ni fallback a `service_role` para marcas |
| Q9 | Resuelta: el mapa **no** lleva `persona_id` ni `persona_activa` |

**Planteadas en la propuesta; resueltas en la aceptación (2026-10-06):** el usuario aceptó **Q10,
Q12, Q13 y Q14 tal cual la recomendación**, como **valores iniciales ajustables** (con comentario,
nunca constantes mudas). **Sólo Q11 sigue abierta** y es de `devops`.

| # | Pregunta | Recomendación aceptada |
|---|---|---|
| Q10 | ¿Valores de los topes de §2: **10 marcas/h por persona** (alarma), **1 000/h por terminal** (alarma) y **5 000/h por terminal** (rechazo transitorio)? | Esos valores. Con ~10-20 personas, una persona supera 10/h sólo con un fallo; ajustar tras un mes de datos reales |
| Q11 | ¿Quién termina TLS (nginx con certificado, `tailscale serve`, otro) y de dónde sale el certificado? | `devops` decide con el estado real de la red; el diseño sólo exige HTTPS verificable |
| Q12 | ¿Los reintentos transitorios del Pi: **50 intentos o 24 h** antes de `pendiente_intervencion`? | Sí; con tope de 15 min entre intentos, 24 h son ~96 intentos, y 50 llegan antes |
| Q13 | ¿Retención de `marca_rechazada` de 90 días y tope de 5 000 filas/terminal/día? | Sí; es evidencia diagnóstica, no registro legal |
| Q14 | ¿La **marca posterior a `baja_confirmada`** (§6 fila 1) debe, además de aparecer en el tablero, **forzar revisión** de la marca? No hay un `motivo_revision` que la describa; agregarlo es cambiar `SCJ-DEC-07`/el catálogo de motivos | **Sólo tablero** por ahora |

---

## Revisión posterior a la implementación

*(se llena al construir, no antes)*
