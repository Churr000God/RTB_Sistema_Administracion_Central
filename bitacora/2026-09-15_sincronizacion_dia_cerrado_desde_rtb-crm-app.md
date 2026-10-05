# 2026-09-15 · — Sincronización de fix "día cerrado revisable" desde RTB-CRM-APP (sentido inverso)

**Participantes:** usuario, `orchestrator` (equipo de 6 especialistas vía `team-orchestrator` en
RTB-CRM-APP: `db`/`backend`/`frontend`/`security`/`devops`; portado a este repo directo por
`orchestrator`, sin sesión de sync dedicada)
**Duración:** una sesión larga (bug real encontrado en vivo → diagnóstico en cascada → fix →
despliegue en RTB-CRM-APP → sincronización a este repo)

---

## Qué se hizo

Dirección inversa a la habitual (`CLAUDE.md`: DDL/fixes se diseñan aquí y se copian a RTB-App,
nunca al revés) — igual que el 11 y 12 de septiembre, el trabajo urgente se hizo directo en
`RTB-CRM-APP` (bug real encontrado por el usuario probando en producción de pruebas) y tocó
portarlo hacia acá.

**El bug real** (RTB-CRM-APP, commit `e5408ba`): un día cerró con paridad par (`tiempo.dia.estado
='cerrado'`, sin alerta, sin excepción de día) pero en realidad faltaban 2 marcas — capturadas un
día después vía captura manual. `tiempo.fn_dia_calcular_armado_tramos` sí las detectaba y armaba
el par correcto (confirmado en vivo, 180 minutos listos), pero ningún camino de escritura admitía
un día `cerrado`: tanto la policy `dia_update_revision` como el chequeo interno de `fn_dia_revisar`
exigían `estado = 'bloqueado'` a secas. Ese tiempo quedaba muerto para siempre — sin tramo, sin
horas, sin ningún RPC que lo reparara. `SCJ-DEC-06` sólo modeló la transición `bloqueado ->
revisado` porque el caso original era paridad impar; nunca contempló una marca tardía sobre un día
que cerró completo.

De paso, investigando por qué las 2 excepciones de esas marcas (`motivo=dia_cerrado`) ya
aparecían `estado='resuelto'` sin que ningún mecanismo del código las hubiera resuelto, se encontró
un hallazgo de seguridad real y aparte: cualquiera con el permiso `excepcion_edicion` podía
resolver **cualquier** excepción pendiente por PostgREST directo, incluida `dia_cerrado` — que por
diseño nunca debería tener vía de resolución humana directa (sólo automática, dentro de
`fn_dia_revisar`).

- **DDL**: 3 archivos nuevos, renumerados `77_.._79_` (RTB-CRM-APP) → `76_.._78_` (encajan en la
  secuencia local, que llegaba hasta `75_*.sql` sin commitear) — referencias cruzadas internas
  ajustadas (los archivos se citan entre sí por número, y el archivo `74_*.sql` de RTB
  correspondía a `73_*.sql` acá por una numeración ya divergente de antes).
  - `76_*.sql`: `dia_update_revision` (RLS) y `fn_dia_revisar` (RPC) amplían el chequeo de estado
    de `'bloqueado'` a `'bloqueado' O 'cerrado'` — mismo algoritmo, sin rama nueva
    (`fn_dia_calcular_armado_tramos` ya era agnóstico al estado).
  - `77_*.sql`: constraint trigger `DEFERRABLE INITIALLY DEFERRED` (primero del proyecto) sobre
    `tiempo.excepcion` — bloquea que una excepción `motivo=dia_cerrado` pase a `resuelto` fuera de
    `fn_dia_revisar`. Evalúa al COMMIT si el día terminó `revisado` en la misma transacción (única
    forma de distinguir el caso legítimo del ilegítimo, dado que ambos comparten el mismo rol/
    permiso — `fn_dia_revisar` es `SECURITY INVOKER`).
  - `78_*.sql`: `GRANT EXECUTE` de `fn_dia_calcular_armado_tramos` a `service_role` (bloqueador
    real: `GET /api/dias` la llama con `service_role`, que no es miembro de `authenticated`).
- **Backend**: `routers/dias.py` — mensaje 409 y docstrings actualizados (`bloqueado ni cerrado` /
  `bloqueado/cerrado -> revisado`), nueva `_resolver_tiene_marcas_por_armar` (llama la RPC de
  cálculo por cada día `cerrado` de la página, criterio deliberadamente NO basado en
  `excepcion.estado` porque puede quedar `resuelto` sin resolución real — ver hallazgo de
  seguridad arriba). `schemas/dias.py` suma `tiene_marcas_por_armar: bool | None`.
- **Frontend**: `DiasPage.tsx` — botón "Revisar" ahora también aparece en días `cerrado`, pero
  gateado por `tiene_marcas_por_armar === true` (no por el estado a secas, para no mostrarlo en
  TODO día cerrado sin necesidad real). Badge nuevo "Cerrado" en la columna Estado.
- **Tests**: 453 backend + 503 frontend en verde después de portar (incluida la suite completa,
  no sólo `test_dias.py`/`DiasPage.test.tsx`) — se corrió la suite completa del lado receptor antes
  de commitear, práctica que quedó anotada como lección en la sincronización del 11-sep anterior.

## Qué se decidió

- **Gatear el botón por un flag de negocio (`tiene_marcas_por_armar`), no por el estado del día a
  secas.** Primer diseño (día `cerrado` ⇒ botón visible siempre) fue objetado por el propio
  `frontend` de RTB-CRM-APP: iba a aparecer en TODO día cerrado, no sólo los que tienen marca
  tardía real. El usuario pidió refinar antes de dar por bueno el fix — se resolvió con un flag
  calculado en backend a partir de `fn_dia_calcular_armado_tramos`, no de la tabla `excepcion`
  (que resultó no ser confiable por el hallazgo de seguridad).
- Renumerar el DDL importado (`77`-`79` de RTB → `76`-`78` acá) en vez de dejar los números
  originales — mismo criterio que la sincronización anterior, mantiene la secuencia local
  contigua.
- No aplicar todavía este DDL contra el Supabase propio de este proyecto (académico) — sólo se
  agregó como migración versionada. Pendiente de decisión del usuario (ver abajo).

## Qué quedó pendiente

- **Aplicar el DDL (`76`-`78`) contra el Supabase real de este proyecto académico**, si el usuario
  lo quiere para poder probar el flujo en vivo acá también — no se hizo en este corte, sólo se
  versionó el archivo.
- El hallazgo de seguridad de `tiempo.excepcion` (excepciones `dia_cerrado` resolubles por
  PostgREST directo) ya viene con su fix incluido en este mismo corte (`77_*.sql`) — no queda
  pendiente aparte, pero vale la pena que quien siga el proyecto entienda que fue un hallazgo
  colateral, no el bug original reportado.
- Actualizar `CLAUDE.md` de este repo con la entrada del módulo Tramos y Días (hecho, ver commit) —
  pero **no** se tocó el resto del backlog de sincronización que ya estaba pendiente antes de esta
  sesión (edición de personas/jornada asignada futura, etc. — ver `bitacora/
  2026-09-11_sincronizacion_desde_rtb-crm-app.md`, ese trabajo sigue sin commitear en este repo,
  archivos aparte, no tocados por esta sincronización).

## Preguntas nuevas

- Ninguna nueva de este corte específico.

## Nota para la retrospectiva

Segunda vez que un bug real de "día cerrado con marca tardía" expone que `SCJ-DEC-06` modeló sólo
un caso (paridad impar) de un problema más general (marca tardía en cualquier día ya no-`abierto`).
El fix de hoy cierra el caso `cerrado`, pero el propio diseño del gate de UI (flag calculado en
vivo contra la RPC, no contra una tabla de estado) es un patrón reusable si aparece un tercer caso
similar — mejor que agregar otra excepción hardcodeada al chequeo de estado.
