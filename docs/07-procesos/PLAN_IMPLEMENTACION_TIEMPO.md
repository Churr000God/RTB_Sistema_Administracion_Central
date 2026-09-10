# Plan de implementación — Subsistema de Tiempo

**Sistema de Control de Jornada**
5 de septiembre de 2026

No es un folio `SCJ-XXX-NN` — ningún tipo de `CONVENCIONES.md §I` cubre "orden de construcción",
así que vive aquí sin versión, como documento de trabajo (mismo trato que `README.md`/`CLAUDE.md`).
Ordena los 8 `SCJ-PRO` de Tiempo (`07` a `14`) por dependencia real, no por número de folio — se
escribieron en el orden en que se diseñaron, no en el orden en que conviene construirlos.

---

## Cómo se armó el orden

Tres criterios, en este orden de prioridad:

1. **Dependencia dura primero.** Si el proceso B necesita una tabla/dato que sólo produce el
   proceso A, A va antes — sin excepción.
2. **Menor riesgo antes que mayor riesgo**, cuando no hay dependencia dura. Los batches de cálculo
   de horas/dinero (`SCJ-PRO-12`/`13`) se dejan al final del todo, con pruebas reales, no un
   intento sin verificar.
3. **Piezas compartidas se construyen una sola vez.** Los tres batches comparten la misma
   orquestación (job + botón manual, `tiempo.corrida_batch`, idempotente por persona) — se
   construye una vez, no tres.

---

## Fase 0 — Ya hecho, no requiere trabajo nuevo

- **Permisos del módulo completo** — 30 códigos en `personas.permiso` (`db/ddl/33` a `36`), ningún
  proceso de los 8 necesita permiso nuevo.
- **Esquema completo** — las 16 tablas de `db/ddl/02_tiempo.sql`, con todos los disparadores de
  integridad ya escritos (`fn_marca_valida_revision`, `fn_correccion_valida`,
  `fn_correccion_recalcula_tramo`, `fn_patron_semanal_valida_tope_legal`,
  `fn_ausencia_resuelve_excepcion` extendido, `fn_aprobacion_ausencia_actualiza_ausencia`,
  `fn_movimiento_de_saldo_actualiza_banco`).
- **RLS del checador** (`terminal_checador`, `37_tiempo_rls_terminal.sql`) — única RLS de `tiempo`
  que ya existe.

---

## Fase 1 — Fundamento: sin esto, nada más tiene sentido

### 1. `SCJ-PRO-09` — Asignación de jornada

**Por qué primero:** ningún otro proceso funciona sin que una persona ya tenga
`jornada_asignada`/`patron_semanal` — ni el checador sabe si alguien llegó tarde, ni el batch
`de_confianza` sabe a quién le toca, ni el corte quincenal tiene contra qué comparar.

**Falta construir:** el `CONSTRAINT TRIGGER` de tope legal ya existe en la base
(`trg_patron_semanal_valida_tope_legal`) — falta el endpoint de asignación (con el diálogo de
confirmación de cierre de vigencia), RLS de `jornada_asignada`/`patron_semanal`, y frontend.

### 2. `SCJ-PRO-14` — Batch de jornada `de_confianza`

**Por qué segundo:** el más simple y de menor riesgo de los tres batches, y completamente
independiente de `marca`/`tramo`/`ausencia` — sólo necesita que la Fase 1.1 ya exista. Conviene
construirlo aquí para validar la orquestación (job + botón + `corrida_batch`) con el batch más
fácil antes de usarla en los otros dos, mucho más riesgosos.

**Falta construir:** el job programado en sí (APScheduler o similar) + endpoint de botón manual —
primera vez que se construye esta orquestación, los otros dos batches la reutilizan. RLS de `dia`
para este flujo.

---

## Fase 2 — Captura de marcas

### 3. `SCJ-PRO-11` — Registro por terminal

**Por qué antes que la captura manual:** es la vía principal y de mayor volumen — 8 personas × 4
marcas al día pensadas para pasar por aquí. También es donde vive `fn_marca_valida_revision`
conceptualmente (aunque el disparador ya está escrito y corre igual para los dos orígenes).

**Falta construir:** el subproyecto del checador en sí es **repo aparte**, fuera de este plan —
aquí sólo falta que exista de verdad esa integración (JWT del checador, alcance de
`terminal_checador` ya listo en `37_*.sql`) y probar el disparador contra marcas reales.

### 4. `SCJ-PRO-07` — Captura manual de marca

**Por qué justo después:** comparte tabla y disparador con el paso anterior — conviene tenerlos
frescos en la misma sesión de trabajo. Es la vía de respaldo, menor volumen.

**Falta construir:** router `tiempo`/`marcas` (no existe, primer router de Tiempo), endpoint
`POST /api/marcas/captura-manual`, RLS de `marca`/`excepcion`, frontend del formulario.

---

## Fase 3 — Resolución humana sobre lo ya capturado

### 5. `SCJ-PRO-10` — Corrección de marca

**Por qué aquí:** necesita que ya existan marcas con `excepcion` real (producto de la Fase 2) para
poder probarse contra algo — antes de eso sólo se puede probar con datos sintéticos.

**Falta construir:** endpoint de corrección con la validación de ventana de 30 días hábiles
(aplicación) — el rechazo por reordenar marcas ya lo hace la base (`fn_correccion_valida`). RLS de
`correccion`.

### 6. `SCJ-PRO-08` — Detección y resolución de falta

**Por qué aquí y no antes:** el *disparo* automático de la ausencia depende del batch de cierre de
día (Fase 4, todavía no existe) — pero el *flujo de resolución* (aprobar/rechazar, reclasificar
tipo) se puede construir y probar ya, insertando una `ausencia` de prueba a mano mientras el batch
no exista. Construirlo aquí adelanta trabajo sin esperar a la fase más riesgosa.

**Falta construir:** endpoint para listar ausencias pendientes y resolverlas (reclasificación +
decisión en una transacción), RLS de `ausencia`/`aprobacion_ausencia`. El disparo automático llega
solo en la Fase 4, sin cambios aquí.

---

## Fase 4 — Los dos batches de mayor riesgo, juntos, con pruebas reales

**Por qué al final:** son los que calculan horas y dinero — un error aquí no es un bug de UI, es un
saldo mal calculado o una jornada ilegal. Se construyen con datos sintéticos reales (`SCJ-GEN-01`,
si ya existe) y se verifican contra casos conocidos antes de darlos por buenos, no de un solo
intento.

### 7. `SCJ-PRO-12` — Cierre de día

**Por qué primero de los dos:** `SCJ-PRO-13` no puede calcular nada sin que `dia.horas_totales` ya
esté resuelto — dependencia dura.

**Falta construir:** el algoritmo completo (armar `tramo` por paridad, decidir `dia.estado`, crear
`ausencia` si falta marca) — es la pieza más grande del subsistema, no tiene atajos. Reutiliza la
orquestación de la Fase 1.2. RLS de `tramo`/`dia`/`corrida_batch`.

### 8. `SCJ-PRO-13` — Corte quincenal + clasificación de tiempo

**Por qué al final de todo:** depende directo del anterior, y añade su propia complejidad
(clasificación por tramo acumulada, reposición contra deuda existente).

**Falta construir:** el algoritmo completo — sin cambios de esquema, ya todo existía. Reutiliza la
misma orquestación. RLS de `clasificacion_de_tiempo`/`movimiento_de_saldo`/`banco_de_horas`.

---

## Resumen visual

```
Fase 1 (fundamento)     09 → 14
Fase 2 (captura)         → 11 → 07
Fase 3 (resolución)          → 10, 08 (en paralelo entre sí)
Fase 4 (riesgo alto)              → 12 → 13
```

`08` y `10` no dependen entre sí — pueden construirse en cualquier orden o en paralelo dentro de la
Fase 3. Todo lo demás es secuencial.

---

*Plan de trabajo · Subsistema de Tiempo · 5 de septiembre de 2026*
