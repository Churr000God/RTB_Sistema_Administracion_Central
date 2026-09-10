# SCJ-DEC-10 · ¿Cómo se calcula la alerta de retardo por jornada normal?

**Estado:** Aceptada
**Fecha de la decisión:** 2026-09-07
**Última revisión:** —

---

## Contexto

Pedido del usuario en vivo, no un requisito original de `SCJ-ESP-01`: para una persona con
jornada `normal` asignada, si su primera marca del día no coincide con su hora de entrada
programada **y** su última marca tampoco coincide con su hora de salida programada, el día se
marca como **alerta de retardo**. Se va a mostrar en el expediente de la persona y en una sección
de reportes/marcas nueva.

No hay respuesta obvia porque, a diferencia de `fuera_de_horario` (`SCJ-PRO-11 §IV`,
`trg_marca_valida_revision`) -- que evalúa **cada marca individual** contra la ventana completa del
turno --, esta regla es un juicio **a nivel día** sobre los dos extremos del patrón (entrada y
salida por separado), y no estaba definida la tolerancia, qué hacer si falta una marca, ni si un
día ya resuelto (ausencia autorizada, revisado por RH) debe seguir generando la alerta. Se
consultaron esos puntos con el usuario antes de implementar (no había una respuesta correcta
obvia ni derivable del resto del sistema); dos puntos menores de forma (franjas partidas, relación
con `fuera_de_horario`) se resolvieron por criterio técnico porque no ameritaban decisión de
negocio.

---

## Opciones consideradas

### A. Fuente de la tolerancia

**Opción A -- Reusar `tiempo.parametro.tolerancia_retardo_min`** (mismo parámetro que ya usa
`fuera_de_horario`).
**A favor:** una sola noción de "tolerancia de retardo" en todo el sistema; sin parámetro nuevo
que versionar ni RH tiene que configurar dos números que casi siempre van a coincidir.
**En contra:** acopla dos reglas conceptualmente distintas (una es por marca, la otra por día) a
un mismo valor -- si algún día necesitan divergir, hay que partir el parámetro recién ahí.

**Opción B -- Tolerancia propia, nueva clave en `tiempo.parametro`.**
**A favor:** las dos reglas pueden evolucionar independiente.
**En contra:** parámetro nuevo sin necesidad real hoy, y este proyecto ya tiene el criterio de "no
agregar configuración hasta que haga falta".

### B. Marca faltante (entrada, salida o ambas)

**Opción A -- Cuenta como alerta.** Sin evidencia de que la persona llegó/salió a su hora, se
asume la falla en vez de darle el beneficio de la duda.
**En contra:** un día realmente sin marcar (persona de baja, terminal caído) también dispara la
alerta -- pero eso ya lo filtra la exclusión de días con ausencia autorizada (punto D).

**Opción B -- Excluir por falta de evidencia** (mismo espíritu que "la evidencia nunca se
descarta, pero tampoco se inventa").
**En contra:** un caso real de retardo total (nunca marcó) pasaría desapercibido -- el hueco más
grave del proceso, invisible.

### C. Dónde vive el cálculo

**Opción A -- Backend (Python), sobre lecturas por lote vía PostgREST** (jornadas vigentes +
patrones + marcas + días, cada una en una sola consulta por rango, cruzadas en memoria).
**A favor:** no toca DDL (fuera del alcance de esta tarea), y a la escala real del proyecto
(decenas de personas, rango típico de un día o una quincena) el costo es trivial.
**En contra:** si la tabla `marca` crece mucho, un cálculo en SQL sería más eficiente.

**Opción B -- Vista o función SQL nueva en `tiempo`.**
**En contra:** requiere coordinar con `db` una migración nueva para una regla de negocio que
todavía se está afinando (recién se resolvieron las ambigüedades con el usuario) -- prematuro.

---

## Decisión

- Tolerancia: reusar `tiempo.parametro.tolerancia_retardo_min` (Opción A del punto A).
- Marca faltante: cuenta como alerta, con motivo propio `sin_marcas` (Opción A del punto B).
- Cálculo: en el backend, sin RPC ni vista nueva (Opción A del punto C) -- `GET
  /api/alertas-de-retardo` en `backend/app/routers/alertas_de_retardo.py`.
- Alcance: sólo `tipo_jornada = 'normal'` (coincide con `jornada_asignada.genera_alerta_horario`,
  ya pensado para esto desde `SCJ-PRO-09`).
- Exclusión: un día con `tiempo.dia.origen = 'ausencia_autorizada'` o `tiempo.dia.estado =
  'revisado'` no genera alerta -- ya está resuelto o cubierto por otro proceso, no necesita otra
  señal más. `bloqueado` (cerrado, pendiente de revisión de RH) sí sigue generando la alerta a
  propósito -- es justo la señal que le falta a RH para revisarlo.
- Franjas partidas (varias filas de `patron_semanal` el mismo día): la entrada programada es la
  del primer renglón (`MIN(hora_entrada)`), la salida programada la del último
  (`MAX(hora_salida)`) -- criterio técnico, no ameritaba decisión de negocio.
- Relación con `fuera_de_horario`: conviven independientes. `fuera_de_horario` sigue evaluando
  cada marca contra la ventana completa del turno (con la misma tolerancia); esta alerta nueva es
  un juicio agregado sobre el día completo, dos condiciones (entrada y salida) que deben fallar
  las dos.
- **Simplificación de alcance, no cubierta por la pregunta original:** `tiempo.marca` no tiene un
  campo que distinga entrada de salida -- es un evento crudo, tipado sólo por orden (`SCJ-DEC-08`).
  "Primera marca" y "última marca" del día son, literalmente, el mínimo y el máximo de
  `momento_recepcion` reconstruido a hora local ese día. Con **una sola marca** ese día, el mínimo
  y el máximo son la misma marca -- se compara igual contra ambos extremos (entrada y salida) sin
  caso especial. No se trató como "falta una marca" (eso queda reservado para el caso de cero
  marcas) porque no hay forma de saber, sin tipo, si esa única marca fue una entrada o una salida.

---

## Por qué

Reusar lo que ya existe (`tolerancia_retardo_min`) y no tocar DDL para una regla que todavía se
estaba definiendo con el usuario mientras se armaba esta decisión -- si el diseño cambia de nuevo
en la próxima iteración, es más barato corregir Python que revertir una migración.

---

## Consecuencias

**Fácil:** agregar la alerta al expediente de una persona o a un reporte por rango sin tocar
`marca`/`jornada_asignada`/`patron_semanal`/`dia` -- el endpoint sólo lee.
**Difícil:** si el volumen de marcas crece mucho, este cálculo por lote en Python deja de ser
trivial y hay que migrarlo a una vista SQL -- el contrato del endpoint (query params, forma de la
respuesta) no tendría que cambiar al hacerlo.
**Cerrado por ahora:** el caso de un solo evento el día se compara contra ambos extremos, no se
distingue "sólo entrada" de "sólo salida" -- si algún día `tiempo.marca` gana un campo de tipo, esta
regla se puede afinar sin romper el contrato externo.

---

## Cómo se verifica

`backend/tests/test_alertas_de_retardo.py` -- casos: alerta por ambos extremos fuera de
tolerancia, sin alerta por estar dentro de tolerancia en al menos un extremo, alerta por cero
marcas (`sin_marcas`), exclusión por ausencia autorizada, exclusión por día revisado, día
`bloqueado` sí genera alerta, `tipo_jornada` distinto de `normal` no se evalúa.

---

## Revisión posterior a la implementación

*(se llena al construir, no antes)*
