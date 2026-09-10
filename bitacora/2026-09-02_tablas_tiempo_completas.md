# 2026-09-02 · Sesión — Se completa el esquema del subsistema de Tiempo

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo.

---

## Qué se hizo

`db/ddl/02_tiempo.sql` estaba vacío ("PENDIENTE, se escribe en C2.1"). Se escribieron las 14 tablas
completas del subsistema de Tiempo, con sus restricciones, comentarios y dos disparadores. Se
resolvieron 5 de las 9 decisiones de diseño que seguían "Propuesta" (`SCJ-DEC-02`, `03`, `06`, `07`,
`09`), se actualizaron `SCJ-MOD-01` (conceptual), `SCJ-MOD-02` (lógico), `SCJ-MOD-03` (físico),
`SCJ-DIC-01` (diccionario, resumen), los diagramas fuente (`conceptual.mmd`, `logico.mmd`) y los
tres documentos vivos (`SCJ-PRA-01`, `SCJ-TRZ-01`, `SCJ-GLO-01`).

## Qué se decidió

- **`SCJ-DEC-02` (saldo):** libro de movimientos (`movimiento_de_saldo`) como única fuente de
  verdad, más un total materializado de sólo lectura (`banco_de_horas.monto`/`.vivo_desde`),
  escrito únicamente por disparador. Cinco tipos de movimiento, no cuatro: `generado_quincena`
  (el único que aumenta la deuda, automático al corte quincenal) más las cuatro salidas ya
  conocidas (`cubrir`/`arrastrar`/`descontar`/`condonar`).
- **`SCJ-DEC-07` (excepciones):** entidad `excepcion` con ciclo de vida propio, `marca_id` o
  `dia_id` (nunca ambos — `ck_excepcion_marca_o_dia`). `marca.requiere_revision` se queda como
  bandera rápida; el detalle se muda a `excepcion`.
- **`SCJ-DEC-06` (día):** entidad materializada, con un cuarto estado que las opciones originales
  no contemplaban: `revisado`. Un día bloqueado que RH ya revisó no vuelve a `cerrado`.
- **`SCJ-DEC-03` (correcciones):** registro de eventos — `correccion` apunta a la `marca` original,
  que nunca se modifica.
- **`SCJ-DEC-09` (unicidad de secuencia):** índice único parcial, tal como estaba redactado en el
  documento — sin sorpresas, era la opción obvia.
- Se agregó `tiempo.dia_festivo` — catálogo que no estaba en el modelo original, necesario para que
  el sistema separe el pago de domingo/festivo trabajado sin depender de una fórmula (los festivos
  mexicanos son móviles). Domingo no necesita catálogo, se deriva de la fecha.
- Se agregó un disparador (`trg_ausencia_resuelve_excepcion`) que cierra sola una `excepcion` de
  día sin checada cuando llega una `ausencia` autorizada tardía — sin que RH tenga que cerrarla a
  mano.

## Qué quedó pendiente

- **`SCJ-DEC-01`, `SCJ-DEC-04`, `SCJ-DEC-05`, `SCJ-DEC-08` siguen "Propuesta".** El DDL tuvo que
  elegir algo físico de todos modos para poder existir (ver la nota al inicio de
  `db/ddl/02_tiempo.sql`): paridad sin restricción de bloqueo (opción D de facto), vigencias con
  `daterange`+`EXCLUDE` (sin resolver si además se congela el valor calculado), `marca.id` como
  subrogada con `evento_id` como llave de negocio aparte, y `ausencia.estado_autorizacion` como
  placeholder de un solo paso que **no** implementa el flujo configurable que `SCJ-DEC-05` exige.
  Estas cuatro decisiones documentadas siguen debiéndose formalmente aunque el esquema ya exista.
- Disparadores que faltan programar: clasificación de `clasificacion_de_tiempo.tipo` (compara
  contra `tope_legal` y `banco_de_horas` vigentes), `marca.requiere_revision` calculado, el proceso
  de cierre diario completo (arma `tramo`, decide `dia.estado`, genera `excepcion`), el corte
  quincenal que inserta `generado_quincena`, y el batch de `dia` directo para jornada
  `de_confianza` (sin marca/tramo sintéticos — se decidió expresamente no generarlos).
- No se corrió el DDL contra un proyecto de Supabase real — sólo se revisó balance de paréntesis y
  coherencia manual. Falta la verificación real de `AGENTS.md` §"Verificación antes de cerrar".
- `SCJ-DIC-01 §II` (detalle columna por columna) no se reescribió a mano — sigue dependiendo de
  `tools/generar_diccionario.sql`, que todavía no existe. Sólo se actualizó el resumen del esquema.
- **`SCJ-MOD-01` es trabajo conjunto** y se le agregó una relación (`MARCA ||--o{ EXCEPCION`) y un
  estado nuevo sin haberlo acordado con el compañero del subsistema de Personas — avisar antes de
  la próxima sesión compartida.

## Preguntas nuevas

- `ausencia.estado_autorizacion` (un solo campo) vs. el flujo de pasos variables que `SCJ-DEC-05`
  exige — ¿qué pasa con las filas ya cargadas cuando esa decisión se resuelva? Anotada en
  `SCJ-PRA-01`.

## Nota para la retrospectiva

Cinco decisiones de diseño llevaban desde su creación como "Propuesta", con las opciones ya
escritas pero sin elegir — esta sesión fue, sobre todo, tomar esas decisiones y escribir el DDL
que de ellas se sigue, no inventar opciones nuevas. Las cuatro que siguen abiertas
(`SCJ-DEC-01`, `04`, `05`, `08`) son honestamente las más difíciles del lote: paridad sin
restricción dura, vigencias con valor congelado, un flujo de autorización genérico, y la tensión
entre llave de negocio y llave física de la marca. Vale la pena una sesión dedicada sólo a esas
cuatro antes del congelamiento del 25 de septiembre.
