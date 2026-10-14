# Plan de desarrollo del piloto — Terminal Hikvision (pruebas con personal avisado)

**Versión:** 1.0 · **Fecha:** 14 de octubre de 2026 · **Responsable:** el usuario (dueño del proyecto) · **Apoyo:** TI (presente en cada alta), `Checador` (sesión del puente), `raspi-pruebas` (backend de pruebas), `security`, `db`, `backend`, `frontend`, `testing`, `devops`.

Este documento es el plan del piloto: qué se va a probar, con quién, en qué orden, qué se mide y cuándo se da por pasado. No sustituye a `PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md` (decisiones y pendientes de desarrollo) ni a `puente/PRUEBA_FISICA.md` del repositorio del puente (lo que el puente asume del firmware); los usa.

---

## 0. En una página

- **Qué es:** un piloto técnico de **un mes** con **personas avisadas** de que es una prueba, sobre la **base de pruebas** (no el sistema final). Al terminar, el aparato se limpia (salvo el usuario del dueño) y se pasa al sistema real, que es otra base de datos.
- **Qué se quiere ver:** que las huellas se registren y se activen bien, que las marcas **suban** y se generen bien (hora, tiempos, tramos, horas), que el cierre de día y el corte quincenal calculen lo esperado, y qué pasa con una **caída del Pi** (si las marcas hechas durante el corte se suben después).
- **Qué NO es:** no se prueba el interruptor de activación automática de huella (queda **apagado**), no hay relevador ni cerradura conectados, no se cargan datos reales de personal definitivo.
- **Reglas que no cambian:** ningún secreto pasa por el chat; la contraseña de la terminal y la llave `scjt_` las custodia el usuario/TI; ante cualquier 401 del aparato se **para y no se reintenta**; un cambio por ventana.

## 1. Estado de partida (13–14 de octubre de 2026)

| Pieza | Estado |
|---|---|
| Puente (`checador-fisico`) | v0.1.1 firmada (`ba4d825`), rueda `b48c6d79…`, instalada por el flujo verificado; segunda construcción en CI coincide. Credenciales rotadas (llave `scjt_` id 2; contraseña de la terminal nueva). Sin drop-in EPERM; 30 min en producción sin incidentes. |
| Ritmo del puente | Ingesta cada 30 s, 10 páginas, pausa 2 s, intervalo mínimo 2 s; reloj, trabajo y reconciliación activos; freno hasta 4 episodios. |
| Backend / frontend | Pi de pruebas (`raspberrypi-serverpruebas`), HTTPS por `tailscale serve`; frontend en `http://100.115.160.115:8080`. |
| Base de datos | `tiempo`: `100_` aplicado (sin privilegios de `anon`). Pendientes de aplicar al arrancar el piloto: `101_` y `102_` (esquema `personas`). |
| Terminal | Hikvision DS-K1A8503EF-B, firmware V1.3.0, zona `CST+6:00:00`, hora manual sin NTP, enlace punto a punto (Pi `192.168.50.1` ↔ terminal `192.168.50.10`), sin relevador. 1 usuario previo (el del dueño). |
| Interruptor de activación por huella | **Apagado.** Se activa cada persona con **confirmación humana** (`huella_confirmada_manual`). |
| Consentimiento | Texto **provisional** v1 (el definitivo de RH/Legal no es necesario para este piloto). Las personas participantes saben que es una prueba. |

## 2. Roles

| Rol | Quién | Qué hace |
|---|---|---|
| Dueño del piloto | el usuario | Decide, autoriza cada ventana de escritura, custodia llaves y contraseña, confirma huellas. |
| TI | persona designada | Presente en cada alta; enrola la huella en el menú del aparato; revisa la hora semanalmente. |
| RH | persona designada | Da de alta personas y asignaciones; confirma la huella; revisa excepciones. |
| Participantes | personas ya identificadas | Marcan entrada y salida; avisan de cualquier anomalía. |
| Operación técnica | `Checador`, `raspi-pruebas`, `db`, `security` | Ventanas del puente, lecturas del servidor, verificación de privilegios. |

## 3. Condiciones previas (marcar antes de la semana 1)

**Técnicas**
- [ ] Ventana E cerrada: `puente.service` y `puente-respaldo.timer` habilitados; reinicio real del Pi probado; revisión de ≥ 12 h sin supervisión sin reinicios ni avisos.
- [ ] `101_` aplicado y verificado (sección 64 en 0 filas).
- [ ] `102_` aplicado y verificado (secciones 63, 65 y 66 en 0 filas) y humo con login real del usuario base.
- [ ] `operador estado`: freno limpio, reloj sincronizado, latido en segundos; tarjetas 14 y 15 sin alarma.
- [ ] Guion de verificación `/home/dhguilleng/verificar-puente.sh` probado.
- [ ] Respaldo reciente de la base del puente (0600).

**De datos**
- [ ] Participantes identificados por nombre (lista cerrada, aceptada por cada uno) y con jornada asignada.
- [ ] Cada participante: persona activa en `personas.persona`, fila en `tiempo.persona`, jornada vigente.
- [ ] Decidido qué se hace con el usuario previo del aparato (el del dueño): vincularlo a su persona o dejarlo fuera; la reconciliación lo mostrará como «alta a mano ajena» mientras no tenga alta en el servidor.

**Humanas**
- [ ] TI y RH disponibles en cada alta (cuatro ojos).
- [ ] Participantes avisados: es una prueba, la información se borrará, qué marcar y cuándo.
- [ ] Quién revisa el tablero cada día y quién recibe los avisos.

## 4. Cómo se activa una persona (interruptor apagado)

1. RH da de alta a la persona y la **asigna a la terminal** (queda `pendiente_alta` con su `employee_no`).
2. El puente crea el usuario en el aparato (`usuario_creado`, **`esperando_huella`**).
3. TI enrola el dedo en el **menú del aparato**, con la persona presente.
4. La persona hace una **marca de prueba**.
5. RH/TI pulsa **«Confirmar huella»** en el sistema → la persona pasa a **`activo`** (`huella_confirmada_manual`, con nota).
6. A partir de ahí sus marcas se aceptan y cuentan.

Una alta que se queda en `esperando_huella` caduca a las **168 h**; el sistema pide la baja y el puente borra el usuario del aparato.

## 5. Calendario

| Semana | Foco | Qué se hace |
|---|---|---|
| **0** | Preparación | Condiciones previas; aplicar `101_`/`102_`; cerrar E; alta de la primera persona con TI + RH. |
| **1** | Uso normal | Altas del resto; entradas y salidas diarias; confirmaciones; cierre de día; revisión de excepciones; primera revisión del reloj. |
| **2** | Caídas | Casos P6 a P9: corte del Pi (limpio y, si se decide, duro), backend caído, deriva de reloj. |
| **3** | Estructura | Marcas tardías en día cerrado; corrección; suspensión de una persona; caducidad de alta; segunda revisión del reloj. |
| **4** | Cierre | Corte quincenal; revisión de horas; decomisión (casos P14–P15); informe. |

La revisión del reloj de la terminal es **semanal** durante el piloto (alerta a partir de 2 minutos de desfase).

## 6. Casos de prueba

Anotar para cada uno: fecha, hora UTC, quién lo hizo, resultado y evidencia. **Sin plantillas biométricas, sin contraseñas, sin `employee_no` en los documentos.**

| # | Caso | Pasos | Resultado esperado |
|---|---|---|---|
| P1 | Alta y activación | §4 | Bitácora completa; estado `activo`; evidencia `huella_confirmada_manual` con nota. |
| P2 | Primera marca (entrada) | La persona pone el dedo | `tiempo.marca` con `origen='terminal'`, `momento_dispositivo` correcto, `desfase_local=-06:00`, `estado_reloj=sincronizado`; visible en Registro de marcas con el retraso real (≤ ~1 min). |
| P3 | Segunda marca (salida) y cierre de día | Marcar salida; esperar el cierre | Tramo con las horas esperadas; día `cerrado`. Marca impar → día `bloqueado` y excepción. |
| P4 | Doble lectura | El mismo dedo dos veces en < 60 s | Una sola marca, o ambas marcadas como señaladas: **anotar el comportamiento real** (a observar). |
| P5 | Duplicados tras reintento | Observar tras P6 o P8 | Sin filas duplicadas; cada `evento_id` una sola vez. |
| P6 | **Corte del Pi limpio** | `sudo poweroff` con la terminal encendida; 3–5 marcas de distintas personas; reconectar | Al volver, el puente arranca solo, retoma desde su cursor y sube todo con su **hora original**; `momento_recepcion` posterior; sin pérdidas ni duplicados; tarjeta 15 pasa por «revisar» y regresa a limpia. |
| P7 | Corte duro (opcional) | Desconectar el Pi sin apagar; hacer marcas; reconectar | Igual que P6 más: base local íntegra (`integrity_check`), sin candado huérfano. **Solo con imagen de la SD y respaldo previo.** |
| P8 | Backend caído | Detener el backend de pruebas ~10 min; marcar; reanudar | El puente acumula y reintenta con espera creciente; al volver sube todo; `marcas_pendientes` vuelve a 0. |
| P9 | Deriva de reloj (opcional) | TI adelanta la hora de la terminal +3 min | Alerta de desfase ≥ 2 min; las marcas se señalan como `deriva`; se restablece. Un solo cambio en el aparato en esa visita. |
| P10 | Usuario previo | Observar `operador estado` | `altas_a_mano_ajenas=1`; **no se borra solo**; se decide vinculación o borrado manual. |
| P11 | Persona suspendida | Suspender a una persona de prueba | Baja solicitada; el puente borra el usuario del aparato; una marca posterior queda rechazada. |
| P12 | Caducidad de alta | Dejar un alta en `esperando_huella` > 168 h | Baja automática; reasignar da otro `employee_no`. |
| P13 | Marca tardía en día cerrado | Subir una marca de un día ya cerrado (p. ej. de P6/P7) | Excepción `dia_cerrado`; «Revisar día» o «Descartar»; «Corregir» bloqueado con su mensaje; sin escritura directa por PostgREST. |
| P14 | Corte quincenal | Al cierre de la quincena | Banco de horas y saldos coherentes con las marcas; sin periodos pendientes ocultos. |
| P15 | Decomisión | Dar de baja a todas las personas de prueba y borrar sus usuarios del aparato, **excepto el del dueño** | `baja_confirmada` en todos; ninguna huella de participantes en el aparato; ninguna plantilla en logs, base, colas ni respaldos. |

**Mediciones adicionales (sin caso propio):**
- **Capacidad del buffer del aparato:** cuántos eventos caben antes de rotar (contador de serie global, incluye eventos de operación).
- **Tiempo de recuperación tras un corte:** desde el arranque del Pi hasta el primer latido y la primera vuelta de ingesta.
- **Latencia de subida** de una marca (de la huella al registro).

## 7. Seguimiento

**Diario (5 min, TI o el dueño):** tablero de anomalías (tarjetas 14 y 15 y el resto); `verificar-puente.sh` si hubo cualquier corte; revisar excepciones abiertas.

**Semanal:** revisión de la hora de la terminal contra la del Pi; `operador estado` completo; tamaño del journal y de los respaldos; lista de marcas rechazadas con su motivo.

**Parar y avisar de inmediato ante:** 401 o `desafio_repetido` del aparato; freno en episodio; cualquier `Record`/`Delete` inesperado; `perdida_buffer`; una marca con `employee_no` desconocido que no sea la del dueño; tarjetas 14/15 en alarma; el servicio en `failed`.

## 8. Criterio de éxito del piloto

Pasa si, al terminar el mes:
1. P1, P2, P3, P6, P8, P11 y P13 pasan sin intervención fuera del enrolamiento y de las confirmaciones.
2. P4, P5, P9, P10, P12, P14 y P15 pasan o quedan **explicados** (comportamiento real documentado).
3. Ninguna marca de una persona activa se perdió ni se duplicó; las horas calculadas coinciden con lo esperado.
4. Ninguna plantilla biométrica ni secreto aparece en logs, base, colas ni respaldos.
5. El corte (P6) quedó medido: tiempo de recuperación y marcas tardías.
6. Un informe de una página con incidentes y decisiones.

## 9. Cierre y paso al sistema final

El sistema final es **otra base de datos**. Al terminar el piloto, **en orden**:
1. Congelar altas nuevas; esperar a que `marcas_pendientes` sea 0 y todas las marcas estén `confirmado`.
2. Respaldo final del puente y exportación de resultados (sin datos biométricos).
3. Decomisión de las altas de prueba (P15): bajas confirmadas y usuarios borrados del aparato, **conservando solo el del dueño**.
4. Revocar la llave `scjt_` de esta base; **emitir una llave nueva** en el sistema final.
5. Apuntar el puente al backend del sistema final (URL, llave, serie de la terminal registrada allí).
6. **Reanudar con la política de arranque que corresponda** y un `employee_no` nuevo para cada alta real; las huellas de las personas definitivas se enrolan de nuevo en el aparato.
7. Aviso a RTB-App del esquema vigente; el DDL se copia allí como migración (nunca en sentido inverso).
8. Una ventana supervisada con los criterios de siempre antes de dejarlo correr solo.

*(Los detalles del paso 5 y 6 —política de arranque y mapa— se afinan al llegar a ese punto con `Checador` y `security`.)*

## 10. Riesgos y residuos aceptados

- **Capacidad del buffer sin medir:** una caída larga con mucho tráfico podría perder eventos; se mide en el piloto.
- **Hora manual sin NTP:** deriva posible; revisión semanal y alerta ≥ 2 min.
- **`main` sin protección de rama** (único desarrollador); la reconstrucción del paquete se verifica por firma y hash.
- **Corte duro:** riesgo de daño al sistema de archivos del Pi; solo con imagen de la SD.
- **Medición de desfase terminal-servidor** con precisión de ±1–2 s (la cabecera `Date` trunca a segundos).
- **Datos de prueba** en una base que no es la final: no se reutilizan.

## 11. Registro de resultados (plantilla)

| Caso | Fecha/hora UTC | Quién | Resultado | Evidencia / nota |
|---|---|---|---|---|
| P1 | | | | |
| P2 | | | | |
| … | | | | |

## 12. Referencias

- `bitacora/2026-10-13_estado_de_la_sesion_para_retomar.md` (estado, ventanas A–E, residuos aceptados).
- `docs/07-procesos/PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md` (decisiones y pruebas físicas originales).
- `docs/07-procesos/CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md` (el interruptor, apagado en este piloto).
- `checador-fisico/puente/PRUEBA_FISICA.md`, `puente/PETICIONES_A_LA_TERMINAL.md`, `puente/despliegue/LEEME_INSTALACION.md`.
