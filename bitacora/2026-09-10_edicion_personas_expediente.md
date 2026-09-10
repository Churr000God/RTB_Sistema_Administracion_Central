# 2026-09-10 · — Edición de datos de persona y expediente

**Participantes:** usuario, `orchestrator` + equipo de 5 especialistas (`db`, `backend`, `frontend`,
`testing`, `security`) vía `team-orchestrator`
**Duración:** una sesión

---

## Qué se hizo

El módulo Personas era append-only en la práctica: `POST /api/personas` (alta) y
`POST /api/personas/{id}/movimientos` (cambio de estado) eran los únicos escritores — ninguna vía
existía para corregir CURP/RFC/NSS/nombre/fechas/expediente tras el alta. El pedido del usuario
partía de la premisa de que "los permisos ya estaban diseñados" para esto — la investigación
mostró que era parcialmente cierto: las policies RLS de `UPDATE` sobre `personas.persona` y
`personas.expediente` sí existían (`db/ddl/31_personas_rls_permiso_especifico.sql`), pero
nacieron por otro motivo (dejar pasar al trigger de bitácora / "por consistencia" con el INSERT)
y **ningún permiso de edición existía en el catálogo** — sólo `alta_personas_usuarios` y
`cambio_estado_persona` para todo el módulo 1.

Entregado de punta a punta en 5 cortes secuenciales + 1 fix de seguridad, con `AskUserQuestion`
antes de tocar código (permiso nuevo vs. reusar existente, campos editables, auditoría, ubicación
de la UI):

- **`db`** (`db/ddl/69_personas_edicion.sql`): permiso `persona_edicion` nuevo (heredable),
  policies de UPDATE reescritas (`persona`: `cambio_estado_persona OR persona_edicion`;
  `expediente`: sólo `persona_edicion`), RPC transaccional `fn_persona_actualizar_datos`
  (`SECURITY INVOKER`, patrón de `fn_corte_quincenal_aplicar_persona`) que nunca toca
  `estado`/`fecha_baja`, otorgado dinámicamente a todo puesto con `alta_personas_usuarios` activo.
- **`backend`**: `PATCH /api/personas/{persona_id}`, schema `PersonaActualizar` (todos los campos
  opcionales, sin `estado`/`fecha_baja` a propósito), 403/404/409/422 mapeados, 428 tests verdes.
- **`frontend`**: edición in-place en `FichaPersonaPage.tsx` — un botón "Editar" funde las
  tarjetas Datos personales + Expediente en un único formulario, un solo `PATCH` con diffing
  (sólo se manda lo que cambió). 471 tests verdes tras el corte.
- **`testing`**: 8 casos nuevos cubriendo precarga, diffing, 403/404/409/422, cancelar, doble
  submit. Suite final: 479 tests, sin bugs encontrados en el flujo implementado.
- **`security`**: encontró un hallazgo real **HIGH** antes de commitear (ver abajo). Confirmado
  limpio en todo lo demás (estado/fecha_baja inalcanzables, RPC sí es `SECURITY INVOKER`, sin
  interacción con la protección del puesto administrador genérico, sin policy residual).

## Qué se decidió

- Crear permiso `persona_edicion` nuevo en vez de reusar `alta_personas_usuarios` o
  `cambio_estado_persona` — separar "quien da de alta/cambia estado" de "quien corrige datos".
- Todos los campos editables (nombres, CURP, RFC, NSS, fecha de nacimiento, fecha de ingreso,
  tipo de contrato, `documento_ref`) — una errata de dedo en el alta era irreparable sin tocar la
  base a mano.
- Sin auditoría de ediciones por ahora (ni tabla nueva ni columnas `actualizado_por`) — se puede
  sumar después si la empresa lo pide; `bitacora_movimiento_persona` no admite un tipo `'edicion'`
  sin romper `fn_bitacora_sincroniza_persona`.
- UI in-place en la ficha existente, sin pestañas ni ruta nueva — mismo patrón que
  `FichaAreaPage`/`FichaDepartamentoPage`/`FichaPuestoPage`.

## Hallazgo de seguridad (HIGH), corregido en el mismo corte

`personas.persona` tiene `GRANT ALL` schema-wide a `authenticated`
(`db/ddl/08_personas_permisos.sql:11`) y RLS de Postgres no filtra por columna, sólo por fila. La
policy `persona_update_requiere_permiso` con `cambio_estado_persona OR persona_edicion` no
distinguía **qué** columnas tocaba el UPDATE: cualquiera con sólo `cambio_estado_persona` podía,
vía PostgREST directo (bypaseando FastAPI), reescribir CURP/RFC/NSS/nombre/apellidos/fechas —
mismo patrón del hallazgo crítico ya documentado sobre `31_*.sql`. No era explotable hoy (los 2
puestos con `cambio_estado_persona` también tienen `persona_edicion`), pero era coincidencia de
datos, no garantía estructural.

No se pudo resolver ajustando el `WITH CHECK` de la policy: en Postgres, el `WITH CHECK` de una
policy de `UPDATE` sólo ve la fila **nueva**, nunca la anterior — no hay forma de comparar
OLD/NEW desde una expresión de policy. El único mecanismo que expone ambas es un trigger
`BEFORE UPDATE`, mismo recurso ya usado en el proyecto para invariantes que RLS no puede expresar
(`trg_puesto_administrador_generico_inmutable`, `trg_persona_sincroniza_baja`).

Fix: `db/ddl/70_personas_persona_update_columnas.sql` — trigger
`trg_persona_protege_columnas_identidad` (`WHEN` compara OLD/NEW de las 9 columnas de identidad)
que exige `persona_edicion` para tocarlas, sin importar qué diga el OR de la policy RLS.
Confirmado por `security` contra `pg_trigger` en vivo: activo, `WHEN` correcto, sin colisión con
`trg_persona_sincroniza_baja` (columnas disjuntas).

## Qué quedó pendiente

- Nada del alcance original — los 5 cortes + el fix cerraron completos.

## Preguntas nuevas

- Si la empresa real pide auditoría de ediciones más adelante, decidir si vale la pena una tabla
  de bitácora nueva o alcanza con columnas `actualizado_por`/`actualizado_en` en `persona`.

## Nota para la retrospectiva

Segunda vez que una política RLS con `OR` para "dejar pasar un trigger interno" termina abriendo
una puerta más ancha de lo previsto para el resto de los callers — la primera fue el hallazgo de
`31_*.sql` documentado en `CLAUDE.md`. Vale la pena, la próxima vez que se agregue un `OR` a una
policy de `UPDATE` por el mismo motivo (dejar pasar un trigger no-`SECURITY DEFINER`), preguntarse
de entrada si hace falta un trigger `BEFORE UPDATE` con columnas explícitas en vez de confiar en
que el permiso más amplio del `OR` sólo se va a usar para lo que se diseñó.
