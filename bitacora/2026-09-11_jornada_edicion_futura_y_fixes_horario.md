# 2026-09-11 · Cuatro bugs de horario/tramos + editar/eliminar jornadas futuras

Sesión larga con el equipo de 6 especialistas vía `team-orchestrator`, en dos bloques: primero una
tanda de bugs reales encontrados por el usuario probando en vivo, después una feature nueva de
punta a punta (diseñada en modo Plan, con exploración previa de `backend`/`db`/`frontend`).

## Bloque 1 — cuatro bugs encadenados, todos del mismo origen

El disparador: una marca real de captura manual (persona `9ea34b1d...`, ayer 7:30pm) se marcó
como "fuera de horario laboral" pese a tener jornada flexible, y el tramo correspondiente no
cerraba al usar "Revisar" en la pantalla Días. Investigando esa cadena aparecieron 4 causas
independientes, cada una arreglada por el especialista de dominio correspondiente:

1. **Trigger `fn_marca_valida_revision` ignoraba `genera_alerta_horario`** — disparaba la alerta
   de horario también para jornada flexible. Fix: `db/ddl/72_*.sql`, commit `9bdca5a`.
2. **La causa raíz real**: `routers/marcas.py::_desfase_local_en()` calculaba el offset horario
   con `datetime.astimezone()` sin argumento — resuelve la zona del **sistema operativo del
   contenedor Docker** (siempre UTC, ningún Dockerfile fija `TZ`), no la de México (UTC-6).
   Afectaba el 100% de las capturas manuales. Fix: `ZoneInfo("America/Mexico_City")` +
   `tzdata` agregado como dependencia incondicional en `pyproject.toml` (antes sólo marcado para
   `win32`). Commits `16bac6e` (backend) + `devops` confirmó `tzdata` funcionando en contenedor
   real dev y prod. Las 2 marcas reales afectadas se corrigieron a mano (`desfase_local=-06:00`)
   con aprobación explícita del usuario en la sesión de `db` (su classifier de permisos bloqueó
   el UPDATE hasta esa aprobación directa).
3. **Columnas ambiguas en `fn_dia_calcular_armado_tramos`** (`65_*.sql`) — `marca_apertura_id` e
   `inicio` colisionaban con los nombres de columna de salida de la función (`RETURNS TABLE`),
   nunca se había detectado porque nunca corrió con un tramo huérfano real. Bloqueaba tanto la
   previsualización como el POST real de "Revisar" (que la llama internamente). Fix: alias de
   tabla en el `SELECT` del loop, `db/ddl/73_*.sql`, commit `534cadf`. De paso, `backend` agregó
   `try/except` a `previsualizar_tramos` + un `exception_handler` global en `main.py` que agrega a
   mano los headers CORS en 500 no anticipados (Starlette conecta el handler de `Exception` fuera
   de `CORSMiddleware` — registrar el handler solo no alcanza), commit `5b87f8e`.
4. **Excepciones "de día" (`marca_id=NULL`, motivo `paridad_impar`) nunca se auto-resolvían** al
   revisar un día exitosamente — quedaban `pendiente` para siempre, sin ningún endpoint que las
   resuelva a mano. Confirmado contra `SCJ-DEC-07` que el diseño sí espera auto-resolución.
   Fix: `fn_dia_revisar` ahora también resuelve por `dia_id` (no sólo por `marca_id`),
   `db/ddl/74_*.sql`, commit `c3f76e2`. De paso, `frontend` encontró y arregló que la Cola de
   Excepciones filtraba (`marca_id !== null`) ocultando exactamente este tipo de excepción,
   commit `a0d6157`.

Cada fix se aplicó y verificó contra la BD real (sólo lectura para diagnosticar, escritura
puntual sólo con aprobación explícita cuando tocó datos reales).

## Bloque 2 — editar/eliminar jornadas futuras

El usuario ya puede precargar hoy un plan de varios meses de `jornada_asignada` (el RPC de
asignar/renovar acepta `vigente_desde` futura sin restricción), pero no había forma de corregir un
error de captura sin recomenzar de cero. Se diseñó en modo Plan (2 agentes Explore en paralelo +
1 agente Plan, ver `/home/diego/.claude/plans/dise-alo-e-implementalo-cryptic-wave.md`) y se
implementó en 3 fases delegadas:

- **Fase 1 (`db`)**: 4 triggers nuevos (`75_tiempo_jornada_asignada_proteccion_vigencias.sql`) que
  cierran un hueco de RLS real — las policies de `39_*.sql` permitían `UPDATE`/`DELETE` sin
  restricción de fecha a cualquiera con el permiso. Los triggers hacen lo que una policy no puede
  (comparar contra `OLD`, evitar recursión de RLS al validar "es la última de la cadena", abortar
  en vez de filtrar en silencio). Más 3 RPCs nuevos (`76_*.sql`):
  `fn_jornada_futura_eliminar`, `fn_jornada_futura_actualizar`, `fn_jornada_en_curso_mover_limite`.
  Auditoría previa de integridad de cadenas existentes salió limpia, permitió aplicar también el
  constraint trigger de "cero huecos/traslapes". Commit `2b68771`.
- **Fase 2 (`backend` + `frontend` en paralelo)**: 4 endpoints nuevos
  (`GET .../jornadas`, `PATCH .../{id}`, `PATCH .../{id}/limite`, `DELETE .../{id}`), más el fix
  de dos bugs de paso encontrados en la exploración (`jornada_vigente_de_persona` y
  `personas.py::_resolver_personas_con_jornada_vigente` devolvían "la fila abierta" en vez de "la
  vigente HOY" — visible recién ahora que existen cadenas con jornadas futuras). Commit `dc8bd07`.
  Frontend extendió `AsignarJornadaPage.tsx` (sin pantalla nueva) para mostrar la cadena completa
  con badges Pasada/En curso/Futura, confirmación inline de borrado (mismo patrón sin modal que
  `DiasFestivosPage`), edición in-place reusando el form existente, y mover límite in-row estilo
  `ParametrosSistemaPage`. Commit `9fb22ba`.
- **Fase 3 (`security` + ajustes en vivo)**: verificación de bypass directo por PostgREST con JWT
  real — los 5 casos probados se comportaron como diseñado, incluido el residual conocido
  (`INSERT` en `patron_semanal` de una jornada en curso sí pasa, a propósito). Encontró que este
  proyecto Supabase **no respeta `Prefer: tx=rollback`** — dejó una fila de prueba real
  (`id=21`) que el propio trigger nuevo vuelve irreversible por la vía normal (bloquea
  `UPDATE`/`DELETE` sin excepción de rol). `db` la limpió con `DISABLE TRIGGER` momentáneo +
  `DELETE` puntual + reactivación, y corrigió el comentario del DDL para que el residual quede
  documentado como "irreversible sin superusuario", no como "benigno". Commit `0016dab`.

Mientras se probaba en vivo, el usuario pidió 3 ajustes más, todos resueltos en el mismo corte:
mostrar las horas/semana esperadas calculadas del patrón (mismo componente compartido
`DetalleJornadaAsignada`, usado también en `FichaPersonaPage`), refrescar la cadena expandida tras
crear/renovar una jornada sin recargar la página, y arreglar espaciado visual + que "Cancelar" ya
no redirija a `/personas`. Commits `2ecdc55` y `3d579fd`.

## Incidente de seguridad, aparte

Al correr manualmente el login de prueba para `security`, el usuario pegó su contraseña en texto
plano en el chat de esa sesión por accidente. `security` lo señaló de inmediato, no la registró en
ningún archivo, y recomendó rotarla vía "olvidé mi contraseña".

## Pendiente

- El comportamiento con `CURRENT_DATE` de los triggers/RPCs nuevos evalúa "hoy" en **UTC** (`db`
  confirmó `SHOW timezone` → UTC), no en hora real de México (UTC-6) — ventana de hasta 6h
  (medianoche-6am CDMX) donde el servidor ya cree que es "mañana". Documentado, no corregido en
  este corte — decisión pendiente del usuario si hace falta fijar timezone o usar
  `(now() AT TIME ZONE 'America/Mexico_City')::date` en los chequeos de fecha.
- Nada de lo de hoy se pusheó a GitHub ni se desplegó al servidor de pruebas del Pi — todo quedó
  en commits locales de este repo, pendiente de que el usuario decida cuándo sincronizar.
- QA visual completo en navegador del editar/eliminar de jornadas futuras quedó pendiente de que
  el usuario lo termine de probar él mismo (los agentes no pueden loguearse — prohibido escribir
  contraseñas).
