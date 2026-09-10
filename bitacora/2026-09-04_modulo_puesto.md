# 2026-09-04 — Tercer corte del módulo Estructura Organizacional: catálogo `puesto`

**Participantes:** `orchestrator` (coordinación) · `db` (DDL + placeholders + seed) · `backend`
(API REST con las dos primeras guardas reales de `SCJ-PRO-06`) · `frontend` (páginas, sin ronda
de mockups) · `testing` (pruebas backend+frontend) · `security` (auditoría). Mismo esquema de
delegación que los dos cortes anteriores.

**Duración:** 4 de septiembre de 2026, inmediatamente después de commitear y verificar en vivo el
corte de `departamento` (`628587f`).

---

## Contexto

Con `area` y `departamento` cerrados, este bloque suma `puesto` — el catálogo más complejo de
`SCJ-PRO-03`: introduce jerarquía propia (`reporta_a_id` autorreferencial) y es el único de los
tres donde `SCJ-PRO-06` (baja) puede implementarse parcialmente de verdad, porque una de sus tres
fuentes de bloqueo (otro puesto subordinado activo) ya es construible con las tablas existentes.

## Conflictos de modelado resueltos con el usuario

Mapear el organigrama real a `SCJ-PRO-03 §V` ("todo puesto cuelga de un departamento, ninguno
cuelga directo del área") expuso tres problemas reales, no bugs:

1. **Nombre de columna**: los documentos usan literal `Puesto_activo` (mayúscula) — se normalizó
   a `activo`, consistente con `area`/`departamento` y `CONVENCIONES.md`.
2. **Gerentes de área sin departamento**: en el organigrama real, el Gerente de CADA una de las
   5 áreas (no sólo Comercial/RH/TI, que no tienen departamentos en absoluto — también Operaciones
   y Administración y Finanzas, cuyo Gerente está un nivel arriba de sus propios departamentos)
   cuelga directo del área. La FK `departamento_id NOT NULL` no lo permite. Resuelto con un
   departamento placeholder por cada una de las 5 áreas.
3. **Puesto tope sin área**: Gerente General no pertenece a ninguna de las 5 áreas del organigrama
   (está arriba de todas). Resuelto creando una 6ª área "Dirección General" con su propio
   departamento placeholder.

El usuario confirmó explícitamente mantener los placeholders después de ver el alcance completo
(6 departamentos sintéticos, no sólo 3) — decisión de modelado documentada, no un descuido.

## Qué se hizo

1. **DB** (`14_personas_puesto.sql`, `15_estructura_placeholders_direccion.sql`,
   `16_puesto_migracion_inicial.sql`) — tabla `personas.puesto` con `nivel` (catálogo cerrado de 4
   valores), `plazas_totales` (CHECK > 0), `reporta_a_id` autorreferencial nullable,
   `CHECK (id IS DISTINCT FROM reporta_a_id)` y un índice único parcial que garantiza a lo sumo un
   puesto tope en todo el sistema. Los 6 departamentos placeholder + la 6ª área "Dirección
   General", sin tocar la migración de área ya aplicada. Seed de los 13 puestos marcados "Actual"
   en el organigrama (los "Previsto"/"Crecimiento" no se siembran), resueltos top-down con la
   jerarquía saltando los nodos futuros no sembrados. El caso del "Gerente de Adm. y Finanzas"
   (listado dos veces en el organigrama: cabeza de área y titular de Finanzas y Tesorería) se
   resolvió como un solo puesto — ese departamento real queda sin puesto propio en el seed.
2. **Backend** (`routers/puestos.py`, `schemas/puestos.py`) — 5 endpoints, validando
   `departamento_id` y `reporta_a_id` antes de insertar. **A diferencia de `area`/`departamento`,
   acá sí se implementaron guardas reales de `SCJ-PRO-06`**: `DP4` (no desactivar con subordinados
   activos) y `RP1` (no reactivar si el departamento o el superior siguen inactivos). `DP1`/`DP3`
   (asignación, puesto_permiso) siguen como TODO — esas tablas no existen.
3. **Frontend** — subpestaña "Puestos" habilitada. Tres páginas con dos selects nuevos en el alta
   (departamento activo, puesto superior activo) y un mapa autorreferencial para resolver "reporta
   a" en el listado sin fetch extra. En la ficha, los mensajes de error de desactivar/reactivar
   muestran el `detail` real del backend (no un texto inventado) — es la primera vez que ese caso
   de error puede dispararse de verdad.
4. **Pruebas** — 18 casos backend nuevos (66 total), 17 casos frontend nuevos (139 total),
   cubriendo explícitamente las guardas `DP4`/`RP1`.
5. **Seguridad** — mismos 6 puntos que los cortes anteriores (se sumó verificación de que
   `ck_puesto_no_autoreferencia` y el índice único del tope están aplicados en el catálogo real de
   Supabase, no sólo en el `.sql`). Sin hallazgos nuevos.

## Qué se decidió

- **Sin validación de ciclo/auto-referencia en código** (`SCJ-PRO-03 P3/P5`) — el propio documento
  admite que en el alta es "imposible por construcción" (siempre se elige un puesto ya existente);
  sería lógica muerta sin el endpoint de edición de `reporta_a_id`, que `SCJ-PRO-03 §I` excluye
  explícitamente de su alcance. Sólo se agregó el `CHECK` defensivo en DDL.
- **Sin reasignar `departamento_id` ni `reporta_a_id`** de un puesto ya creado — mismo criterio
  que área/departamento, fuera del proceso documentado.
- **Gate débil, mismo riesgo aceptado y misma condición de cierre** que área/departamento
  (`SCJ-PRO-05` implementado → exigir `puesto_edicion`/`puesto_lectura`).

## Qué quedó pendiente

- Con `puesto` cerrado, `SCJ-PRO-03` está completo. Quedan `SCJ-PRO-04` (asignación de persona a
  puesto), `SCJ-PRO-05` (otorgar/revocar permiso a puesto) y el resto de `SCJ-PRO-06` (baja de
  departamento/área con hijos reales, hoy sin tabla que consultar más allá de puesto).
- `DP1`/`DP3` de la guarda de desactivar puesto (asignación vigente, puesto_permiso activo) sólo
  se pueden completar cuando existan esas tablas.
- Convención acordada con `testing`: de acá en adelante, los fixtures de test deben usar nombres
  claramente ficticios (no parecidos a estructura real) para que `security` no tenga que
  reconfirmar origen de datos en cada corte — ya se repitió la misma pregunta en `departamento` y
  `puesto`.

## Conteos de tests al cierre de este bloque

- Backend: 48 → **66** casos (`uv run pytest`).
- Frontend: 122 → **139** casos (`npm test`).
