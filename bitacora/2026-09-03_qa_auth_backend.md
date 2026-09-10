# QA de flujo de auth — parte de backend

**Sesión:** `backend` (rol) · 3 de septiembre de 2026
Contexto: QA end-to-end del flujo de login/2FA/recuperación de contraseña, coordinado por
`orchestrator`. `testing` ejerce el flujo en el navegador contra `http://localhost:5173`;
esta nota cubre la parte de backend: estado de los endpoints reales y monitoreo de `registros`.

## 1. Endpoints reales — códigos y forma de respuesta

Stack dev arriba (`./scripts/desplegar.sh dev estado`, ambos contenedores `healthy`). Se
probaron todos los endpoints de `backend/app/routers/` sin token real (no hay credenciales de
prueba documentadas en el repo — ver §3):

| Endpoint | Sin `Authorization` | Con `Authorization` mal formado | Notas |
|---|---|---|---|
| `GET /salud` | — | — | `200 {"estado":"ok"}`, sin dependencias |
| `GET /api/personas` | `422`, `detail[0].loc=["header","authorization"]` | (no probado) | Header requerido vía `Header(...)` — FastAPI valida y devuelve `422`, no `401`, cuando el header falta del todo. `401` sólo sale si el header llega pero no empieza con `Bearer ` (`deps.get_caller_client`) |
| `POST /api/personas` | `422`, junta el error de header + los de body (`primer_nombre`, `curp`, `rfc`, `nss`, `fecha_nacimiento`, `fecha_ingreso`, `tipo_contrato`, `documento_ref`) | — | Forma de respuesta consistente con `PersonaOut`/`PersonaCreate` (`backend/app/schemas/personas.py`) |
| `GET /api/personas/{id}` | `422`, mismo patrón de header | — | — |
| `POST /api/usuarios` | **`422` sin ningún error de `authorization`** — sólo `persona_id`, `correo`, `nombre_usuario` | — | **Ver §2 — no hay `Authorization` porque el endpoint no la exige** |
| `POST /api/personas/{id}/movimientos` | `422`, header + `tipo_movimiento`/`motivo` | — | — |
| `GET /api/personas/{id}/movimientos` | `422`, mismo patrón de header | — | — |
| `GET /api/no-existe` (control) | `404 {"detail":"Not Found"}` | — | — |

No se pudo ejercer el camino feliz (200 con datos reales) porque el repo no trae credenciales
de prueba ni un usuario sembrado para pedir un token — ver §3, bloqueo.

## 2. Hallazgo: `POST /api/usuarios` sin autenticación ni autorización

Ya reportado por la sesión `security` en `SCJ-PRA-01` (pregunta #02) y confirmado acá de forma
independiente, con evidencia adicional del comportamiento en runtime:

- `backend/app/routers/usuarios.py:11` usa `Depends(get_service_client)`, no
  `Depends(get_caller_client)` — es el único router de los tres que no pasa por el chequeo de
  `Authorization`.
- Runtime lo confirma: el `422` de `POST /api/usuarios` con body vacío **no** trae el error de
  `header.authorization` que sí aparece en `personas` y `movimientos` — la validación de
  Pydantic corre antes de tocar ninguna dependencia de auth, porque no hay ninguna.
- `backend/app/main.py` no tiene middleware ni dependencia global de auth — cada router decide
  por su cuenta, y `usuarios` no decidió nada.
- Impacto: cualquiera que alcance el puerto 8000 (dev: sin restricción de red más allá del
  `docker-compose.yml`) puede invitar un usuario a cualquier `persona_id`, disparando
  `db.auth.admin.invite_user_by_email` con el `service_role` — manda un correo de invitación
  real a la dirección que el atacante ponga. CORS (`main.py`) no mitiga nada: sólo frena
  navegadores, no `curl`/scripts.
- No se ejecutó un POST con body válido para no disparar una invitación real — el `422` con
  body vacío ya es evidencia suficiente (confirma que no hay dependencia de auth antes de la
  validación de body).

No se toca código: es hallazgo de diseño (`personas.fn_caller_activo()` tampoco distingue rol,
no hay concepto de permiso/admin en el proyecto todavía — `puesto`/`área`/`permiso` quedaron
fuera de `SCJ-PRO-01`). Queda anotado en `SCJ-PRA-01` #02, no se duplica acá.

## 3. Bloqueo: sin credenciales de prueba para el camino feliz

No hay usuario sembrado ni token de prueba documentado en el repo para pedir un JWT real y
ejercer `GET/POST /api/personas` autenticado. Si `testing` obtiene un `access_token` válido
durante su QA de login (vía `localStorage` del navegador o la respuesta de Supabase), pasarlo
permitiría cerrar el camino feliz de los endpoints. No bloquea el resto de este QA: la forma de
error y los códigos de estado ya quedaron confirmados.

## 4. `registros` — monitoreo durante el QA de auth

Se dejó `docker compose logs -f` corriendo (backend + frontend) desde que arrancó este QA.
Hasta el momento de escribir esta nota, el único tráfico visible en `backend` es el
healthcheck (`GET /salud` cada 10s) — **cero errores 4xx/5xx, cero trazas**. Esto es esperable:
login/2FA/recuperación de contraseña son flujo Supabase Auth directo desde el frontend
(`frontend/src/`), no pasan por este backend FastAPI — el backend sólo entra en escena para
`personas`/`usuarios`/`movimientos`, después de que el usuario ya tiene sesión. Si `testing`
llega a ejercitar pantallas de `personas` después de loguearse, ahí sí debería verse tráfico
real en estos `registros`.

## 5. Recomendación: no hay configuración de logging en el proyecto

Confirmado en `backend/Dockerfile` y `docker-compose.yml`: uvicorn corre con sus defaults (sin
`--log-config`, sin `--log-level` explícito), sin volumen dedicado a logs, y el
`docker-compose.yml` no define bloque `logging:` (rotación) — usa el driver por default de
Docker, que crece sin límite. Además, el healthcheck cada 10s (`interval: 10s`) genera una
línea de acceso por chequeo, que en la práctica ahoga cualquier señal real en `docker compose
logs`.

**Recomendación (no implementada — cambio de alcance mayor a este QA, evaluación nada más):**

- Nivel de log explícito por entorno: `--log-level info` en prod, `debug` opcional en dev vía
  variable de entorno, en vez de heredar el default de uvicorn.
- Formato estructurado (JSON) en prod facilitaría filtrar por nivel/ruta si en algún momento se
  agrega un colector — hoy es texto plano de uvicorn, ilegible para un parser.
- Bloque `logging:` con rotación (`max-size`/`max-file`) en `docker-compose.prod.yml` como
  mínimo, para no llenar disco en un despliegue de larga duración.
- El ruido del healthcheck (`GET /salud` cada 10s) podría filtrarse con
  `--no-access-log` combinado con logging propio de la app, o aceptarse como costo conocido —
  vale la pena decidirlo antes de depender de estos `registros` para diagnosticar producción.

No urge para este proyecto académico (no hay producción real, ver `SCJ-ANO-01`), pero si
`RTB-App` copia este backend como base, esta ausencia sí importa ahí.

## 6. Checklist `SCJ-ANO-01` antes de subir

- `~/palabras.txt` no existe en este entorno — no se pudo correr el grep de palabras
  prohibidas (ítems 1 y 6 del checklist). El resto de items relevantes a esta nota (2, 3, 4)
  están limpios: ningún folio ajeno a `SCJ-`, ningún `.env` ni credencial, ninguna captura de
  pantalla adjunta. Ningún dato real: los `curl` de este QA no completaron ningún alta (sólo
  se probó con body vacío o inexistente), no se generó ningún dato sintético nuevo.

## Archivos tocados

- `bitacora/2026-09-03_qa_auth_backend.md` (este archivo, nuevo)

Sin cambios en `backend/app/` — el QA fue de sólo lectura/observación.
