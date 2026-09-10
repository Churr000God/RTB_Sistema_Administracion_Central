# 2026-09-07 · Registro de marcas — hora del dispositivo editable y motivo de revisión visible

**Participantes:** Diego (usuario), `orchestrator` + equipo de 6 especialistas (`db`/`security`/
`backend`/`frontend`/`testing`) vía `team-orchestrator`.
**Duración:** una sesión, modo Plan (`ExitPlanMode`), exploración previa con 2 agentes `Explore` en
paralelo (DDL/docs y backend+frontend).

---

## Qué se hizo

El usuario pidió "agregar" `momento_dispositivo`, su desfase local, y el motivo de
`requiere_revision` a `tiempo.marca`. La exploración mostró que los tres ya existían — se
restauraron en `bitacora/2026-09-05_reconciliacion_registro_marcas.md` — así que el trabajo real
fue otro: la captura manual forzaba `momento_dispositivo = momento_recepcion = now()`
(perdiendo la hora real del evento) y la UI no exponía ni `momento_dispositivo` ni
`motivo_revision` pese a que el backend ya los tenía disponibles.

**`db/ddl/61_tiempo_marca_ventana_captura_manual.sql`:** endurece la policy
`marca_insert_captura_manual` (antes sólo exigía `origen = 'captura_manual'`) con un `WITH CHECK`
que agrega `momento_dispositivo <= now()`, `momento_dispositivo >= now() - interval '90 days'` y
`estado_reloj = 'sincronizado'` — techo duro de respaldo si alguien bypasea FastAPI directo por
PostgREST, ya que `routers/marcas.py` usa `get_caller_client` (RLS es la autorización real, no
`service_role`). `security` revisó la policy antes de aplicarla; encontró que faltaba fijar
`estado_reloj` (impacto bajo — sólo generaría una excepción espuria de `reloj_no_sincronizado`,
no una escalación — pero gratis de cerrar) y se sumó en la misma migración. Sin `ALTER TABLE`,
ninguna columna nueva — sólo policy + `COMMENT ON COLUMN` (`momento_dispositivo` nunca tuvo uno
propio; el de `estado_reloj` se corrigió porque ya no es cierto que en captura manual "siempre sea
sincronizado, tomado del reloj del servidor").

**Backend:** `schemas/marcas.py::MarcaCapturaManualCreate` gana `momento_dispositivo: datetime |
None = None` (`None` = comportamiento anterior). `routers/marcas.py` valida hora futura (422) y
ventana de días hábiles de `tiempo.parametro.dias_habiles_correccion_marca` (422) cuando viene un
valor explícito; `_desfase_local_en(momento)` calcula el desfase vigente en ese instante, no en
"ahora" (`SCJ-CDT-01 §VII.1` — hoy da lo mismo en México sin horario de verano, pero la firma
correcta evita una migración de datos si eso cambia). `GET /api/marcas` ahora resuelve
`motivos_revision` por marca con una consulta batch a `tiempo.excepcion` (mismo criterio de "no
consultar si no hace falta" que ya usaba `_resolver_nombres_persona`). Refactor de paso: los
helpers de días hábiles de `routers/correcciones.py` se movieron a `app/dias_habiles.py` para
reusarlos sin duplicar lógica de calendario. Catálogo nuevo `app/catalogo_motivos_revision.py` con
los 6 motivos reales (`reloj_no_sincronizado`, `persona_inactiva`, `dia_cerrado`,
`fuera_de_horario`, `paridad_impar`, `plantilla_desconocida`); `batches/cierre_dia.py` importa la
constante desde ahí en vez de tener el string suelto.

**Frontend:** `lib/motivosRevision.ts` (nuevo) — espejo del catálogo backend, con
`etiquetaMotivo(motivo)` que separa el sufijo que `fn_ausencia_resuelve_excepcion` concatena al
resolver una excepción (`" — resuelto por ausencia autorizada/rechazada..."`) y traduce sólo la
parte anterior, preservando el sufijo tal cual. `RegistroMarcasPage.tsx` gana columna "Ocurrió"
(`momento_dispositivo` + `desfase_local`) junto a "Recibida", y motivos etiquetados bajo el badge
de revisión. `CapturaManualMarcaPage.tsx` gana un `datetime-local` para el momento del evento
(default: ahora), reemplaza el subtítulo que decía "nadie la escribe a mano", y muestra ambas
horas en la confirmación. `ColaExcepcionesPage.tsx` reemplaza su diccionario local de etiquetas
por el módulo compartido. Decisión de diseño de `frontend` no cubierta en el plan: las tres
pantallas ahora muestran las mismas etiquetas crudas del catálogo unidas por coma (antes
`CapturaManualMarcaPage` armaba una frase tipo oración) — se prefirió consistencia entre pantallas
sobre la redacción particular de una sola.

**Testing:** 4 casos nuevos backend (`test_marcas.py`: hora pasada válida, futuro → 422, fuera de
ventana → 422, listado con motivos), 9 nuevos frontend (incluido `motivosRevision.test.ts`, nuevo,
con el caso del sufijo concatenado que motivó crear el módulo). `uv run pytest`: 278/278. `npm
test`: 396/396. Sin bugs reales encontrados en el código de producción.

## Qué se decidió

- Captura manual con hora editable, no fija a "ahora" — validada contra futuro y contra la misma
  ventana de días hábiles que ya usa la corrección de marca (`dias_habiles_correccion_marca`), sin
  parámetro separado nuevo.
- Alcance de UI: las tres pantallas (captura manual, registro en vivo, cola de excepciones), no
  sólo el listado.
- Catálogo de motivos en código (`catalogo_motivos_revision.py` + `motivosRevision.ts`), sin
  `CHECK` en la base — un constraint sobre `motivo_revision` chocaría con la concatenación de
  `fn_ausencia_resuelve_excepcion`, que depende de que el campo sea texto libre.
- RLS pone el techo duro (90 días calendario, backstop de bypass directo); el backend calcula la
  ventana fina en días hábiles y da el mensaje legible — mismo reparto que la protección del
  puesto administrador.

## Qué quedó pendiente

- Ninguno abierto por este corte. El pendiente de "Movimiento de saldo" (módulo Parámetros) sigue
  igual, sin relación con este trabajo.

## Preguntas nuevas

-

## Nota para la retrospectiva

La migración `61_*.sql` no se pudo aplicar por `psql` desde esta sesión ni desde la shell real del
usuario — el TCP conecta contra el pooler de Supabase (confirmado con `openssl s_client`) pero el
handshake de Postgres/TLS nunca completa, en ambos entornos. Se aplicó manualmente pegando el
archivo en el SQL Editor del dashboard de Supabase. Señal a vigilar: si vuelve a pasar con otra
migración, no vale la pena reintentar `psql` más de 2-3 veces — ir directo al SQL Editor.
