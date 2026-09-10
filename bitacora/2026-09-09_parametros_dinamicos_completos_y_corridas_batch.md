# 2026-09-09 · Parámetros del sistema 100% dinámicos + corridas batch con fecha/bloqueo horario

**Participantes:** Diego (usuario), `orchestrator` + `backend` + `frontend` vía `team-orchestrator`.
**Duración:** cuatro cortes independientes en la misma sesión, cada uno con investigación previa
(dos agentes `Explore` en paralelo) antes de plan mode, delegación a `backend`/`frontend` en
paralelo con el contrato de API fijado por escrito en el plan, y verificación final en el
navegador con `claude-in-chrome` para los dos primeros cortes.

---

## Qué se hizo

### 1. Ventana del banco de horas: los últimos 3 huecos de "6" hardcodeado

Pedido: reemplazar el valor fijo de 6 meses por el parámetro `ventana_banco_meses` en todo lugar
donde apareciera. La exploración encontró que la lógica de cálculo (`banco_antiguedad.py`) ya
estaba parametrizada desde el 8 de septiembre — quedaban 3 huecos reales, ninguno de lógica de
negocio:

- `MENSAJE_MONTO_EXCEDE_FUERA_VENTANA` en `routers/banco_de_horas.py` tenía "6+ meses" literal en
  el texto del 422 — ahora interpola `{meses}` real.
- `catalogo_parametros.py` marcaba `ventana_banco_meses` con `impacta_logica=False` pese a tener
  consumidor real desde el corte anterior — corregido a `True`.
- `frontend/src/lib/tramosAntiguedad.ts` calculaba la mitad de la ventana con `ventanaMeses / 2`
  (decimal); el backend corta con `//` (piso entero) — con ventana par coincidían, con ventana
  impar la etiqueta mentía. Frontend pasó a `Math.floor(ventanaMeses / 2)`.

Probado en vivo: cambiar la ventana de 6 a 4 en Parámetros del sistema movió columnas, filtro y
resumen de Banco de Horas a `0-2M/2-4M/4+M` sin reiniciar nada. Commit `59013a1`.

### 2. Corridas batch: fecha objetivo + bloqueo horario + bug real del scheduler

Pedido: que el disparo manual de cierre de día respete la hora configurada y permita elegir qué
día procesar. La exploración encontró que **el backend ya aceptaba `fecha` opcional** en los 3
POST — el frontend nunca la mandaba — y un **bug real**: el job programado de `cierre_dia` corría
a las 03:00 pasando `date.today()` en vez del día anterior, contradiciendo tanto el texto de la UI
("detecta faltas del día anterior") como `prevision_corte_quincenal.py`, que ya asumía esa
semántica. Confirmado con el usuario (3 preguntas: arreglar sólo `cierre_dia` con hoy-1, umbral =
`hora_corte_dia + hora_corrida_cierre_dia`, bloqueo sólo si la fecha es hoy y no dio la hora).

- Nuevo `backend/app/hora_cierre_dia.py`: suma las 2 claves de hora con desborde de 24h.
- `POST /api/corridas-batch/cierre-dia` rechaza fecha futura siempre, y fecha de hoy antes del
  umbral (mensaje interpola la hora real, nunca "03:00" hardcodeado). Fecha pasada, siempre
  permitido.
- Scheduler: `cierre_dia` pasa a `date.today() - timedelta(days=1)`; `de_confianza`/
  `corte_quincenal` sin cambio.
- `hora_corte_dia` gana su primer consumidor real (antes nadie la leía).
- Frontend: selector de fecha por cada uno de los 3 botones (ayer por defecto para cierre_dia,
  hoy para los otros dos), manda `{fecha}` en el POST.

Commit `3b524e4`.

### 3. Alerta de magnitud de deuda en Banco de Horas

Pedido inicial del usuario: ampliar Alertas de retardo para que también use `umbral_aviso_pct`
(100%) y `umbral_escalamiento_pct` (200%). La investigación (dos agentes `Explore` en paralelo)
encontró que **esos parámetros no son de retardo** — `SCJ-ESP-01 §VI.6`, `SCJ-DEC-02` y
`SCJ-TRZ-01` los definen como el segundo eje de alerta del Banco de Horas (magnitud de la deuda
como % de la jornada semanal), complementando el eje de antigüedad que ya existía. Presentado el
conflicto al usuario con `AskUserQuestion`, confirmó implementarlo en Banco de Horas — Alertas de
retardo no se tocó.

- Nuevo `backend/app/banco_alertas_magnitud.py`: `jornada_semanal_horas` reusa el mismo cálculo
  que `jornada_asignada.py::_horas_patron`/`corte_quincenal.py::_horas_patron_fila` (nunca la
  columna `horas_semanales_calculadas`, siempre `NULL`); clasifica cada persona en
  `sin_alerta`/`aviso`/`escalamiento` con fronteras inclusivas.
- `GET /api/banco-de-horas` suma `jornada_semanal_horas`/`porcentaje_jornada_semanal`/
  `nivel_alerta` por persona, contadores y umbrales reales en el resumen, filtro `nivel_alerta`.
- Frontend: columna "Nivel" con badge, 2 tarjetas de resumen, selector de filtro, renglón de
  detalle en la fila expandida.
- Con este corte, **las 8 claves del catálogo de parámetros quedan con consumidor real** — cero
  badges "Sin efecto en la lógica actual" en toda la pantalla de Parámetros del sistema.

Commit `79de103`.

### 4. Fix: Alertas de retardo rompía con rango de fechas vacío

El usuario reportó, probando en vivo, que "si quitamos los filtros de tiempo no muestra nada y
marca error". Investigado: `desde`/`hasta` son query params **requeridos sin default** en
`GET /api/alertas-de-retardo` (a diferencia de Tramos/Días, donde son opcionales) — el frontend
mandaba la petición igual si el usuario borraba cualquiera de los 2 inputs, el backend devolvía
422, la UI caía al estado de error genérico. Fix: `cargar()` corta antes del fetch si falta
cualquiera de las 2 fechas, mostrando un mensaje que invita a completar el rango en vez del error.

Commit `be15672`.

## Qué se decidió

- Los umbrales de aviso/escalamiento son del Banco de Horas, no de Alertas de retardo — decisión
  confirmada explícitamente con el usuario tras presentarle el conflicto entre su pedido inicial y
  lo que dice la especificación.
- `cierre_dia` (el batch programado) procesa el día anterior; `de_confianza`/`corte_quincenal`
  siguen procesando el día de la corrida — no se generalizó el fix de fecha a los 3 por igual.
- El umbral horario del disparo manual de `cierre_dia` es la suma `hora_corte_dia +
  hora_corrida_cierre_dia`, fiel a `SCJ-PRO-12 §V` (el código estaba desviado del documento, no al
  revés).

## Qué quedó pendiente

- Nada bloqueante de estos 4 cortes. `SCJ-PRA-01 #14` (relleno de día bloqueado) sigue abierto,
  sin relación con lo de hoy.

## Preguntas nuevas

-

## Nota para la retrospectiva

Segunda vez que investigar antes de plantear el plan cambia el diseño por completo: el pedido
original del usuario ("ampliar Alertas de retardo con estos 2 parámetros") habría producido una
pantalla mezclando dos dominios de negocio si se hubiera implementado literal. La especificación
ya tenía la respuesta correcta esperando — sólo hacía falta leerla antes de diseñar. Mismo patrón
que `bitacora/2026-09-08_movimiento_de_saldo_manual.md` documentó como lección repetida.
