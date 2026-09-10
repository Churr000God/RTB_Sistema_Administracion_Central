# 2026-09-08 · Alertas preventivas de corte quincenal — Días (banner) + Banco de Horas (corte pendiente)

**Participantes:** Diego (usuario), `orchestrator` + `backend` + `frontend` vía `team-orchestrator`.
**Duración:** un corte, sin DDL — investigación en caliente disparada por una duda del usuario
(por qué "Encargado de Sistemas" no tenía fila en Banco de Horas), 2 rondas de `AskUserQuestion`
(la segunda corrigió el diseño de la primera tras un hallazgo real), plan mode, delegación
secuencial `backend` → `frontend`.

---

## Qué se hizo

El usuario preguntó por qué una persona con jornada `flexible` no tenía fila en Banco de Horas.
Investigando la respuesta ("no corrió corte quincenal todavía para su periodo") surgieron dos
dudas de seguimiento: cómo saber a quién le va a fallar el corte antes de que corra, y cómo saber
a quién nunca se le corrió el corte correspondiente.

**El hallazgo que cambió el diseño a medio camino:** la condición real que bloquea a una persona
en `corte_quincenal.py::_procesar_persona` es `dia is None or dia["estado"] == "abierto"`. Grep
exhaustivo en `db/ddl/*.sql` y `backend/app/` confirmó que **ningún código escribe nunca
`tiempo.dia` con `estado='abierto'`** — es sólo el `DEFAULT` de la columna, sin escritor real
(`cierre_dia.py`, `de_confianza.py`, `fn_ausencia_resuelve_excepcion` siempre escriben
`cerrado`/`bloqueado` explícito). En la práctica, lo que bloquea el corte es una **fila ausente**
(persona con cero marcas ese día) — el hueco ya documentado a propósito como pendiente en
`SCJ-PRA-01 #14` ("relleno de día bloqueado"). Esto invalidó el primer diseño acordado con el
usuario ("badge en la fila de Días") — no hay fila real que marcar en el caso común — y se volvió
a preguntar antes de seguir: la alerta de Días pasó a ser un **banner resumen** (persona + fechas
faltantes), no un badge por fila.

**Backend**, cambio mínimo y de bajo riesgo sobre código ya testeado: `_procesar_persona` (15
tests existentes la llaman posicional) sumó un kwarg-only `solo_simular: bool = False` — los 2
`_aplicar_persona(...)` internos quedan detrás de `if not solo_simular`, sin tocar ningún otro
comportamiento. Nuevo módulo `backend/app/prevision_corte_quincenal.py` que reusa por import
directo (cross-módulo, incluso símbolos con guión bajo, documentado) la lógica ya escrita de
elegibilidad de periodo/jornada/festivos de `corte_quincenal.py` — mismo criterio que evitó una
tercera reconstrucción de "hora local" al crear `alertas_horario.py`. Dos funciones:
`resolver_dias_faltantes` (periodo EN CURSO, enumera TODAS las fechas faltantes por persona, a
diferencia de `_procesar_persona` que corta en la primera) y `resolver_personas_con_corte_pendiente`
(último periodo YA VENCIDO, simula con `solo_simular=True` y marca como pendiente a cualquiera que
no devuelva `SALTADA_YA_PROCESADA`).

`GET /api/dias/pendientes-corte-quincenal` (nuevo) alimenta el banner. `GET /api/banco-de-horas`
suma `corte_pendiente` por persona (para el último periodo vencido) más filas sintéticas
(`monto=0`) para quien nunca tuvo fila real en `tiempo.banco_de_horas` — antes esas personas eran
invisibles en la pantalla por completo.

**Frontend**: banner colapsable en Días (patrón crudo `aria-expanded`+Chevron de `AppShell.tsx`,
arranca expandido, fetch propio al montar, falla en silencio — puramente informativo). Badge
"Corte pendiente" + métrica nueva en Banco de Horas. Un detalle de texto se corrigió en revisión:
el primer borrador del `title` del badge decía "periodo actual", pero `corte_pendiente` en Banco de
Horas es sobre el **último periodo ya vencido** — concepto distinto del banner de Días.

## Qué se decidió

- La alerta de Días es un banner, no un badge por fila — corregido a medio plan tras confirmar que
  el caso real es "fila ausente", no "fila con estado abierto".
- Reusar `_procesar_persona` real (con flag de simulación) en vez de escribir una segunda
  implementación de la regla de negocio — riesgo de divergencia futura descartado desde el diseño.
- Banco de Horas muestra personas con corte pendiente aunque nunca hayan tenido fila real — con
  saldo sintético en 0, para que RH las vea en vez de que sean invisibles.
- Esto es diagnóstico puro, no repara nada — no crea días, no dispara ningún corte. Explícitamente
  comunicado al usuario al cierre del corte.

## Qué quedó pendiente

- El hueco de fondo (`SCJ-PRA-01 #14`, "relleno de día bloqueado") sigue sin resolverse — este
  corte sólo lo hace visible antes de tiempo, no lo repara.
- `GET /api/banco-de-horas` ahora simula `_procesar_persona` para todas las personas normal/
  flexible en cada request (mismo trabajo que el batch real, sin escribir) — aceptable a la escala
  actual (decenas de personas), sin caché. Revisar si el volumen crece mucho.
- No se agregó ningún acceso directo desde el banner de Días a la pantalla de captura manual — RH
  tiene que ir por su cuenta a resolver cada fecha listada.

## Preguntas nuevas

-

## Nota para la retrospectiva

Segunda vez en el día (después de Banco de Horas) que una exploración a fondo antes de diseñar
evita construir sobre una premisa equivocada — acá, a medio plan, no antes de empezar: el primer
`AskUserQuestion` asumió que "abierto" era un estado real y visible, y sólo al escribir el módulo
compartido se confirmó por grep que nunca ocurre en la práctica. Volver a preguntar en cuanto se
encontró la discrepancia, en vez de seguir con el diseño ya aprobado, evitó un banner/badge que no
habría mostrado nada útil en el caso real.
