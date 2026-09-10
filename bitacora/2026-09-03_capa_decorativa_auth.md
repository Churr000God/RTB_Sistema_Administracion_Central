# Capa decorativa de los mockups en las 5 pantallas de auth

**Participantes:** `frontend` (rol)
**Duración:** 3 de septiembre de 2026, sesión puntual post-QA de auth (`bitacora/2026-09-03_qa_auth_backend.md`)

---

## Qué se hizo

Réplica fiel de la capa decorativa de `diseno_paginas/personas/01-05` (mockups Kairos) en las
5 pantallas de auth ya funcionales (`LoginPage`, `VerificarTotpPage`, `Configurar2FAPage`,
`OlvideContrasenaPage`, `RestablecerContrasenaPage`). Cambio sólo visual/UX — ninguna lógica de
negocio ni contrato con backend/Supabase Auth se tocó. Se sumó `lucide-react` como única
librería de íconos del proyecto (ver `CLAUDE.md`, sección Stack).

- Íconos en campos (correo, candado) y toggle mostrar/ocultar contraseña con ícono de ojo.
- Ícono de reloj junto al wordmark "Kairos" en `AuthLayout`.
- Tarjeta de error con título + ícono + contador de intentos en `LoginPage`, con bloqueo
  temporal de 15 minutos tras 5 intentos fallidos (client-side, no hay rate-limit en backend).
- Badges de estado: "Paso 2 de 3 · Seguridad" en `Configurar2FAPage`, "Enlace verificado" en
  `RestablecerContrasenaPage`.
- Medidor de fuerza de contraseña con checklist en tiempo real (largo, mayús/minús, número o
  símbolo) en `RestablecerContrasenaPage`; sube `minLength` de 8 a 12 para que coincida con lo
  que el checklist muestra.
- Texto de ayuda "Escribe a Recursos Humanos" en `LoginPage` y `OlvideContrasenaPage`.
- Flechas en botones primarios.

Commits: `beadea0` (feature) y `c480a3f` (doc, menciona `lucide-react` en `CLAUDE.md`). Ya
mergeados y pusheados a `main` antes de esta nota — el árbol de código no se toca acá, sólo se
cierra el registro pendiente.

## Qué se decidió

- No replicar el casillero de 6 dígitos en `VerificarTotpPage` — fuera del pedido puntual de
  esta sesión.
- No replicar el checklist "distinta de tus 3 contraseñas anteriores" en
  `RestablecerContrasenaPage` — no verificable sin historial de contraseñas del backend (no
  existe ese dato en el modelo actual).
- No replicar el temporizador en vivo del código TOTP en `Configurar2FAPage`/`VerificarTotpPage`
  — fuera del pedido puntual de esta sesión.
- Subir `minLength` de contraseña de 8 a 12 para que el formulario sea consistente con el
  checklist visible (evita mostrar un requisito que el `<input>` no exige).

## Qué quedó pendiente

- Las 3 réplicas no hechas (casillero TOTP, checklist de contraseñas anteriores, temporizador en
  vivo) — si algún mockup posterior o QA las pide explícitamente, hace falta sesión aparte.
- El bloqueo de 15 minutos tras 5 intentos fallidos es sólo client-side (no persiste ni se
  valida en backend/Supabase) — evaluar si hace falta server-side antes de considerar el flujo
  de login "duro" ante fuerza bruta.
- QA manual de estas 5 pantallas contra los mockups no se corrió en esta sesión (fue
  implementación directa guiada por los mockups, no verificación pixel a pixel).

## Preguntas nuevas

- ¿El bloqueo temporal de 15 minutos amerita reforzarse server-side, o alcanza con el mitigante
  client-side para el alcance académico del proyecto?

## Nota para la retrospectiva

Primera vez que el proyecto usa una librería de íconos (`lucide-react`) — antes el frontend era
sólo CSS/SVG inline. Buen candidato para mencionar en `SCJ-TRZ-01` si se documenta la evolución
de dependencias del frontend.
