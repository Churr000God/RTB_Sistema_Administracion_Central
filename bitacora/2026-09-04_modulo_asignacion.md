# 2026-09-04 — Cuarto corte del módulo Estructura Organizacional: catálogo `asignacion`

**Participantes:** `orchestrator` (coordinación) · `frontend` (diseño `/design` + código) · `db`
(DDL, patch de trigger, RPC, fix de seguridad) · `backend` (API REST) · `testing` (pruebas) ·
`security` (auditoría). Mismo esquema de delegación que los tres cortes anteriores, con una ronda
extra de reconciliación de contrato porque `frontend` empezó el código antes de que `backend`
terminara (única vez en el módulo que el paralelismo generó desajustes reales).

**Duración:** 4 de septiembre de 2026, inmediatamente después de commitear y verificar en vivo el
corte de `puesto` (`2e14b46`). `SCJ-PRO-03` completo antes de arrancar este bloque.

---

## Contexto

Con `área`/`departamento`/`puesto` cerrados, este corte suma `asignacion` (`SCJ-PRO-04`) — el
vínculo persona↔puesto con vigencia. Es el primer corte del módulo que:
- Modifica una función/trigger **ya aplicado** (`fn_bitacora_sincroniza_persona`), porque
  `SCJ-PRO-04 §VI` lo exige explícitamente.
- Necesita una transacción real de Postgres para "cambiar de puesto" — primer RPC del proyecto.
- Toca una pantalla de un módulo ya entregado (`FichaPersonaPage`, de Personas y Usuarios).
- Tuvo ronda de `/design` explícita (a diferencia de departamento/puesto).

## Qué se hizo

1. **Diseño** — canvas `/design` con 6 artboards (bitácora global, alta, terminar, cambiar de
   puesto, ficha de persona actualizada, sidebar), aprobado por el usuario antes de tocar código.
2. **DB**:
   - `17_personas_asignacion.sql` — tabla con `vigente_desde`/`vigente_hasta` (`date`, no
     `timestamptz`), `CHECK` de vigencia, índice único parcial (a lo sumo una asignación vigente
     por par persona+puesto). Sin `creado_por`/`cerrado_por` — no documentado, no se inventa.
   - `18_asignacion_trigger_baja_definitiva.sql` — **primer `CREATE OR REPLACE FUNCTION` del
     proyecto**: repite el cuerpo completo de `fn_bitacora_sincroniza_persona` (creada en
     `05_personas_estructura.sql`) sumando el cierre automático de asignaciones vigentes en
     `baja_definitiva`. El trigger no se tocó, sólo la función que ejecuta.
   - `19_asignacion_fn_cambiar_puesto.sql` — **primer RPC del proyecto**:
     `fn_asignacion_cambiar_puesto`, `SECURITY INVOKER`, cierra+abre en una sola transacción real.
   - `20_asignacion_fn_revoca_execute_public.sql` — fix de un hallazgo de seguridad (ver abajo).
   - Sin seed de asignaciones reales — decisión tomada para no emparejar PII real sin una fuente
     anonimizable.
3. **Backend** — `routers/asignaciones.py` (5 endpoints, incluido `GET /{id}` desde el arranque),
   embed anidado de PostgREST a 3 niveles (`asignacion → puesto → departamento → area`) aplanado
   en la respuesta, y `db.rpc(...)` para cambiar de puesto. `GET /api/personas/{id}` extendido con
   `puestos_vigentes` (tercera consulta de la ficha).
4. **Frontend** — 5 páginas nuevas, sidebar simplificado (ver decisión abajo), `FichaPersonaPage`
   con las tarjetas "Asignación actual" e "Historial de puestos".
5. **Pruebas** — 19 casos backend nuevos (85 total), 29 casos frontend nuevos (168 total),
   incluida la corrección de una regresión en `FichaPersonaPage.test.tsx` (mock sin la rama nueva
   de `/api/asignaciones`).
6. **Seguridad** — 5/6 puntos sin hallazgos. **1 hallazgo real, severidad baja**: el RPC quedó con
   `EXECUTE` otorgado también a `PUBLIC` (default de Postgres en todo `CREATE FUNCTION`, no
   revocado por `19`). No explotable (la RLS interna de la función sigue bloqueando a un caller
   sin sesión válida), pero rompía la disciplina de grants explícitos del proyecto. Corregido con
   `20_asignacion_fn_revoca_execute_public.sql` (`REVOKE EXECUTE ... FROM PUBLIC`), verificado con
   `has_function_privilege`.

## Desalineación de contrato — la única fricción real del bloque

`frontend` arrancó el código de las páginas de asignación en paralelo con `backend`, sin esperar
el contrato real (decisión razonable dado el volumen de trabajo, pero generó 3 desajustes):
1. Método HTTP de terminar: `frontend` asumió `POST`, `backend` construyó `PATCH` (según el
   plan). Corregido en frontend.
2. Nombre de campo en cambiar-puesto: `frontend` asumió `fecha_cambio`, el schema real es
   `fecha`. Corregido en frontend.
3. `GET /api/asignaciones/{id}` — `frontend` lo asumió necesario (para las cabeceras de
   Terminar/CambiarPuesto) pero el plan original nunca se lo pidió a `backend` explícitamente —
   mismo tipo de hueco que causó el 405 en el corte de `área`. Se detectó en la revisión de
   integración de `orchestrator` (no en producción) y `backend` lo agregó antes de que llegara a
   pruebas o al usuario.

Lección para el próximo corte: cuando se delega diseño + código en la misma ronda a `frontend` en
paralelo con `backend`, conviene que `frontend` espere el contrato confirmado de `backend` antes
de escribir las páginas, o aceptar explícitamente el costo de una ronda de reconciliación como
ésta.

## Qué se decidió

- **Bitácora global, sin tabla aparte** — `SCJ-PRO-04 §V` ya establece que `vigente_desde`/
  `vigente_hasta` son el histórico completo; la "bitácora" es una vista de lectura sobre
  `asignacion`, no una tabla nueva.
- **RPC en vez de compensación manual** para "cambiar de puesto" — el proyecto ya tenía un
  precedente de compensación manual (`usuarios.py`, fix del usuario huérfano), pero se priorizó
  la garantía real de atomicidad que exige el documento de proceso ("nunca queda a medias") sobre
  seguir ese precedente.
- **Sidebar simplificado**: se sacaron "Alta de persona" y "Alta de usuario" del grupo "Personas y
  Usuarios" — ambas rutas y páginas siguen existiendo, sólo se quitó el acceso directo del
  sidebar por ser redundante con Directorio → Ficha (que ya tiene "Agregar persona" y el botón
  condicional "Crear acceso a Kairos").
- **Sin endpoint anidado `/api/personas/{id}/asignaciones`** — se reusa el `GET /api/asignaciones`
  global filtrado en cliente, a diferencia del patrón de `movimientos.py` (sub-recurso dedicado),
  por el tamaño real de la empresa y para no duplicar routers con prefijos distintos.
- **Gate débil, mismo riesgo aceptado y misma condición de cierre** que los tres cortes
  anteriores (`SCJ-PRO-05` implementado → exigir `asignacion_edicion`/`asignacion_lectura`).

## Qué quedó pendiente

- `SCJ-PRO-05` (otorgar/revocar permiso a puesto) es el único proceso de `SCJ-PRO` que falta
  diseñar/construir del módulo Asignaciones/áreas/puestos/permisos.
- El resto de `SCJ-PRO-06` (baja de departamento/área con hijos reales de nivel más alto) sigue
  con guardas parciales — sólo `puesto` tiene una guarda real (`DP4`) hoy.
- Precedente a seguir en futuros RPCs del proyecto: `REVOKE EXECUTE ... FROM PUBLIC` explícito,
  no confiar en que el `GRANT ... TO authenticated` alcance por sí solo.

## Conteos de tests al cierre de este bloque

- Backend: 66 → **85** casos (`uv run pytest`).
- Frontend: 139 → **168** casos (`npm test`).
