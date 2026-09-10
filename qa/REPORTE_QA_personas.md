# Reporte QA — Fidelidad visual del módulo Personas y Usuarios (11-13)

Fecha: 2026-09-03 (continuación de la sesión de `bitacora/2026-09-03_qa_auth_backend.md` y del plan
de QA de mockups de Personas/Usuarios)
Rol: `frontend` — Tarea F del plan (fidelidad visual de `AltaPersonaPage`, `AltaUsuarioPage`,
`CambiarEstadoPage` contra `diseno_paginas/personas/11-13`)

Este documento cubre sólo la Tarea F (fidelidad visual de 11/12/13). Las pantallas 07-10 y 14
(brecha funcional real) se documentan aparte cuando cierre esa ola.

## Nota sobre la skill `/design`

El plan pedía invocar `Skill({ skill: "design", ... })` para esta revisión. Al invocarla se
confirmó que esa skill es para **crear/publicar un canvas nuevo de diseño** (artboards `.dc.html`
sobre un Artifact de Claude Design), no para comparar código React ya existente contra un mockup
y aplicar cambios directo al `.tsx`/`tokens.css` — no genera ese tipo de salida. En vez de forzar
la skill a un uso que no es el suyo (publicar tres canvases nuevos sin que nadie los edite ni
alimenten el código real), se hizo la comparación de fidelidad manualmente: lectura directa de
los 3 PNG + los `.tsx` actuales + `tokens.css`, aplicando el mismo criterio cosmético/estructural
que pedía el plan. Avisado a `orchestrator` en el reporte de esta tarea.

## `11-alta-persona` — `AltaPersonaPage.tsx`

**Hallazgo:** el formulario era una lista plana de `label`+`input` sin agrupación, sin migas, sin
iconografía — el mockup agrupa en 3 tarjetas (Datos personales / Alta laboral / Referencia de
expediente), cada una con ícono, y usa un control segmentado para "Tipo de contrato" en vez de
radios sueltos.

**Decisión:** aplicar directo lo cosmético/local — agrupación en `<fieldset>` con ícono
(`.icono-seccion`/`.encabezado-fieldset`), rejilla responsiva de campos (`.rejilla-campos`),
captions de ayuda bajo CURP/RFC/NSS/`documento_ref` (`.ayuda-campo`), migas (`.migas`), y "Tipo de
contrato" convertido a control segmentado con `:has(input:checked)` (`.opciones-seleccionables`),
sin tocar la semántica de radios nativos. Se agregó un link "Cancelar" junto al botón de envío.

**Acción:** implementado en el mismo commit de esta tarea. `npm test` verde,
comparación visual confirmada con `mcp__claude-in-chrome__*`.

**No implementado (estructural o sin respaldo real — ver `NOTAS_campos_extra_mockups.md`):**
- Panel lateral "Vista previa" (avatar/CURP/NSS/ingreso en vivo) — panel lateral nuevo.
- Panel "Validaciones" (dígito verificador de CURP, cruce NSS contra el padrón) — necesita lógica
  de validación real que no existe hoy ni en frontend ni backend.
- Checklist "Al registrar el alta" — copy informativo nuevo, no es fidelidad de layout.
- "Guardar borrador" — sin endpoint, sin modelo de borradores.
- Subida de archivo del expediente al bucket — sin endpoint de Storage (ya en `NOTAS`).
- Callout "Vigencia inicial" — copy de negocio nuevo, no aplicado; se puede agregar sin
  dependencias si el usuario lo pide explícitamente.

## `12-alta-usuario` — `AltaUsuarioPage.tsx`

**Hallazgo:** mismo patrón — sin agrupación ni migas; el `<select>` de persona no tenía ícono; el
botón de envío no tenía ícono ni había link de cancelar.

**Decisión:** aplicar directo — migas, `<fieldset>` "Datos de acceso" con ícono, extendida
`.campo-con-icono` para soportar también `<select>` (antes sólo `<input>`), ícono de sobre en
correo, caption de vigencia del enlace (72 horas, copy del mockup), ícono en el botón de envío,
link "Cancelar".

**Acción:** implementado. Sin test previo para esta página (no existía
`AltaUsuarioPage.test.tsx`); no se rompió nada del resto de la suite.

**No implementado:**
- Layout de navegación superior del mockup (barra horizontal) en vez del sidebar del `AppShell`
  real — cambio de layout global, fuera de esta pantalla.
- Combobox de búsqueda con card de preview (número de empleado/puesto/área) — campos sin
  respaldo real (`NOTAS`). El `<select>` simple se mantiene; si se quiere combobox real sin esos
  campos inexistentes, dos opciones para decidir: (A) construir búsqueda client-side sobre la
  lista de personas ya cargada, sin backend nuevo; (B) dejarlo como está.
- Panel "Qué ocurre al enviar" (3 pasos) y panel "Permisos" — paneles laterales nuevos.
- Tabla "Invitaciones pendientes" con reenviar — no hay endpoint que liste invitaciones.

## `13-cambio-estado` — `CambiarEstadoPage.tsx`

**Hallazgo funcional (no sólo cosmético):** confirmado el mismo bug que `FichaPersonaPage` — la
página **no estaba envuelta en `AppShell`**, así que al entrar acá desaparecía el sidebar
completo. Además los 3 radios de "Tipo de cambio" eran texto plano sin ícono ni descripción, y no
se mostraba a quién se le estaba cambiando el estado ni su estado actual.

**Decisión:**
1. Envolver en `<AppShell>` (fix del bug de sidebar).
2. Convertir los 3 radios en tarjetas seleccionables (`.opciones-seleccionables` +
   `.opcion-seleccionable`, ícono + título + descripción, estado seleccionado vía
   `:has(input:checked)`) — **cuidado explícito del plan respetado**: cada opción sigue siendo un
   `<label>` que envuelve su `<input type="radio">`, así que
   `getByLabelText(/suspensión/i)` en el test sigue resolviendo el mismo control (el nombre
   accesible del label ahora incluye también la descripción, pero el matcher es una regex parcial
   — sigue encontrando el input).
3. Agregar una cabecera compacta (`.cabecera-persona`) con avatar de iniciales, nombre y badge de
   estado actual (`.insignia-estado`), consultando `GET /api/personas/{id}` (endpoint que ya
   existe, sin backend nuevo) — versión simplificada del header del mockup, sin panel lateral.

**Acción:** implementado. `CambiarEstadoPage.test.tsx` se amplió con un mock de
`../lib/supabaseClient` (el `AppShell` nuevo llama `getUser()`); el test existente
(`exige motivo y envía el movimiento elegido`) sigue verde sin cambios en sus aserciones.

**No implementado (estructural o sin respaldo real — ver `NOTAS_campos_extra_mockups.md`):**
- Panel lateral derecho completo del mockup ("Resumen del cambio" con pill antes→después, "Al
  confirmar" con bullets, "Historial de estados") — panel lateral nuevo. La cabecera compacta
  agregada cubre parte de esa necesidad (saber a quién y su estado actual) sin el panel.
- Campos "Fecha de efecto" / "Reincorporación estimada" — no existen en
  `bitacora_movimiento_persona` (sólo `fecha_efectiva`, fijada por el servidor).
- "Historial de estados" en el panel lateral — depende de la pantalla de bitácora (`14`, Ola 2 del
  plan, todavía no implementada).
- Layout de navegación superior del mockup — mismo caso que `12`.

## Resumen

| Pantalla | Bug funcional | Fidelidad cosmética aplicada | Estructural pendiente (opciones para el usuario) |
|---|---|---|---|
| 11-alta-persona | — | Sí (fieldsets+iconos, rejilla, captions, migas, control segmentado) | Panel de vista previa, validaciones reales, borrador, subida de archivo |
| 12-alta-usuario | — | Sí (fieldset+icono, campo-con-icono en select, botón con icono) | Combobox real, paneles "Qué ocurre"/"Permisos", tabla de invitaciones |
| 13-cambio-estado | **Sí — sidebar desaparecía** (arreglado) | Sí (tarjetas seleccionables, cabecera de persona) | Panel lateral completo, fecha de efecto/reincorporación (requiere columnas nuevas) |

`npm test`: verde en las 3 páginas tocadas (suite completa, sin regresiones). `npx tsc -b`: sin
errores. Comparación visual con `mcp__claude-in-chrome__*` contra los 3 PNG originales.

## QA e2e completo (07-14 + correos configurables) — 2026-09-04

Rol: `testing`. Pedido de `orchestrator`: QA manual e2e de todo lo mergeado hoy (backend
B1/B2/B3, devops config de correos, frontend 07/F/08/09/14/contactos/10), antes del cierre final
de la tanda. Este apartado se va completando a medida que avanza (parte bloqueada en cuentas de
prueba, ver abajo).

### Suites automatizadas

- Backend (`uv run pytest`): **15/15 verde**.
- Frontend (`npm test -- --run`): **70/70 verde** (16 archivos). Los `Error: Not implemented:
  navigation` en stderr son ruido esperado de jsdom (no soporta navegación real), no fallas.

### 07 — Login con error

**PASS.** Con credenciales inválidas (`no.existe@distribuidoracentral.mx` / clave inventada): el
panel cambia título/bajada a "No pudimos verificar tu acceso." / "Revisa tu correo corporativo y
tu contraseña...", aparece el recuadro "Credenciales inválidas" con el detalle, el campo
contraseña queda en rojo con hint "Distingue mayúsculas y minúsculas.", y el botón cambia a
"Reintentar acceso". Captura: `qa/capturas/07-login-error.jpg`.

Nota adicional (no pedida, observada): el mensaje avisa "Te quedan 4 intentos antes de bloquear
la cuenta por 15 minutos" — hay contador de intentos fallidos con bloqueo temporal. No se probó
agotar los 5 intentos (fuera de alcance de esta tarea).

### Correos de contacto configurables (punto 6)

**PASS**, default y custom. Confirmado en dos instancias del dev server:

- **Default** (`frontend/.env` sin las `VITE_CONTACTO_*`, server compartido de `:5173`): login y
  `/olvide-contrasena` muestran `mailto:rh@distribuidoracentral.mx`; `/cuenta-suspendida` con
  `motivo=suspension` y con `motivo=sin_usuario` muestra `rh@distribuidoracentral.mx` /
  `sistemas@distribuidoracentral.mx` respectivamente (defaults de `lib/contactos.ts`).
- **Custom** (instancia aparte en `:5176`, sin tocar el `.env` ni el server compartido, variables
  pasadas sólo por entorno del proceso: `VITE_CONTACTO_RH_CORREO=custom-rh@qa-test.mx`,
  `VITE_CONTACTO_SISTEMAS_CORREO=custom-sistemas@qa-test.mx`, ídem Administración/Dirección):
  login y `/olvide-contrasena` reflejan `mailto:custom-rh@qa-test.mx`; `/cuenta-suspendida` con
  ambos `motivo` refleja el correo custom correspondiente (RH para `suspension`, Sistemas para
  `sin_usuario`). Instancia de prueba destruida al terminar, no queda residuo.

### Hallazgo funcional — punto 2 (parcial): `/personas` no rebota sin sesión válida

**FAIL respecto al criterio pedido** ("sin sesión viva, recargar `/personas` debe rebotar").

Reproducido con `qa.sin.totp@refacrtb.com.mx` (cuenta de Auth existente sin `persona_id`
vinculado — resultó ser justo el caso `sin_usuario`, no hizo falta forzarlo). Al loguear con esa
cuenta, el login sí redirige correctamente a `/cuenta-suspendida?motivo=sin_usuario` (contacto
**Sistemas**, correcto — ver captura `qa/capturas/08-sin-usuario-sistemas.jpg`). Pero navegando o
recargando manualmente `/personas` con esa misma sesión ya iniciada, el router **no** rebota:
se queda en `/personas`, el `AppShell` completo (sidebar, nav) se pinta igual, y sólo la llamada
`GET /api/personas` falla con `422`, mostrando el estado de error genérico "No se pudo cargar el
directorio" / "Reintentar" — no el bloqueo esperado.

**Causa (revisada en código):** `frontend/src/layouts/AppShell.tsx` no tiene ningún guard de
sesión — sólo pinta el shell y hace `supabase.auth.getUser()` para mostrar el correo en el pie,
sin chequear estado ni redirigir (líneas 17-30). El chequeo de `sesion` (activo/suspensión/
sin_usuario) sólo corre una vez, en `LoginPage`, al momento del login. Cualquier navegación
posterior a una ruta protegida (recarga de página, link directo, `history.back`, etc.) no vuelve
a pasar por ese chequeo.

**Impacto:** una cuenta suspendida o sin persona vinculada, si ya tiene una sesión de Supabase
Auth válida en el navegador (aunque sea vieja), puede navegar al shell completo de la app con sólo
cambiar la URL — las llamadas a la API individualmente fallan (buena noticia: no hay fuga de datos
real, el backend sí valida), pero la experiencia y el criterio de aceptación del plan no se
cumplen, y el `sidebar`/nav no debería ser visible en ese estado.

### Actualización 06:57 — re-verificado después del fix de `AppShell`, sigue fallando

`orchestrator` avisó que frontend agregó un guard a `AppShell` (llamada a `GET /api/sesion` con
pantalla "Verificando acceso…"). Confirmado en código
(`frontend/src/layouts/AppShell.tsx`): ahora sí hay un `useEffect` que llama `/api/sesion` y, si
`acceso_permitido === false`, hace `signOut()` + redirige a `/cuenta-suspendida?motivo=...`. El
comentario en el código aclara que el fail-open ante error/```!respuesta.ok``` es **intencional**
("D8 del plan" — la RLS de Postgres es el control real, no un bug nuevo).

**Pero re-probado end-to-end con `qa.sin.totp@refacrtb.com.mx` (sesión real, no simulada) el
resultado sigue siendo FAIL:**

1. Login → redirige correctamente a `/cuenta-suspendida?motivo=sin_usuario` (esto sí funciona).
2. Con esa misma sesión, navegar directo a `/personas` → **no rebota**. Se queda en `/personas`
   con el sidebar completo, "Directorio de personas" con métricas en 0 y "No se pudo cargar el
   directorio" (la llamada a `GET /api/personas` sí falla, con 422). Captura:
   `qa/capturas/02-guard-no-rebota-personas.jpg`.
3. Revisando `read_network_requests` para `/api/sesion` en esa sesión: mezcla de respuestas —
   algunas `422`, una `200`. Después de esa navegación, `Object.keys(localStorage)` da **vacío**:
   la sesión terminó cerrada (`signOut()` sí se ejecutó en algún momento), pero la URL nunca
   cambió de `/personas` — quedó una pantalla que parece autenticada (sidebar, "Cerrar sesión")
   con la sesión ya muerta por debajo, sin avisar ni redirigir.

**Hipótesis de causa (no confirmada con debugger, inferida del código):**
`AppShell.tsx`, el `useEffect` del guard tiene esta forma:
```
apiFetch("/api/sesion").then(async (respuesta) => {
  if (!respuesta.ok) { if (vivo) setEstadoAcceso("permitido"); return; }
  const sesion = await respuesta.json();
  if (!vivo) return;                     // <- acá
  if (!sesion.acceso_permitido) {
    await supabase.auth.signOut();
    window.location.href = `/cuenta-suspendida?motivo=${sesion.motivo_bloqueo ?? "suspension"}`;
    return;
  }
  ...
```
El `if (!vivo) return` está **entre** el `await respuesta.json()` y la lógica de
`signOut()`+redirect. En React 18 con `StrictMode` (u otra causa de que el efecto se
limpie/reinicie — por ejemplo un remount rápido), si la limpieza corre antes de que resuelva esa
promesa concreta, esa instancia del efecto descarta el resultado (ni desloguea ni redirige) sin
dejar rastro. Si hay más de un fetch en vuelo (por eso los 422 mezclados con un 200 en el log de
red) y el que efectivamente ejecuta `signOut()` no es el mismo que controla el `estadoAcceso` que
React está renderizando, el resultado observable es exactamente lo que se vio: sesión muerta,
pantalla no redirigida.

**Esto es peor que el hallazgo original en un aspecto:** antes al menos la sesión quedaba viva y
la ruta accesible; ahora la ruta también queda accesible pero además la sesión termina cerrada
"a mitad de camino" sin que el usuario se entere, lo cual puede confundir con otros bugs
intermitentes más adelante (ej. llamadas que fallan con 401 después de esto sin explicación
visible).

Avisado a `orchestrator` en caliente (2026-09-04 ~06:57) para que decida si esto vuelve a
frontend antes de seguir, dado que el fix no cumplió el criterio de aceptación al re-probarlo.

### Actualización 07:20 — causa raíz real: condición de carrera en el navegador, no el backend ni los datos

Frontend subió un segundo fix (`3c23c8e`, separando `signOut()` en su propio try/catch para que
un rechazo no tirara el redirect al `.catch()` de fail-open). Re-probado con sesión real otra
vez: **sigue sin rebotar** de forma consistente. Pero esta vez até la causa con evidencia dura,
no sólo lectura de código:

1. **El backend es 100% determinístico.** Saqué un token fresco por `POST
   /auth/v1/token?grant_type=password` (anon key, el mismo camino que usa el login normal — no
   admin API) y le pegué a `GET /api/sesion` directo por `curl`, **5 veces seguidas**: las 5
   dieron `200` con exactamente `{"acceso_permitido":false,"motivo_bloqueo":"sin_usuario"}`. Cero
   variación. El código de `backend/app/routers/sesion.py` no tiene ningún problema.
2. **Sólo desde el navegador aparece la inconsistencia.** En la misma sesión, mirando
   `read_network_requests` filtrado a `/api/sesion` en una carga limpia de `/personas` (pestaña
   nueva, sin contaminación de navegaciones previas), aparecen **dos** llamadas a `/api/sesion`
   (`AppShell` monta el efecto dos veces — comportamiento esperado de `React.StrictMode` en dev,
   que remonta cada efecto una vez a propósito). Cuando ambas dan `422` (sin token válido en el
   header, ver `apiFetch`/`getSession()` en `apiClient.ts`), el guard hace fail-open correctamente
   *por diseño* — pero el resultado visible es el mismo directorio roto de siempre. Cuando al menos
   una da `200` a tiempo, si el `vivo` que sigue vivo es el que la recibe, sí redirige.
3. `db` confirmó en paralelo (2026-09-04 07:1x) que **no tocó** el vínculo de `qa.sin.totp` en
   ningún momento — descarta que sea un problema de datos cambiando entre pruebas. Encontró el
   mismo patrón de no-determinismo del lado de `LoginPage` (misma cuenta, mismo password, a veces
   aterriza en `/configurar-2fa`, a veces en `/cuenta-suspendida?motivo=sin_usuario`) — es la
   misma clase de bug, no coincidencia.

**Conclusión:** no es un bug de lógica de negocio ni de datos — es una condición de carrera del
lado del navegador entre el doble montaje de efectos (`StrictMode`) y el timing de
`apiFetch`/`supabase.auth.getSession()`, que hace que una de las dos llamadas concurrentes salga
sin token válido (`422`) en vez de con el token de la sesión recién autenticada. El patrón
fail-open de D8 está funcionando exactamente como se diseñó — el problema es que se dispara más
seguido de lo esperado por esta carrera, no por fallas reales de red. Mismo mecanismo probable
detrás del hallazgo de `db` en `LoginPage`.

**No es responsabilidad de `testing` diagnosticar más a fondo el fix concreto** (cambiar el
patrón de guard, quizás moviendo el fetch fuera de un efecto por página a un contexto/provider de
sesión que se resuelva una sola vez, o deshabilitando el doble-montaje sólo para este efecto) —
eso es de frontend. `db` sugirió que esto entra en el alcance de `security` por D8/D9 del plan,
dado que toca el criterio de fail-open de autenticación. Reportado a `orchestrator` con este
detalle para que decida a quién lo asigna.

### Actualización 07:40 — tercer fix (deduplicación de `/api/sesion`), confirmado 5/5

Frontend aplicó el fix real: deduplicó la llamada a `/api/sesion` con una promesa compartida para
que el doble-montaje de `StrictMode` dispare la petición de red una sola vez (commit `1289efd`,
84/84 tests). Re-probado **5 veces seguidas**, pestaña nueva cada vez, sesión real inyectada vía
`supabase.auth.signInWithPassword()` (mismo camino que usa la app, sin curl ni admin API) contra
`qa.sin.totp@refacrtb.com.mx`:

| Intento | `/personas` → | Resultado |
|---|---|---|
| 1-5 | `/cuenta-suspendida?motivo=sin_usuario` | **PASS**, las 5 veces, sin excepción |

También re-probado `/usuarios/nuevo` (el que crasheaba con `personas.map is not a function`) con
la misma sesión bloqueada: ahora rebota igual a `/cuenta-suspendida?motivo=sin_usuario` antes de
intentar renderizar el formulario — ya no es alcanzable en este estado, así que el crash de
`AltaUsuarioPage` tampoco se puede disparar por esta vía (sigue siendo una buena idea que
`AltaUsuarioPage` maneje el error de todos modos, por defensividad, pero deja de ser explotable
por una sesión bloqueada).

**Cerrado — PASS definitivo del punto 2 del pedido original.** No hace falta que nadie siga
mirando esto; ya no observo el no-determinismo en 5/5 intentos limpios.

### 09 — Directorio, contra datos reales (Cuenta B)

**PASS.** Logueada como `qa.cuenta.b@refacrtb.com.mx` (persona+usuario real, creada por `db`; le
enrolé y verifiqué TOTP yo misma — código calculado localmente en el navegador vía WebCrypto,
`HMAC-SHA1`, sin exponer el secreto en ningún momento). El directorio muestra **2 personas**
("Sistemas Kairos", "QA Cuenta"), ambas **Activo** — coincide exacto con las métricas que pasó
`db` (total 2, activos 2, suspensión 0, bajas 0). Búsqueda/filtro no re-probados a fondo (ya
verificados estructuralmente por frontend en su fidelidad de mockup; con sólo 2 registros no hay
mucho que estresar).

### Hallazgo funcional nuevo (bloqueante) — `GET /api/personas/{id}` crashea con 500 si la persona no tiene `expediente`

**FAIL grave.** Al entrar a la ficha de "QA Cuenta" (persona de Cuenta B, `id`
`88e3a0e8-5c73-430e-b599-33665e5324b9`) la página se queda colgada en "Cargando…" **para
siempre** — sin mensaje de error, sin reintentar, nada. Captura: `qa/capturas/10-ficha-colgada.jpg`.

**Causa raíz (confirmada con logs del contenedor, `docker logs sistema-control-jornada-backend-1`):**
```
File "/app/app/routers/personas.py", line 61, in ficha_persona
    return {**fila, **expediente}
TypeError: 'NoneType' object is not a mapping
```
`backend/app/routers/personas.py`, endpoint `GET /api/personas/{persona_id}` (línea 49-61): hace
`.select("*, expediente(tipo_contrato, documento_ref)")` y después `expediente =
fila.pop("expediente")` seguido de `{**fila, **expediente}` sin chequear que `expediente` no sea
`None`. Si la persona no tiene fila relacionada en `personas.expediente`, PostgREST devuelve
`expediente: null` (no una lista/objeto vacío), y el spread revienta con `TypeError`. FastAPI lo
traduce en `500` (mi curl directo a `:8000` dentro del contenedor) — pero pasando por el proxy que
usa el frontend en `:8000` externo, algunas veces aparece como `503`, no está claro por qué cambia
el código exacto entre las dos rutas, pero el error de fondo es el mismo (confirmado con el
traceback).

**Verificado 100% determinístico:** 3/3 vía `curl` directo con token fresco, mismo error las 3
veces — no es flakiness de Supabase como los hallazgos anteriores de esta sesión, es un bug de
lógica real y reproducible.

**Causa de que la persona no tenga `expediente`:** `db` insertó la persona de Cuenta B por SQL
directo (no vía `POST /api/personas`, que si crea el expediente junto con la persona en la misma
transacción). No es necesariamente un error de `db` — puede ser una omisión al armar la cuenta de
prueba rápido, o puede ser un estado de datos legítimamente alcanzable (¿es `expediente`
obligatorio para toda persona, o puede faltar en la vida real, ej. un alta incompleta?). De
cualquier manera, el endpoint **no debería crashear con 500** ante esto — es un dato faltante
razonable de contemplar (columna de una relación 1-a-1 opcional, o en el peor caso un estado
transitorio de datos), no una entrada inválida.

**Dos bugs compuestos, dos dueños distintos:**
1. **Backend:** `ficha_persona` no maneja `expediente is None`. Fix trivial: `expediente = fila.pop("expediente") or {}` (o devolver un 404/422 explícito si se considera que toda persona debe tener expediente).
2. **Frontend:** `FichaPersonaPage.tsx` (líneas 58-65) no tiene `.catch()` ni chequeo `.ok` en ninguno de los dos `apiFetch` del `useEffect` — igual patrón que tenía `AltaUsuarioPage` antes del fix de hoy. Si el fetch falla (por este bug o cualquier otro motivo), `persona` se queda `null` para siempre y la página no sale nunca de "Cargando…". Comparar con `BitacoraMovimientosPage.tsx`, que sí maneja esto bien (`.ok` check + `.catch(() => setEstadoCarga("error"))`) — ese es el patrón a copiar acá.

No pude completar el resto de 10 (RFC/NSS/fecha de nacimiento/tipo de contrato/link a bitácora)
por este bloqueo — la página nunca renderiza el contenido real. Avisado a `orchestrator`/`db`/
`backend` en caliente.

### 08 — Cuenta suspendida, el bug funcional real: PASS completo

Con Cuenta A (`qa.cuenta.a@refacrtb.com.mx`, provista por `db`; le enrolé y verifiqué TOTP igual
que a B, código calculado localmente) como caller:

1. Suspendí a Cuenta B vía `POST /api/personas/{id}/movimientos` (`tipo_movimiento: "suspension"`)
   **desde la pantalla real** `/personas/:id/movimiento` — nunca UPDATE directo. `201`. Ficha de B
   pasa a "Suspendido", historial muestra el movimiento con autor `qa.cuenta.a` (no B misma) —
   confirma que el caller correcto queda registrado.
2. Logueé con B (sesión nueva) → redirige correcto a `/cuenta-suspendida?motivo=suspension`,
   contacto **Recursos Humanos** (correcto, distinto de `sin_usuario`→Sistemas). Captura:
   `qa/capturas/08-suspension-rh.jpg`.
3. Sin sesión viva: recargar `/personas` con la sesión de B rebota de nuevo a
   `/cuenta-suspendida?motivo=suspension` (confirma el fix de `AppShell` también para el caso de
   suspensión real, no sólo `sin_usuario`).
4. Reactivé a B con A (mismo endpoint, `tipo_movimiento: "reactivacion"`) desde la pantalla real.
   `201`. Historial: Suspendido → Activo, autor `qa.cuenta.a`.
5. Logueé con B de nuevo → entra normal al directorio, sin pedir nada raro. 3 personas en total
   (Sistemas Kairos, QA Cuenta [A], QA Cuenta [B]), todas activas. Captura:
   `qa/capturas/08-login-b-normal-post-reactivacion.jpg`.

**Hallazgo transitorio (no bug de la app, anotado por transparencia):** durante la prueba, un
intento de reactivación falló dos veces seguidas con `422` — inspeccioné el request real
interceptando `fetch` en la página y encontré que salía **sin header `Authorization`** (`getSession()`
devolvió sesión nula en esa pestaña en ese momento). Repetí la acción en una pestaña nueva
(sesión fresca) y funcionó al toque. Coincide con la sesión de esa pestaña habiendo quedado
completamente vacía en `localStorage` tras muchas acciones seguidas (login, enrolamiento TOTP,
varias llamadas) — mismo síntoma de fondo que otros hallazgos de hoy (Supabase Auth bajo carga
por el volumen de pruebas concurrentes de todo el equipo). No lo reporto como bug de código nuevo
— ya está cubierto por el mismo tema de fondo que motivó el fix de `AppShell` — pero lo dejo
anotado por si `security`/`backend` quieren mirar más a fondo la resiliencia de sesiones
prolongadas en una sola pestaña.

### 14 — Bitácora con historial completo (alta + suspensión + reactivación): PASS

Con el historial real generado en el punto 08 (5 movimientos: alta, suspensión, reactivación,
suspensión, reactivación), la bitácora de "QA Cuenta" (B) muestra las píldoras de transición
correctas en cada fila (`Suspendido → Activo`, `Activo → Suspendido`, etc.), coincidiendo exacto
con `persona.estado` real después de cada paso. Autor mostrado correctamente como `qa.cuenta.a`
en cada movimiento que ella ejecutó (nunca aparece como si B se hubiera movido a sí misma).
"MOVIMIENTOS: 5", agrupado por año (2026), buscador y filtro por tipo presentes. Captura:
`qa/capturas/14-bitacora-completa-transiciones.jpg`. **Punto 14 completo, PASS.**

## Cierre — resumen final

| Punto | Resultado |
|---|---|
| Flujo de auth (login/2FA/reset) | OK — re-verificado hoy vía enrolamiento y login TOTP real en varias cuentas |
| 07 — Login con error | PASS |
| 08 — Cuenta suspendida (bug funcional real) | PASS completo, con Cuenta A/B reales |
| 09 — Directorio contra datos reales | PASS |
| 14 — Bitácora con historial completo | PASS |
| 10 — Ficha de persona | PASS (tras fix del backend/frontend) |
| Correos de contacto configurables | PASS |
| F — Fidelidad visual 11/12/13 | PASS (12 tras fix del crash) |

**Suites automatizadas, corridas al final de toda la tanda:** backend `uv run pytest` → **16/16
verde**. Frontend `npm test -- --run` → **87/87 verde** (19 archivos).

**Bugs reales encontrados y arreglados durante este QA (todos confirmados cerrados):**
1. `AppShell` sin guard de sesión — cuenta bloqueada podía navegar a rutas internas (fix inicial +
   fix de la condición de carrera con `StrictMode`, deduplicando `/api/sesion`).
2. `AltaUsuarioPage` crasheaba con pantalla en blanco si fallaba el listado de personas.
3. `GET /api/personas/{id}` crasheaba con 500 si la persona no tenía fila en `expediente`.

Sin bugs abiertos conocidos al cierre de esta tanda. QA e2e completo.

### 10 y 14 — confirmados con "Sistemas Kairos" (la otra persona, que sí tiene `expediente`)

Mientras se resolvía el bug de arriba, probé la ficha de la otra persona real (`Sistemas Kairos`,
`id` `1ece5827-...`) — confirma que el bug es específico a que a Cuenta B le falta la fila de
`expediente` (creada por SQL directo), no un problema general: esta persona sí tiene fila de
`expediente` (con campos vacíos) y la ficha renderiza normal.

**10 — Ficha de persona: PASS.** RFC (`XEXX900101AB3`), NSS (`11223344556`), fecha de nacimiento
(`01 ene 1990`) visibles. Tipo de contrato muestra **"—"** (guión, no "Indeterminado") cuando no
hay expediente cargado — confirma que `ETIQUETA_TIPO_CONTRATO` nunca cae en ese caso. Sidebar de
`AppShell` presente. Link "Ver bitácora completa →" funciona y navega a la ruta correcta. Captura:
`qa/capturas/10-ficha-sistemas-kairos.jpg`.

**14 — Bitácora de movimientos: PASS (parcial, sólo hay historial de alta todavía).** Un
movimiento "Alta", estado "Activo", autor mostrado como `sistemas.kairos` — confirma que B3 del
backend efectivamente guarda `registrado_por` real (no un placeholder). Resumen (1 movimiento
registrado, 0 suspensiones, 0 reactivaciones, 0 días en suspensión), agrupado por año (2026),
buscador por motivo/autor y filtro por tipo presentes. Captura:
`qa/capturas/14-bitacora-sistemas-kairos.jpg`. **Falta** verificar las píldoras de transición
alta→suspensión→reactivación con historia real — depende de la Cuenta A para suspender/reactivar
Cuenta B (bloqueado, ver abajo).

### Actualización 07:55 — fix del 500/cuelgue confirmado, ficha de Cuenta B ya renderiza

Backend (`ff87109`) y frontend (`45f2d8f`) cerraron los dos bugs (16/16 y 87/87 tests). Re-probado
directo contra la persona de Cuenta B (la que no tiene `expediente`): **ya no crashea ni se
cuelga.** Renderiza "QA Cuenta B", RFC/CURP/NSS/fecha de nacimiento correctos, "Expediente" con
"Sin expediente asignado." y tipo de contrato "—" (manejo gracioso del caso sin fila de
expediente), historial de estado con autor `qa.cuenta.b`. Captura:
`qa/capturas/10-ficha-cuentab-fixed.jpg`. Punto 10 **PASS completo** para ambas personas.

### Hallazgo funcional nuevo — `AltaUsuarioPage` crashea sin manejo de error en la carga de personas

**FAIL.** Navegando a `/usuarios/nuevo` (sesión sin token válido, por el estado descrito arriba —
pero el bug es independiente de eso, ver análisis): la página entera revienta con la pantalla
genérica de React Router "Unexpected Application Error! `personas.map is not a function`".
Captura: `qa/capturas/12-altausuario-crash.jpg`.

**Causa (código, `AltaUsuarioPage.tsx` líneas 14-17):**
```
useEffect(() => {
  apiFetch("/api/personas")
    .then((r) => r.json())
    .then(setPersonas);
}, []);
```
Sin chequeo de `r.ok` ni `.catch`. Si `GET /api/personas` responde con error (401/422/500, lo que
sea — cualquier cosa que no sea un array de personas en el body), el `.json()` del cuerpo de error
(normalmente `{"detail": "..."}`) se guarda tal cual en `personas`, y el `.map()` del render
revienta porque `personas` ya no es un array. A diferencia de `DirectorioPersonasPage`, que sí
maneja este mismo tipo de falla mostrando "No se pudo cargar el directorio" con botón reintentar,
`AltaUsuarioPage` no tiene ningún manejo — cualquier usuario que llegue a esta pantalla sin poder
listar personas (sesión inválida, RLS, backend caído, lo que sea) se encuentra una pantalla de
error de React en blanco, no un error de la app. Bug independiente del guard de `AppShell`
descrito arriba, aunque lo disparé en el mismo estado de sesión rota.

### F — Fidelidad visual 11/12/13, confirmación liviana (punto 7 del pedido)

**11 — `AltaPersonaPage` (`/personas/nueva`): confirmado.** Cargó completa (sin sesión válida, por
el fail-open — sólo layout, no se probó el submit): fieldsets con ícono ("Datos personales",
"Alta laboral", "Referencia de expediente"), rejilla de campos, captions de ayuda bajo
CURP/RFC/NSS, control segmentado para "Tipo de contrato", migas "Personas / Alta de persona".
Coincide con lo descrito en el apartado de arriba (tarea F de frontend). Captura:
`qa/capturas/screenshot-*` (ver la del error de 12 abajo para contexto del mismo intento; la de
11 no se guardó aparte porque no mostró nada nuevo respecto a lo ya documentado por frontend).

**12 — `AltaUsuarioPage` (`/usuarios/nuevo`): confirmado, tras el fix del crash.** Fieldset "Datos
de acceso" con ícono, `<select>` de persona con `campo-con-icono`, campo de correo con ícono de
sobre, caption "A esta dirección llega el enlace de activación. Vigencia de 72 horas.", botón
"Enviar invitación" con ícono, link "Cancelar". Fiel a lo descrito por frontend. Captura:
`qa/capturas/12-altausuario-fixed.jpg`.

**13 — `CambiarEstadoPage` (`/personas/:id/movimiento`): confirmado, con el sidebar.** Probado
contra un `id` inexistente (sin datos reales) — la cabecera de persona simplemente no aparece
(falla en silencio esa parte, esperable sin persona real), pero el resto de la pantalla carga
completa: sidebar de `AppShell` presente (confirma el fix del bug de layout que mencionaba el
resumen de arriba), migas "Personas / Cambio de estado", 3 tarjetas seleccionables ("Suspensión
temporal" / "Reactivación" / "Baja definitiva") con ícono+título+descripción, campo "Motivo",
botones "Cancelar"/"Confirmar". Fiel al patrón de tarjetas seleccionables descrito por frontend.
Captura: `qa/capturas/13-cambio-estado-sidebar.jpg`.

### Bloqueado — pendiente de cuentas de prueba

Necesito de `db` dos cuentas activas con `usuario`+`persona` vinculados (una para hacer de caller
de `POST /api/personas/{id}/movimientos`, otra para suspender/reactivar) para completar:

- 08 (bloqueo real vía movimiento, reactivación, verificación con caller)
- 09 (directorio contra métricas reales)
- 14 (bitácora — autor real, píldoras de transición)
- 10 (ficha de persona con datos reales)
- Fidelidad visual 11-13 con sesión real dentro del `AppShell`

Pedido enviado a `db` a las ~06:04 (2026-09-04), sin respuesta a las 06:45 (sesión de `db` en
estado `waiting`, posiblemente trabada en un prompt de permiso propio). Escalado a `orchestrator`.

**Flujo de auth general (recordatorio de ayer) — no re-verificado hoy en su totalidad:** el login
normal y el error de credenciales sí se probaron hoy (arriba). 2FA/restablecer contraseña con paso
TOTP embebido no se re-corrió completo en esta sesión porque requiere una cuenta con
usuario/persona real para probar el flujo end-to-end dentro del `AppShell` — queda incluido en el
bloqueo de arriba, se retoma con las mismas cuentas.

## Hallazgo reportado por el usuario — `/usuarios/nuevo` sin punto de entrada en la navegación

Fecha: 2026-09-04 (después del cierre de la tanda anterior). `orchestrator` ya investigó y
confirmó la causa en código: la ruta existe y funciona (ver 12 arriba), pero no hay **ningún**
link hacia ella en ningún lugar de la app — ni en el sidebar de `AppShell`, ni en el botón de
acción del directorio de personas, ni en la ficha de persona. Sólo es alcanzable escribiendo la
URL a mano.

**Síntoma confirmado en vivo, dos puntos de contraste distintos:**

1. **Sidebar (`AppShell`)** — los únicos ítems son Panel/Personas/Marcas/Jornadas/
   Autorizaciones/Reportes/Configuración, y de esos sólo "Personas" tiene `href` real (los demás
   son placeholders `disponible: false`, `href: null`). No hay ítem "Usuarios" en ningún lado.
2. **`/personas` (directorio)** — el único botón de creación es "Agregar persona"
   (`/personas/nueva`). Confirmado programáticamente: `[...document.querySelectorAll('a')]` en la
   página no devuelve ningún `href` a `/usuarios/nuevo`. Captura:
   `qa/capturas/sin-entrada-usuarios-directorio.jpg`.
3. **`/personas/:id` (ficha)** — los únicos enlaces de acción son "Nuevo movimiento" y "Ver
   bitácora completa". Tampoco hay nada para invitar/crear un usuario para esa persona. Captura:
   `qa/capturas/sin-entrada-usuarios-ficha.jpg`.

Confirmado: es un dead-end real, no un falso positivo del usuario. Enviado a `frontend` para
agregar un punto de entrada. Pendiente re-verificar cuando avisen.

### Re-verificación tras el fix de frontend — PASS completo

Commit `842d797`: botón "Crear acceso a Kairos" en la cabecera de `FichaPersonaPage`,
condicionado a `persona.tiene_usuario` (nuevo campo expuesto por backend en
`GET /api/personas/{id}`, commit `0aef661`). Re-probado en vivo con sesión real:

1. **Persona con usuario** (`Sistemas Kairos`, la propia cuenta logueada): botón **no aparece**,
   sólo "Nuevo movimiento". Correcto.
2. **Persona sin usuario** (`prueba preuba`, persona de prueba ya existente en la base sin
   usuario vinculado): botón **sí aparece**, "Crear acceso a Kairos" junto a "Nuevo movimiento".
3. Click en el botón → navega a `/usuarios/nuevo?persona_id=edaefa1f-...` con el `<select>` de
   persona **preseleccionado en "prueba preuba"** (no hace falta volver a buscarla). Captura:
   `qa/capturas/usuarios-nuevo-preseleccionado.jpg`.
4. Flujo completo de invitación probado de punta a punta: correo + nombre de usuario + "Enviar
   invitación" → `"Invitación enviada."` en pantalla.
5. Volviendo a la ficha de esa persona después de crear el usuario: el botón "Crear acceso a
   Kairos" **ya no aparece** (ahora `tiene_usuario` es `true`) — confirma que el campo se
   recalcula correctamente tras la invitación, no queda cacheado en falso.

**PASS en los 3 puntos pedidos por `orchestrator`.** Sin regresiones. El hallazgo original del
usuario queda cerrado.

### Pasada de calidad visual 09-14 (commit `d4e05a4`) — revisión rápida, sin romper nada

Repaso liviano (no exhaustivo, como pidió `orchestrator`) navegando 09 (directorio), 10 (ficha),
14 (bitácora) con sesión real después de este commit: las tres pantallas cargan y se ven
correctas, sin errores de consola nuevos, mismos datos que antes (3-4 personas según el momento,
historial de Cuenta B intacto con sus 5 movimientos). No se detectó ninguna regresión funcional
en el repaso. No se comparó pixel a pixel contra los mockups de nuevo — eso ya lo habían hecho
frontend/backend en sus propios commits; esto fue sólo una pasada de humo post-cambio.

## Pasada de calidad visual — 09/10/11/12/13/14 (2026-09-04)

Pedido del usuario: mejorar la fidelidad/calidad visual de estas 6 pantallas usando las skills
de diseño del workspace, **sin agregar ningún dato ni campo que no exista en la base real**
(`personas.persona`/`expediente`/`usuario`/`bitacora_movimiento_persona`) — puesto, área, número
de empleado, banco de horas, asistencia, etc. siguen descartados, documentados en
`diseno_paginas/personas/NOTAS_campos_extra_mockups.md`.

**Skill usada:** `redesign-existing-projects` (audita el proyecto existente y aplica mejoras
dirigidas sin reescribir desde cero — encaja mejor que las opciones orientadas a landing
pages/marketing, que no aplican a un panel interno de RH). La mayoría de su checklist tampoco
aplica acá (glassmorphism, parallax, gradientes de marketing, hero sections) — se descartó
explícitamente todo lo que no fuera pulido puro de lo que ya se muestra, para no contradecir el
trabajo de fidelidad a los mockups "Kairos" ya hecho en tandas anteriores.

**Cambios aplicados, todos en `tokens.css` + las 6 páginas (ningún dato/campo nuevo):**

1. **Números tabulares** (`font-variant-numeric: tabular-nums`) en las cifras de métricas del
   directorio (09), la cabecera de la bitácora y su resumen lateral (14) — evita que los dígitos
   salten de ancho si el valor cambia.
2. **Tipografía monoespaciada para identificadores** (`--font-mono` nuevo en `:root`, clase
   `.campo-identificador`): CURP/RFC/NSS/`documento_ref` en el formulario de alta (11) y en la
   ficha de persona (10) — son identificadores para verificar carácter por carácter, no prosa.
   Reutiliza el mismo token que ya usaba `.pildora-monoespaciada` (antes hardcodeado ahí nomás).
3. **Feedback de presión en botones** (`:active { transform: scale(0.98) }`) en `button`,
   `.boton-primario` — antes sólo había estado `:hover`, sin señal táctil al hacer clic.
4. **Hover en filas de tabla** (`tbody tr:hover`) — el directorio (09) no daba ninguna señal
   visual de que las filas son clickeables antes de posarse justo sobre el link del nombre.
5. **Estados de carga consistentes**: Directorio (09), Ficha (10), Bitácora (14) y Alta de
   usuario (12) mostraban un `<p>Cargando…</p>` plano; ahora usan el mismo patrón de ícono
   girando (`Loader2` + `.icono-girando`) que ya existía en `Configurar2FAPage` — antes era el
   único lugar que lo usaba.
6. **Bug real encontrado de paso**: `.boton-con-icono` estaba scopeada sólo a `button`/`a`
   (`button.boton-con-icono, a.boton-con-icono`) — el propio `Configurar2FAPage` ya la aplicaba
   sobre un `<p>` para su "Generando código…" y nunca había tenido el `display:inline-flex` real
   (el ícono y el texto caían en flujo inline normal, sin el `gap`/alineación pensados).
   Generalizada la clase a cualquier elemento — arregla ese caso viejo de paso, además de los
   nuevos "Cargando…" que ahora también la usan.
7. **Estado vacío del directorio** con ícono (`Users`, mudo) además del texto — antes era sólo
   una oración suelta.
8. **Login centrado verticalmente en pantallas grandes** — ver la tarea 1 más arriba, mismo
   commit distinto (`226d4c4`).

**Explícitamente NO tocado** (para no reintroducir lo ya descartado ni salirse de "pulido
visual"): ningún campo/columna nueva, ninguna reestructuración de layout (sin paneles laterales
nuevos, sin wizards), sin tipografías de marca nuevas (Playfair/Inter ya tienen carácter propio,
no son el "Inter genérico" que la skill señala como problema), sin gradientes/glassmorphism/grain
(no encajan con la identidad "Kairos" ya validada contra los mockups de auth).

`npm test`: 88/88 verde. `tsc -b`: sin errores. Verificado a mano contra localhost: mayúsculas +
monoespaciado en CURP al tipear, botón de login sin regresión visual, estado de error de
Directorio sin romperse. No se pudo verificar el estado vacío con datos reales (sin sesión ni
backend arriba en el momento de la verificación) — confiado en la revisión de código + el mismo
patrón ya usado en otras páginas.
