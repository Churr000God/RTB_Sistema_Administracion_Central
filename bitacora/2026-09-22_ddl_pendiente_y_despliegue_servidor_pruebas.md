# 2026-09-22 · — DDL 71-78 aplicado al Supabase real y despliegue de SCJ en servidor de pruebas

**Participantes:** usuario, `orchestrator` (equipo de 6 especialistas vía `team-orchestrator`:
`db`, `devops`; `backend`/`frontend`/`testing`/`security` no participaron, sin tarea para su
dominio en este corte)
**Duración:** una sesión, arrancó con una tarea sin relación (baja de la página de pruebas de
OCEAAN_WEB en el mismo servidor) que terminó destrabando acceso al servidor para lo que sigue

---

## Qué se hizo

**Aparte, sin relación con SCJ:** el usuario pidió dar de baja la página de pruebas de OCEAAN_WEB
(otro proyecto) en el servidor `74.208.253.210` — contenedor `oceaan-web` y las imágenes
`nginx:alpine`/`ubuntu:24.04` borradas, `~/oceaan-web/repo` (250M) se dejó intacto a propósito para
poder reexponerlo sin resubir nada. En el camino se encontró que `dhguilleng@74.208.253.210` no
tenía `~/.ssh/authorized_keys` (por eso costaba conectar pese a que el usuario recordaba haber
entrado antes) y se le agregó `NOPASSWD` en sudoers a pedido del usuario para mantenimiento futuro
de un stack de Nextcloud en producción real que corre en el mismo servidor (`/srv/nextcloud/`, no
tocado). Ver `CLAUDE.md` de `OCEAAN_WEB` para el detalle — no se repite acá porque es otro repo.

**Ya sobre SCJ**, el usuario pidió dos cosas en orden: (1) asegurar que la base de datos esté al
día, (2) desplegar el proyecto en el mismo servidor de pruebas, en un puerto nuevo, adaptado para
acceso remoto.

**DB (`db`):** el DDL `71_*.sql` a `78_*.sql` (portado desde RTB-CRM-APP el 11 y 15 de septiembre,
ver `bitacora/2026-09-11_sincronizacion_desde_rtb-crm-app.md` y
`bitacora/2026-09-15_sincronizacion_dia_cerrado_desde_rtb-crm-app.md`) estaba versionado pero
**nunca aplicado** contra el Supabase real de este proyecto académico. Se verificó primero que
efectivamente faltaba (funciones/policies/triggers ausentes vía `pg_proc`/`pg_policy`), se pidió
confirmación explícita al usuario (el auto-mode classifier de la sesión `db` bloqueó el primer
intento de escritura contra la base real y preguntó), y se aplicaron los 8 archivos en orden
estricto con `psql -v ON_ERROR_STOP=1 -f`, cero errores. El primer intento de `psql` falló con un
error de tenant/rol que resultó ser `$DATABASE_URL` no exportada en el shell de esa sesión, no un
problema real del pooler — diagnosticado por `orchestrator` reproduciendo el mismo error y
corrigiendo el `export`. Verificación post-aplicación confirmó los 8 archivos activos (ver detalle
en el reporte de `db`, no repetido acá).

**Deploy (`devops`):** SCJ desplegado en `74.208.253.210` junto al Nextcloud existente, sin
tocarlo. Puerto **8081** para el frontend (reusa la regla `ufw` que ya tenía OCEAAN_WEB, liberado
en este mismo corte) y **8082** nuevo para el backend. Código transferido por `rsync` a `~/scj/`
(sin `.git`/`node_modules`/`.venv`). Se armó un `docker-compose.remoto.yml` que **vive sólo en el
servidor** (no en el repo, no commiteado) para override de puertos sobre el compose de prod
existente. `.env`/`frontend/.env` en el servidor llevan los mismos secrets que el `.env` local del
repo (misma base de Supabase, no una nueva) — transferidos por `ssh`+`stdin` con aprobación
explícita del usuario (el classifier de `devops` también bloqueó el primer intento automático de
mandar secrets, por diseño, igual que pasó en `db`). `FRONTEND_URL` sumó
`http://74.208.253.210:8081` sin sacar los orígenes existentes (localhost/Tailscale);
`VITE_API_URL` del frontend apunta a `http://74.208.253.210:8082`.

Dos bugs reales encontrados y corregidos en el camino, ninguno afectó producción real:
- El primer `docker-compose.remoto.yml` no usaba `!override` en `ports` — Compose mergea listas
  por default, así que el frontend intentaba bindear también el `8080` heredado del compose de
  prod (choque directo con Nextcloud). Corregido con `!override` explícito en ambos servicios
  antes de levantar nada.
- El backend quedó sano puertas adentro (`localhost:8082/salud` bien) pero inalcanzable desde
  afuera — no era bug del stack ni de `ufw` (confirmado con `tcpdump` en el servidor: el SYN
  externo ni llegaba a la NIC). Era el firewall/security group del proveedor de hosting, una capa
  fuera del alcance de `sudo`/`ssh` — `8081`/`22`/`80`/`443` ya estaban whitelisteados ahí de antes
  (por OCEAAN_WEB/Nextcloud), `8082` nunca se había abierto en esa capa. El usuario lo destrabó
  desde el dashboard del proveedor.

Verificado end-to-end: `http://74.208.253.210:8081/` responde 200 con el bundle real de Kairos;
`http://74.208.253.210:8082/salud` responde 200 `{"estado":"ok"}` — ambos confirmados por curl y
por el usuario en navegador.

## Qué se decidió

- Aplicar el DDL `71`-`78` contra el Supabase real del proyecto académico (pendiente desde el
  15-sep) — el usuario lo autorizó explícitamente cuando `db` le preguntó.
- Reusar el mismo servidor de OCEAAN_WEB para el despliegue de pruebas de SCJ, en vez de levantar
  infraestructura nueva — puerto 8081 (liberado de OCEAAN_WEB) + 8082 nuevo.
- El override de puertos (`docker-compose.remoto.yml`) queda **sólo en el servidor**, no se
  commitea al repo — es específico de este servidor compartido con Nextcloud, no un patrón general
  del proyecto.
- Mismo criterio que ya estaba documentado para `db` (no escribir contra la BD real sin
  aprobación): `devops` tampoco manda secrets a un servidor remoto sin que el usuario lo apruebe
  explícitamente en su propia sesión — ningún peer puede aprobar eso por otro.

## Qué quedó pendiente

- Nada de SCJ propiamente dicho — deploy verificado end-to-end, DDL al día.
- Fuera de alcance de este corte pero relacionado: el hallazgo del `.env`/secrets en texto plano en
  el servidor remoto no tiene rotación ni gestión de secretos formal (queda igual que el flujo ya
  usado para RTB-CRM-APP en su Pi de pruebas) — no se tocó, no era parte del pedido.

## Preguntas nuevas

- Ninguna nueva de este corte.

## Nota para la retrospectiva

Segunda vez que un permission classifier de una sesión del equipo bloquea correctamente una
escritura sensible (antes fue el incidente real de `psql` contra producción del 7-sep, documentado
en `feedback-no-escribir-en-bd-real-para-depurar.md`; ahora fueron dos bloqueos limpios — DDL
contra Supabase real y secrets hacia un servidor remoto — ambos resueltos pidiendo aprobación
directa al usuario en la sesión bloqueada, sin que `orchestrator` ni ningún otro peer intentara
rodear la denegación). Confirma que el patrón "el classifier frena, la sesión pregunta en su propio
chat, nadie más aprueba por ella" funciona como red de seguridad real, no sólo como fricción.
