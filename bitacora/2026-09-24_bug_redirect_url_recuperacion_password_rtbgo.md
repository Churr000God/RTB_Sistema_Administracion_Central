# 2026-09-24 · [SCJ-OPS] — Redirect URL de Supabase Auth no honrado en RTBGO (dev), workaround aplicado

**Participantes:** orchestrator (sesión directa, sin equipo)
**Duración:** una sesión larga, resuelto con workaround manual

---

## Qué se hizo

Se dio de alta un usuario de prueba nuevo en `sistema-control-jornada` (proyecto académico,
comparte el proyecto Supabase `RTBGO` — `main`, org `Churr000God` — con este repo en modo dev),
asignado al puesto con los 16 permisos, y se le mandó "Crear acceso a Kairos" (invitación real por
correo, `taruadas@gmail.com`, dispositivo externo). El link de invitación redirigió a
`http://localhost:5173` en vez del servidor de pruebas remoto (`74.208.253.210:8081`), con
`error_code=otp_expired`.

Diagnóstico paso a paso, con evidencia directa (no adivinado):

1. **Faltaba el origen remoto en Redirect URLs** de Supabase (Authentication → URL Configuration)
   — sólo tenía `http://localhost:5173/**`. Se agregó `http://74.208.253.210:8081/**`. El dashboard
   lo guardó sin problema.
2. **Aun así, el link seguía cayendo a `localhost`.** Se probó llamando directo a
   `auth.admin.generate_link` (Admin API, `service_role`, sin pasar por correo) con distintos
   `redirect_to` apuntando al servidor remoto — bare host, con `/`, con path, con el wildcard
   literal — **todos** volvieron con `redirect_to=http://localhost:5173` en la respuesta, es decir,
   el servidor de Auth ignora la entrada nueva de la allowlist a pesar de que el dashboard la
   muestra guardada. Se probó también quitar y volver a agregar la entrada (por si era caché) y
   esperar ~20s entre intentos — mismo resultado. Como control: el mismo llamado con
   `redirect_to=http://localhost:5173/...` (la entrada vieja) sí se respeta exacto — el mecanismo
   funciona en general, falla específicamente para la entrada nueva.
3. **Hallazgo aparte, independiente del bug de arriba:** el primer link de invitación se quemó
   antes de que el tester humano hiciera clic — `last_sign_in_at` en el usuario de Auth quedó con
   un timestamp *anterior* al clic real reportado por el tester, consistente con que Gmail (u otro
   escáner de seguridad) pre-visita/consume los links de un solo uso de los correos antes de que la
   persona los abra. Esto es independiente del bug de redirect y puede afectar cualquier invitación
   real a una cuenta `gmail.com`, no sólo pruebas.

## Qué se decidió

- No se tocó código de `alta_usuario`/`OlvideContrasenaPage` — el problema es de configuración de
  la plataforma Supabase, no del código de la app (mismo patrón de este repo: no confundir "bug de
  código" con "bloqueo/config externa", ver
  `bitacora/2026-09-22_verificacion_bloqueo_cloudflare_resuelto.md`, que documentó un caso similar
  — bloqueo de red de Cloudflare, no bug de código — para un problema distinto: ese era sobre
  *egress* (el backend no podía llegar a Supabase), este es sobre el *redirect de vuelta al
  navegador* después de un link de correo. Dos causas distintas, mismo patrón de diagnóstico.
- Workaround usado para destrabar la prueba de hoy, sin depender del bug: se generó el link de
  recuperación con `redirect_to` apuntando a `localhost:5173` (que sí funciona), se le pasó al
  tester **directo, no por correo** (evita el consumo por escáner), y al fallar la conexión en
  `localhost`, se le pidió cambiar sólo el host en la URL resultante (que ya trae el token de
  sesión válido en el `#hash`) por el del servidor remoto — el intercambio de token final es
  100% client-side, no vuelve a pasar por la validación de `redirect_to` del servidor. Funcionó.
- Para destrabar el acceso real de esa cuenta de prueba hoy mismo: se fijó una contraseña
  directamente vía `auth.admin.update_user_by_id` (Admin API, no SQL crudo sobre `auth.users`) y se
  le compartió al usuario para dársela al tester. Login directo, sin pasar por invitación/reset.

## Qué quedó pendiente

- **Antes de tocar nada más en este repo o en `sistema-control-jornada`, en la próxima sesión de
  pruebas verificar si el proyecto Supabase real de la empresa (cuenta `sistemas@refacrtb.com.mx`,
  producción real) tiene el mismo problema.** Ese proyecto ya tiene la IP del túnel/VPN configurada
  en la allowlist desde hace más de una semana — probar ahí:
  - Alta de usuario (invitación real) desde esa IP.
  - "¿Olvidaste tu contraseña?" (recuperación) desde esa IP.
  Si en ese proyecto el redirect sí funciona con una entrada de más de una semana de antigüedad, y
  hoy en `RTBGO` una entrada de minutos de antigüedad no funciona, la hipótesis más probable pasa a
  ser **propagación/caché lenta del lado de Supabase** (minutos u horas, no segundos) en vez de un
  bug estructural con IPs literales — mismo patrón que el bloqueo de Cloudflare de la bitácora del
  22 de septiembre, que también tardó días en resolverse solo. Si en cambio el proyecto real
  también falla pese a la antigüedad, hay que abrir ticket con soporte de Supabase con evidencia
  concreta (los `generate_link` de control ya armados en esta sesión sirven de repro).
- No se investigó si el hallazgo de Gmail pre-visitando/consumiendo links de un solo uso afecta
  invitaciones reales ya enviadas a usuarios `gmail.com` de este proyecto — vale la pena revisarlo
  aparte, es independiente del bug de redirect.
- No se tocó `CLAUDE.md` de este repo con estos hallazgos — sólo esta bitácora, a la espera de
  confirmar si el problema es real/estructural antes de promoverlo a gotcha documentado.

## Preguntas nuevas

- ¿El proyecto Supabase real de la empresa tiene el mismo comportamiento con Redirect URLs nuevas,
  o sólo pasa en `RTBGO` (dev)?
- Si es propagación lenta: ¿cuánto tarda realmente? (la de Cloudflare tardó días — no asumir que
  "minutos" es suficiente la próxima vez que se agregue una URL nueva a la allowlist de cualquiera
  de los dos proyectos).

## Nota para la retrospectiva

Segunda vez en el historial combinado de estos dos repos que un problema que *parece* de código
(redirect a la URL equivocada, invitación que nunca llega) resulta ser una combinación de
configuración de plataforma externa + comportamiento de terceros (Gmail) fuera del control de la
app — y de nuevo se resolvió diagnosticando con llamadas directas a la API (`generate_link` de
control) en vez de adivinar por el síntoma en el navegador. Vale la pena, la próxima vez que se
agregue una Redirect URL nueva a cualquiera de los dos proyectos Supabase, probarla con
`generate_link` antes de asumir que ya quedó lista para usarse en un flujo real.
