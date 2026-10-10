# 2026-10-10 · SCJ-PRO-15 — Verificación de la terminal Hikvision con el usuario (checklist A→H)

**Participantes:** el usuario (frente al aparato y custodio de la contraseña de administrador), la sesión `Checador` (corre en el Pi del puente, 192.168.10.50), `orchestrator`.
**Terminal:** DS-K1A8503EF-B, firmware V1.3.0, 192.168.10.130. Banco de pruebas.
**Checklist seguido:** `docs/07-procesos/CHECKLIST_TI_VERIFICACION_TERMINAL.md`.

---

## Qué se hizo

Se recorrieron los bloques A a H del checklist con un usuario sintético (número 900001, nombre `U900001`), con confirmación del usuario antes de cada escritura y sin imprimir secretos. Se creó y se borró el usuario sintético, se enroló una huella en el menú del aparato, se hicieron marcajes válidos y denegados, y se corrigió la zona horaria.

## Resultados

| Bloque | Resultado |
|---|---|
| A — Salida de puerta | No está conectada a chapa ni cerradura real (banco de pruebas): no hubo riesgo de abrir nada. **Pendiente de decidir para producción:** si la salida de la terminal controlará una puerta real. |
| B — Usuarios, PIN, modos, tarjetas | 1 usuario real (tipo normal). Modo de verificación global: solo huella. 0 tarjetas. El firmware enmascara la contraseña; con modo solo huella no hay PIN. Sin rostro. |
| C — Alta del usuario sintético | **El cuerpo mínimo (`employeeNo`, `name`, `userType`) es RECHAZADO**: HTTP 400, `subStatusCode = MessageParametersLack`. V1.3.0 exige `Valid`, `doorRight` y `RightPlan`. Con el cuerpo completo se acepta. Valores por omisión: `Valid.enable = true`, vigencia de 2026 a 2037 (hora local), `doorRight = 1`, `RightPlan` puerta 1 plantilla 1, `userVerifyMode` vacío (hereda el modo global), tiempos de apertura 0. Con esos valores el usuario **sí podría marcar**: está habilitado, vigente, con derecho y plan. |
| D — Evento de alta de huella | Sí genera un evento, pero de operación (`major = 3`), no de acceso: `minor 80` = alta de usuario, `minor 81` = enrolamiento de huella. No traen número de empleado. |
| E — Marcajes | Válido: `major 5`, `minor 38`, `employeeNoString = 900001`, hora con desfase, `serialNo`, `doorNo 1`. **Denegado (dedo no registrado): `minor 49`, no 39**, con `employeeNoString = 0` (anónimo). **No existe `currentVerifyMode` ni `verifyMode` en el evento de acceso de este firmware:** el método se deduce del `minor` (38 = huella aceptada, 49 = huella rechazada). `attendanceStatus` queda indefinido (no distingue entrada de salida). Solo hay un modo activo, así que no hubo segundo modo que probar. |
| F — Hora y zona | Antes: hora manual, zona `CST-8:00:00` (UTC+8): la hora local mostrada coincidía con la de México, pero la hora absoluta quedaba unas 14 horas desfasada. **Después de la escritura confirmada: `CST+6:00:00` (UTC-6, México)**, hora manual correcta. Los eventos nuevos salen con desfase -06:00; los anteriores conservan +08:00. NTP no está configurado (nombre de servidor vacío); sin cambios. |
| G — Red | IP estática 192.168.10.130/24, puerta de enlace .10.1, DNS 8.8.8.8 y 8.8.4.4; sin DHCP. No se tocó la IP. **Pendiente (acciones del usuario):** reserva de respaldo en el router y aislamiento (punto a punto o VLAN). |
| H — Limpieza | Usuario sintético borrado; quedó 1 usuario. Sus eventos permanecen en el registro (seriales 34 a 36) y su número no se reutiliza. |

## Qué se decidió / consecuencias para el puente

Estos hallazgos corrigen supuestos del puente. Cada uno requiere un cambio y su revisión de seguridad antes de la prueba física:

1. **El alta de usuario debe enviar el cuerpo completo** (vigencia, derecho de puerta y plan). Hasta ahora el puente enviaba solo tres campos, que este firmware rechaza: todas las altas habrían fallado. Hay que fijar los valores con criterio de privilegio mínimo y decidir, según si la salida de puerta controlará una puerta en producción, qué derecho de puerta se asigna.
2. **El método de verificación se deduce del código de evento, no de un campo de modo.** La constante `VALOR_VERIFICACION_HUELLA` (basada en `currentVerifyMode`) deja de tener sentido; la verificación por huella es `minor 38` y el rechazo por huella es `minor 49`. Con ello la activación por la primera marca verificada (`95_`) puede habilitarse cuando el puente lo envíe.
3. **El evento de denegado es `minor 49`**, y trae número de empleado cero. El supuesto de `minor 39` era incorrecto.
4. **La zona horaria del aparato ya está en México**, pero el puente debe validar siempre que el desfase efectivo coincida con `America/Mexico_City` y no fiarse de la configuración (T-PI-7). Los eventos de prueba anteriores al cambio quedaron con desfase +08:00 y hora absoluta incorrecta.
5. **Paginación de eventos:** la posición 0 es la más antigua, los números de serie son dispersos (cuentan todos los tipos de evento), la página real es de unas 10 filas y hay que seguir con `responseStatusStrg = MORE`. Hay que revisar que la ingesta no asuma que una página llena mide 30.
6. Los eventos de alta de usuario y de huella (`major 3`, `minor 80/81`) no traen número de empleado y no sirven como evidencia por persona.

## Qué quedó pendiente

- Decidir si la salida de puerta controlará una puerta real en producción y, según eso, el derecho de puerta de los usuarios nuevos.
- Cambios del puente listados arriba, con revisión de `security`, y un nuevo ensayo físico del alta con cuerpo completo.
- Reserva DHCP de respaldo y aislamiento de red de la terminal.
- Configurar NTP o aceptar la hora manual con revisión periódica.
- Si se requiere distinguir entrada de salida, configurar el modo de asistencia en el aparato.

## Decisiones del usuario (10 de octubre de 2026, después de la verificación)

- **La terminal solo registrará asistencia.** No controlará ninguna puerta. El derecho de puerta que el firmware obliga a enviar queda como un valor técnico sin efecto físico, con la **condición escrita de que ningún relevador ni cerradura se conecte a la salida de la terminal** mientras los usuarios de asistencia tengan derecho de puerta. Si algún día se quisiera controlar una puerta, hay que separar el control de acceso físico de la asistencia y decidirlo de forma explícita.
- **Se acepta la hora manual de la terminal con revisión periódica**, sin NTP por ahora. Consecuencias: el reloj puede derivar, así que el puente debe medir y alertar el desfase contra la hora del servidor (T-PI-7), y TI debe revisar y corregir la hora del aparato con una periodicidad fija (propuesta: cada semana durante el primer mes y después cada mes, y siempre tras un corte de energía). El umbral de alerta y la periodicidad se fijan en T-PI-7 y en el procedimiento de operación.

## Preguntas nuevas

- ¿Qué periodicidad exacta de revisión de la hora y qué umbral de desfase (minutos) se adoptan? Propuesta: alerta a partir de 2 minutos de desfase y revisión semanal el primer mes.
- ¿Se hace la prueba de derecho de puerta vacío con un usuario sintético? Ya no es necesaria para la seguridad física (no hay puerta), pero reduciría el privilegio técnico de los usuarios; queda opcional.

## Nota para la retrospectiva

Los supuestos del firmware (conteo de huellas, cuerpo mínimo de alta, modo de verificación, código de denegado) se habían escrito sin ver el aparato y todos resultaron distintos. Lección: antes de diseñar sobre un dispositivo, probar su contrato real con una verificación de solo lectura y un usuario sintético, y no codificar el supuesto en cientos de pruebas.
