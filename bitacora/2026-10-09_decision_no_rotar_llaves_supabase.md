# 2026-10-09 · SCJ-DEC-12 — Decisión de no rotar las llaves de Supabase (riesgo aceptado)

**Participantes:** el usuario (dueño del proyecto y único con acceso a los equipos), `orchestrator`, `security`, `db`, `devops`, sesión `Checador`.
**Duración:** una sesión larga de trabajo sobre el puente de la terminal Hikvision.

---

## Qué se hizo

Se descubrió que existía una copia con valores reales de `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_JWT_SECRET` en `~/Checador_RTB/backend/.env` del Raspberry Pi del puente (IP 192.168.10.50, nodo Tailscale "checador"), un equipo distinto al Pi de pruebas donde se despliega el sistema de administración central. El archivo pertenece al checador básico (repositorio `Checador_RTB`), que ya no se usa, y estaba con permisos 0664 (legible por grupo y otros). Última modificación: 9 de septiembre de 2026.

Verificaciones de solo lectura hechas ese día en el Pi del puente:

- El checador básico no corría: sin servicio systemd, sin proceso, sin Docker, sin puertos de aplicación en escucha, sin `checador.db`.
- No existe en ese Pi el puente nuevo (`puente/`), solo commits publicados en GitHub.
- No quedaron `.bak`, `.swp` ni otros `.env`, y el historial del shell (`~/.bash_history`) no contenía los nombres de las variables.

Acciones ejecutadas por la sesión `Checador` con autorización expresa del usuario: `chmod 600` sobre el archivo y luego `rm ~/Checador_RTB/backend/.env`. No se copiaron ni imprimieron valores. Las llaves siguen disponibles en el dashboard de Supabase del usuario.

Se retiró además el rol `terminal_checador` de la base real (`db/ddl/93_tiempo_retira_terminal_checador.sql`, aplicado el 9 de octubre de 2026 tras ensayo `BEGIN…ROLLBACK` 19/19 y revisión de `security`), junto con su policy `terminal_inserta_su_origen`, el `INSERT` sobre `tiempo.marca`, el `USAGE` del esquema y su membresía en `authenticator`.

## Qué se decidió

El usuario decidió **no rotar** `SUPABASE_JWT_SECRET` ni `SUPABASE_SERVICE_ROLE_KEY`. Aceptó el riesgo residual con estos hechos a la vista:

- Declaró que él puso las llaves en ese equipo y que solo él ha tenido acceso; no hay otros usuarios en el Pi.
- Con el archivo borrado, el `.env` ya no está en el Pi, pero **borrar no invalida las llaves**: en una tarjeta SD no hay borrado seguro, y con permisos 0664 durante unas semanas no se puede probar que nadie lo leyó (aunque no hay evidencia de que alguien más tuviera acceso).
- Quien tuviera el JWT secret podría firmar un token con cualquier rol, incluido `service_role`, y por tanto escribir en la base por caminos más anchos que el rol `terminal_checador`. Quien tuviera la `SERVICE_ROLE_KEY` podría llamar directamente al RPC de marcas con cualquier `p_terminal_id`, saltándose la llave `scjt_`. El retiro de `terminal_checador` (93_) es higiene y defensa en profundidad, **no una mitigación de esa fuga**.
- La única mitigación real de la fuga habría sido rotar. El costo de rotar es conocido: ventana corta del sistema principal, actualizar el `.env` del backend del Pi de pruebas (service_role y anon), reconstruir el frontend de producción con `--build` (la anon key es variable de build) y reautenticar a los usuarios.

Controles compensatorios vigentes:

- `.env` borrado del Pi del puente y sin copias residuales verificadas.
- El puente nuevo no necesita ni usará esas llaves: sube marcas por el backend con su propia llave opaca `scjt_` (SCJ-DEC-12).
- El checador básico no se despliega (`CHECADOR_BASICO_DEV=1` para montar su router de personas, README "NO SE DESPLIEGA") y su retiro está planeado en T-PI-10 y antes de la primera prueba física.
- El rol `terminal_checador` ya no puede escribir en `tiempo.marca`.
- Sugerencia de `security`, aún no implementada: un `SELECT` periódico de solo lectura (con aprobación del usuario) que busque marcas con `origen='terminal'` cuyo `terminal_id` no esté registrado en `tiempo.terminal`.

Condiciones que **reabrirían** la decisión (rotar sin esperar):

- Aparece evidencia de acceso no autorizado a ese Pi, a la cuenta de Tailscale o al repositorio.
- Aparecen en `tiempo.marca` marcas con `origen='terminal'` de un `terminal_id` no registrado, o marcas que no correspondan a una terminal real.
- Aparece actividad inesperada en los logs de la API de Supabase (IPs desconocidas).
- El Pi se pierde, se presta, se reutiliza o se da de baja sin borrado completo de la SD.
- Otra persona recibe acceso a ese equipo o a la cuenta de Tailscale.

## Qué quedó pendiente

- Escribir, si el usuario lo pide, la verificación periódica de marcas de terminales no registradas.
- Revisar en el panel de Tailscale quién tiene acceso a los nodos.
- Actualizar el residuo aceptado de `SCJ-DEC-12` ("enlace sin TLS"): ahora, además de nombres, viajan por ese enlace credenciales (`password`, `cardNo`) que la terminal incluye en sus respuestas.
- Revisar esta decisión antes del primer despliegue real y antes de la prueba física con la terminal conectada.

## Preguntas nuevas

- ¿Se rotarán las llaves antes de producción? Hoy no; queda como reevaluación obligatoria en el punto anterior.

## Nota para la retrospectiva

Un error de proceso previo explica por qué había una copia de las llaves en un equipo que ya no las necesitaba: el checador básico se construyó con `service_role` "temporal" (ver `SCJ-DEC-12`) y quedó el `.env` cuando se descartó ese diseño. Lección: cuando un componente se retira, hay que inventariar y borrar también sus secretos, no solo el código.
