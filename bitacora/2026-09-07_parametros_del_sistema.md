# 2026-09-07 · Módulo Parámetros — tercera pantalla, "Parámetros del sistema"

**Participantes:** Diego (usuario), `orchestrator` + equipo de 4 especialistas (`db`/`backend`/
`frontend`/`testing`) vía `team-orchestrator`.
**Duración:** una sesión, modo Plan (`ExitPlanMode`), exploración previa con 3 agentes `Explore`
en paralelo (DDL/backend/frontend) más un intento fallido de agente `Plan` (se colgó, 600s sin
progreso) — el plan lo terminó escribiendo `orchestrator` directamente con los 3 reportes de
exploración ya en mano.

---

## Qué se hizo

Cierra el pendiente declarado en `bitacora/2026-09-07_modulo_parametros_tope_legal_dias_festivos.md`
(no "Movimiento de saldo", que sigue pendiente — el usuario pidió esta pantalla primero:
`tiempo.parametro`, la tercera tabla de configuración sin pantalla propia).

**Migración `db/ddl/60_tiempo_parametro_vigencia_y_autor.sql`:** `tiempo.parametro` gana
`vigente_hasta date` (NULL = vigencia activa) y `registrado_por uuid REFERENCES
personas.usuario(auth_user_id)`, sin backfill (las 8 filas sembradas quedan con ambas columnas en
NULL). `REVOKE UPDATE, DELETE ... FROM anon, authenticated` — la tabla pasa a ser histórica
(gotcha de `ALTER DEFAULT PRIVILEGES` de siempre: `service_role` no se revoca, el RPC lo necesita).
RPC `tiempo.fn_parametro_actualizar_valor(clave, valor, registrado_por)`, SECURITY INVOKER, mismo
patrón que `fn_tope_legal_crear_vigencia` (`59_*.sql`) pero con una diferencia de diseño nueva: si
la vigencia activa ya es de **hoy**, hace `UPDATE` in-place en vez de abrir una vigencia nueva (dos
cambios del mismo parámetro el mismo día son la misma vigencia corregida, no dos vigencias — evita
el conflicto con `uq_parametro_clave_vigente` y un rango invertido). Clave sin vigencia activa →
`RAISE EXCEPTION ... USING ERRCODE = 'SCJ02'` (código nuevo, no confundir con `SCJ01` que ya
significa "conflicto de vigencia sin confirmar" en otros RPCs — acá el backend lo mapea a 404, no
409).

**Backend:** `catalogo_parametros.py` (nuevo) — catálogo cerrado en código, no en columnas de la
tabla, con las 8 claves de `SCJ-DIC-01 §IV`; `impacta_logica: bool` marca las 3 claves que algún
router/batch realmente lee hoy (`tolerancia_retardo_min`, `dias_habiles_correccion_marca`,
`hora_corrida_cierre_dia`) contra las 5 decorativas. `routers/parametros.py` (nuevo): `GET
/api/parametros` (vigentes + merge con catálogo), `GET /api/parametros/historial` (todas las
vigencias, sin query params — dataset chico, filtrado 100% client-side, mismo criterio que
`dias_festivos.py`), `PUT /api/parametros/{clave}`. Permisos `parametro_lectura`/
`parametro_edicion` **ya existían** en el catálogo (`33_permiso_tiempo_migracion_inicial.sql`) y ya
estaban mapeados a puestos — cero DDL de permisos nuevo. Detalle de diseño que surgió durante la
implementación (no estaba en el plan original): la validación de formato del valor no puede ser un
`@field_validator` de Pydantic porque la clave viaja por path, no en el body — quedó como función de
módulo `validar_formato_valor(clave, valor)` invocada desde el router antes del RPC.

**Frontend:** `pages/ParametrosSistemaPage.tsx` (nuevo) — dos `Card`: valores vigentes con edición
inline por fila + confirmación (fila expandible, patrón de `DiasFestivosPage.tsx`) mostrando valor
anterior → nuevo, y `Badge` marcando las claves sin efecto en la lógica actual y la que requiere
reiniciar el backend (`hora_corrida_cierre_dia`); historial con búsqueda por nombre (insensible a
acentos), rango de fechas y un `<select>` de orden — el proyecto no tiene (ni tuvo nunca) columnas
de tabla ordenables por clic, el patrón real siempre fue un select. Tercer ítem en el sidebar
("Parámetros del sistema") y ruta `/tiempo/parametros/sistema`.

**Testing:** `test_parametros.py` (13 casos) y `ParametrosSistemaPage.test.tsx` (8 casos). Sin
bugs reales encontrados — el contrato entre backend y frontend, fijado por el plan antes de
delegar, coincidió exacto. Detalle no trivial de los tests de frontend: la misma etiqueta de
parámetro aparece en las dos tablas (vigentes e historial) a la vez, hubo que escopar las
queries por tabla en vez de `screen.getByText` a secas.

## Qué se decidió

- Borde de vigencia **inclusivo** (`vigente_hasta = nueva.vigente_desde - 1`), no el semiabierto
  exclusivo de `SCJ-DEC-04` — consistencia con `tope_legal`/`jornada_asignada`, ya implementados
  así. Anotado como divergencia conocida en `SCJ-DEC-04`, sin tocar el código existente.
- `vigente_desde` siempre es hoy, puesto por el backend — sin campo de fecha en el formulario, sin
  programar cambios a futuro ni corregir retroactivamente.
- Sólo se editan valores de claves existentes — sin alta ni baja de parámetros desde la pantalla.
- Discrepancia real encontrada en `SCJ-DIC-01`: `hora_corte_dia` documentado como `03:00` pero
  sembrado como `00:00` — corregido el documento para que coincida con el seed (`00:00` es
  consistente con "hora de corte del día" como medianoche; `03:00` es el colchón de
  `hora_corrida_cierre_dia`, probablemente un copy-paste entre las dos filas de la tabla).
- Los 3 consumidores actuales de `tiempo.parametro` (`scheduler.py`, `correcciones.py`,
  `alertas_de_retardo.py`) no se tocaron — siguen ignorando `vigente_hasta` porque con una sola
  vigencia activa por clave el resultado no cambia.

## Qué quedó pendiente

- Módulo Parámetros: sigue faltando "Movimiento de saldo" (la pantalla que el usuario mencionó
  como pendiente desde el 7 de septiembre, antes de esta sesión).
- `hora_corrida_cierre_dia` cambiado desde la pantalla nueva no toma efecto hasta reiniciar el
  backend (el scheduler la lee una sola vez al arrancar) — la UI sólo advierte con un badge, no se
  implementó recarga en caliente ni reprogramación de APScheduler.

## Preguntas nuevas

-

## Nota para la retrospectiva

Primer intento fallido de agente `Plan` en este proyecto (colgado 600s sin progreso, con un
prompt largo que incluía los 3 reportes completos de exploración). `orchestrator` no reintentó el
agente — escribió el plan directamente con la información ya reunida, sin perder el trabajo de
exploración. Señal a vigilar: prompts muy largos para el agente `Plan` podrían necesitar acotarse
o partirse si vuelve a pasar.
