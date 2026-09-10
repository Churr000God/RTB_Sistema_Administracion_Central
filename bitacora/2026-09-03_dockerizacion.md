# 2026-09-03 · SCJ-DOK-01 — Dockerización, contexto al día y merge del módulo Personas y Usuarios

**Participantes:** Diego, sesión `sistema-control-jornada-a9` (dockerización), sesión `sistemas-42`
(módulo Personas y Usuarios, coordinada por mensaje entre sesiones)
**Duración:** ~2 horas

---

## Qué se hizo

1. **Merge a `main`.** El módulo Personas y Usuarios (`SCJ-PRO-01`/`SCJ-PRO-02`) vivía sólo en
   `feature/modulo-personas-usuarios` (26 commits, fast-forward puro). Se integró a `main` y se
   empujó a `origin` por decisión explícita de Diego, **sin esperar** el QA manual pantalla por
   pantalla de los 14 mockups ni la revisión final de rama que exige
   `superpowers:subagent-driven-development` — ver "Qué quedó pendiente".
2. **Dos ajustes de código** para que el backend corriera en contenedor sin romper nada:
   - `backend/app/config.py`: `env_file` pasó de una sola ruta relativa (`"../.env"`, rompía
     dentro del contenedor) a una tupla de candidatos.
   - `backend/app/main.py`: el CORS ya no tiene `http://localhost:5173` fijo — lee `FRONTEND_URL`
     directo del entorno (con ese mismo valor como default). Se decidió leerlo del entorno crudo,
     no de `app.config.Settings`, para no forzar la validación de las llaves de Supabase sólo por
     construir el middleware — eso rompía la colección de pruebas cuando no hay `.env`.
3. **Dockerización completa:** `backend/Dockerfile` y `frontend/Dockerfile` (ambos multi-stage,
   target `dev`/`prod`), `frontend/nginx.conf` (fallback SPA), `.dockerignore` en cada servicio,
   `docker-compose.yml` (dev, hot reload) y `docker-compose.prod.yml` (override: nginx + uvicorn
   sin reload, `VITE_*` como `build.args`). Sin contenedor de base de datos — sigue siendo Supabase
   remoto.
4. **`scripts/desplegar.sh`**: un solo script, `dev`/`prod` × `levantar`/`bajar`/`reconstruir`/
   `registros`/`pruebas`/`estado`, con validación previa de que existan `.env`/`frontend/.env` y
   que las llaves de Supabase no estén vacías.
5. **Verificado de punta a punta** (backend 7/7, frontend 9/9, dentro y fuera de contenedor; dev y
   prod levantados en puertos alternos para no chocar con los servidores manuales que
   `sistemas-42` seguía usando para su QA). Detalle en la sección de verificación de
   `docs/superpowers/plans/` de esta sesión / historial de comandos — no se repite aquí.
6. **CLAUDE.md, README.md y AGENTS.md actualizados** al estado real: ya no dicen que
   `backend/`/`frontend/` están vacíos ni que el framework está por decidir.

## Qué se decidió

- Publicar el módulo a `main`/`origin` **antes** de terminar su QA y su revisión final de rama —
  riesgo aceptado explícitamente por Diego. Los fixes que salgan del QA caerán encima de `main`.
- Las `VITE_*` del frontend se resuelven como variables de **build**, no de runtime — más simple
  que inyección de configuración en tiempo de ejecución, a costa de que cambiar una en producción
  exige reconstruir la imagen.
- CORS del backend lee `FRONTEND_URL` del entorno crudo (no de `Settings`), para no acoplar el
  arranque del middleware a la validación completa de credenciales de Supabase.

## Qué quedó pendiente

- **QA manual pantalla por pantalla contra los 14 mockups de `diseno_paginas/personas/`** — no
  bloqueó el merge, sigue abierto. Retomar sobre `main` directo, no sobre la rama vieja.
- Revisión final de rama completa (`superpowers:subagent-driven-development`) — tampoco corrió
  antes del merge.
- `ficha_persona` (endpoint `GET /api/personas/{id}`) no maneja explícitamente el caso de un
  `persona_id` inexistente: hoy PostgREST lanza `APIError` en 0 filas y FastAPI lo deja pasar como
  500 en vez de un 404 limpio. Cambio de bajo riesgo, cero impacto hoy porque nada en el flujo
  actual navega ahí con un id inválido — hardening pendiente.
- "Enforce single session per user" en Supabase está gateado al plan Pro (este proyecto está en
  Free) — no se pudo activar. TTL de sesión (900s) + RLS ya cubren buena parte de la exposición que
  `SCJ-PRO-02` buscaba mitigar; falta la decisión de Diego (subir a Pro o aceptar el hueco).
- La verificación manual de los triggers de bitácora (`trg_bitacora_sincroniza_persona`,
  `trg_usuario_bitacora_alta`) sólo ejerció la rama de suspensión en su script de validación
  formal; el resto de ramas (reactivación, baja definitiva) se ejercitaron en el walkthrough manual
  de alta→suspensión→reactivación→baja, no en un script repetible.
- Puesto/área/departamento/permiso/asignación quedaron **fuera de alcance a propósito** del módulo
  Personas y Usuarios — no hay tablas ni endpoints de eso todavía, es módulo aparte sin diseñar.
- Configuración que vive **fuera del repositorio**, en el dashboard de Supabase, y que hay que
  actualizar a mano al pasar de dev a producción: Site URL, lista de Redirect URLs y plantillas de
  correo (invitación / recuperar contraseña) siguen apuntando a `http://localhost:5173`. En
  producción con Docker (frontend en `:8080`) hay que cambiarlos ahí, ningún cambio del repo lo
  cubre.
- Exponer un esquema en Data API (Dashboard → Integrations → Data API → Settings) **no** otorga
  permisos de Postgres — hace falta el `GRANT` (`db/ddl/08_personas_permisos.sql`) aparte. Ya
  corregido para `personas`, pero es una trampa real si se agrega un esquema nuevo más adelante.

## Preguntas nuevas

- ¿Se sube el proyecto de Supabase a plan Pro para poder forzar sesión única por usuario, o se
  acepta el hueco de "múltiples sesiones activas simultáneas" como riesgo residual documentado?
- El correo de invitación/recuperación usa SMTP propio ya configurado con diseño de marca — falta
  decidir si el remitente definitivo queda fijo o si se habilita un alias adicional en el servidor
  de correo (fuera del control de este repositorio).

## Nota para la retrospectiva

Primera vez que dos sesiones de Claude Code trabajando en el mismo repositorio (una en el
worktree del módulo, otra en la raíz dockerizando) tuvieron que coordinarse en vivo antes de una
acción compartida difícil de revertir (merge + push a `origin`). El mecanismo que funcionó: la
sesión que iba a hacer el cambio le preguntó a la otra antes de tocar `main`, la otra se negó
citando una instrucción explícita del usuario que el primer mensaje no traía, y sólo se destrabó
cuando el usuario confirmó la decisión directamente en ambas sesiones — ninguna tomó la palabra de
la otra como autorización. Vale la pena repetir ese patrón cuando dos agentes comparten un
repositorio: pedir confirmación de la fuente humana antes de una acción irreversible compartida, no
de un peer.
