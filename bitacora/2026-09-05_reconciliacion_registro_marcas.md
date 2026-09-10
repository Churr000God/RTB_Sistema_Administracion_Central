# 2026-09-05 · Reconciliación del módulo Registro-marcas-jornadas-ausencias-asistencias

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo.

---

## Qué se hizo

Se revisó el diagrama Lucid V2 (`9015128f-275f-4c42-bf86-85eb41a329f6`, grupo
"Regsitro-marcas-jornadas-ausencias-asistencias" — typo corregido) contra `SCJ-CDT-01`,
`SCJ-ESP-01`, `SCJ-MOD-02` y `db/ddl/02_tiempo.sql` para cerrar lo que faltaba del subsistema de
Tiempo antes de construirlo. Se encontró que `marca` había divergido del contrato sin ninguna
decisión formal que lo respaldara, y que `SCJ-DEC-05` (aceptada desde el 2 de septiembre) nunca se
implementó en el DDL.

**Reconciliación docs/DDL:**
- `marca`: se restauran `desfase_local` y `version_software` (obligatorios en `SCJ-CDT-01`, se
  habían perdido), se restaura `estado_reloj` como enum de 3 valores (estaba colapsado en un
  boolean `reloj_sincronizado`), se renombran `momento_terminal`→`momento_dispositivo` y
  `momento_servidor`→`momento_recepcion`, y `origen` vuelve a sus 2 valores reales
  (`terminal`/`captura_manual`) — se elimina `contingencia`, que apareció en `SCJ-MOD-02 V1.1` y el
  DDL sin respaldo en ningún documento ni decisión.
- `SCJ-CDT-01` sube a **V2.0** y `SCJ-ESP-01` a **V2.0** (ambos mayores): el valor de `origen` para
  el registro asistido pasa de `asistido` a `captura_manual` — nombre que el modelo lógico y el DDL
  ya usaban desde el 2 de septiembre sin que estos documentos de entrada se hubieran actualizado.
- Se agregó `tiempo.aprobacion_ausencia` (15ª tabla del esquema) implementando `SCJ-DEC-05` Opción
  C: cadena de aprobación por paso, congelada al crear la solicitud, sin tabla de "definición de
  flujo". `ausencia.estado_autorizacion` pasa a materializado de sólo lectura, escrito por
  disparador (mismo patrón que `banco_de_horas`, `SCJ-DEC-02`).
- Se corrigieron referencias que apuntaban a `marca.evento_id` cuando el FK físico real es
  `marca.id` (`tramo.marca_apertura_id/marca_cierre_id`, `excepcion.marca_id`,
  `correccion.marca_id`), y una fuga de frontera en el diagrama: `movimiento_de_saldo.autor`/
  `correccion.autor` mostraban FK a `usuario.persona_id` (esquema Personas) cuando el DDL real
  referencia `tiempo.persona` — corregido en el diagrama, el DDL nunca tuvo el error.
- `SCJ-MOD-02` sube a **V2.0**. `SCJ-DIC-01`, `SCJ-TRZ-01`, `SCJ-NRM-01`, `SCJ-GLO-01` y
  `diagramas/fuente/logico.mmd` actualizados a juego (los tres últimos son documentos vivos, no
  suben de versión).

**Lucid V2 (vía MCP, ediciones de texto — sin reconstruir el documento):**
- Renombrado el título del grupo (typo "Regsitro"→"Registro").
- `marca`, `clasificacion_de_tiempo` (antes `clasificacion_tiempo`), `banco_de_horas` (antes
  `saldo`), `ausencia.tipo_de_ausencia` (antes `naturaleza`, con sus 5 valores reales),
  `movimiento_de_saldo`, `correccion`, `tramo`, `excepcion`, `dia.origen` — todos sincronizados a
  los nombres y valores reales del DDL.
- **No se pudo completar por API, se dejó nota adhesiva:** 2 columnas nuevas de `marca`
  (`desfase_local`, `version_software`) y la entidad `aprobacion_ausencia` completa —
  `ERDEntityBlock4` no acepta filas nuevas después de creado (límite ya documentado en
  `[[diseno-bd-scj-control-jornada]]`), y no hay herramienta MCP para agregar una entidad
  correctamente dimensionada a un documento ya existente (`lucid_create_erd` siempre crea un
  documento nuevo). **Resuelto por el usuario el mismo día, a mano en la UI**: agregó las 2
  columnas a `marca` y creó `tiempo.aprobacion_ausencia` completa (7 campos), mismo patrón que
  usó antes para `tope_legal.vigente_hasta`. Verificado vía MCP: los 7 campos, las 2 relaciones
  (`ausencia` 1─N `aprobacion_ausencia`, `persona` 1─N `aprobacion_ausencia` como aprobador) y las
  11 columnas de `marca` quedaron correctas — sólo se corrigió un typo de la FK
  (`fk tiempo.tiempo.ausencia_id`→`fk tiempo.ausencia.ausencia_id`). Nota adhesiva borrada (el
  usuario ya la había quitado al trabajar en la UI). **Lucid V2 queda 100% sincronizado con el
  DDL real.**

**Documento de proceso nuevo:** `SCJ-PRO-07` — captura manual de marca (`origen = captura_manual`).
Primer `SCJ-PRO` del subsistema de Tiempo, mismo nivel de madurez que `SCJ-PRO-01` a `06` tenían
antes de construirse (diagrama de flujo, reglas confirmadas, nada de código todavía).

**Permisos del módulo de Tiempo, mapeados completos (mismo día, segunda mitad de la sesión):**
27 códigos nuevos en `personas.permiso` (catálogo pasa de 16 a 43) —
`db/ddl/33_permiso_tiempo_migracion_inicial.sql` (catálogo + catch-up de `Gerente o Encargado de
TI`, mismo patrón `CROSS JOIN` que `26_puesto_permiso_bootstrap_admin_generico.sql`) y
`34_puesto_permiso_tiempo_mapeo_inicial.sql` (32 filas de bitácora, otorgando a `Gerente General`
y `Responsable de Recursos Humanos`). Resuelve `SCJ-PRA-01 #09` (antes `#04`) — el permiso de
captura manual quedó como `captura_manual_edicion`, **no heredable**.

Regla confirmada por el usuario: `ver_modulo_3`, `movimiento_de_saldo`, `jornada_asignada`,
`patron_semanal`, `ausencia`, `excepcion`, `aprobacion_ausencia`, `marca`, `tramo`,
`clasificacion_de_tiempo`, `dia` son heredables; `tope_legal`, `dia_festivo`, `parametro`,
`captura_manual`, `tiempo_persona`, `banco_de_horas` no. `tiempo_persona` sólo tiene versión
edición (tabla interna de cálculo, sólo TI); `marca`/`tramo`/`clasificacion_de_tiempo`/`dia`/
`banco_de_horas` sólo tienen versión lectura (calculadas por el sistema). Los pares `_lectura` de
los recursos que sí tienen edición se crearon en el catálogo pero no se asignaron a nadie —
pendiente de que el usuario diga quién los tiene.

## Qué se decidió

- `contingencia` no es un tercer origen real — se descarta, `origen` son exactamente 2 valores.
  Confirmado por el usuario.
- El nombre definitivo del valor es `captura_manual` (no `asistido`, aunque `asistido` era el
  nombre original del contrato) — se actualizaron `SCJ-CDT-01`/`SCJ-ESP-01` para igualar al DDL en
  vez de al revés, porque el DDL/modelo lógico ya lo usaban desde antes sin que nadie lo notara.

## Qué quedó pendiente

- **Pares `_lectura` sin asignar** — creados en el catálogo (`tope_legal`, `dia_festivo`,
  `parametro`, `captura_manual`, `movimiento_de_saldo`, `jornada_asignada`, `patron_semanal`,
  `ausencia`, `excepcion`, `aprobacion_ausencia`), pero ningún puesto los tiene todavía.
- **Disparadores/batches de negocio, deliberadamente no tocados esta sesión** (piden diseño propio,
  no sólo reconciliación): `clasificacion_de_tiempo.tipo` (compara tramo contra `tope_legal` y
  `banco_de_horas`), cierre diario completo (paridad → `tramo` → `dia.estado` → `excepcion`), corte
  quincenal (`generado_quincena`), batch de `dia` directo para `de_confianza`.
- **DDL no verificado contra Supabase real** — sigue sin correrse (mismo pendiente que ya existía
  desde el 2 de septiembre). El esquema `tiempo` puede o no estar ya aplicado en el proyecto real
  tras la reconstrucción del 4 de septiembre (`DROP SCHEMA ... CASCADE` + reaplicación) — si lo
  está, sigue con los nombres viejos hasta que alguien reaplique `02_tiempo.sql` a propósito. No se
  hizo aquí por ser una operación potencialmente destructiva sobre datos reales sin confirmación
  explícita.
- `SCJ-PRO-07` es sólo diseño — nada de backend/frontend/RLS existe para Tiempo todavía (ver §VI
  del propio documento para el orden sugerido).
- `diagramas/export/logico.svg` no se regeneró — sigue reflejando `SCJ-MOD-02 V1.1`.

## Preguntas nuevas

- Ninguna sin resolver — `SCJ-PRA-01 #09` (permisos de captura manual y del resto del módulo)
  quedó resuelta el mismo día.

## Nota para la retrospectiva

Esta sesión fue reconciliación, no diseño nuevo — casi todo lo corregido ya estaba decidido en algún
documento (`SCJ-CDT-01`, `SCJ-ESP-01`, `SCJ-DEC-05`) que simplemente nadie había cruzado contra el
DDL/Lucid reales después de escribirlos. Vale la pena, antes del congelamiento del 25 de septiembre,
una pasada de este mismo tipo sobre el resto de las tablas de Tiempo (no sólo `marca`/`ausencia`) —
el patrón de "el DDL avanzó y el documento de entrada se quedó atrás" puede repetirse en cualquier
tabla que se haya tocado sin releer `SCJ-CDT-01`/`SCJ-ESP-01` en el mismo momento.
