# 2026-09-04 — Primer corte del módulo Estructura Organizacional: catálogo `area`

**Participantes:** `orchestrator` (coordinación) · `db` (DDL + seed) · `frontend` (mockups `/design`
+ sidebar agrupado + páginas) · `backend` (API REST) · `testing` (pruebas backend+frontend) ·
`security` (auditoría). Trabajo delegado a las sesiones del equipo, en cadena
`db → {backend, frontend} → testing → security`, con integración final por `orchestrator`.

**Duración:** 4 de septiembre de 2026, sesión de planificación aprobada por el usuario en
`/home/diego/.claude/plans/okey-entonces-vamos-a-lovely-lark.md`.

---

## Contexto

El módulo Asignaciones/áreas/puestos/permisos (`docs/07-procesos/SCJ-PRO-03` a `06`) estaba 100%
diseñado y 0% construido — ninguna de sus seis tablas (`area`, `departamento`, `puesto`, `permiso`,
`puesto_permiso`, `asignacion`) existía. Este bloque abre el módulo por el extremo más aislado:
`area`, el catálogo raíz, de punta a punta (DDL + API + UI + pruebas + auditoría + migración
inicial con las áreas reales de la empresa, anonimizadas).

## Qué se hizo

1. **DB** (`db/ddl/10_personas_area.sql`, `11_area_migracion_inicial.sql`) — tabla
   `personas.area` (id, nombre_area UNIQUE, activo, creado_en, actualizado_en), índice único
   insensible a mayúsculas sobre `lower(nombre_area)`, RLS con la policy `solo_caller_activo`
   existente, `GRANT` explícito. Seed de 5 áreas del organigrama real, ya genéricas de industria:
   Comercial, Operaciones, Administración y Finanzas, Recursos Humanos, Tecnologías de la
   Información. Aplicado contra Supabase con `psql "$DATABASE_URL"`. `README.md` actualizado — la
   cadena de arranque de `personas` (04-11) nunca había quedado documentada ahí.
2. **Mockups** — canvas `/design` publicado como Artifact
   (`https://claude.ai/code/artifact/1f672d24-a228-49fb-bd0e-29569607a9bd`), 7 artboards: sidebar
   agrupado (activo/default), listado, estados de carga/vacío/error, alta, ficha, confirmación.
   Aprobados por el usuario.
3. **Backend** (`backend/app/routers/areas.py`, `schemas/areas.py`) — `GET/POST /api/areas`,
   `PATCH /api/areas/{id}` (renombrar), `PATCH /api/areas/{id}/estado` (activar/desactivar).
   **Primeros PATCH de todo el proyecto** — no había precedente de PUT/PATCH que copiar.
4. **Frontend** — `AppShell.tsx` reestructurado: sidebar plano → grupos desplegables
   (`NAV_GROUPS`) con autoexpansión por ruta activa, dejando `disponible` como el punto de
   enganche para cuando exista el gate por permisos. Tres páginas nuevas
   (`DirectorioAreasPage`, `AltaAreaPage`, `FichaAreaPage`), rutas `/estructura/areas*`.
5. **Pruebas** — 10 casos backend nuevos (29 total), 18 casos frontend nuevos (109 total). Sin
   bugs de producción encontrados.
6. **Seguridad** — RLS verificada con caller suspendido simulando el rol `authenticated` real
   (no sólo la función equivalente — el `DATABASE_URL` conecta como `postgres` con
   `bypassrls=true`, así que hizo falta forzar `SET LOCAL ROLE` + JWT claim para probar la policy
   en acción). `GRANT` confirmado vía `information_schema.role_table_grants`. Sin hallazgos de
   inyección SQL ni de fuga de datos RTB.

## Qué se decidió

- **Sólo `area` en este corte** — sin `departamento` ni `puesto`.
- **Columnas exactas de `SCJ-PRO-03`** — se descartó `tipo_area` (línea/apoyo, visible en el
  organigrama origen) por no tener respaldo documental, mismo criterio que ya cataloga
  `diseno_paginas/personas/NOTAS_campos_extra_mockups.md`.
- **Gate débil, aceptado formalmente como riesgo temporal** — `area_edicion`/`area_lectura` no
  existen (dependen de `puesto_permiso`/`SCJ-PRO-05`, no construido). Cualquier usuario
  autenticado y activo puede crear/renombrar/desactivar áreas; el único control real es la RLS
  `solo_caller_activo`. **Condición de cierre explícita**: implementar `SCJ-PRO-05`
  (`puesto_permiso`) y hacer que el router de `area` exija `area_edicion`/`area_lectura`. Ya
  documentado en el docstring de módulo de `areas.py`, y registrado acá a pedido de `security`
  para que no se lea como algo colado sin que nadie lo viera.
- **Los 5 nombres de área entran literales al repo** — son genéricos de industria, no identifican
  a la empresa real; no violan `SCJ-ANO-01`. Nada más del organigrama externo (personas,
  departamentos, puestos, razón social) entró al repositorio.
- **Sidebar reagrupado en grupos + subpestañas**, no sólo para `area`: es el rediseño de
  navegación que el usuario pidió de una — cada módulo agrupa sus vistas, con la estructura
  data-driven lista para gatear por permisos más adelante.
- **Sin trigger de guarda `SCJ-PRO-06 DA1`** ("no desactivar `area` con `departamento` activo") —
  `departamento` no existe todavía; queda comentario `-- TODO SCJ-PRO-06 DA1` en el DDL y en el
  endpoint de estado del backend.

## Qué quedó pendiente

- `departamento` y `puesto` (`SCJ-PRO-03` resto), asignación (`SCJ-PRO-04`), permisos a puesto
  (`SCJ-PRO-05`) y baja de estructura completa (`SCJ-PRO-06` resto) — mismo estado de diseño
  cerrado / construcción pendiente que antes de este bloque, ahora con `area` como precedente de
  patrones (DDL, primer PATCH, páginas, tests, sidebar).
- Cerrar el gate débil de `area` en cuanto exista `puesto_permiso` (condición de cierre de arriba).
- Confirmación de UI antes de desactivar un área — el canvas de `/design` la muestra, el código no
  la implementó (no estaba explícitamente en el alcance de la tarea de código); evaluar si se
  agrega antes de repetir el patrón en `departamento`/`puesto`.

## Conteos de tests al cierre de este bloque

- Backend: 19 → **29** casos (`uv run pytest`).
- Frontend: 91 → **109** casos (`npm test`).

## Preguntas nuevas

- ¿Se agrega la confirmación de desactivar como parte del patrón estándar antes de replicarlo en
  `departamento`/`puesto`, o se deja para cuando el usuario lo pida explícito?
