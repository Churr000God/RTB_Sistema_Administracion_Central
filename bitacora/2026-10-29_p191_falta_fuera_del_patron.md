# 2026-10-29 · P-191 — cierre_dia ya no crea falta fuera del patrón semanal

**Participantes:** Diego (encargo vía `sistemas-bf`), `orchestrator`, `backend`
**Duración:** una sesión corta

---

## Qué se hizo

- `backend/app/batches/cierre_dia.py`: helper `_fecha_en_patron`. Un día sin marcas que el patrón
  semanal de la jornada vigente no espera trabajado cuenta como «saltada» y no crea `tiempo.ausencia`.
  Solo se consulta cuando el día no tiene marcas. Si no encuentra la jornada vigente, conserva el
  comportamiento anterior (crea la falta).
- `backend/app/batches/corte_quincenal.py`: un día fuera del patrón sin `tiempo.dia` se omite
  (esperada 0) en vez de devolver `PENDIENTE_DIA_ABIERTO`. Si se trabajó y existe el día, se procesa
  como siempre.
- `backend/app/prevision_corte_quincenal.py`: `resolver_dias_faltantes` ya no reporta días de descanso.
- Pruebas: 2877 passed, 1 skipped (+10 casos). Commit `551a2f9`. Sin DDL (esquema congelado intacto).
- `SCJ-PRO-09` V1.1 §VIII: el párrafo del defecto P-191 pasa a «Defecto corregido».

## Qué se decidió

- Las marcas nunca se descartan por caer fuera del patrón: el patrón solo decide si un día SIN marcas
  genera falta.
- El domingo queda fuera de alcance (regla de negocio aparte, pregunta legal).

## Qué quedó pendiente

- Desplegar al Pi de pruebas (requiere OK explícito de Diego).
- Caso borde: una jornada vigente sin ninguna fila de `patron_semanal` trata todos los días como
  descanso. Coincide con SCJ-PRO-08 A1; si se prefiere «patrón vacío = todos esperados» es un cambio
  de una línea.
- Un día fuera del patrón con `tiempo.dia` en estado `abierto` sigue bloqueando el corte (nada escribe
  `abierto` hoy).
- Varios tests viejos de `cierre_dia` aseguran `resultado["estado"]`, que viene fijo del mock de
  `corrida_batch`; no prueban el resultado real. Los nuevos sí verifican el `detalle`.

## Preguntas nuevas

-

## Nota para la retrospectiva

- Un test de previsión pasaba por agotamiento del mock (`StopIteration`), no por la regla; se corrigió
  al tocarlo. Revisar mocks que «pasan» por accidente.
