# Preguntas abiertas

**Sistema de Control de Jornada**
Folio SCJ-PRA-01 · Versión 1.0 · Agosto de 2026

Lista viva. Toda duda que aparece se anota aquí antes de resolverse. **Una pregunta que se resuelve
sin pasar por esta lista es una pregunta que nadie va a recordar en octubre.**

*Última actualización: 21 de octubre de 2026 (se marca lo que respondieron los scripts `118` a `125`).*

---

## I. Abiertas

| # | Pregunta | Levantada en | Fecha | Bloquea a |
|---|---|---|---|---|
| 02 | `POST /api/usuarios` (`backend/app/routers/usuarios.py:11`) usaba `get_service_client` (service_role) sin ningún chequeo de autenticación — cualquiera que alcanzara el endpoint podía invitar un usuario y atarlo al `persona_id` que quisiera. **Parcialmente resuelto 3 sep**: se agregó `Depends(get_caller_client)` — ahora exige Bearer token, igual que `personas.py`/`movimientos.py`. Sigue abierto: `personas.fn_caller_activo()` (la única RLS de `personas`) sólo valida "el caller tiene una persona activa detrás", sin distinción de rol — cualquier empleado activo con token válido puede invitar usuarios y atarlos a cualquier `persona_id`. No existe en el proyecto ningún concepto de permiso/rol todavía (`puesto`/`área`/`permiso` quedaron fuera de alcance de `SCJ-PRO-01`, decisión explícita). ¿Se gatea `alta_usuario` con una RLS/chequeo de rol admin explícito, o se introduce un modelo de permisos antes? Decisión de Diego (3 sep, vía orchestrator): aplicar sólo el gate de token ahora, el de rol queda para otra sesión. | Auditoría de seguridad, sesión `security` (rol) | 3 sep | modelo de permisos/rol (sin decisión aún) |
| 03 | `react-router-dom` en frontend (6.30.6) tiene 2 avisos moderados (open redirect y constructor injection en hidratación SSR — este último no aplica, la SPA no hace SSR). El único fix es bump mayor 6→7 (`npm audit fix --force`, breaking). Decisión de Diego (3 sep): no hacer el bump ahora, se hace después del QA de auth en sesión aparte. | Auditoría de seguridad, sesión `security` (rol) | 3 sep | ninguno todavía |
| 10 | `SCJ-ESP-01 §VI.8` exige saldo de vacaciones por antigüedad (tabla configurable, ej. 12 días el primer año, creciendo hasta un tope). No existe en el modelo — `SCJ-PRO-08` sólo cubre falta autodetectada, no solicitud de vacaciones. ¿Dónde vive esa tabla (`tiempo.parametro` genérico, o una tabla propia)? | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 11 | `SCJ-ESP-01 §VI.8` exige detectar traslape de ausencias entre personas de un mismo grupo. No implementado, y "mismo grupo" no está definido (¿mismo departamento? ¿mismo puesto?). | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 12 | `ausencia.documento_ref` (evidencia cargada) no tiene mecanismo de subida definido — ¿Storage de Supabase, mismo patrón que el expediente de Personas? | `SCJ-PRO-08`, al acotar alcance | 5 sep | Solicitud manual de ausencia (no construida) |
| 14 | `SCJ-ESP-01 §VI.2` exige que un día `bloqueado` (paridad impar) se rellene con la **jornada pactada** de esa persona ese día como `horas_totales`. **Parcialmente resuelto 5 sep:** el corte quincenal excluye el día del cálculo mientras siga `bloqueado` (`SCJ-ESP-01 V2.1`) — no importa el valor de relleno hasta que se revisa. Sigue abierto: cómo se calcula exactamente el relleno una vez revisado (¿`patron_semanal` completo del día, o algo distinto?) — se deja para cuando el sistema se aplique a la empresa real. **Estado al 21-oct-2026: sigue abierto.** Hoy el cierre de día atómico (`fn_cierre_dia_armar`, `124_`) crea el día impar `bloqueado` con `horas_totales` NULL y su excepción de día `paridad_impar`; RH lo revisa con `fn_dia_revisar` y **escribe las horas a mano** (`63_`), con ayuda de «Calcular tiempo total» (`65_`, solo sugiere), y el corte quincenal lo excluye mientras siga `bloqueado`. No cambió con `118`-`125`: sigue sin definirse un relleno automático. Conviene decidirlo antes de aplicar a la empresa real. | `SCJ-TRZ-01 III.2`, releído al escribir `SCJ-PRO-12` | 5 sep | Batch de cierre de día (sin programar) |
| 15 | `tiempo.marca` no guarda **quién capturó** una marca manual. Quien tenga captura manual y permiso de descarte (`excepcion_dia_cerrado_descarte`) podría crear una marca `fuera_de_horario` ajena y descartar su alerta (`125_` solo impide descartar la alerta de una marca propia). Mejora: guardar el autor de la captura en la marca e impedir descartar la alerta de una marca capturada por uno mismo. | Revisión de `security` de `125_` | 21 oct | Descarte auditado de alertas de horario (sin riesgo hoy: pocas personas con ambos permisos) |
| 16 | La normalización del motivo de `fn_excepcion_dia_cerrado_descartar` (`86_`) solo cubre `[[:cntrl:]]`; `125_` ya cubre separadores y bidireccionales Unicode, invisibles de ancho cero, NBSP y colapso de espacios antes de medir el mínimo. Alinear `86_` con `CREATE OR REPLACE` (repitiendo `SECURITY DEFINER` y `search_path`) la próxima vez que se toque esa función. | Revisión de `security` de `125_` | 21 oct | — (opcional) |
| 17 | Los `COMMENT ON` de `tiempo.parametro` (`03_`) y de `tiempo.persona` (`01_`) en el DDL remiten a documentos que ya no existen o describen el proyecto escolar (discrepancia 14 de `SCJ-DIC-01`); corregirlos exige un script nuevo. Se hará en un corte futuro. | Diccionario de datos V1.1 | 5 oct | — (cosmético) |

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
| 18 | ¿Por qué el corte de 01–15-oct-2026 cargó 86 h de deuda a una persona con permisos con goce autorizados? | Tres causas: los días de ausencia no tienen tramos (el corte solo sumaba tramos); la jornada neta de la ausencia usaba el descuento global de pausa y no `minutos_comida` por fila; y nada impedía aplicar dos veces un periodo sin tramos. Corregido: el corte cuenta `horas_totales` de los días sin tramos, la ausencia usa `minutos_comida` por fila (`118_`) y los periodos se registran por persona (`119_`) | `SCJ-PRO-13` V1.1, `118_`, `119_` | 20 oct |
| 19 | ¿Cómo se deshace un `generado_quincena` erróneo sin editar un libro inmutable? | Movimiento `compensacion` ligado al original, con motivo y autor, una sola vez, sin saldo negativo, con permiso no heredable (`120_`). El endpoint y la pantalla de la compensación **aún no existen**: hoy solo se aplica con un script de corrección autorizado | `SCJ-DEC-02` V1.1, `120_` | 20 oct |
| 20 | ¿Se puede cambiar el tipo de una ausencia ya resuelta (p. ej. de sin goce a con goce) y borrar deuda sin rastro? | No: una ausencia resuelta no cambia de tipo, ni siquiera `service_role` (`SCJ25`) | `SCJ-PRO-08` V1.1, `121_` | 20 oct |
| 21 | ¿Quién puede resolver una ausencia? ¿Puede aprobarse la propia? | Nadie resuelve su propia ausencia (`SCJ26`); la aprobación queda a nombre de quien la hace; tampoco se edita el tipo de la propia ausencia pendiente | `SCJ-PRO-08` V1.1, `SCJ-DEC-05` V1.1, `122_` | 20 oct |
| 22 | ¿Puede alguien con `dia_revision_edicion` escribir por PostgREST un tramo con minutos e instantes arbitrarios? | No: el trigger de `123_` exige que `inicio`, `fin` y `minutos_trabajados` coincidan con los momentos efectivos de las marcas (`SCJ15` / `tramo_tiempos_incoherentes`); y dos correcciones de una marca no comparten `creado_en` | `SCJ-PRO-12` V1.1, `123_` | 21 oct |
| 23 | ¿Un fallo a medias del cierre puede dejar un día creado sin tramos que la idempotencia salte para siempre? | Ya no: el cierre de cada día es una sola transacción (`fn_cierre_dia_armar`, `SCJ27`) | `SCJ-PRO-12` V1.1, `124_` | 21 oct |
| 24 | ¿Cómo se resuelve una alerta `fuera_de_horario` cuando el día ya cerró y la marca ya está en un tramo (no se puede corregir)? | Descarte auditado `fn_excepcion_horario_descartar` (permiso `excepcion_dia_cerrado_descarte`, motivo de 10 a 500 caracteres, nunca la alerta propia), con constancia inmutable | `SCJ-PRO-10` V2.0 §VII, `SCJ-DEC-07` V1.1, `125_` | 21 oct |
| 25 | Si alguien con `correccion_edicion` (RH) no podía corregir una marca con excepción pendiente, ¿era de permisos o de datos? | Era un defecto de la policy de INSERT de `tiempo.correccion` (`e.marca_id = marca_id` comparaba la columna consigo misma, así que exigía `excepcion_reapertura` a todos). Corregido calificando la fila nueva | `SCJ-PRO-10` V2.0, `117_` | 19 oct |

---

## III. Cerradas sin resolver

Preguntas que dejaron de importar, o que se decidió no responder en este proyecto. **Se registran
para que nadie las vuelva a abrir sin saber que ya se descartaron.**

| # | Pregunta | Por qué se cierra | Fecha |
|---|---|---|---|
| | | | |

---

*Preguntas abiertas · Folio SCJ-PRA-01 · V1.0*
