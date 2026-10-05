# 2026-09-22 · [SCJ-OPS] — Verificación del bloqueo de Cloudflare al Pi (ya resuelto)

**Participantes:** orchestrator, devops (vía `team-orchestrator`)
**Duración:** corte corto, una sola pregunta

---

## Qué se hizo

El usuario pidió confirmar si seguía activo el bloqueo del WAF de Cloudflare de Supabase contra
la IP de salida del Pi de pruebas (`raspberrypi-serverpruebas`), documentado el 11 de septiembre
de 2026 (`bitacora/2026-09-11_jornada_edicion_futura_y_fixes_horario.md`). `orchestrator` delegó
la verificación a `devops` (sólo lectura, sin disparar el flujo real de invitación): SSH al Pi +
`curl -i` directo contra `POST /auth/v1/invite` con apikey anon.

## Qué se decidió

- El bloqueo **ya no está activo**. Misma IP de salida del Pi que en septiembre
  (`201.141.17.29`, sin cambio) — la respuesta ahora es JSON real de GoTrue (`401
  no_authorization`, headers `sb-project-ref`/`sb-request-id` presentes), no el HTML de bloqueo de
  Cloudflare ("Sorry, you have been blocked") de antes.
- No se investigó la causa de la resolución (si fue el ticket de soporte de Supabase o Cloudflare
  liberándolo solo) — no era parte del pedido.
- CLAUDE.md actualizado: el gotcha correspondiente se marcó `[RESUELTO el 22 de septiembre de
  2026]` con la evidencia de la verificación, sin borrar el historial del hallazgo original.

## Qué quedó pendiente

- No se revisó si el ticket abierto con soporte de Supabase sigue abierto o fue cerrado por ellos.
- No se hizo una prueba end-to-end real de "Alta de usuario" desde el Pi (a propósito, para no
  disparar una invitación real) — la verificación fue sólo a nivel de red/WAF.

## Preguntas nuevas

- Ninguna.

## Nota para la retrospectiva

Segunda vez que un bug de infraestructura externa (bloqueo de IP en un WAF ajeno) se documenta
como gotcha vigente y después se verifica resuelto en una sesión aparte, sin volver a tocar
código — vale la pena, cuando se documenta un bloqueo de este tipo, dejar planteada la pregunta de
"¿cómo se yo cuándo esto se resuelve?" desde el principio, no sólo describir el síntoma.
