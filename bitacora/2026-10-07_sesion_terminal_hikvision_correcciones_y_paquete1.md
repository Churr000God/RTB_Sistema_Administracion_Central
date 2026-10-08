# 2026-10-07 · TERM — Terminal Hikvision: DDL 82-87, backend/frontend de excepciones y correcciones, Paquete 1

**Participantes:** usuario, `orchestrator` y las sesiones `backend`, `frontend`, `db`, `testing`, `security`,
`devops` (más la sesión remota "Cheador", que corre dentro del Pi checador).
**Duración:** del 5 al 8 de octubre de 2026 (continuación de
`2026-10-05_checador_hikvision_auditoria_y_modelo.md`).

Estado consolidado y plan completo hasta producción: `docs/07-procesos/PLAN_TERMINAL_HIKVISION_HASTA_PRODUCCION.md`.

---

## Qué se hizo

- **Modelo de datos de la terminal completo y aplicado** (`80_` a `85_`): terminal, altas, bitácora
  inmutable, credencial por hash, RPC `SECURITY DEFINER` de autenticación/mapa/movimientos/latido/marcas/baja,
  `marca_rechazada` con purga, caducidad de altas. Cada migración se ensayó con `BEGIN…ROLLBACK` contra
  Supabase real (61/61, 230/230, 31/31), la revisó `security` y la aplicó el usuario desde el SQL Editor.
- **Se descubrió que `78_` nunca se había aplicado** (la base real tenía 49 funciones y los scripts 50). El
  usuario lo aplicó sin ensayo; `security` lo revisó después y encontró **dos evasiones reales** (cambiar el
  motivo antes de resolver; sembrar un tramo falso). El diagnóstico de sólo lectura de los datos reales no
  mostró uso del hueco. `86_` lo cierra (columnas inmutables, revisión del día en la misma transacción o
  descarte auditado, coherencia de tramos, permiso de acción no heredable). Ensayo 100/100.
- **Se confirmó con un ensayo real una inconsistencia:** corregir la hora de una marca que ya está en un
  tramo se guardaba en `tiempo.correccion` pero el UPDATE de tramo afectaba 0 filas por RLS (tramo abierto:
  `42501`); como dueño/`service_role` el trigger pisaba las horas manuales de RH y el descuento de pausa.
  Respuesta: bloqueo en el backend (409) y respaldo en la base (`87_`, ensayo 47/47).
- **Backend:** corte 1 de `SCJ-DEC-12` (autenticación de terminal y latido, 601 pruebas); mapeo de `SCJ15`,
  descarte de marcas tardías, bloqueo de correcciones, campos y filtros para la interfaz (786 pruebas).
- **Frontend:** Paquete 1 (Registro de marcas con bloqueo, Excepciones con descarte, Días con resumen), 603
  pruebas, tras diseño previo aprobado (mockups servidos por tailnet).
- **Paquete 2 (enrolamiento):** 8 mockups de borrador entregados, sin implementar.
- **Auditoría y análisis de la terminal** desde dentro del Pi (sesión "Cheador"): capacidades ISAPI, red,
  hora, qué permite y qué no (ver bitácora del 5 de octubre).
- **Documentos:** `SCJ-DEC-11` V1.1, `SCJ-DEC-12` V2.0, `SCJ-CDT-01` V3.0, `SCJ-ESP-01` V3.0, `SCJ-PRO-11` V3.0,
  `SCJ-PRO-15` V1.1, `SCJ-DIC-01` V1.3, `SCJ-MOD-03` V1.8; `db/ensayos/` y el plan consolidado.

## Qué se decidió

- **La huella se enrola en el menú del aparato; ninguna plantilla sale de la terminal; TI custodia la
  contraseña admin** (opción B de `security`; la opción A —enrolar mediado por el Pi— se descartó porque
  `CaptureFingerPrint` devuelve la plantilla y viajaría por HTTP sin TLS).
- Credencial propia de la terminal (llave `scjt_`, hash en base) y marcas por el backend con RPC; el Pi
  manda `employee_no`; `SCJ-CDT-01` sube a V3.0 (versión mayor por `CONVENCIONES §I`).
- Rechazo de marcas no enroladas con `marca_rechazada` (retención 90 días).
- `terminal_usuario_edicion` y `excepcion_dia_cerrado_descarte` **no heredables**; auto-asignación prohibida
  salvo el administrador genérico.
- Camino legítimo para marcas tardías en día revisado: **RPC de descarte** con permiso de acción;
  **"Corregir" se bloquea** en marcas ya en un tramo (opción A); la opción B queda para después.
- Cambios de versión mayor en `SCJ-ESP-01` y `SCJ-PRO-11` (V3.0) y `SCJ-DEC-12` (V2.0).

## Qué quedó pendiente

Todo está en el plan consolidado (secciones 3 a 6). En resumen:
- **Decisiones del usuario:** D1-D6 (mockups P2: navegación, modal compartido, quién ve anomalías, texto de
  consentimiento, mínimo de huellas, avisar a TI), D7 (opción B), D8 (consentimiento LFPDPPP), D9-D13
  (TLS/Tailscale/`sudo`/ACL/SSH), D14-D16 (escrituras en la terminal y credenciales), D17 (aviso a RTB-App),
  D18 (`SCJ-MOD-02`), D19 (sincronizar el repo académico).
- **Backend:** cortes 2+ (ruta de marcas, lado terminal, endpoints web de terminales, banderas de sesión,
  hook de baja y jobs de caducidad/purga, monitoreo, verificación real del `SCJ15` diferido).
- **Puente del Pi** (repo `checador-fisico`): credencial, cliente ISAPI sin plantillas, polling+push,
  outbox, reconciliación, reloj/chrony, latido, `systemd`, simulador de pruebas.
- **Frontend:** implementar el Paquete 2; verificación visual real.
- **Despliegue:** TLS (nginx en contenedor), configuración de la terminal (zona, red punto a punto, NTP,
  borrar usuario de prueba), alta de la primera llave, servicio del puente.
- **Pruebas físicas** con la terminal (15 casos, sección 6 del plan).

## Preguntas nuevas

- ¿Navegación "Terminales" como grupo propio o dentro de "Parámetros"? (recomendado: grupo propio)
- ¿Un modal de asignar compartido con la ficha de persona? ¿Quién ve el tablero de anomalías?
- Texto real del aviso de privacidad y del consentimiento biométrico (RH/Legal); ¿dónde se registra?
- ¿El firmware permite un usuario no-admin que gestione usuarios sin capturar ni leer plantillas? ¿Hay
  campo de conteo de huellas por usuario sin `fingerData`? (la sesión del Pi lo investiga)
- ¿Cuándo se construye la opción B (corregir marcas ya en un tramo)?
- ¿El error diferido `SCJ15` llega a `supabase-py` con `code` y `hint` desde PostgREST? (sólo probado con
  mocks)
- ¿Dónde editó el usuario `SCJ-MOD-02`? No aparece cambio en este repo.

## Nota para la retrospectiva

- **Un fix de seguridad sin ensayo da una falsa sensación de cierre.** `78_` quedó sin aplicar semanas, y
  al aplicarlo a ciegas resultó evadible; contrastar los scripts versionados contra la base real después de
  cada tanda (`verificar_ddl.sql`) lo habría detectado antes.
- **Un `WHEN` con igualdad exacta sobre una columna que el mismo actor puede editar es evadible**: usar
  prefijo y proteger las columnas con un trigger aparte (el `WITH CHECK` de RLS no ve el `OLD`).
- **Los ensayos `BEGIN…ROLLBACK` encontraron errores que la revisión por lectura no:** el trigger BEFORE
  que corta antes que el `CHECK`, el `SET CONSTRAINTS ALL IMMEDIATE` que queda activo toda la transacción,
  restricciones de `fn_correccion_valida`, comillas faltantes. Siguen sin poder simular concurrencia.
- **El clasificador de permisos bloquea `psql` de escritura**: el flujo "el usuario pega el SQL en el
  editor, `db` verifica en sólo lectura" funcionó bien y deja evidencia clara.
- **Cada sesión pide su propia confirmación al usuario** para escribir contra la base real; el OK dado al
  orquestador no la sustituye. Conviene avisar al usuario de que le llegará.
- **Los mockups por tailnet** (servidor estático sólo en la IP de Tailscale, con copia acotada) permitieron
  revisar el diseño desde la tablet; la extensión de Chrome sirve para medir geometría cuando Playwright no
  encuentra Chrome.
- **Se siguió el patrón de revisión en cascada** (`db`/`backend` → `security` → `testing`) con aplicación de
  cada hallazgo antes del commit; produjo ~6 hallazgos medios que habrían llegado a producción.
