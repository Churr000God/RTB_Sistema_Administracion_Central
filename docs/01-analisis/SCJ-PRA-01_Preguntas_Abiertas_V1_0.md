# Preguntas abiertas

**Sistema de Control de Jornada**
Folio SCJ-PRA-01 · Versión 1.0 · Agosto de 2026

Lista viva. Toda duda que aparece se anota aquí antes de resolverse. **Una pregunta que se resuelve
sin pasar por esta lista es una pregunta que nadie va a recordar en octubre.**

---

## I. Abiertas

| # | Pregunta | Levantada en | Fecha | Bloquea a |
|---|---|---|---|---|
| 02 | `POST /api/usuarios` (`backend/app/routers/usuarios.py:11`) usaba `get_service_client` (service_role) sin ningún chequeo de autenticación — cualquiera que alcanzara el endpoint podía invitar un usuario y atarlo al `persona_id` que quisiera. **Parcialmente resuelto 3 sep**: se agregó `Depends(get_caller_client)` — ahora exige Bearer token, igual que `personas.py`/`movimientos.py`. Sigue abierto: `personas.fn_caller_activo()` (la única RLS de `personas`) sólo valida "el caller tiene una persona activa detrás", sin distinción de rol — cualquier empleado activo con token válido puede invitar usuarios y atarlos a cualquier `persona_id`. No existe en el proyecto ningún concepto de permiso/rol todavía (`puesto`/`área`/`permiso` quedaron fuera de alcance de `SCJ-PRO-01`, decisión explícita). ¿Se gatea `alta_usuario` con una RLS/chequeo de rol admin explícito, o se introduce un modelo de permisos antes? Decisión de Diego (3 sep, vía orchestrator): aplicar sólo el gate de token ahora, el de rol queda para otra sesión. | Auditoría de seguridad, sesión `security` (rol) | 3 sep | modelo de permisos/rol (sin decisión aún) |
| 03 | `react-router-dom` en frontend (6.30.6) tiene 2 avisos moderados (open redirect y constructor injection en hidratación SSR — este último no aplica, la SPA no hace SSR). El único fix es bump mayor 6→7 (`npm audit fix --force`, breaking). Decisión de Diego (3 sep): no hacer el bump ahora, se hace después del QA de auth en sesión aparte. | Auditoría de seguridad, sesión `security` (rol) | 3 sep | ninguno todavía |
| 10 | `SCJ-ESP-01 §VI.8` exige saldo de vacaciones por antigüedad (tabla configurable, ej. 12 días el primer año, creciendo hasta un tope). No existe en el modelo — `SCJ-PRO-08` sólo cubre falta autodetectada, no solicitud de vacaciones. ¿Dónde vive esa tabla (`tiempo.parametro` genérico, o una tabla propia)? | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 11 | `SCJ-ESP-01 §VI.8` exige detectar traslape de ausencias entre personas de un mismo grupo. No implementado, y "mismo grupo" no está definido (¿mismo departamento? ¿mismo puesto?). | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 12 | `ausencia.documento_ref` (evidencia cargada) no tiene mecanismo de subida definido — ¿Storage de Supabase, mismo patrón que el expediente de Personas? | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 14 | `SCJ-ESP-01 §VI.2` exige que un día `bloqueado` (paridad impar) se rellene con la **jornada pactada** de esa persona ese día como `horas_totales`. **Parcialmente resuelto 5 sep:** el corte quincenal excluye el día del cálculo mientras siga `bloqueado` (`SCJ-ESP-01 V2.1`) — no importa el valor de relleno hasta que se revisa. Sigue abierto: cómo se calcula exactamente el relleno una vez revisado (¿`patron_semanal` completo del día, o algo distinto?) — se deja para cuando el sistema se aplique a la empresa real. | `SCJ-TRZ-01 III.2`, releído al escribir `SCJ-PRO-12` | 5 sep | Batch de cierre de día (sin programar) |

---

## II. Resueltas

| # | Pregunta | Respuesta | Dónde quedó | Fecha |
|---|---|---|---|---|
| 01 | ¿La fecha de ingreso cruza la frontera, o el subsistema de Personas entrega los días devengados? | Se replica en `tiempo.persona`, de sólo lectura, como única excepción documentada | `SCJ-FRO-01 §V` | 29 ago |
| 02 | ¿El saldo se calcula al vuelo o se materializa? | Libro de movimientos (`movimiento_de_saldo`) como fuente de verdad, más un total materializado sólo de lectura, escrito únicamente por disparador | `SCJ-DEC-02` | 2 sep |
| 03 | ¿`requiere_revision`/`motivo_revision` en la marca, o entidad de excepción aparte? | Entidad `excepcion` con ciclo de vida propio; `marca.requiere_revision` queda como bandera rápida | `SCJ-DEC-07` | 2 sep |
| 04 | ¿El día es entidad materializada o estado derivado? | Materializada, con un cuarto estado (`revisado`) que las opciones originales no contemplaban | `SCJ-DEC-06` | 2 sep |
| 05 | ¿Versionado, auditoría o eventos para las correcciones? | Registro de eventos: `correccion` apunta a la `marca` original, que nunca se modifica | `SCJ-DEC-03` | 2 sep |
| 06 | ¿Cómo sabe el sistema que un día es festivo, para separar el pago de domingo/festivo trabajado? | Catálogo nuevo `dia_festivo` (no calculable por fórmula, festivos móviles). Domingo se deriva de la fecha, sin catálogo | `SCJ-MOD-02 §II.13` | 2 sep |
| 07 | Si una ausencia se carga tarde (después de que ya se generó una excepción por el día sin checada), ¿se resuelve sola o alguien la cierra a mano? | Se resuelve sola por disparador. Corregido 5 sep (`SCJ-PRO-08`): reacciona a `autorizada` **y** a `rechazada` — un rechazo también es una decisión humana ya tomada, no debía dejar la excepción abierta para siempre | `db/ddl/02_tiempo.sql` (`trg_ausencia_resuelve_excepcion`) | 2 sep, corregido 5 sep |
| 08 | `ausencia.estado_autorizacion` se implementó como un solo campo para poder programar algo — pero `SCJ-DEC-05` exige un flujo de pasos variables configurable. ¿Se sustituye esa columna cuando DEC-05 se resuelva? | Tabla `tiempo.aprobacion_ausencia` (cadena de pasos congelada al crear la solicitud); `estado_autorizacion` se queda como materializado de sólo lectura sobre ella, mismo patrón que `banco_de_horas` | `SCJ-DEC-05`, `db/ddl/02_tiempo.sql` | 5 sep |
| 09 | Captura manual de marca (`SCJ-PRO-07`) necesita un permiso nuevo para saber quién es "usuario aprobado". ¿Código y si es heredable? | `captura_manual_edicion` (+ `_lectura` sin asignar), **no heredable**. De paso se mapeó el resto del módulo de Tiempo: 27 códigos nuevos (`ver_modulo_3` y los pares edición/lectura de `tope_legal`/`dia_festivo`/`parametro`/`movimiento_de_saldo`/`jornada_asignada`/`patron_semanal`/`ausencia`/`excepcion`/`aprobacion_ausencia`, más `tiempo_persona_edicion` y los `_lectura` sueltos de `marca`/`tramo`/`clasificacion_de_tiempo`/`dia`/`banco_de_horas`). Otorgados a `Gerente General` y `Responsable de Recursos Humanos`; `Gerente o Encargado de TI` los recibe automático (bootstrap) | `db/ddl/33_permiso_tiempo_migracion_inicial.sql`, `34_puesto_permiso_tiempo_mapeo_inicial.sql` | 5 sep |
| 13 | `fn_ausencia_resuelve_excepcion` sólo cerraba la `excepcion` al resolver una ausencia — no materializaba `tiempo.dia`, así que el día se quedaba `abierto` para siempre. | Extendido para materializar `tiempo.dia` (`estado='cerrado'`, `origen='ausencia_autorizada'`) por cada fecha del rango: jornada completa si `vacaciones`/`permiso_con_goce`/`incapacidad` autorizada, cero horas si `permiso_sin_goce` o `falta` rechazada. `ON CONFLICT` sólo pisa un día que seguía `abierto` | `db/ddl/02_tiempo.sql` (`fn_ausencia_resuelve_excepcion`) | 5 sep |

---

## III. Cerradas sin resolver

Preguntas que dejaron de importar, o que se decidió no responder en este proyecto. **Se registran
para que nadie las vuelva a abrir sin saber que ya se descartaron.**

| # | Pregunta | Por qué se cierra | Fecha |
|---|---|---|---|
| | | | |

---

*Preguntas abiertas · Folio SCJ-PRA-01 · V1.0*
