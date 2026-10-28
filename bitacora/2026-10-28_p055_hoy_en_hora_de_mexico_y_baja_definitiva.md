# 2026-10-28 · P-055/P-182 — «hoy» en hora de México en la base y la baja exige asignacion_edicion

**Participantes:** Diego; orchestrator con `db`, `security` y `backend` (vía `team-orchestrator`); `sistemas-63` (bóveda) pidió la tarea.
**Duración:** una sesión, 28-oct-2026.

---

## Qué se hizo

Es el primer cambio sobre el esquema congelado que sigue el procedimiento de `SCJ-ACT-03` §V. El motivo y la aprobación están en
la bóveda, en `Sistemas/Bitacora/2026-10-28_p055_fecha_mexico_cambio_esquema.md`.

- **`127_`**: `CURRENT_DATE` pasa a `personas.fn_hoy_mexico()` en 10 funciones:
  - Las 6 de vigencias de jornada de `75_`/`76_`.
  - `personas.fn_persona_sincroniza_baja`.
  - `tiempo.fn_parametro_actualizar_valor`, `fn_terminal_config_actualizar` y `fn_terminal_config_valor`.

  La base corre en UTC y, entre las 18:00 y las 24:00 de CDMX, tomaba el día siguiente. Los cuerpos salen de
  `pg_get_functiondef` real, con atributos y ACL idénticos. Ensayo 58/58, que incluye la reversa ejecutable (fase R).
  Diego la aplicó antes de la revisión de `security`; la revisión posterior no encontró nada crítico ni alto.
- **`128_`**: `personas.fn_bitacora_sincroniza_persona` fecha la baja y el cierre de asignaciones con
  `fn_hoy_mexico(NEW.fecha_efectiva)`. Antes usaba `instante::date` en UTC. Ensayo 20/20.
- **`129_`**: la policy `bitacora_insert_requiere_permiso` exige `asignacion_edicion` en `baja_definitiva`. Va con `CASE` y no
  con `OR`, porque la sección 55 del verificador prohíbe `OR` en esa policy. Antes, quien tenía solo `cambio_estado_persona`
  daba la baja y las asignaciones quedaban abiertas sin error, porque la RLS filtraba el UPDATE del trigger INVOKER. Ensayo 19/19.
- **Backend** (`routers/movimientos.py`):
  - La baja definitiva exige además `asignacion_edicion`; sin el permiso responde 403.
  - Si la persona ocupa el puesto administrador, responde 422 en una verificación previa con `service_role`.
  - Cualquier 42501 del INSERT responde 403 genérico, sin leer el texto de Postgres.
  - `tipo_movimiento` pasa a `Literal`.
  - 2867 pruebas.
- **`verificar_ddl.sql`**: secciones 89 a 92.
- **Documentos**: `SCJ-DIC-01` V1.7, `SCJ-DEC-04` V1.1 y `SCJ-ACT-03` V1.2, firmada el 28-oct. Huella del DDL `00_`–`129_`:
  `a5aa73ad183fa195f633f1cd4af0b8e6a908124a452845021eea1adf0611af92`.
- **Commits** `bf502fd`, `6156eec` (resultados del piloto) y `d0826bd` (firma), con push hecho. Todavía no se despliegan en el Pi.

## Qué se decidió

- No se fija la zona horaria de la sesión ni la de la base. Toda fecha de regla de negocio usa `fn_hoy_mexico()` o
  `fn_hoy_mexico(instante)`.
- El interruptor de huella (`97_`) sigue en UTC a propósito.
- El 403 de respaldo no afirma ninguna causa, porque un 42501 puede venir de la policy de la bitácora o de la de `asignacion`
  (protección del administrador).
- No se expone `puede_dar_baja_definitiva` en `/api/sesion` por ahora.
- `db/correcciones/` no se versiona, porque trae UUID de una persona real y el repositorio es público.

## Qué quedó pendiente

- Desplegar el backend en el Pi, con OK de Diego.
- CHECK de vigencia en `tiempo.parametro` y `tiempo.tope_legal` (`SCJ-ACT-03` V1.2 §IV).
- P-214: tipar `persona_id: UUID` en `/api/personas/{id}`; hoy da 500 con un valor que no es UUID.
- `SCJ-PRO-02` podría anotar que la baja definitiva exige `asignacion_edicion`.
- `docs/07-procesos/GUIA_ENROLAR_HUELLA.html` está desactualizado frente al `.md`; hay que regenerarlo.

## Nota para la retrospectiva

- Distinguir errores por el texto del mensaje de Postgres no es un contrato. La revisión de `security` lo evitó y se usó una
  verificación previa.
- Aplicar antes de la revisión funcionó esta vez, pero la reversa no era ejecutable. Lección: probar la reversa dentro del
  ensayo desde el principio.
