# QA de mockups del módulo Personas y Usuarios (07-10, 14) + fidelidad visual 11-13

**Participantes:** `orchestrator` (coordinación) · `backend` (B1/B2/B3) · `db` (DB1) · `frontend`
(07/F/08/09/14/contactos/10 + fixes) · `testing` (QA e2e) · `security` (revisión del guard de
sesión) · plan aprobado por el usuario en sesión previa.
**Duración:** 3-4 de septiembre de 2026 (arrancó el 3, cerró el 4)

---

## Contexto e inventario inicial

El QA manual pantalla por pantalla contra los 14 mockups de `diseno_paginas/personas/` nunca se
había corrido antes de mergear el módulo a `main` (decisión explícita registrada en `CLAUDE.md`
desde el 3 de septiembre). Inventario al arrancar esta tanda:

- **01-06 y 11-13**: implementados, pero 11/12/13 nunca tuvieron una pasada de fidelidad visual.
- **07** (error de credenciales): fusionado inline en `LoginPage`, pero incompleto — el panel
  decorativo nunca cambiaba de copy con el error.
- **08** (cuenta suspendida): stub de 10 líneas **inalcanzable de verdad** — nada redirigía ahí y
  el backend no exponía si una persona estaba suspendida; una persona suspendida logueaba bien y
  veía un directorio vacío en vez de un aviso.
- **09** (directorio) y **10** (ficha): esqueletos básicos, sin fidelidad al mockup.
- **14** (bitácora de movimientos): no existía — ni ruta ni componente.

## Decisiones del plan (D1-D9, no re-litigadas durante la ejecución)

- **D1** — `GET /api/sesion` usa `service_role`, no el cliente del caller: la policy
  `solo_caller_activo` de `personas.usuario` también bloquearía a un caller ya suspendido
  consultándose a sí mismo — el mismo síntoma que el endpoint existe para diagnosticar. Lee una
  fila indexada exclusivamente por el `auth_user_id` verificado del token, nunca por un parámetro
  de la request. Excepción documentada a la regla de `deps.py`.
- **D2** — La identidad del caller se resuelve con `supabase.auth.get_user(token)` (valida firma y
  expiración contra GoTrue), no decodificando el JWT localmente.
- **D3** — El nombre del autor de un movimiento se resuelve con una segunda consulta batcheada en
  el backend, no con embedding de PostgREST.
- **D4** — El FK de `registrado_por` no puede fallar: `fn_caller_activo()` exige que el caller ya
  tenga fila en `personas.usuario` antes de dejarlo insertar en la bitácora.
- **D5** — Filtrado/búsqueda/métricas del directorio: 100% client-side (volumen de proyecto
  académico; una segunda petición real habría roto el test que mockea un solo `Response`).
- **D6** — `baja_definitiva` y "usuario sin persona" también van a `/cuenta-suspendida`, con copy
  distinto vía `?motivo=`.
- **D7** — La inmutabilidad real de la bitácora (revoke + policies + trigger) entra en esta tanda.
- **D8** — El fallo del endpoint de sesión es fail-open: si `/api/sesion` no responde, se loguea y
  el flujo sigue normal — es UX, el control de seguridad real sigue siendo la RLS de Postgres.
- **D9** — La consulta de sesión va antes de la bifurcación MFA tras un login exitoso — no tiene
  sentido pedir TOTP a alguien que va a terminar bloqueado.

## Backend (B1 → B2 → B3)

- **B1** (`4f8cba2`): `deps.py` gana `CallerIdentity`/`get_caller_identity`; `GET /api/sesion`
  nuevo, con el criterio de D1/D2. Devuelve `acceso_permitido` y `motivo_bloqueo`
  (`suspension`/`baja_definitiva`/`sin_persona`/`sin_usuario`/`None`).
- **B2** (`92c2748`): `fecha_baja` expuesta en `PersonaOut` (la columna ya existía en el DDL, sólo
  no se exponía) — usada por la métrica "Bajas del mes" del directorio (09).
- **B3** (`43678e4`): `POST /movimientos` guarda `registrado_por` (D4); `GET` resuelve
  `registrado_por_nombre` (D3) y expone `documento_ref`, antes nunca expuesto.
- **Fix tardío** (`ff87109`, durante el QA e2e): `GET /api/personas/{id}` crasheaba con 500 para
  una persona sin fila de expediente — `tipo_contrato`/`documento_ref` pasaron a nullable en
  `PersonaConExpediente`. Frontend se actualizó en el mismo lote (ver más abajo).

## db (DB1)

`db/ddl/09_personas_bitacora_inmutable.sql` (`e7b8950`, aplicado y verificado el 4 de
septiembre): `REVOKE UPDATE, DELETE` sobre `personas.bitacora_movimiento_persona` a
`anon`/`authenticated`; policy `FOR ALL` reemplazada por `FOR SELECT`+`FOR INSERT` explícitas;
trigger `BEFORE UPDATE OR DELETE` que aborta la operación (alcanza incluso a `service_role`,
que salta RLS pero no el `REVOKE`). Confirmado que `UPDATE`/`DELETE` fallan de verdad y que
`trg_bitacora_sincroniza_persona` sigue disparando tras el cambio de policies. Con esa
confirmación, la tarjeta "Registro inmutable" del mockup 14 se sumó a `BitacoraMovimientosPage`
(`ef461fb`) — antes había quedado condicionada a esta confirmación, para no mentir en la UI.

## frontend — las 7 tareas

1. **07** (`e4f09cb`) — Panel decorativo de `LoginPage` cambia título/bajada con el error; campo
   de contraseña marcado inválido (`.campo-con-icono.invalido`) con `aria-invalid`/
   `aria-describedby`; hint "Distingue mayúsculas y minúsculas."; link de recuperación en la
   misma línea que su label; placeholder en el campo.
2. **F** (`813317e`) — Fidelidad visual de 11/12/13. La skill `/design` pedida en el plan resultó
   ser para publicar canvases nuevos de Claude Design, no para revisar fidelidad de código
   existente — se hizo la comparación manualmente (documentado en
   `qa/REPORTE_QA_personas.md`). Aplicado: fieldsets con ícono, rejilla de campos, migas,
   controles segmentados/tarjetas seleccionables vía `:has(input:checked)`. Confirmado ahí mismo
   el bug de `AppShell` faltante en `CambiarEstadoPage` (mismo caso que 10, ver abajo).
3. **08** (`bdface2`) — Fix funcional real: `LoginPage` consulta `GET /api/sesion` antes de la
   bifurcación MFA (D9); si `!acceso_permitido`, `signOut()` + redirect a
   `/cuenta-suspendida?motivo=X` (fail-open, D8). `CuentaSuspendidaPage` reescrita fiel al
   mockup, copy por motivo.
4. **09** (`4f2fcf4`) — Directorio reescrito: métricas, buscador sin acentos, filtro por estado,
   avatar+badge, estados cargando/error/vacío. Refactor de `.insignia--bloque` (el margin-bottom
   embebido desalineaba badges en tabla).
5. **14** (`3392670` + `ef461fb`) — Pantalla nueva. `lib/movimientos.ts` deriva transiciones
   espejando `fn_bitacora_sincroniza_persona` exactamente, y calcula días en suspensión
   emparejando tramos.
6. **contactos** (`6efaf45`) — Correos de RH/Sistemas/Administración/Dirección configurables por
   `VITE_CONTACTO_*_CORREO`, con fallback si no están seteadas. `CuentaSuspendidaPage` enruta
   `suspension`/`baja_definitiva` a RH y `sin_persona`/`sin_usuario` a Sistemas.
7. **10** (`86d1376`) — Ficha reescrita: RFC/NSS/fecha de nacimiento (ya venían del backend, se
   descartaban), `tipo_contrato` con el enum real, historial resumido a 3 movimientos con link a
   la bitácora completa.

## Los 3 bugs reales que encontró testing en el QA e2e

Los únicos tres hallazgos de esta tanda con impacto funcional real (no cosmético):

1. **`AppShell` sin guard de sesión, más una condición de carrera de `StrictMode`.**
   `AppShell.tsx` no chequeaba `/api/sesion` — sólo `LoginPage` lo hacía, al momento del login.
   Una sesión ya bloqueada que navegaba directo a una ruta interna no rebotaba: el sidebar
   cargaba normal y sólo fallaba en silencio `GET /api/personas` (422). Primer fix (`3d0be78`)
   agregó el guard, pero testing lo reprobó con una cuenta real: a veces no redirigía y la sesión
   quedaba deslogueada en silencio. Causa intermedia identificada (`3c23c8e`): `signOut()`
   rechazando (hiccup de red hacia GoTrue) caía al `.catch()` externo de fail-open en vez de
   redirigir. **Causa raíz real**, atada por testing con evidencia de backend 100% determinístico
   por `curl` directo (5/5): `React.StrictMode` monta el efecto dos veces en dev, disparando dos
   `GET /api/sesion` concurrentes — por timing, uno podía salir sin token válido, y el fail-open
   entraba de más, por la carrera, no por una falla real (mismo mecanismo rompía `LoginPage`: la
   misma cuenta aterrizaba a veces en `/configurar-2fa`, a veces en `/cuenta-suspendida`). Fix
   final (`1289efd`): `lib/sesion.ts` con `consultarSesion()`, que deduplica la petición con una
   promesa compartida a nivel de módulo, usada en `AppShell.tsx` y `LoginPage.tsx`. Verificado con
   evidencia de red real (no sólo unitaria): exactamente un `GET /api/sesion` pese al doble-mount.
2. **`AltaUsuarioPage` crasheaba si fallaba el listado de personas.** El fetch para el `<select>`
   no chequeaba `.ok` ni tenía `.catch` — un `GET /api/personas` fallido guardaba el body de error
   como `personas` y el `.map()` del render reventaba con la pantalla genérica de React Router.
   Fix (`3c23c8e`): mismo patrón que `DirectorioPersonasPage` (estado cargando/listo/error con
   reintentar). Mismo bug, mismo fix, se encontró después en `FichaPersonaPage` (`45f2d8f`) —
   ahí se quedaba colgada en "Cargando…" para siempre en vez de crashear, pero el defecto de
   origen (sin `.ok`/`.catch`) era idéntico.
3. **`GET /api/personas/{id}` 500 para una persona sin expediente.** Bug de backend
   (`ff87109`), cerrado en paralelo con el fix de frontend de `FichaPersonaPage`.

## Qué se decidió

- No implementar un listener global de `PASSWORD_RECOVERY` en `App.tsx` (evaluado el 3 de
  septiembre): el supuesto problema de `redirect_to` que lo motivó era un artefacto de cómo
  `testing` invocó `generate_link` en su prueba de diagnóstico, no un bug real.
- La skill `/design` no sirve para revisar fidelidad de código existente contra un mockup — es
  para crear canvases nuevos de Claude Design. Documentado para no repetir el intento.
- El guard de sesión de `AppShell` es UX (D8) — el control de seguridad real sigue siendo la RLS
  de Postgres, nunca al revés.

## Qué quedó pendiente

- Responsive completo de `AppShell` y las tablas internas (mockups 09-14) — declarado fuera de
  tanda desde el diseño de `tokens.css`.
- Roles/autorización real en `POST /api/usuarios` — pendiente ya conocido, no se tocó.
- `DirectorioPersonasPage` dispara 2 `GET /api/personas` reales por el mismo `StrictMode` de dev
  (no deduplicado como `/api/sesion`) — observado durante la verificación del fix del bug 1, no
  es un bug funcional (GET idempotente, sin efectos secundarios, no ocurre en build de
  producción), documentado por si algún día importa.
- Puesto/área/departamento/permiso/asignación siguen fuera de alcance del proyecto a propósito.

## Nota para la retrospectiva

Los 3 bugs reales de esta tanda comparten una lección: "sin `.ok`/`.catch`" y "efecto que no
considera `StrictMode`" son las dos clases de defecto que el QA manual encontró una y otra vez —
ninguna la hubiera atrapado una revisión sólo de código, hicieron falta pasos reales contra una
cuenta real. Vale la pena convertir ambos patrones en checklist explícito para el próximo módulo
(subsistema Tiempo): todo fetch nuevo con `.ok` + `.catch` desde el primer commit, y todo efecto
con llamada de red probado (al menos mentalmente) contra un doble-montaje.
