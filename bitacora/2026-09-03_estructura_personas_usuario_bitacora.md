# 2026-09-03 — Estructura de expediente, usuario y bitacora_movimiento_persona

Se implementan en DDL las tres tablas que faltaban del subsistema Personas para poder construir
`SCJ-PRO-01` y `SCJ-PRO-02` de punta a punta: `personas.expediente`, `personas.usuario`,
`personas.bitacora_movimiento_persona`. El diseño ya estaba cerrado en el modelo de Lucid
`RTB-APP_DIAGRAMA_V2` (subsistema Personas, sesión 2026-09-02) — este documento solo formaliza la
decisión de pasarlo a DDL, mismo patrón que se usó para `personas.persona` (sesión 2026-08-31, ver
`bitacora/2026-08-31_campos_persona.md`).

Fuera de alcance a propósito: `puesto`, `area`, `departamento`, `permiso`, `puesto_permiso`,
`asignacion` — módulo aparte, todavía sin proceso de negocio diseñado.

Una desviación del texto literal del diagrama: `bitacora_movimiento_persona.registrado_por` está
anotado en Lucid como `fk usuario.persona_id`, pero `persona_id` no es clave única en
`personas.usuario` (la PK es `auth_user_id`) — Postgres no permite una FK contra una columna sin
restricción de unicidad. Se corrige a `registrado_por uuid REFERENCES personas.usuario(auth_user_id)`,
que es semánticamente lo mismo que pedía el diagrama (qué usuario hizo el movimiento), solo que
apuntando a la clave real de la tabla.
