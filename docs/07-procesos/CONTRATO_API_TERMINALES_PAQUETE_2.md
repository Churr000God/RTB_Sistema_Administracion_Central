# Contrato de la API web — Terminales, Paquete 2 (PROPUESTA)

**Estado: PROPUESTA de `backend`, sin implementar y sin aprobar.** Fecha: 2026-10-08.
Fuentes: `SCJ-DEC-12 V2.0` §4–§6, `SCJ-PRO-15 V1.1` §VI, `PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md` (T-BE-4 a T-BE-8),
`diseno_paginas/tiempo_terminales_enrolamiento/` (01–11 + README), y los borradores de `db/ddl/88_*.sql` y `89_*.sql`
(sin aplicar al momento de escribir esto; los nombres y firmas de abajo se leyeron de esos archivos).

**Qué NO es:** no define el lado del Pi (`/api/terminal/*`, cortes 2–3 de `SCJ-DEC-12`), ni pantallas.

---

## 0. Convenciones transversales

- **Prefijo y router:** `backend/app/routers/terminales.py` (`/api/terminales`), `routers/consentimiento_terminales.py`
  y `routers/config_terminales.py` si crece (todos bajo `/api/terminales/configuracion/…`), más un `GET
  /api/personas/{persona_id}/terminales` (en `routers/personas.py` o `routers/terminales.py`, ver §3.6). Sin tocar
  `/api/terminal/*` (credencial de terminal).
- **Dos clientes (lección de `banco_de_horas.py`):**
  - **Cliente del caller** (`get_caller_client`, anon + JWT): toda **escritura** y toda **lectura de tablas con RLS
    por permiso** (`tiempo.terminal`, `terminal_usuario`, bitácora, `terminal_consentimiento`). La RLS es la
    autorización real; `requiere_permiso(...)` sólo da un 403 legible.
  - **`service_role`:** sólo **lecturas de insumo** que el caller no puede hacer y que no son autorización:
    `tiempo.parametro` (deny-all), `tiempo.terminal_credencial` y `tiempo.marca`/`tiempo.marca_rechazada` para el tablero,
    y `fn_terminal_config_valor` (EXECUTE sólo `service_role`). Siempre filtradas por ids ya validados y por
    `terminal_id` en código (M2: nunca devolver datos de otra terminal).
- **Errores:** mensajes **fijos**, el texto de la base nunca llega a la respuesta; todo `APIError` no reconocido cae
  al 500 genérico. Los cuerpos de error siguen siendo `{"detail": "<texto>"}`; los 409/422 que necesitan datos
  (`consentimiento_vigente`, `no_elegibles`) agregan **un campo hermano** (ver §6). Un `42501` sin hint siempre deja
  `ERROR` en el log.
- **Paginación/orden:** sólo donde el volumen lo justifica (la terminal tiene decenas de altas); el contrato no abre
  listados sin tope: `limite` ≤ 200.
- **Compatibilidad:** campos nuevos opcionales; ningún campo existente de otros routers cambia de significado.
- **TDD con mocks por nombre de tabla** (patrón de `test_dia_cerrado_datos_ui.py`), contratos RPC↔DDL leyendo
  `db/ddl/88_*.sql`/`89_*.sql`, nunca contra la base real.

### 0.1 Gates (permisos)

| Operación | Gate débil (`requiere_permiso`) | Autorización real |
|---|---|---|
| Ver terminales, altas, historial, anomalías, consentimiento, variables | `terminal_usuario_lectura` o `terminal_usuario_edicion` (**o** `terminal_config_edicion`, ver §7) | RLS de cada tabla (`fn_caller_tiene_permiso`) |
| Asignar, baja/cancelar, reconsentir | `terminal_usuario_edicion` | policy `bitacora_terminal_usuario_insert_web` |
| Publicar texto, editar variables, simular caducidad | `terminal_config_edicion` | gate **dentro** de cada RPC (persona activa + permiso) |

`terminal_usuario_lectura` es heredable; `terminal_usuario_edicion` y `terminal_config_edicion` **no**.

---

## 1. `GET /api/terminales`

Lista de terminales con el estado de su puente. Cliente del caller (RLS de `tiempo.terminal`). Refresco del front: 60 s.

```json
[
  {
    "id": 1,
    "serie": "…",                      // tiempo.terminal.terminal_id (varchar); NO el id interno
    "nombre": "Entrada principal",
    "modelo": "DS-K1A8503EF-B",
    "activa": true,
    "estado_contacto": "en_linea",     // en_linea | sin_contacto | nunca | inactiva
    "ultimo_contacto_en": "2026-10-08T15:00:00Z",
    "segundos_sin_contacto": 40,       // null si nunca
    "terminal_alcanzable": true,       // null si el Pi nunca lo reportó
    "reloj_desfase_seg": 2,            // terminal − servidor; null si no se sabe
    "version_pi": "1.4.0",
    "marcas_pendientes": 0
  }
]
```

- `estado_contacto` se **calcula al leer**: `inactiva` (activa=false) > `nunca` (sin `ultimo_contacto_en`) >
  `sin_contacto` (`segundos_sin_contacto` ≥ umbral) > `en_linea`. Umbral: variable de entorno
  `TERMINAL_UMBRAL_SIN_CONTACTO_SEG` (**nueva** en `Settings`, defecto 300; `SCJ-DEC-12 Q5`: infraestructura, no
  `tiempo.parametro`). El frontend sólo pinta el nivel.
- No expone `id` de credencial, hash ni IP. Orden: `nombre`.
- `GET /api/terminales/{id}` devuelve el mismo objeto (404 si no existe o no es visible).
- Errores: 403 (gate), 404.

---

## 2. Altas (usuarios) de una terminal

### 2.1 `GET /api/terminales/{id}/usuarios`

Filtros: `estado` (uno de los 5), `persona_id` (UUID), `desde` (fecha ISO sobre `creado_en`),
`reconsentimiento` (`pendiente` | `al_corriente`), `limite` (1–200, def. 100), `desplazamiento`. Orden: `creado_en` desc.
Cliente del caller (+ lectura de insumo de la caducidad, abajo).

```json
{
  "total": 8,
  "resumen": {
    "por_estado": {"pendiente_alta": 1, "esperando_huella": 2, "activo": 12, "pendiente_baja": 1, "baja": 1},
    "reconsentimiento_pendiente": 14
  },
  "altas": [
    {
      "id": 77,                          // tiempo.terminal_usuario.id
      "terminal_id": 1,
      "employee_no": 1042,
      "persona_id": "uuid",
      "persona_nombre": "Ana Torres",    // el aparato sólo conoce employee_no
      "estado": "esperando_huella",
      "huellas_capturadas": 0,
      "creado_en": "…",                  // asignación
      "actualizado_en": "…",
      "usuario_creado_en": "…" ,         // null mientras sea pendiente_alta
      "caduca_en": "…",                  // ver nota; null salvo estado=esperando_huella
      "error_codigo": "usuario_ya_existe",   // null si no hay error
      "error_detalle": "…",                  // saneado (≤500, texto plano); null si no hay error
      "consentimiento": {"id": 3, "version": 3, "provisional": false},   // la que CONFIRMÓ esta alta
      "consentimiento_vigente_id": 4,
      "reconsentimiento_pendiente": true,
      "es_propia": false,                // la alta es de la persona del llamador (C6: la UI deshabilita su casilla)
      "reconsentimiento_elegible": true, // false si no se puede reconsentir ahora (ver razón); C6
      "reconsentimiento_razon": null,    // null | "es_propia" | "ya_al_corriente" | "en_baja" (lista cerrada)
      "accion_disponible": "cancelar_alta" // cancelar_alta | dar_de_baja | null
    }
  ]
}
```

**Reglas y decisiones del contrato:**
- **`caduca_en` (obligatorio en el esquema, siempre presente):** para `esperando_huella` =
  `usuario_creado_en + terminal_caducidad_alta_horas`; `null` en cualquier otro estado (sólo esas caducan). Se calcula
  en el servidor con la variable vigente (`fn_terminal_config_valor`, `service_role`; si falla, defecto 24) para que
  el cliente **no hardcodee 24 h** y siga válido cuando la variable cambie. `usuario_creado_en` sale del movimiento
  `usuario_creado` de la **bitácora** (no de `actualizado_en`, que también mueve un `error`; `SCJ-DEC-12 §12.7`).
  *Nota:* es la hora nominal; la baja efectiva ocurre en la siguiente corrida del job (cada ~10 min, tope 50).
- **`error_codigo` / `error_detalle`:** el Pi guarda `"<codigo>: <detalle>"` en `error_detalle` (`SCJ-DEC-12 §3`); el
  servidor lo separa en el primer `": "` (código ≤ 40, `[a-z0-9_]`; si no cumple, `error_codigo` = null y todo va a
  `error_detalle`). Ambos como **texto plano** (el frontend nunca lo interpreta como HTML).
- **`accion_disponible`:** regla en un solo lugar: `pendiente_alta`/`esperando_huella` → `cancelar_alta`; `activo` →
  `dar_de_baja`; `pendiente_baja`/`baja` → `null`. (La UI además oculta la acción sin `terminal_usuario_edicion`.)
- **`reconsentimiento_pendiente`:** definición **única** = `fn_terminal_reconsentimiento_pendiente_ids()` (INVOKER, 88_).
  Filtro `reconsentimiento=pendiente|al_corriente` se aplica con esa lista de ids. *Límite aceptado:* la lista se pasa como
  `in_` — correcto para decenas/cientos de altas; si algún día hay miles, se cambia a una función SQL con la terminal.
- **`resumen`** se calcula sobre **todas** las altas de la terminal (no sólo la página); `resumen.reconsentimiento_pendiente`
  = las pendientes de **esa** terminal.
- **Campos de C6 por alta:** `es_propia` (la alta es de quien llama), `reconsentimiento_elegible` y `reconsentimiento_razon`
  (`null` | `en_baja` | `es_propia` | `ya_al_corriente`; prioridad en_baja > es_propia > ya_al_corriente; el administrador
  genérico nunca es «propia»). Filtro `reconsentimiento=pendiente|al_corriente` y contador usan la misma función de la base.
- **Límite aceptado de `fn_terminal_reconsentimiento_pendiente_ids`:** PostgREST topa un `SETOF` a 1000 filas; con más de 1000
  altas pendientes el contador/bandera subestimaría (con una terminal de decenas de altas no ocurre). Si el volumen crece,
  pasar a una función SQL con la terminal como parámetro.
- **`usuario_creado_en` y `consentimiento`** salen de las columnas de 88_ (`terminal_usuario.usuario_creado_en`,
  `consentimiento_id`), no de consultas a la bitácora.
- **Aislamiento:** siempre `.eq("terminal_id", id)`; un `{id}` inexistente o no visible → 404.
- Sin nada biométrico: sólo `huellas_capturadas` (conteo).
- **Depende de 88_** (columna `consentimiento_id`, función de pendientes). Antes de 88_ el endpoint no se puede
  desplegar tal cual (ver §11).

### 2.2 `GET /api/terminales/{id}/reconsentimientos-pendientes`

`{"total": 14, "ids": [77, 81, …], "hay_mas": false}` — los ids de **todas** las pendientes de esa terminal (tope 200;
`hay_mas` si total > 200). Alimenta «Seleccionar las N pendientes» (que no puede depender de la página). Gate lectura.

### 2.3 `GET /api/terminales/{id}/personas-asignables?busqueda=&limite=`

```json
[{"persona_id": "uuid", "nombre": "Ana Torres", "puesto": "Encargado de bodega", "area": "Logística"}]
```
personas `activo` **sin alta vigente** (`estado <> 'baja'`) en esa
terminal; `busqueda` (texto libre sobre nombre/apellidos, ≥ 2 caracteres), `limite` ≤ 50, orden alfabético. **`puesto` y `area` (nuevo, pedido de frontend para distinguir homónimos):** el nombre del puesto (`personas.puesto.nombre_puesto`) y del área (`personas.area.nombre_area`, vía `departamento`) de la asignación **vigente** (`personas.asignacion.vigente_hasta IS NULL`); **ambos `null` si no hay asignación vigente**. Si hubiera varias vigentes (la base permite una por puesto), se toma la de `vigente_desde` más reciente. Se resuelven con el cliente del caller en 3 consultas por lote de personas (asignaciones, puestos/departamentos, áreas), no una por persona, sobre las ≤50 personas devueltas. Respuesta a
la pregunta 7 del README: **lo filtra el backend** (el cliente no tiene todas las altas ni la lista completa de
personas). Gate `terminal_usuario_edicion`. No incluye datos de identidad más allá de nombre, puesto y área (lo que el módulo Personas y Estructura ya exponen a las cuentas activas; no se agrega superficie). Un test cubre persona sin asignación (`puesto: null, area: null`), con varias vigentes (gana la más reciente) y homónimos con puestos distintos.

### 2.4 `POST /api/terminales/{id}/usuarios` — asignar

Cuerpo: `{"persona_id": "uuid", "consentimiento_id": 4}`. **201** con la alta creada (mismo objeto de 2.1) y
`{"consentimiento": {"id","version","provisional"}}` ya incluido en ella.

Flujo en el servidor, en este orden:
1. **Auto-asignación:** si `persona_id` == persona del caller (`resolver_persona_id`) y el caller **no** ocupa el puesto
   administrador genérico (`permisos.es_administrador_generico`, nuevo helper) → **422**
   `"No puedes asignarte a ti mismo a una terminal. Sólo el puesto administrador puede hacerlo."` (texto fijo).
2. **Texto vigente:** lee la versión vigente (la de mayor `version`). Si `consentimiento_id` no es la vigente →
   **409** `{"detail": "El texto de consentimiento cambió; vuelve a leerlo.", "consentimiento_vigente": {…}}`
   (siempre, sin excepción; estructura en §6.1). Evita depender sólo del trigger y permite devolver el texto.
3. `INSERT` en la bitácora con el **cliente del caller**: `tipo_movimiento='asignado'`, `terminal_id`, `persona_id`,
   `terminal_usuario_id` y `employee_no` NULL (los asigna el trigger), `origen='web'`,
   `registrado_por = auth.uid()`, `consentimiento_id`, `detalle` fijo `"consentimiento y aviso de privacidad
   recabados: versión N"` (≤500). La confirmación de la casilla se **exige en el cuerpo**: campo
   `consentimiento_recabado: true` obligatorio (422 si falta o es false) — responde la pregunta 2 del README (el
   servidor lo exige; no es un adorno de la UI).
4. Errores del trigger/RLS por el mapeo de §6 (`SCJ12` `alta_duplicada` 409 / `persona_no_activa` 422 /
   `terminal_no_valida` 422; `SCJ16` carrera 409 con el vigente; `23503` 422 «persona no sincronizada»; `23505` carrera
   409; `42501` 403).

Cuerpo completo: `{persona_id, consentimiento_id, consentimiento_recabado: true}`.

### 2.5 `POST /api/terminales/{id}/usuarios/{tu_id}/baja` — baja o cancelación

Cuerpo: `{"motivo": "…"}`. **El motivo es OBLIGATORIO** (decisión del usuario, 2026-10-08): tras sanear (espacios
colapsados, sin controles ni invisibles) debe medir **10 a 500 caracteres**; si no → **422** con mensaje fijo «El motivo
de la baja debe tener entre 10 y 500 caracteres.» (nada se escribe). Constante `MOTIVO_BAJA_OBLIGATORIO` /
`MOTIVO_BAJA_MIN` / `MOTIVO_BAJA_MAX` en `routers/terminales.py`. El 422 de Pydantic (tipo, campos extra, > 2000 de
entrada cruda) conserva su forma estándar. **201** con la alta (ya en `pendiente_baja`).
Valida que `{tu_id}` pertenezca a `{id}` (404 si no). Inserta `baja_solicitada` con el cliente del caller
(`terminal_id`, `persona_id` de la fila; `detalle` = motivo saneado: espacios colapsados, sin controles, ≤500).
Errores: `SCJ11` → 409 (estado no válido / ya en baja), 403, 404. «Cancelar alta» y «Dar de baja» son **el mismo
endpoint** (la diferencia es sólo el estado de origen, `accion_disponible`).

### 2.5 bis `POST /api/terminales/{id}/usuarios/{tu_id}/huella-confirmada` — confirmar la huella a mano (94_, vía C)

Con el conteo de huellas fuera de alcance en la terminal real (V1.3.0 no lo da), una persona declara en la web que **la huella quedó enrolada en el menú del aparato**. Cuerpo CERRADO:
`{"nota": "…"}` — **la nota es OBLIGATORIA**: tras sanear (espacios colapsados, sin controles ni invisibles) debe medir **10 a 500 caracteres**; si no → **422** «La nota de la
confirmación debe tener entre 10 y 500 caracteres.» y nada se escribe (el trigger repite la regla con `SCJ12`/`nota_requerida`). Campos extra o tipos distintos → 422 estándar.
Gate: **`terminal_usuario_edicion`** (el mismo de asignar y dar de baja; no hay permiso nuevo). Valida que `{tu_id}` pertenezca a `{id}` (404 si no) e inserta
`huella_confirmada_manual` en la bitácora **con el cliente del caller** (origen `web`, `registrado_por = auth.uid()`): la policy `bitacora_terminal_usuario_insert_web` y el trigger
son la autorización real. **201** con el alta ya en `activo`, `huella_evidencia = "manual"` y `huellas_capturadas = 0` (**0 = «enrolada, conteo desconocido»**, nunca «sin huellas»).
Una confirmación equivocada **no se deshace** (la bitácora es inmutable): se pide la baja y se asigna de nuevo. No elude el consentimiento biométrico (el de la asignación sigue ligado).

| Error de la base | HTTP | `detail` fijo |
|---|---|---|
| `SCJ11` `transicion_invalida` (el alta no está en `esperando_huella`) | 409 | «El movimiento no es válido para el estado actual del alta.» |
| `SCJ12` `auto_confirmacion_huella_prohibida` (confirmas la huella de tu propia alta; el puesto administrador sí puede) | 422 | «No puedes confirmar tu propia huella; la confirma otra persona con permiso.» |
| `SCJ12` `misma_persona_que_asigno` (sólo si la base activa los «cuatro ojos»; hoy apagado) | 422 | «Quien asignó el alta no puede confirmar su huella; la confirma otra persona con permiso.» |
| `SCJ12` `nota_requerida` | 422 | «La nota de la confirmación debe tener entre 10 y 500 caracteres.» |
| `SCJ12` `marca_no_corresponde` (no debería ocurrir por este endpoint) | 409 | «Ese movimiento no se puede registrar desde aquí.» |
| `42501` | 403 | «No tienes permiso para esta acción.» |

**`huella_evidencia`** (nuevo en `AltaOut`, 94_): `"conteo"` (el aparato reportó el conteo) · `"inferida"` (la primera marca por huella la activó, 95_) · `"manual"` (una persona la
confirmó) · `null` (sin evidencia). Sólo la fija el trigger y sólo sube. En el historial (§2.6), cada movimiento `huella_capturada` / `huella_inferida` / `huella_confirmada_manual`
lleva el `huella_evidencia` correspondiente y los demás `null`; esa evidencia es la **de esa fila** (deriva del tipo del movimiento), **no la vigente del alta**: cualquier resumen de la alta debe pintar `AltaOut.huella_evidencia`, nunca la del último movimiento. **El backend y la UI no deben leer `huellas_capturadas = 0` como «sin huellas».** DESPLIEGUE: el backend selecciona
`terminal_usuario.huella_evidencia`, así que **requiere 94_ aplicado** antes de desplegar este corte. Orden obligado **DDL → backend → frontend**, forzado así: el backend se NIEGA a arrancar (`app/precondiciones.py`, `RuntimeError` con la migración que falta) si la base responde que la columna no existe, y `scripts/desplegar.sh levantar` ejecuta la misma comprobación (`scripts/verificar_esquema.py`: 0 = ok, 1 = falta una migración y el despliegue ABORTA, 2 = no se pudo consultar la base: aviso y se sigue). No hay fallback silencioso a columnas sin `huella_evidencia`: enmascararía un despliegue en mal orden. `SCJ_PRECONDICIONES=off` apaga la comprobación del arranque (pruebas/emergencias).

### 2.6 `GET /api/terminales/{id}/usuarios/{tu_id}/movimientos` — historial

```json
[
  {"id": 910, "tipo_movimiento": "reconsentido", "creado_en": "…", "origen": "web",
   "registrado_por_nombre": "María López",     // null si origen='terminal' (la UI muestra «Terminal»)
   "detalle": "reconsentimiento recabado: versión 4",
   "huellas_capturadas": null,
   "consentimiento": {"id": 4, "version": 4, "cambio_material": true}}   // sólo asignado y reconsentido
]
```
Orden `creado_en` desc. Cliente del caller (RLS). Nombres como en `movimientos.py`. `detalle` ya viene saneado de la
base (CHECK ≤500). Sin plantillas. 404 si `{tu_id}` no es de `{id}`.

### 2.7 `GET /api/personas/{persona_id}/terminales`

Altas de **esa persona** en todas las terminales, para la sección «Terminal» de la ficha (responde el pedido 4):

```json
[{ "alta": { …objeto de 2.1… }, "terminal": {"id":1,"nombre":"…","serie":"…","estado_contacto":"en_linea","activa":true} }]
```
Incluye altas en `baja` (la UI decide cuáles pinta); orden `creado_en` desc. Gate `terminal_usuario_lectura`/`edicion`
(sin él, **403** y el frontend oculta la sección por la bandera de sesión). Cliente del caller.

---

## 3. Consentimiento (texto versionado)

Bajo `/api/terminales/configuracion/consentimiento`. Visibilidad: quien ve el grupo (lectura/edición/config).

### 3.1 `GET …/consentimiento`

```json
{
  "vigente": {"id": 4, "version": 4, "texto": "…", "texto_sha256": "…hex64…", "provisional": false,
              "cambio_material": true, "motivo_cambio": "…", "vigente_desde": "…",
              "publicado_por_nombre": "Carlos Ruiz", "es_semilla": false},
  "historial": [ {…misma forma…, "vigente_hasta": "…|null"} ]   // todas, versión desc; incluye la vigente
}
```
- `motivo_cambio` = columna `nota`. `vigente_desde` = `creado_en` de la versión; `vigente_hasta` = `creado_en` de la
  siguiente (la tabla no tiene rango, se deriva). `publicado_por_nombre` se resuelve desde `creado_por`
  (`personas.persona`); la semilla (sin autor) → `publicado_por_nombre: null`, `es_semilla: true` (la UI escribe
  «Sistema (texto provisional)»).
- El texto es **texto plano**; el frontend lo muestra como texto (no HTML). **El texto completo viaja sólo en `vigente`**;
  cada entrada de `historial` trae `texto: null` (con 200 versiones de hasta 4 000 caracteres el historial pesaría cientos de
  KB). El texto de una versión anterior se pide bajo demanda con **`GET …/consentimiento/{version}`** (mismo gate; devuelve la
  versión completa con la misma forma, `vigente_hasta` incluido; 404 «La versión del texto no existe.»; `version` 1–2147483647).
  Cliente del caller (policy `terminal_consentimiento_select_lectura`). *Afecta al mockup 09 (historial): «ver texto» de una
  versión anterior hace esta segunda petición.*

### 3.2 `GET …/consentimiento/impacto?cambio_material=true|false`

Para el panel de publicar (cifra «cuántas quedarían pendientes»), calculada **antes** de publicar.
**Gate: `terminal_usuario_lectura` o `terminal_usuario_edicion`** (decisión del usuario; `terminal_config_edicion` sola NO basta):
las cifras se cuentan con la RLS del caller, así que quien sólo configura vería 0 altas y publicaría un cambio material a
ciegas. Quien publica debe, por tanto, poder ver también las altas; sin eso el panel responde **403**.

```json
{"cambio_material_efectivo": true, "forzado": true,
 "altas_que_quedarian_pendientes": 14, "en_proceso": 3, "activas": 11, "pendientes_actuales": 0}
```
- `forzado=true` si la vigente es **provisional** (publicar definitiva fuerza `cambio_material`; el cliente no puede
  desmarcarlo).
- Si `cambio_material_efectivo` es true, todas las altas en `pendiente_alta`/`esperando_huella`/`activo` quedarían
  pendientes (la nueva versión es mayor que cualquier confirmación): se cuenta con el cliente del caller sobre
  `terminal_usuario` (RLS). Si es false, `altas_que_quedarian_pendientes` = 0 y `pendientes_actuales` informa las que
  ya hay. No requiere RPC nuevo.

### 3.3 `POST …/consentimiento` — publicar

Cuerpo: `{"texto": "1–4000", "cambio_material": false, "motivo_cambio": "≤200 opcional", "base_version": 3}`.
**`base_version` es OBLIGATORIO** (422 si falta): la pantalla de publicar lo manda siempre, con la versión vigente que leyó al
abrir; el RPC compara (`p_base_version`) y, si otra persona publicó mientras tanto, responde `SCJ16 / version_base_desactualizada`
(409 con `consentimiento_vigente`). Ya no es un chequeo previo del backend.
Llama `fn_terminal_consentimiento_publicar(p_texto, p_cambio_material, p_nota)` con el **cliente del caller** (gate dentro).
- **201** `{"resultado":"publicada","id","version","cambio_material","cambio_material_forzado","pendientes"}` (con `pendientes`
  que devuelve el RPC) o **200** `{"resultado":"sin_cambio","version"}` si el texto es igual al de la vigente definitiva.
- **409** si `base_version` ≠ versión vigente: `{"detail": "Otra persona publicó una versión nueva…", "consentimiento_vigente":{…}}`.
- Validación de entrada en Pydantic (texto 1–4000, motivo ≤200, `extra=forbid`); el RPC sanea y vuelve a validar
  (`22023` `texto_invalido`/`nota_invalida` → 422, mensajes fijos).
- **La primera definitiva que sustituye a la provisional fuerza `cambio_material` en el servidor** (lo hace el RPC; el
  backend sólo lo refleja en la respuesta con `cambio_material_forzado: true`).
- **Sin `provisional` en el cuerpo (resuelto):** `frontend` quitó «Marcar como provisional» del mockup 09. El POST **no acepta
  `provisional`** (`extra=forbid` → 422 si llega) porque el RPC nunca publica `provisional=true`
  (`ck_terminal_consentimiento_provisional`: sólo la v1 sembrada lo es). Dejar de ser provisional = publicar una versión nueva, que
  además fuerza `cambio_material`.

---

## 4. Reconsentimiento

Gate `terminal_usuario_edicion`; escribe con el cliente del caller (RPC `SECURITY INVOKER`).

### 4.1 Por alta — `POST /api/terminales/{id}/usuarios/{tu_id}/reconsentimiento`
Cuerpo `{"consentimiento_id": 4, "declaracion_documentos": true}`. Equivale a un lote de un elemento (§4.2).
**201** `{"registradas": 1}`.

### 4.2 Lote — `POST /api/terminales/{id}/usuarios/reconsentimientos`
Cuerpo `{"tu_ids": [..1–200..], "consentimiento_id": 4, "declaracion_documentos": true}`.
- `declaracion_documentos` **obligatoria** (la casilla «los documentos firmados existen»; 422 si falta). Es una
  declaración de quien registra; el detalle fijo del movimiento lo pone el RPC.
- **Reconsentimiento propio prohibido** (decisión del usuario, 2026-10-08), salvo administrador genérico
  (`es_administrador_generico`): lo **impone la base** (`db`), y el backend lo refleja en tres lugares: (a) en C6 mapea
  el rechazo de la base a **422** con mensaje fijo (sin texto crudo); (b) la alta de la persona del llamador se
  **excluye** de la lista de pendientes del lote (`GET …/reconsentimientos-pendientes` y «Seleccionar las N
  pendientes»), y si un lote la trae igualmente se reporta en `no_elegibles` con razón `es_propia`; (c) el listado de
  altas expone `es_propia` / `reconsentimiento_elegible` / `reconsentimiento_razon` para que la UI deshabilite la
  casilla con la razón (ya no depende de adivinar). Razones cerradas: `es_propia`, `ya_al_corriente`, `en_baja`.
- **Máximo 200** (más → 422 `lote_invalido`, antes de tocar la base); sin duplicados (se deduplican).
- **Todo o nada:** el backend **antes** del RPC valida elegibilidad de **cada** id contra la terminal `{id}` y
  `fn_terminal_reconsentimiento_pendiente_ids()`. Si alguno no es elegible → **409** sin escribir nada:

```json
{"detail": "No se registró nada: algunas altas ya no son elegibles.",
 "no_elegibles": [{"tu_id": 81, "persona_nombre": "Julio Cano", "razon": "ya_al_corriente"},
                  {"tu_id": 90, "persona_nombre": "Sofía Vega", "razon": "en_baja"}]}
```
  Razones (lista cerrada): `es_propia` (la alta es de quien llama; no aplica al administrador genérico), `ya_al_corriente` (alguien más ya la registró), `en_baja` (`pendiente_baja` o `baja`),
  `no_encontrada` (no existe o es de otra terminal; **sin nombre** para no filtrar existencia).
- Versión desactualizada → **409** `{"detail": "El texto de consentimiento cambió…", "consentimiento_vigente":{…}}`.
- Éxito **201** `{"registradas": N, "pendientes_restantes": M}`.
- **Atomicidad real (Pregunta Q3):** `fn_terminal_reconsentir` **omite** (no rechaza) las no elegibles y devuelve
  `omitidas`; entre mi verificación y el RPC una alta puede dejar de ser elegible y el lote quedaría parcial
  (inofensivo: sólo registra declaraciones). Si `db` agrega un modo estricto (`p_estricto`) el backend lo usa y la
  garantía es total; mientras no, la respuesta incluye `omitidas` si las hubo (poco probable) en lugar de ocultarlo.

---

## 5. Variables (claves `terminal_*` de `tiempo.parametro`, 89_)

Bajo `/api/terminales/configuracion/variables`. Catálogo de **etiqueta, descripción, unidad y orden en código**
(`backend/app/catalogo_terminal.py`); **rangos** desde `fn_terminal_config_catalogo()` (única fuente en la base) y un test
de contrato que compara ambos.

### 5.1 `GET …/variables`
```json
[{"clave": "terminal_caducidad_alta_horas", "etiqueta": "Caducidad de altas sin huella",
  "descripcion": "…", "unidad": "horas", "minimo": 4, "maximo": 168, "valor_defecto": 24,
  "valor": 48, "vigente_desde": "2026-10-08", "modificado_por_nombre": "Carlos Ruiz"}]
```
Lectura de `tiempo.parametro` con **`service_role`** (deny-all para el caller; lectura de insumo, sólo claves de la
lista blanca `terminal_*`). Si una clave falta o está corrupta devuelve el valor por defecto con `vigente_desde: null`
(no tumba la pantalla; mismo criterio que `fn_terminal_config_valor`).

### 5.2 `PATCH …/variables/{clave}`
Cuerpo `{"valor": 48, "valor_base": 24}` (entero). Llama `fn_terminal_config_actualizar(p_clave, p_valor)` con el
**cliente del caller** (gate dentro). `valor_base` es el valor que el cliente tenía; si no coincide con el vigente →
**409** `{"detail":"La variable cambió mientras la editabas…","valor_actual":N}` (chequeo previo con `service_role`; el
RPC no compara). Respuestas: **200** `{"resultado":"actualizada"|"sin_cambio","clave","valor","vigente_desde"}`.
Errores: `22023` `clave_no_editable` → 404/422; `valor_invalido` → 422 con **mensaje armado en el backend** a partir del catálogo
(«El valor debe ser un entero entre {min} y {max}.»; las reglas cruzadas llave/traslape se explican con texto fijo);
`SCJ02` → 404; 403. Un segundo cambio el mismo día corrige la vigencia en sitio (comportamiento de la base).

### 5.3 `GET …/variables/historial?clave=&desde=`
Vigencias de las claves `terminal_*` (valor, `vigente_desde`, `vigente_hasta`, `modificado_por_nombre`, estado
`vigente|reemplazada`), más recientes primero; tope 200. `service_role` (misma razón que 5.1).

### 5.4 `POST …/variables/terminal_caducidad_alta_horas/simular`
Cuerpo `{"valor": 12}`. **Sólo para esa clave** (otra → 404). Gate `terminal_config_edicion`. Sin escribir:

```json
{"valor_actual": 24, "valor_propuesto": 12, "acorta": true,
 "altas_en_espera": 5,
 "altas_que_ganan_plazo": 0,
 "altas_que_caducarian_ya": [{"tu_id":77,"persona_nombre":"Luis Ramírez","esperando_desde":"…"}],
 "altas_por_caducar_nuevas": 1,
 "tope_por_corrida": 50}
```
Se calcula sobre las altas en `esperando_huella` con su `usuario_creado_en` (bitácora): «caducarían ya» = llevan ≥
`valor_propuesto` y < `valor_actual`; «ganan plazo» (si alarga) = las que hoy caducan antes y con el nuevo plazo no;
«por caducar» = quedan a < 1 h. `altas_que_caducarian_ya` se corta a 50 nombres (el tope de la función SQL) con
`total` aparte si hay más. Validación del rango idéntica al PATCH (422).

### 5.5 Filtro del router genérico de Parámetros (**URGENTE, ver §11 · C0**)
`routers/parametros.py::_mezclar_con_catalogo` hace `CATALOGO[fila["clave"]]`: en cuanto 89_ siembre las 5 claves, `GET
/api/parametros` y su historial dan **KeyError → 500**. Antes de aplicar 89_: ignorar en el listado vigente y el
historial toda fila cuya clave no esté en `CATALOGO` (o empiece por `terminal_`), y mapear `SCJ17`/`clave_reservada` de
`PUT /api/parametros/{clave}` a 403 mensaje fijo («Esa variable se edita desde Terminales → Configuración.»). El `PUT` ya
rechaza claves fuera del catálogo; el guard del SQL es la red de seguridad.

---

## 6. Mapeo de errores `SCJ11`–`SCJ17` (nuevo `errores.py::traducir_error_terminal_web`)

Mismo patrón que `traducir_error_dia_cerrado` (devuelve `HTTPException|None`, y `manejar_…` NoReturn). Mensajes **fijos**.

| Error de la base | HTTP | `detail` fijo |
|---|---|---|
| `SCJ11` `transicion_invalida` | 409 | «El movimiento no es válido para el estado actual del alta.» |
| `SCJ12` `alta_duplicada` | 409 | «La persona ya tiene un alta vigente en esta terminal.» |
| `SCJ12` `persona_no_activa` | 422 | «La persona no existe o no está activa.» |
| `SCJ12` `terminal_no_valida` | 422 | «La terminal no existe o no está activa.» |
| `SCJ13` `terminal_con_altas_vigentes` | 409 | «La terminal tiene altas vigentes; da de baja todas antes de desactivarla.» (no hay endpoint de desactivación; por si se agrega) |
| `SCJ14` (credencial revocación inmutable) | 409 | «La credencial ya está revocada.» (idem) |
| `SCJ15` | — | **lo traduce el helper existente** (`traducir_error_dia_cerrado`) |
| `SCJ16` `consentimiento_desactualizado` | 409 | «El texto de consentimiento cambió; vuelve a leerlo.» **+ `consentimiento_vigente`** |
| `SCJ16` `consentimiento_requerido` | 422 | «Falta la versión del texto de consentimiento.» (no debería ocurrir) |
| `SCJ17` `clave_reservada` | 403 | «Esa variable se edita desde Terminales → Configuración.» |
| `22023` `texto_invalido` | 422 | «El texto debe tener entre 1 y 4 000 caracteres.» |
| `22023` `nota_invalida` | 422 | «El motivo del cambio no puede pasar de 200 caracteres.» |
| `22023` `lote_invalido` | 422 | «El lote debe traer entre 1 y 200 altas.» |
| `22023` `clave_no_editable` | 404 | «La variable no existe.» |
| `22023` `valor_invalido` | 422 | «El valor debe ser un entero entre {min} y {max}.» (del catálogo del backend) |
| `SCJ02` | 404 | «No existe un parámetro activo con esa clave.» |
| `23503` | 422 | «La persona no está sincronizada en el esquema de tiempo; avisa a Sistemas.» |
| `23505` | 409 | «Otra asignación de esta persona ocurrió al mismo tiempo; recarga.» |
| `42501` `sin_permiso` | 403 | «No tienes permiso para esta acción.» |
| `42501` sin hint | 403 + `ERROR` en el log | ídem |
| `PGRST202`/`PGRST204`/`PGRST205`/`42P01` (objeto inexistente: **migración sin aplicar**, p. ej. 88_) | 503 | «Servicio no disponible. Avisa a Sistemas.» + `ERROR` en el log (handler global de `APIError`) |
| respuesta de un RPC con forma inesperada (publicar, reconsentir) o bitácora sin `terminal_usuario_id` (asignar) | 503 | «El servicio no respondió como se esperaba; intenta de nuevo o avisa a Sistemas.» + `ERROR` en el log |
| `SCJ16` `version_base_desactualizada` | 409 | «Otra persona publicó una versión nueva del texto; vuelve a leerlo antes de publicar.» **+ `consentimiento_vigente`** |
| `SCJ12` `auto_asignacion_prohibida` | 422 | «No puedes asignarte a ti mismo a una terminal. Sólo el puesto administrador puede hacerlo.» |
| `SCJ12` `auto_reconsentimiento_prohibido` | 422 | «No puedes registrar tu propio reconsentimiento; lo registra otra persona con permiso.» |
| `SCJ12` `auto_confirmacion_huella_prohibida` | 422 | «No puedes confirmar tu propia huella; la confirma otra persona con permiso.» (94_) |
| `SCJ12` `misma_persona_que_asigno` | 422 | «Quien asignó el alta no puede confirmar su huella; la confirma otra persona con permiso.» (94_) |
| `SCJ12` `nota_requerida` | 422 | «La nota de la confirmación debe tener entre 10 y 500 caracteres.» (94_) |
| `SCJ12` `marca_no_corresponde` | 409 | «Ese movimiento no se puede registrar desde aquí.» (94_) |
| cualquier otro | 500 genérico | — |

### 6.0 Campo estable `codigo` (cambio aditivo, 2026-10-08)
Los errores con campos hermanos llevan además `"codigo"`, un identificador **estable** para que el cliente decida por él y nunca
deduzca por el texto de `detail` (que sigue siendo fijo y puede cambiar de redacción): `consentimiento_desactualizado`,
`version_base_desactualizada`, `valor_desactualizado`, `lote_no_elegible` y `lote_reintentar` (409 de carrera con la lista
reconstruida vacía). Cuerpo: `{"detail": "<texto fijo>", "codigo": "<código>", …campos hermanos}`. Quien ignore `codigo` no se ve
afectado. Si la relectura del texto vigente falla, el 409 de consentimiento sale con `detail` + `codigo` y **sin**
`consentimiento_vigente`. Los demás errores (sin campos hermanos) no llevan `codigo`.

### 6.1 Cuerpo de los 409 de consentimiento
`{"detail": "<texto fijo>", "consentimiento_vigente": {"id","version","texto","texto_sha256","provisional","cambio_material","vigente_desde"}}`.
Se arma releyendo la vigente con el cliente del caller; si esa relectura falla, se devuelve sólo `detail` (el frontend
debe tolerar la ausencia del campo y pedir `GET …/consentimiento`). Es el único tipo de `detail` con campo hermano
(junto con `no_elegibles` y `valor_actual`); el cliente HTTP del frontend debe conservar el cuerpo completo en los
errores.

---

## 7. Banderas en `GET /api/sesion`

Campos nuevos (default `false`, calculados con `permisos.tiene_permiso` — con herencia donde corresponde):

| Campo | Regla |
|---|---|
| `puede_ver_terminales` | tiene `terminal_usuario_lectura` **o** `terminal_usuario_edicion` **o** `terminal_config_edicion` (la visibilidad del grupo y de Configuración; coincide con la policy de `terminal_consentimiento`) |
| `puede_editar_terminales` | `terminal_usuario_edicion` (asignar, baja, reconsentir) |
| `puede_editar_config_terminales` | `terminal_config_edicion` (publicar texto, variables) |

`false` en las tres si la cuenta está bloqueada. Costo: 3 consultas de permiso más por sesión (hoy 5): aceptable; si molesta,
se cachea el árbol de puestos dentro de la petición. `puede_descartar_excepciones` y `puede_ver_modulo_N` no cambian.
*Q5 — RESUELTA por el usuario (2026-10-08):* `puede_ver_terminales` es true **sólo** con `terminal_usuario_lectura` o
`terminal_usuario_edicion`; `terminal_config_edicion` por sí sola NO abre Terminales (solo marca
`puede_editar_config_terminales`). Se revirtió el supuesto anterior («sí, para alinearse con la RLS»).

---

## 8. Advertencias al suspender / dar de baja

`POST /api/personas/{id}/movimientos` (`routers/movimientos.py`): tras el `INSERT` exitoso y sólo para `suspension` y
`baja_definitiva`, llama `fn_terminal_baja_por_persona_inactiva(p_persona_id)` con **`service_role`** (la persona
suspendida puede no tener `terminal_usuario_edicion`; autor derivado de la bitácora de personas dentro del RPC;
`SCJ-DEC-12 §5`). `MovimientoOut` suma (opcionales, compatibles):

```json
{"…": "…", "advertencias": ["baja_terminal_pendiente"], "bajas_terminal_emitidas": 2}
```
- `advertencias` se llena **sólo si falla** el RPC (excepción, o resultado `-1` = sin autor derivable): el movimiento
  de persona ya está confirmado y sigue siendo `201`; `ERROR` en el log; el job de respaldo (§9) reintenta.
- `bajas_terminal_emitidas`: entero ≥ 0 (cuántas bajas emitió el RPC) — responde el pedido 8 del README (banner
  informativo opcional). `reactivacion`/`alta`: `advertencias: []`, `bajas_terminal_emitidas: 0`, sin llamar al RPC.

---

## 9. Tablero de anomalías

### 9.1 `GET /api/terminales/{id}/anomalias?desde=YYYY-MM-DD&hasta=`
`desde` por defecto = hoy − `terminal_anomalias_ventana_dias` (variable; tope 90 días); `hasta` por defecto = ahora.
Gate lectura. **Cada categoría se calcula aislada**: si una falla, esa tarjeta lleva `estado: "error"` y las demás
siguen (el tablero nunca es todo-o-nada).

```json
{
  "terminal_id": 1, "desde": "…", "hasta": "…", "generado_en": "…",
  "categorias": [
    {"clave": "marcas_posteriores_a_baja", "numero": 1, "titulo": "Marcas posteriores a la baja",
     "estado": "con_hallazgos",          // sin_hallazgos | con_hallazgos | no_disponible | error
     "nivel": "atender",                 // atender | revisar | informativo | null (sin hallazgos)
     "total": 2,
     "ejemplos": [ {…forma por categoría…} ],     // hasta 3
     "hay_mas": false}
  ]
}
```
- **El backend manda el `nivel`** (respuesta al pedido 5): 1 y 7 → `atender`; 2, 3, 4, 5, 6, 8, 10, 11, 12, 13 → `revisar`; 9 →
  `informativo`; `null` cuando `total` = 0. El frontend sólo lo pinta.
- **Categorías sin fuente / con fallo:** `no_disponible` si la fuente aún no existe (p. ej. antes de aplicar 84_ para la 5)
  y `error` si la consulta falla; ambas con `total: null` y `ejemplos: []`. Cada tarjeta lleva además `nota` (texto fijo de contexto o `null`; hoy sólo la 11).
- **«Ver todos»:** `GET …/anomalias/{clave}?desde=&limite=&desplazamiento=` (limite ≤ 200) devuelve `{total, items:[…]}` con la
  misma forma de `ejemplos`.

| # | `clave` | Qué cuenta (fuente) | Forma de un ejemplo |
|---|---|---|---|
| 1 | `marcas_posteriores_a_baja` | marcas de la persona en esa terminal con `momento_dispositivo` posterior al `baja_confirmada` de su alta (`marca` + bitácora) | `{persona_nombre, marca_en, baja_confirmada_en}` |
| 2 | `picos_de_tasa` | persona con > **10** marcas/hora (fijo, igual que el RPC) y terminal con > 1 000/h (`marca`) | `{persona_nombre?, hora, marcas, limite}` |
| 3 | `reloj_degradado` | marcas con `estado_reloj='deriva'` o excepción `reloj_no_sincronizado`; más `reloj_desfase_seg` actual | `{conteo, desfase_actual_seg}` |
| 4 | `huecos_de_secuencia` | saltos en `secuencia_local` de la terminal | `{desde, hasta, faltan, fecha}` |
| 5 | `rechazos_definitivos` | `marca_rechazada` por `codigo` | `{codigo, total}` |
| 6 | `credenciales` | llave > `terminal_llave_max_meses`; **traslape abierto** > `terminal_traslape_llave_max_dias`; cambio de IP reciente; llaves sin uso | `{tipo, antiguedad_meses|dias_abierto|…}` (sin hash ni IP completa) |
| 7 | `inconsistencias_de_baja` | persona `estado <> 'activo'` con alta no-`baja` (hook y job fallaron) | `{persona_nombre, estado_persona, estado_alta}` |
| 8 | `altas_atascadas` | `pendiente_alta`/`pendiente_baja` con más de **N h** y `esperando_huella` ya vencidas | `{persona_nombre, estado, horas}` |
| 9 | `altas_recientes` | `asignado` en el periodo (con quién asignó) | `{persona_nombre, asignada_por, creado_en}` |
| 10 | `reconsentimientos_pendientes` | `fn_terminal_reconsentimiento_pendiente_ids()` | `{persona_nombre, version_confirmada, version_vigente, dias_pendiente}` |
| 11 | `huellas_inferidas_exceso` (94_) | días con más de **5** `huella_inferida`, o confirmaciones **manuales** (≥ 3) que son más de la mitad de las activaciones del día (la vía automática no funciona). RPC `fn_terminal_anomalias` | `{dia, inferidas, manuales, activaciones, limite_inferidas}` + **`nota`** fija: «Es ESPERADO el primer día de puesta en marcha: varias altas se activan a la vez…» |
| 12 | `inferida_sin_marcas` (94_) | alta activada por inferencia/confirmación manual hace > 7 días **sin ninguna marca más** de esa persona en los 7 días siguientes (la marca que sirvió de evidencia no cuenta). RPC. **Cruza `tiempo.marca`: exige además `marca_lectura`** (sin él: `no_disponible`/`sin_permiso`, como 1 y 2) | `{persona_nombre, evidencia, activada_en}` |
| 13 | `asignador_confirmador` (94_) | confirmaciones manuales hechas por **la misma persona que asignó** el alta (la variante barata de los cuatro ojos). RPC | `{persona_nombre, confirmada_por, confirmada_en}` |
| 14 | `interruptor_huella` (97_/98_) | **GLOBAL**: alarma del interruptor de la activación por huella (ver `CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md` §5); ilegible ⇒ `error` | `{codigo, mensaje}` |
| 15 | `terminal_sin_contacto` | el puente no manda latido. **POR terminal**, con la MISMA función de estado de contacto que la insignia de Terminales (`app/contacto_terminal.py`; el tablero no reimplementa el umbral `terminal_umbral_sin_contacto_seg`). `nunca` ⇒ `revisar` («aún no se ha comunicado»); `sin_contacto` ⇒ `revisar` entre el umbral (5 min) y 15 min, `atender` desde 15 min; inactiva o en línea ⇒ sin hallazgos; un último contacto ilegible ⇒ tarjeta `error` | `{codigo: nunca_comunicada\|sin_latido_revisar\|sin_latido_atender, mensaje, minutos_sin_latido (entero redondeado hacia abajo, null si nunca)}` — sin serie, IP, employee_no ni credencial |

**Categoría 15 es un aviso PASIVO:** no envía correos ni mensajes (la tarjeta lleva esa `nota`). Se recomienda una revisión diaria del tablero por TI o un monitor externo que consulte el estado de contacto; el LEEME de instalación del puente y `operador estado` lo repiten. Va sin `marca_lectura` (solo el gate del tablero), aislada como las demás y con la caché de 45 s del tablero.

**Datos que el caller no puede leer** (marcas, credenciales, `marca_rechazada`, personas con estado, `parametro`): se leen con `service_role`
**filtrando siempre por el `terminal_id` de la URL en código** y exponiendo sólo lo de la tabla (nombres, fechas, cifras;
nunca hash, IP completa, persona_id ni employee_no). Es una escalada de visibilidad **acotada**: quien tiene
`terminal_usuario_lectura` ve, por ejemplo, la hora de una marca de otra persona (mismo conjunto que ya ve en el
tablero de marcas con `marca_lectura`). *Pregunta Q6 para security.*

**Opciones de implementación (decide `db`+`backend`, Pregunta Q4):** (A) una función SQL de sólo lectura
`tiempo.fn_terminal_anomalias(p_terminal_id, p_desde, p_hasta)` (STABLE, EXECUTE `service_role`, filtra por terminal
**dentro**) — evita truncamientos de `max-rows`, N+1 y agregaciones en Python (picos, huecos); (B) consultas Python con
tope de filas y `truncado: true`. **Recomiendo A** para 2, 4 y 1 (agregaciones); el resto puede ser Python.

Hasta que existan sus fuentes: la 10 depende de 88_; la 5 de 84_ (ya aplicado); la 6 de los datos de credenciales.
`N` de la categoría 8: valor propuesto = `terminal_caducidad_alta_horas` (reusa la variable; Pregunta Q7).

---

## 10. Jobs (scheduler) que cierran el ciclo — mismo paquete T-BE-6/7

No son API web, pero dependen de las variables de §5 y del hook de §8:
1. **Baja por persona inactiva** (≈10 min): personas `estado <> 'activo'` con altas no-`baja` → `fn_terminal_baja_por_persona_inactiva`; `-1`
   se registra como alerta, no se reintenta en bucle.
2. **Caducidad:** `p_horas = fn_terminal_config_valor('terminal_caducidad_alta_horas')` → `fn_terminal_baja_por_caducidad(p_horas)`
   (piso 4 h y tope 50 dentro de la función). Cada corrida lee el valor vigente (el cambio aplica a las altas en curso).
3. **Purga:** `fn_marca_rechazada_purgar(p_dias = fn_terminal_config_valor('terminal_retencion_rechazos_dias'))`.
Un solo worker (el `BackgroundScheduler` embebido); idempotentes.

---

## 11. Orden de cortes sugerido (cada uno con TDD con mocks, sin BD real)

| Corte | Contenido | ¿Depende de que `db` aplique 88_/89_? |
|---|---|---|
| **C0 (hotfix previo a 89_)** | Filtro de claves `terminal_*` en `routers/parametros.py` + mapeo de `SCJ17`; **debe estar desplegado antes de aplicar 89_** (si no, `GET /api/parametros` da 500). Test con una fila `terminal_x` en el mock | No (compatible hacia atrás); **bloquea la aplicación de 89_** |
| **C1** | `errores.py::traducir_error_terminal_web` (SCJ11–SCJ17), `permisos.es_administrador_generico`, banderas de `/api/sesion` (lectura/edición ya; `puede_editar_config_terminales` devuelve false hasta que exista el permiso) | No (el permiso `terminal_config_edicion` aparece con 88_; la bandera es tolerante) |
| **C2** | `GET /api/terminales` y `/{id}` + `Settings.terminal_umbral_sin_contacto_seg` | No |
| **C3** | Hook de baja por persona inactiva + `advertencias`/`bajas_terminal_emitidas` en movimientos | No |
| **C4** | Baja/cancelar + historial + `GET /api/personas/{id}/terminales` + personas-asignables + lista de altas **sin** campos de consentimiento | Los de consentimiento no; el resto no |
| **C5** | **Consentimiento** (GET, impacto, publicar) y **asignar con `consentimiento_id`**; campos de consentimiento en altas/historial/ficha | **Sí: 88_** |
| **C6** | **Reconsentimiento** (por alta, lote, ids pendientes, filtro/contador) | **Sí: 88_** |
| **C7** | **Variables** (GET/PATCH/historial/simular) + `caduca_en` con la variable real + jobs de caducidad/purga leyendo la variable | **Sí: 89_** (hasta entonces `caduca_en` usa 24 h por defecto) |
| **C8** | **Tablero de anomalías** (10 categorías; la 10 con 88_; la 5/6 con sus fuentes) + job de baja de respaldo | 88_ para la 10; resto no |

C2–C4 no dependen de db y pueden empezar ya; C5–C7 esperan 88_/89_ **aplicados** (los mocks y los tests de contrato RPC↔DDL
sí pueden escribirse antes leyendo los archivos sin trackear, pero no se despliegan). Cada corte: revisión de `security` y `testing`
antes de commitear, como hasta ahora.

---

## 12. Lo que depende de `db` (y no está en 88_/89_)

1. **Q1 `detalle` de `asignado`:** el contrato propone `detalle` fijo «consentimiento y aviso de privacidad recabados: versión N»
   (la versión ya vive en `consentimiento_id`). ¿Conforme, o prefiere `NULL`?
2. ~~Q2 «Marcar como provisional»~~ **Resuelta:** el control se quitó del mockup 09; el POST no lleva `provisional`; sólo la v1 sembrada lo es. Nada que pedir a `db`.
3. **Q3 Atomicidad del lote de reconsentimientos** (`p_estricto boolean` en `fn_terminal_reconsentir`, §4.2) y **`p_base_version`**
   en `fn_terminal_consentimiento_publicar` (hoy el 409 por «publicó otra persona» es un chequeo previo del backend, con una ventana
   de carrera mínima).
4. **Q4 Anomalías en SQL** (§9): ¿`fn_terminal_anomalias` o Python?
5. **Q8 `usuario_creado_en` como columna** de `terminal_usuario` (la fijaría el trigger en `usuario_creado`): hoy se deriva de la
   bitácora con una consulta extra por página; con la columna, `caduca_en` y la simulación son una sola lectura. Opcional.

---

## 13. Preguntas abiertas para el usuario / orchestrator

- **Q5** (resuelta, §7) `puede_ver_terminales` para quien sólo tiene `terminal_config_edicion`: no.
- **Q6** (`security`) Visibilidad del tablero con `service_role` acotado a la terminal de la URL (§9).
- **Q7** Umbral de «alta atascada» (categoría 8): ¿reusar `terminal_caducidad_alta_horas` o una constante (24 h)?
- **Q9** Contrato 409 con campo hermano (`consentimiento_vigente`, `no_elegibles`, `valor_actual`): ¿lo acepta el cliente HTTP del
  frontend (debe conservar el cuerpo del error)?
- ~~Q10~~ **Resuelta:** `personas-asignables` devuelve además `puesto` y `area` (null si no hay asignación vigente) para distinguir homónimos.
- **Q11** Permisos de lectura de la configuración: las pantallas 09/10 las ve «quien ve el grupo»; los endpoints GET de
  consentimiento/variables usan ese mismo gate (no hay permiso de lectura aparte).

---

## 14. Resumen de endpoints

| Método y ruta | Gate | Cliente | Corte |
|---|---|---|---|
| `GET /api/terminales`, `/{id}` | lectura/edición | caller | C2 |
| `GET /api/terminales/{id}/usuarios` | lectura/edición | caller (+service para `caduca_en`) | C4→C5 |
| `GET …/{id}/reconsentimientos-pendientes` | lectura/edición | caller | C6 |
| `GET …/{id}/personas-asignables` | edición | caller | C4 |
| `POST …/{id}/usuarios` (asignar) | edición | caller | C5 |
| `POST …/{id}/usuarios/{tu_id}/baja` | edición | caller | C4 |
| `POST …/{id}/usuarios/{tu_id}/huella-confirmada` (94_) | edición | caller | 94_ |
| `GET …/{id}/usuarios/{tu_id}/movimientos` | lectura/edición | caller | C4 |
| `POST …/{id}/usuarios/{tu_id}/reconsentimiento` | edición | caller | C6 |
| `POST …/{id}/usuarios/reconsentimientos` | edición | caller | C6 |
| `GET /api/personas/{id}/terminales` | lectura/edición | caller | C4 |
| `GET/POST …/configuracion/consentimiento`, `GET …/impacto` | lectura; publicar: `config_edicion` | caller | C5 |
| `GET/PATCH …/configuracion/variables`, `GET …/historial`, `POST …/simular` | lectura; editar: `config_edicion` | service (lectura) + caller (escritura) | C7 |
| `GET …/{id}/anomalias`, `GET …/anomalias/{clave}` | lectura/edición | service acotado | C8 |
| `GET /api/sesion` (+3 banderas) | sesión | service | C1 |
| `POST /api/personas/{id}/movimientos` (+`advertencias`, `bajas_terminal_emitidas`) | `cambio_estado_persona` | caller + service (RPC de baja) | C3 |
| `GET/PUT /api/parametros` (filtro `terminal_*`, `SCJ17`) | existente | existente | **C0** |


---

## 15. Notas de implementación y despliegue (C5/C6, 2026-10-08)

- **Orden de aplicación/despliegue:** `88_` → desplegar el backend → `89_` → `90_` → `91_`. El backend de C5+ **exige 88_ aplicado**
  (el listado de altas lee `usuario_creado_en`/`consentimiento_id` y llama a la función de pendientes); sin 88_ esos endpoints
  responden **503** «Servicio no disponible» (no 500). El filtro de C0 debe estar desplegado **antes** de aplicar 89_.
- **Asignar:** el cuerpo no manda `detalle` (la base lo fija siempre) ni `employee_no`/`terminal_usuario_id`; `consentimiento_recabado`
  es obligatorio y verdadero (422 si no).
- **Reconsentimiento propio:** la base lo impone (`auto_reconsentimiento_prohibido`, 88_); el backend además lo marca en el
  listado (`es_propia`), lo excluye de `reconsentimientos-pendientes` y lo reporta en `no_elegibles` con razón `es_propia`.
  El lote usa `p_estricto = true`: todo o nada también ante carreras (si el RPC rechaza con `lote_no_elegible`, el backend
  reconstruye la lista; nunca se relaya el `DETAIL`). Respuesta: `{"registradas", "pendientes_restantes", "omitidas": []}`.

### 15.1 C7 — como quedó implementado (2026-10-08)

- **Variables:** `GET/PATCH …/configuracion/variables`, `GET …/variables/historial`, `POST …/variables/terminal_caducidad_alta_horas/simular`.
  Rangos y etiquetas viven en `app/catalogo_terminal.py` (un test compara los rangos con `fn_terminal_config_catalogo()` de 89_).
- **PATCH:** `valor` y `valor_base` son **enteros JSON estrictos y obligatorios** (`"48"` o `48.0` → 422). Orden: clave de la lista
  blanca (404) → rango (422, «El valor debe ser un entero entre {min} y {max}.») → `valor_base` contra el vigente (409 con
  `valor_actual`, sin escribir) → RPC con el cliente del caller. Un `valor_invalido` del RPC después de validar el rango sólo puede
  ser la regla cruzada de llaves: 422 con texto fijo («El traslape de llaves no puede superar la mitad de la antigüedad máxima de la
  llave (en días).» / «La antigüedad máxima de la llave no puede ser menor al doble del traslape máximo.»).
- **Simular:** exige `terminal_config_edicion` **y** `terminal_usuario_lectura|edicion` (lista nombres con la RLS del caller; misma razón
  que `/impacto`). Respuesta como §5.4, más `altas_que_caducarian_ya_total` (la lista se corta a 50). «Caducarían ya» = llevan entre
  el valor propuesto y el actual; «ganan plazo» = hoy ya habrían caducado y con el nuevo plazo no; «por caducar» = quedan a ≤ 1 h.
  Usa la columna `usuario_creado_en` de 88_, no la bitácora.
- **Valor vigente:** `valor_vigente` llama a `fn_terminal_config_valor` (service_role) y, si no devuelve un entero válido (89_ sin
  aplicar, forma rara), lee `tiempo.parametro` y, en último caso, usa el defecto; nunca levanta. Lo usan `caduca_en` de las altas, la
  simulación y los jobs.
- **Jobs (scheduler embebido, un solo worker, `max_instances=1`, `coalesce`):** baja por caducidad cada 10 min (lee la variable en cada
  corrida y llama `fn_terminal_baja_por_caducidad(p_horas)`; piso 4 h y tope 50 viven en la función) y purga de rechazos a diario
  04:15 (`fn_marca_rechazada_purgar(p_dias)`, piso de 7 días en la función). Un job que falla se registra con `ERROR` y espera a la
  siguiente corrida; nunca propaga.
- **Valor ilegible (pedido de frontend/security):** cada fila de `GET …/variables` y de `GET …/variables/historial` trae
  `valor_ilegible: bool` (la base tiene un valor corrupto o fuera de rango; en el listado se muestra el defecto, en el historial el
  texto tal cual). La UI lo avisa y **no formatea** ese valor.
- **Simulación que falla:** si no se puede calcular (error de la base, red, timeout) responde **503** `{"detail": "No se pudo calcular
  el impacto; intenta de nuevo."}` con `ERROR` en el log; la UI deshabilita «Confirmar» al acortar mientras no haya un cálculo exitoso.
- **Jobs destructivos (caducidad y purga) con lectura ESTRICTA:** leen la variable con `valor_vigente_estricto`; si hay excepción,
  forma inesperada o un valor ilegible/fuera de rango en la base, registran `ERROR` («no se pudo leer la variable; se omite la
  corrida») y **no llaman** a la función destructiva. El defecto sólo aplica si la clave aún no existe (89_ sin aplicar), con
  `WARNING`. Cada corrida con efecto deja un `WARNING` estructurado (`altas=… plazo_horas=… fecha=…` / `filas=…
  retencion_dias=… fecha=…`) y la de caducidad avisa cuando llega al tope de 50 por corrida. `valor_vigente` (con defecto) queda
  sólo para mostrar (`caduca_en`, simulación).

### 15.2 C8 — como quedó implementado (2026-10-08)

- **Endpoints:** `GET /api/terminales/{id}/anomalias?desde=&hasta=` (10 tarjetas) y `GET …/anomalias/{clave}?desde=&hasta=&limite=&desplazamiento=`
  («ver todos», `limite` 1–200, por omisión 50, `{clave, total, items}`; una falla ahí SÍ es un error, no se aísla).
- **Ventana:** `desde`/`hasta` son días de México (`YYYY-MM-DD`; `desde` 00:00 local, `hasta` hasta el final de ese día sin pasar de
  «ahora»). Por omisión `desde` = hoy − `terminal_anomalias_ventana_dias` y `hasta` = ahora. `hasta < desde` o más de 90 días → 422 fijo.
- **Tarjeta:** `{clave, numero, titulo, estado, nivel, total, ejemplos (≤3), hay_mas, motivo}`. `estado`: `sin_hallazgos` (nivel `null`) ·
  `con_hallazgos` · `no_disponible` (`motivo`: `sin_permiso` | `falta_migracion`) · `error` (total `null`, ejemplos `[]`). Cada tarjeta se
  calcula aislada: una excepción sólo marca esa tarjeta (log `ERROR` con la categoría y el código, nunca el texto de la base).
- **Visibilidad (respuesta a Q6):** las categorías 1 (`marcas_posteriores_a_baja`) y 2 (`picos_de_tasa`) muestran marcas de personas y
  exigen **además `marca_lectura`** (AND con el gate lectura|edición); sin él la tarjeta sale `no_disponible/sin_permiso` y el detalle
  responde 403. Los **nombres** se resuelven siempre con el cliente del caller. `service_role` se usa sólo para `fn_terminal_anomalias`
  (1, 2, 4), `tiempo.marca` (3), `tiempo.marca_rechazada` (5), `tiempo.terminal_credencial` (6, sin hash ni IP) y la variable (8), siempre
  acotado a la terminal de la URL. Nunca salen `persona_id`, `employee_no`, hashes ni IP.
- **Definiciones:** (3) conteo de marcas `deriva` + `sin_sincronizar` de la terminal en la ventana y el `reloj_desfase_seg` actual;
  (5) `total` = suma de rechazos, un ejemplo por código (los 5 códigos del CHECK); (6) `llave_antigua` (> `terminal_llave_max_meses`),
  `traslape_abierto` (≥ 2 llaves vigentes y la más nueva > `terminal_traslape_llave_max_dias`), `cambio_de_ip` (en la ventana),
  `llave_sin_uso` (vigente, sin uso y > 1 día); (7) persona `estado ≠ activo` con alta en `pendiente_alta|esperando_huella|activo`;
  (8) `pendiente_alta`/`pendiente_baja` con más de N h desde `actualizado_en` y `esperando_huella` con más de N h desde
  `usuario_creado_en`, con **N = `terminal_caducidad_alta_horas`** (Q7: se reutiliza la variable); (10) `dias_pendiente` = días desde la
  última versión con `cambio_material`.
- **Job de reconciliación de bajas (condición de salida a producción):** cada 10 min (`max_instances=1`, `coalesce`). Busca personas
  `estado ≠ activo` con altas vivas y llama `fn_terminal_baja_por_persona_inactiva(p_persona_id)` por cada una (tope 200 por corrida). Un
  `-1` (sin autor derivable) **no se reintenta en bucle**: se registra una **ALERTA PERMANENTE** (`ERROR`, con los primeros 8 caracteres
  de cada id) en CADA corrida mientras exista, y la tarjeta 7 del tablero la muestra. Las fallas por persona se cuentan sin propagar.
- **Ajustes de security a C8:** (B1) la reconciliación procesa primero las personas que NO fueron `-1` en la corrida anterior (estado en
  memoria del único worker), así que más de 200 `-1` permanentes no dejan sin atender a las demás; (B2) una alta viva cuya persona ya no
  existe en `personas.persona` (la frontera no tiene FK) se trata como inactiva: el job pide su baja y la tarjeta 7 la muestra con
  `estado_persona: "inexistente"` y sin nombre; (B3) `GET …/anomalias` se sirve de una caché de 45 s por (usuario, terminal, fechas pedidas,
  permiso de marcas), máximo 200 entradas; el gate y la existencia de la terminal se validan antes de leerla; (B4) una prueba recorre las
  diez categorías (tablero y «ver todos») con fuentes que traen `persona_id`/`marca_id`/hash/IP/`employee_no` y afirma que ninguna clave
  de identidad ni secreto aparece en la salida.

### 15.3 Mensajes de rechazo fijos en rutas legadas (cierre del M3 de C0)
Ningún router devuelve ya el texto de la base en un 422: los fallthrough de captura manual de marca, previsualización y armado de tramos
de días, movimientos de saldo, tope legal, cambio de puesto y jornada asignada responden «La operación no se pudo completar; revisa los
datos o avisa a Sistemas.» (o un texto fijo propio de la ruta) y el texto real, saneado y truncado, va sólo al log. Una prueba de regresión
escanea `app/routers/` y falla si reaparece `HTTPException(…, error.message)`. Los casos deliberados del RPC de saldo (`SCJ01`/`SCJ02`) se
conservan como textos fijos del backend.
