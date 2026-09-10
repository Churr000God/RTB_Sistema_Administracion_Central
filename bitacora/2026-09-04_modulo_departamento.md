# 2026-09-04 — Segundo corte del módulo Estructura Organizacional: catálogo `departamento`

**Participantes:** `orchestrator` (coordinación) · `db` (DDL + seed) · `backend` (API REST) ·
`frontend` (páginas, sin ronda nueva de mockups) · `testing` (pruebas backend+frontend) ·
`security` (auditoría). Mismo esquema de delegación que el corte anterior:
`db → {backend, frontend} → testing → security`, integración final por `orchestrator`.

**Duración:** 4 de septiembre de 2026, inmediatamente después de commitear y verificar en vivo
el corte de `area` (`847fa96`).

---

## Contexto

Con `area` cerrado y funcionando, este bloque suma `departamento` — el segundo catálogo de
`SCJ-PRO-03`, hijo de `area`. Mismo patrón de punta a punta, con `area` como plantilla literal de
código (mejor referencia que cualquier mockup, por eso esta vez no hubo ronda de `/design`).

## Qué se hizo

1. **DB** (`db/ddl/12_personas_departamento.sql`, `13_departamento_migracion_inicial.sql`) —
   tabla `personas.departamento` (id, `area_id` FK a `personas.area`, `nombre_departamento`
   único **global** — no por área, confirmado en `SCJ-PRO-03 §V` —, activo, timestamps), mismo
   índice insensible a mayúsculas, RLS y GRANT calcados de `area`. Seed de los 6 departamentos
   reales del organigrama (3 bajo Operaciones, 3 bajo Administración y Finanzas), resuelto por
   `nombre_area` vía `JOIN`, sin UUIDs hardcodeados. Aplicado contra Supabase, verificado.
2. **Backend** (`backend/app/routers/departamentos.py`, `schemas/departamentos.py`) — los mismos
   5 endpoints de `area` (incluido `GET /{id}` desde el día uno, evitando repetir el hueco que
   causó el 405 en el corte anterior). Suma una validación que `area` no tenía por no tener
   padre: `POST` verifica que `area_id` exista y esté `activo` antes de insertar (`SCJ-PRO-03 D1`),
   devolviendo 422 con mensaje claro.
3. **Frontend** — sin mockups nuevos. Habilitada la subpestaña "Departamentos" (ya estaba en
   `NAV_GROUPS` como placeholder atenuado). Tres páginas calco de las de `area`, con el agregado
   de: columna/dato de área padre (resuelta con un segundo fetch a `/api/areas`, mismo espíritu
   que la resolución de nombres que ya usa el proyecto en la bitácora de movimientos), selector de
   área activa en el alta (deshabilitado si no hay ninguna), y traducción del 422 de área
   inválida/inactiva a un mensaje inline legible.
4. **Pruebas** — 15 casos backend nuevos (48 total), 13 casos frontend nuevos (122 total). Se
   corrigió un test existente de `AppShell.test.tsx` que había quedado desactualizado al
   habilitarse la subpestaña de Departamentos.
5. **Seguridad** — mismos 5 puntos que `area`, mismo método de verificación de RLS con rol
   simulado real. Sin hallazgos nuevos. Una nota de baja severidad sobre nomenclatura de
   fixtures de test (nombres inventados tipo "Ventas"/"Cobranza") se confirmó con `testing` como
   generados de cero, sin contacto con el organigrama real no versionado.

## Qué se decidió

- **Sin reasignación de `area_id`** en un departamento ya creado — no está en `SCJ-PRO-03`, no se
  inventó. `DepartamentoRename` sólo acepta el nombre.
- **Único global de `nombre_departamento`**, no compuesto con `area_id` — regla explícita del
  documento de proceso, no la interpretación "obvia" (que hubiera sido por área).
- **Validación de `area_id` en el backend, no en DDL** — mismo criterio que el resto del proyecto:
  las reglas de flujo (`SCJ-PRO-03 D1`) viven en la capa de aplicación; el DDL sólo impone la FK
  estructural.
- **Gate débil, mismo riesgo aceptado y misma condición de cierre que `area`** (`SCJ-PRO-05`
  implementado → exigir `departamento_edicion`/`departamento_lectura`).
- **Sin trigger de guarda `SCJ-PRO-06 DD1`** ("no desactivar con `puesto` hijo activo") —
  `puesto` no existe todavía; `# TODO SCJ-PRO-06 DD1` en DDL y backend, igual que `area`.

## Qué quedó pendiente

- Nit de frontend, no bloqueante: `FichaDepartamentoPage.tsx` maneja una respuesta 400/422 en
  "cambiar estado" con un mensaje que menciona "puestos activos debajo" — el backend no implementa
  esa validación todavía (es el `TODO SCJ-PRO-06 DD1`), así que esa rama de error es código muerto
  hasta que se construya `puesto`. No corregido en este corte por no ser bloqueante.
- `puesto` (resto de `SCJ-PRO-03`), `asignacion` (`SCJ-PRO-04`), permisos a puesto (`SCJ-PRO-05`)
  y el resto de `SCJ-PRO-06` — mismo estado que antes de este bloque.
- Warning de deprecación de Starlette (`HTTP_422_UNPROCESSABLE_ENTITY` → renombrado en versiones
  nuevas) apareció en la corrida de pytest — cosmético, no afecta el comportamiento, evaluar en una
  pasada de mantenimiento de dependencias.

## Conteos de tests al cierre de este bloque

- Backend: 33 → **48** casos (`uv run pytest`).
- Frontend: 109 → **122** casos (`npm test`).
