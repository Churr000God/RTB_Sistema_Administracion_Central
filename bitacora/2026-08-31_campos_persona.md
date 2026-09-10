# 2026-08-31 · Sesión — Campos de `persona` y DDL real de personas

**Participantes:** Diego (con asistencia de IA).
**Duración:** ~1 sesión de trabajo.

---

## Qué se hizo

Se decidió que el esquema `personas` sí se implementa dentro de este proyecto (no queda como
subsistema puramente externo representado sólo por el stub), empezando por la tabla `persona`. Se
definieron sus campos y se escribió el DDL en `db/ddl/04_personas.sql`. Se actualizó
`SCJ-MOD-01 §III` con el detalle de atributos y se ajustó `tiempo.persona.id` (stub) de `bigint` a
`uuid` para que coincida con el tipo real de `personas.persona.id`.

## Qué se decidió

- `personas.persona` se implementa de verdad en este proyecto, no sólo como silueta conceptual
- Campos: `id` (uuid, PK), `actualizado_en` (timestamptz — marca de versión: el registro vigente
  es el de mayor valor, no hay tabla de historial aparte), `curp`, `rfc`, `primer_nombre`,
  `segundo_nombre` (opcional), `apellido_paterno`, `apellido_materno` (opcional),
  `fecha_nacimiento`, `fecha_ingreso`, `fecha_baja` (opcional), `estado`
- `estado`: sólo tres valores — `activo`, `baja_definitiva`, `suspension`. Se descarta
  `incapacidad` como estado propio de persona (estaba en el borrador de la sesión J1.1)
- `tiempo.persona.id` cambia de `bigint` a `uuid` para poder cargar el mismo valor que
  `personas.persona.id` al sincronizar

## Qué quedó pendiente

- `CLAUDE.md` describe el esquema `personas` como "stub" — ya no es exacto y hay que actualizarlo
  para reflejar que sí tiene DDL real
- Definir si `personas.persona` necesita historial de correcciones (como `marca` en Tiempo,
  `SCJ-DEC-03`) o si un campo `actualizado_en` mutable basta — no se decidió a fondo, se optó por
  lo simple por ahora
- Validar con el compañero del subsistema de Personas: este campo de atributos y la decisión de
  implementarlo aquí no estaban acordados desde antes

## Preguntas nuevas

- Ninguna formal. Ver "Qué quedó pendiente" para lo abierto.

## Nota para la retrospectiva

La frontera (`SCJ-FRO-01`) se escribió asumiendo que Personas era un subsistema externo, diseñado
por otra persona, del que sólo cruzaba `persona_id`. Esta sesión empieza a implementarlo también
aquí. No contradice la regla de la frontera (`tiempo` sigue sin atributos de identidad propios),
pero sí cambia el alcance del proyecto respecto a lo que decía `CLAUDE.md` — si en octubre esto no
se resolvió con el compañero real de Personas, este archivo es el punto de partida.
