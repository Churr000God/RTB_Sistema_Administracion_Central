# 2026-09-07 · Módulo Parámetros de Tiempo — Tope legal y Días festivos

**Participantes:** Diego (usuario), `orchestrator` + equipo de 6 especialistas (`backend`/
`frontend`/`db`/`testing`/`security`/`devops`) vía `team-orchestrator`.
**Duración:** una sesión larga, en modo Plan (`ExitPlanMode`) para las dos pantallas nuevas.

---

## Qué se hizo

**Auditoría previa** (a pedido del usuario, antes de tocar código): revisión del plan de
implementación del subsistema Tiempo (`docs/07-procesos/PLAN_IMPLEMENTACION_TIEMPO.md`) contra lo
realmente construido. Confirmó que los 8 procesos `SCJ-PRO-07` a `14` sí están completos, pero
`tiempo.parametro`/`tiempo.dia_festivo`/`tiempo.tope_legal` (tablas de configuración que existen
en el DDL desde `02_tiempo.sql`) nunca tuvieron pantalla ni endpoint propio — se consumían sólo
internamente (triggers, batches). También confirmó que `patron_semanal`/`tramo`/
`clasificacion_de_tiempo`/`movimiento_de_saldo` son *por diseño* side-effects de otros procesos,
no faltantes. El usuario decidió construir las pantallas de configuración una por una.

**Pestaña "Tope legal"** (primera del módulo "Parámetros" nuevo en el sidebar): edición como
vigencias versionadas (no un valor único) — `POST /api/tope-legal` vía RPC transaccional
`tiempo.fn_tope_legal_crear_vigencia` (`db/ddl/59_*.sql`, mismo patrón que
`fn_jornada_asignar_renovar`, diálogo de confirmación si hay que cerrar la vigencia activa) y
`GET /api/tope-legal` para el historial. Segunda parte, más compleja: `GET
/api/tope-legal/exceso-semanal?semana_de=<lunes>`, tabla de personas que superan el tope en una
semana dada. La regla de negocio se refinó dos veces con el usuario en el camino:
1. Primero: comparar horas *reales* trabajadas (no el patrón contractual) contra `maximo_semanal`,
   excluyendo semanas con algún día `abierto`/`bloqueado` (semana completa, no parcial).
2. Después el usuario aclaró que `maximo_extra` (el otro tope de la tabla) también debía
   evaluarse, cruzando con `tiempo.clasificacion_de_tiempo.tipo` — quedaron 3 comparaciones
   independientes por persona/semana: `supera_semanal` (horas `ordinario` vs `maximo_semanal`),
   `supera_extra` (horas `extra` vs `maximo_extra`), `supera_combinado` (`ordinario+extra` vs
   `maximo_semanal+maximo_extra`). Horas `reposicion` se calculan pero no participan en ninguna
   comparación (pagan una deuda previa, no son carga de trabajo nueva). El agente de diseño
   encontró y corrigió un caso de test imposible que yo mismo había pedido ("combinado sin que
   ningún individual se dispare" — matemáticamente no puede pasar) y lo reemplazó por uno válido.
   Documentado como decisión de negocio nueva en `SCJ-DEC-10`.
3. Decisión de arquitectura: el endpoint usa `get_service_client` para *todo* el acceso a datos
   (`tope_legal`, `dia`, `tramo`, `personas.persona`), nunca `get_caller_client` — `tiempo.dia`/
   `tiempo.tramo` tienen RLS real (`dia_lectura`/`tramo_lectura`) hoy acoplada a los mismos
   puestos que `tope_legal_lectura` pero sin garantía estructural de seguir acoplada; con
   `get_caller_client` este reporte de cumplimiento legal podría devolver "nadie supera el tope"
   por RLS silenciosa en vez de por ser cierto. Mismo patrón que ya usaba `corridas_batch.py`.

**Pestaña "Días festivos"** (segunda del módulo): CRUD simple sobre `tiempo.dia_festivo` — sin
migración DDL nueva (tabla, RLS deny-all y permisos ya existían). Alta libre (permite catálogo
retroactivo), baja restringida a `fecha > hoy` (**primer `@router.delete` del proyecto**, `<=` no
`<` — el festivo de hoy tampoco se borra, 422 nunca 403). Dos vistas: Lista (con filtros de
nombre/año/mes/fecha exacta, todo client-side sobre un único `GET` sin query params — catálogo
chico, mismo criterio que las páginas de Excepciones/Ausencias) y Calendario (Mensual y Semanal,
con un "ancla" compartido entre ambas). El calendario mensual es el primero del proyecto —
`frontend/src/lib/calendario.ts` arma la grilla de semanas completas cubriendo el mes (incluye
relleno de meses adyacentes), reusando `lunesDeLaSemana` de `semanaIso.ts`.

**Incidente real durante la investigación del bug 422** (antes de las dos pantallas, mismo día):
al reproducir un 422 en la asignación de jornada al administrador, `backend` corrió el RPC de
asignación *directo contra la BD real* (vía `psql`, no contra datos sintéticos) para depurarlo.
Eso cerró la jornada vigente real del administrador (`tiempo.jornada_asignada.id 6`,
`vigente_hasta` pasó de `NULL` a una fecha) e insertó una fila de prueba (borrada después).
`backend` intentó revertir el `UPDATE` de la fila 6 pero el permission classifier se lo bloqueó
dos veces. `orchestrator` **rehusó** ejecutar la reversión en nombre de `backend` (sería
"permission laundering" — rodear una denegación de otra sesión) y lo escaló al usuario, quien
autorizó y `orchestrator` corrió el `UPDATE` de restauración directamente. El bug 422 original
resultó ser transitorio (no se reprodujo después). Ver gotcha nuevo abajo.

## Qué se decidió

- Tope legal: 3 comparaciones independientes (semanal/extra/combinado), horas reales no
  contractuales, reposición excluida de las 3 — `docs/03-decisiones/SCJ-DEC-10_*.md`.
- Días festivos: alta sin restricción de fecha, baja sólo futura estricta, sin filtros
  server-side (todo client-side).
- Ningún agente corre queries de escritura/RPC directo contra la BD real de Supabase para
  "probar" o "reproducir" un bug — usar mocks/tests, o pedir aprobación explícita del usuario
  antes de tocar datos reales fuera de una migración DDL versionada.

## Qué quedó pendiente

- Módulo Parámetros: falta "Movimiento de saldo" (tercera pantalla mencionada por el usuario) —
  sesión futura, "una a la vez".
- Ninguna pregunta nueva quedó abierta en `SCJ-PRA-01` — todas las ambigüedades de negocio se
  resolvieron con el usuario en el camino (ver `SCJ-DEC-10`).

## Preguntas nuevas

-

## Nota para la retrospectiva

Primera vez que se usó modo Plan (`ExitPlanMode`) combinado con `team-orchestrator`: exploradores
en paralelo (agentes `Explore`) para levantar hechos del repo, un agente `Plan` para diseñar, y
recién con el plan aprobado por el usuario se delegó a las sesiones reales `db`/`backend`/
`frontend`. Sirvió para blindar decisiones de negocio no triviales (el caso matemáticamente
imposible que el propio diseñador detectó) antes de que llegaran a código.
