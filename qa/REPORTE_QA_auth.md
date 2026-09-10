# Reporte QA — Flujo de autenticación

Fecha: 2026-09-03
Entorno: dev, `http://localhost:5173` (proyecto ya levantado con Docker)
Herramienta: `mcp__claude-in-chrome__*` (extensión Claude en Chrome)
Credencial usada: usuario de prueba (cuenta existente del proyecto, con 2FA/TOTP ya configurado)

Este documento cubre el QA manual del flujo de autenticación descrito en el plan de la sesión
coordinada, contra los mockups de `diseno_paginas/`. Compara lo observado con lo esperable de un
flujo de auth estándar; el contraste fino contra cada mockup queda para frontend.

## Resumen de resultado

| Bloque | Resultado |
|---|---|
| Login (vacío, credenciales inválidas, credenciales válidas) | OK |
| 2FA / verificar TOTP | OK (código dictado manualmente por el usuario) |
| Configurar 2FA (cuenta con 2FA ya activo) | **Hallazgo** — pantalla se cuelga |
| Post-login `/personas` | OK |
| Cerrar sesión | **Hallazgo** — no existe botón de logout en la UI |
| Olvidé mi contraseña (formulario + confirmación) | OK |
| Restablecer contraseña vía link de correo | **Bloqueado** — link llega vencido, ver detalle |
| Verificación final de login con la credencial de prueba | OK (sigue siendo la original, sin cambios) |

## Paso a paso

### 1. `/` — login vacío
Captura: `01-login.png`. Formulario carga correctamente, sin errores en blanco, campos "Correo
electrónico" y "Contraseña" vacíos, botón "Iniciar sesión" habilitado. Sin incidencias.

### 2. `/` — credenciales inválidas a propósito
Captura: `07-error-credenciales.png`. Se probó con un correo y contraseña inventados. La app
responde con el mensaje "Correo o contraseña incorrectos." en un recuadro rojo bajo el campo de
contraseña. Comportamiento correcto — no revela si el problema es el correo o la contraseña
(buena práctica de seguridad).

### 3. Login con la credencial de prueba
Se ingresó el correo y contraseña de la cuenta de prueba. La app redirigió directo a
`/verificar-totp` (la cuenta ya tenía 2FA configurado de antes, no pasó por `/configurar-2fa` en
este flujo).

### 4. `/verificar-totp`
Captura: `03-verificar-totp.png`. Pantalla pide "Código de verificación" con un solo campo y botón
"Verificar". El usuario dictó el código TOTP vigente manualmente (tal como indicaba el plan — no
se adivinó ni se saltó este paso) y el login se completó, redirigiendo a `/personas`. Sin
incidencias en esta pantalla.

### 4b. `/configurar-2fa` (navegación manual, sin completar el flujo)
Captura: `02-configurar-2fa.png`. Por pedido explícito de orchestrator, se navegó manualmente a
esta ruta (con sesión ya iniciada) solo para capturarla contra el mockup, sin interactuar con el
formulario ni tocar el enrolamiento real de 2FA.

**Hallazgo:** la pantalla se queda indefinidamente en el estado "Generando código..." y nunca
llega a mostrar el QR ni el campo para confirmar el código. Se esperó más de 8 segundos sin
cambios. Causa probable: la cuenta ya tiene 2FA activo, y el flujo de enrolamiento no contempla
ese caso (podría estar fallando la llamada que genera el secreto/QR, o el componente no maneja el
estado "ya enrolado"). Requiere revisión de frontend/backend.

### 5. `/personas` (post-login)
Captura: `09-directorio-personas.png`. Carga correctamente el listado de personas con columnas
"Nombre" / "Estado", muestra el registro de la cuenta de prueba como "activo", y el enlace
"Agregar persona". Sidebar completo (Panel, Personas, Marcas, Jornadas, Autorizaciones, Reportes,
Configuración). Sin incidencias visuales.

**Hallazgo aparte (detectado al buscar cómo cerrar sesión):** el ítem "Configuración" del sidebar
no tiene `href` y no navega a ningún lado al hacer clic — es un enlace muerto. Coincide con lo ya
documentado en el plan (no existe ruta `/configuracion` implementada), pero como ítem de UI
visible y clickeable sin feedback, es confuso para el usuario final.

### 6. Cerrar sesión
**Hallazgo:** no se encontró ningún control de "cerrar sesión" en toda la interfaz logueada — ni
en el sidebar, ni dentro de "Configuración" (que no navega). Se tuvo que simular el cierre de
sesión limpiando manualmente `localStorage`/`sessionStorage` vía JavaScript para poder continuar
el flujo de recuperación de contraseña. Este es un gap funcional real: ningún usuario final puede
cerrar su sesión desde la aplicación.

### 6b. `/olvide-contrasena` — formulario
Captura: `04-olvide-contrasena.png`. Formulario simple con campo "Correo electrónico" y botón
"Enviar enlace". Sin incidencias.

### 6c. `/olvide-contrasena` — confirmación de envío
Captura: `04b-olvide-contrasena-enviado.png`. Tras enviar, el formulario se reemplaza por el
mensaje "Revisa tu correo para continuar." Sin incidencias.

### 7. Buzón real — extracción del link de recuperación
El usuario abrió su buzón de correo real en otra pestaña y compartió la URL de su bandeja de
entrada. Desde ahí se ubicó el correo "Restablece tu contraseña — Kairos" (remitente y plantilla
correctos) y se extrajo el enlace del botón "Restablecer contraseña" (apunta al endpoint de
verificación de Supabase Auth con `type=recovery` y `redirect_to` hacia `/restablecer-contrasena`,
como se espera).

### 8. `/restablecer-contrasena` — formulario
Captura: `05-restablecer-contrasena.png`. Al seguir el primer link, redirigió correctamente al
formulario con campos "Nueva contraseña" y "Confirmar contraseña". Visualmente sin incidencias.

### 9. Definir nueva contraseña — BLOQUEADO
Siguiendo la instrucción crítica del plan, se intentó primero conservar la misma contraseña de la
credencial de prueba. La app respondió con un mensaje genérico: "No se pudo actualizar la
contraseña." — comportamiento esperado si Supabase rechaza reusar la contraseña anterior, aunque
el mensaje no distingue esa causa de cualquier otro error.

Se coordinó con orchestrator una contraseña temporal distinta para no quedar bloqueados. Al
intentar guardarla, el navegador reportó en consola `Failed to load resource: the server responded
with a status of 401 ()`. Se investigó la causa pidiendo un **segundo** link de recuperación desde
cero (sin reintentos previos que lo consumieran) y se seguyó apenas llegó:

**Hallazgo (bloqueante para completar el paso 9-10 del plan):** el segundo link, sin haber sido
usado antes, redirige con `#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired`
en el propio hash de la URL — es decir, llega ya vencido/inválido antes de que nadie lo use.
Captura de evidencia: `05c-restablecer-token-expirado.png`.

**Hallazgo adicional, más grave, de frontend:** la página `/restablecer-contrasena` **no lee ni
muestra** ese error del hash de la URL. El formulario se ve idéntico a un link válido — nada le
avisa al usuario que el enlace venció. Esto explica el 401 "silencioso" del intento anterior: el
usuario llena la contraseña y recién al enviar el formulario se entera (con un error técnico sin
contexto) de que el link nunca fue válido. Debería mostrarse un mensaje claro tipo "Este enlace
venció, solicitá uno nuevo" apenas se detecta el error en la URL.

La investigación de la causa raíz (¿TTL de OTP configurado muy corto en Supabase Auth?, ¿algún
sistema de correo/seguridad corporativa pre-visitando el link antes de que el usuario lo abra?)
quedó a cargo de otra sesión del equipo (db), por tocar configuración de Supabase Auth —
fuera del alcance de este QA.

**Resultado:** no se pudo verificar end-to-end el "guardar exitoso" del restablecimiento de
contraseña (paso 10 del plan, captura `05b-restablecer-exito.png` no obtenida) por este bloqueo
externo a la aplicación bajo prueba. La contraseña de la cuenta de prueba **nunca llegó a
cambiarse** — ningún intento de guardado tuvo éxito.

### 11. Verificación final de login
Se confirmó que el login sigue funcionando con la credencial de prueba **original** (nunca se
modificó, dado que ningún intento de restablecimiento tuvo éxito): el formulario aceptó
correo y contraseña y redirigió a `/verificar-totp` con normalidad. No se completó el TOTP en esta
verificación final (no era necesario para confirmar que la contraseña seguía siendo válida).

## Incidencias — resumen para frontend/backend

1. **`/configurar-2fa` se cuelga en "Generando código..."** cuando la cuenta ya tiene 2FA
   configurado. Necesita manejar ese caso (mensaje claro, o redirigir, en vez de spinner infinito).
2. **No existe forma de cerrar sesión** desde la UI logueada. Gap funcional, no solo cosmético.
3. **El ítem "Configuración" del sidebar es un enlace muerto** (sin `href`, no navega). Si la
   funcionalidad está fuera de alcance (confirmado en `CLAUDE.md`), debería no mostrarse o
   mostrarse deshabilitado con alguna indicación, no como un link normal que no hace nada.
4. **`/restablecer-contrasena` no maneja el error de link vencido/inválido** que Supabase Auth
   entrega en el hash de la URL (`error=access_denied&error_code=otp_expired`). Debería detectarlo
   y mostrar un mensaje claro en vez de exponer el formulario normal, que termina en un 401
   confuso al guardar.
5. **Los links de recuperación llegan vencidos** incluso sin usarlos previamente (reproducido dos
   veces). Causa raíz en investigación por el rol `db` (configuración de Supabase Auth, fuera de
   alcance de testing).

## Incidencias de herramienta (no de la aplicación)

Durante toda la sesión la extensión de Claude en Chrome mostró inestabilidad recurrente:
capturas de pantalla que quedaban colgadas en el protocolo CDP tras cambios de estado de la
página (se resolvía reintentando o abriendo una pestaña nueva), y el grupo de pestañas de la
sesión se cayó por completo un par de veces ("Selected Chrome extension disconnected"),
recuperándose solo tras reintentar. No afectó la validez de las capturas obtenidas, pero sí el
tiempo total del QA.

## Capturas incluidas

Todas en `qa/capturas/` (no versionado, ver `.gitignore`):

- `01-login.png`
- `07-error-credenciales.png`
- `03-verificar-totp.png`
- `02-configurar-2fa.png`
- `09-directorio-personas.png`
- `04-olvide-contrasena.png`
- `04b-olvide-contrasena-enviado.png`
- `05-restablecer-contrasena.png`
- `05c-restablecer-token-expirado.png` (evidencia del bloqueo, no estaba en el plan original)

No se obtuvo `05b-restablecer-exito.png` por el bloqueo documentado en el paso 9-10.
