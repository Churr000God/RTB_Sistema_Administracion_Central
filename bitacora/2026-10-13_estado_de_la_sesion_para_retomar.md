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
