# Contrato de la API del puente — `/api/terminal/*` (Paquete 3: marcas, cola, mapa, movimientos)

**Estado: PROPUESTA de `backend` para que el puente del Pi se escriba contra ella.** Fecha: 2026-10-09.
Fuentes: `SCJ-DEC-12 V2.1` §2, §3, §12; `SCJ-CDT-01 V3.0` §IX; `PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md` §4.2/§4.4;
`db/ddl/83_*`, `84_*`, `85_*`, `91_*` (firmas reales de los RPC). Ya existe `POST /api/terminal/latido` (corte 1); este documento
define lo que falta: **`POST /marcas`, `GET /cola`, `GET /mapa`, `POST /movimientos`**, y fija las reglas comunes que ya cumple el latido.

---

## 0. Reglas comunes (todos los endpoints de `/api/terminal/*`)

- **Transporte:** sólo HTTPS (`403` «Se requiere HTTPS…» en claro, salvo el modo de desarrollo ya existente). JSON UTF-8.
- **Autenticación:** `Authorization: Bearer scjt_<43 caracteres>` (la llave opaca de la terminal; SHA-256 en la base). **Nunca** el JWT de
  Supabase. El `id` de la terminal sale de la credencial; **ningún cuerpo ni query puede elegir otra terminal**. Si un cuerpo trae
  `terminal_id` (la **serie**), debe coincidir con la de la credencial (`403` «La credencial no corresponde a esa terminal.» si no).
- **Identidad:** el Pi sólo conoce `employee_no`. **`persona_id`, nombres y estado de la persona nunca viajan** en ningún sentido.
- **Cuerpos cerrados:** `extra=forbid` en los envoltorios (un campo desconocido es `422`). Las **claves de cada evento de marca** se
  filtran con lista blanca (§1).
- **Tamaño:** cuerpo máximo **256 KB** (`413`), la misma cifra que el `client_max_body_size` de nginx (`SCJ-DEC-12 §7`); un lote de 200 marcas
  pesa ≈ 40 KB. Lo aplica un middleware ASGI **antes de autenticar y de parsear JSON**: por `Content-Length` y **contando los bytes recibidos**
  (también chunked o con un `Content-Length` mentiroso), sin leer el cuerpo entero en memoria.
- **Caché:** toda respuesta de `/api/terminal/*` lleva `Cache-Control: no-store` y `Strict-Transport-Security` (también los `4xx`/`5xx`).
- **Alcance exacto:** estas reglas (límite de cuerpo, HSTS, `no-store`, 422 fijo) aplican a `/api/terminal` y `/api/terminal/…`, **no** a
  `/api/terminales/…` (la API web). Se evalúa sobre la ruta relativa de Starlette (sin `root_path`).
- **`422` de protocolo:** un cuerpo que no valida, o que no es JSON, responde siempre `422 {"detail": "Los datos enviados no son válidos."}`
  **sin repetir lo que mandó el cliente**. Es un error de protocolo: el Pi **no reintenta el mismo lote** (lo biseca o lo envía unitario).
- **Cuerpo lento (slowloris):** el límite de 256 KB no cubre el tiempo; `limit_req`/`client_body_timeout` en nginx quedan en la lista de `devops`.
- **Errores:** siempre `{"detail": "<texto fijo>"}`; **nunca** texto de la base. Códigos comunes:

| HTTP | Cuándo | El Pi |
|---|---|---|
| `401` | Credencial inválida, revocada, expirada o terminal desactivada | Deja de reintentar agresivamente; registra local; latido lento (`SCJ-DEC-12 §8.1.8`) |
| `403` | HTTPS requerido, o `terminal_id` del cuerpo ≠ credencial | Error de configuración: no reintenta; alerta local |
| `413` | Cuerpo > 256 KB | Bug del Pi: parte el lote |
| `422` | Cuerpo mal formado / lote vacío o > 200 / campo fuera de rango (**error de protocolo**) | **No reintentar igual**; es un bug (el lote no cambia solo) |
| `429` | Demasiados fallos de autenticación desde la IP, o tope de errores por alta (§4) | Respeta `Retry-After` |
| `503` | Base o red caídas, `fn_*` ausente por migración pendiente, respuesta inesperada de un RPC | **Reintentar** con espera creciente (5 s, 15 s, 1 min, 5 min, tope 15 min) |
| `500` | Excepción no prevista (sin texto) | Como `503` |

  Un `2xx` con la confirmación individual (§1) es la **única** señal de que algo quedó guardado. Cualquier otra cosa = «no sé»: reintentar
  (la idempotencia limpia).

---

## 1. `POST /api/terminal/marcas` — ruta de marcas

Llama `fn_marca_terminal_registrar(p_terminal_id, p_eventos jsonb)` (`service_role`, `SECURITY DEFINER`). Un lote a la vez por terminal
(lock dentro del RPC), confirmación **individual**, idempotente por `evento_id`.

### Request

```json
{
  "terminal_id": "SERIE-DE-LA-TERMINAL",
  "version_software": "1.0.0",
  "eventos": [
    {"evento_id": "6f1c0a52-8f6e-5f0a-9d1e-0b7a3c2d4e10",
     "employee_no": 17,
     "secuencia_local": 4417,
     "momento_dispositivo": "2026-10-06T15:03:00Z",
     "desfase_local": "-06:00",
     "estado_reloj": "sincronizado"}
  ]
}
```

| Campo | Regla del envoltorio (Pydantic → `422` del lote) | Regla por evento (la valida el RPC → rechazo individual) |
|---|---|---|
| `terminal_id` | opcional, ≤ 32; si viene debe igualar la serie de la credencial | — |
| `version_software` | **obligatorio**, 1–16 caracteres; el backend lo **inyecta en cada evento** | — |
| `eventos` | lista de **1 a 200** objetos (`422` si 0 o > 200) | — |
| `evento_id` | — | UUID. **Determinista**: `uuid5(NAMESPACE, nombre)` con `NAMESPACE = uuid5(NAMESPACE_URL, "https://scj.invalid/terminal/evento/v1")` y `nombre = "<serie de la terminal>:<serialNo>"` en la **generación 0** (la de siempre) o `"<serie>:g<gen>:<serialNo>"` en la **generación `gen` ≥ 1**, que sólo sube una persona tras reiniciar o reemplazar la terminal (sus `serialNo` se reutilizan) para no chocar con los ya enviados. El mismo evento físico = el mismo id, también tras reinstalar el Pi. El servidor sólo ve el UUID: no cambia nada de su lado (`puente/src/puente/ingesta.py::evento_id_de`) |
| `employee_no` | — | entero 1–99 999 999 |
| `secuencia_local` | — | entero ≥ 0, propio del Pi, **sólo sobre marcas aceptadas**, nunca baja (persistido) |
| `momento_dispositivo` | — | ISO 8601 con fecha, hora y **zona** (`Z` o `±hh:mm`); 2024-01-01 ≤ t ≤ ahora + 1 año |
| `desfase_local` | — | `^[+-]\d{2}:\d{2}$` (−12:00 … +14:00): la zona del **lugar** donde ocurrió la marca |
| `estado_reloj` | — | `sincronizado` · `deriva` · `sin_sincronizar` |
| `modo_verificacion` | **opcional** | única cadena significativa: **`huella`** (igualdad exacta, sin mayúsculas ni espacios). Cualquier otro valor, tipo o largo se **descarta** (queda `NULL`) antes del RPC; nunca es forma inválida |

- **`modo_verificacion` (95_, 2026-10-09):** campo **opcional** del evento. El puente lo manda **solo** para una marca **`minor 38` cuyo `currentVerifyMode` coincide EXACTAMENTE
  con el valor de huella del firmware real** (`VALOR_VERIFICACION_HUELLA`, hoy **sin confirmar**: a confirmar en la prueba física con TI; mientras tanto el puente no lo manda
  nunca). Es la evidencia de la que el RPC infiere la huella enrolada (alta `esperando_huella` → `activo` con `huella_evidencia = 'inferida'`). El resto de los eventos no lleva
  la clave. El backend lo deja pasar sólo si es la cadena exacta `huella`; no afecta el vocabulario de rechazos ni la idempotencia.
- **Lista blanca, con tipo estricto por campo:** el backend reconstruye cada evento sólo con las 6 claves de la tabla (más `version_software`
  inyectada, y `modo_verificacion` si es exactamente `huella`). Se descartan en silencio `origen`, `requiere_revision`, `persona_id`, `fingerData` y cualquier otra. `employee_no` y
  `secuencia_local` deben ser **enteros estrictos** (ni `bool` ni `float` ni cadena) con |valor| ≤ 2⁶²; los otros cuatro, **cadenas de ≤ 64
  caracteres sin NUL, sin caracteres de control (C0/C1) y codificables en UTF-8** (un `\u0000` haría fallar a Postgres con `22P05` y tumbaría
  el lote; un sustituto suelto no se puede serializar). Un valor que no cumple **se omite** y el RPC rechaza **ese** evento como
  `forma_invalida`, sin tumbar el lote. Un elemento de `eventos` que no es objeto conserva su índice y sale como `forma_invalida`.
- **Un evento malo no tumba el lote:** los errores de forma por evento son rechazos individuales; sólo la estructura del lote es `422`.

### Response `200`

```json
{"momento_recepcion": "2026-10-09T16:00:00.123456+00:00",
 "resultados": [
   {"indice": 0, "evento_id": "…", "estado": "confirmado"},
   {"indice": 1, "evento_id": "…", "estado": "duplicado"},
   {"indice": 2, "evento_id": "…", "estado": "rechazo_definitivo", "codigo": "no_enrolado"},
   {"indice": 3, "evento_id": "…", "estado": "rechazo_transitorio", "codigo": "tope_terminal"}
 ]}
```

- `resultados` trae **exactamente un elemento por evento enviado**, `indice` = posición en `eventos` (0-based), en orden. El backend
  **valida** esa forma (mismo número, índices 0..n−1 sin repetir, vocabulario cerrado); si el RPC devolviera otra cosa → `503`
  «Servicio no disponible; reintenta.» con `ERROR` en el log (nunca se reenvía una respuesta rara al Pi).
- `evento_id` en la respuesta puede ser `null` (evento sin UUID válido, `forma_invalida`): el Pi se guía por `indice`.

### Qué hace el Pi con cada resultado (`SCJ-CDT-01 §IX.2/§IX.6`)

| `estado` | `codigo` (lista cerrada) | Acción del Pi |
|---|---|---|
| `confirmado` | — | Marca **confirmada** en el outbox |
| `duplicado` | — | **Igual que confirmado** |
| `rechazo_transitorio` | `tope_terminal`, `error_interno` | Sigue pendiente; reintenta con espera creciente. Tras **50 intentos o 24 h** → `pendiente_intervencion` |
| `rechazo_definitivo` | `forma_invalida`, `no_enrolado`, `conflicto_evento`, `secuencia_fuera_de_rango` | Sale de reintentos → `pendiente_intervencion`. **Nunca se borra** |
| `rechazo_definitivo` | `secuencia_duplicada` | **Renumera** con `ultima_secuencia_recibida`+1 (se obtiene del **latido**, ya existente) y reenvía con **el mismo `evento_id`** |

El servidor guarda la evidencia de los rechazos definitivos en `tiempo.marca_rechazada` (84_, dentro del RPC) **sin** `persona_id`; el
backend no la reenvía al Pi.

### Errores de lote

| Origen | HTTP |
|---|---|
| Credencial inválida / HTTPS / serie distinta | `401` / `403` / `403` (§0) |
| Terminal inexistente o inactiva en el RPC (`SCJ12/terminal_no_valida`) | `401` (la credencial dejó de valer) |
| `22023/lote_invalido` (defensa en profundidad del RPC) | `422` |
| Cualquier otro `22xxx` | `422` «Los datos enviados no son válidos.» |
| `42501` (grant/policy rota) | `503` + `ERROR` en el log |
| Base/red caídas, `PGRST202/204/205`, `42P01` | `503` (nunca un `200` con 200 transitorios) |

---

## 2. `GET /api/terminal/cola` — trabajo pendiente del Pi

Respuesta `200`:

```json
{"hora_servidor": "2026-10-09T16:00:00+00:00",
 "altas": [
   {"terminal_usuario_id": 77, "employee_no": 1042, "estado": "pendiente_alta",   "huellas_capturadas": 0, "accion": "crear_usuario"},
   {"terminal_usuario_id": 78, "employee_no": 1043, "estado": "esperando_huella", "huellas_capturadas": 0, "accion": "sondear_huellas"},
   {"terminal_usuario_id": 79, "employee_no": 1010, "estado": "pendiente_baja",  "huellas_capturadas": 2, "accion": "borrar_usuario"}
 ]}
```

- Fuente: `fn_terminal_mapa(p_terminal_id)` filtrado **en el backend (en Python, por `accion`; el RPC devuelve todas las altas no-`baja`)** a `pendiente_alta`, `pendiente_baja` y `esperando_huella`, ordenado
  por `employee_no`. Sin paginación (decenas de filas).
- `accion` la calcula el backend (una sola regla): `pendiente_alta → crear_usuario` · `esperando_huella → sondear_huellas` ·
  `pendiente_baja → borrar_usuario`.
- **Sin `persona_id`, sin nombres, sin `persona_activa`.** Una baja por persona suspendida llega como `pendiente_baja` (SCJ-DEC-12 §5).
- El Pi **vuelve a leer la cola** ante un `409` de `/movimientos` (la alta cambió de estado) y no reintenta a ciegas.

## 3. `GET /api/terminal/mapa` — reconciliación

Misma forma y misma fuente, **todas las altas no-`baja`** (incluye `activo`), con `accion: null` para las que no tienen trabajo:

```json
{"hora_servidor": "…", "altas": [
  {"terminal_usuario_id": 80, "employee_no": 1001, "estado": "activo", "huellas_capturadas": 2, "accion": null}]}
```

Sirve para comparar los usuarios que **existen en el aparato** contra lo que el servidor espera y borrar huérfanos / altas hechas a mano
en el menú (T-PI-6). Una alta en `baja` no aparece (el `employee_no` nunca se reutiliza).

---

## 4. `POST /api/terminal/movimientos` — el Pi reporta

Llama `fn_terminal_movimiento_registrar(p_terminal_id, p_terminal_usuario_id, p_tipo, p_huellas, p_detalle)`.

### Request

```json
{"terminal_usuario_id": 77, "tipo": "usuario_creado"}
{"terminal_usuario_id": 77, "tipo": "huella_capturada", "huellas": 2}
{"terminal_usuario_id": 79, "tipo": "baja_confirmada"}
{"terminal_usuario_id": 77, "tipo": "error", "codigo": "usuario_ya_existe", "detalle": "el aparato ya tenía ese employeeNo"}
```

| Campo | Regla |
|---|---|
| `terminal_usuario_id` | entero ≥ 1 (el id de la **alta** que viene de la cola; el Pi no manda `employee_no` aquí) |
| `tipo` | `usuario_creado` · `huella_capturada` · `baja_confirmada` · `error` (cualquier otro: `422`) |
| `huellas` | **obligatorio y 1–10 sólo con `huella_capturada`**; prohibido con los demás tipos (`422`). **Conteo**, nunca plantilla |
| `codigo` | **obligatorio sólo con `error`**: `^[a-z0-9_]{1,40}$` (prohibido con los demás) |
| `detalle` | opcional, sólo con `error`, texto ≤ 2 000 que el backend **sanea** (§ abajo) |

- **Saneo de `detalle`** (antes del RPC; el RPC aplica además `left(…, 500)`): quita caracteres de control y de formato Unicode invisibles,
  quita marcado `<…>`, colapsa espacios y trunca a 500; se guarda **`"<codigo>: <detalle>"`** (≤ 500 en total), el formato que ya separa el
  tablero web. Un `detalle` que contenga `fingerData` o «plantilla» se rechaza con `422` **sin guardar nada**: el contrato del Pi es
  **nunca** mandar cuerpos ISAPI, cabeceras ni datos de otros usuarios ni plantillas (`SCJ-DEC-12 §12`).
- **Términos reservados (el Pi debe usar códigos y mensajes neutros):** el filtro juzga el `detalle` **y** el `codigo`, normalizados (NFKC,
  minúsculas, sin invisibles y también «aplastados» sin separadores), y rechaza con `422` lo que contenga `fingerprint`, `fingerdata`,
  `template`, `plantilla` o `base64`, o una racha de ≥ 64 caracteres base64/hexadecimales. Códigos neutros válidos: `huella_no_capturada`,
  `usuario_ya_existe`, `timeout_terminal`, `sin_respuesta`, `isapi_401`. Un `422` aquí es la red de seguridad, no el camino normal.
- Un texto con sustitutos Unicode sueltos se guarda sin ellos (si no, llegaría a la base como `22P05` y se perdería el reporte).
- El backend **no** acepta `employee_no`, `persona_id` ni `terminal_id` aquí: la alta se resuelve por `(terminal_usuario_id, terminal de
  la credencial)`.

### Response

| `resultado` del RPC | HTTP | Cuerpo |
|---|---|---|
| `registrado` | `200` | `{"resultado": "registrado", "estado": "<nuevo estado de la alta>"}` |
| `ya_aplicado` | `200` | `{"resultado": "ya_aplicado", "estado": "<estado actual>"}` — **igual que éxito** (idempotente) |
| `no_encontrado` (no existe **o es de otra terminal**: no se distingue) | `404` | «La alta no existe.» |
| `limitado` (más de 20 `error` por alta en la última hora) | `429` | «Demasiados errores reportados para esta alta; reintenta más tarde.» + `Retry-After: 300` |

Errores de la base: `SCJ11/transicion_invalida` → `409` «El movimiento no es válido para el estado actual del alta.» (**el Pi relee la
cola**); `22023/huellas_invalidas` → `422`; `SCJ12/terminal_no_valida` → `401`; `42501` → `503`; migración/red → `503`. Sin texto de la base.

### Semántica por tipo (idempotente; el Pi puede repetir sin miedo)

| `tipo` | Estado de origen → destino | Repetido |
|---|---|---|
| `usuario_creado` | `pendiente_alta` → `esperando_huella` | `ya_aplicado` si ya está en `esperando_huella` o `activo` |
| `huella_capturada` | `esperando_huella` → `activo` (con `huellas`) | `ya_aplicado` si `activo` con el mismo conteo |
| `baja_confirmada` | `pendiente_baja` → `baja` | `ya_aplicado` si `baja` (tratar «el usuario no existe en el aparato» como éxito) |
| `error` | no cambia el estado | siempre se inserta (hasta el tope de 20/h por alta) |

---

## 5. Lo que NO hace esta API (límites)

- No hay endpoint para subir plantillas ni huellas; el Pi **nunca** llama `CaptureFingerPrint` ni lee `fingerData`.
- No devuelve `persona_id`, nombres ni estado de la persona; no hay forma de unir un `employee_no` con una persona desde el Pi.
- `GET /cola` y `GET /mapa` son de sólo lectura y se acotan a la terminal de la credencial **dentro de SQL** (`p_terminal_id`).
- El latido (`POST /latido`, existente) es el canal para `ultima_secuencia_recibida` y el estado del aparato; no se repite en `/marcas`.

## 6. Cortes de implementación del backend (cada uno: TDD con mocks de firma real, revisión de `security` y `testing`)

| Corte | Contenido |
|---|---|
| **B1** | `POST /marcas` (lista blanca, validación del lote, mapeo de errores, validación de la respuesta del RPC, 413) |
| **B2** | `GET /cola` + `GET /mapa` |
| **B3** | `POST /movimientos` (saneo de `detalle`, 404/409/429, idempotencia) |

## 7. Residuos aceptados y controles compensatorios (revisión de `security`, 2026-10-09)

- **Enlace Pi↔terminal sin TLS** (HTTP + Digest en claro): se acepta con cable punto a punto o VLAN aislada, IP fija, servicios innecesarios apagados
  en el aparato, firewall en el Pi y contraseña larga. Controles en el puente: sólo eventos de **verificación exitosa**, `serialNo` estrictamente
  creciente (un salto atrás o un duplicado con contenido distinto es anomalía), nunca enviar un `momento_dispositivo` > ahora + 5 min como
  `sincronizado`, y `deriva` si la hora del aparato y la del Pi difieren más del umbral.
- **Llave `scjt_` robada:** permite mandar marcas de esa terminal hasta que se revoque (`SCJ-DEC-12 §1`); cada marca sólo puede ser de un
  `employee_no` enrolado en esa terminal y con topes de tasa en el RPC.
- **Heurística de carga binaria (residuo aceptado):** una carga partida en rachas de < 64 caracteres, o escrita con homógrafos (cirílico/griego
  parecido al latino) o con marcas combinantes, puede esquivar el filtro; es defensa en profundidad, no una garantía. La garantía es el
  contrato del Pi (nunca leer `fingerData`: lista blanca de métodos y rutas ISAPI, CI que falla ante esos términos).
- **Puente:** un `422` de lote significa bug del Pi, no «reintenta igual»: el Pi **biseca** el lote o envía unitario, y el evento que aun solo da
  `422` pasa a `pendiente_intervencion` sin bloquear a los demás. `Retry-After` se acota a 1 s–15 min con jitter.
- **Puente, códigos desconocidos del servidor:** el llamador del almacén (P3) debe **mapear cualquier `codigo` que no esté en la lista cerrada de
  §1** (o que no cumpla `[a-z0-9_]{1,40}`) a un código fijo y neutro (p. ej. `codigo_desconocido`) **antes** de llamar a `pasar_a_intervencion` o
  `registrar_fallo_transitorio`. Si no, el almacén lanza `ErrorAlmacen` y la marca reintenta **sin contador** (el mismo fallo que tuvo
  `Retry-After` NaN): el contador de intentos y el tope de 50 intentos / 24 h sólo avanzan si la llamada se completa. Lo mismo vale para
  `Retry-After` ilegible: se trata como ausente. El tope de 50 intentos / 24 h aplica **sólo a los `rechazo_transitorio` por resultado**. Un fallo de LOTE (red, `5xx`,
  `408/423/425`, `429`, respuesta ilegible) es un **backoff global** del Pi (5 s, 15 s, 1 min, 5 min, tope 15 min, piso de 5 s aunque `Retry-After` diga
  menos) que **no toca intentos ni mueve ninguna marca**; si dura 24 h el Pi **alerta**, no manda las marcas a intervención (un servidor caído
  no es culpa de las marcas). Un `401` pausa 15 min con alerta; un `403` o una redirección **detiene** la subida hasta que una persona la reanude.
  Un `422/413` biseca el lote; las marcas aisladas sólo van a intervención si en el mismo ciclo el servidor aceptó algo, y 3 aisladas seguidas
  (o más del 20 % del ciclo) detienen la subida en vez de vaciar el outbox. El contenido de cada resultado de `/marcas` se juzga por resultado
  (un código fuera del catálogo: definitivo -> `codigo_desconocido`, transitorio -> `error_interno`); sólo la estructura invalida el lote.
