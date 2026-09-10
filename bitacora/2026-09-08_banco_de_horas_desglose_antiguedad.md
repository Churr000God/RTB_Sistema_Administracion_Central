# 2026-09-08 · Banco de Horas — desglose de antigüedad del saldo (FIFO sobre el ledger)

**Participantes:** Diego (usuario), `orchestrator` + `backend` + `frontend` vía `team-orchestrator`.
**Duración:** un corte, sin DDL — exploración con 3 agentes `Explore` en paralelo (DDL/docs,
backend, frontend), `AskUserQuestion` para 4 decisiones, plan mode, dos delegaciones secuenciales
(`backend` → `frontend`, dependencia dura de shape), revisión de diffs y commit.

---

## Qué se hizo

El usuario mandó una captura del modelo ER de `tiempo.banco_de_horas` y pidió rehacer la pantalla
para poder ver "cuánto del tiempo total pertenece a la sección de seis meses o más" — filtros por
persona y por periodo de antigüedad.

**El hallazgo que definió todo el diseño:** `tiempo.banco_de_horas.vivo_desde` es un único
timestamp por persona, y el trigger `fn_movimiento_de_saldo_actualiza_banco` lo resetea a `NULL`
cada vez que el saldo toca 0 (`db/ddl/02_tiempo.sql:795-799`). No alcanza para responder la
pregunta del usuario: una persona con 2h de deuda vieja + 3h nuevas se ve como un solo bloque. Lo
que sí alcanza, sin ninguna migración: `tiempo.movimiento_de_saldo` es un ledger append-only con
`creado_en` por movimiento (`SCJ-DEC-02`), ya con RLS de lectura lista desde el 6 de septiembre
(`db/ddl/56_*.sql`) que nadie consumía todavía. El parámetro `ventana_banco_meses = 6` también
estaba sembrado desde semanas atrás sin ningún lector (`impacta_logica=False`).

4 decisiones confirmadas con el usuario antes de diseñar: FIFO real sobre el ledger (no
aproximación por `vivo_desde`); 3 tramos 0-3/3-6/6+ meses; conservar métricas y gráfica "Top en
deuda" existentes, la tabla sí pasa al molde paginado; sí incluir el ledger por persona como fila
expandible.

**Backend** (`backend/app/banco_antiguedad.py`, nuevo módulo de lógica pura, molde de
`alertas_horario.py`): `calcular_lotes` hace FIFO real — cada `generado_quincena` apila un lote con
su fecha, cada `cubrir`/`descontar`/`condonar` consume desde el lote más viejo primero,
`arrastrar` (monto 0, sin emisor todavía) no toca nada. `repartir_por_tramo` deriva los 2 cortes de
`ventana_meses` en vez de hardcodear 3/6 — si el parámetro cambia, los tramos se mueven solos.
**Reconciliación explícita**: si la suma de lotes no cuadra con `banco_de_horas.monto` (tolerancia
de un centavo de hora), se marca `conciliado=False` y cae a un reparto de bulto único con
`vivo_desde`, en vez de inventar una distribución que no se sostiene — es la detección que
`SCJ-DEC-02:95-97` reconocía como hueco abierto ("nada lo detecta solo").

`GET /api/banco-de-horas` pasó de un array plano sin filtros a `{total, resumen, saldos}`.
Divergencia deliberada del molde `tramos.py`: el desglose por tramo no es una columna real, así que
filtro/orden/paginación de eso se hacen en memoria (documentado en el docstring, mismo criterio que
la limitación ya documentada de `tramos.py:112-113`) — volumen esperado bajo, ~2 movimientos por
persona por mes. `resumen` (métricas + top-8) se calcula siempre sobre la foto completa, antes de
aplicar los filtros de `saldos`. Nuevo `GET /api/banco-de-horas/{persona_id}/movimientos` para el
ledger de una persona, con `saldo_corrido` y flag `vivo` (reusa `calcular_lotes`).

**Cambio de postura de gate**, encontrado en la propia exploración: el router pasó de
`get_caller_client` a `get_service_client`, sumando un segundo `Depends(requiere_permiso(...))`
explícito sobre `movimiento_de_saldo_lectura`/`edicion` (AND con `banco_de_horas_lectura`, OR entre
esos dos). Con el gate viejo, alguien con permiso de banco pero sin permiso de ledger habría
recibido `[]` de movimientos y visto toda la antigüedad en cero **sin ningún error** — falla
silenciosa. Los mismos dos puestos (RH, Gerente General) ya tenían ambos permisos mapeados, nadie
perdió acceso.

**Frontend**: reescritura sobre el molde `DiasPage`/`TramosPage` (debounce, `cargaEnCursoRef`,
paginación offset), conservando la banda de métricas y las 2 tarjetas (ahora `<Card>`), sumando una
4ª métrica "Fuera de ventana" y 2 columnas de tramo a la tabla — todas alimentadas por `resumen`,
lo que de paso corrige un bug menor que la pantalla vieja arrastraba: las métricas se calculaban
sobre el array completo y no reaccionaban a la búsqueda. Fila expandible con el ledger, cacheada
por persona para no refetchear al reabrir (mismo patrón que Jornada Asignada). Nuevo
`frontend/src/lib/tramosAntiguedad.ts`, con funciones en vez de un catálogo `Record` fijo (molde
`tiposAusencia.ts`) porque las etiquetas dependen de `ventana_meses` dinámico.

## Qué se decidió

- FIFO real sobre el ledger, no aproximación por `vivo_desde` — más preciso, sin costo real de DDL
  ni de performance al volumen actual.
- Reconciliación visible (`conciliado=False` + badge "Aproximado") en vez de forzar que el reparto
  siempre cuadre — si algún día un movimiento se registra sin pasar por el flujo esperado, esta
  pantalla lo va a mostrar en vez de mentir con un desglose inventado.
- El corte de tramos se deriva del parámetro, nunca hardcodeado — coherente con cómo ya se trató
  `ventana_meses`/`descuento_pausa_no_registrada_min` en cortes anteriores del mismo día.
- Filtro/orden/paginación de antigüedad en memoria, aceptado como divergencia documentada del molde
  estándar — el volumen real (ledger chico) no justifica una vista materializada todavía.

## Qué quedó pendiente

- El proceso de alerta real de `SCJ-ESP-01 §VI.6` (aviso al 100%, escalamiento al 200%, alerta por
  antigüedad) sigue sin construirse — `banco_antiguedad.py` queda listo para alimentarlo el día que
  se pida, pero este corte no lo incluyó.
- `umbral_aviso_pct`/`umbral_escalamiento_pct` siguen sin consumidor real.
- El movimiento `arrastrar` sigue sin ningún emisor de código (`SCJ-PRO-13 §I` lo deja fuera de
  alcance a propósito, resolución manual de saldo no implementada).
- Si el ledger crece mucho, un índice `(banco_de_horas_id, creado_en)` en
  `tiempo.movimiento_de_saldo` ayudaría — no se agregó, el volumen actual no lo pide.

## Preguntas nuevas

-

## Nota para la retrospectiva

Tercer corte del día (después de Ausencias y Jornada Asignada) que resuelve un pedido de UI
rascando bajo la superficie y encontrando que el dato pedido no existía todavía en ninguna
estructura — sólo un parámetro sembrado sin lector y un timestamp que no alcanzaba. La exploración
en paralelo (3 agentes `Explore`, DDL/docs + backend + frontend) antes de `AskUserQuestion` fue lo
que permitió detectar esto de entrada, en vez de descubrirlo a medio plan.
