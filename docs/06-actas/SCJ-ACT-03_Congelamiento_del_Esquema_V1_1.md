# Acta — Congelamiento del esquema

**Sistema de Control de Jornada**
Folio SCJ-ACT-03 · Versión 1.1 · 23 de octubre de 2026

**A partir de esta fecha el esquema de los módulos 1 y 2 no cambia.** Corresponde a la tarea J3.1
del plan.

> **Cambio de versión (V1.0 → V1.1, 23-oct-2026):** la V1.0 era una plantilla vacía fechada el
> 25-sep, que nunca se llenó. Esta versión la llena con el estado real verificado contra la base el
> 23-oct-2026. Cambia también la firma: desde el 22-oct firma solo Diego (el colaborador académico
> ya no participa), y §V se ajusta a un solo responsable.

---

## I. Qué significa congelar

Lo que venga después son **ajustes de parámetros, no de estructura**.

Si en la operación aparece algo que exige cambiar el esquema, **se anota como pendiente para una
versión posterior** — no se cambia sobre la marcha con datos reales adentro.

El congelamiento cubre los **módulos 1 y 2** (Personas y Control de tiempo). El módulo 3 (vacaciones
completas y paquete de incidencias, todavía sin planear) traerá su propia estructura y su propia
acta (§IV).

---

## II. Lo que se congela

| | |
|---|---|
| Esquemas | `tiempo` (26 tablas) y `personas` (11 tablas) |
| Versión | Módulos 1 y 2 · DDL `00_` a `126_` (127 archivos) |
| Última migración aplicada | `126_tiempo_comment_parametro.sql` (aplicada el 23-oct-2026; solo `COMMENT ON`) |
| Huella del DDL | `a7a15caa3355dcb66ff97fdde4a29ae503fd3958683477772dc5b84670a26179` — `sha256` de los 127 archivos de `db/ddl/` concatenados en orden numérico (`cd db/ddl && cat $(ls \| sort -V) \| sha256sum`) |
| Base | Supabase `RTBGO` |
| Fecha | 23 de octubre de 2026 |

---

## III. Verificación previa

| # | Verificación | Resultado (23-oct-2026) |
|---|---|---|
| 1 | Los dos subsistemas funcionan integrados | **Sí.** Tarea V3.1 cerrada; el sistema opera con el piloto de la terminal Hikvision desde el 15-oct |
| 2 | La frontera de `SCJ-FRO-01` sigue intacta | **Sí, con una observación.** Ninguna FK de `tiempo` apunta a `personas.persona` ni copia identidad (solo `persona_id` y `fecha_ingreso`, §V de FRO-01). Hay dos FK de **autoría** hacia `personas.usuario(auth_user_id)`: `tiempo.parametro.registrado_por` (`60_`) y `tiempo.bitacora_movimiento_terminal_usuario.registrado_por` (`81_`). No son atributos de identidad, pero FRO-01 V1.2 no las menciona: hay que documentarlas (§IV, #3) |
| 3 | No quedan migraciones pendientes de aplicar | **Sí.** `00_` a `126_` aplicados. Verificado contra la base: el permiso de `79_` (`service_role` sobre `fn_dia_calcular_armado_tramos`), las funciones de `124_` y `125_`, el trigger de `123_` y el comentario de `126_` |
| 4 | La documentación corresponde a lo que está construido | **Sí, con observación.** Puestos al día hoy: `SCJ-MOD-02` V2.3 (26 tablas) y `SCJ-PRO-07` V1.2 (captura manual construida). Falta lo de FRO-01 (#2) |
| 5 | `SCJ-DIC-01` refleja el esquema real | **Sí.** V1.6 cuenta 26 tablas en `tiempo`, igual que la base |
| 6 | Las cinco consultas de validación pasan | **Parcial.** `db/verificar_ddl.sql` (secciones 1 a 88) corre sin errores y todas las verificaciones estructurales cumplen. Dos comentarios del script están desfasados: §7 espera 53 permisos y hay 54 (`120_`), y §10 espera 0 huérfanos de `auth.users` y hay 1, aceptado el 9-oct. La §9 (prueba HTTP con curl) no se corrió. Las consultas de negocio `03_calculo_historico`, `04_tope_vigente` y `05_reconstruccion_historica` que cita `SCJ-TRZ-01` **no existen** en `db/consultas/validacion/` (§IV, #4) |
| 7 | `SCJ-TRZ-01` no tiene requisitos en estado *Pendiente* sin justificación | **Sí.** Los pendientes tienen justificación: relleno del día impar (decisión del 22-oct: lo captura RH a mano, `SCJ-PRA-01 #14`); saldo de vacaciones y traslape por grupo (pasan al módulo 3, decisión del 23-oct); consultas de validación (#6) |

---

## IV. Pendientes que quedan fuera del congelamiento

Cambios identificados y **deliberadamente pospuestos**.

| # | Cambio | Por qué se pospone | Cuándo se retomaría |
|---|---|---|---|
| 1 | Protección de traslape de vigencias en `tiempo.tope_legal` (tiene `vigente_hasta` y solo `UNIQUE (vigente_desde)`) | Hay una sola vigencia y solo se crea por la RPC `fn_tope_legal_crear_vigencia` | Fixes de módulos 1 y 2, antes de registrar el tope de la reforma de 2027 |
| 2 | Estructura de vacaciones completas (saldo por antigüedad, periodos, prima) y paquete de incidencias para el despacho | Pasan al módulo 3, todavía sin planear (decisión del 23-oct) | Módulo 3, con su propia acta |
| 3 | Documentar en `SCJ-FRO-01` las FK de autoría hacia `personas.usuario` (`60_`, `81_`) | Solo documentación; no cambia el esquema | Fixes de módulos 1 y 2 |
| 4 | Escribir las consultas de validación `03_`, `04_` y `05_` de `SCJ-TRZ-01` y poner al día los comentarios §7 y §10 de `verificar_ddl.sql` | Son consultas de solo lectura; no cambian el esquema | Fixes de módulos 1 y 2 |

---

## V. Procedimiento para un cambio posterior

Si después de esta fecha resulta indispensable cambiar el esquema:

1. Se documenta el motivo por escrito
2. Lo aprueba por escrito el responsable del sistema (Diego) — **no se aplica sin esa aprobación**
3. Se escribe una migración numerada en `db/ddl/`, con ensayo `BEGIN…ROLLBACK`, nunca un cambio directo sobre la base
4. Se actualiza `SCJ-DIC-01` y la decisión de diseño afectada
5. Se levanta una versión nueva de esta acta

---

## VI. Firma

| | Nombre | Fecha |
|---|---|---|
| Responsable del sistema (módulos 1 y 2) | Diego Hermilo Guillén García | 27-oct-2026 |

---

*Acta de congelamiento · Folio SCJ-ACT-03 · V1.1*
