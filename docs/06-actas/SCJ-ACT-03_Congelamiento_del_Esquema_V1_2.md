# Acta — Congelamiento del esquema

**Sistema de Control de Jornada**
Folio SCJ-ACT-03 · Versión 1.2 · 28 de octubre de 2026

**El esquema de los módulos 1 y 2 sigue congelado.** Esta versión registra el primer cambio
posterior al congelamiento, hecho con el procedimiento de §V. Corresponde a la tarea J3.1 del plan.

> **Cambio de versión (V1.1 → V1.2, 28-oct-2026):** primer cambio sobre el esquema congelado
> (P-055, con P-182 fusionada). **Motivo:** la base corre con `TimeZone = UTC`. Entre las 18:00 y
> las 24:00 de la Ciudad de México, `CURRENT_DATE` ya daba la fecha del día siguiente. Las
> protecciones de vigencias de jornada (`75_`, `76_`), las bajas de personas y las vigencias de
> parámetros y de configuración de terminales tomaban «mañana» como «hoy». La V1.1 congeló `00_` a
> `126_` sin anotar P-055 entre los pendientes (§IV): se pasó por alto. Al revisar el cambio
> aparecieron dos hallazgos más del mismo origen, y se corrigieron con él:
> - **`127_`:** las 10 funciones de `tiempo` y `personas` que usaban `CURRENT_DATE` como «hoy»
>   pasan a `personas.fn_hoy_mexico()`.
> - **`128_`:** la baja por la bitácora (`personas.fn_bitacora_sincroniza_persona`) toma la fecha en
>   México del instante de la baja, en lugar de `fecha_efectiva::date`.
> - **`129_`:** la baja definitiva exige también el permiso `asignacion_edicion` (policy
>   `bitacora_insert_requiere_permiso`). Sin ese permiso, la persona quedaba dada de baja con sus
>   asignaciones abiertas, sin ningún error.
>
> **No cambia la estructura:** mismas tablas, columnas, restricciones, índices, permisos y claves de
> parámetro, y las mismas cifras de §II, salvo el número de archivos de DDL.
>
> **Aprobación (§V, paso 2):** Diego, el 28-oct-2026, por escrito en dos lugares:
> - El chat de esa fecha, para `127_`, con el alcance de las cuatro funciones extra. Queda en la
>   bóveda de Sistemas: `Sistemas/Bitacora/2026-10-28_p055_fecha_mexico_cambio_esquema.md`.
> - El chat de coordinación de la sesión `orchestrator`, para `128_` («Sí, sumarla») y para `129_`
>   (la opción C de `security`: una policy, sin `SECURITY DEFINER`).
>
> **Revisión:** `security` revisó y aprobó `127_`, `128_` y `129_`.

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
| Versión | Módulos 1 y 2 · DDL `00_` a `129_` (130 archivos) |
| Última migración aplicada | `129_personas_baja_exige_asignacion_edicion.sql`. `127_`, `128_` y `129_` se aplicaron el 28-oct-2026, en ese orden, con el comando de Diego, y se verificaron en solo lectura ese mismo día |
| Huella del DDL | `a5aa73ad183fa195f633f1cd4af0b8e6a908124a452845021eea1adf0611af92` — `sha256` de los 130 archivos de `db/ddl/` concatenados en orden numérico (`cd db/ddl && cat $(ls \| sort -V) \| sha256sum`). Huella de la V1.1 (`00_` a `126_`): `a7a15caa3355dcb66ff97fdde4a29ae503fd3958683477772dc5b84670a26179` |
| Catálogo (solo lectura, 28-oct-2026) | 37 tablas; 97 funciones propias (45 `SECURITY DEFINER`, 45 de trigger); 76 policies RLS; 54 permisos (27 no heredables); 15 claves en `tiempo.parametro`. Iguales a la V1.1: los tres scripts nuevos no agregan ni quitan objetos |
| Base | Supabase `RTBGO` |
| Fecha | 23 de octubre de 2026 (congelamiento) · 28 de octubre de 2026 (cambio de la V1.2) |

---

## III. Verificación previa

Las verificaciones 1 a 7 son las del congelamiento (23-oct-2026) y siguen vigentes. La 8 es la del
cambio de la V1.2.

| # | Verificación | Resultado |
|---|---|---|
| 1 | Los dos subsistemas funcionan integrados | **Sí.** Tarea V3.1 cerrada; el sistema opera con el piloto de la terminal Hikvision desde el 15-oct |
| 2 | La frontera de `SCJ-FRO-01` sigue intacta | **Sí, con una observación.** Ninguna FK de `tiempo` apunta a `personas.persona` ni copia identidad (solo `persona_id` y `fecha_ingreso`, §V de FRO-01). Hay dos FK de **autoría** hacia `personas.usuario(auth_user_id)`: `tiempo.parametro.registrado_por` (`60_`) y `tiempo.bitacora_movimiento_terminal_usuario.registrado_por` (`81_`). No son atributos de identidad, pero FRO-01 V1.2 no las menciona: hay que documentarlas (§IV, #3). `127_`–`129_` no tocan la frontera |
| 3 | No quedan migraciones pendientes de aplicar | **Sí.** `00_` a `129_` aplicados. Al congelar se comprobó contra la base el permiso de `79_` (`service_role` sobre `fn_dia_calcular_armado_tramos`), las funciones de `124_` y `125_`, el trigger de `123_` y el comentario de `126_`. Para `127_` a `129_`, ver la #8 |
| 4 | La documentación corresponde a lo que está construido | **Sí, con una observación.** Están al día `SCJ-MOD-02` V2.3 (26 tablas), `SCJ-PRO-07` V1.2 (captura manual construida), `SCJ-DIC-01` V1.7 y `SCJ-DEC-04` V1.1 (estos dos con `127_`–`129_`). Falta lo de FRO-01 (#2) |
| 5 | `SCJ-DIC-01` refleja el esquema real | **Sí.** La V1.7 cuenta 37 tablas, 97 funciones, 76 policies y 54 permisos, igual que el catálogo del 28-oct |
| 6 | Las cinco consultas de validación pasan | **Parcial.** `db/verificar_ddl.sql` (secciones 1 a 92) corre sin errores y todas las verificaciones estructurales cumplen. Hay dos comentarios del script desfasados: el §7 espera 53 permisos y hay 54 (`120_`), y el §10 espera 0 huérfanos de `auth.users` y hay 1, aceptado el 9-oct. La §9 (prueba HTTP con curl) no se corrió. Las consultas de negocio `03_calculo_historico`, `04_tope_vigente` y `05_reconstruccion_historica` que cita `SCJ-TRZ-01` **no existen** en `db/consultas/validacion/` (§IV, #4) |
| 7 | `SCJ-TRZ-01` no tiene requisitos en estado *Pendiente* sin justificación | **Sí.** Los pendientes tienen justificación: relleno del día impar (decisión del 22-oct: lo captura RH a mano, `SCJ-PRA-01 #14`); saldo de vacaciones y traslape por grupo (pasan al módulo 3, decisión del 23-oct); consultas de validación (#6) |
| 8 | El cambio de la V1.2 (`127_`–`129_`) se ensayó y se verificó | **Sí.** Los tres se ensayaron con `BEGIN…ROLLBACK` contra la base real, con datos sintéticos y sin residuo: `ensayo_127` 54/54, y 58/58 con la reversa probada; `ensayo_128` 20/20; `ensayo_129` 19/19. Después de aplicarlos, en solo lectura: las secciones 55, 89, 90 y 91 de `verificar_ddl.sql` dan 0 filas; la 92 (informativa: puestos con `cambio_estado_persona` sin `asignacion_edicion`, contando herencia) también da 0, así que `129_` no le quita a ningún puesto real la posibilidad de dar bajas. Los atributos, el dueño y el `EXECUTE` de las 11 funciones, y el comando, los roles y el `USING` de la policy, son iguales a los de antes del cambio. Cada script tiene su reversa ejecutable en `db/ensayos/` (`vigente_127_*`, `vigente_128_*`, `vigente_129_*`) |

---

## IV. Pendientes que quedan fuera del congelamiento

Cambios identificados y **deliberadamente pospuestos**.

| # | Cambio | Por qué se pospone | Cuándo se retomaría |
|---|---|---|---|
| 1 | Protección de traslape de vigencias en `tiempo.tope_legal` (tiene `vigente_hasta` y solo `UNIQUE (vigente_desde)`) | Hay una sola vigencia y solo se crea por la RPC `fn_tope_legal_crear_vigencia` | Fixes de módulos 1 y 2, antes de registrar el tope de la reforma de 2027 |
| 2 | Estructura de vacaciones completas (saldo por antigüedad, periodos, prima) y paquete de incidencias para el despacho | Pasan al módulo 3, todavía sin planear (decisión del 23-oct) | Módulo 3, con su propia acta |
| 3 | Documentar en `SCJ-FRO-01` las FK de autoría hacia `personas.usuario` (`60_`, `81_`) | Solo documentación; no cambia el esquema | Fixes de módulos 1 y 2 |
| 4 | Escribir las consultas de validación `03_`, `04_` y `05_` de `SCJ-TRZ-01` y poner al día los comentarios §7 y §10 de `verificar_ddl.sql` | Son consultas de solo lectura; no cambian el esquema | Fixes de módulos 1 y 2 |
| 5 | *(V1.2)* `CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)` en `tiempo.parametro` y `tiempo.tope_legal`. `tiempo.jornada_asignada` y `personas.asignacion` ya lo tienen | Hallazgo BAJO de `security` en la revisión de `127_`. Las únicas vías de escritura son las RPC versionadas, que ya no producen intervalos invertidos con «hoy» en hora de México. Agregar el `CHECK` es un cambio de estructura | Fixes de módulos 1 y 2, con su propia migración y ensayo (antes, comprobar que ninguna fila real lo viole) |
| 6 | *(V1.2)* El interruptor de la activación por huella (`fn_terminal_inferir_huella_cambiar`/`_estado`, claves `terminal_inferir_huella_*`) sigue con fecha UTC explícita | Decisión de Diego del 28-oct-2026: se deja así **a propósito** (`97_`; `ensayo_98` prueba la medianoche UTC). Está fuera de la regla de `127_`. Cualquier chequeo de `vigente_desde > fn_hoy_mexico()` sobre `tiempo.parametro` debe excluir esas claves | Solo si se decide alinearlo con la fecha de México. Exigiría versión nueva de esta acta |

Fuera del esquema, y por eso no está en esta tabla: validar `persona_id` como UUID en la ruta de
`/api/personas` es del backend. Lo sigue la bitácora del 28-oct-2026, no esta acta.

---

## V. Procedimiento para un cambio posterior

Si después de esta fecha resulta indispensable cambiar el esquema:

1. Se documenta el motivo por escrito
2. Lo aprueba por escrito el responsable del sistema (Diego) — **no se aplica sin esa aprobación**
3. Se escribe una migración numerada en `db/ddl/`, con ensayo `BEGIN…ROLLBACK`, nunca un cambio directo sobre la base
4. Se actualiza `SCJ-DIC-01` y la decisión de diseño afectada
5. Se levanta una versión nueva de esta acta

En la V1.2 se cumplieron los cinco pasos:
1. **Motivo:** la nota de cambio de esta versión y la bitácora de la bóveda.
2. **Aprobación:** la nota de cambio de esta versión.
3. **Migraciones:** `127_`, `128_` y `129_`, con sus ensayos (#8 de §III).
4. **Documentación:** `SCJ-DIC-01` V1.7 y `SCJ-DEC-04` V1.1.
5. **Acta:** esta versión.

---

## VI. Firma

| | Nombre | Fecha |
|---|---|---|
| Responsable del sistema (módulos 1 y 2) | Diego Hermilo Guillén García | ____-oct-2026 *(a llenar al firmar la V1.2)* |

La V1.1 se firmó el 27-oct-2026; esa firma queda en el historial del repositorio (commit `9ebb534`).

---

*Acta de congelamiento · Folio SCJ-ACT-03 · V1.2*
