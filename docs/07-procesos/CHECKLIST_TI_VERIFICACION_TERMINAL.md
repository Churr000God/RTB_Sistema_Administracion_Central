# Checklist de verificación con TI antes de enrolar en la terminal Hikvision

**Terminal:** DS-K1A8503EF-B, firmware V1.3.0 (IP 192.168.10.130, vista desde el Pi del puente en 192.168.10.50).
**Fecha de redacción:** 9 de octubre de 2026.
**Quién lo hace:** una persona de TI, una sola vez, supervisada. **No lo hace el puente ni ninguna sesión automática.** TI custodia la contraseña de administrador de la terminal; no se comparte por chat, correo ni se guarda en archivos.
**Para qué sirve:** la sonda de solo lectura del 9 de octubre de 2026 mostró que la terminal no informa el conteo de huellas y que devuelve datos que no esperábamos (contraseña y número de tarjeta dentro del usuario). Este checklist confirma lo que sólo se puede ver en el aparato mismo, antes de enrolar a ninguna persona real.

## Reglas durante la verificación

- Usar **un solo usuario sintético** (número de empleado de pruebas acordado de antemano, sin relación con ninguna persona real). Nunca una persona real.
- Todo se hace desde el **menú del propio aparato** o desde su interfaz web con la sesión de TI. El puente no se conecta durante la verificación.
- No capturar ni exportar plantillas de huella, fotografías ni tarjetas. Si el aparato ofrece "exportar" o "respaldar usuarios", no usarlo.
- No anotar contraseñas ni PIN. Para cada dato sensible anotar sólo **sí/no** ("tiene valor", "está vacío").
- Un intento de contraseña incorrecto repetido puede bloquear la cuenta o la IP del aparato: si falla la sesión, parar y avisar, no reintentar en bucle.
- Si algo del aparato se comporta distinto a lo esperado, **detenerse y avisar**; no improvisar cambios de configuración.

## Antes de empezar

- [ ] La caducidad de altas sin huella está en **168 horas** (hecho el 9 de octubre de 2026 desde la pantalla de configuración de terminales). Ver bitácora.
- [ ] El puente **no está desplegado** en el Pi (se confirmó el 9 de octubre de 2026; no debe haber ningún servicio de checador en marcha). Si ya existe, apagarlo antes.
- [ ] Hay una persona que pueda **desconectar físicamente** la terminal de la red o de la corriente si algo sale mal.
- [ ] Se tiene a la mano el manual o acceso web de la terminal, y un teléfono para tomar fotos de pantallas de configuración (sin datos personales en cuadro).

## A. Seguridad física

1. [ ] **Salida de puerta / relevador.** ¿La salida de puerta de la terminal está conectada a una cerradura, chapa, barrera u otro dispositivo que abra algo? Anotar: **sí / no**.
   - Si **no** está conectada: el riesgo de que un usuario nuevo abra una puerta es nulo. Anotarlo y seguir.
   - Si **sí** está conectada: **antes de enrolar a nadie**, desactivar la salida de puerta o poner el tiempo de apertura en 0 desde el menú del aparato (no desde el sistema). Verificar que marcar con el usuario sintético no activa el relevador.

## B. Credenciales dentro de los usuarios

2. [ ] **Contraseñas y PIN de usuarios existentes.** La terminal devuelve un campo de contraseña dentro de cada usuario. Anotar sólo si **hay usuarios con contraseña/PIN con valor** (sí/no) y cuántos, sin anotar los valores.
3. [ ] **Modo de verificación.** ¿Se permite hoy verificar por contraseña, tarjeta o rostro además de huella? Anotar qué modos están activos.
   - Si no se usan contraseña ni tarjeta: **dejar sólo huella** como modo de verificación para los usuarios nuevos.
4. [ ] **Tarjetas.** ¿Algún usuario tiene número de tarjeta registrado? Anotar sí/no. Si el número de tarjeta no se usa, no capturarlo en los usuarios nuevos.

## C. Usuario sintético: valores por omisión

5. [ ] Crear **un usuario sintético** desde el menú del aparato con el número de empleado de pruebas acordado y el nombre `U<número>` (por ejemplo `U900001`), **sin** tarjeta ni contraseña.
6. [ ] Anotar los **valores por omisión** que el aparato asignó a ese usuario (en su ficha, sin foto):
   - vigencia habilitada (sí/no), fecha de inicio y de fin;
   - derechos de puerta (puertas asignadas) y plan de acceso;
   - modo de verificación del usuario;
   - tiempo de apertura de puerta.
7. [ ] Si la vigencia o los derechos por omisión **denegarían** las marcas (por ejemplo, vigencia vencida, sin derechos de puerta, deshabilitado), anotarlo: el sistema no los cambia hoy y lo mostrará como alerta, y habrá que decidir si se corrigen en el aparato o por el puente en una versión posterior.

## D. Eventos de la terminal

8. [ ] **Evento de alta de huella.** Enrolar una huella al usuario sintético desde el menú. Luego, en el registro de eventos del aparato (sin exportar plantillas), anotar si **aparece un evento** de alta/modificación de huella o de usuario, y su tipo si el aparato lo muestra. Anotar **sí/no**.
9. [ ] **Verificación por huella.** Marcar con el usuario sintético. Anotar del evento resultante (en pantalla, sin copiar datos personales):
   - código de evento (major/minor) y si coincide con **verificación exitosa por huella** (se esperaba minor 38);
   - el campo que dice con qué modo se verificó (`currentVerifyMode` o su equivalente) y su valor **exacto** para huella;
   - formato de la hora del evento (¿lleva desfase?) y del número de serie del evento.
10. [ ] **Verificación fallida.** Marcar con un dedo no registrado. Anotar el código del evento de **acceso denegado** (se esperaba minor 39) y si el evento trae número de empleado o no.
11. [ ] **Verificación con otro modo.** Si algún modo no-huella está activo (contraseña, tarjeta), probar uno con el usuario sintético y anotar si el evento **se distingue** del de huella por su modo.

## E. Hora, zona y red (escrituras de configuración, sólo TI en el menú)

12. [ ] Anotar la **zona horaria** y la hora actuales del aparato (hoy se vio zona `CST-8:00:00`, que equivale a UTC+8 en la notación POSIX invertida).
13. [ ] Cambiar la zona a la de México (`CST+6:00:00`, UTC-6) y dejar la **hora correcta**. Anotar si el aparato conserva el cambio tras reiniciar.
14. [ ] Anotar si hay **NTP** disponible en el aparato y si se activó (hoy la hora es manual). Si se configura NTP, anotar el servidor.
15. [ ] Anotar la **dirección IP** y si usa DHCP. Acordar una **IP fija** o reserva en el router.
16. [ ] Acordar **aislamiento de red**: la terminal debe quedar en un enlace punto a punto con el Pi del puente o en una VLAN aislada, porque el enlace con la terminal es HTTP con Digest, sin TLS.

## F. Limpieza

17. [ ] Borrar el usuario sintético desde el menú del aparato. Anotar que **quedan eventos** en el registro del aparato asociados a ese número y que no hay que reutilizar ese número.
18. [ ] Confirmar que la terminal quedó **sin usuarios de prueba** y con la configuración acordada.

## Qué se registra y a dónde va

Anotar las respuestas en un solo documento (sin contraseñas, PIN, tarjetas ni fotos) y entregarlo a `orchestrator` o guardarlo en `bitacora/` con la fecha. Resumen mínimo:

| # | Dato | Respuesta |
|---|------|-----------|
| 1 | Salida de puerta conectada | |
| 2 | Usuarios con contraseña/PIN con valor | |
| 3 | Modos de verificación activos | |
| 4 | Usuarios con tarjeta | |
| 6 | Vigencia, derechos, plan y modo por omisión | |
| 8 | Evento de alta de huella | |
| 9 | Minor de verificación por huella y valor exacto del modo | |
| 10 | Minor de acceso denegado | |
| 12-15 | Zona, NTP, IP | |

## Qué desbloquea y qué no

Con estas respuestas se pueden **confirmar o corregir** los supuestos que el puente asume sobre el firmware (códigos `minor` 38/39, valor de `currentVerifyMode` para huella, derechos y vigencia por omisión, formato de las horas). Eso se necesita antes de congelar el esquema del puente.

**Esto no autoriza todavía a enrolar personas reales.** Para eso deben estar cumplidas, además:

- [ ] `94_` y `95_` aplicados en la base y probados (confirmación manual de la huella y activación por la primera marca verificada), y las pantallas del sistema mostrando "huella confirmada" en vez de "0 huellas".
- [ ] La caducidad de altas en 168 horas **y** la confirmación manual en uso, para que una persona enrolada no sea dada de baja (con su huella) a los 7 días.
- [ ] El relevador de puerta cerrado o desconectado (punto 1).
- [ ] La zona horaria corregida y la hora validada (puntos 12-14).
- [ ] La decisión sobre la llave `scjt_` del puente y su alta por TI.

Las 15 pruebas físicas completas están en `PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md`.
