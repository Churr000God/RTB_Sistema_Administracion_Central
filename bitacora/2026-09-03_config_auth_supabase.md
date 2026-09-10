# 2026-09-03 — Configuración de Supabase Auth para SCJ-PRO-01/02

- **TTL del access token: 3600s → 900s (15 min).** Hecho y confirmado (recargando el dashboard,
  el valor persiste en 900). Acota la ventana de un JWT ya emitido tras una suspensión
  (`SCJ-PRO-02`, JWT es stateless).
- **"Enforce single session per user": NO se pudo activar.** El proyecto está en plan Free —
  Authentication → Sessions muestra el bloque completo de "User Sessions" (incluye este toggle,
  "Time-box user sessions" e "Inactivity timeout") deshabilitado con el mensaje "Configuring user
  sessions is only available on the Pro Plan and above". Se intentó el click igual y se confirmó
  que no cambia de estado — no es un error de la sesión, es un límite real del plan. **Pendiente de
  decisión del usuario:** subir a Pro, o dejar esta mitigación fuera de alcance por ahora (el TTL
  de 15 min y la RLS de `SCJ-PRO-02` ya cierran la mayor parte del riesgo sin esto).
- **Site URL**: estaba en el default `http://localhost:3000` (no `5173`, que es el puerto real del
  frontend Vite de este plan) — corregido a `http://localhost:5173`.
- **Redirect URLs**: no había ninguna URL en la lista (`No Redirect URLs`) — se agregó
  `http://localhost:5173/**` (wildcard, cubre todas las rutas del frontend en desarrollo). Sin esto,
  `resetPasswordForEmail`/la invitación hubieran redirigido al Site URL a secas, sin llegar a
  `/restablecer-contrasena` ni `/completar-invitacion`.
- **Plantilla de invitación**: no se tocó el cuerpo del template (Authentication → Emails →
  Templates pide configurar SMTP propio para editar asunto/cuerpo, fuera de alcance de este task).
  El link de invitación por default de Supabase ya usa `{{ .SiteURL }}` más el token — con el Site
  URL corregido a `5173`, el link cae en el frontend correcto sin necesidad de tocar la plantilla.

Verificado a mano: no se pudo probar "login desde dos navegadores" porque la función está
bloqueada por el plan — queda sin verificar hasta que se resuelva la decisión de arriba.
