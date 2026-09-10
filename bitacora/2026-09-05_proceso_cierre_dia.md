# 2026-09-05 · Sesión — Proceso de cierre de día (`SCJ-PRO-12`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (sexto proceso seguido en el mismo día, después de
`SCJ-PRO-07` a `11`).

---

## Qué se hizo

Discutido en el chat, escrito `SCJ-PRO-12`: cierre de día para jornadas `normal`/`flexible`. Es el
primer proceso puramente de sistema (lo dispara el reloj, no un usuario resolviendo algo), y del
que ya dependían `SCJ-PRO-08`/`10`/`11` sin que existiera todavía.

**Decisión de orquestación** (lo que el usuario planteó explícito): combinación de job programado
en el backend + botón manual, ambos invocando la misma función — reintentar y reprocesar son la
misma operación porque el batch es **idempotente por persona** (una persona con `tiempo.dia` ya
resuelto se salta sola). 3 reintentos automáticos antes de quedar `fallida` esperando el botón.

Implementado de una vez en `db/ddl/`:

- `tiempo.corrida_batch` (tabla nueva, 16ª del esquema) — estado visible de cada corrida
  (`tipo_batch`, `fecha`, `estado`, `intentos`, `iniciado_en`/`terminado_en`, `detalle`). Sirve
  para los tres batches (cierre de día, corte quincenal, `de_confianza`), no sólo éste.
- `tiempo.parametro.hora_corrida_cierre_dia` (ejemplo `03:00`) — colchón después de
  `hora_corte_dia` para dar tiempo a que los terminales sincronicen antes de que el batch corra.
- **Corregido de paso:** `tiempo.dia.origen` tenía `'terminal'` en el `CHECK` por error — nunca se
  usó (el caso de marcas reales siempre fue `NULL`, no un valor explícito). Se quitó y se agregó
  `'ausencia_autorizada'`, el tercer caso real que este batch necesita (día resuelto contra una
  ausencia, no contra marcas). Corregido también en Lucid V2.

`SCJ-MOD-02` sube a **V2.2** (agrega `corrida_batch` + corrige `dia.origen`). `SCJ-DIC-01`
actualizado (16 tablas, nuevos enumerados `tipo_batch`/`estado_batch`).

**El algoritmo del batch en sí (recorrer personas, armar tramo, decidir estado del día) queda
diseñado pero NO implementado** — es la pieza de más riesgo del subsistema (afecta cálculo de
horas), se construye con pruebas reales, no de un intento sin verificar.

## Qué se decidió

- **Job + botón manual, misma invocación** — no son dos rutas distintas.
- **Colchón fijo de 3am, como parámetro** — mismo patrón que el resto del proyecto, no
  hardcodeado.
- **Idempotencia por persona**, no por corrida completa — permite que "reintentar 3 veces" y
  "reprocesar con el botón" sean la misma operación sin rastrear qué falló específicamente. Una
  persona que revienta no detiene a las demás.
- **`tiempo.corrida_batch` centraliza el estado visible** de los tres batches, no sólo de éste.
- **Día sin marca y sin ausencia → se crea la ausencia, el día NO se materializa todavía** — sólo
  cuando la ausencia se resuelve, el día queda con `origen='ausencia_autorizada'`.

## Qué quedó pendiente

- **El batch en sí** (la función que recorre personas y aplica el algoritmo) — diseñado, no
  construido.
- **Extender `fn_ausencia_resuelve_excepcion`** (o un disparador nuevo) para que, al resolver una
  ausencia, también materialice `tiempo.dia` — hoy sólo cierra la `excepcion`. `SCJ-PRA-01 #13`.
- **`horas_totales` de un día `bloqueado` (paridad impar)** — `SCJ-ESP-01 §VI.2` exige rellenarlo
  con la jornada pactada, esta ronda no lo discutió con el usuario. `SCJ-PRA-01 #14`.
- Job del backend + endpoint del botón manual — no existen.
- RLS de `tiempo.corrida_batch`/`tramo`/`dia` — no existen.

## Preguntas nuevas

- `SCJ-PRA-01 #13` — extender el trigger de ausencia para materializar `tiempo.dia`.
- `SCJ-PRA-01 #14` — relleno de `horas_totales` en día bloqueado.

## Addendum (mismo día): se resolvieron los 2 huecos

El usuario pidió resolver los dos huecos de inmediato en vez de dejarlos para la empresa real.

- **`SCJ-PRA-01 #13`, resuelto:** `fn_ausencia_resuelve_excepcion` (`db/ddl/02_tiempo.sql`) ahora
  también materializa `tiempo.dia` para cada fecha del rango de la ausencia —
  `vacaciones`/`permiso_con_goce`/`incapacidad` autorizada cuenta como jornada completa (calculada
  contra `jornada_asignada`/`patron_semanal` vigente esa fecha); `permiso_sin_goce` o `falta`
  rechazada cuenta cero. `ON CONFLICT (persona_id, fecha) ... WHERE estado='abierto'` — nunca pisa
  un día que ya se resolvió por otra vía (idempotente, mismo criterio que el resto del batch).
- **`SCJ-PRA-01 #14`, parcialmente resuelto:** el usuario confirmó la regla propuesta — un día
  `bloqueado` se excluye del corte quincenal hasta pasar a `revisado`. Como le gustó también para
  la empresa real, se actualizó `SCJ-ESP-01` (sube a **V2.1**, menor — precisa §VI.2, no contradice
  nada). Sigue abierto sólo el **valor exacto** del relleno de `horas_totales` mientras el día está
  bloqueado (no importa para el cálculo, pero sí para mostrarlo) — eso sí se deja para la empresa
  real.

`SCJ-MOD-03` sube a **V1.5** (agrega la extensión del trigger como restricción activa). `SCJ-TRZ-01`
y `SCJ-PRA-01` actualizados a juego.

## Nota para la retrospectiva

Esta fue la sesión de diseño más grande del día (6 procesos seguidos, `SCJ-PRO-07` a `12`) y
también la más deliberadamente incompleta a propósito: se decidió NO implementar el algoritmo
central del batch (el mayor riesgo, afecta cálculo de horas/nómina), pero sí sus dos huecos de
soporte en cuanto se identificaron, porque eran acotados y de bajo riesgo. Buen criterio de corte:
lo grande y riesgoso espera a pruebas reales; lo pequeño y bien definido se cierra en el momento en
vez de acumularse como deuda.
