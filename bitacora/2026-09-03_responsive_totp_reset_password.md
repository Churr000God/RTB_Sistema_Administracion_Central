# Responsive de auth + pantalla TOTP fiel al mockup + fix del 401 al restablecer contraseña

**Participantes:** `frontend` (rol) · plan aprobado por el usuario, coordinado por `orchestrator`;
`security` revisó criterio de C/D; `db` confirmó diagnóstico del 401 y descartó el hallazgo
colateral de `redirect_to`; `testing` corrió la diferencial.
**Duración:** 3 de septiembre de 2026, sesión posterior a `bitacora/2026-09-03_capa_decorativa_auth.md`

---

## Qué se hizo

Tres tareas en serie (A, B, C — más un fix de animación y una tarea D chica sumada durante la
sesión), cada una en su propio commit, con `npm test` en verde antes de avanzar a la siguiente.
Ya mergeadas a `main`: `e6fd63d`, `d9a0895`, `3abe3fb`, `1f45134`, `8c090f1`.

### A — Responsive de las 7 pantallas de auth (`e6fd63d`)

`frontend/index.html` no tenía `<meta name="viewport">` (un teléfono real reportaba ~980px y
escalaba la página) y `tokens.css` no tenía ninguna `@media` en 363 líneas. `AuthLayout.tsx`
reservaba `flex: 0 0 42%` con `padding: 3rem` sin breakpoint — a 375px el panel izquierdo
quedaba en 157px, de los que sólo 61px eran contenido útil.

Se agregó el meta viewport, se reescribió `AuthLayout.tsx` sin ningún `style={{}}` inline (todo
por clases), y se sumó una sección `§layout auth` en `tokens.css` con breakpoints `48rem` /
`64rem` / `80rem`. El split de dos columnas entra recién en `64rem`, no antes, por aritmética:
a 768px el aside al 42% deja 226px útiles tras su padding, mientras la tarjeta necesita 500px en
los 446px restantes del panel — desborda 54px. A 1024px entra con 47px de aire por lado (iPad
landscape). `minmax(20rem, 42%)` en vez de `flex: 0 0 42%` evita que el panel se encoja bajo su
contenido, y `min-width: 0` en `.zona-formulario` es el arreglo real del grid que no se encoge
bajo su min-content.

Como el meta viewport afecta a *todas* las páginas (no sólo auth), se agregó un stopgap
defensivo en páginas internas: `.contenedor-pagina` con padding reducido y `.tabla-desplazable`
envolviendo la tabla de `DirectorioPersonasPage`. El responsive completo de `AppShell` y las
demás tablas (mockups 09–14) queda fuera de alcance a propósito — es su propia tanda de diseño.

### B — VerificarTotp fiel al mockup 03 (`d9a0895`)

`VerificarTotpPage.tsx` usaba un solo `<input maxLength={6}>` donde el mockup pide un casillero
de 6 celdas con temporizador. Se crearon dos componentes nuevos en `frontend/src/components/`
(carpeta nueva):

- `CasilleroCodigo.tsx` — 6 `<input>` reales (no un input oculto con celdas pintadas, para no
  romper el foco visible ni el caret en lectores de pantalla), con auto-avance, Backspace que
  limpia hacia atrás, pegado normalizado y navegación por teclado.
- `TemporizadorTotp.tsx` — anclado al reloj Unix (`30 - (Date.now()/1000 % 30)`), nunca un
  contador propio, para no derivar cuando la pestaña se duerme.

`lib/mfa.ts` centraliza `challenge` + `verify` por separado (no `challengeAndVerify`), para
preservar el contrato que ya testeaba la página. Se arregló también el bug de la insignia con
ícono pero sin texto — mismo bug en `VerificarTotpPage.tsx` y `OlvideContrasenaPage.tsx` —,
reemplazado por `.icono-tarjeta` (el cuadrado teal con escudo del mockup). `VerificarTotpRoute`
ya no se queda colgado en "Cargando…" para siempre si no hay factor: ahora tiene tres estados
(cargando/sin factor/error).

**Fuera de alcance a propósito:** "Confiar en este equipo 30 días" y "Usar un código de
respaldo" — Supabase MFA no tiene device trust ni backup codes.

### C — El 401 al restablecer contraseña (`3abe3fb`)

Diagnóstico: `RestablecerContrasenaPage.tsx` descartaba el objeto `error` de Supabase por
completo. La hipótesis principal —confirmada con logs reales de Auth por el rol `db`— era
`insufficient_aal`: la sesión que nace de un link de recovery es `aal1`, y con TOTP obligatorio
en este proyecto GoTrue no deja cambiar la contraseña sin `aal2`.

Fix: `lib/erroresAuth.ts` nuevo (`registrarErrorAuth`/`mensajeDeErrorAuth`/`esInsuficienteAal`)
con un diccionario cerrado de `error.code`, verificado contra la versión de `@supabase/auth-js`
realmente instalada (2.114.0). `RestablecerContrasenaPage` pasa a una máquina de estados
(`cargando`/`necesita-totp`/`listo`/`guardado`) que detecta el AAL al montar y, si hace falta,
renderiza el paso TOTP embebido (reusando `CasilleroCodigo`/`TemporizadorTotp` de B) antes del
formulario — sin redirect, sin reconsumir el link. Tras guardar con éxito, `signOut({scope:
"others"})` cierra de verdad las demás sesiones (antes el copy lo prometía sin hacerlo).

**Criterio de `security`** (aplicado tal cual): nunca `error.message` crudo en la UI —sólo el
mensaje mapeado del diccionario cerrado, con el código técnico aparte en un `<small>` cuando no
hay mapeo—; `console.error` sí recibe el detalle completo para diagnóstico. `signOut(others)`
se llama de verdad después de que `updateUser` confirme éxito; si falla, se loguea pero no
bloquea la UX (la contraseña ya cambió).

### Fix de animación (`1f45134`)

Un hook de diseño detectó que `.barra-progreso .relleno` animaba `width` (layout thrash). Se
cambió a `transform: scaleX()` + `transform-origin: left`.

### D — Fix del 429 al reintentar pedir el enlace (`8c090f1`)

Hallazgo colateral de la incidencia 5 del QA original ("links vencidos"): la causa real, según
la reconstrucción de `db` con logs de Auth, **no era TTL ni un escáner de correo consumiendo el
link**. Era esto: `OlvideContrasenaPage.tsx` llamaba `resetPasswordForEmail` y descartaba el
resultado por completo. Si el usuario pedía el enlace una segunda vez (creyendo que necesitaba
uno nuevo), Supabase respondía `429 over_email_send_rate_limit` sin generar token nuevo — pero
la página igual mostraba "revisa tu correo". El usuario reabría el único link real, ya
consumido por el primer pedido, y veía "One-time token not found".

Fix: se captura `{ error }`, se loguea con `registrarErrorAuth` y se muestra el mensaje mapeado
(nueva entrada `over_email_send_rate_limit` en `erroresAuth.ts`) en vez de pasar a "enviado".

## Qué se decidió

- Breakpoints `48rem`/`64rem`/`80rem` para las pantallas de auth, con el split de dos columnas
  entrando en `64rem` por la aritmética del panel decorativo, no por preferencia visual.
- TOTP sólo visual en B: sin "confiar en este equipo" ni "código de respaldo" — Supabase MFA no
  los soporta.
- Diccionario cerrado de `error.code` en `erroresAuth.ts`: nunca `error.message` crudo en la UI
  (decisión de `security`).
- `signOut({scope: "others"})` real tras guardar la contraseña, no sólo el copy (decisión de
  `security`).
- **No se implementa un listener global de `PASSWORD_RECOVERY` en `App.tsx`.** Se investigó
  durante la sesión como posible defensa en profundidad (el patrón estándar de Supabase para
  cuando el link no aterriza en la ruta esperada), pero `db` confirmó que el supuesto problema
  de `redirect_to` que motivó la pregunta era un artefacto de cómo `testing` invocó
  `generate_link` en su prueba de diagnóstico (mandó `redirect_to` en el body JSON en vez de
  como query param — GoTrue lo ignora silenciosamente). El flujo real de producción
  (`resetPasswordForEmail` del SDK, el que usa `OlvideContrasenaPage`) ya aterriza correctamente
  en `/restablecer-contrasena`, confirmado con logs reales. Sin bug real detrás, el usuario
  decidió no sumar código adicional.

## Qué quedó pendiente

- Responsive completo de `AppShell` y las páginas internas (mockups 09–14, incluida la decisión
  de diseño para las tablas) — sólo quedó el stopgap de `.tabla-desplazable`.
- QA visual real a 320/375/768/1024/1280px: bloqueado en esta sesión porque
  `mcp__claude-in-chrome__resize_window` no baja de ~922px de viewport en este entorno (mínimo
  del window manager) y `computer screenshot` daba timeout. Se verificó por otras vías (chequeo
  de `scrollWidth`/`clientWidth` en el ancho disponible, matemática de breakpoints al escribir
  el CSS, smoke funcional de las rutas sin sesión real) pero no hubo barrido visual pixel a
  pixel contra `qa/capturas/`.
- Migrar `window.location.href` a `useNavigate` — decisión ya tomada de dejarlo para otra tanda.
- Checklist "distinta de tus 3 contraseñas anteriores" del mockup 05 — sin historial de
  contraseñas en el modelo actual.

## Preguntas nuevas

- Ninguna abierta — la pregunta sobre el listener de `PASSWORD_RECOVERY` se cerró en la misma
  sesión al confirmarse que no había bug real detrás.

## Nota para la retrospectiva

Primera vez que el frontend usa una máquina de estados explícita para una pantalla de auth
(`RestablecerContrasenaPage`), en vez de sólo booleans sueltos. Buen candidato para mencionar en
`SCJ-TRZ-01` como patrón a repetir si aparecen más flujos con AAL condicional.
