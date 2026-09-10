# 2026-09-08 · Jornada Asignada — fila expandible + bug real de vigencias solapadas cazado en vivo

**Participantes:** Diego (usuario), `orchestrator` + equipo (`db`/`backend`/`frontend`) vía
`team-orchestrator`. Mockups vía `frontend` usando HTML/CSS/JS directo contra `tokens.css` (no
21st.dev/`/design` como se pidió explícito — decisión propia de `frontend` por fidelidad, marcada al
usuario, que la aceptó sin pedir rehacerlo).
**Duración:** un corte de diseño (3 mockups) + un corte de implementación + una investigación de bug
en vivo con logging temporal, todo el mismo día.

---

## Qué se hizo

**Mockups:** `AsignarJornadaPage.tsx` ya tenía tabla de cobertura ("Con jornada"/"Sin jornada") y
formulario siempre visible. Pedido: ver el patrón semanal al elegir una persona, y formulario
colapsable. Sin precedente en el proyecto de "tabla + fila que expande detalle de sólo lectura" (los
4 casos de fila expandible existentes son todos para confirmar una acción o editar). `frontend`
armó un solo Artifact con 3 propuestas interactivas (A: panel lateral fijo, B: fila expandible, C:
flujo guiado en 3 pasos) reusando la paleta/tipografía real del proyecto. Usuario eligió **B**.

**Implementación (sin backend nuevo — `GET /api/personas/{id}/jornada-vigente` ya alcanzaba):**
`DetalleJornadaAsignada.tsx` nuevo, extraído de la tarjeta que ya existía en `FichaPersonaPage.tsx`
(segunda vez que aparece ese bloque, se comparte en vez de duplicar). Filas de la tabla de cobertura
pasan a expandibles (clic alterna, cacheado por persona para no refetchear al reabrir); el
formulario arranca cerrado, con el mismo patrón crudo `aria-expanded`+Chevron que ya usaba
`AppShell.tsx` (sin componente Accordion nuevo). Encontrado y corregido en revisión antes de
commitear: la fila clickeable no tenía ningún `cursor:pointer` propio — `tbody tr:hover` ya resalta
*cualquier* fila de la app, así que sin esa regla la fila nueva no se distinguía en nada de una
normal.

**Bug real cazado en vivo, en 2 rondas:** el usuario probó renovar la jornada de su propio usuario
(admin) y confirmó el diálogo de "cerrar la vigente y asignar la nueva" (409 → confirmar). Primer
hallazgo: la jornada anterior quedó sin cerrar (dos filas `vigente_hasta IS NULL` simultáneas para
la misma persona) — se descartaron RLS (policy de `tiempo.jornada_asignada` no filtra por fila,
sólo por permiso), doble-submit (el botón de confirmar se deshabilita mientras envía) y payload
obsoleto (el frontend reenvía el snapshot original, no relee el DOM) sin encontrar la causa. Se
corrigió el dato a mano (aprobación explícita del usuario) y se propuso reproducirlo en vivo con
logging temporal para no quedarse con una teoría sin evidencia.

**Segunda ronda, con log real:** `backend` agregó 3 `logger.warning` temporales (con `.info` el
mensaje se habría perdido — el proyecto no configura el logger raíz) mostrando el payload exacto
que llega a `fn_jornada_asignar_renovar`. El usuario repitió el flujo (sin querer, sobre la misma
cuenta admin) — el log confirmó que el payload llegaba perfecto (`persona_id`,
`confirma_cierre_vigente=true` correctos) y el RPC devolvió éxito. Esta vez la jornada anterior **sí**
se cerró, pero con `vigente_hasta` **antes** de su propio `vigente_desde` — intervalo invertido.
Causa raíz real: el RPC calcula `vigente_hasta = nueva.vigente_desde - 1`, asumiendo que la nueva
vigencia siempre empieza *después* de que empezó la anterior. El usuario había renovado dos veces
el mismo día — mismo `vigente_desde` en ambas — así que el cálculo dio un día *antes* del propio
inicio de la fila que se estaba cerrando. Nada en `tiempo.jornada_asignada` impedía guardar ese
intervalo imposible (sin `CHECK` de orden de fechas).

**Fix (`db/ddl/67_*.sql`):** `fn_jornada_asignar_renovar` gana un segundo chequeo (`ERRCODE SCJ02`,
local a esta función — mismo criterio ya establecido de reusar códigos entre funciones distintas,
`SCJ01` ya se reusa así) que rechaza la operación si la nueva vigencia no es estrictamente posterior
a la fecha en que empezó la actual, *antes* de escribir nada. `CHECK ck_jornada_asignada_vigencia`
nuevo en la tabla (`vigente_hasta IS NULL OR vigente_hasta >= vigente_desde`) como red de seguridad
a nivel base. Se borró la fila corrupta (nunca estuvo vigente un día completo, la siguiente la
reemplazó el mismo día) y su `patron_semanal`, con aprobación explícita del usuario. El log temporal
se retiró íntegro tras confirmar la causa.

## Qué se decidió

- Mockup B (fila expandible) sobre panel lateral fijo o flujo guiado — el usuario lo eligió viendo
  las 3 opciones interactivas.
- Componente compartido para el detalle de jornada en vez de duplicar el bloque una segunda vez.
- Renovar una jornada el mismo día en que ya empezó la vigente actual es un error, no un caso válido
  a resolver de otra forma (se descartó la alternativa de "reemplazar en vez de cerrar").

## Qué quedó pendiente

- El primer incidente (jornada nunca cerrada, con `vigente_desde` distintos entre ambas filas) sigue
  sin causa raíz confirmada — no se pudo reproducir con esas condiciones exactas. Se corrigió el
  dato, pero si vuelve a pasar con fechas distintas (no el mismo día), amerita otra ronda de
  investigación con logging.
- Una anomalía de datos preexistente, no relacionada con este bug, quedó anotada sin corregir: dos
  vigencias antiguas de la misma persona (`id=6`→`id=27`) se solapan un día — probablemente dato
  sintético de sesiones de prueba anteriores, no de este flujo. Bajo prioridad, el usuario puede
  decidir después si vale la pena limpiarla.

## Preguntas nuevas

-

## Nota para la retrospectiva

Instrumentar con logging temporal (retirado inmediatamente después) fue lo que realmente permitió
cazar la causa raíz — las tres hipótesis "de escritorio" (RLS, doble-submit, payload obsoleto) eran
razonables pero todas incorrectas; sin el log real habríamos seguido especulando. Vale la pena tener
presente esta técnica (`superpowers:systematic-debugging` §"Gather Evidence in Multi-Component
Systems") como primer recurso, no el último, cuando una teoría de código no explica un dato real
observado.
