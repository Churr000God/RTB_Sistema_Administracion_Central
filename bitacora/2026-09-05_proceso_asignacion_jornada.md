# 2026-09-05 · Sesión — Proceso de asignación de jornada (`SCJ-PRO-09`)

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo (misma jornada que `SCJ-PRO-08`, tercer proceso seguido).

---

## Qué se hizo

Discutido pregunta por pregunta en el chat (mismo patrón que `01`/`02`/`08`), escrito `SCJ-PRO-09`:
asignación de `jornada_asignada`/`patron_semanal`, paso siguiente al alta de puesto (`SCJ-PRO-04`)
en el flujo de onboarding.

Se implementó de una vez el `CONSTRAINT TRIGGER` de tope legal que el documento exigía —
`tiempo.fn_patron_semanal_valida_tope_legal()` / `trg_patron_semanal_valida_tope_legal`
(`db/ddl/02_tiempo.sql`). `DEFERRABLE INITIALLY DEFERRED` porque `patron_semanal` se inserta como
varias filas por jornada; validar fila por fila reventaría con la primera aunque la suma final sea
válida. Recalcula las horas desde `hora_entrada`/`hora_salida`/`minutos_comida` en vez de confiar
en `horas_efectivas` (columna derivada, ya documentada como "no es fuente de verdad").

`SCJ-MOD-03` sube a **V1.2** (menor): se agregan esta restricción y `aprobacion_ausencia` (de
`SCJ-PRO-08`, se había implementado sin reflejarse aquí) a §IV, y se corrige la fila de §V sobre el
flujo de autorización de ausencia, que seguía redactada como si `SCJ-DEC-05` no se hubiera resuelto.
`SCJ-TRZ-01` actualizado (`III.4` pasa de Pendiente a Implementado).

## Qué se decidió

- **Orden confirmado:** alta persona → asignar puesto → asignar jornada. Mismos 3 puestos de
  siempre (Gerente General / RH / TI) pueden asignar, mismo permiso ya mapeado
  (`jornada_asignada_edicion`/`patron_semanal_edicion`).
- **Nunca coexisten dos vigencias activas.** Insertar una nueva con una ya vigente bloquea y pide
  confirmación explícita — al confirmar, cierra la anterior (`vigente_hasta = nueva.vigente_desde
  - 1 día`), nunca silencioso.
- **Todo cambio (incluido cambiar de tipo) cierra y abre, nunca edita en el lugar** — mismo
  mecanismo, sin caso especial para el cambio de tipo. Banco de horas pasa intacto.
- **Tope legal sólo aplica a `normal`.** `flexible`/`de_confianza` no tienen jornada fija que sumar
  contra un tope, quedan fuera por diseño.
- **Tope legal se refuerza en la base, a diferencia del traslape de vigencias (`SCJ-DEC-04`), que
  se dejó sólo en la aplicación.** Decisión explícita del usuario tras la recomendación: es
  cumplimiento legal (horas máximas), no una comodidad de UX, y el proyecto ya encontró que
  `anon`/`authenticated` pueden saltarse el backend pegándole directo a PostgREST
  (`31_personas_rls_permiso_especifico.sql`) — el mismo riesgo aplicaría aquí si sólo viviera en la
  app. El traslape de vigencias sí se quedó únicamente en la app porque ahí el costo de un traslape
  colado es mucho menor que el de una jornada ilegal.
- **Diferencia operativa `normal` vs. `flexible`:** `normal` genera alertas de entrada/salida tarde
  contra el horario exacto del patrón; `flexible` no las genera, sólo importa el total de horas.

**Addendum (mismo día):** se agregó `jornada_asignada.genera_alerta_horario` (boolean, default
`true`) — el usuario lo dio de alta primero en Lucid, luego se replicó en
`db/ddl/02_tiempo.sql`/`SCJ-MOD-02` (sube a **V2.1**, menor). De paso, al tocar `jornada_asignada`
en `diagramas/fuente/logico.mmd` se encontraron 2 columnas más desactualizadas desde antes de esta
sesión: `jornada_asignada` seguía con `daterange vigencia` (pre-`SCJ-DEC-04`) en vez de
`vigente_desde`/`vigente_hasta`, y `tope_legal` le faltaba `vigente_hasta` — corregidas ambas de
paso (documento vivo, no sube de versión).

## Qué quedó pendiente

- Backend/frontend/RLS de `jornada_asignada`/`patron_semanal` — nada existe todavía (`SCJ-PRO-09
  §VI`).
- El diálogo de confirmación de cierre (B1-B3 del diagrama) es UX de aplicación, no tiene pieza de
  base — queda documentado, no construido.
- Trigger no verificado contra Supabase real (mismo pendiente de siempre en esta sesión — el DDL no
  se ha corrido).

## Preguntas nuevas

- Ninguna — las dos dudas planteadas (fecha exacta de cierre, capa de la validación de tope legal)
  se resolvieron en la misma conversación.

## Nota para la retrospectiva

Segunda vez en el día que documentar un proceso destapa una inconsistencia en un documento ya
"cerrado" (`SCJ-MOD-03` seguía sin `aprobacion_ausencia` desde la sesión de `SCJ-PRO-08`, unas horas
antes). Confirma la nota de la sesión de reconciliación de la mañana: vale la pena una pasada de
"¿el modelo físico ya refleja la última decisión?" cada vez que se cierra un `SCJ-PRO`, no sólo al
final.
