# 2026-09-06 · [ID] — Implementación de los 8 procesos del subsistema Tiempo

**Participantes:** Diego + `orchestrator` coordinando por `SendMessage` a las 6 sesiones
persistentes del equipo (`db`/`backend`/`frontend`/`testing`/`security`/`devops`, roster fijo de
`team-orchestrator`).
**Duración:** una sesión larga, las 4 fases seguidas con checkpoint del usuario entre cada una.

---

## Qué se hizo

Implementación de punta a punta (DB + backend + frontend, RLS real, tests, revisión de
seguridad, prueba de humo contra Supabase real) de los 8 procesos diseñados el 2026-09-05
(`docs/07-procesos/SCJ-PRO-07` a `SCJ-PRO-14`), siguiendo el orden de 4 fases de
`docs/07-procesos/PLAN_IMPLEMENTACION_TIEMPO.md`:

- **Fase 1** — `SCJ-PRO-09` (Asignación de jornada) y `SCJ-PRO-14` (Batch de confianza).
  Primer router/página/RPC de Tiempo del proyecto. Estrena la orquestación compartida de los 3
  batches (`corrida_batch` + APScheduler embebido en el lifespan de FastAPI + botón manual).
- **Fase 2** — `SCJ-PRO-11` (Registro por terminal, sólo verificación — ya estaba implementado
  desde el diseño) y `SCJ-PRO-07` (Captura manual de marca, primer router humano que escribe en
  `tiempo.marca`).
- **Fase 3** — `SCJ-PRO-10` (Corrección de marca) y `SCJ-PRO-08` (Detección de falta), en
  paralelo entre sí (sin dependencia).
- **Fase 4** — `SCJ-PRO-12` (Cierre de día) y `SCJ-PRO-13` (Corte quincenal), las 2 piezas de
  mayor riesgo y de mayor impacto financiero directo del subsistema.

Resultado: `db/ddl/` llega hasta `57_*.sql` (33 migraciones nuevas desde `33` hasta `57`, contando
el catch-up de permisos que ya estaba escrito pero sin aplicar). Backend suma 8 routers nuevos
(`jornada_asignada`, `corridas_batch`, `marcas`, `correcciones`, `ausencias`, `excepciones`,
`banco_de_horas`) + 3 batches (`de_confianza`, `cierre_dia`, `corte_quincenal`) + el scheduler.
Frontend suma 6 páginas nuevas bajo `/tiempo/*`. Backend termina en 212 casos de pytest, frontend
en 316 casos de vitest. 18 commits de dominio a lo largo de las 4 fases (db/backend/frontend por
separado, batcheados por el orchestrator al final de cada fase, mismo criterio que el pase
cross-stack del 2026-09-04).

Fuera de las 4 fases: se corrigió un bug real reportado por el usuario probando desde el celular
vía Tailscale (`crypto.randomUUID` no existe en contexto inseguro — HTTP sin TLS sobre IP) y se
agregó soporte de múltiples orígenes CORS en `FRONTEND_URL` (separados por coma) para poder
trabajar por `localhost` y por Tailscale/LAN al mismo tiempo sin reiniciar.

## Qué se decidió

- **Checkpoint por fase** (4 pausas totales), no por proceso ni corrida completa sin pausas —
  decisión explícita del usuario antes de arrancar, dado el tamaño y riesgo del trabajo.
- **APScheduler embebido en el proceso FastAPI** (no cron externo del contenedor) para los 3
  batches — sin infraestructura nueva, verificado por `devops` que el lifespan de FastAPI
  garantiza un solo scheduler vivo por proceso incluso con `--reload` en dev.
- Cada especialista usa todas sus herramientas/skills antes de implementar (pedido explícito del
  usuario en cada delegación).
- Dejar el rastro sintético inerte de las pruebas de humo (personas/marcas con prefijo `smoke-`)
  en vez de forzar su borrado — varias tablas de Tiempo son inmutables por diseño (sin `DELETE`
  ni para `service_role`), igual que ya pasaba con `bitacora_movimiento_persona` en `personas`.
  Decisión confirmada con el usuario, mismo criterio que el hallazgo de septiembre con `personas`.

## Qué quedó pendiente

- Cómo se resuelve visualmente un día `bloqueado` (paridad impar) — la excepción con `dia_id` se
  crea bien, pero no hay ninguna pantalla que la muestre o resuelva (`ColaExcepcionesPage` filtra
  por `marca_id`). El propio `SCJ-PRO-12 §VI` deja esto explícitamente para cuando el sistema se
  aplique a la empresa real — ya estaba anotado como `SCJ-PRA-01 #14`, no se agregó pregunta nueva.
- Panel de corridas de batch sin selector de fecha para el disparo manual (siempre dispara "hoy")
  — mejora de UX menor, no bloqueante, anotada por `testing` en dos fases distintas.
- Mismo patrón de "fecha sin hora corre un día atrás en timezones detrás de UTC" (bug real
  arreglado en `BandejaAusenciasPage` esta sesión) existe también, sin arreglar, en varias páginas
  de Estructura Organizacional (`AsignacionesPage`, `FichaPersonaPage`, `PermisosPage`, etc.) —
  ahí sólo afecta agrupación/orden, no lo que se muestra en pantalla. Fuera de alcance de esta
  sesión, anotado por `frontend`.
- Fragilidad menor (no un hueco real hoy) en el gate de `excepcion_reapertura`: depende de que
  quien tenga `correccion_edicion` también tenga visibilidad RLS de `tiempo.excepcion` — cierto
  hoy porque los 3 puestos mapeados coinciden, pero no está garantizado si el catálogo de permisos
  se remapea en el futuro. `security` sugirió envolverlo en una función `SECURITY DEFINER`.

## Preguntas nuevas

-

## Nota para la retrospectiva

Segunda vez que un `GRANT ALL` schema-wide (`38_tiempo_permisos.sql`, calcado del patrón ya usado
en `personas`) deja tablas sin ninguna RLS expuestas a `anon` sin login — la primera fue el 4 de
septiembre con las 14 tablas de `tiempo` recién creadas, después otra vez con `tiempo.excepcion`
en Fase 2 cuando su RLS se apagó a propósito para no romper triggers. El patrón que terminó
funcionando: **todo `GRANT ALL` schema-wide nuevo debe ir acompañado, en el mismo corte, de un
inventario explícito de qué tablas quedan con RLS real y cuáles quedan en deny-by-default** — no
alcanza con "ya lo revisé para las tablas que me importaban en el momento" (mismo mea culpa que
`db` se hizo dos veces esta sesión). También segunda vez que un batch/endpoint nuevo necesita un
RPC transaccional después de construirse con inserts sueltos (`fn_ausencia_resolver`,
`fn_corte_quincenal_aplicar_persona`) — la próxima vez que se construya un endpoint que escribe en
más de una tabla relacionada, vale la pena preguntarse desde el diseño si necesita atomicidad real
en vez de descubrirlo en la revisión de seguridad.
