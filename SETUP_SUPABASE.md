# Configuración manual del dashboard de Supabase — RTB-CRM-APP

Checklist operativo para dejar el proyecto de Supabase de **Refacciones Tomás Badillo, S.A. de
C.V.** listo para este repo. Es para seguirse en orden, de arriba hacia abajo — cada paso asume
que el anterior ya se hizo. Nadie más que quien tiene acceso al dashboard puede completarlo:
ninguna sesión de IA tiene las credenciales.

Fuente: plan de migración (`okey-ahora-ya-casi-wobbly-crystal.md` §2.1). Ver también `CLAUDE.md` y
`README.md` §"Cómo levantar el proyecto" para cómo se usan estas variables una vez llenas.

---

## 0. Antes de empezar

- [ ] Confirmar que el proyecto de Supabase de RTB ya existe (Project Settings → General → nombre
      del proyecto, referencia `<PROJECT_REF>.supabase.co`).
- [ ] Confirmar que el DDL (`db/ddl/*.sql`) **todavía no se aplicó** contra este proyecto — los
      pasos 3 y 4 de abajo van *después* de aplicar el DDL (§2.2 del plan), no antes.

## 1. Credenciales de API — `Project Settings → API`

- [ ] Copiar **Project URL** → va en `.env` (`SUPABASE_URL`) y `frontend/.env`
      (`VITE_SUPABASE_URL`).
- [ ] Copiar **`anon` key** → `.env` (`SUPABASE_ANON_KEY`) y `frontend/.env`
      (`VITE_SUPABASE_ANON_KEY`).
- [ ] Copiar **`service_role` key** → sólo `.env` (`SUPABASE_SERVICE_ROLE_KEY`). **Nunca** en
      `frontend/.env` ni en ningún archivo versionado.
- [ ] **Si el proyecto nació con el sistema de keys nuevo** (se ven `sb_publishable_…` /
      `sb_secret_…` en vez de JWT largos que empiezan con `eyJ`): ir a **Legacy API keys** y
      habilitarlas. `supabase-py` (el cliente que usa `backend/`) espera las JWT clásicas — con
      sólo las keys nuevas, el backend arranca pero falla en el primer request real.

## 2. Cadena de conexión para DDL — `Project Settings → Database`

- [ ] Copiar la cadena del **Session pooler**, puerto **`:5432`** (no el Transaction pooler,
      `:6543` — ese cuelga el `psql` usado para aplicar el DDL, ver gotcha de `CLAUDE.md`).
      Usarla como `DATABASE_URL` sólo para el DDL manual (`psql`/SQL Editor) — el backend en
      runtime no lee `DATABASE_URL`.

## 3. Aplicar el DDL

- [ ] Correr `db/ddl/*.sql` en orden (ver §2.2 del plan) contra el Session pooler del paso 2.
      **No continuar a los pasos 4+ de esta lista hasta que el DDL completo termine sin error.**

## 4. Exponer los esquemas — `Integrations → Data API → Settings → Exposed schemas`

- [ ] Agregar `personas` y `tiempo` a la lista de esquemas expuestos.
      **Va después del DDL, no antes** — el DDL trae el `GRANT` (`08_*.sql`/`38_*.sql`), pero
      exponer sin `GRANT` falla igual que `GRANT` sin exponer. Hacen falta los dos.

## 5. URLs de autenticación — `Authentication → URL Configuration`

- [ ] **Site URL**: `http://localhost:5173`
- [ ] **Redirect URLs**: `http://localhost:5173/**`
      (agregar también `http://localhost:8080/**` si se va a usar el entorno `prod` local)
- [ ] Cuando exista un dominio público real de la app, agregarlo aquí también — recordar
      actualizar `FRONTEND_URL` en `.env` al mismo tiempo (acepta varios orígenes separados por
      coma).

## 6. Duración de sesión — `Authentication → Sessions`

- [ ] **Access token (JWT) expiry: `900`** segundos. Decisión tomada, no el default de Supabase —
      ver `bitacora/2026-09-03_config_auth_supabase.md` del repo académico.

## 7. Segundo factor — `Authentication → Multi-Factor Authentication`

- [ ] Habilitar **TOTP**. Sin esto, `/configurar-2fa` falla en runtime sin un error obvio en la
      UI — el enrolamiento del usuario base (paso 10) lo necesita.

## 8. SMTP corporativo — `Authentication → Emails → SMTP Settings`

- [ ] Activar **Enable Custom SMTP**.
- [ ] **Host**: `mail.refacrtb.com.mx`
- [ ] **Port**: `587` (STARTTLS)
- [ ] **Username**: `sistemas@refacrtb.com.mx`
- [ ] **Password**: `<contraseña de la cuenta SMTP — no va en ningún archivo del repo>`
- [ ] **Sender email**: `sistemas@refacrtb.com.mx`
- [ ] **Sender name**: `RTB` (o el nombre que se quiera ver en el "De:" del correo)
- [ ] Enviar un correo de prueba desde el propio dashboard (botón de test, si el proveedor lo
      ofrece) antes de seguir al paso 9.

## 9. Límite de envío de correos — `Authentication → Rate Limits`

- [ ] Subir **"Rate limit for sending emails"** por encima del default (**2 correos/hora**). Con
      SMTP propio no hay motivo para dejar el límite bajo de Supabase — las invitaciones de
      usuarios se cortan en silencio (sin error visible) al tercer usuario si se deja el default.
      Valor sugerido: `<definir según volumen esperado de altas/recuperaciones — no hay un número
      fijado por el plan, ajustar con margen>`.

## 10. Plantillas de correo — `Authentication → Emails → Templates`

> Sólo editable una vez que el SMTP propio del paso 8 ya está guardado.

- [ ] **Invite user**: pegar el contenido de `frontend/emails/invitacion.html`. Asunto en
      español (ej. "Invitación a RTB — completa tu acceso").
- [ ] **Reset password**: pegar el contenido de `frontend/emails/recuperar_contrasena.html`.
      Asunto en español (ej. "Recuperación de contraseña — RTB").
- [ ] Confirmar que ambas plantillas conservan `{{ .ConfirmationURL }}` — es lo que el HTML de
      este repo espera para armar el link.

## 11. Llenar los `.env` locales

- [ ] `.env` (raíz): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (paso 1),
      `FRONTEND_URL` (paso 5).
- [ ] `frontend/.env`: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (paso 1), `VITE_API_URL`,
      y los 4 `VITE_CONTACTO_*` (ver `frontend/.env.example` para los valores de RTB ya
      precargados como referencia).
- [ ] Confirmar con `git status` que ninguno de los dos `.env` quedó en seguimiento de git.

## 12. Verificación end-to-end

Antes de dar por cerrada la configuración, correr al menos:

- [ ] `./scripts/desplegar.sh dev levantar` — bootstrapea el usuario base sin error.
- [ ] Login con el usuario base → `/configurar-2fa` → enrolar TOTP → cerrar sesión → reentrar pasa
      por `/verificar-totp`.
- [ ] `/olvide-contrasena` con un correo real → llega el correo con el HTML propio de RTB (no el
      default en inglés de Supabase) → el link cae en `/restablecer-contrasena`.
- [ ] `/usuarios/nuevo` sobre una persona de prueba → llega la invitación por el mismo SMTP.

Ver la sección "Verificación end-to-end" del plan de migración para la lista completa (incluye
pruebas de RLS/permisos que no dependen de esta configuración de dashboard).
