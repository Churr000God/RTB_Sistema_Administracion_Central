# AGENTS.md

Guía maestra de trabajo para agentes en `sistema-control-jornada`.

## Orden de lectura del código

1. `docs/00-contexto/SCJ-CTX-01_*.md` — el caso y su alcance
2. `docs/00-contexto/SCJ-ESP-01_*.md` — qué debe poder representar el modelo
3. `docs/00-contexto/SCJ-FRO-01_*.md` — la frontera entre Personas y Tiempo
4. `docs/01-analisis/SCJ-MOD-01_*.md` — modelo conceptual
5. `docs/02-modelo/SCJ-MOD-02_*.md` — modelo lógico
6. `docs/03-decisiones/` — las cinco decisiones de diseño
7. `db/ddl/` en orden numérico — el modelo físico ejecutable
8. `docs/01-analisis/SCJ-TRZ-01_*.md` — requisito → tabla → consulta que lo demuestra

## Módulos activos vs. legado

- **Activos:** todo `docs/`, `db/ddl/`, `db/indices/`, `diagramas/`, `bitacora/`,
  `tools/generador/`, `backend/`, `frontend/`, `diseno_paginas/`, `scripts/`.
  - `backend/app/` (routers/schemas/deps/config, FastAPI + `supabase-py`) y `frontend/src/`
    (pages/layouts/router, Vite + React + TypeScript) tienen el módulo Personas y Usuarios
    (`SCJ-PRO-01`/`SCJ-PRO-02`) completo, con sus pruebas (`backend/tests/`,
    `frontend/src/**/*.test.tsx`). Antes de tocarlos, leer las convenciones que ya establecieron:
    los routers usan `db.postgrest.schema("personas").table(...)`, no `db.table(...)` directo; los
    endpoints devuelven los esquemas de `app/schemas/`, no dicts sueltos.
  - `diseno_paginas/personas/` son los 14 mockups (marca ficticia "Kairos") contra los que el
    frontend todavía no pasó QA manual completo — ver `bitacora/2026-09-03_dockerizacion.md`.
- **Vacíos, en construcción:** `db/migraciones/`, `db/seeds/`. No asumir contenido ni
  convenciones de estos hasta que exista algo.

## Reglas de implementación

- Español en documentos y comentarios de código.
- Nombres de archivo y folios siguen `CONVENCIONES.md` — no inventar prefijos nuevos.
- Ningún dato real, ningún nombre real, ningún documento con folio `RTB-` (ver
  `docs/00-contexto/SCJ-ANO-01_*.md` y el checklist antes de cada entrega).
- Un cambio de esquema (`db/ddl/`) que no esté ya cubierto por un `docs/03-decisiones/SCJ-DEC-*.md`
  necesita su propio documento de decisión antes de implementarse.

## Skills sugeridos y cuándo usarlos

- `test-driven-development` — antes de tocar el generador de datos, las consultas de validación,
  o cualquier cálculo de saldos/paridad en backend.
- `code-review` — si el cambio toca DDL junto con código de aplicación, o cualquier KPI visible
  en frontend.
- `run` — para levantar el proyecto (backend, frontend; la base de datos ya vive en Supabase, no
  se levanta) y observar comportamiento real, no sólo leer código.
- `verification-before-completion` — antes de reportar cualquier tarea como lista.
- `security-review` — antes de cualquier merge a `main`.

## Verificación antes de cerrar

1. El DDL corre limpio sobre un proyecto de Supabase nuevo (o reseteado desde su dashboard).
2. Las consultas de validación de `db/consultas/validacion/` devuelven lo esperado.
3. El nombre del archivo y la versión del encabezado del documento coinciden.
4. El checklist de `docs/00-contexto/SCJ-ANO-01_*.md` está corrido sobre lo que se va a subir.
5. Los tres documentos vivos (`SCJ-PRA-01`, `SCJ-TRZ-01`, `SCJ-GLO-01`) y la `bitacora/` de la
   sesión están al día.

## MCP disponibles relevantes

- **Supabase** — es la base de datos del proyecto. Útil para correr DDL, revisar tablas y datos,
  y leer logs sin salir de Claude Code.
- **Figma** — plausible para `diseno_paginas/`, si el diseño de pantallas se hace ahí.
- Gmail, Calendar, Drive, Notion, Gamma, Canva, n8n — sin uso previsto en este proyecto.
