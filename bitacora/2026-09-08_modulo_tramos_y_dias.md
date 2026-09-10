# 2026-09-08 · Módulo Tramos y Días — primeras pantallas, primera escritura humana sobre `tramo`/`dia`

**Participantes:** Diego (usuario), `orchestrator` + equipo (`db`/`backend`/`frontend`) vía
`team-orchestrator`, varios cortes delegados a lo largo del día.
**Duración:** una sesión larga, varios ciclos de `EnterPlanMode`/`ExitPlanMode` (uno por corte),
con exploración previa vía agentes `Explore` en paralelo antes de cada plan.

---

## Qué se hizo

`tiempo.tramo` y `tiempo.dia` nunca habían tenido pantalla propia — sólo se leían desde dentro del
sistema (`alertas_de_retardo.py`, `tope_legal.py`, los batches). Este día sumó ambas, de punta a
punta, en varios cortes:

**Corte 1 — `GET /api/tramos` + `TramosPage.tsx`:** listado con búsqueda de persona (texto libre,
resuelta server-side), filtro de rango de fechas, orden y paginación real. `tiempo.tramo` no tiene
`persona_id` ni `fecha` propios — cuelgan de `dia_id`; el embed `dia:dia_id!inner(fecha,
persona_id)` (dentro del mismo esquema `tiempo`) resolvió eso sin necesitar el patrón de segunda
consulta que usa `marcas.py` para cruzar a `personas`. `tramo_lectura` ya existía en el catálogo
(heredable, otorgado a RH/Gerente General/TI) — cero DDL de permisos.

**Corte 2 — botón "Corregir" en Registro de marcas:** se encontró que `tiempo.marca.requiere_revision`
es una bandera de una sola vía (el trigger la pone `true`, nunca la vuelve a `false`) — no servía
para saber si una marca tenía algo pendiente *ahora*. `GET /api/marcas` suma
`excepcion_pendiente_id` (la excepción `pendiente` más antigua de esa marca, si la hay) para que el
botón sólo aparezca cuando de verdad hay algo que resolver.

**Corte 3 — bug real encontrado por el usuario probando en vivo:** tras corregir una marca, "Ocurrió"
seguía mostrando el valor original (por diseño, `SCJ-DEC-03`: `tiempo.marca` es *insert-only*, la
corrección vive en `tiempo.correccion`) y el badge seguía en "Requiere revisión" para siempre.
`GET /api/marcas` suma `momento_efectivo` (corrección aplicada si existe) y `estado_revision`
(`sin_revision`/`pendiente`/`resuelta`, derivado de `excepcion_pendiente_id`) — el frontend deja de
usar el booleano crudo para decidir el badge.

**Corte 4 — `dia_estado` en Tramos:** el usuario notó tramos "En curso" que en realidad nunca iban a
cerrar porque el día quedó `bloqueado`. `tramo:dia_id!inner(...,estado)` suma `dia_estado` a
`TramoListaItem`, badge nuevo en el frontend.

**Corte 5 — pantalla Días, primera escritura humana sobre `tiempo.dia` (`db/ddl/62_*.sql`):**
`SCJ-DEC-06` permite exactamente una transición manual — `bloqueado → revisado` — y hasta hoy no
tenía ningún camino (ni permiso, ni RLS, ni endpoint). Nuevo permiso de **acción** (no de tabla)
`dia_revision_edicion` (heredable, mismo patrón que `corrida_batch_edicion`; deliberadamente no se
llama `dia_edicion`, ese nombre significaría CRUD general). Policy `dia_update_revision` asimétrica
(`USING` exige `bloqueado`, `WITH CHECK` exige `revisado` + `revisado_en` no futuro + `revisado_por`
= el propio caller). RPC `fn_dia_revisar` nuevo (`SECURITY INVOKER`, la policy es la autorización
real), `ERRCODE SCJ06`/`SCJ07`. Columnas de auditoría nuevas `revisado_por`/`revisado_en` en
`tiempo.dia` — decisión propia (no pedida explícitamente) justificada porque `SCJ-DEC-06` exige
poder "demostrar la intervención explícita de RH", imposible sin saber quién y cuándo.

`GET /api/dias` (nuevo router) suma, además del listado con filtros/orden/paginación,
**primera/última marca efectiva** y **dos alertas de horario direccionales e independientes**
(`retardo`/`entrada_anticipada`, `salida_anticipada`/`salida_tardia`) — corrigiendo 3 gaps reales de
`alertas_de_retardo.py` (que usa `abs()` sin dirección, exige que fallen los dos extremos a la vez,
e ignora `tiempo.correccion`) sin tocar esa pantalla. Lógica nueva en `backend/app/alertas_horario.py`,
módulo compartido creado justamente porque ya había **dos** implementaciones divergentes de
"reconstruir hora local" en el proyecto (`cierre_dia.py` robusta, `alertas_de_retardo.py` frágil) —
se copió el criterio robusto para no sumar una tercera copia.

**Corte 6 — horas al revisar, guiado por el usuario probando en vivo:** el RPC sólo cambiaba
`estado`, dejando `horas_totales` en `NULL` para siempre (hueco ya anotado a propósito en
`SCJ-PRA-01 #14`, "relleno de día bloqueado"). Decisión confirmada con el usuario: **RH escribe el
valor a mano** — un día bloqueado es, por definición, un caso que el sistema no puede calcular
solo. `fn_dia_revisar` gana `p_horas_totales numeric` (`ERRCODE SCJ08` si fuera de [0,24]).
`GET /api/dias` suma `excepciones_pendientes` por fila, sólo como guía (el cierre automático
nocturno sigue igual, no se bloquea nada). `TramosPage` deja de decir "En curso" para un tramo cuyo
día está bloqueado/revisado — pasa a "Sin cierre (día bloqueado/revisado)".

**Corte 7 — armar tramos huérfanos al revisar (`db/ddl/64_*.sql`):** el usuario esperaba que 4
marcas corregidas formaran 2 tramos completos al revisar el día — sólo se formaba 1, para siempre.
No era un bug: `fn_correccion_recalcula_tramo` sólo ajusta el `inicio`/`fin` de un tramo al que la
marca **ya** pertenece, nunca la asigna a uno nuevo. Se abrió, deliberadamente, el primer camino de
escritura humana sobre `tiempo.tramo` (hasta entonces cero policies de escritura, "ni siquiera el
botón manual"): `fn_dia_revisar` ahora también cierra tramos abiertos existentes con la marca
huérfana que corresponda cronológicamente y arma tramos nuevos con las que sobran, resolviendo las
excepciones de las marcas emparejadas. Dos policies nuevas (`tramo_insert_revision`,
`tramo_update_revision`) reusando el mismo permiso `dia_revision_edicion` (misma acción humana).

**Corte 8 — previsualización + bloqueo de huérfanas sin pareja (`db/ddl/65_*.sql`):** a pedido del
usuario, el armado de tramos se refactorizó a una función de sólo lectura
`fn_dia_calcular_armado_tramos` (una sola fuente de verdad, `fn_dia_revisar` la reusa para aplicar
de verdad) que además ahora **bloquea todo el revisar** (`ERRCODE SCJ09`) si quedaría una marca sin
pareja — antes se insertaba en silencio un tramo abierto de más. `GET /api/dias/{id}/previsualizar-tramos`
(nuevo) muestra el total calculado ANTES de confirmar; el frontend pasa de un input ciego a un
botón "Calcular tiempo total" que precarga el valor sugerido (editable). Hallazgo de seguridad de
paso: con `SCJ09` bloqueando todo, la rama de `tramo_insert_revision` que permitía insertar un
tramo *abierto* quedó sin ningún llamador legítimo — se angostó la policy en el mismo corte
(`ALTER POLICY`).

## Qué se decidió

- Primer camino de escritura humana sobre `tiempo.tramo`/`tiempo.dia` — ambos deliberadamente
  restringidos a la única transición que `SCJ-DEC-06` permite, nunca CRUD general.
- Horas al revisar: siempre a mano de RH, nunca auto-calculadas ciegamente — pero con el total
  calculado disponible como sugerencia antes de confirmar.
- Excepciones pendientes en Días: sólo informativas, el cierre automático (`SCJ-PRO-12`) no se
  toca ni se bloquea por ellas.
- Una marca huérfana sin pareja bloquea todo el revisar — no se inventa un cierre que no existe.

## Qué quedó pendiente

- Refactorizar `alertas_de_retardo.py` para usar `app/alertas_horario.py` — el módulo se escribió
  para que ese refactor sea trivial después, no se tocó esa pantalla en este corte.
- Índice `(persona_id, momento_dispositivo)` en `tiempo.marca` — sugerido como follow-up de
  rendimiento para `GET /api/dias`, no bloqueante a esta escala.
- El día 7 de septiembre del usuario administrador quedó `revisado` sin tramos armados (se revisó
  con el RPC viejo, antes del corte 7) — la transición ya se consumió, no se corrigió
  retroactivamente.

## Preguntas nuevas

-

## Nota para la retrospectiva

Los cortes 6, 7 y 8 nacieron **todos** de que el usuario probó la pantalla en el navegador después
de cada entrega y encontró el siguiente hueco real — ninguno estaba en un plan original. Patrón que
se repitió también en Jornada Asignada el mismo día (ver bitácora aparte): "entregar, probar en
vivo, encontrar el siguiente hueco" funcionó mejor que intentar anticipar todo el alcance de
antemano para una lógica de negocio tan nueva (`SCJ-PRA-01 #14` llevaba semanas sin resolverse por
falta de esa iteración).
