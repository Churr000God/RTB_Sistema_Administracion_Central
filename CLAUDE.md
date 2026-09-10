# CLAUDE.md

Instrucciones que se cargan cada sesión para trabajar en `sistema-control-jornada`.

## Qué es el proyecto

Sistema de Control de Jornada (SCJ) — proyecto académico, caso de estudio *Distribuidora Central,
S.A. de C.V.* (empresa ficticia). Cubre el modelo de datos del subsistema de Tiempo, más un
backend y un frontend que lo exponen. Ver `README.md` y `docs/00-contexto/SCJ-CTX-01_*.md`.

## Stack y cómo correrlo

- **Base de datos:** Supabase (Postgres administrado, extensión `btree_gist`), esquemas
  `personas` y `tiempo`, ambos con DDL real (decisión de sesión 2026-08-31: `personas` ya no es
  sólo stub — ver `bitacora/2026-08-31_campos_persona.md`). El stub original de `tiempo.persona`
  se mantiene como ancla de la frontera (`SCJ-FRO-01`); `personas.persona` es la implementación
  completa. **No hay Postgres local ni contenedor de base de datos** — el DDL de `db/ddl/` corre
  contra el proyecto de Supabase, vía `psql "$DATABASE_URL"` o pegado en su SQL Editor.
  Configuración en `.env` (plantilla en `.env.example`). Pasos completos en `README.md`
  §"Cómo levantar el proyecto".
- **Generador de datos sintéticos:** Python, en `tools/generador/` — carpeta vacía por ahora
  (`SCJ-GEN-01`, entregable `E5`). Se invoca con `uv run python generar.py ...`, no `python3`
  directo: `python3` está bloqueado por un hook de este entorno.
- **Backend:** FastAPI + `supabase-py` v2, en `backend/app/` (routers/schemas/deps/config).
  Manual: `cd backend && uv run uvicorn app.main:app --reload --port 8000`. Tests:
  `uv run pytest`. Lee `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
  `FRONTEND_URL` del `.env` de la raíz (no lee `DATABASE_URL`, eso es sólo para `psql`/DDL manual).
  `FRONTEND_URL` acepta varios orígenes separados por coma desde el 6 de septiembre de 2026
  (`parse_frontend_urls` en `config.py`/`main.py`) — sirve para trabajar por `localhost:5173` y por
  una IP de Tailscale/LAN al mismo tiempo sin reiniciar; ver ejemplo en `.env.example`. El link de
  invitación de usuarios (`routers/usuarios.py`) toma sólo el primero de la lista, necesita una
  única URL.
- **Frontend:** Vite + React + TypeScript, en `frontend/src/` (pages/layouts/router). Manual:
  `cd frontend && npm run dev` (puerto 5173). Tests: `npm test`. `diseno_paginas/` guarda el
  diseño de pantallas (mockups "Kairos") previo a implementarlas — sigue siendo la referencia
  visual mientras dure el QA módulo por módulo. `lucide-react` es la única librería de iconos del
  proyecto (sumada en el QA de auth de 2026-09-03 para replicar la capa decorativa de los
  mockups de login/2FA/recuperación de contraseña). Los correos de contacto que la app muestra
  (Recursos Humanos, Sistemas, Administración, Dirección) son configurables por variable de
  entorno — `VITE_CONTACTO_RH_CORREO`, `VITE_CONTACTO_SISTEMAS_CORREO`,
  `VITE_CONTACTO_ADMINISTRACION_CORREO`, `VITE_CONTACTO_DIRECCION_CORREO` en `frontend/.env.example`
  — nunca hardcodeados en el código de las páginas. Sólo frontend las usa (el backend no envía
  correos, delega 100% en Supabase Auth). Mismo gotcha que las demás `VITE_*`: en prod son de
  build, cambiar el valor exige `--build`, no basta reiniciar el contenedor.
- **Docker:** `./scripts/desplegar.sh [dev|prod] <levantar|bajar|reconstruir|registros|pruebas|estado>`
  levanta backend + frontend con `docker compose` (dev con hot reload, prod con nginx sirviendo el
  build). No hay contenedor de base de datos — sigue siendo Supabase remoto. Las `VITE_*` del
  frontend son variables de **build**, no de runtime: cambiarlas en prod exige `--build`, no basta
  reiniciar el contenedor. `prod pruebas` **no existe** — la imagen prod del backend se instala con
  `--no-dev` (sin pytest) y el frontend prod es nginx sirviendo el bundle (sin npm/node); el script
  corta con un mensaje explícito en vez de fallar con un error de `docker exec`. Las pruebas
  siempre corren con `dev pruebas`.
- **Tests:** backend `uv run pytest` (393 casos), frontend `npm test` (458 casos, 60 archivos).
  Ambos corren igual dentro de los contenedores (`./scripts/desplegar.sh <entorno> pruebas`).
  Cobertura instrumentada desde el 4 de septiembre de 2026: `uv run pytest --cov=app
  --cov-report=term-missing` (backend) y `npm run test:coverage` / `npm test -- --coverage`
  (frontend) — medición habilitada, sin umbral mínimo forzado todavía. `backend/.coverage` y
  `frontend/coverage/` son artefactos generados, no se versionan.
- **CI:** `.github/workflows/ci.yml` (agregado 4 de septiembre de 2026) corre backend (`uv run
  pytest`) y frontend (`vitest run`) en cada push/PR — sin secrets de Supabase (todos los tests
  mockean el cliente de Supabase, ninguno pega contra el proyecto real). No hace deploy, sólo
  valida.
- **Módulo Personas y Usuarios (`SCJ-PRO-01`/`SCJ-PRO-02`):** entregado el 3 de septiembre de 2026,
  de punta a punta (backend + frontend + DDL de `personas`). Puesto/área/departamento/permiso/
  asignación quedaron **fuera de alcance a propósito** — no asumir tablas ni endpoints de eso.
  **QA manual completado el 4 de septiembre de 2026** contra las 14 pantallas de
  `diseno_paginas/personas/` (incluida la bitácora de movimientos, pantalla nueva); sumó el
  endpoint `GET /api/sesion` para el enforcement real de cuenta suspendida (antes sólo existía
  el bloqueo de RLS, sin feedback en la UI). Ver `bitacora/2026-09-04_qa_personas_mockups.md`.
  **Segundo bloque de fixes, mismo día**: login centrado en pantallas grandes, CURP/RFC
  normalizados a mayúsculas (frontend y backend), fix de usuario huérfano en Supabase Auth si
  fallaba el insert tras la invitación, auditoría de inyección SQL sin hallazgos (el diseño ya la
  cubre por construcción: `supabase-py` parametrizado + Pydantic), pasada de calidad visual en
  09-14 y fix del bug real de "Alta de usuario" inalcanzable (ahora hay botón "Crear acceso a
  Kairos" en la ficha, condicionado al campo `tiene_usuario` de `GET /api/personas/{id}`). Ver
  `bitacora/2026-09-04_qa_personas_fixes.md`.
- **Módulo Estructura Organizacional (`SCJ-PRO-03/04/05`):** entregado el 4 de septiembre de 2026,
  de punta a punta, en 5 cortes delegados al equipo (`area` → `departamento` → `puesto` →
  `asignacion` → `puesto_permiso`, commits `847fa96`/`628587f`/`2e14b46`/`3de346f`/`d3997cb`).
  Catálogo de 16 permisos (`personas.permiso`, única tabla del proyecto con `codigo varchar` como
  `PRIMARY KEY`), otorgar/revocar con validación real de auto-otorgamiento y herencia jerárquica,
  y un mecanismo de "usuario base de bootstrap" en `./scripts/desplegar.sh` (crea un usuario con
  todos los permisos al desplegar desde cero, credenciales por prompt interactivo, nunca en
  `.env` — ver memoria de proyecto `usuario-base-bootstrap`). **El gate de permisos real YA ESTÁ
  conectado** (commit `a52b534`, mismo día): `backend/app/permisos.py` resuelve los puestos
  vigentes del caller y la herencia jerárquica (el jefe hereda lo del subordinado), y
  `requiere_permiso(...)` (primer `403` del proyecto) gatea los 7 routers relevantes —
  `areas`/`departamentos`/`puestos`/`asignaciones`/`permisos` (lectura exige lectura-o-edición,
  escritura exige edición) y `personas`/`usuarios`/`movimientos` (sólo sus `POST`, con
  `alta_personas_usuarios`/`cambio_estado_persona` — sus `GET` siguen con el gate débil a
  propósito, el catálogo de 16 permisos no tiene código de lectura para ese módulo).
  `GET /api/sesion` expone `puede_ver_modulo_1`/`puede_ver_modulo_2` para que el sidebar oculte
  grupos completos sin permiso (fail-open si la sesión no carga). Primer `CREATE OR REPLACE
  FUNCTION` y primer RPC del proyecto (`fn_asignacion_cambiar_puesto`) aparecieron en el corte de
  `asignacion`. La base se **wipeó y reconstruyó por completo** el mismo día (`DROP SCHEMA
  personas/tiempo CASCADE` + reaplicación de todo el DDL versionado, `auth.users` vaciado vía
  Admin API) para eliminar 4 cuentas de desarrollo que la inmutabilidad de la bitácora hacía
  imposible borrar quirúrgicamente — el único usuario que queda es el usuario base de bootstrap,
  con los 16 permisos y 2FA configurado. Ver
  `bitacora/2026-09-04_modulo_{area,departamento,puesto,asignacion,puesto_permiso}.md` para el
  detalle de cada corte.
- **Pase de mejora cross-stack con equipo de 6 especialistas (4 de septiembre de 2026):** con el
  gate de permisos ya conectado, el usuario pidió una pasada de optimización orquestada —
  `orchestrator` coordinó por `SendMessage` a 6 sesiones persistentes (`frontend`/`backend`/`db`/
  `testing`/`security`/`devops`, roster fijo de `team-orchestrator`) para que cada una explorara y
  mejorara su dominio con sus propias skills, sin commitear nada individualmente (commits
  batcheados al final por dominio, revisados por `orchestrator`). Resultado: capa de componentes
  UI reutilizables en frontend (`Button`/`Card`/`Badge`/`Input`, `frontend/src/components/`,
  primera vez que el proyecto tiene componentes compartidos más allá de `CasilleroCodigo`/
  `TemporizadorTotp`) usada para migrar las 17 páginas de Estructura Organizacional (construidas
  sin mockup) más el rediseño de `Configurar2FAPage` (era la única pantalla de auth sin nivelar al
  resto); helper `backend/app/errores.py` deduplicando el patrón `APIError` 23505 → `409` de 4
  routers; 21 índices FK nuevos (`db/ddl/30_indices_fk.sql`); cobertura instrumentada (ver más
  arriba); CI agregado (ver más arriba). Ver `bitacora/2026-09-04_pase_mejora_cross_stack_equipo.md`
  para el detalle completo, incluido el hallazgo de seguridad crítico documentado abajo.
- **QA en vivo + protección del puesto administrador (5 de septiembre de 2026):** el usuario probó
  la app en el navegador y pidió una larga serie de ajustes de UI en Estructura Organizacional y
  Permisos (organigrama interactivo por `reporta_a_id` — componente compartido
  `frontend/src/components/Organigrama.tsx`, CSS/SVG puro sin librería de diagramas, usado en
  `AsignacionesPage`/`DirectorioPuestosPage`; patrón de carga real con `Button`
  `cargando`/`textoCargando` que bloquea doble submit, aplicado a 17 pantallas). De paso, dos
  hallazgos reales: (1) "Encargado de TI" (puesto real del organigrama, `16_*.sql`) y "Gerente o
  Encargado de TI" (fixture de bootstrap, `26_*.sql`) eran dos conceptos separados a propósito que
  parecían un duplicado — unificados en el seed, quedó sólo el segundo; (2) pedido de seguridad
  para que el puesto administrador (`personas.puesto.es_administrador_generico`, columna nueva,
  inmutable por trigger) no pueda quedar sin acceso — ver gotcha abajo. Ver
  `bitacora/2026-09-05_pulido_permisos_estructura_y_proteccion_admin.md` para el detalle completo.
- **Módulo Tiempo, los 8 procesos completos (`SCJ-PRO-07` a `SCJ-PRO-14`, 6 de septiembre de
  2026):** entregado de punta a punta por el equipo de 6 especialistas vía `team-orchestrator`, en
  4 fases con checkpoint del usuario entre cada una, siguiendo el orden de
  `docs/07-procesos/PLAN_IMPLEMENTACION_TIEMPO.md` — **Fase 1** `SCJ-PRO-09` (Asignación de
  jornada) → `SCJ-PRO-14` (Batch de confianza, estrena la orquestación compartida de los 3
  batches); **Fase 2** `SCJ-PRO-11` (Registro por terminal, sólo verificación) → `SCJ-PRO-07`
  (Captura manual de marca); **Fase 3** `SCJ-PRO-10` (Corrección de marca) y `SCJ-PRO-08`
  (Detección de falta), en paralelo; **Fase 4** `SCJ-PRO-12` (Cierre de día) → `SCJ-PRO-13` (Corte
  quincenal), las 2 piezas de mayor riesgo/impacto financiero. `db/ddl/` llega hasta `57_*.sql`.
  Backend suma 8 routers (`jornada_asignada`, `corridas_batch`, `marcas`, `correcciones`,
  `ausencias`, `excepciones`, `banco_de_horas`) + 3 batches (`de_confianza`/`cierre_dia`/
  `corte_quincenal`, `backend/app/batches/`) orquestados con **APScheduler embebido en el lifespan
  de FastAPI** (`backend/app/scheduler.py`, sin cron externo ni infraestructura nueva — el mismo
  job programado y el botón manual invocan la misma función). Frontend suma 6 páginas bajo
  `/tiempo/*`, sidebar con los grupos "Jornadas"/"Marcas"/"Autorizaciones"/"Reportes" (placeholders
  que ya existían deshabilitados, activados en vez de crear grupos nuevos), todos gateados por el
  mismo `puede_ver_modulo_3`. 3 RPC transaccionales nuevos (mismo patrón que
  `fn_asignacion_cambiar_puesto`): `fn_jornada_asignar_renovar`, `fn_ausencia_resolver`,
  `fn_corte_quincenal_aplicar_persona` — los 3 nacieron de encontrar, en la revisión de seguridad
  de cada fase, que un endpoint escribía en más de una tabla relacionada con inserts sueltos sin
  transacción real. Ver `bitacora/2026-09-06_implementacion_subsistema_tiempo.md` para el detalle
  completo, incluidos los hallazgos de seguridad corregidos en el camino (ver gotcha abajo) y lo
  que quedó pendiente a propósito (relleno de día bloqueado, `SCJ-PRA-01 #14`).
- **Módulo Parámetros de Tiempo, 3 de 4 pantallas (7 de septiembre de 2026):** auditoría
  previa confirmó que `tiempo.parametro`/`tiempo.dia_festivo`/`tiempo.tope_legal` (tablas de
  configuración del DDL desde `02_tiempo.sql`) nunca tuvieron pantalla propia — sólo se
  consumían internamente. Nuevo grupo de sidebar "Parámetros" (gateado por el mismo
  `puede_ver_modulo_3`). **Tope legal**: edición como vigencias versionadas (RPC
  `fn_tope_legal_crear_vigencia`, `db/ddl/59_*.sql`, mismo patrón que
  `fn_jornada_asignar_renovar`) + tabla de personas que superan el tope por semana, con 3
  comparaciones independientes (`supera_semanal`/`supera_extra`/`supera_combinado`, cruzando
  `tiempo.clasificacion_de_tiempo.tipo`) sobre horas *reales* trabajadas, no el patrón
  contractual — regla de negocio documentada en `docs/03-decisiones/SCJ-DEC-10_*.md`. **Días
  festivos**: CRUD sin migración DDL nueva (tabla/RLS/permisos ya existían) — alta libre,
  `DELETE` (primer del proyecto) restringido a `fecha > hoy` estricta; dos vistas, Lista (filtros
  client-side, catálogo chico) y Calendario (Mensual/Semanal, primer calendario de mes del
  proyecto, `frontend/src/lib/calendario.ts`). Ambas pantallas usan `get_service_client` para
  todo el acceso a datos (RLS deny-all en `tope_legal`/`dia_festivo`), `get_caller_client` sólo
  para el gate de `requiere_permiso(...)`. **Parámetros del sistema** (mismo día, corte
  posterior, vía `team-orchestrator` con 4 especialistas): edita las 8 claves de
  `tiempo.parametro` como vigencias versionadas, RPC `fn_parametro_actualizar_valor`
  (`db/ddl/60_*.sql`) con **borde inclusivo** (`vigente_hasta = nueva.vigente_desde - 1`,
  divergente del semiabierto de `SCJ-DEC-04`, anotado ahí como decisión deliberada) y
  `vigente_desde` siempre hoy — sin alta/baja de claves, sólo edición de valores existentes. Dos
  cambios del mismo parámetro el mismo día son un `UPDATE` in-place, no una vigencia nueva.
  Catálogo de descripción/tipo/unidad vive en código (`backend/app/catalogo_parametros.py`), no
  en columnas — de las 8 claves, sólo 3 (`tolerancia_retardo_min`, `dias_habiles_correccion_marca`,
  `hora_corrida_cierre_dia`) tienen efecto real en la lógica hoy, marcado en la UI con un badge
  para las otras 5. Historial con búsqueda/rango de fechas/orden 100% client-side (dataset chico).
  Falta "Movimiento de saldo" (cuarta pantalla, pendiente). Ver
  `bitacora/2026-09-07_modulo_parametros_tope_legal_dias_festivos.md` (incluido un incidente real
  de una sesión corriendo un RPC directo contra la BD real para depurar un bug, ver gotcha abajo)
  y `bitacora/2026-09-07_parametros_del_sistema.md` (primer intento fallido de agente `Plan` del
  proyecto, colgado 600s sin progreso — el plan se escribió a mano con la exploración ya hecha).
- **Registro de marcas: hora del dispositivo editable y motivo de revisión visible (7 de
  septiembre de 2026, mismo día, corte posterior):** `momento_dispositivo`/`desfase_local`/
  `motivo_revision` ya existían desde la reconciliación del 5 de septiembre — lo que faltaba era
  que captura manual dejara de forzar `momento_dispositivo = momento_recepcion = now()` (perdía la
  hora real del evento) y que la UI expusiera esos campos. `db/ddl/61_*.sql` endurece la policy
  `marca_insert_captura_manual` con techo duro de 90 días + no futuro + `estado_reloj =
  'sincronizado'` (RLS es la autorización real en `routers/marcas.py`, que usa
  `get_caller_client`). Backend valida la ventana fina de días hábiles
  (`dias_habiles_correccion_marca`, helper compartido movido a `app/dias_habiles.py`) y expone
  `motivos_revision` en `GET /api/marcas`; catálogo de los 6 motivos reales en
  `app/catalogo_motivos_revision.py`, espejado en frontend por `lib/motivosRevision.ts` (que
  separa el sufijo que `fn_ausencia_resuelve_excepcion` concatena al resolver una excepción). Ver
  `bitacora/2026-09-07_registro_marcas_hora_dispositivo.md`.
- **Módulo Tramos y Días, primera escritura humana sobre `tiempo.tramo`/`tiempo.dia` (8 de
  septiembre de 2026):** ninguna de las dos tablas tenía pantalla propia. `GET /api/tramos` +
  `TramosPage.tsx` primero (búsqueda/filtros/orden/paginación, embed `dia:dia_id!inner(...)` para
  fecha/persona/estado sin segunda consulta). Después, en cortes sucesivos guiados por el usuario
  probando en vivo: botón "Corregir" en Registro de marcas gateado por `excepcion_pendiente_id`
  (no por `requiere_revision`, que es una bandera de una sola vía); `momento_efectivo`/
  `estado_revision` en `GET /api/marcas` para que "Ocurrió" y el badge reflejen la corrección real.
  **Pantalla Días** (`db/ddl/62_*.sql`): primer permiso de *acción* `dia_revision_edicion`
  (heredable, RH/Gerente General/TI) + policy asimétrica + RPC `fn_dia_revisar` — la única
  transición manual que permite `SCJ-DEC-06` (`bloqueado → revisado`), con columnas de auditoría
  nuevas `revisado_por`/`revisado_en`. `GET /api/dias` suma primera/última marca efectiva y dos
  alertas de horario direccionales e independientes (`backend/app/alertas_horario.py`, módulo
  nuevo — corrige 3 gaps reales de `alertas_de_retardo.py` sin tocar esa pantalla). Horas al
  revisar: **RH las escribe a mano** (`db/ddl/63_*.sql`, `p_horas_totales`), nunca auto-calculadas
  a ciegas, con un botón "Calcular tiempo total" que sugiere el valor antes de confirmar
  (`db/ddl/65_*.sql`, `fn_dia_calcular_armado_tramos` de sólo lectura, reusada por el RPC real).
  `db/ddl/64_*.sql` abrió el primer camino de escritura humana sobre `tiempo.tramo` (hasta entonces
  cero policies de escritura): al revisar, arma los tramos que quedaron con marcas huérfanas
  (llegadas después del bloqueo) — si quedaría una marca sin pareja, bloquea todo el revisar
  (`ERRCODE SCJ09`) en vez de inventar un cierre. `db/ddl/` llega hasta `67_*.sql`. Ver
  `bitacora/2026-09-08_modulo_tramos_y_dias.md`.
- **Descuento de pausa unificado + rediseño de Ausencias (8 de septiembre de 2026, mismo día, 2
  cortes):** `tiempo.parametro.descuento_pausa_no_registrada_min` (sembrado hace semanas sin
  consumidor) gana su primer uso real: `cierre_dia.py` lo resta de `horas_totales` cuando un día
  resulta en un solo tramo (sin pausa marcada), sin importar tipo de jornada.
  `fn_ausencia_resuelve_excepcion` (`db/ddl/66_*.sql`) deja de restar `patron_semanal.minutos_comida`
  y pasa a restar el mismo parámetro global — un solo concepto de "descuento por pausa" en todo el
  sistema. Excepción deliberada a `SCJ-PRO-14` ("de confianza siempre `NULL`"): cualquier ausencia
  resuelta de una persona `de_confianza`, incluso rechazada, pone la jornada completa neta, nunca
  `0` — documentada en el propio proceso, ver gotcha de `CREATE OR REPLACE FUNCTION` abajo.
  **Ausencias** pasa de tarjetas-sólo-pendientes a tabla completa (`GET /api/ausencias` nuevo, con
  columna "Aprobado por" resuelta desde `tiempo.aprobacion_ausencia`) con leyenda de los 5 tipos —
  el schema que el usuario propuso en 2 diagramas ER ya existía casi exacto en la base real, sólo
  se construyó pantalla y listado. `corte_quincenal.py` sigue sin ver este descuento (divergencia
  conocida y aceptada, no se toca cálculo de nómina sin pedido aparte). Ver
  `bitacora/2026-09-08_rediseno_ausencias_y_descuento_pausa.md`.
- **Jornada Asignada: fila expandible + bug real de vigencias solapadas (8 de septiembre de 2026,
  mismo día, corte final):** rediseño de `AsignarJornadaPage.tsx` (3 mockups interactivos, usuario
  eligió fila expandible con el patrón semanal — `DetalleJornadaAsignada.tsx` nuevo, compartido con
  `FichaPersonaPage.tsx`; formulario colapsable). Sin backend nuevo. El usuario, probando en vivo,
  encontró un bug real: renovar la jornada dos veces el mismo día dejaba `vigente_hasta` **antes**
  del propio `vigente_desde` de esa fila (`fn_jornada_asignar_renovar` calcula `vigente_hasta =
  nueva.vigente_desde - 1`, sin contemplar vigencias que empiezan el mismo día). Cazado con logging
  temporal real (retirado después) tras descartar RLS/doble-submit/payload obsoleto de escritorio.
  Fix en `db/ddl/67_*.sql`: `ERRCODE SCJ02` nuevo rechaza el caso antes de escribir, más
  `CHECK ck_jornada_asignada_vigencia` como red de seguridad a nivel base. Ver
  `bitacora/2026-09-08_jornada_asignada_rediseno_y_bug_vigencia.md`.
- **Banco de Horas: desglose de antigüedad del saldo (8 de septiembre de 2026, corte posterior,
  sin DDL):** `tiempo.banco_de_horas.vivo_desde` es un único timestamp por persona (se resetea a
  `NULL` cuando el saldo toca 0) — no distingue horas viejas de nuevas dentro de la misma persona.
  `backend/app/banco_antiguedad.py` (nuevo) reconstruye el desglose 0-3/3-6/6+ meses con FIFO puro
  sobre el ledger `tiempo.movimiento_de_saldo` (append-only, ya existía desde `02_tiempo.sql`, sin
  migración nueva), usando `ventana_banco_meses` — primer consumidor real de ese parámetro,
  sembrado desde hace semanas sin nadie que lo leyera. Reconciliación explícita contra
  `banco_de_horas.monto`: si el FIFO no cuadra, `conciliado=false` y cae a un fallback por
  `vivo_desde` en vez de esconder la desalineación (el hueco que `SCJ-DEC-02` ya documentaba sin
  resolver). `GET /api/banco-de-horas` pasa de un array plano sin filtros a
  `{total, resumen, saldos}` paginado/filtrable/ordenable — filtro y orden por tramo de antigüedad
  se hacen en memoria (el desglose no es una columna real, no hay `.range()`/`.order()` de
  PostgREST posible sobre eso). Cambio de postura deliberado: pasa de `get_caller_client` a
  `get_service_client` con dos permisos exigidos explícitos (`banco_de_horas_lectura` AND
  `movimiento_de_saldo_lectura`-o-`edicion`) — con el gate viejo, alguien sin permiso sobre el
  ledger habría visto toda la antigüedad en cero sin ningún error. `GET
  /api/banco-de-horas/{persona_id}/movimientos` nuevo alimenta una fila expandible con el ledger
  completo de la persona. Métricas y gráfica "Top en deuda" de la pantalla se conservaron, ahora
  alimentadas por el `resumen` del backend en vez de un `useMemo` local (corrige de paso que antes
  no reaccionaban a la búsqueda).
- **Alertas preventivas de corte quincenal en Días y Banco de Horas (8 de septiembre de 2026,
  corte posterior, sin DDL):** el usuario preguntó por qué "Encargado de Sistemas" no tenía fila en
  Banco de Horas — investigando eso se encontró que ningún código del proyecto escribe nunca
  `tiempo.dia` con `estado='abierto'` (grep exhaustivo: `cierre_dia.py`/`de_confianza.py`/
  `fn_ausencia_resuelve_excepcion` siempre escriben `cerrado`/`bloqueado` explícito; `'abierto'` es
  sólo el `DEFAULT` de la columna sin escritor real). En la práctica, lo que bloquea el corte
  quincenal (`_procesar_persona`, `PENDIENTE_DIA_ABIERTO`) casi siempre es una **fila ausente**
  (persona con cero marcas ese día) — el hueco ya anotado a propósito como pendiente en
  `SCJ-PRA-01 #14` ("relleno de día bloqueado"). Esto invalidó el primer diseño ("badge en la fila")
  para la alerta de Días — no hay fila que marcar en el caso real — así que pasó a ser un **banner
  resumen** con persona + fecha(s) faltantes del periodo en curso. Nuevo módulo compartido
  `backend/app/prevision_corte_quincenal.py` reusa `_procesar_persona` de `corte_quincenal.py` (kwarg
  nuevo `solo_simular=True`, sin tocar su comportamiento por defecto — los 2 call-sites de
  `_aplicar_persona` quedan detrás de `if not solo_simular`) en vez de reimplementar la
  elegibilidad de periodo/jornada/festivos — mismo criterio que evitó una tercera reconstrucción de
  "hora local" al crear `alertas_horario.py`. `GET /api/dias/pendientes-corte-quincenal` (nuevo)
  para el banner de Días; `GET /api/banco-de-horas` suma `corte_pendiente` por persona para el
  **último periodo ya vencido**, con fila sintética (`monto=0`) para quien nunca tuvo fila real en
  `tiempo.banco_de_horas` — antes esas personas eran invisibles en la pantalla. Es diagnóstico, no
  arregla nada: no crea días ni dispara ningún corte, el hueco de `SCJ-PRA-01 #14` sigue abierto.
- **Movimiento de saldo manual — renovar/descontar/condonar deuda vieja (8 de septiembre de 2026,
  corte posterior):** cierra el pendiente más viejo del proyecto ("cuarta pantalla" de Parámetros
  mencionada desde el 7 de septiembre, nunca construida). `db/ddl/68_*.sql` — primera vía de
  escritura humana sobre `tiempo.movimiento_de_saldo` (hasta entonces sólo tenía policy de SELECT,
  el único escritor real era el batch de corte quincenal con `service_role`): policy RLS de INSERT
  nueva + RPC `fn_movimiento_de_saldo_manual_registrar` (`SECURITY INVOKER`, gateado por el permiso
  `movimiento_de_saldo_edicion` ya sembrado desde semanas atrás sin ningún consumidor). Semántica
  de negocio confirmada con el usuario tras una ronda de preguntas (su propio texto tenía
  incertidumbre real sobre "cubrir"/"arrastrar"): **"Renovar antigüedad"** (persiste
  `tipo='arrastrar'`, nunca `'cubrir'` — esa palabra ya significa "repago real" en el batch
  automático y no se reutiliza para evitar un significado ambiguo) NO reduce el saldo total —
  inserta un par de filas (`-monto`/`+monto`, mismo `motivo`, mismo `creado_en` porque `now()` es
  estable dentro de una transacción) en una sola transacción, que el FIFO ya existente en
  `banco_antiguedad.py::calcular_lotes` procesa sin ningún cambio (la fila vieja se consume, la
  nueva abre un lote fechado hoy). **"Descontar"/"Condonar"** sí reducen el saldo de verdad (una
  sola fila) — sólo difieren en significado (descontar es campo para un futuro módulo de nómina,
  condonar no genera ninguna consecuencia). Validación en 2 capas: Python topa el monto contra la
  porción con 6+ meses de antigüedad de esa persona (recalculada al momento, nunca confía en algo
  cacheado del frontend) antes de llamar al RPC, que sólo puede topar contra el saldo total como
  backstop grueso (no tiene el FIFO). El endpoint usa 2 clientes Supabase distintos a propósito
  (`service_role` para leer el insumo de la validación, el caller sólo para el INSERT real) — ver
  gotcha nuevo abajo. Formulario dentro de la fila expandible del ledger que ya tenía Banco de
  Horas (sin pantalla ni ruta nueva), visible sólo si la persona tiene deuda fuera de la ventana.
- **Parámetros del sistema 100% dinámicos + corridas batch con fecha/bloqueo horario (9 de
  septiembre de 2026, cuatro cortes independientes):** cierra los últimos huecos de "6"
  hardcodeado en `ventana_banco_meses` (mensaje de error del 422 con `{meses}` interpolado,
  badge del catálogo corregido, frontend usa piso entero `Math.floor` para la mitad de la ventana
  — antes usaba división real y mentía con ventana impar). **Corridas batch**: el panel de
  `/tiempo/corridas-batch` gana selector de fecha por botón (backend ya aceptaba `fecha` opcional,
  el frontend nunca la mandaba) y el disparo manual de `cierre_dia` rechaza fecha futura siempre y
  fecha de hoy antes de `hora_corte_dia + hora_corrida_cierre_dia` (nuevo
  `backend/app/hora_cierre_dia.py`, primer consumidor real de `hora_corte_dia`). De paso se
  encontró y arregló un **bug real del scheduler**: el job programado de `cierre_dia` corría a las
  03:00 pasando `date.today()` en vez del día anterior — procesaba un día de tres horas de vida,
  sin marcas, generando faltas falsas; contradecía tanto el texto de la UI como
  `prevision_corte_quincenal.py`, que ya asumía la semántica correcta. Corregido a
  `date.today() - timedelta(days=1)`; `de_confianza`/`corte_quincenal` siguen sin cambio.
  **Alerta de magnitud de deuda en Banco de Horas**: el pedido original era ampliar Alertas de
  retardo con `umbral_aviso_pct`/`umbral_escalamiento_pct` — la investigación encontró que esos
  parámetros son el segundo eje de alerta del Banco de Horas por especificación (`SCJ-ESP-01
  §VI.6`, magnitud de la deuda como % de la jornada semanal, complementando el eje de antigüedad
  que ya existía), no de retardo; confirmado con el usuario, Alertas de retardo no se tocó. Nuevo
  `backend/app/banco_alertas_magnitud.py` (`jornada_semanal_horas` reusa el cálculo de
  `jornada_asignada.py::_horas_patron`, nunca la columna `horas_semanales_calculadas` que está
  siempre `NULL`); cada saldo suma nivel `sin_alerta`/`aviso`/`escalamiento`, badge, filtro y
  tarjetas de resumen. Con este corte **las 8 claves del catálogo de parámetros quedan con
  consumidor real** — cero badges "Sin efecto en la lógica actual" en la pantalla de Parámetros.
  **Fix de UI**: Alertas de retardo mandaba la petición igual si el usuario borraba el rango de
  fechas (`desde`/`hasta` son requeridos sin default en ese endpoint, a diferencia de Tramos/Días)
  — 422 y pantalla de error genérica; ahora corta antes del fetch con un mensaje que invita a
  completar el rango. Ver
  `bitacora/2026-09-09_parametros_dinamicos_completos_y_corridas_batch.md` para el detalle
  completo de los 4 cortes.
- **Edición de datos de persona y expediente (10 de septiembre de 2026):** el módulo Personas era
  append-only — sólo alta y cambio de estado, sin vía para corregir CURP/RFC/NSS/nombre/fechas
  tras el alta. Nuevo permiso `persona_edicion` (`db/ddl/69_*.sql`), RPC transaccional
  `fn_persona_actualizar_datos` (`SECURITY INVOKER`, nunca toca `estado`/`fecha_baja`),
  `PATCH /api/personas/{id}` gateado por `requiere_permiso("persona_edicion")`, edición in-place
  en `FichaPersonaPage.tsx` (mismo patrón de `FichaAreaPage`/`FichaDepartamentoPage`/
  `FichaPuestoPage`). Sin auditoría de ediciones por ahora (decisión deliberada). `db/ddl/` llega
  hasta `70_*.sql` — el `70_*.sql` es un fix de seguridad real encontrado por `security` antes de
  commitear: el `OR` de `persona_update_requiere_permiso` (`cambio_estado_persona OR
  persona_edicion`) no distinguía qué columnas tocaba el UPDATE, así que cualquiera con sólo
  `cambio_estado_persona` podía reescribir identidad completa vía PostgREST directo — mismo
  patrón del hallazgo ya documentado sobre `31_*.sql`. Corregido con un trigger `BEFORE UPDATE`
  (`trg_persona_protege_columnas_identidad`), porque el `WITH CHECK` de una policy RLS de UPDATE
  sólo ve la fila nueva, nunca la anterior — comparar OLD/NEW exige trigger, no se puede resolver
  sólo con RLS. Ver `bitacora/2026-09-10_edicion_personas_expediente.md`.
- **Subproyecto del checador físico creado (9 de septiembre de 2026):** `SCJ-PRO-11 §V` ya
  especificaba que el checador es su propio subproyecto con repositorio propio — creado en
  `/home/diego/Proyectos/checador-fisico/`, pusheado a
  `https://github.com/Churr000God/Checador_RTB.git` (rama `main`). Versión deliberadamente básica
  (sin Raspberry Pi ni lector biométrico decidido todavía): FastAPI + Jinja2 sin build de Node,
  SQLite local sin ORM sobre el esquema ER que mandó el usuario (`entidad_local.marca` +
  `entidad_local.persona_cache`) más una columna no negociable, `evento_id` (idempotencia,
  `SCJ-CDT-01 §VIII.2`), lector biométrico abstracto con stub, JWT autofirmado con
  `role=terminal_checador` (el rol de Postgres ya existe acá desde
  `db/ddl/37_tiempo_rls_terminal.sql`), sync simple contra `tiempo.marca` real. Identidad visual de
  Kairos aplicada a las 3 pestañas (Marcar/Historial/Config) para pantalla táctil de kiosco. Todo
  lo diferido (protocolo de lotes, reintentos con backoff, lector real, etc.) documentado en el
  `README.md` de ese repo, no acá. Ver
  `bitacora/2026-09-09_checador_fisico_subproyecto_creado.md`.

## Arquitectura y módulos

- Dos esquemas separados por una frontera explícita (`docs/00-contexto/SCJ-FRO-01_*.md`):
  `persona_id` es el único dato que cruza de `personas` a `tiempo`. Ningún atributo de identidad
  vive en `tiempo`.
- El DDL se diseña y prueba aquí, sobre datos sintéticos, y se copia a RTB-App como migración.
  **Nunca en sentido inverso** — ningún dato real regresa a este repositorio.
- Mapa de carpetas completo en `README.md` §"Estructura del repositorio".

## Reglas de negocio críticas

Cada una vive en su propio documento de decisión — no se duplican aquí, sólo se referencian:

- Validación de paridad de marcas → `docs/03-decisiones/SCJ-DEC-01_*.md`
- Saldo del banco de horas → `docs/03-decisiones/SCJ-DEC-02_*.md`
- Modelo de correcciones (inmutabilidad de la marca) → `docs/03-decisiones/SCJ-DEC-03_*.md`
- Vigencias temporales sin traslape → `docs/03-decisiones/SCJ-DEC-04_*.md`
- Flujo de autorización configurable → `docs/03-decisiones/SCJ-DEC-05_*.md`
- Entidad día o estado derivado (día bloqueado) → `docs/03-decisiones/SCJ-DEC-06_*.md`
- Modelo de excepciones (`requiere_revision`/`motivo_revision`) → `docs/03-decisiones/SCJ-DEC-07_*.md`
- Clave de la marca (`evento_id`) → `docs/03-decisiones/SCJ-DEC-08_*.md`
- Unicidad parcial de secuencia (`terminal_id` + `secuencia_local`) → `docs/03-decisiones/SCJ-DEC-09_*.md`

## Gotchas conocidos

- **Ningún documento con folio `RTB-` entra al repositorio** (`.gitignore` los excluye por
  patrón). Identifican a la empresa real. Ver `docs/00-contexto/SCJ-ANO-01_*.md`.
- Los valores de política en `db/ddl/03_parametros_ejemplo.sql` son de ejemplo, no reales.
- Los diagramas se versionan como texto (Mermaid/PlantUML) en `diagramas/fuente/`, nunca binarios.
- La versión en el nombre de archivo y la del encabezado del documento siempre coinciden
  (`CONVENCIONES.md`).
- El esquema se congela el 25 de septiembre de 2026 (`docs/06-actas/SCJ-ACT-03_*.md`); después de
  esa fecha ningún cambio sin que RTB-App se entere.
- `SCJ-PRA-01`, `SCJ-TRZ-01`, `SCJ-GLO-01` y `bitacora/` son documentos vivos: se tocan en cada
  sesión de trabajo, no se "empiezan" una vez.
- Exponer un esquema en Data API (Dashboard → Integrations → Data API → Settings → Exposed
  schemas) **no** otorga permisos de Postgres — hace falta además el `GRANT` explícito
  (`db/ddl/08_personas_permisos.sql`). Sin los dos, PostgREST responde "permission denied for
  schema…" aunque el esquema se vea expuesto en el dashboard.
- El dashboard de Supabase (Site URL, Redirect URLs, plantillas de correo) tiene
  `http://localhost:5173` fijo a mano — esa configuración no vive en este repositorio. Al pasar a
  producción (`docker compose … prod`, frontend en `:8080`) hay que actualizarla ahí también, o
  los links de invitación/recuperación de contraseña no aterrizan en la app.
- El DDL corre hasta `db/ddl/68_*.sql`. `personas.permiso`
  es la única tabla del proyecto con clave natural (`codigo varchar PRIMARY KEY`) en vez de `uuid`
  — decisión deliberada, fiel a la redacción literal de `SCJ-PRO-05`, no un descuido a corregir.
- Las tablas de bitácora inmutables (`bitacora_movimiento_persona`,
  `bitacora_movimiento_puesto_permiso`) bloquean `UPDATE`/`DELETE` **incluso para `postgres`** — a
  propósito, es la garantía de auditoría. Consecuencia real: si una cuenta de desarrollo/QA generó
  aunque sea una fila ahí (como autor o como persona afectada), no se puede borrar esa cuenta
  quirúrgicamente ni con acceso de superusuario. La única salida limpia es `DROP SCHEMA ... CASCADE`
  + reaplicar el DDL versionado desde cero (que sí regenera todo el dato real, porque está
  capturado en archivos `.sql`) — no intentar desactivar el trigger ni forzar el `DELETE`.
- `ALTER DEFAULT PRIVILEGES` de `08_personas_permisos.sql` le da `GRANT ALL` a cualquier tabla nueva
  creada por el mismo rol — eso incluye `UPDATE`/`DELETE`, que un `GRANT` explícito más chico
  (`SELECT, INSERT`) **no revoca** (`GRANT` es aditivo). Toda tabla de bitácora nueva que deba ser
  inmutable necesita su propio `REVOKE UPDATE, DELETE` explícito desde el arranque, no asumir que
  "nunca se concedieron" sólo porque el `GRANT` del archivo no los menciona (hallazgo real de
  seguridad en el corte de `puesto_permiso`, corregido en `28_*.sql`).
- **RLS no es automáticamente autorización — puede ser sólo autenticación disfrazada.** Hasta
  `30_*.sql`, las policies de `area`/`departamento`/`puesto`/`asignacion`/`permiso`/
  `puesto_permiso`/`persona`/`usuario` sólo exigían `fn_caller_activo()` (persona activa, no
  suspendida) para INSERT/UPDATE/DELETE — nunca el permiso específico que sí valida
  `backend/app/permisos.py::requiere_permiso(...)`. Como los 7 routers de Estructura
  Organizacional/Personas usan `get_caller_client` (anon key + JWT del usuario, sujeto a RLS) para
  **toda** lectura y escritura — nunca `service_role` — y el esquema está expuesto en Data API con
  `GRANT ALL` a `anon`/`authenticated`, cualquier persona activa podía pegarle directo a PostgREST
  (bypaseando FastAPI por completo) e insertar en `bitacora_movimiento_puesto_permiso`; el trigger
  `fn_puesto_permiso_sincroniza` sincronizaba eso en un otorgamiento real, sin pasar por ninguna de
  las validaciones de auto-otorgamiento de `routers/permisos.py`. Escalaba a admin total del
  módulo de permisos partiendo de cualquier cuenta. Corregido en
  `31_personas_rls_permiso_especifico.sql`: `personas.fn_caller_tiene_permiso(codigo)` replica en
  SQL (con herencia jerárquica) la misma lógica de `tiene_permiso()` de Python, y las policies de
  escritura ahora la exigen además de `fn_caller_activo()`. **Lección para módulos nuevos:** si un
  router usa `get_caller_client` en vez de `service_role`, la policy RLS de esas tablas es la
  autorización real, no un respaldo — hay que validar el permiso específico ahí, no sólo "¿está
  activo?".
- **El puesto administrador (`personas.puesto.es_administrador_generico`) no puede quedar sin
  acceso, por diseño.** Columna booleana (`32_puesto_administrador_generico_proteccion.sql`),
  inmutable después del backfill inicial (trigger `BEFORE UPDATE`, mismo patrón que las bitácoras
  inmutables) — ni con `puesto_edicion` se le puede apagar el flag por PostgREST directo. Bloqueada
  en RLS, sin excepción (ni auto-acción, ni de otro puesto con el permiso correspondiente): revocar
  cualquier permiso, terminar o reasignar la asignación de quien lo ocupa, y desactivar el puesto.
  `fn_asignacion_cambiar_puesto` no necesitó cambio propio (`SECURITY INVOKER`, pasa por el mismo
  `UPDATE` que ya cubre la policy de `asignacion`). Backend tiene el chequeo espejo en los 4
  endpoints correspondientes (`revocar_permiso`, `terminar_asignacion`,
  `cambiar_puesto_asignacion`, `cambiar_estado_puesto`) sólo para dar un `422` legible — RLS es la
  que efectivamente lo impide. Reglas documentadas en `SCJ-PRO-04/05/06 §V`. **Si se agrega un
  vector de mutación nuevo sobre `puesto`/`asignacion`/`puesto_permiso` en el futuro, hay que
  evaluar si también puede sacarle acceso al puesto administrador y protegerlo igual.**
- **Todo `GRANT ALL` schema-wide nuevo debe traer, en el mismo corte, un inventario explícito de
  qué tablas quedan con RLS real y cuáles quedan en deny-by-default.** Pasó dos veces con `tiempo`
  (6 de septiembre de 2026): `38_tiempo_permisos.sql` (el equivalente de `08_personas_permisos.sql`
  para el esquema `tiempo`, nunca había existido) dejó 14 tablas nuevas sin ninguna policy — `anon`
  sin login podía leer/escribir/borrar directo por PostgREST, corregido con
  `41_tiempo_rls_deny_default.sql`. Volvió a pasar con `tiempo.excepcion` específicamente: su RLS
  se tuvo que apagar (`42_*.sql`) porque dos triggers no-`SECURITY DEFINER` necesitaban escribir
  ahí como el caller humano, y nadie le revocó el `GRANT` heredado hasta que `marcas.py` empezó a
  leerla en producción (`47_tiempo_excepcion_revoca_anon.sql`). **Revisar caso por caso, no asumir
  que "ya está bien" por dejarlo como estaba antes de la migración anterior.**
- **Un endpoint/batch que escribe en más de una tabla relacionada probablemente necesita un RPC
  transaccional, no inserts sueltos** — pasó 3 veces en el módulo Tiempo
  (`fn_jornada_asignar_renovar`, `fn_ausencia_resolver`, `fn_corte_quincenal_aplicar_persona`, ver
  arriba) que la falta de atomicidad se descubrió recién en la revisión de seguridad de la fase,
  no en el diseño. Preguntarlo desde el arranque de cualquier endpoint/batch nuevo que toque 2+
  tablas.

- **Ninguna sesión corre queries de escritura/RPC directo contra la BD real de Supabase para
  "reproducir" o "depurar" un bug** — pasó una vez (7 de septiembre de 2026): al investigar un
  422 en la asignación de jornada, `backend` corrió el RPC de asignación vía `psql` directo
  contra producción (no contra datos sintéticos de prueba) para ver si reproducía, y de paso
  cerró la jornada vigente real del administrador (alteró `tiempo.jornada_asignada.vigente_hasta`
  de una fila real). El permission classifier bloqueó su propio intento de revertirlo, y
  `orchestrator` correctamente rehusó ejecutar esa reversión en su lugar (habría sido rodear una
  denegación ajena) — lo escaló al usuario, quien autorizó la restauración manual. El bug
  original resultó transitorio. **Lección:** un bug se reproduce con tests/mocks o, si hace falta
  BD real, con `SELECT` de sólo lectura y aprobación explícita del usuario antes de cualquier
  `INSERT`/`UPDATE`/`DELETE`/RPC de escritura fuera de una migración versionada de `db/ddl/`.
- **`psql "$DATABASE_URL"` puede colgarse indefinidamente contra el pooler de Supabase** (puerto
  `6543`) en esta máquina — el TCP conecta (confirmado con `openssl s_client`), pero el handshake
  de Postgres/TLS nunca completa, tanto desde el sandbox de una sesión como desde la shell real del
  usuario (7 de septiembre de 2026, aplicando `61_*.sql`). No es un problema de la migración ni de
  credenciales. **Lección:** no reintentar `psql` más de 2-3 veces — pegar el archivo directo en el
  SQL Editor del dashboard de Supabase. Desde el 8 de septiembre `psql` sí volvió a funcionar sin
  colgarse (`62_*.sql` a `67_*.sql` se aplicaron todos por esa vía) — el gotcha sigue vigente como
  posibilidad, no asumir que "ya se solucionó para siempre".
- **`CREATE OR REPLACE FUNCTION` no hereda `SECURITY DEFINER`/`SET search_path` de un `ALTER
  FUNCTION` anterior — los resetea a los valores por defecto si no se repiten explícitos.**
  Encontrado el 8 de septiembre de 2026 al modificar `fn_ausencia_resuelve_excepcion` (que había
  ganado `SECURITY DEFINER SET search_path = tiempo, pg_temp` vía `51_*.sql`, no en su
  `CREATE FUNCTION` original): reescribirla con un `CREATE OR REPLACE FUNCTION ... $$ LANGUAGE
  plpgsql;` literal habría reintroducido en silencio el mismo bug de RLS sobre `tiempo.dia` que
  `51_*.sql` corrigió. **Lección:** antes de tocar con `CREATE OR REPLACE` cualquier función que
  alguna vez recibió un `ALTER FUNCTION` posterior a su creación (buscar el nombre de la función en
  todo `db/ddl/*.sql`), repetir esas cláusulas explícitas en el nuevo `CREATE OR REPLACE` — no
  asumir que se heredan.
- **Ninguna vigencia debe poder quedar con `vigente_hasta` anterior a su propio `vigente_desde` —
  y ningún `CHECK` lo impedía en `tiempo.jornada_asignada` hasta que pasó de verdad.** Renovar una
  jornada dos veces el mismo día (`db/ddl/67_*.sql`, 8 de septiembre de 2026): el RPC calculaba
  `vigente_hasta = nueva.vigente_desde - 1` asumiendo que la nueva siempre empieza *después* de que
  empezó la anterior — con el mismo `vigente_desde` en las dos, eso da un intervalo invertido,
  guardado en silencio. Cazado con logging temporal real tras descartar RLS/doble-submit/payload
  obsoleto de escritorio como hipótesis de escritorio, ninguna correcta. **Lección:** toda tabla
  con `vigente_desde`/`vigente_hasta` (`jornada_asignada`, `tope_legal`, `parametro`, `asignacion`)
  debería tener su propio `CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)` — sólo
  `jornada_asignada` lo tiene por ahora, agregado recién tras encontrar el bug, no por diseño desde
  el principio. Revisar las demás si se vuelve a tocar alguna.
- **Un endpoint que lee de una tabla para validar y escribe en otra no debe asumir que el permiso
  de escritura siempre va a traer consigo el de lectura de la primera.** Encontrado el 8 de
  septiembre de 2026 al construir el POST manual de `movimiento_de_saldo`
  (`routers/banco_de_horas.py::registrar_movimiento_manual`, `db/ddl/68_*.sql`): el endpoint
  necesita leer `tiempo.banco_de_horas` (RLS exige específicamente `banco_de_horas_lectura`, sin
  `OR` con `movimiento_de_saldo_edicion` — no existe `banco_de_horas_edicion` en el catálogo) antes
  de poder escribir en `movimiento_de_saldo` (gateado por `movimiento_de_saldo_edicion`). Con
  `get_caller_client` para todo, alguien con sólo el segundo permiso habría recibido un 404 falso
  ("no tiene banco de horas") en vez de la validación real — hoy no pasa porque los 3 puestos que
  tienen `movimiento_de_saldo_edicion` también tienen `banco_de_horas_lectura` mapeado, pero el
  código no debería depender de esa coincidencia. **Lección:** cuando un endpoint combina lectura
  de insumo (para validar) con una escritura real gateada por RLS, usar dos clientes Supabase
  distintos si los permisos no están garantizados de estar siempre acoplados — `service_role` para
  la lectura de insumo (no es la autorización, sólo datos para decidir), el cliente del caller sólo
  para la escritura real (ahí sí importa la identidad, RLS es la autorización).

- **Un `OR` agregado a una policy RLS de UPDATE para "dejar pasar un trigger interno" abre acceso
  más ancho de lo previsto para todos los demás callers — y el `WITH CHECK` no puede cerrarlo.**
  Segunda vez que pasa (la primera fue `31_*.sql`, ya documentada arriba). El 10 de septiembre de
  2026, al agregar edición de datos de persona: `persona_update_requiere_permiso` necesitaba dejar
  pasar a `trg_bitacora_sincroniza_persona` (corre con los privilegios de quien sólo tiene
  `cambio_estado_persona`) sin perder la exigencia de `persona_edicion` para editar identidad —
  la solución obvia, `cambio_estado_persona OR persona_edicion`, deja que cualquiera con el primero
  toque cualquier columna, porque RLS no filtra por columna. **El `WITH CHECK` de una policy de
  UPDATE en Postgres sólo ve la fila NUEVA — no hay forma de referenciar la fila anterior (OLD)
  desde una expresión de policy**, así que "sólo permitir el cambio si NO tocó columnas de
  identidad" no se puede expresar ahí. Se resolvió con un trigger `BEFORE UPDATE` aparte
  (`trg_persona_protege_columnas_identidad`, `db/ddl/70_*.sql`) cuyo `WHEN` compara OLD/NEW.
  **Lección:** cualquier `OR` nuevo en una policy de UPDATE para dejar pasar un trigger interno
  no-`SECURITY DEFINER` necesita, desde el diseño inicial, evaluar si además hace falta un trigger
  `BEFORE UPDATE` con columnas explícitas — no asumir que el permiso más amplio del `OR` sólo se va
  a usar para lo que se diseñó.

## Historial de decisiones

Vacío por ahora. Las decisiones de diseño están en `docs/03-decisiones/`; la retrospectiva final
en `docs/05-entrega/SCJ-ENT-03_*.md`.
