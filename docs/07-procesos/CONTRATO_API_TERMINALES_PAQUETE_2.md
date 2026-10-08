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
- **`resumen`** se calcula sobre **todas** las altas de la terminal (no sólo la página).
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
- El texto es **texto plano**; el frontend lo muestra como texto (no HTML). Se devuelve siempre completo (≤4 000 ×
  pocas versiones). Cliente del caller (policy `terminal_consentimiento_select_lectura`).

### 3.2 `GET …/consentimiento/impacto?cambio_material=true|false`

Para el panel de publicar (cifra «cuántas quedarían pendientes»), calculada **antes** de publicar:

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
| cualquier otro | 500 genérico | — |

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
- **El backend manda el `nivel`** (respuesta al pedido 5): 1 y 7 → `atender`; 2, 3, 4, 5, 6, 8, 10 → `revisar`; 9 →
  `informativo`; `null` cuando `total` = 0. El frontend sólo lo pinta.
- **Categorías sin fuente / con fallo:** `no_disponible` si la fuente aún no existe (p. ej. antes de aplicar 84_ para la 5)
  y `error` si la consulta falla; ambas con `total: null` y `ejemplos: []`.
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
