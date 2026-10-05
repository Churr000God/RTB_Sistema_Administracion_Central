# 2026-09-11 · — Sincronización de fixes/feature desde RTB-CRM-APP (sentido inverso)

**Participantes:** usuario, `orchestrator` (relevo de contexto vía mensaje entre sesiones)
**Duración:** una sesión

---

## Qué se hizo

Dirección inversa a la habitual (`CLAUDE.md`: DDL/fixes se diseñan aquí y se copian a RTB-App,
nunca al revés) — hoy el trabajo urgente se hizo directo en `RTB-CRM-APP` (bugs reales
encontrados en vivo contra la base de producción) y tocó portarlo hacia acá, filtrando cualquier
referencia a la identidad real (RTB/Refacciones Tomás Badillo) antes de aplicar nada. Se revisó
el diff real de 13 commits (`3ca1e66..3e45425`) archivo por archivo — no sólo el resumen que mandó
`orchestrator` — y se encontraron 2 cambios genuinos que el resumen no mencionaba (fix de
`personas.py::_resolver_personas_con_jornada_vigente`, mismo bug que `jornada_vigente_de_persona`;
y los helpers `esFutura`/`esPasadaOhoy`/`hoyISO`/`sumarDiasISO` de `calendario.ts`). Se excluyó a
propósito `db/ddl/71_expediente_documento_ref_formato_rh_eit.sql` y su consumidor en
`routers/personas.py` — el formato de folio que valida (`RTB-RH-EIT-<año>-<número>`) es identidad
real de la empresa, y además es anterior al rango de commits pedido (no era parte de este corte).

- **DDL**: 5 archivos nuevos, renumerados `72_.._76_` → `71_.._75_` para encajar en la secuencia
  local (llegaba hasta `70_*.sql`) — incluidas las referencias cruzadas internas entre ellos
  (comentarios que se citan por número de archivo).
  - `71_*.sql`: `fn_marca_valida_revision` ahora respeta `genera_alerta_horario` (jornada
    flexible/de confianza no debía generar `fuera_de_horario`).
  - `72_*.sql`: alias de tabla en `fn_dia_calcular_armado_tramos` — columnas ambiguas bloqueaban
    "Revisar" un día con tramo huérfano.
  - `73_*.sql`: `fn_dia_revisar` ahora también resuelve excepciones "de día" (`marca_id NULL`,
    `paridad_impar`), antes quedaban pendientes para siempre.
  - `74_*.sql`: 4 triggers de protección sobre `tiempo.jornada_asignada`/`patron_semanal` — cierra
    un hueco real de RLS (`UPDATE`/`DELETE` sin restricción de fecha desde `39_*.sql`).
  - `75_*.sql`: 3 RPCs nuevos — editar/eliminar jornada futura, mover el límite de la en curso.
- **Backend**: `main.py` (exception handler global con headers CORS a mano — Starlette conecta el
  handler de `Exception` fuera de `CORSMiddleware`), `marcas.py` (`_desfase_local_en` usa
  `ZoneInfo("America/Mexico_City")` explícito en vez de `astimezone()` sin argumento — en Docker
  daba `+00:00` siempre), `dias.py` (captura `APIError` en `previsualizar_tramos`), `personas.py` +
  `jornada_asignada.py` (bug de "vigente hoy" vs. "fila abierta" — filtrar sólo por
  `vigente_hasta IS NULL` contaba una jornada futura precargada como vigente), 4 endpoints nuevos
  de `jornada_asignada.py` (`GET .../jornadas`, `PATCH .../{id}`, `PATCH .../{id}/limite`,
  `DELETE .../{id}`). `tzdata` agregado a `pyproject.toml` (dependencia real de `ZoneInfo` en
  Docker). 452 tests de backend en verde (incluida la migración completa de
  `test_jornada_asignada.py`, que pasó de 477 a 893 líneas).
- **Frontend**: `calendario.ts` gana `hoyISO`/`esFutura`/`esPasadaOhoy`/`sumarDiasISO`;
  `ColaExcepcionesPage.tsx` deja de ocultar las excepciones de día; `DiasFestivosPage.tsx` usa los
  helpers nuevos; `DetalleJornadaAsignada.tsx` calcula horas/semana del patrón (el campo de la DB
  siempre es `NULL`); `AsignarJornadaPage.tsx` gana la cadena completa de jornadas en la fila
  expandible (badges Pasada/En curso/Futura) con editar/eliminar/mover límite in-place. 503 tests
  de frontend en verde, `tsc --noEmit` limpio.

## Qué se decidió

- **No copiar el comportamiento de "cerrar el formulario tras éxito" de `AsignarJornadaPage.tsx`
  tal cual venía en RTB.** El diff real traía `limpiarFormulario()` cerrando el formulario
  (`setFormAbierto(false)`) después de un alta exitosa — pero el archivo de pruebas ya en este
  repo (`AsignarJornadaPage.test.tsx`, sin tocar por esta sincronización) exige lo contrario: el
  formulario se queda montado con los campos reseteados, decisión propia de una sesión anterior
  (agregó el botón de cabecera "Asignar o renovar jornada"/"Ocultar formulario" como affordance
  explícito). Se mantuvo la decisión local: `limpiarFormulario()` ya no toca `formAbierto`; sólo
  `handleCancelarFormulario` y el éxito de **editar** (acción sobre una fila puntual, no tiene
  sentido seguir con el form abierto) lo cierran explícitamente.
- Renumerar el DDL importado en vez de dejarlo con los números originales de RTB-CRM-APP (`72`-
  `76`) — mantiene la secuencia local contigua y evita que un futuro `71_*.sql` local choque con
  el nombre.
- Excluir `71_expediente_documento_ref_formato_rh_eit.sql` (real, fuera del rango de commits
  pedido, contiene el folio `RTB-` literal).

## Qué quedó pendiente

- Nada del alcance pedido por `orchestrator` — los 13 commits se revisaron todos; sólo el DDL 71
  real (expediente RH/EIT) se dejó fuera, deliberadamente.
- El gotcha de `CURRENT_DATE` evaluando en UTC (no en hora de México) en los triggers/RPCs nuevos
  de `74_*.sql`/`75_*.sql` se documentó en el propio archivo (heredado del real) — no se corrigió,
  mismo criterio que el real: fuera del alcance de este corte.

## Preguntas nuevas

- Ninguna nueva — el flujo de "revisar el diff real en vez de confiar en el resumen de otra
  sesión" encontró 2 cambios no mencionados; vale la pena mantenerlo como práctica default en
  cualquier sincronización futura entre los dos repos, en cualquier dirección.

## Nota para la retrospectiva

Primera sincronización real en sentido inverso (RTB-CRM-APP → académico) desde que existe el
segundo repo. El resumen de la sesión que hizo el trabajo original en el repo real fue útil como
mapa, pero no sustituyó revisar el diff completo — silenciosamente omitía dos archivos que sí
cambiaron. Y migrar features nuevas de un repo a otro con historia divergente (aunque sea por
pocos días) puede pisar una decisión de UX ya tomada localmente si se copia el diff literal sin
antes correr la suite de tests existente del lado receptor — acá lo agarró la corrida de tests,
no una revisión manual.
