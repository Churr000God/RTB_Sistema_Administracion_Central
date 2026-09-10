# 2026-09-05 · Sesión — Proceso de corrección de marca (`SCJ-PRO-10`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (cuarto proceso seguido en el mismo día, después de
`SCJ-PRO-07/08/09`).

---

## Qué se hizo

Discutido pregunta por pregunta en el chat, escrito `SCJ-PRO-10`: corrección de
`tiempo.correccion` (`SCJ-DEC-03`).

Se implementaron de una vez los dos disparadores que el documento exigía, en
`db/ddl/02_tiempo.sql`:

- `fn_correccion_valida` (`BEFORE INSERT`): exige que la marca tenga una `excepcion` asociada —
  sin eso, rechaza. Además bloquea la corrección si `valor_corregido` cruzaría el **momento
  efectivo** (última corrección si existe, si no el original) de la marca anterior o siguiente de
  la misma persona — la corrección ajusta la hora, nunca el orden.
- `fn_correccion_recalcula_tramo` (`AFTER INSERT`): cierra sola la excepción pendiente asociada
  (mismo patrón que `trg_ausencia_resuelve_excepcion`), y recalcula `inicio`/`fin`/
  `minutos_trabajados` **sólo del tramo** que usa la marca corregida como apertura o cierre, más
  `dia.horas_totales` de ese día — nunca el histórico completo. Si la marca aún no forma parte de
  ningún tramo (día sin cerrar), no recalcula nada — el cierre de día, cuando corra, ya va a leer
  el valor corregido.

Se agregó `tiempo.parametro.dias_habiles_correccion_marca` (ejemplo: 30) —
`db/ddl/03_parametros_ejemplo.sql`. Se detectó y llenó un hueco real: `tiempo.correccion` no tenía
ningún permiso mapeado en la ronda de 27 de la sesión de reconciliación —
`db/ddl/35_permiso_correccion_migracion_inicial.sql` (`correccion_edicion`/`_lectura`, heredable, +
`excepcion_reapertura`, no heredable, exclusivo de TI) y
`36_puesto_permiso_correccion_mapeo_inicial.sql` (otorga `correccion_edicion` a Gerente General y
RH; TI ya lo recibe vía el catch-up del bootstrap).

`SCJ-MOD-03` sube a **V1.3** (menor): 3 restricciones nuevas en §IV, 1 regla nueva en §V.
`SCJ-DIC-01` y `SCJ-TRZ-01` actualizados a juego.

## Qué se decidió

- **Sólo se corrige resolviendo una excepción, nunca libre** — sin eso el sistema no sabría que la
  marca necesitaba revisión. Confirmado por el usuario.
- **Editar/reabrir una excepción ya resuelta es exclusivo de `Gerente o Encargado de TI`**, con
  permiso propio (`excepcion_reapertura`) — ni RH ni Gerente General pueden, aunque tengan
  `excepcion_edicion`/`correccion_edicion`.
- **Dos capas de validación, decididas por separado (mismo patrón que `SCJ-PRO-09`):**
  - Ventana de 30 días hábiles → **sólo aplicación**. Política de proceso, no integridad
    estructural; costo bajo de que alguien la salte por PostgREST directo.
  - No reordenar marcas al corregir → **base de datos**, `BEFORE INSERT` (no `CONSTRAINT TRIGGER`
    deferido como el de tope legal, porque `correccion` se inserta fila por fila, no en lote). Es
    la misma integridad que sostiene todo el modelo de paridad/tramo, no negociable.
- **Recálculo automático pero acotado al tramo afectado** — nunca se toca el histórico completo.

## Qué quedó pendiente

- Backend/frontend/RLS de `tiempo.correccion` — nada existe todavía (`SCJ-PRO-10 §VI`).
- Recalcular `clasificacion_de_tiempo.tipo` tras una corrección — depende del disparador de
  clasificación, sigue sin programar (mismo pendiente de siempre).
- Triggers no verificados contra Supabase real.

## Preguntas nuevas

- Ninguna — las dos decisiones de capa (ventana en app, orden en base) se resolvieron en la misma
  conversación.

## Nota para la retrospectiva

Tercera vez en el día que se encuentra un hueco real al diseñar un proceso — esta vez fue un
permiso completo que faltaba (`correccion` no tenía ninguno en la ronda de 27). Verificado de paso:
con `35_*.sql` ya no falta ninguna — las 15 tablas de `02_tiempo.sql` más el stub `persona` tienen
todas su código de permiso (`tiempo_persona_edicion` cubre el stub; `ver_modulo_3` y
`captura_manual_*` no son tabla, son la vista del módulo y la acción de captura). Cerrado, no
queda pendiente de repasar.
