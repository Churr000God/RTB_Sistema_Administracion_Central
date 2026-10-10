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

## 9. Tareas en curso al momento de escribir esto

- `backend`: paso 1 del diseño v2 (simulador fiel y retiro de `currentVerifyMode`).
- `db`: diseño del parámetro `terminal_inferir_huella_activa`.
- `security`: revisión del diseño v2 del puente.
- `Checador`: lectura de solo lectura de los tipos JSON de los campos de puerta (entrega no confirmada).
- Pendiente del usuario: confirmar umbral y periodicidad de la revisión de la hora.
