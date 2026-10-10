# 2026-10-10 · SCJ-PRO-15 — Estado de la sesión del puente y la terminal Hikvision (para retomar tras compactar)

**Participantes:** el usuario, `orchestrator` (esta sesión) y las sesiones locales `backend`, `frontend`, `db`, `testing`, `security`, `devops`; sesión remota `Checador` (Pi del puente).
**Propósito de este documento:** reconstruir el contexto completo si la conversación se compacta. Resume lo ocurrido el 9 y 10 de octubre de 2026, lo decidido, el estado de cada repositorio y de la base, las reglas de trabajo aprendidas y lo que sigue.

---

## 1. Dónde está todo

- **Repositorio principal** `RTB-CRM-APP` (GitHub `Churr000God/RTB_Sistema_Administracion_Central`, rama `main`): backend, frontend, DDL en `db/ddl/` (`00` a `96`), ensayos en `db/ensayos/`, contratos y procesos en `docs/07-procesos/`, mockups en `diseno_paginas/tiempo_terminales_enrolamiento/`.
- **Repositorio del puente** `checador-fisico` (`/home/diego/Proyectos/checador-fisico`, GitHub `Churr000God/Checador_RTB`): el puente nuevo en `puente/` (SQLite, cliente ISAPI, ingesta, subida, trabajador, reconciliación, simulador) y el checador básico retirado (`backend/`, no se despliega).
- **Dos Raspberry Pi distintos.** El *Pi de pruebas* (`raspberrypi-serverpruebas`, Tailscale 100.115.160.115) despliega el sistema de administración central (backend :8000, frontend :8080). El *Pi del puente* (192.168.10.50, nodo `checador`) es el que hablará con la terminal; ahí corre la sesión `Checador`. Nada del puente nuevo está desplegado todavía.
- **Plan consolidado:** `docs/07-procesos/PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md`. **Checklist de TI:** `docs/07-procesos/CHECKLIST_TI_VERIFICACION_TERMINAL.md`. Contratos: `CONTRATO_API_PUENTE_TERMINAL.md` y `CONTRATO_API_TERMINALES_PAQUETE_2.md`.
- **Bitácoras relevantes:** `2026-10-09_decision_no_rotar_llaves_supabase.md`, `2026-10-10_verificacion_terminal_hikvision_con_ti.md` y este documento.

## 2. Estado de la base real (Supabase)

`94_`, `95_` y `96_` (parte A) están **aplicados y verificados**, cada uno con `psql --single-transaction`, comprobaciones antes y después y el verificador completo en 0 filas (`verificar_ddl.sql`, secciones 57 a 59):

- `94_`: columna `huella_evidencia` y `marca_id` en la bitácora, tipos de movimiento `huella_confirmada_manual` (web) y `huella_inferida` (terminal), trigger, caducidad (`FOR UPDATE SKIP LOCKED`) y anomalías 11 a 13. `tipo_movimiento` pasó a 30 caracteres.
- `95_`: activación por la primera marca verificada por huella dentro de `fn_marca_terminal_registrar` (campo opcional `modo_verificacion`, solo la cadena `huella`).
- `96_` parte A: avisos de dos funciones sin `employee_no` ni `persona_id`. La **parte B (endurecer `anon`)** no existe aún como SQL.
- Línea base: 76 policies, 53 permisos, `terminal_usuario` vacía, `terminal_caducidad_alta_horas` en **168** (puesta por el usuario el 9 de octubre), 1 terminal activa sin tráfico, 0 marcas recientes.
- Pendientes de base: parámetro del servidor `terminal_inferir_huella_activa` (diseño de `db`, sería `97_`), parte B de `anon` con inventario y ensayo, `RAISE EXCEPTION` que interpolan valores, y migraciones reales del esquema del puente.

## 3. Estado de los despliegues

Backend y frontend desplegados en el Pi de pruebas a **`87a5a85`** (devops, con aprobación del usuario en la sesión de `devops`). Verificado con Chrome (Terminales, Usuarios, Anomalías 13/13, sin errores). El backend se niega a arrancar si falta la columna `huella_evidencia` (precondición de esquema). Orden obligatorio de cambios: DDL, luego backend, luego frontend. Commits posteriores de documentación (`c4f2de5` y los de bitácora) no requieren redespliegue.

## 4. Verificación real de la terminal (9 y 10 de octubre)

La sonda de solo lectura y la verificación con el usuario (ver su bitácora) corrigieron supuestos:

- **No hay `numOfFP`:** el firmware no informa el conteo de huellas. Diseño sin conteo: huella declarada por la primera marca verificada (`huella_inferida`, vía B) o por confirmación humana en la web (`huella_confirmada_manual`, vía C). Sin excepciones a las rutas `FingerPrint`; borrado automático de huérfanos eliminado (solo manual).
- **El alta con cuerpo mínimo falla** (HTTP 400, `MessageParametersLack`): V1.3.0 exige vigencia, derecho de puerta y plan. Valores por omisión: habilitado, vigencia hasta 2037, `doorRight 1`, `RightPlan` puerta 1 plantilla 1.
- **No existe `currentVerifyMode`**: el método se deduce del `minor` (38 huella aceptada, **49 rechazada**, no 39). Eventos de operación `major 3`, `minor 80/81` sin número de empleado.
- **Serial disperso y página real de unas 10 filas**; `deviceInfo` y `System/time` responden XML; hora manual sin NTP; zona corregida a `CST+6:00:00`.

## 5. Decisiones del usuario vigentes

- Terminal **solo asistencia, sin puerta**; condición escrita: ningún relevador ni cerradura conectados a la salida mientras los usuarios tengan derecho de puerta.
- **Hora manual con revisión periódica**, sin NTP. Propuesta pendiente de confirmar: alerta de desfase desde 2 minutos; revisión de TI semanal el primer mes, después mensual y tras cortes de energía.
- **No rotar** las llaves de Supabase (riesgo aceptado, documentado). El `.env` del Pi del puente se borró.
- Caducidad de altas en **168 horas**. Concurrencia verificada por revisión de código y en la primera alta real (opción c), sin script sobre la base real.
- Botón web «Confirmar huella» aprobado; D1 reutilizar `terminal_usuario_edicion`; D2 cuatro ojos apagado con alerta; D5 nota de al menos 10 caracteres.
- Migraciones: ninguna ahora (no hay base que conservar); congelar el esquema del puente tras T-PI-6/T-PI-9, con respaldo automático antes de migrar.
- El huérfano de Auth `prueba-diagnostico-local@example.com` se deja.

## 6. Estado del puente (`checador-fisico`)

T-PI-1 a T-PI-5 completos y T-PI-6 corte A (detección e informe, sin borrado), con pruebas de bordes y mutación; pusheado hasta `949c5d1` (esquema v15). Con la verificación real, backend aprobó el **diseño v2** (cuerpo de alta completo con constantes y comparación posterior; vía B por `minor 38` y 49 como denegado; interruptor de la vía B también en el servidor; serial disperso con `cursor_fuera_del_buffer`; paginación con tope; validación de zona en T-PI-7) en pasos 1 a 5: simulador fiel, cuerpo de alta, minors, ingesta, documentación. Cada paso es un commit local revisado por `security` antes del push.

## 7. Reglas de trabajo aprendidas (obligatorias)

- Toda escritura en la base real requiere autorización explícita del usuario por operación; los ensayos son siempre `BEGIN…ROLLBACK`, por el pooler de sesión (5432), con salida sin `employee_no`, `persona_id` ni nombres. Nunca fixtures comprometidos en la base real.
- El `git push` lo hace `orchestrator` con el OK del usuario y la revisión de `security`; antes de empujar **verificar `git log origin/main..main`** (una vez se arrastró un commit sin revisar).
- Una sesión no puede aceptar la autorización de otra: el despliegue en el Pi de pruebas se aprobó en la propia sesión de `devops`. Nunca pedir a un compañero que haga lo que se denegó.
- Nombres de sesión duplicados: usar la referencia de la sesión local viva (`backend [afc10b]`, `testing [8118f3]`, `security [8da837]`, `db [80ac33]`, `frontend [f369b0]`, `devops [f22327]`); `Checador [08fdf2]` es remota (Remote Control) y la entrega de mensajes no se confirma.
- Mutaciones y pruebas destructivas solo sobre copias en el scratchpad, nunca `git checkout` sobre árbol con trabajo sin commit; `git add` archivo por archivo con `git status` antes.
- Para el navegador: la sesión de Chrome solo controla su propio grupo de pestañas; el usuario inicia sesión en la pestaña de ese grupo y no se escriben contraseñas.

## 8. Qué sigue, en orden

1. Terminar el diseño v2 del puente (pasos 1 a 5) con revisión de `security`; confirmar tipos JSON reales de los campos de puerta (los lee `Checador`).
2. `db` diseña el parámetro `terminal_inferir_huella_activa` (`97_`); después ensayo y aplicación, cada uno con autorización del usuario.
3. T-PI-7 (hora y zona, medir y alertar el desfase) y T-PI-9 (el servicio que cablea todo). Después congelar el esquema del puente y escribir migraciones.
4. Reserva de respaldo en el router y aislamiento de red de la terminal (acciones del usuario).
5. Primera alta real supervisada con TI y RH, con la caducidad en 168 horas; ahí se ven el botón «Confirmar huella» y las etiquetas, y se activa la vía B tras comprobar el modo de verificación.
6. Parte B de `anon`, `RAISE EXCEPTION` con valores, y retiro del checador básico (T-PI-10).

## 8 bis. Revisiones de `security` recibidas después del diseño v2 (pendientes de aplicar en código)

- **Serial (lo más importante):** `salto_serial` NO se elimina sin medir. Es la única señal de que a la terminal le faltan eventos. Hay que medir con la terminal real (lectura de solo lectura que se pidió a `Checador`) si el serial es **contiguo cuando se piden todos los eventos** (`major 0`, `minor 0`). Si es contiguo: pedir todo, filtrar localmente y conservar `salto_serial` cuantificado. Si no: eliminar el hueco pero añadir una **auditoría periódica por conteo** de los eventos de acceso aceptados contra las marcas subidas. `cursor_fuera_del_buffer`: una alerta por episodio (avanza el cursor) y mensaje «posible pérdida» con consulta filtrada.
- **`beginTime` fijo y lejano** (por ejemplo 2020-01-01T00:00:00-06:00), no el inicio del día; `endTime` fijo 2037-12-31T23:59:59-06:00; comparar instantes, no texto. En producción solo la política de derechos (c); (a) y (b) viven en la herramienta de prueba. Tope de unas 50 páginas por ciclo (no 500). El reloj del Pi debe estar sincronizado (chrony) para medir el desfase; un salto fuera de rango da `sin_sincronizar` de inmediato.
- **Interruptor de la vía B en el servidor:** diseño de `db` (`97_` mínimo: siembra del parámetro `terminal_inferir_huella_activa` en 0, catálogo y un `CHECK` que impide valores distintos de 0 y 1, porque el lector acota y un `7` se leería como activo; `98_`: `fn_marca_terminal_registrar` lee el interruptor una vez por lote y falla cerrado; bitácora append-only y función dedicada con nota al activar, en cortes siguientes antes de permitir activarlo en producción). `service_role` conserva escritura sobre `tiempo.parametro`: el interruptor protege contra el puente y el backend, no contra quien tenga esa llave. Falta revisión de `security` y la decisión D1 a D4 del usuario.

**Orden aceptado por `security` para el interruptor de la vía B:** `97_` COMPLETO en un solo archivo (siembra en 0, catálogo, `CHECK`, bitácora append-only de configuración, **trigger de auditoría** sobre `tiempo.parametro`, función dedicada con nota de al menos 10 caracteres al activar, y rechazo de la clave en `fn_terminal_config_actualizar`) → `98_` (`fn_marca_terminal_registrar` lee el interruptor en crudo comparando con la cadena exacta `'1'`; todo lo demás es apagado; nunca el lector tolerante que acota) → activarlo solo con la primera alta real supervisada. Decisión de producto pendiente: «activo hasta» con apagado automático. Ningún corte se aplica sin autorización del usuario. `db` rehace el resumen del diseño con esos requisitos.

**Tipos JSON reales del alta (lectura de `Checador`, 10 de octubre):** `Valid.enable` bool; `beginTime`/`endTime` string con desfase al leer (el aparato también acepta la cadena sin desfase en la entrada y la normaliza); `Valid.timeType` string (`local` o `UTC`); `doorRight` string `"1"`; `RightPlan[].doorNo` entero; `RightPlan[].planTemplateNo` string `"1"`; `userType` `"normal"`; `maxOpenDoorTime` y `openDoorTime` enteros 0; `userVerifyMode` string vacío en la entrada hereda el modo global. Límites: número de empleado de hasta 8 dígitos numéricos, nombre de hasta 64, 1000 usuarios, unos 100 000 eventos. Queda confirmada la hipótesis de `backend` sobre los tipos. Falta la medición de contigüidad del serial.

**Diseño v3 del interruptor (`db`, pendiente de revisión de `security` y de la autorización del usuario):** `97_` completo con siembra en 0, `CHECK`, bitácora append-only de configuración, trigger de auditoría sobre `tiempo.parametro`, función dedicada con nota al activar (hoy UTC explícito) y rechazo de la clave en `fn_terminal_config_actualizar`; `98_` con lectura cruda estricta `valor = '1'` dentro de `fn_marca_terminal_registrar`. Decisiones abiertas D1 a D4: clave fuera del catálogo (recomendado), «activo hasta» con apagado automático (recomendado sí, con tope de 30 días, y debe entrar ya), la nota por variable de transacción y que quien tenga `service_role` pueda escribir la fila directamente (solo queda registrado). Ningún SQL escrito ni aplicado.

**Medición real del serial (lectura de `Checador`, 10 de octubre):** `serialNo` es un contador **global, único, contiguo y creciente sobre todos los tipos de evento** (`major` 2 excepciones, 3 operación, 5 acceso). Pidiendo todos los eventos (`major 0`) los 38 seriales son consecutivos; pidiendo solo acceso salen huecos que son exactamente eventos de otros tipos. Decisión: el puente **pide todos los eventos, filtra localmente y conserva `salto_serial`** como señal fuerte cuantificada; `cursor_fuera_del_buffer` es preciso (posición 0 igual a cursor más 1 es sin pérdida). Techo del firmware 3 000 000 000, buffer de unos 100 000 eventos, páginas de unos 10. Los eventos `major 2` (excepciones, `minor` 39 y 1024 a 1031) se cuentan con alerta local ante picos o tipos nuevos; los `major 3` `minor` 80/81 son altas y enrolamientos normales.

**Precauciones de `security` para pedir todos los eventos:** un evento que no es de acceso nunca es malformado (solo se exige serial, `major` y `minor` válidos; `employeeNoString` y `time` solo en `major 5` con `minor` 38 o 49); el cursor y la continuidad recorren todos los eventos, incluidos los ignorados; en cada ciclo `totalMatches` debe igualar último serial menos primero más 1, y si no cuadra faltan eventos dentro del buffer (alerta fuerte y evidencia, sin detener); los eventos `major 2` y `major 3` se cuentan por (`major`, `minor`) con tope de 20 claves, alerta ante tipo nuevo o pico, y el latido al servidor lleva solo contadores agregados; tope de unas 50 páginas por ciclo; el serial puede llegar a 3 000 000 000 (entero de 64 bits); la contigüidad no autentica (residuo del HTTP en claro).

**Diseño final v4 del interruptor:** `db/ensayos/DISENO_interruptor_inferir_huella.md` (208 líneas, solo texto, aprobado por `security` en D1 a D4 y P1 a P5). Resumen de lo consolidado: `97_` completo en un archivo y una transacción (siembra de dos claves, `terminal_inferir_huella_activa` y `terminal_inferir_huella_hasta` con valor centinela vencido, `CHECK`, bitácora append-only sin `FK`, trigger de auditoría estrecho sobre las dos claves, función dedicada con nota de al menos 10 caracteres, vencimiento máximo de 30 días, rechazo si no hay consentimiento vigente o terminal activa, y lector del estado efectivo como única definición); `98_` (`fn_marca_terminal_registrar` lee ese lector una vez por lote). Falta: confirmación del usuario de «activo hasta», autorización para escribir el SQL y autorizaciones separadas para ensayar y aplicar. Texto propuesto para `CLAUDE.md` se entrega al aplicar.

**Diseño v3 del puente (`backend`, aprobado en diseño, código de los pasos 2 a 4 EN ESPERA de un «go» explícito tras compactar):** paso 1 (simulador fiel con serial global contiguo, mezcla de eventos `major` 2, 3 y 5, páginas de hasta 10, alta con cuerpo completo validado, `por_huella` por `minor 38`, denegado 49) hecho y verde sin commitear (`backend` lo commitea y guarda el diseño en `puente/DISENO_v3_tras_verificacion.md`); paso 2: alta con constantes (`beginTime` fijo 2020-01-01T00:00:00-06:00, `endTime` 2037-12-31T23:59:59-06:00, `timeType` `local`, `doorRight` `"1"`, plan puerta 1 plantilla `"1"`), relectura comparando instantes, código fijo `terminal_rechazo_cuerpo_alta`; paso 3: ingesta pidiendo todos los eventos, filtro local, `salto_serial` cuantificado, `cursor_fuera_del_buffer` preciso, comprobación `totalMatches` igual a último menos primero más 1, contadores por (`major`, `minor`) con tope de 20 claves, tope de unas 50 páginas por ciclo y turno por página, esquema v16; paso 4: pruebas de integridad; T-PI-7: medir desfase de la hora (como máximo cada 60 segundos), umbral 120 segundos configurable, marcas con `deriva` o `sin_sincronizar` nunca descartadas. El interruptor del servidor sigue el diseño v4 de `db`.

## 9. Tareas en curso al momento de escribir esto

**Al compactar (10 de octubre de 2026):** todas las tareas de análisis y diseño terminaron. No hay trabajo de código en vuelo salvo que `backend` commitea el paso 1 del puente y guarda su diseño v3. Nada nuevo se aplicó en la base después de `96_`.

**Cómo retomar:**

1. Leer este documento y los tres de apoyo: `2026-10-10_verificacion_terminal_hikvision_con_ti.md`, `db/ensayos/DISENO_interruptor_inferir_huella.md` y `puente/DISENO_v3_tras_verificacion.md` (en `checador-fisico`).
2. Verificar con `git log origin/main..main` en los dos repositorios y listar sesiones con `ListAgents` (referencias locales indicadas en la sección 7).
3. Dar el «go» a `backend` para los pasos 2 a 4 del diseño v3 del puente (un commit por paso, revisados por `security` antes de empujar); pedir a `security` que revise el simulador del paso 1.
4. Decisiones del usuario aún abiertas: periodicidad y umbral de la revisión de la hora (propuesta: 120 segundos y semanal el primer mes), «activo hasta» del interruptor (recomendado sí, con tope de 30 días), y si se hace la prueba opcional de derecho de puerta vacío.
5. Antes de escribir el SQL del interruptor (`97_` y `98_`): confirmación del usuario de «activo hasta» y autorización expresa; ensayar y aplicar son autorizaciones separadas.
6. Acciones físicas del usuario: reserva DHCP y aislamiento de red de la terminal; primera alta real supervisada con TI y RH (caducidad en 168 horas).
7. La sesión remota `Checador` es la única con acceso a la terminal; su entrega de mensajes no se confirma y a veces hay que pegarle el texto.
