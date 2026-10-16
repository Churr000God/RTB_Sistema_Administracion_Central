# 2026-10-13 · Estado de la sesión del checador (puente + terminal + interruptor) para retomar

Sustituye en lo vigente a `2026-10-10_estado_de_la_sesion_para_retomar.md` (que sigue siendo el histórico de las decisiones
de 2026-10-08 a 10-10). Léelo después de éste si hace falta contexto. Rol de quien lo lea: `orchestrator` del equipo de
sesiones persistentes (`team-orchestrator`): nunca `Agent()` para especialistas; delegar por `SendMessage` tras `ListAgents`.

## 0. Cómo retomar (en este orden)

1. `ListAgents`; `git fetch` y `git log origin/main..main` en `RTB-CRM-APP` y en `/home/diego/Proyectos/checador-fisico`
   (ambos estaban limpios y empujados al compactar: RTB-CRM-APP `origin/main` = `07b540f`, checador-fisico = `3bb05a9`).
2. Preguntar al usuario qué ya hizo en el Pi del puente desde este documento (sesión `Checador`, Remote Control).
3. La siguiente acción es la **ETAPA 1 del puente (reloj ON)**, no antes de que el usuario la autorice (ver §4).
4. Reglas de trabajo en §7. No inventar autorizaciones: cada escritura en base real, despliegue y escritura en un Pi
   necesita el OK del usuario en esta conversación y, además, se ratifica en la sesión que la ejecuta.

## 1. Lo logrado desde 2026-10-10

- **DDL aplicado y verificado en la base real:** `94_`, `95_`, `96_` (parte A), `97_` (interruptor de la activación por huella),
  `98_` (la marca respeta el interruptor) y `99_` (`tiempo.terminal.ingesta_detenida` y `fn_terminal_latido` de 7 argumentos).
  `verificar_ddl.sql` en 0 filas salvo la línea base conocida. El interruptor sigue **apagado de fábrica**; solo enciende la
  función `fn_terminal_inferir_huella_cambiar` (nota ≥10, vencimiento ≤30 días, consentimiento DEFINITIVO publicado, terminal
  activa) y hoy el único consentimiento es el provisional, así que encender da `SCJ16`.
- **Endpoint y pantalla del interruptor** («Activación por huella», tercera pestaña de Configuración de terminales),
  tarjeta 14 `interruptor_huella` y tarjeta 15 `terminal_sin_contacto` del tablero de anomalías; contrato en
  `docs/07-procesos/CONTRATO_API_INTERRUPTOR_INFERIR_HUELLA.md`. Revisados por `security` y mutados por `testing`.
- **Manejador de errores global seguro:** `app/registro_seguro.py` (nunca registra el texto de una excepción) y batches con
  lista acotada a 20 ids. Cabeceras `X-Forwarded-*` repetidas se unen (`2cbef23`).
- **HTTPS del backend de pruebas** por `tailscale serve` (`https://raspberrypi-serverpruebas.<tailnet>.ts.net`, solo tailnet,
  sin funnel); el 8000 solo en `127.0.0.1`; `TERMINAL_PROXIES_CONFIANZA=172.19.0.1` con subred Docker fijada `172.19.0.0/16`;
  `VITE_API_URL` https en `frontend/.env` del Pi. `security` cerró formalmente el HTTPS (2026-10-13). Residuos aceptados:
  el 8080 del frontend sigue en HTTP escuchando en todas las interfaces; sin `limit_req` ni tope de cuerpo (para el
  despliegue real: proxy propio, IP exacta de confianza); revisar la caducidad del certificado a ~60 días (`openssl x509
  -enddate -noout -in /var/lib/tailscale/certs/…crt`); el nombre de la máquina quedó en Certificate Transparency.
- **Servicio del puente (T-PI-9) escrito, revisado e instalado de forma directa en el Pi del puente** (Debian 13 Trixie,
  systemd 257, Python 3.12.14 de `uv` en `/opt/puente/python`): watchdog por progreso, freno escalado del 401 persistido,
  modo supervisado con caducidad, respaldo diario (unidad aparte), unidades endurecidas, instalación verificable.
- **Aislamiento de la terminal:** enlace punto a punto Pi `eth0=192.168.50.1` ↔ terminal `192.168.50.10`, sin internet, sin
  gateway ni DNS en la terminal, NTP servido por `chrony` del Pi (NTS, `allow` solo la terminal), `nftables` dedicado,
  `ip_forward=0`. Evidencia literal en `checador-fisico/docs/bitacora/2026-10-10_aislamiento_terminal_hikvision.md`.
- **CAUSA RAÍZ DEL 401 DEL PRIMER ARRANQUE (resuelta):** el firmware V1.3.0 de la terminal **no acepta reutilizar el nonce
  Digest**: `httpx.DigestAuth` era preventivo (mismo nonce, `nc=2`) y la terminal respondía 401 SIN `WWW-Authenticate`.
  Corrección `0086d38`/`6bee6ff`: `DigestSinReuso` (una petición lógica = sin credenciales → desafío → `nc=00000001` sobre una
  conexión nueva `Connection: close`; nunca preventivo; un nonce repetido NUNCA recibe credenciales, `DesafioRepetido`;
  un 401 tras desafío fresco es rechazo real ⇒ freno). **Ventana 2 (2026-10-13 ~14:34–14:42Z): ÉXITO**, una vuelta de ingesta
  completa, 28 conexiones nuevas, todas `nc=1`, 0 rechazos; cursor 98→122; latido real llegó; `ultima_ip` en
  `tiempo.terminal_credencial` = IP del Pi del puente (cadena de confianza OK).
- El firmware V1.3.0 **no tiene interfaz web ni registro consultable**: todo diagnóstico sale de captura pasiva (pcap de
  cabeceras, SECRETO, `shred -u`) + el diagnóstico del 401 del puente.

## 2. Estado de los repositorios y despliegues

| Qué | Dónde | Estado |
|---|---|---|
| RTB-CRM-APP `origin/main` | GitHub | `07b540f` (docs del frontend); código desplegado: backend `2cbef23`, frontend `beafa8a` (bundle con `VITE_API_URL` https) en el Pi de pruebas |
| checador-fisico `origin/main` | GitHub (privado) | `3bb05a9` (código instalado en el Pi del puente: `6bee6ff`, rueda `33f921e2…`) |
| Pi de pruebas | `raspberrypi-serverpruebas`, `100.115.160.115` | backend/frontend sanos; el clasificador bloquea «Production Deploy» a `devops`: despliega la sesión `raspi-pruebas` (Remote Control, corre en ese Pi) con aprobación del usuario en su sesión |
| Pi del puente | tailnet `checador`, `100.122.161.26`, usuario `dhguilleng` | servicio `puente` **DETENIDO** (no `enable`), drop-in `SystemCallErrorNumber=EPERM` puesto, `puente.env` en modo supervisado |
| DDL | `db/ddl/` | `00`–`99` aplicados; `100_` y `101_` escritos y empujados, SIN ensayar ni aplicar |

## 3. Pendientes de `db` (autorizaciones de una en una)

1. **Ensayo de `100_`** (revoca a `anon` y TRUNCATE/REFERENCES/TRIGGER en `tiempo`, por catálogo; solo privilegios, BEGIN…
   ROLLBACK, 5432): `security` lo aprobó. Debe imprimir `pg_default_acl` completo, pase o falle D1. Luego aplicar `100_`
   (`--single-transaction`), `verificar_ddl.sql` (sección 63 en 0), y humo de la API real (login, `/api/sesion`, una lectura
   de Tramos/Días, un latido).
2. **Ensayo de `101_`** (errores sin identidad en `fn_bitacora_terminal_usuario_aplica`): SÍ inserta filas sintéticas en
   bitácoras inmutables dentro de la transacción: comando EXACTO `psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f
   db/ensayos/ensayo_101.sql`, SIN `-1`/autocommit, puerto 5432, verificar después que no quedó la persona sintética.
   Luego aplicar `101_` y sección 64.
3. Siguientes cortes anotados (no mezclar): `REVOKE` por catálogo en el esquema `personas` (CURP/RFC/NSS; prioridad), y el
   inventario de `EXECUTE` de funciones `SECURITY DEFINER` para `anon`; la sección 64 pasar a lista permitida.
4. `CLAUDE.md`: `db` propone el texto (DDL hasta `99_`, 15 parámetros, 77 policies, 53 permisos, firma nueva del latido):
   aplicarlo cuando se cierre el ciclo de `100_`/`101_`.

## 4. El puente, por etapas (decididas con `security`; una por ventana, nunca dos cambios a la vez)

Común a todas: bloque «PRIMER ARRANQUE SUPERVISADO» de `puente.env` con `PUENTE_SUPERVISADO_HASTA` ≤ 24 h, `FRENO_EPISODIOS_MAX=2`,
`LATIDO_INGESTA_DETENIDA=1`; `PUENTE_ETIQUETAR_HUELLA=0`; interruptor del servidor apagado; **parar y NO reintentar ese día ante
cualquier 401 o `desafio_repetido`**; el freno persistido NO se limpia a mano (sale con la sonda o con `operador
reanudar-terminal`); commit y rueda instalados anotados en el acta; nadie más toca la terminal; ninguna alta real.

1. **Etapa 1: reloj ON** (`PUENTE_RELOJ_ACTIVO=1`, resto igual, una vuelta). Éxito = `operador estado` con `reloj=sincronizado`,
   desfase terminal-Pi y terminal-servidor ≤ 1 s, modo NTP, `pi_sincronizado=si`, `timedatectl`/`chronyc` bajo la unidad
   con EPERM sin negativas. Sin `tcpdump` (diagnóstico + registro); capturar solo si falla sin explicación.
2. **Antes de la etapa 2** (requisitos de `security`): `backend` prueba que la reconciliación **nunca** emite baja/escritura
   sobre usuarios sin alta en el servidor (hay en la terminal 1 usuario REAL ajeno al sistema; el informe sale solo por
   `puente-operador reconciliar`, sin employeeNo ni nombre en el registro/acta); la cola del servidor para la terminal debe
   estar VACÍA (si hubiera una alta pendiente, trabajo ON la ejecutaría = «primera alta real»); acordar con TI/RH qué es ese
   usuario ajeno.
3. **Etapa 2: trabajo + reconciliación ON** (lectura de `UserInfo/Search`, sin escrituras).
4. **Etapa 3: subir ritmo** en pasos (`max_paginas` 10, `ingesta_cada_s` ≥ 30; no bajar `intervalo_min_s` de 1 s); ~30 min de
   observación con una persona marcando.
5. **Etapa 4: quitar el modo supervisado y `enable`**, solo con: recorrido COMPLETO bajo la unidad real con EPERM (migración,
   candado, `respaldar`, `timedatectl`/`chronyc`, un ciclo de cada lazo, parada limpia); verificaciones del LEEME §5–6;
   **rotación de la llave `scjt_` y de la clave Digest** (ambas vivieron en el Pi de la instalación directa); retirar el
   drop-in EPERM solo si el recorrido no mostró negativas; y la instalación definitiva por el flujo verificado (etiqueta
   firmada, segunda construcción independiente).

## 5. Pendientes del usuario

- **Texto definitivo del consentimiento biométrico** (RH/Legal): sin él no se puede encender el interruptor ni hacer la
  primera alta con personal real. El usuario lo dejó pendiente a propósito el 2026-10-12.
- **Etiqueta firmada `puente-v0.1.0`**: el usuario ya generó su llave SSH de firma dedicada (`~/.ssh/puente_firma`, con
  `gpg.format=ssh` y `allowed_signers` en `~/.ssh`, fuera del repo); la etiqueta NO se ha creado (la firma `git tag -s` es
  del usuario, no de una sesión) y se hace después de las pruebas físicas por si cambian directivas de la unidad.
- **Segunda construcción independiente** (propuesta de CI inactiva en `puente/despliegue/propuesta-ci/`) antes de cualquier uso
  con personas reales; excepción aceptada solo para la instalación de prueba directa.
- **Primera alta real supervisada** (TI + RH, checklist en `checador-fisico/puente/PRUEBA_FISICA.md`): voluntario con
  consentimiento específico, cuatro ojos, interruptor apagado hasta observar «solo huella»; el paso del interruptor solo con
  visto bueno aparte.
- Decidir si el 8080 del frontend pasa a loopback + `tailscale serve`; recordatorio del certificado (~60 días, hacia
  mediados de diciembre de 2026).

## 6. Excepciones y residuos aceptados (para el acta)

- Instalación de prueba directa en el Pi del puente: sin etiqueta firmada ni construcción independiente; `uv` y
  `hatchling` sin hash; construida en el propio Pi. **No se usa con personas reales hasta repetirla por el flujo verificado**
  y hasta rotar la llave y la clave Digest.
- `tcpdump` se instaló y retiró dos veces (excepción a la regla de no herramientas de depuración); hoy NO está instalado.
- Con trabajo OFF una baja pendiente no se ejecuta (solo aceptable en la ventana supervisada y por una vuelta).
- Un proceso local del Pi de pruebas puede afirmar HTTPS/IP (residuo aceptado del proxy de confianza).
- No se rotan las llaves de Supabase (decisión del usuario, documentada el 2026-10-09).

## 7. Reglas de trabajo aprendidas (vigentes)

- `git push` lo hace `orchestrator` con OK del usuario y **solo lo revisado por `security`**; verificar `git log origin/main..main`
  justo antes; `git add` archivo por archivo; nunca `git checkout` para restaurar; mutación de `testing` solo en copias.
- Cada sesión que escribe en la base real o despliega pide su propio OK al usuario; el clasificador de auto-mode bloquea
  «Production Deploy» aunque haya regla `allow`: no se rodea, lo ejecuta el usuario o `raspi-pruebas` con su aprobación.
- Secretos: la llave `scjt_`, la clave Digest y toda captura pcap NUNCA pasan por el chat ni se adjuntan; el número de serie
  de la terminal y la MAC no entran a documentos del repo (redactados).
- La terminal V1.3.0 tiene un contador de bloqueo desconocido: **no probar variantes contra el aparato real**; se prueban en
  el simulador fiel (`puente/src/puente/simulador.py`, con `rechaza_reuso_de_nonce`, traza dorada).
- Una sesión ajena (p. ej. `backend`) puede confundir qué commits están empujados: verificar siempre.

## 8. Mapa de sesiones

`backend`, `frontend`, `db`, `testing`, `security`, `devops` (locales, persistentes); `Checador` (Remote Control, en el Pi del
puente); `raspi-pruebas` (Remote Control, en el Pi de pruebas). Los mensajes a `Checador` y `raspi-pruebas` no confirman
entrega: si no responden, el usuario pega el texto. El navegador de Chrome del grupo MCP tiene la sesión iniciada en
`http://100.115.160.115:8080` (la pantalla del interruptor y Anomalías son lentas: ~12 s por 15 categorías en serie).

## 9. Actualización de la tarde del 13 de octubre de 2026 (después de compactar)

Todo lo siguiente se hizo con autorización explícita del usuario en cada ventana, tras revisión de `security`.

- **Puente, etapas 1 a 3 y recorrido completo (EPERM puesto):** reloj ON, trabajo + reconciliación ON y ritmo subido
  (`INGESTA_CADA_S=30`, `MAX_PAGINAS=10`, `PAUSA_PAGINAS_S=2`, `INTERVALO_MIN_S=2`) sin 401 ni negativas. El -1.5 s de
  `desfase_terminal_servidor` es la resolución de 1 s de la cabecera `Date` (reloj del backend a -2.9 ms por NTP). Con el
  servidor sin altas el barrido de reconciliación sale `mapa_vacio` (el seguro, no una falla).
- **`checador-fisico` en `origin/main` = `f00c977`:** `e719879` + `ba4d825` (prueba de reconciliación con usuario ajeno,
  contadores `huerfanos_del_puente`/`altas_a_mano_ajenas` en `operador estado`) y el workflow `reconstruir-paquete.yml`
  (segunda construcción, pines por SHA, `uv` 0.12.15 con checksum, solo lectura). Etiqueta firmada `puente-v0.1.1` sobre
  `ba4d8257971abf18e632924f892bc7dea0ba5e34` (la `puente-v0.1.0` es de la instalación de prueba, no se mueve).
- **R1 cumplida:** el CI (run `38443271837`) y la máquina del usuario dan la misma rueda
  `b48c6d79f0283dc13da9565efcca97a86797be11e15c60bb8d00b8312e4cba7b` y el mismo paquete
  `73e4450ba87f4d5397723fd79c1ba1e98f9797e38bcb2b6acb44231e3a6f0e7d`. `construir-paquete.sh`
  `138e85672dea53ec447a687a329ad853091bb0213d2e1409a77b42c4bb6adc73`, `empaquetar.sh`
  `d028cbac5c26d565d9dc2e78919147db649de7517489424d89dcbc57ceb24d3e`. Variables del repo creadas por el usuario desde su
  máquina. `main` sin protección de rama (decisión del usuario, único desarrollador; recomendación documentada en el LEEME).
- **Instalación verificada en el Pi del puente (ventana 1):** paquete v0.1.1 instalado con `--require-hashes`; rastros del
  build local retirados; unidad definitiva; `.env` sin llaves; `uv` del Pi 0.12.12.
- **Rotación de credenciales:** ventana A: `scjt_` nueva (id 2, etiqueta «puente v0.1.1 2026-10-13», emitida el usuario) y
  revocación de la vieja (id 1) a las 19:33:43 UTC por el usuario (irreversible, SCJ14); la prueba «401 con la vieja» se
  sustituyó por cuatro evidencias aceptadas por `security`. Ventana B: contraseña de administrador de la terminal cambiada
  en el MENÚ LOCAL por el usuario; autentica sin 401. Ambas custodiadas por el usuario/TI; los valores nunca pasaron por chat.
- **`db`:** `100_` APLICADO por el usuario el 13-oct (anon sin privilegios en `tiempo`; TRUNCATE/REFERENCES/TRIGGER/MAINTAIN
  fuera para authenticated/service_role; guarda de versión PG17; verificador 1–65, secciones 63 y 65 en 0). Commits
  `60ebc72`, `c908cf2`, `8f20e5e` empujados (`origin/main` de RTB-CRM-APP = `8f20e5e`). `101_` sigue sin ensayar.
  `fn_terminal_autenticar` viva = archivo (md5 `76ed43c1…`). Reversa de `100_` guardada por `db` (115 sentencias) hasta una
  semana de uso normal y el corte de `personas`.
- **Pruebas de EPERM:** migración v15→v16 bajo el mismo sandbox y mapa de syscalls x86→aarch64 sin diferencia (122 usadas
  frente a 356 permitidas en systemd 257.9); cinco unidades verificadas bajo su filtro. El drop-in EPERM NO se retira
  todavía (ventana D, con llaves y configuración finales). Vigilancia: `futex_wake/wait/requeue`, `pidfd_getfd`.

### Lo que queda (orden fijado por `security`)
1. **Ventana C:** configuración de producción con el drop-in puesto: quitar los valores supervisados, `FRENO_EPISODIOS_MAX=4`.
2. **Ventana D:** retiro del drop-in (`.disabled`) y recorrido completo con llaves finales; cinco unidades `is-failed`.
3. **Ventana E:** `enable` del servicio y del timer; reinicio del Pi.
4. Después: consentimiento definitivo, primera alta real supervisada, interruptor de huella (visto bueno aparte).
5. Pendientes de `db`: `101_` (ensayo y aplicación), `REVOKE` del esquema `personas`, inventario de `EXECUTE`.
6. Mejoras: `operador probar-servidor` (latido sin validar `TERMINAL_CLAVE`); subir la versión del paquete a 0.1.1 en la
   próxima etiqueta; las dos aserciones opcionales de `security` en `test_despliegue.py`; sha256 del workflow en el acta
   (commit `f00c977`).

## 10. Posibles implementaciones futuras (ideas, no pendientes)

Anotadas a petición del usuario el 13 de octubre de 2026. No son tareas comprometidas ni bloquean nada; se retoman solo si el
usuario las pide.

- **Corte de luz del Pi con la terminal funcionando.** Hoy la terminal marca por su cuenta y guarda los eventos en su buffer
  circular; al volver el Pi, el puente retoma desde su cursor persistente y sube lo que falta, con la hora original y sin
  duplicados (identificador por serie, generación y serial). Si el buffer rotó, el puente lo detecta (`perdida_buffer`) y
  cuantifica la pérdida. Ideas:
  - **Medir la capacidad real del buffer** del aparato (el contador de serie cuenta también los eventos de operación `(3,*)`,
    así que la capacidad útil para marcas es menor a la nominal).
  - **Columna o reporte de «llegó tarde»** en el servidor y la interfaz: `momento_recepcion − momento_dispositivo` ya existe
    en `tiempo.marca`, pero ninguna pantalla lo calcula.
  - **Visibilidad del hueco durante una caída:** el servidor solo sabe que hay un hueco de contacto (`ultimo_contacto_en`,
    tarjeta 15); no puede contar las marcas que siguen solo en el aparato.
  - **UPS pequeño** para el Pi y la terminal.
  - **Medir el tiempo de recuperación tras un corte** (se puede hacer en la ventana de `enable` y reinicio real del Pi).
  - Efecto a comprobar con un retraso real: una marca que llega después del cierre de día genera una excepción
    `dia_cerrado` para revisión.
- **Endurecer el filtro de syscalls** de la unidad del puente (`security`): negar `io_uring_*`, `userfaultfd`, `kcmp`,
  `process_vm_readv/writev`, `keyctl`, `add_key` y `request_key`; ninguna se usa. Es un cambio del filtro con su propio
  análisis y recorrido, posterior a la ventana de `enable`.
- **`operador probar-servidor`:** un latido con la `scjt_` del `.env` sin validar `TERMINAL_CLAVE` ni tocar la terminal,
  para rotar la llave del servidor sin arrancar los lazos del aparato.
- **Medición del desfase con subsegundos:** un timestamp con fracción en el cuerpo del latido, porque la cabecera `Date` de
  HTTP trunca a segundos y el desfase terminal-servidor se mide con ±1–2 s.
- **Valores de producción como predeterminados** del código y de `puente.env.ejemplo` (hoy 5 s / 50 páginas / intervalo 0,
  que no se quiere con este firmware), y exigir una confirmación explícita para bajar `PUENTE_TERMINAL_INTERVALO_MIN_S` de 1 s.
- **Protección de rama en `main`, `CODEOWNERS` para `.github/workflows/**` y un Environment con revisor**, cuando haya más de un
  desarrollador o plan de pago (hoy decisión del usuario: no).
- **E2, corte de luz duro del Pi (sin apagado limpio):** prueba de durabilidad opcional (WAL, `integrity_check`, candado
  huérfano, outbox sin marcas perdidas ni duplicadas). Riesgo de dañar el sistema de archivos de la tarjeta SD: solo con
  respaldo previo y, mejor, con imagen de la SD, o ya en el equipo definitivo. El caso del apagado limpio (P6) no la necesita.
- **`After=tailscaled.service` en la unidad definitiva** para eliminar la carrera de orden del arranque (hoy el servicio
  espera `network-online.target` y `chrony.service`, pero no a Tailscale; en el arranque real no se manifestó). Es un cambio
  de unidad aparte, con su ventana.
- **Subir la versión del paquete a 0.1.1** en la próxima etiqueta (la telemetría `version_pi` dice `0.1.0` aunque la
  etiqueta es `puente-v0.1.1`); la etiqueta existente no se mueve.
- **Límite de memoria del puente (residuo aceptado en el banco de pruebas).** `MemoryMax=256M` está declarado en la unidad pero el
  kernel del Pi trae `cgroup_disable=memory` de fábrica (`cgroup.controllers` = `cpuset cpu io pids`, sin `memory`), así que el
  tope no se aplica y no existen `MemoryCurrent`/`memory.peak`/`memory.events`; `TasksMax=64` sí se aplica (existe `pids`).
  Medición sustituta: `VmRSS`, `VmHWM` y `Threads` de `/proc/<pid>/status`. Para el EQUIPO DEFINITIVO, antes de usar el puente con
  personas reales (y como verificación previa en el LEEME §3: `grep memory /sys/fs/cgroup/cgroup.controllers` debe imprimir
  `memory`): habilitar el controlador (quitar `cgroup_disable=memory` y añadir `cgroup_enable=memory cgroup_memory=1` en
  `/boot/firmware/cmdline.txt`, una sola línea, con copia del archivo e imagen de la SD y acceso físico) o fijar `LimitDATA=`
  (nunca `LimitAS=`) con un valor holgado sobre el pico medido. Mejora barata: que `operador estado` imprima
  `limite_memoria=aplicado|no_aplicado`; y que muestre «hace X, ya resuelto» junto al diagnóstico 401 histórico (el último 401
  real fue 2026-10-12T19:53:47Z, el del primer arranque).

## 11. Límite de datos del servicio del puente (14 de octubre de 2026)

- **Aplicado** `LimitDATA=384M` (402 653 184 B) con el drop-in `/etc/systemd/system/puente.service.d/20-limite-datos.conf`
  (root:root 0644), como compensación de `MemoryMax=256M` no aplicado (`cgroup_disable=memory`). Regla: `max(384 MiB, 3 × el
  máximo de VmData observado)`; `VmData` observado 68.9 MiB (después 61 MiB) con 5 hilos de 64. Nunca `LimitAS=`
  (`VmSize` ≈ 410 MiB). Hora: 2026-10-14T18:26:19Z (restart 18:26:24Z).
- **Prueba transitoria** (`systemd-run` con las mismas propiedades): importa `puente`, un hilo adicional arranca, y la
  asignación forzada levanta `MemoryError` capturable a 360 MiB (sin ABRT/SEGV).
- **Observación:** chequeos cada 5 min con el mismo PID, `NRestarts=0`, freno limpio, latido en segundos, `fallos_seguidos=0`,
  journals sin `MemoryError`/ABRT/SEGV/EPERM/SIGSYS/status=31; ningún gatillo de reversa.
- **Hash de `systemctl cat puente.service`:** antes `b9b7e904f25f802920fdaef79cbc231cb64e59eb6a5599630c11beb347005eb6`,
  después `8212ca9f…b3dbed`. El `.disabled` del drop-in EPERM y el filtro de syscalls no se tocaron.
- **Pendientes de esta compensación:** pasar `LimitDATA` al archivo de unidad en la próxima etiqueta (y un valor propio para
  `puente-respaldo.service` y las unidades de aviso); verificar en el equipo definitivo `grep memory
  /sys/fs/cgroup/cgroup.controllers` (LEEME §3). Reversa: renombrar el drop-in, `daemon-reload`, `restart`.

## 12. Estado al 15 de octubre de 2026 (~14:10 UTC) para retomar tras compactar

**Cómo retomar:** leer §0, §9, §10, §11 y esta sección; `ListAgents`; pedir a `Checador` el reporte de la revisión de la mañana
(sigue sin llegar; su sesión `Checador [47f0d1]` es Remote Control y no confirma lectura: si no responde, el usuario corre
`ssh -t dhguilleng@100.122.161.26 'sudo bash /home/dhguilleng/verificar-puente.sh'` y pega la salida). Los recordatorios
programados (CronCreate, solo de sesión) ya dispararon todos; no queda ninguno.

**Base de datos (todo aplicado por el usuario con su propio comando; `security` cerró cada corte):** DDL `00` a `106`
(107 archivos), 76 policies, 81 funciones propias (33 `SECURITY DEFINER`, todas con `search_path` fijo), 53 permisos,
`verificar_ddl.sql` 1–71 con la línea base de 10. Aplicados el 14-oct: `101_` (errores sin identidad), `102_` (personas),
`103_` (UPDATE/DELETE inmutables, `anon` sin `personas.permiso`), `104_` (banco de horas: trigger `DEFINER` atómico y RPC
`fn_movimiento_de_saldo_manual_registrar` como única vía de escritura), `105_` (EXECUTE de funciones de trigger y helpers de
RLS) y `106_` (`search_path` de `fn_caller_tiene_permiso`). Reversas guardadas por `db` en su scratchpad (fuera del repo)
durante una semana de uso normal (hasta ~21-oct). **Abierto:** el humo con login real del usuario en la app (todas las
pantallas de lectura, incl. Banco de Horas; reenviar su salida a `security`); grupo E (UPDATE/DELETE de `service_role` en
`tiempo`, sin OK ni prisa); diccionario SCJ-DIC-01 V1.6 completo (hoy V1.5 con nota); primer uso real del movimiento manual de
saldo, supervisado, con sección 68 después. Excepciones documentadas: `public.rls_auto_enable`, `graphql_public.graphql`.

**Puente (`checador-fisico`, `origin/main` = `f00c977`, etiqueta `puente-v0.1.1` = `ba4d825`):** instalado por el flujo verificado
(R1 cumplida), credenciales rotadas, drop-in EPERM retirado (`.disabled` conservado como reversa), `enable` de servicio y timer
hecho (ventana E), reinicio REAL del Pi probado (11/11 criterios: activo en 11 s, `NRestarts=0`, reloj sincronizado en ~39 s,
respaldo de catch-up 0600). `LimitDATA=384M` aplicado el 14-oct 18:26Z (drop-in `20-limite-datos.conf`; hash de `systemctl
cat` antes `b9b7e904…` → después `8212ca9f…`); `MemoryMax` NO se aplica (kernel con `cgroup_disable=memory`): residuo aceptado en
el banco de pruebas, requisito previo para el equipo definitivo (LEEME §3). Último 401 real: 2026-10-12T19:53:47Z.
**Ventana E, estado de cierre:** servidor sano (`raspi-pruebas`, 2487 latidos todos 200, terminal en contacto, 0 marcas, credencial
id 2 en uso desde 100.122.161.26, id 1 revocada). **Matiz abierto:** 25 huecos de latido de 90–159 s en DOS ráfagas
(01:01–02:04Z y 05:35–07:00Z del 15-oct; ninguno supera 300 s ni dispara la tarjeta 15). Hipótesis a confirmar por `Checador`:
cargas periódicas de otras aplicaciones en ese Pi (hay carpetas de conciliación de pagos, dashboards, Nextcloud) o el timer de
respaldo (00:10 CST en la 2.ª ráfaga). Faltan de `Checador`: guion de la mañana, `VmData`/`VmRSS`/`Threads` (comparar con
~61 MiB y 5 hilos), respaldo de las 00:10 con 0600 y rotación 7/30, avisos del journal, `OnFailure`. E se da por cerrada con eso.

**Notion / bóveda (sesión `Asistente`):** creó 39 tareas del piloto (madre P-124, 30 sub-tareas, abiertas sueltas P-125 a P-132)
y cerró P-083, P-050 y P-051 (esta última con nota «por confirmar que ya no queda» la `service_role` key temporal en el Pi del
puente: verificación de solo lectura de `.env` en `~/RTB-CRM-APP` del Pi del puente PENDIENTE). Se le pidió marcar hechas
`101_` a `104_` y crear: humo con login real, primer uso del movimiento manual, EXECUTE, grupo E, V1.6, guardar reversas una
semana. Espejo en `/home/diego/Nextcloud/Sistemas` (12-Pendientes y `Bitacora/2026-10-14_piloto_hikvision_tareas_notion.md`).

**Piloto:** plan en `docs/07-procesos/PLAN_PILOTO_TERMINAL_HIKVISION.md` (un mes, personal avisado, base de pruebas, interruptor
APAGADO, consentimiento provisional; casos P1–P15; al final se limpia el aparato salvo el usuario del dueño y se pasa a otra
base). **Pendiente del usuario:** fecha de inicio y lista de participantes; que TI y RH estén en la primera alta; decidir qué
hacer con su usuario previo en el aparato (vincular o dejar). No hay consentimiento definitivo (no se necesita para el piloto).

**Commits de RTB-CRM-APP:** `origin/main` incluye todo hasta la nota del límite de memoria salvo los que se empujen al final de
esta sección (ver `git log origin/main..main`). Reglas que se mantuvieron: nada se empuja sin revisión de `security` y OK del
usuario; cada escritura en la base real la corre el USUARIO con su comando (el clasificador deniega aplicar a `db`); ninguna
llave o contraseña pasa por el chat; `python3` está bloqueado (usar `uv run python`); los comandos con `!` corren en bash, la
terminal normal del usuario es fish (`set -x VAR (cmd)`, sin heredoc); antes de dar un comando de aplicación, `db` guarda la
reversa y la línea base.

## 13. Cierre del desarrollo y arranque del piloto (15-oct-2026, tarde)

**Decisión del usuario:** el desarrollo del checador (terminal + puente) y de los módulos 1 y 2 se da por CERRADO. El piloto
arranca el **16-oct-2026 con el equipo completo de RTB**. Siguiente paso: sentarse con RH para que vea la interfaz de
retroalimentación y empezar el manual/guía base de la aplicación. `orchestrator` ayuda a generar esa guía base.

**Ventana E: CERRADA y ratificada por `security`.** Servicio sin reinicios espontáneos, recuperación sola tras reinicio real del
Pi, cola en 0, reloj y freno sanos, servidor con 2487 latidos 200. Hallazgo de proceso: `verificar-puente.sh` era ciego a los
logs de la app (sin `--namespace=puente` y filtrando por prioridad: el puente imprime `WARNING` como texto por stdout, journald
lo guarda como info). Corregido en el Pi (copia `verificar-puente.sh.20261015T151737Z.bak`): namespace puente, filtro por texto
`WARNING|ERROR|CRITICAL`, conteo por tipo, primer y último aviso, VmData/VmRSS/VmHWM/Threads, conteo de respaldos.

**25 huecos de latido (90–159 s):** causa = red transitoria entre los dos equipos, ya identificada; no son defecto del puente.
113 latidos fallidos con `ErrorTransitorio` (106 en las dos ráfagas), ~430 `context canceled` en el proxy de `tailscale serve`
del servidor solo en esas horas, cambios de DERP home. Descartados con evidencia: E/S de la SD, subtensión/térmica
(`throttled=0x0`), respaldo (1 s), caída del servidor. Hoy la ruta entre los dos Pi es directa por LAN. Barridos de
reconciliación: 128 en ~23 h (uno cada ~11 min, todos inválidos por `mapa_vacio`/`turno_ocupado`/`servidor_no_disponible`,
lo esperado con el servidor sin altas).

**Telemetría de causa del fallo transitorio (`backend`, ratificada por `security`, SIN commit ni etiqueta):** en
`checador-fisico/puente`, 2587 pruebas. Causas por CLASE (`ReadTimeout`, `ConnectTimeout`, `tls`, `dns`, `rechazada`,
`http_429`, `http_5xx`, `otra`…), racimos con duración y causa dominante, `operador estado` con contadores de 24 h, WARNING
deduplicado e INFO «latido recuperado». Condiciones para empaquetar: versión NUEVA (no 0.1.1: esa etiqueta ya existe y no se
mueve; `pyproject.toml` dice 0.1.0), flujo verificado completo (etiqueta firmada, commit esperado dictado por el usuario,
segunda construcción en CI y en la máquina del usuario, hashes en el acta, ventana de instalación) e incluir en el mismo corte
`LimitDATA` en el archivo de unidad y `limite_memoria=` en `estado`. Banner «ENLACE CON EL SERVIDOR» y CRITICAL periódico para
causas persistentes: propuesta de `security`, NO decidida (futuro).

**Terminal reinstalada en su lugar definitivo (15-oct, ~16:00Z):** ingesta sana (`fallos_seguidos=0`), freno limpio, reloj
sincronizado (+0.8 s / -1.2 s), cursor 184 (subió de 175 por 9 eventos propios de la terminal, sin marcas). El servicio
arrancó de nuevo ~15:42Z: causa por confirmar con el usuario (¿reinicio o corte del Pi al moverla?).

**Observaciones abiertas para el piloto (no bloquean):** (1) `VmData` 61 → 69.3 MiB en ~18 h (~0.5 MiB/h; tope 384 MiB):
medir de nuevo a las 24 y 48 h con el guion corregido; si es lineal es hallazgo; (2) rotación de respaldos 7/30 observable
recién el día 8–9 (~22–23-oct); (3) eventos `major=2` (`minor` 39, 1029, 1030, 1031) sin significado confirmado (el puente
solo los cuenta; hipótesis `minor=39` = caída de red de la terminal, NO verificada; falta catálogo ISAPI o TI); (4) guion
a contar racimos y no líneas cuando entre la versión nueva; (5) el humo con login real en la app sigue siendo la única
condición abierta de `102_`–`106_`.

**Aviso para el piloto con equipo completo:** el plan (`PLAN_PILOTO_TERMINAL_HIKVISION.md`) se pensó para un grupo reducido
de personal avisado. Con todo el personal: confirmar que el consentimiento provisional v1 y el aviso previo al personal
cubren a todos, planear el enrolamiento por oleadas (cada alta caduca a las 168 h y exige TI y RH presentes), y no dar de alta
a nadie sin la persona ya creada en el servidor.

## 14. Primer alta real, brecha del padrón y arranque del piloto (15-oct-2026, tarde-noche)

**Qué pasó.** RH se sentó con el usuario a dar de alta a una persona real (la propia RH) desde la app de pruebas.
Cada paso destapó un defecto, todos cerrados y desplegados el mismo día (commits `b2834f3`, `8d465ba`, `f221743`,
`4965542`, `b6a8d1d`, `46f53c9`, `9df0329`, `d0e65b4`, `b6ca894`, `aaad604`, `ea7882b`; DDL `107_`, `108_`, `109_`
aplicados por el usuario):
1. **Alta no atómica y errores 500** (`POST /api/personas`): RPC `fn_persona_crear` (`107_`) y mapeo 409/422.
2. **Folio `documento_ref`:** la pantalla decía «RTB-__-__»; la base exige `RTB-RH-EIT-AAAA-N`. Corregido y validado en pantalla.
3. **Invitación 422:** `AuthUnknownError` con `http=403` y cuerpo no JSON = WAF de Cloudflare por un `redirect_to` con
   IP literal y `http`. Solución de configuración: `tailscale serve --https=8443` hacia la SPA y `FRONTEND_URL` con el
   dominio con HTTPS primero; Redirect URLs y Site URL de Supabase actualizados. Registro seguro de la causa
   (clase, estado, código de lista cerrada).
4. **Padrón legible por cualquier persona activa** (descubierto porque la persona sin puesto vio todo): `108_`/`109_`.
5. **`/api/sesion` con 500 puntual (57014)** y frontend fail-open: sesión en paralelo, un cliente por petición, 503
   con `Retry-After`; frontend sin `?? true`, ítem «Inicio» y 2FA con emisor del proyecto.

**Verificado en vivo (usuario y RH):** la persona sin puesto aterriza en Inicio, ve solo su fila y configuró su 2FA;
el usuario base ve todo igual. `db` midió con `SET ROLE`: sin puesto 1/1/1/0/0/0/0 filas.

**Línea base nueva de la base:** DDL `00`–`109`, 76 policies, 85 funciones propias (con las de `public`),
`verificar_ddl.sql` 1–74, línea base de 10 conjuntos con filas.

**Abierto antes del piloto con el equipo completo:**
- `110_`: separar nombre de identidad (RLS no filtra columnas: quien tenga cualquier permiso de módulo lee CURP/RFC/NSS
  por la API directa); `111_`: `fn_caller_tiene_permiso` a DEFINER (rendimiento de Tiempo).
- Guarda de pantalla en `/estructura/*` y `/tiempo/*` (`RutaVerificada`), y `signOut` best-effort ante 401.
- Rendimiento: `SyncPostgrestClient.schema()` crea un cliente httpx por llamada; solo se atacó `/api/sesion`.
  Medir la latencia real de `/api/sesion` y vigilar 503 y «error transitorio… se reintenta» la primera semana.
- Copia `~/RTB-CRM-APP/.env.bak-frontend-url-20261015` en el Pi de pruebas (secretos, 0600): borrar.
- Plan del piloto: consentimiento provisional v1, aviso al personal, enrolamiento por oleadas (TI y RH presentes;
  cada alta caduca a las 168 h), fecha de inicio. Guía base de la aplicación (alta de persona y usuario) en
  elaboración con capturas de RH; las capturas no deben llevar CURP/RFC/NSS, enlace de invitación, QR ni clave de 2FA.
- Diccionario SCJ-DIC-01 V1.6 (funciones nuevas y 7 policies) y README de ensayos 107–109.

## 15. Cierre de la identidad y estado para el piloto (16-oct-2026, madrugada UTC)

`110_` (aditiva) y `111_` (cierre) aplicadas por el usuario, ambas con ensayo `BEGIN…ROLLBACK` (17/17 y 28/28, batería de
equivalencia de 22 casos de crear/actualizar idéntica antes y después) y revisión de `security`. Desde `111_`,
`authenticated` solo lee 9 columnas de `personas.persona` (id, nombres, apellidos, estado, fecha_ingreso, fecha_baja,
actualizado_en); CURP/RFC/NSS/fecha de nacimiento solo salen por `personas.fn_persona_identidad` (propia persona o
conjunto estricto) y por `service_role`/dueño. Backend `ee21e8d` y frontend desplegados antes de aplicar `111_`.
Verificador 1–76, línea base de 10, 87 funciones propias (con las de `public`), 76 policies. Regla nueva: toda columna
nueva de `persona` necesita su `GRANT SELECT` de columna o declararse de identidad (sección 76).

**Vigilancia:** 42501 «permission denied for table persona» en logs del backend (reversa instantánea
`GRANT SELECT ON personas.persona TO authenticated;`) y, al día siguiente, que los jobs programados (cierre de día,
corte, de confianza) no lo hayan registrado. **Pendiente:** `112_` (`fn_caller_tiene_permiso` a DEFINER, rendimiento de
Tiempo), guarda de pantalla en `/estructura/*` y `/tiempo/*`, rendimiento de `schema()` de postgrest-py en el resto de
endpoints, medir la latencia de `/api/sesion`, borrar `.env.bak-frontend-url-20261015` del Pi de pruebas, diccionario
V1.6, y del piloto: consentimiento provisional v1, aviso al personal, enrolamiento por oleadas y fecha.
