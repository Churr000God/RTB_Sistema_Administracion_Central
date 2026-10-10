# Contrato de la API web — Interruptor de la activación por huella (PROPUESTA v2)

**Estado: PROPUESTA de `backend`, sin implementar y sin commit hasta la luz verde de `orchestrator`.** Fecha: 2026-10-10. **v2:** incorpora las decisiones de `orchestrator`
(Q1–Q4), los 8 cambios C1–C8 y los extras de `security`, y las dos precisiones de `frontend` («activo hasta» y conteo de activaciones).
Fuentes: `db/ddl/97_tiempo_terminal_inferir_huella_interruptor.sql` y `98_tiempo_marca_respeta_interruptor_huella.sql` (ya aplicados; firmas, estados y
`HINT` de abajo se leyeron de ahí), `db/ensayos/DISENO_interruptor_inferir_huella.md` (v4), `CONTRATO_API_TERMINALES_PAQUETE_2.md` (§0, §6, §9) y el patrón de
`backend/app/routers/config_terminales.py`.

**Qué es:** la pantalla/endpoint con que una persona con `terminal_config_edicion` **enciende, renueva y apaga** la «activación por huella» (vía B: el servidor
marca un alta como activa al recibir su primera marca por huella, minor 38) y ve su estado. Encender es un acto humano deliberado: nota, vencimiento de hasta 30
días, consentimiento biométrico **definitivo** publicado y rastro inmutable. **Qué NO es:** no toca `/api/terminal/*` (credencial de terminal) ni decide qué
hace el puente; no define el microcopy ni el modal de nota (los diseña `frontend`).

---

## 0. Convenciones

- **Router nuevo:** `backend/app/routers/interruptor_huella.py`, prefijo `/api/terminales/configuracion/activacion-por-huella` (hermano de `…/variables` y
  `…/consentimiento`, `tags=["terminales"]`). Helper puro de la alarma en `backend/app/interruptor_huella.py`.
- **Clientes (lección de `banco_de_horas.py`, igual que `config_terminales.py`):**
  - **Escritura = cliente del CALLER** (`get_caller_client`, anon + JWT): `fn_terminal_inferir_huella_cambiar` valida **dentro** persona activa +
    `terminal_config_edicion` (RLS/permiso real). El router **nunca** usa `service_role` para escribir ni para llamar esa función (`EXECUTE` es solo `authenticated`).
  - **Estado = `service_role`:** `fn_terminal_inferir_huella_estado()` (`EXECUTE` solo `service_role`). Es insumo, no autorización. También con `service_role`, **solo agregados
    sin identidades**: el conteo de §1 y la comparación de nota de §3.5 (que no se devuelve).
  - **Nombres de personas = cliente del LLAMADOR (RLS), nunca `service_role` (C2):** el nombre del autor se resuelve con las consultas del caller sobre `personas.usuario` →
    `personas.persona`; si la RLS no le deja ver a esa persona (o la consulta falla), el nombre es **`null`** — jamás el uuid ni un nombre obtenido por otra vía.
  - **Historial = cliente del caller** sobre `tiempo.bitacora_config_terminal`.
- **Gates (débil, `requiere_permiso`; la autorización real es la de la base):**

| Operación | Gate débil | Autorización real |
|---|---|---|
| `GET` estado | `terminal_usuario_lectura` **o** `terminal_usuario_edicion` **o** `terminal_config_edicion` | el estado es insumo (sin identidades); el nombre del autor sale solo con el cliente del caller y su RLS |
| `GET` historial (**C1**) | `terminal_config_edicion` **o** `terminal_usuario_edicion` — con `terminal_usuario_lectura` a secas → **403** | policy SELECT de la bitácora (la base la concede a los tres; el backend la **cierra más**, porque el historial lleva notas de texto libre y autores) |
| `POST` encender / renovar / apagar | `terminal_config_edicion` | gate **dentro** de la función (persona activa + permiso, no heredable) |

  **C1:** el ESTADO (activo/apagado/vencido, `hasta`, alarma, conteo) está abierto a los tres permisos de lectura (quien ve Terminales debe saber si las altas se están
  activando solas). `encendido_por_nombre` solo se llena si el llamador tiene `terminal_config_edicion` **o** `terminal_usuario_edicion`; con `terminal_usuario_lectura` a secas
  llega **`null`**. `GET /api/sesion` **no necesita bandera nueva**: la UI usa `puede_editar_config_terminales` (= `terminal_config_edicion`) para los botones.
- **Errores:** mensajes **fijos** en español, sin interpolar valores; el texto de la base nunca llega a la respuesta. Cuerpo `{"detail": "<texto fijo>"}` y, cuando el
  cliente debe decidir por el motivo, un campo estable `"codigo"` (patrón de §6.0 del Paquete 2). Todo `APIError` no reconocido cae al 500 genérico; `PGRST202/204/205` y
  `42P01` → 503 por el handler global.
- **C3 — los 422 de validación NO eco de datos:** este router lleva su **propio manejador de `RequestValidationError`** (registrado en la app y activo solo para rutas bajo el
  prefijo de arriba; el resto de la app conserva el manejador por omisión). Responde `{"detail": "<texto fijo>", "codigo": "<código>"}` **sin** `input`, `ctx`, `loc`, `msg` ni
  texto de Pydantic (la nota es texto libre). El `codigo` se decide por el **nombre del campo** que falló, no por su valor: `nota` → `nota_requerida`; `hasta_fecha`/`hasta_base` →
  `hasta_invalido`; cualquier otro (campo extra, cuerpo no JSON, tipos) → `cuerpo_invalido` («La solicitud no es válida.»). El log no lleva el cuerpo.
- **F1 — `Cache-Control: no-store`:** TODAS las respuestas de este prefijo (estado, historial y los tres POST, incluidos los errores) llevan `Cache-Control: no-store` (y `Pragma: no-cache`), porque
  llevan nombres y notas de texto libre: una línea en el router (dependencia `response.headers[...]`) o un middleware por prefijo; no se confía en el valor por omisión de FastAPI.
- **Logs:** nunca la nota ni el `hasta` enviados; solo SQLSTATE/`HINT`, el nombre de la operación y el id de la petición. Ninguna respuesta ni log contiene la nota del llamador
  salvo el historial de §2 (que es justamente su registro).
- **TDD con mocks** (patrón de `test_config_terminales*.py`), sin base real; contratos RPC↔DDL leyendo `97_*.sql`.

---

## 1. `GET /api/terminales/configuracion/activacion-por-huella` — estado

Gate lectura. Llama `fn_terminal_inferir_huella_estado()` con `service_role` y completa con el nombre del autor (cliente del caller, C1/C2), el conteo de activaciones y los
requisitos.

```json
{
  "activo": true,
  "estado": "encendido",
  "motivo": null,
  "mensaje": null,
  "hasta": "2026-11-03T05:59:59Z",
  "hasta_fecha": "2026-11-02",
  "vencido": false,
  "encendido_por_nombre": "Carlos Ruiz",
  "encendido_en": "2026-10-12T16:03:11Z",
  "altas_activadas_desde_encendido": 7,
  "maximo_dias": 30,
  "fecha_minima": "2026-10-12",
  "fecha_maxima": "2026-11-10",
  "nota_minimo": 10,
  "nota_maximo": 500,
  "requisitos": {"consentimiento_publicado": true, "terminal_activa": true},
  "alarma": {"activa": false, "nivel": null, "codigo": null, "mensaje": null}
}
```

- `estado` (derivado por el backend, para pintar): `encendido` | `apagado` | `vencido` | `inconsistente`. `encendido` ⇔ `activo`; `vencido` ⇔ `motivo == "vencido"`;
  `apagado` ⇔ `motivo == "apagado"`; `inconsistente` ⇔ cualquier otro `motivo` (el interruptor está **apagado** por falla cerrada, pero el dato no es el de un apagado normal).
- `motivo`: el de la base (código estable); `null` si `activo`. `mensaje`: texto fijo del backend (tabla §6.2); `null` si `activo` o `apagado`.
- **«Activo hasta» (frontend, punto a):** el usuario elige una **FECHA**, no un instante. La API la recibe como `hasta_fecha` (`YYYY-MM-DD`, fecha civil en
  **America/Mexico_City**) y el interruptor **vence al final de ese día: 23:59:59 hora de México**. El backend la convierte con `ZoneInfo("America/Mexico_City")` (hoy -06:00
  todo el año) al instante UTC `(hasta_fecha 23:59:59 MX)` y lo pasa como `p_hasta` (la base lo guarda en UTC con `Z`). Se **devuelve de las dos formas**: `hasta` = el instante
  UTC real que guardó la base (para cálculos) y `hasta_fecha` = esa misma fecha civil en México (para mostrar). `null` ambos si está apagado (la base guarda el centinela `1970…`;
  no se expone) o ilegible; con `vencido: true` conservan la fecha vencida.
  - **Una sola función calcula el rango (security 1a):** `rango_de_fechas(ahora) -> (fecha_minima, fecha_maxima)` es compartida por el GET (que la devuelve) y por la validación del POST (que
    **recalcula con su propio reloj, nunca confía en lo que mostró el GET**). Una fecha que el GET ofreció pero que ya queda fuera de rango al llegar el POST (pasó la medianoche o se acercó el tope) →
    **422 `hasta_invalido`** por el router, no un error de la base.
  - **Rango y tope de 30 días contra la hora UTC de la función:** la base exige `p_hasta > now()` y `p_hasta <= now() + 30 días` con SU `now()`. El backend calcula
    `fecha_minima` y `fecha_maxima` (México) con un margen de seguridad de **60 s** para que el reloj del backend no cruce el tope por una carrera:
    `fecha_maxima` = la última fecha cuyo 23:59:59 MX sea `<= now() + 30 días - 60 s`; `fecha_minima` = hoy (MX) si `now() + 60 s < hoy 23:59:59 MX`, si no, mañana. Se devuelven en el
    GET para que el selector de fecha se limite a ese rango. Fuera de rango → **422** `hasta_invalido` sin llamar a la base (que valida de nuevo y es la autoridad). En la práctica
    la fecha máxima es «hoy + 29 o 30 días» según la hora del día.
- `encendido_por_nombre` / `encendido_en`: de la última fila de bitácora de la vigencia actual. **El nombre solo para `terminal_config_edicion` o `terminal_usuario_edicion` (C1) y
  resuelto con el cliente del caller (C2); si no se puede ver a la persona, o la fila trae un autor que no se resuelve, es `null` — nunca el uuid.** No se expone el uuid.
- **Conteo (frontend, punto b) — SÍ, barato y sin identidades:** `altas_activadas_desde_encendido` = número de movimientos `huella_inferida` en
  `tiempo.bitacora_movimiento_terminal_usuario` con `creado_en >= encendido_en` (una sola consulta `count` exacto, `service_role`, sin traer filas, **solo el número**; no se filtra por
  terminal: el interruptor es global). Solo se calcula si `estado == "encendido"` y hay `encendido_en`; en cualquier otro caso es `null`, y también `null` si la consulta falla
  (no tumba el GET). Una **renovación** no reinicia el conteo (cambia el vencimiento, no `encendido_en`).
  **`encendido_en` es el de la vigencia ACTUAL** (security 2c): renovar no lo mueve, pero **apagar y volver a encender SÍ lo reinicia** (y con ello el conteo). El campo es solo un número informativo: la
  pantalla no lo muestra junto a nombres de personas y **la regla de alarma (§5) NO depende de él** (security 2d). Abierto a los tres permisos de lectura.
- `requisitos` (para deshabilitar «Encender» con explicación; **informativo**, la base decide): `consentimiento_publicado` = existe versión vigente con `provisional = false`;
  `terminal_activa` = hay al menos una `tiempo.terminal` activa. Lecturas con `service_role`; si fallan, el campo es `null`. No se expone el texto ni la versión.
- `alarma`: ver §5.
- Falla de lectura de la función (`APIError` o forma inesperada): **503** «El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas.» + `ERROR` en el log.
  **Nunca** se rellena con «apagado» una respuesta ilegible. (Distinto del RPC de marcas, que sí cae a apagado.)

## 2. `GET …/activacion-por-huella/historial?limite=50`

**Gate (C1):** `terminal_config_edicion` o `terminal_usuario_edicion`; con `terminal_usuario_lectura` a secas → **403** («No tienes permiso para esta acción.»). Cliente del caller
sobre `tiempo.bitacora_config_terminal` (orden `id desc`, `limite` 1–100, por omisión 50).

```json
{"items": [{"id": 12, "creado_en": "2026-10-12T16:03:11Z", "clave": "terminal_inferir_huella_activa", "operacion": "UPDATE",
            "valor_anterior": "0", "valor_nuevo": "1", "nota": "Primer día de puesta en marcha…", "autor_nombre": "Carlos Ruiz", "via_funcion": true}]}
```

- Expone solo: `id`, `creado_en`, `clave`, `operacion`, `valor_anterior`, `valor_nuevo`, `nota`, `autor_nombre` (de `registrado_por`; cliente del caller, `null` si no se resuelve), `via_funcion`.
  **No** `rol_jwt`, `usuario_sesion`, `txid` ni `registrado_por`.
- **Claves y operaciones (confirmado para `frontend`):** `clave` es exactamente `terminal_inferir_huella_activa` o `terminal_inferir_huella_hasta` (el CHECK `ck_bitacora_config_terminal_clave` de 97_ no admite otra) y
  `operacion` es exactamente `INSERT` | `UPDATE` | `UPDATE_VIGENCIA` | `DELETE` (CHECK `ck_bitacora_config_terminal_operacion`); `via_funcion` es booleano no nulo. Un encendido normal deja dos filas por
  transacción (una de cada clave). `valor_anterior`/`valor_nuevo` son los valores crudos de la clave (`"0"`/`"1"` para la activa; el instante ISO UTC o el centinela `1970-01-01T00:00:00Z` para `hasta`) y pueden ser
  `null` en INSERT/DELETE. `UPDATE_VIGENCIA` (cierre o reapertura de una vigencia) no cambia el valor.
- `via_funcion: false` es la evidencia de un cambio hecho fuera de la función dedicada: el frontend lo marca (es el rastro de la alarma de §5).

## 3. Encender, renovar y apagar

Los tres llaman `fn_terminal_inferir_huella_cambiar(p_activa, p_nota, p_hasta)` con el **cliente del caller**:
`db.postgrest.schema("tiempo").rpc("fn_terminal_inferir_huella_cambiar", {"p_activa": …, "p_nota": …, "p_hasta": …}).execute()`.

### 3.1 `POST …/activacion-por-huella/encender`
Cuerpo cerrado (`extra="forbid"`): `{"nota": "…", "hasta_fecha": "2026-11-02"}`.
- `nota`: 10–500 caracteres tras `strip()` (validación previa para un 422 legible; **la base valida de nuevo y sanea invisibles**: es la autoridad).
- `hasta_fecha`: fecha ISO (`YYYY-MM-DD`) dentro de `[fecha_minima, fecha_maxima]` del GET. `p_hasta` = esa fecha a las 23:59:59 America/Mexico_City, en ISO con zona.
- Chequeo previo con `service_role`: si el estado ya es `activo` → **409** `codigo: "ya_esta_encendido"` («Ya está encendido; usa Renovar para cambiar el vencimiento.») **con el `estado` actual**
  como campo hermano (misma forma que §1) para refrescar la pantalla. (Carrera: la base es idempotente y solo cambia el vencimiento; el chequeo es cortesía, no seguridad.)

### 3.2 `POST …/activacion-por-huella/renovar`
Cuerpo: `{"nota": "…", "hasta_fecha": "…", "hasta_base": "2026-11-03T05:59:59Z"}`. Misma llamada con `p_activa = true` (la base cambia solo el vencimiento).
- **`hasta_base` (C5)** = el `hasta` (instante) que el cliente tenía en pantalla. Se compara por **INSTANTE**: se normaliza a UTC y se trunca al segundo antes de comparar con el `hasta` vigente
  (no por texto: `…Z` y `…-06:00` del mismo instante coinciden). No parseable o sin zona → **422** `hasta_invalido`. `estado_desactualizado` se decide con el estado leído con
  `service_role` justo antes de la llamada; es un **chequeo de cortesía** (la base sigue siendo idempotente y no compara).
- Si el estado no es `activo` → **409** `no_esta_encendido`; si `hasta_base` no coincide → **409** `estado_desactualizado` con el `estado` actual como campo hermano.
- **Nota nueva obligatoria (C6):** además de la regla de la base, el backend rechaza una nota **idéntica a la última nota registrada del interruptor** (comparación tras `strip`, espacios
  colapsados y `casefold`) con **422** `nota_repetida` («Escribe un motivo nuevo para la renovación.»). La "última nota" se lee de `bitacora_config_terminal` con `service_role` **solo para
  comparar** (el valor no se devuelve ni se loguea).

### 3.3 `POST …/activacion-por-huella/apagar`
Cuerpo: `{"nota": "…"}` (opcional, ≤ 500; la base no la exige al apagar, queda en la bitácora si viene). `p_activa = false`, `p_hasta = null`. Apagar **siempre** se puede (aunque ya esté apagado:
`resultado: "sin_cambio"`); no hace falta consentimiento ni terminal activa.

### 3.4 Respuesta de los tres (200)
```json
{"resultado": "actualizada", "estado": { …misma forma que GET §1… }}
```
`resultado` ∈ `actualizada` | `sin_cambio`. `estado` se arma con el `estado` que **devuelve la propia función** (misma transacción) + nombre (cliente del caller, C1/C2), conteo y requisitos como en §1.
Forma inesperada (sin `resultado` válido o sin `estado` dict) → **503** `MENSAJE_RESPUESTA_INESPERADA` + `ERROR` en el log.

### 3.5 Concurrencia y reintento (C4)
SQLSTATE `55P03` (lock no disponible), `40P01` (deadlock) y `40001` (fallo de serialización) → **503** `codigo: "reintentar"`, «El cambio no se pudo aplicar por una operación concurrente; vuelve a
intentarlo.» El log lleva **solo el SQLSTATE**. (La función toma un advisory lock por transacción: dos cambios simultáneos se serializan; el reintento es seguro porque la base es idempotente.)

## 4. Qué NO hace el router
- No escribe `tiempo.parametro` ni la bitácora (ni con `service_role`). No llama `fn_terminal_config_actualizar` con las claves del interruptor (la base las rechaza con `clave_no_editable`).
- No guarda ni loguea la nota. No cachea el estado: cada GET lee la función.

## 5. La ALARMA

Fuente única de verdad: **`alarma_de(estado: object) -> dict`**, **función pura** sobre el JSON de `fn_terminal_inferir_huella_estado()` (sin I/O), que usan el GET, la respuesta de los POST y el tablero.

| Condición | `nivel` | `codigo` | Qué significa |
|---|---|---|---|
| `motivo == "sin_respaldo_de_la_funcion"` | `atender` | `sin_respaldo_de_la_funcion` | alguien escribió el parámetro directo (service_role/psql): quedó **apagado** a la fuerza |
| `activo` y `ultimo_cambio_via_funcion` es `false` | `atender` | `cambio_fuera_de_la_funcion` | encendido pero el último cambio no lo hizo la función dedicada (R1 lo apaga; defensa en profundidad) |
| `activo` y `sin_registro` es `true` | `atender` | `sin_registro` | encendido sin fila de bitácora de esa vigencia |
| `motivo` ∈ {`vigencias_inconsistentes`, `valor_invalido`, `hasta_ilegible`, `hasta_excede_tope`, `error`} (**Q1: sí entra**) | `revisar` | el `motivo` | apagado por falla cerrada con el dato corrupto: falla cerrada VISIBLE |
| **forma ilegible** (no es dict, falta `activo`/`motivo`, tipos que no son los esperados) | `revisar` | `estado_ilegible` | el estado no se puede interpretar: nunca se trata como «sin alarma» |
| cualquier otro (`apagado`, `vencido`, `activo` sano) | — | — | sin alarma |

Forma: `{"activa": bool, "nivel": "atender"|"revisar"|null, "codigo": str|null, "mensaje": str|null}`. **C7:** el helper no depende del motivo exacto fuera de esta tabla (un `motivo`
desconocido que no sea `apagado`/`vencido` ni el de una fila → `revisar` / `estado_ilegible`, nunca silencio); `mensaje` = texto fijo (§6.2) que **remite a Sistemas** y no lleva valores.

**Tablero de anomalías (`GET /api/terminales/{id}/anomalias`, Paquete 2 §9) — Q2: categoría 14 `interruptor_huella` GLOBAL:** una sola tarjeta («Interruptor de la activación por huella»),
más el banner en la propia pantalla del interruptor. `estado: "con_hallazgos"` / `nivel` del helper / `total: 1` y un solo ejemplo `{"codigo": …, "mensaje": …}` (**sin nombres, sin nota, sin fechas
de personas**) cuando hay alarma; `sin_hallazgos` si no; **`error` si la lectura falla o el estado es ilegible — nunca `sin_hallazgos`**. Reglas (C7):
- **No exige `marca_lectura`** (no cruza marcas), pero sí el **gate del tablero** (lectura de Terminales).
- Es global: se repite igual en el tablero de cada terminal pero, **en los agregados del tablero, cuenta como UNA alarma global**, no N por terminal.
- Lleva `nota` fija: «Es un ajuste global del sistema, no de esta terminal.» Lectura con `service_role`, aislada como las demás tarjetas (si falla, las otras siguen).

## 6. Mapeo de errores (módulo `errores.py`, nuevo `traducir_error_interruptor_huella`)

Mismo patrón que `traducir_error_terminal_web` (devuelve `HTTPException|None`; el `manejar_…` es `NoReturn`). Se decide por el **`HINT`/SQLSTATE** estable, nunca por el texto.

### 6.1 Errores
| Error de la base / del router | HTTP | `codigo` | `detail` fijo |
|---|---|---|---|
| `42501` `sin_permiso` | 403 | — | «No tienes permiso para cambiar el interruptor de la activación por huella.» |
| `42501` sin hint | 403 + `ERROR` en el log | — | ídem |
| `22023` `nota_requerida` | 422 | `nota_requerida` | «La nota debe tener entre 10 y 500 caracteres.» |
| `22023` `hasta_invalido` | 422 | `hasta_invalido` | «El vencimiento debe ser una fecha futura de a lo más 30 días.» |
| `22023` `terminal_no_activa` | 409 | `terminal_no_activa` | «No hay ninguna terminal activa; no se puede encender.» |
| `22023` `vigencias_inconsistentes` | 409 | `vigencias_inconsistentes` | «El ajuste está en un estado inconsistente; avisa a Sistemas.» + `ERROR` en el log |
| `SCJ16` `sin_consentimiento_vigente` | 409 | `sin_consentimiento_vigente` | «Falta publicar el texto de consentimiento biométrico definitivo; mientras solo exista el provisional no se puede encender.» **No incluye versión ni contenido del texto.** (Hoy solo existe el provisional: encender dará este 409 hasta que se publique uno.) |
| `22023` `parametros_invalidos` | **500 + `ERROR`** | — | genérico. **No es 422**: el esquema cerrado lo impide, así que no es culpa del usuario; si ocurre es un bug. |
| `22023` `clave_no_editable` | 503 + `ERROR` | — | «El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas.» (inalcanzable por esta ruta: indicaría un bug) |
| `SCJ02` | 503 + `ERROR` | — | «Servicio no disponible. Avisa a Sistemas.» (falta la siembra de 97_) |
| `55P03`, `40P01`, `40001` (**C4**) | 503 | `reintentar` | «El cambio no se pudo aplicar por una operación concurrente; vuelve a intentarlo.» (log solo SQLSTATE) |
| `PGRST202/204/205`, `42P01` | 503 | — | handler global |
| cualquier otro | 500 genérico | — | — |
| router: `ya_esta_encendido` / `no_esta_encendido` / `estado_desactualizado` | 409 | el mismo | textos de §3; `ya_esta_encendido` y `estado_desactualizado` llevan `estado` hermano |
| router: `nota_repetida` (C6) | 422 | `nota_repetida` | «Escribe un motivo nuevo para la renovación.» |
| router: validación de cuerpo (C3) | 422 | `nota_requerida` / `hasta_invalido` / `cuerpo_invalido` | textos fijos; **sin eco** del cuerpo |

### 6.2 Textos fijos de `motivo` / alarma
| `motivo` / `codigo` | `mensaje` |
|---|---|
| `apagado` | `null` |
| `vencido` | «El vencimiento ya pasó; el interruptor está apagado.» |
| `sin_respaldo_de_la_funcion` | «Se detectó un cambio hecho fuera de esta pantalla; el interruptor quedó apagado. Avisa a Sistemas.» |
| `cambio_fuera_de_la_funcion`, `sin_registro` | «El interruptor está encendido pero su último cambio no quedó registrado como debe. Avisa a Sistemas.» |
| `vigencias_inconsistentes` | «El ajuste está en un estado inconsistente; el interruptor quedó apagado. Avisa a Sistemas.» |
| `valor_invalido`, `hasta_ilegible`, `hasta_excede_tope` | «El ajuste tiene un valor no válido; el interruptor quedó apagado. Avisa a Sistemas.» |
| `error`, `estado_ilegible` | «No se pudo leer el ajuste; el interruptor quedó apagado. Avisa a Sistemas.» |

## 7. Relación con `/api/terminal/marcas` (lado del Pi, fuera de este contrato) — C8
La ruta de marcas del Pi lee **el mismo** estado efectivo (`fn_terminal_inferir_huella_estado()`, `service_role`) y envía `modo_verificacion = 'huella'` al RPC **solo si `activo`**; ante cualquier
error o forma ilegible → apagado (falla cerrado). **Prohibido cualquier caché del estado en esa ruta** (se lee por petición; la base lo revalida otra vez por lote en 98_). La ruta **no loguea el
`motivo` con valores** (a lo más el SQLSTATE o el nombre del motivo fijo). Es un corte aparte del backend; este contrato solo fija que ambos usan la misma lectura.

## 8. Pruebas esperadas (TDD con mocks, sin base real)

Archivo `backend/tests/test_interruptor_huella.py` (+ ampliación de `test_anomalias_terminal*.py` y una prueba de la ruta de marcas):

1. **Mock de `rpc` con la firma de postgrest-py**: `db.postgrest.schema("tiempo").rpc(nombre, params).execute().data`; un fake que registra `(schema, nombre, params)` y **qué cliente** lo llamó.
2. **El router no usa `service_role` para escribir:** con `get_service_client` sustituido por un cliente que **falla la prueba** si alguien llama `.rpc("fn_terminal_inferir_huella_cambiar", …)` o `.table("parametro"|"bitacora_config_terminal").insert/update/delete/upsert`; encender/renovar/apagar pasan con ese fake. A la inversa: el estado se lee con el cliente de servicio.
3. **Parámetros exactos:** encender → `{"p_activa": True, "p_nota": …, "p_hasta": <ISO con zona = hasta_fecha 23:59:59 America/Mexico_City>}`; apagar → `{"p_activa": False, "p_nota": <nota|None>, "p_hasta": None}`.
4. **«Activo hasta»:** `rango_de_fechas` única (el GET y el POST la usan; el POST recalcula con su reloj: fecha buena en el GET pero fuera de rango en el POST = 422 `hasta_invalido` sin llamar al RPC); conversión fecha→instante (`2026-11-02` → `2026-11-03T05:59:59Z`); `fecha_minima`/`fecha_maxima` con reloj fijo (incluida la hora de borde cercana a 23:59 y la del tope de 30 días con margen de 60 s); fecha fuera de rango → 422 `hasta_invalido` **sin** llamar al RPC; `hasta`/`hasta_fecha` del GET coherentes y `null` al estar apagado (centinela 1970 no expuesto).
5. **Gates (C1):** sin sesión 401; con solo `terminal_usuario_lectura`: GET estado 200 con `encendido_por_nombre: null`, **`/historial` 403**, POST 403; con `terminal_usuario_edicion`: estado con nombre e historial 200, POST 403; con `terminal_config_edicion`: todo; un 42501 de la base → 403.
6. **Nombres (C2):** se resuelven con el cliente del **caller** (el fake de `service_role` falla si se usa para `personas`); si la RLS no deja ver a la persona → `null`; **«`encendido_por` existe pero la persona no se resuelve ⇒ nombre `null` y NO el uuid»**; el uuid no aparece en ninguna respuesta.
7. **Validación sin eco (C3):** nota de 9 y de 501 caracteres, campo extra, `hasta_fecha` mal formada, `hasta_base` sin zona: el cuerpo de la respuesta es exactamente `{"detail","codigo"}` fijos y **no contiene** la nota ni el `hasta` enviados (comparación de subcadena sobre el JSON de respuesta); el mismo test sobre otra ruta de la app comprueba que el manejador por omisión NO cambió.
8. **Mapeo de errores:** una prueba por fila de §6.1 (hint + SQLSTATE → status, `codigo`, `detail` exactos), incluidos `55P03`/`40P01`/`40001` → 503 `reintentar` (log solo SQLSTATE) y `parametros_invalidos` → **500**; el texto de la base nunca aparece en la respuesta; el 409 de consentimiento no incluye versión ni contenido.
9. **Concurrencia y nota (C5/C6):** encender con estado activo → 409 `ya_esta_encendido` **con `estado`**; renovar sin estar encendido → 409; `hasta_base` por instante (`…Z` vs `…-06:00` del mismo instante coinciden; distinto instante → 409 `estado_desactualizado` con `estado`; no parseable → 422); renovar con la misma nota (otra capitalización/espacios) → 422 `nota_repetida`, y con nota nueva pasa.
10. **Estado:** una prueba por `motivo` (derivación de `estado`, `mensaje`, `vencido` conserva la fecha); `altas_activadas_desde_encendido` es solo un entero (consulta `count`, sin filas), `null` si no está encendido o si la consulta falla sin tumbar el GET; `requisitos` `null` si su lectura falla; función que falla o devuelve forma inesperada → 503 (no «apagado»).
11. **Alarma (C7):** tabla de verdad de `alarma_de` (pura; sin I/O) con las filas de §5 + sano + `motivo` desconocido + **`error` y forma ilegible ⇒ `revisar`/`estado_ilegible`**; en el GET, en la respuesta de los POST y en la tarjeta 14 (`con_hallazgos`/`sin_hallazgos`/`error` — la forma ilegible da `error`, nunca `sin_hallazgos`; no exige `marca_lectura` pero sí el gate del tablero; el ejemplo no lleva nombres ni nota; en los agregados cuenta UNA alarma global con 2+ terminales; aislada: si falla, las otras tarjetas siguen).
12. **Historial:** solo las columnas permitidas (sin `rol_jwt`, `usuario_sesion`, `txid`, `registrado_por`); `limite` acotado; cliente del caller; `autor_nombre` `null` si no se resuelve.
13. **Privacidad de logs/respuestas:** ninguna respuesta ni línea de log (`caplog` en todos los niveles) contiene la nota del llamador, salvo el historial; los `ERROR` llevan solo SQLSTATE/HINT.
14. **Ruta de marcas (C8):** sin caché del estado (dos peticiones seguidas con estados distintos usan el estado nuevo); ilegible/error → apagado; no se loguea el motivo con valores.
14 bis. **`Cache-Control: no-store` (F1):** los GET (estado, historial) y los tres POST, en éxito y en error (403/409/422/503), llevan `Cache-Control: no-store`.
15. **Contrato RPC↔DDL:** un test que lee `db/ddl/97_*.sql` y comprueba la firma `fn_terminal_inferir_huella_cambiar(boolean, text, timestamptz)`, los `HINT` de §6.1 y las claves del JSON de `fn_terminal_inferir_huella_estado()` (`activo, vencido, motivo, valor, hasta, encendido_por, encendido_en, ultimo_cambio_via_funcion, sin_registro`).
16. **Precondición de esquema:** agregar las dos funciones a `app/precondiciones.py` (si falta alguna, el arranque falla como con 94_).

## 9. Decisiones registradas
- **Q1 sí:** la alarma `revisar` por falla cerrada (y por estado ilegible) entra. **Q2:** categoría 14 `interruptor_huella` GLOBAL (una tarjeta, una alarma en agregados) + banner en la pantalla del interruptor.
- **Q3:** renovar exige nota nueva, sin pre-llenar, y el backend rechaza la repetida (`nota_repetida`). **Q4:** historial en esta entrega, solo columnas seguras, sin uuid, solo para `terminal_config_edicion`/`terminal_usuario_edicion`.
- **Orden de implementación (cuando haya luz verde, un commit local por parte):** 1) router + lectura del estado (+ manejador de validación, `errores.py`, precondición); 2) escrituras (encender/renovar/apagar); 3) alarma y tarjeta 14 del tablero; 4) historial.
