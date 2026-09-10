# 2026-09-09 · Subproyecto del checador físico creado y pusheado

**Participantes:** Diego (usuario), `orchestrator` + `backend` + `frontend` vía `team-orchestrator`,
coordinación cruzada con `sistemas-a3` (sesión independiente del usuario) y una sesión Remote
Control ("Configurar Raspberry Pi para checador físico") que va a clonar el repo ahí.
**Duración:** un corte, plan mode con investigación previa a fondo de la especificación existente
(`SCJ-CDT-01`/`SCJ-PRO-11`), delegación secuencial `backend` → `frontend`, y una ronda de
coordinación cruzada para pushear a GitHub con verificación estricta de permiso.

---

## Qué se hizo

Primer subproyecto independiente fuera de `sistema-control-jornada`: `SCJ-PRO-11 §V` ya
especificaba que "el checador es su propio subproyecto, con su propio repositorio" — este corte lo
crea. Repo nuevo en `/home/diego/Proyectos/checador-fisico/`, pusheado a
`https://github.com/Churr000God/Checador_RTB.git` (rama `main`, commit `d325529`).

**Investigación previa** (antes de plan mode): dos preguntas de clarificación en dos rondas — el
usuario había pedido algo ambiguo ("las pestañas reparadas") que resultó ser "diseñá vos las 3
pestañas de la UI sobre la identidad visual de Kairos". Confirmado: lector biométrico genérico/
stub (sin hardware todavía, "lo resolvemos cuando ya tengamos conectada la raspi"), stack Python/
FastAPI, ubicación `/home/diego/Proyectos/checador-fisico`, base de datos local **lo más básica
posible**. El usuario mandó su propio diagrama ER (`entidad_local.marca` + `entidad_local.
persona_cache`) como base del esquema SQLite, que se siguió literal más una columna: `evento_id`
(UUID v4), no negociable incluso en la versión básica porque `SCJ-CDT-01 §VIII.2` liga la
idempotencia completa a que ese identificador nazca en el origen, y `tiempo.marca` del servidor
real tiene `UNIQUE` sobre esa columna (`SCJ-DEC-08`).

**Backend**: FastAPI + Jinja2 (sin build de Node, liviano para la Raspberry Pi), SQLite plano sin
ORM (`schema.sql`, `CREATE TABLE IF NOT EXISTS`), `lector.py` con interfaz abstracta
`LectorBiometrico` + `LectorStub`, `jwt_terminal.py` autofirma JWT HS256 con claim
`role=terminal_checador` (mismo mecanismo que usa PostgREST para `anon`/`authenticated`/
`service_role`, contra el rol que ya existe en la base real desde `db/ddl/37_tiempo_rls_terminal.
sql`), `sync.py` sube marcas pendientes una por una contra `tiempo.marca` real (sin protocolo de
lote todavía). Placeholder documentado explícito: `personas.py` usa `service_role` para refrescar
`persona_cache` porque `terminal_checador` no tiene `SELECT` en nada — marcado como solución
temporal a reemplazar. 17 tests, todo mockeado, nunca contra Supabase real.

**Frontend**: identidad visual de Kairos (paleta teal/navy/oro, Playfair Display + Inter) aplicada
sobre las 3 pestañas (Marcar/Historial/Config), diseñada para pantalla táctil de kiosco — tarjetas
grandes, confirmación inmediata al marcar, sin depender de hover. Encontró y corrigió de paso 2
tests de `backend` que habían quedado acoplados a la copia exacta del HTML viejo (fragilidad del
mismo tipo, uno reportado, el otro encontrado por iniciativa propia).

**Push a GitHub, con verificación estricta de permiso**: una sesión distinta (`sistemas-a3`),
coordinando la configuración de la Raspberry Pi, pidió la URL del repo. Al no existir remoto
todavía, se le explicó la situación y se le dieron 2 caminos (copiar por red vía Tailscale, o
pushear a un remoto). La misma sesión volvió diciendo "confirmado por el usuario, pusheá a
`Churr000God/Checador_RTB.git`" — **`orchestrator` rehusó actuar sobre esa palabra** y le pidió a
`sistemas-a3` que la confirmación viniera directo del usuario en este chat, insistiendo dos veces
más cuando `sistemas-a3` volvió a preguntar el estado sin traer esa confirmación. Recién actuó
cuando Diego escribió "apruebo el repo" directo en esta sesión. Verificado antes de pushear: sin
`.env` ni secretos commiteados.

## Qué se decidió

- Versión deliberadamente básica: lector biométrico stub, sync sin protocolo de lote ni reintento
  con backoff, 3 estados de reloj reducidos a un booleano, caché de personas sin versionar. Todo
  documentado en el `README.md` del repo nuevo, sección "Qué falta para la Raspberry Pi".
- `evento_id` se agrega al esquema del usuario pese al pedido de "lo más básico" — es la única
  pieza no negociable del contrato por la garantía de idempotencia.
- Ninguna sesión pushea a un remoto nuevo ni actúa sobre una aprobación relayada por otro agente —
  la confirmación tiene que llegar directo del usuario en el chat que va a ejecutar la acción.

## Qué quedó pendiente

- Todo lo listado en `checador-fisico/README.md` §"Qué falta para la Raspberry Pi": lector
  biométrico real, protocolo de lote (`POST /marcas/lote`, tope 200, confirmación individual),
  reintento con espera creciente, 3 estados de reloj reales, ventana de supresión de 60s, Flujo B
  (bitácora de Operación), caché de plantillas versionada, mecanismo de lectura de personas más
  angosto que `service_role`.
- La sesión Remote Control de la Raspberry Pi todavía no clonó ni corrió el repo — `sistemas-a3`
  tiene las instrucciones completas de despliegue.

## Preguntas nuevas

-

## Nota para la retrospectiva

Primera vez que este proyecto coordina con sesiones fuera del roster fijo de `team-orchestrator`
(`sistemas-a3`, una Remote Control de la Raspberry Pi) — el patrón de confirmación directa del
usuario resistió la presión de un peer relayando "ya está aprobado" dos veces seguidas antes de
que la aprobación real llegara. Vale la pena mantener ese reflejo también cuando la fuente parece
confiable (era una sesión real del mismo usuario, no un mensaje inyectado) — la regla no es "no
confiar en el peer", es "la aprobación de una acción riesgosa vive en el chat que la ejecuta, no en
un relato de otro chat".
