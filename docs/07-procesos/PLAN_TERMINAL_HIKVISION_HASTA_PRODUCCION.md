# Plan — Terminal Hikvision y correcciones de Tiempo, hasta producción y pruebas físicas

**Sistema de Control de Jornada · RTB-CRM-APP**
Estado al **8 de octubre de 2026**. Documento vivo (sin folio, mismo trato que
`PLAN_IMPLEMENTACION_TIEMPO.md`): se actualiza en cada sesión. Existe para que una conversación nueva
(o una persona nueva) pueda retomar sin haber leído el historial. Complementa
`bitacora/2026-10-05_checador_hikvision_auditoria_y_modelo.md` y
`bitacora/2026-10-07_sesion_terminal_hikvision_correcciones_y_paquete1.md`.

Convención de estados: **HECHO** · **EN CURSO** · **PENDIENTE (usuario)** = espera decisión o acción
del usuario · **PENDIENTE (equipo)** = trabajo delegable · **BLOQUEADO** = depende de otro ítem.

---

## 0. En una página

- El checador físico ya **no** es el sensor R503Pro (descartado). Es una **terminal Hikvision
  DS-K1A8503EF-B** (firmware V1.3.0), con el **Raspberry Pi 5 sin pantalla** como puente entre la terminal
  y el backend.
- **Nada del flujo de marcas reales está construido todavía del lado del Pi ni de las rutas de marcas del
  backend.** Lo que sí está: todo el modelo de datos de enrolamiento y de terminal en Supabase real
  (DDL `80_` a `87_`), la autenticación de la terminal y el latido en el backend (corte 1), y la pantalla
  de descarte/bloqueo de correcciones (backend + frontend, Paquete 1).
- Principio rector (decisión del usuario): **ninguna plantilla biométrica sale de la terminal**. La huella
  se enrola en el **menú del propio aparato**, con TI presente. El Pi y el backend sólo manejan
  `employee_no`, estado y *conteo* de huellas. El Pi **nunca** llama `CaptureFingerPrint`.
- Falta, en grueso: cortes 2 en adelante del backend de la terminal, el puente del Pi (repo
  `checador-fisico`), las pantallas de enrolamiento (Paquete 2: diseño entregado, sin implementar), el TLS y
  el despliegue, la configuración de la terminal (zona horaria, NTP, red), el alta de la primera llave, el
  aviso a RTB-App, y la **prueba física completa** (sección 6).

---

## 1. Qué está HECHO

### 1.1 Base de datos (Supabase real; todo aplicado y verificado)
| Archivo | Qué hace | Ensayo `BEGIN…ROLLBACK` |
|---|---|---|
| `80_tiempo_terminal_usuario.sql` | `tiempo.terminal`, `tiempo.terminal_usuario` (tabla viva, la escribe sólo el trigger), secuencia `seq_terminal_employee_no`, permisos `terminal_usuario_lectura` (heredable) y `terminal_usuario_edicion` (**no** heredable) | 61/61 (con 81) |
| `81_tiempo_bitacora_movimiento_terminal_usuario.sql` | Bitácora inmutable (fuente de verdad) + trigger de transiciones, `SCJ11`/`SCJ12` con `HINT` | 61/61 |
| `82_tiempo_terminal_credencial_y_estado.sql` | `tiempo.terminal_credencial` (hash SHA-256 de la llave `scjt_`), 4 columnas de estado en `terminal` | 230/230 (82-84) |
| `83_tiempo_terminal_rpc.sql` | RPC `SECURITY DEFINER`: `fn_terminal_autenticar`, `fn_terminal_mapa`, `fn_terminal_movimiento_registrar`, `fn_terminal_latido`, `fn_marca_terminal_registrar`, `fn_terminal_baja_por_persona_inactiva`; triggers `SCJ13` (no desactivar terminal con altas) y `SCJ14` (revocación irreversible) | 230/230 |
| `84_tiempo_marca_rechazada.sql` | `tiempo.marca_rechazada` + `fn_marca_rechazada_purgar` (única vía de borrado, retención 90 d) | 230/230 |
| `85_tiempo_terminal_baja_por_caducidad.sql` | `fn_terminal_baja_por_caducidad(p_horas=24)`: piso 4 h, tope 50 por corrida, re-lectura `FOR UPDATE` | 31/31 |
| `86_tiempo_excepcion_protege_dia_cerrado_v2.sql` | Cierra el hueco de `78_` (evadible): columnas inmutables en `tiempo.excepcion`, constraint trigger por prefijo que exige revisión del día **en la misma transacción** o un descarte registrado, `tiempo.excepcion_descarte`, permiso de acción `excepcion_dia_cerrado_descarte` (no heredable), RPC `fn_excepcion_dia_cerrado_descartar`, `SCJ15` | 100/100 |
| `87_tiempo_correccion_bloquea_marca_en_tramo.sql` | Trigger `BEFORE INSERT` en `tiempo.correccion`: `SCJ15`/`marca_en_tramo` si la marca es apertura/cierre de cualquier tramo | 47/47 |

Además se aplicó `78_` (a mano, sin ensayo) y se verificó que lo aplicado coincide con el archivo. Estado
real verificado tras `87_`: **34 tablas** (`tiempo` 23), **57 funciones**, **76 policies**, **52 permisos**,
`verificar_ddl.sql` completo con **0 filas** en todas las consultas de violaciones.
La terminal real está dada de alta (1 fila en `tiempo.terminal`, activa; la serie vive en la bóveda y **no
se versiona**). `terminal_usuario`, bitácora, `marca_rechazada`, `terminal_credencial` y `excepcion_descarte`
están **vacías**.

### 1.2 Documentos
`SCJ-DEC-11` V1.1 (mapeo en el servidor, Pi como caché), `SCJ-DEC-12` V2.0 (credencial de terminal, ruta de
marcas por RPC, requisitos de seguridad), `SCJ-CDT-01` V3.0 (la marca de terminal lleva `employee_no`),
`SCJ-ESP-01` V3.0, `SCJ-PRO-11` V3.0, `SCJ-PRO-15` V1.1 (proceso de enrolamiento), `SCJ-DIC-01` V1.3,
`SCJ-MOD-03` V1.8, `README.md`, `scripts/aplicar_ddl.sh`, `CLAUDE.md`, bitácoras del 5 y 7 de octubre.

### 1.3 Backend (`backend/`)
- **Corte 1 de `SCJ-DEC-12`:** `app/terminal_auth.py` (`get_terminal_actual`: HTTPS efectivo y falla cerrada,
  bloqueo por IP con "IPs buenas", formato `scjt_`, RPC de autenticación, 401 uniforme, 503 ante fallos de la
  base), `POST /api/terminal/latido`, `scripts/alta_credencial_terminal.py` (genera la llave, guarda sólo el
  hash, la muestra una vez; **no se ha ejecutado contra la base real**).
- **`SCJ15` y descarte:** mapeo de errores con mensajes fijos (`app/errores.py`),
  `POST /api/excepciones/{id}/descartar` (cliente del caller; la autorización real es la base),
  bloqueo con 409 de correcciones sobre marcas ya en un tramo o de día cerrado/revisado
  (`app/marca_en_tramo.py`), campos para la interfaz (`motivo_bloqueo_correccion`, `camino_resolucion`,
  `puede_descartar_excepciones`, `dia_de_la_marca_fecha`, `fecha_local`, `dia_id`, filtros
  `persona_id`/`dia_id` en `GET /api/dias`). **786 pruebas.**

### 1.4 Frontend (`frontend/`)
Paquete 1 implementado y revisado: Registro de marcas con "Corregir" bloqueado, Excepciones con pestañas y
modal de descarte, Días con resumen y filtros por URL. **603 pruebas.** Mockups aprobados en
`diseno_paginas/tiempo_excepciones_y_correcciones/`. **Nunca se ha visto corriendo en un navegador real
contra el backend** (sólo pruebas con mocks y los mockups HTML).

### 1.5 Commits relevantes (rama `main`, ya en el remoto)
`50cf34f` DDL 80/81 · `6760606` DEC-12 + CDT-01 V3.0 · `51e6b21` ESP-01/PRO-11 V3.0 + PRO-15 ·
`0756036` DDL 82-85 · `fb8e79b` docs enrolamiento en el menú · `afb23f5` backend corte 1 ·
`b6860cb` DDL 86 · `03385fd` backend SCJ15/descarte · `5749224` backend campos y filtros ·
`1c44213` DDL 87 · `429855e` frontend Paquete 1. (Este documento y la bitácora del 7 de octubre se
commitean después.)

---

## 2. Decisiones ya tomadas (no re-litigar sin motivo)

1. **R503Pro descartado.** Terminal Hikvision + Pi como puente sin pantalla.
2. **Mapeo `employee_no` ↔ `persona_id` en el servidor**; el Pi sólo lo cachea (SQLite local). El `persona_id`
   nunca sale del servidor hacia el Pi: el Pi manda `employee_no` en cada marca y el servidor resuelve.
3. **La huella se enrola en el menú del aparato** (opción B), TI con RH presente, TI custodia la contraseña
   admin; la credencial del Pi es distinta y vive sólo en su `.env` (permisos 600).
4. **El Pi accede por endpoints del backend con credencial propia** (llave opaca `scjt_`, hash en base), no
   con el secreto JWT de Supabase. Las marcas suben **por el backend** con RPC `SECURITY DEFINER` vía
   `service_role` (sin minteo de JWT; el backend no guarda `SUPABASE_JWT_SECRET`).
5. Una sola terminal por ahora (el diseño admite varias).
6. Marca de un `employee_no` sin alta (o con alta en `pendiente_alta`, o fuera de su vida útil ±1 h):
   **rechazada** y guardada en `tiempo.marca_rechazada`; no entra a `tiempo.marca`.
7. Permisos nuevos: `terminal_usuario_lectura` (heredable), `terminal_usuario_edicion` (**no** heredable,
   biometría), `excepcion_dia_cerrado_descarte` (**no** heredable). Auto-asignación prohibida (422) salvo el
   puesto administrador genérico ("Gerente o Encargado de TI").
8. Caducidad de altas en `esperando_huella`: **24 h** (ajustable), por `fn_terminal_baja_por_caducidad`.
9. Día cerrado: una marca tardía crea una excepción `dia_cerrado`; se resuelve **revisando el día** (misma
   transacción) o, si el día ya está `revisado`, **descartando** la marca con motivo y auditoría. Nada de
   `UPDATE` a mano.
10. **"Corregir" se bloquea** (opción A) para marcas ya en un tramo o de día cerrado/revisado, con mensaje
    claro; el respaldo está en la base (`87_`). Consecuencia: tras `cierre_dia` casi ninguna marca es
    corregible por esa vía (ver B1 en la sección 4).
11. HTTPS Pi↔backend **obligatorio** (requisito, no recomendación); la terminal sólo habla HTTP+Digest sin
    TLS, aceptado **sólo** con el tramo Pi↔terminal aislado (red punto a punto, servicios no usados apagados).
12. Mockups: copy en tuteo; excepciones como tabla con selector de tipo.

---

## 3. PENDIENTE (usuario): decisiones y acciones que sólo el usuario puede tomar

### 3.1 Preguntas abiertas de diseño (Paquete 2, enrolamiento)
Los mockups están en `diseno_paginas/tiempo_terminales_enrolamiento/` (8 HTML + README). Falta que el
usuario los revise (ver cómo servirlos en 7.4) y responda:

| # | Pregunta | Recomendación del equipo |
|---|---|---|
| D1 | **Navegación:** grupo propio "Terminales" en el sidebar (A) o dentro de "Parámetros" (B) | A, grupo propio |
| D2 | ¿Un **modal de asignar compartido** entre la pantalla de la terminal y la ficha de persona? | Sí, un solo componente |
| D3 | **¿Quién ve el tablero de anomalías?** (RH, TI, Gerente General… o sólo TI) | Quien tenga `terminal_usuario_lectura`; confirmar |
| D4 | **Leyenda de consentimiento biométrico:** el texto del mockup es propuesta; el aviso real lo define RH/Legal | Que RH/Legal entregue el texto |
| D5 | **Mínimo de huellas** para pasar a `activo` | 1 (como está en el trigger) |
| D6 | ¿**Avisar a TI** cuando hay un alta en `esperando_huella`? (canal y umbral) | Sí, definir canal (correo/tablero) |

### 3.2 Decisiones de producto y de despliegue
| # | Tema | Detalle / recomendación |
|---|---|---|
| D7 | **Opción B: RPC de corrección de días cerrados** | Hoy no existe forma de corregir la hora de una marca ya incluida en un tramo. Diseño propuesto: RPC `SECURITY DEFINER` con el control dentro, que corrija la marca, actualice el tramo, recalcule `dia.horas_totales` **sólo en días `cerrado`** (respetando el descuento de pausa) y **no pise las horas manuales de RH** en días `revisado`. Decidir cuándo (recomendación: después de lo urgente de terminal). |
| D8 | **Aviso de privacidad y consentimiento biométrico (LFPDPPP)** | Lo provee RH/Legal fuera del repo. Decidir dónde queda el registro del consentimiento (hoy: documento firmado en el expediente + casilla en la pantalla; si Legal exige evidencia verificable —folio, fecha, archivo— requiere diseño nuevo y cruza `SCJ-FRO-01`). |
| D9 | **HTTPS Certificates en Tailscale** | Habilitar en la consola de Tailscale (sin esto `tailscale cert` falla). Alternativa: CA interna con pinning (plan B). |
| D10 | **Aceptar que el nombre del nodo quede en los registros públicos de transparencia de certificados** (`raspberrypi-serverpruebas…ts.net`) | O elegir el plan B. |
| D11 | **`sudo` en el Pi de pruebas** para `/opt/scj/tls`, timer de renovación y recarga de nginx | Autorización explícita. |
| D12 | **ACL del tailnet** | Limitar el checador a `443` hacia el Pi de pruebas (recomendado, hoy probablemente todo permitido). |
| D13 | **`tailscale ssh dhguilleng@checador`** | Probablemente ya **no hace falta** (la sesión interna "Cheador" lee el Pi); sólo si `devops` debe ejecutar él mismo los pasos de red. Sin autorización explícita nadie lo usa. |
| D14 | **Escrituras en la terminal** (cada una pide OK explícito al ejecutarse; ver 4.6) | Zona horaria `CST+6:00:00`, NTP al Pi, IP fija / red punto a punto, borrar el usuario de prueba (el usuario debe **confirmar por escrito cuál `employeeNo`**, es irreversible), endurecimiento opcional. |
| D15 | **Credenciales de la Hikvision** (`HIK_USER`/`HIK_PASS`) | Sólo en variable de entorno de la sesión que las use; nunca en chat ni repo. La sesión del Pi las tiene. |
| D16 | **Quién tendrá la contraseña admin del aparato** | Decidido: TI. Falta nombrar a la persona/rol y el procedimiento de rotación. |
| D17 | **Aviso a RTB-App** del esquema nuevo | El esquema está congelado desde el 25-sep-2026: tablas (`terminal`, `terminal_usuario`, bitácora, `terminal_credencial`, `marca_rechazada`, `excepcion_descarte`), permisos, funciones y el cambio de contrato `SCJ-CDT-01` V3.0. **Es acción del usuario**, fuera de las sesiones. |
| D18 | **`SCJ-MOD-02` línea 59** | Dice que `marca.persona_id` viene "ya resuelto por el terminal"; ahora lo resuelve el servidor. El usuario dijo que lo corrigió pero **no aparece cambio en este repo**: confirmar dónde lo editó. |
| D19 | **Sincronización con el repo académico `sistema-control-jornada`** | El académico no tiene los DDL `76_` a `87_` ni el código nuevo (ver memoria `project-rtb-crm-app-real-vs-academico`). Decidir si se sincroniza y por quién (sesión `Sincronizador-proyecto-academico`). |
| D20 | **¿Versionar los ensayos SQL?** | Se copiaron a `db/ensayos/` (ver 7.5). Confirmar que se quedan en el repo. |

### 3.3 Preguntas abiertas de proceso (`SCJ-PRO-15` V1.1)
P4 (banderas de sesión: `puede_ver/editar_terminales`; `puede_descartar_excepciones` ya existe), P5 (mínimo de
huellas = D5), P6 (¿el consentimiento exige DDL?), P7 (¿el aviso de privacidad ya existe y cubre
biometría?), P8 (quién firma la lista de servicios de la terminal y cada cuánto). Preguntas Q15-Q18 de
`SCJ-DEC-12` §12.8: Q15 (usuario no-admin en el firmware: la sesión del Pi lo está verificando), Q16 (N=24 h,
resuelta), Q17 (función de caducidad: resuelta con `85_`), Q18 (conteo de huellas sin `fingerData`: ver
4.4, T-PI-5).

### 3.4 Revisión visual pendiente
- Confirmar en la tablet que el mockup 04 corregido ya no tiene la sección "muy junta/encimada" (se midió por
  DOM a 1920 px: sin solapamientos; **no** se probó el ancho de tablet).
- Probar el Paquete 1 **corriendo** (no mockup) cuando esté desplegado en el Pi de pruebas.

---

## 4. PENDIENTE (equipo): trabajo técnico hasta producción

Dueños sugeridos entre corchetes. Dependencias con `←`.

### 4.1 Base de datos [`db`]
- (Nada estructural abierto.) Documentar en `SCJ-DIC-01`/`SCJ-MOD-03` cualquier cambio de los cortes
  siguientes. Mantener `verificar_ddl.sql` al día (0 filas) tras cada migración.
- **B1 (opción B)** si se aprueba D7: nuevo DDL (`88_`+) con ensayo y revisión de `security`.
- Residual **B2** de `86_`: `dia_update_revision` deja pasar un día a `revisado` por PostgREST sin armar
  tramos; quien tenga ese permiso y el de descarte puede revisar y descartar (auditado). Endurecer
  `tiempo.dia` con un constraint trigger diferido cuando toque.
- Residual del dueño: `DROP`/`DISABLE TRIGGER` de las bitácoras inmutables y de `marca_rechazada`.
- Revisar `ensayo_78.sql` (nunca corrido; obsoleto tras `86_`).

### 4.2 Backend [`backend`] — cortes 2+ de `SCJ-DEC-12` §8.3
Todos con TDD y mocks (**nunca contra la base real**), revisión de `security` y `testing`.
- **T-BE-2 Ruta de marcas:** `POST /api/terminal/marcas` (lote ≤ 200, confirmación por marca,
  idempotente por `evento_id`) que llama `fn_marca_terminal_registrar` con `service_role`; mapeo de
  `SCJ11`/`SCJ12` y de los códigos de resultado de `SCJ-CDT-01` §IX.6; 503 ante fallos de la base.
- **T-BE-3 Lado terminal:** `GET /api/terminal/cola`, `GET /api/terminal/mapa`,
  `POST /api/terminal/movimientos` (`usuario_creado`, `huella_capturada`, `baja_confirmada`, `error`),
  siempre filtrando por la terminal de la credencial (`fn_terminal_*` con `p_terminal_id`).
- **T-BE-4 Endpoints web de terminales** (`routers/terminales.py`, cliente del caller + `requiere_permiso` +
  RLS): asignar (con `consentimiento: true` en el cuerpo —ver D8—), solicitar baja, listar con estado,
  historial de un alta, altas por persona (para la ficha), tablero de anomalías (9 categorías; definir la
  forma de cada bloque y qué devuelven las categorías 5 y 6 sin fuente), `caduca_en` por alta,
  `error_detalle` saneado, personas asignables filtradas, `estado_contacto` calculado al leer
  (latido 60 s, umbral 5 min por variable de entorno).
  Mapeo de errores `SCJ11` (409 transición inválida), `SCJ12` por hint (`alta_duplicada` 409,
  `persona_no_activa` 422, `terminal_no_valida` 422), `23503` (persona sin fila en `tiempo.persona`) 422,
  `23505` carrera 409, `42501` 403; sin retransmitir texto crudo; auto-asignación prohibida con 422 salvo
  admin genérico.
- **T-BE-5 Banderas de sesión:** `puede_ver_terminales` y `puede_editar_terminales` en `/api/sesion`.
- **T-BE-6 Hook de baja por persona inactiva:** sincrónico en `routers/movimientos.py` (al suspender/dar de
  baja) llamando `fn_terminal_baja_por_persona_inactiva`; `201` con `advertencias:["baja_terminal_pendiente"]`
  si falla; **job idempotente** (≈10 min) en `backend/app/scheduler.py` como respaldo; tratar `-1`
  (persona no activa sin autor derivable) como alerta, no reintentar en bucle.
- **T-BE-7 Jobs del scheduler:** caducidad (`fn_terminal_baja_por_caducidad`, 24 h, tope 50), purga de
  `marca_rechazada` (`fn_marca_rechazada_purgar`, 90 d). Un solo worker (el scheduler embebido lo exige).
- **T-BE-8 Monitoreo/alarmas:** tablero de anomalías de marcas (fuera de rango, persona sin alta, rechazos
  definitivos por hora, huecos de secuencia) y alerta si la terminal/Pi dejan de reportar. No hay canal de
  alerta saliente todavía (D6).
- **T-BE-9 Endurecimiento pendiente:** limitador por proceso (N×workers), `SecretStr` para
  `supabase_service_role_key`, advertencia de arranque que lea también el `.env`, JSON mal formado sin
  credencial da 422 (aceptado).
- **T-BE-10 Verificar el error diferido `SCJ15`** (llega al `COMMIT`) con una petición real que falle (p. ej.
  una corrección sobre una marca `dia_cerrado` de datos de prueba aborta sin residuo); hoy sólo está probado
  con mocks. Si llegara con otro código el comportamiento es seguro (422/409 fijo), sólo se pierde el
  mensaje específico.
- **T-BE-11 Opción B** si se aprueba D7 (endpoint que llame al RPC).

### 4.3 Frontend [`frontend`]
- **T-FE-1** Esperar respuestas D1-D6 y los contratos de T-BE-4/5, **luego implementar el Paquete 2**
  (8 pantallas: terminales, usuarios de la terminal, modales asignar/baja, historial, anomalías, sección en
  la ficha de persona, aviso al suspender —`CambiarEstadoPage` hoy redirige con el `201` y perdería la
  advertencia—, navegación). Sin botón "Capturar"; estados `pendiente_alta`/`esperando_huella`
  (cuenta regresiva a 24 h)/`activo`/`pendiente_baja`/`baja`; casilla obligatoria de consentimiento.
- **T-FE-2** Habilitar una verificación visual real: Playwright no encuentra Chrome en esta máquina. La
  extensión de Chrome sí funciona (se usó para medir el mockup 04). Prueba E2E de foco/teclado con la API
  interceptada (nunca contra la base real).
- **T-FE-3** Mensaje de la interfaz para el caso "tras el cierre casi nada se corrige por aquí" (ya está en
  el Paquete 1) y, si se aprueba D7, la pantalla de la opción B.

### 4.4 Puente del Pi [repo `/home/diego/Proyectos/checador-fisico`; hoy es la versión básica con el R503Pro simulado]
Diseño en `SCJ-DEC-12` §7, §8.1, §12 y `SCJ-PRO-15`. Cambios previstos de ese repo:
- **T-PI-1 Credencial y transporte:** reemplazar `jwt_terminal.py` (firma con el secreto de Supabase) por la
  llave `scjt_` en `Authorization: Bearer`; hablar sólo con los endpoints del backend por HTTPS; eliminar
  `routers/personas.py` con `service_role` temporal.
- **T-PI-2 Cliente ISAPI (Digest) de la terminal, sólo lectura de plantillas:** **prohibido**
  `CaptureFingerPrint` y todo endpoint que devuelva `fingerData`; el Pi lee sólo conteos. Crear/borrar
  usuarios (`UserInfo`), contar huellas (`T-PI-5`), consultar `AcsEvent`, `System/time`.
- **T-PI-3 Ingesta de eventos:** polling de `AcsEvent` con **cursor** (`estado_puente`) y push por
  `httpHosts` (vacío hoy; el listener restringido a la red punto a punto), ambos idempotentes;
  `evento_id` **determinista** (UUIDv5 de terminal + serie + `serialNo`); `secuencia_local` propia sólo sobre
  marcas aceptadas; vigilar continuidad de `serialNo`; ventana de supresión de 60 s contra doble marca;
  descartar a `evento_descartado` (local) los intentos denegados/desconocidos.
- **T-PI-4 Subida y resiliencia:** outbox SQLite; reintentos 5 s / 15 s / 1 min / 5 min (tope 15 min);
  clasificación transitorio/definitivo por código; ante `secuencia_duplicada` con `evento_id` nuevo
  **renumerar** con `ultima_secuencia_recibida`+1 y reenviar con el **mismo** `evento_id`; tope de 50
  reintentos o 24 h antes de `pendiente_intervencion`; sin estado en memoria que se pierda al reiniciar.
- **T-PI-5 Cola de trabajo y enrolamiento:** leer `cola`/`mapa`; crear el usuario con su `employeeNo`;
  reportar `usuario_creado`; **sondear el conteo de huellas** cada 5–10 s sólo mientras el alta está en
  `esperando_huella` (ventana abierta, sin timeout de 20 s); reportar `huella_capturada(n)`; en baja,
  borrar el usuario y confirmar (tratar "no existe" como éxito); ante `409` releer la cola.
  *Pregunta abierta Q18:* confirmar el campo de conteo de huellas por usuario sin traer `fingerData`
  (la sesión del Pi lo está investigando; si sólo existe una consulta que trae datos, descartar el cuerpo
  en el parser sin materializar `fingerData`).
- **T-PI-6 Reconciliación (M8):** comparar usuarios de la terminal contra `mapa`; borrar huérfanos y altas
  hechas a mano en el menú, reportando `error`/`usuario_no_mapeado`. **Error de procedimiento a evitar:**
  enrolar en el menú *antes* de que el servidor asigne y el Pi cree el usuario hará que la reconciliación
  lo borre. Orden correcto: asignar en la web → esperar `usuario_creado` → enrolar.
- **T-PI-7 Reloj:** `estado_reloj` (`sincronizado`/`deriva`/`sin_sincronizar`) comparando la hora de la
  terminal con la del Pi; el Pi usa `chrony` (hoy **no está instalado**) y sirve NTP a la terminal.
- **T-PI-8 Latido** cada 60 s (`POST /api/terminal/latido`) con alcanzabilidad, desfase, versión, marcas
  pendientes; guardar `ultima_secuencia_recibida`.
- **T-PI-9 Operación:** servicio `systemd` sin pantalla; contraseña Hikvision y llave `scjt_` en `.env` 600
  fuera del repo; logs sin secretos ni cuerpos ISAPI; el Pi **no** se conecta a otra red con credencial
  admin de la terminal; usuario ISAPI **no-admin** de mínimo privilegio si el firmware lo permite (Q15) o
  aceptar y firmar el residual (un Pi comprometido con admin podría leer plantillas).
- **T-PI-10 SQLite local** (cambia junto con el código, no antes): `persona_cache` →
  `employee_no PK, persona_id, estado, actualizado_en`; `marca` con `terminal_id`, `secuencia_local`,
  `serial_evento`, `desfase_local`, `estado_reloj` (3 valores), `version_software`, `UNIQUE (terminal_id,
  serial_evento)`; `estado_puente` (cursor); `evento_descartado`. Retirar la pestaña "Marcar" y el
  `LectorStub`; conservar Historial/Config como diagnóstico.
- **T-PI-11 Pruebas:** simulador de la terminal ISAPI (Digest) para pruebas automáticas; CI/grep que falle
  si aparece `fingerData` en el repo del Pi o del backend.
- **T-PI-12 Acceso al Pi checador:** no hay `authorized_keys`; se entra por Tailscale SSH
  (`tailscale ssh dhguilleng@checador`, usuario `dhguilleng`) o agregando una llave pública (acciones del
  usuario, ver D13). El Pi 5 sin RTC con batería depende de NTP al arrancar.

### 4.5 Seguridad [`security`]
- Revisar cada corte (T-BE-2..11, puente, frontend P2) antes de commitear, como se hizo hasta hoy.
- Revisión **final previa a producción** de: TLS/proxy, ACL del tailnet, rotación de la llave (cada 12
  meses, con traslape), custodia de contraseñas, lista de servicios de la terminal firmada por TI,
  procedimiento de decomisión (borrar usuarios y reset de fábrica).
- Pruebas de abuso reales sobre el despliegue (límite de peticiones, tamaño de cuerpo, backoff por IP).

### 4.6 Despliegue y configuración [`devops`] — todas son **escrituras que piden OK explícito del usuario**
- **T-DV-1 TLS** (`SCJ-DEC-12` Q11): `nginx` en contenedor (`terminal-proxy`) que termina TLS con el
  certificado de `tailscale cert`, publicado **sólo** en la IP tailnet del Pi de pruebas, que expone
  **únicamente** `/api/terminal/` (todo lo demás 404), `limit_req` ≈5 r/s burst 20,
  `client_max_body_size 256k`, `allow` sólo la IP tailnet del checador, `log_format` sin
  `$http_authorization`, HSTS; el proxy **sobrescribe** `X-Forwarded-Proto` y añade al final de
  `X-Forwarded-For`; `FORWARDED_ALLOW_IPS` nunca `*`; `TERMINAL_PROXIES_CONFIANZA` con la IP real del
  proxy; el puerto 8000 no se publica hacia fuera si hay proxy; timer semanal de `tailscale cert` +
  recarga de nginx. Archivos previstos: `deploy/nginx/terminal.conf`, `docker-compose.prod.yml`,
  `backend/Dockerfile`, `backend/app/config.py`, `.env.example`, `scripts/desplegar.sh`, runbook.
  *Requiere D9, D10, D11, D12.* El Pi checador resuelve MagicDNS (verificado) y su
  `BACKEND_URL` usaría `https://<nombre-magicdns-del-pi-de-pruebas>`.
- **T-DV-2 Configuración de la terminal** (orden recomendado; cada paso con su `GET` previo, verificación
  y reversión; máx. 2–3 intentos de contraseña por el bloqueo por IP del equipo):
  0. Respaldo de línea base (sólo `GET`, guardado fuera del repo, permisos 600).
  1. **Zona horaria:** hoy `CST-8:00` (China) en modo manual y **sin NTP**; el reloj de pared ya marca la
     hora local de México. Cambiar **sólo `timeZone`** a `CST+6:00:00` conservando la hora local
     (`PUT /ISAPI/System/time` con el XML completo leído por `GET`); verificar que el offset de los
     `AcsEvent` sea `-06:00`. Riesgo: el firmware podría guardar un instante UTC interno y desplazar la hora
     14 h; si salta, un `PUT` adicional de `localTime` (aprobación aparte). Lo más robusto es hacerlo junto
     con NTP.
  2. **Red punto a punto** `192.168.50.0/30` entre el `eth0` del Pi (hoy sin cable, libre; `192.168.50.1`) y
     la terminal (`192.168.50.2`, sin gateway ni DNS): perfil NetworkManager `eth0` manual y
     `ipv4.never-default yes`; `PUT /ISAPI/System/Network/interfaces/1` a estático **con el cable aún en
     la LAN** (hoy la terminal está en la LAN por switch/AP y el Pi la alcanza por WiFi); luego el usuario
     mueve el cable al `eth0` del Pi. `wlan0` y el tailnet no se tocan (son la salida del Pi). Recuperación:
     SADP (desde una PC con Windows en la misma capa 2) o el menú físico de la terminal; reset de fábrica
     sólo como último recurso (borra los usuarios).
  3. **NTP:** instalar `chrony` en el Pi (hoy `systemd-timesyncd`; confirmar con `apt -s` que lo reemplaza),
     `makestep 1 3`, `allow 192.168.50.0/30`, **sin** `local stratum 10 orphan`; `chronyc tracking`
     sincronizado **antes** de apuntar la terminal; luego `PUT /ISAPI/System/time/ntpServers/1` al Pi y
     `timeMode=NTP` con la zona. Firewall: `udp/123` sólo por `eth0`.
  4. **Limpieza del usuario de prueba:** hoy hay 1 usuario registrado; el usuario **confirma por escrito su
     `employeeNo`** antes de `DELETE` (irreversible: no hay plantilla exportada ni se exportará).
  5. **Endurecimiento opcional:** apagar servicios no usados (Hik-Connect/EZVIZ, UPnP, SNMP, ONVIF,
     SSH/Telnet), cambiar la contraseña por defecto si aplica, bloqueo por intentos fallidos; confirmar si
     HTTPS es posible (hoy 443 cerrado; el puerto SDK 8000 está abierto).
- **T-DV-3 Despliegue en el Pi de pruebas** (`raspberrypi-serverpruebas`): ver
  `reference_ssh_pi_deploy` (memoria) y `README.md`: `git pull origin main`, `./scripts/desplegar.sh prod
  reconstruir` y `levantar`; las `VITE_*` del frontend son de **build**. Verificar salud
  (`/salud`, frontend). El puerto 8080 puede estar compartido con contenedores ajenos del Pi.
  Los DDL ya están aplicados en Supabase (no hay migración en el despliegue).
- **T-DV-4 Alta de la primera llave** por el script de TI en el servidor (la llave se muestra una vez, no se
  guarda ni queda en historial) y configuración en el Pi checador (`.env` 600).
- **T-DV-5 Servicio del puente** en el Pi checador (`systemd`), arranque tras `tailscaled`, `eth0` y
  `chrony`; reinicio controlado del Pi para comprobar que todo vuelve solo.
- **T-DV-6 Incidente sin resolver del Pi 5** (25-sep): se apagó solo al conectar el R503Pro al riel de 3.3 V
  del GPIO. Con la Hikvision (alimentación propia) no aplica, pero **no se confirmó que el Pi quedó sano**:
  revisar `vcgencmd get_throttled` y `journalctl -k | grep -i under-voltage` antes de la prueba física.

---

## 5. Secuencia recomendada hasta el deploy final

1. **Decisiones rápidas del usuario:** D1-D6 (mockups P2), D8-D13, D14 (autorizaciones de escritura),
   D16, D17, D18.
2. **Backend T-BE-2/3** (ruta de marcas y lado terminal): son lo mínimo para una prueba de punta a punta.
   Revisión de `security` + `testing`. Commit. ← DDL ya aplicado.
3. **TLS y despliegue** (T-DV-1/3) en el Pi de pruebas, con el backend de (2).
4. **Configuración de la terminal** (T-DV-2: zona, red punto a punto, NTP, limpiar usuario de prueba). ← D14.
5. **Puente del Pi** (T-PI-1…12) contra el backend desplegado, con el simulador ISAPI primero y la terminal
   real después.
6. **Endpoints web y pantallas de enrolamiento** (T-BE-4/5/6/7/8, T-FE-1). ← D1-D6 y contratos.
7. **Alta de la llave** (T-DV-4) + servicio del Pi (T-DV-5).
8. **Prueba física** (sección 6). Corregir lo que salga.
9. **Revisión final de seguridad** (4.5), actualización de `CLAUDE.md` y bitácora, aviso a RTB-App (D17).
10. Decidir y construir la **opción B** (D7) y las mejoras diferidas (alertas salientes, etc.).

---

## 6. Plan de pruebas físicas con la terminal (registrar una huella y marcar)

**Prerrequisitos (todos verificados antes de empezar; marcar cada uno):**
- [ ] Pi checador encendido y en el tailnet; `vcgencmd get_throttled` sin subvoltaje.
- [ ] Terminal activada; zona `CST+6:00:00`, NTP al Pi con `chronyc tracking` sincronizado; hora de la
      terminal ≈ hora del Pi (±2 s); offset de eventos `-06:00`.
- [ ] Red punto a punto activa (Pi `192.168.50.1` ↔ terminal `192.168.50.2`), terminal sin ruta hacia LAN.
- [ ] Backend desplegado con TLS; `curl` desde el Pi a `/api/terminal/latido` responde por HTTPS;
      HTTP y `X-Forwarded-Proto` falsificado son rechazados.
- [ ] Llave `scjt_` creada, `terminal` activa, latido llegando (`ultimo_contacto_en` se actualiza).
- [ ] Usuario de prueba de la terminal borrado (con confirmación escrita) y `terminal_usuario` vacío.
- [ ] Una **persona de prueba** activa en `personas.persona` con su fila en `tiempo.persona` y jornada
      asignada; consentimiento firmado (D8). Identificar quién opera (TI + RH presentes) y quién tiene la
      contraseña admin.

**Casos (anotar resultado, hora y evidencia; no incluir plantillas ni credenciales):**
1. **Alta y enrolamiento:** RH asigna la persona en la web → `pendiente_alta` con `employee_no` → el Pi crea
   el usuario (`usuario_creado`, `esperando_huella`) → TI enrola la huella en el menú del aparato → el Pi
   detecta el conteo ≥ 1 → `huella_capturada` → `activo`. Verificar bitácora completa y el estado en la web.
2. **Primera marca (entrada):** la persona pone el dedo → evento `AcsEvent` → el Pi lo sube → `tiempo.marca`
   con `origen='terminal'`, `momento_dispositivo` y `desfase_local = -06:00` correctos, `estado_reloj =
   sincronizado`, `requiere_revision = false`; aparece en Registro de marcas.
3. **Segunda marca (salida):** paridad correcta; tras el cierre de día se arma el tramo con las horas
   esperadas. Marca impar al cierre → día `bloqueado` y excepción de día (flujo de revisión).
4. **Doble lectura** del mismo dedo en < 60 s: una sola marca (ventana de supresión).
5. **Idempotencia:** reenviar un lote ya subido → `duplicado`, sin filas nuevas; mismo `evento_id` con
   contenido distinto → `conflicto_evento` (rechazo definitivo, queda en `marca_rechazada`).
6. **Pi apagado 10 min:** la terminal retiene eventos; al volver, el polling los recupera sin pérdidas ni
   duplicados.
7. **Backend caído:** el Pi acumula en el outbox y reintenta con la espera creciente; al volver sube todo y
   `marcas_pendientes` vuelve a 0.
8. **Reinstalación del Pi** (secuencia vuelve a 1): renumera con `ultima_secuencia_recibida`+1 y reenvía con
   el mismo `evento_id`; ninguna marca se pierde.
9. **Reloj:** forzar deriva > 5 min en la terminal → las marcas llegan con `estado_reloj = deriva` y se
   señalan; restablecer NTP.
10. **Usuario huérfano:** crear a mano un usuario en el menú sin alta → la reconciliación lo detecta y lo
    borra, reportando `usuario_no_mapeado`.
11. **Persona suspendida:** suspender a la persona de prueba → `baja_solicitada` automática → el Pi borra el
    usuario → `baja_confirmada`; una marca posterior queda como `no_enrolado` (rechazada) o señalada.
12. **Caducidad:** dejar un alta en `esperando_huella` > 24 h (o ajustar el parámetro en el ensayo) → baja
    automática; reasignar produce otro `employee_no`.
13. **Seguridad:** llave revocada → 401 y el Pi lo registra; terminal desactivada con altas vigentes →
    `SCJ13`; intento de `CaptureFingerPrint` desde el código del Pi → inexistente (grep/CI);
    tráfico Pi↔backend sólo HTTPS; desde otra IP del tailnet el proxy responde 403.
14. **Corrección y cierre de día con marcas reales:** día `cerrado` con una marca tardía → excepción
    `dia_cerrado` → "Revisar día" o "Descartar" según el estado; "Corregir" bloqueado con el mensaje fijo;
    `SCJ15` si se intenta por PostgREST directo.
15. **Decomisión (simulada):** dar de baja todas las altas, esperar `baja_confirmada`, desactivar la terminal
    (`SCJ13` no debe saltar), reset de fábrica de la terminal y comprobar que no queda ninguna huella.

**Criterio de aceptación:** los casos 1–8, 11 y 13 pasan sin intervención manual fuera del enrolamiento; los
9, 10, 12, 14 y 15 pasan con los resultados descritos; ninguna plantilla biométrica aparece en logs, base,
colas ni respaldos; ningún secreto en logs ni repo.

---

## 7. Operación y entorno (para retomar sin contexto)

### 7.1 Equipo de sesiones (`team-orchestrator`)
Roster fijo de sesiones persistentes: `backend`, `frontend`, `db`, `testing`, `security`, `devops`; esta
sesión es `orchestrator`. **Nunca** `Agent()` para trabajo de dominio. Cada sesión pide **su propia**
confirmación al usuario para escribir contra la base real (el OK dado al orquestador no la sustituye). Además
existe la sesión remota **"Cheador"** (Remote Control) que corre **dentro del Pi checador**; sirve para
lecturas ISAPI y de red; no avisa al terminar y no confirma recepción. Hay muchas sesiones remotas antiguas
(offline) con los mismos nombres: usar siempre la referencia de la sesión local viva.

### 7.2 Reglas que se respetaron (mantenerlas)
- Ninguna sesión corre escrituras/RPC contra la base real fuera de una migración versionada **con OK
  explícito del usuario**; los ensayos son `BEGIN…ROLLBACK` por conexión directa (puerto 5432, sin `-1`,
  `ON_ERROR_STOP`, `SET LOCAL` de timeouts), con personas sintéticas.
- `psql` de escritura lo bloquea el clasificador de permisos: **el usuario pega los DDL en el SQL Editor de
  Supabase**, cada archivo completo en una ejecución, en orden. Copiar con rutas **absolutas**:
  `! wl-copy < /home/diego/Proyectos/RTB-CRM-APP/db/ddl/NN_archivo.sql`.
- Tras aplicar: `verificar_ddl.sql` completo en **sólo lectura** (`default_transaction_read_only=on`),
  0 filas en las consultas de violaciones.
- Flujo por corte: escribir → `security` revisa → ensayo con OK → el usuario aplica → `db` verifica →
  documentar → commit. Los commits los hace el orquestador tras revisar; el push sólo con OK del usuario
  (o rutina ya autorizada).
- No versionar: serie de la terminal, IPs privadas, MACs, credenciales, llaves `scjt_`, plantillas. Los
  documentos con folio `RTB-` no entran al repo.

### 7.3 Artefactos fuera del repo (pueden perderse)
- Scratchpad de la sesión `db`: `/tmp/claude-1000/-home-diego-Proyectos-RTB-CRM-APP/8b0fd01a-ecb8-4443-9f80-493da181aabc/scratchpad/`
  (ensayos y salidas). **Copiados al repo** en `db/ensayos/` (7.5).
- Material de `testing` (mutantes): scratchpad de la sesión `testing`; no es necesario conservarlo.

### 7.4 Ver los mockups por tailnet
Un servidor estático (copia sólo de los mockups y `tokens.css`, **no** el repo) corre en esta máquina:
`http://<ip-tailscale-de-esta-máquina>:8099/diseno_paginas/<carpeta>/<archivo>.html`, escuchando **sólo** en la IP de
Tailscale. Carpetas: `tiempo_excepciones_y_correcciones/` (Paquete 1, aprobado e implementado) y
`tiempo_terminales_enrolamiento/` (Paquete 2, borrador). Detener: `pkill -f "http.server 8099"`. Si se
reinició la máquina, volver a servir: copiar `diseno_paginas/<carpeta>` y `frontend/src/styles/tokens.css`
a un directorio temporal con la misma estructura y correr `uv run --no-project python -m http.server 8099
--bind <ip-tailscale> --directory <dir>`. La copia no se actualiza sola.

### 7.5 Ensayos versionados
`db/ensayos/*.sql` conserva los ensayos `BEGIN…ROLLBACK` de cada migración (`80_81`, `82_84`, `85`, `86`,
`87`, corrección de tramos, `78` obsoleto) y sus consultas de verificación auxiliares. Las rutas `\ir` apuntan
a rutas absolutas del scratchpad original y del repo; ajustarlas antes de reutilizarlos. Cada uno exige OK
explícito del usuario antes de correrse contra Supabase.

### 7.6 Referencias
`SCJ-DEC-11`, `SCJ-DEC-12`, `SCJ-CDT-01` V3.0, `SCJ-PRO-11` V3.0, `SCJ-PRO-15` V1.1, `SCJ-ESP-01` V3.0,
`SCJ-DIC-01` V1.3, `SCJ-MOD-03` V1.8; bitácoras `2026-10-05_*` y `2026-10-07_*`; `CLAUDE.md`
(entradas del 5-7 de octubre); `diseno_paginas/tiempo_terminales_enrolamiento/README.md` (pedidos al
contrato del Paquete 2); memorias del proyecto (`project-checador-hikvision-estado-2026-10-08`,
`reference-ssh-pi-deploy`).

---

## 8. Riesgos y residuales aceptados (para que nadie los redescubra)

- **HTTP + Digest sin TLS** en el tramo Pi↔terminal (la terminal no soporta HTTPS): aceptado sólo con el
  tramo aislado.
- **Un Pi comprometido con credencial admin** podría leer plantillas por ISAPI (`FingerPrintCfg`) o disparar
  una captura (requiere una persona frente al lector): mitigar con usuario de dispositivo no-admin si el
  firmware lo permite; si no, firmar el residual.
- **El dueño de la base puede `DROP`/`DISABLE TRIGGER`** de las bitácoras inmutables y de `marca_rechazada`.
- **Quien tenga `terminal_usuario_edicion` puede enrolar a cualquier persona activa** sin doble aprobación
  (auditado en la bitácora; prohibida la auto-asignación salvo el administrador genérico).
- **Marcas falsas con la llave válida:** limitadas por `estado_reloj` degradado, rechazo de valores absurdos,
  topes por hora y revisión; no hay forma de distinguirlas de las legítimas dentro de la vida de una alta.
- **Limitador de intentos por proceso** (un solo worker en producción) y bloqueo por IP que puede afectar al
  Pi si otro host comparte su IP (mitigado con la lista de IPs buenas).
- **`dia_update_revision` (B2)** y la carrera al armar el tramo en otra transacción.
- **Tras `cierre_dia` casi ninguna marca es corregible** hasta la opción B (D7); las horas manuales de RH
  podrían divergir del tramo y nadie lo ve (ya divergen por diseño en algunos días).
- **Desactivar una terminal con altas** lo impide `SCJ13`; el procedimiento correcto es dar de baja todas las
  altas, esperar `baja_confirmada` y `marcas_pendientes = 0`, desactivar y hacer reset de fábrica.
- **Esquema congelado desde el 25-sep-2026:** todo lo anterior exige aviso a RTB-App (D17).
