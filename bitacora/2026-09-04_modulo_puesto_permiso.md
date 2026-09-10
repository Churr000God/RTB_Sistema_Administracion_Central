# 2026-09-04 — Quinto y último corte del módulo Estructura Organizacional: catálogo `puesto_permiso`

**Participantes:** `orchestrator` (coordinación) · `db` (DDL, catálogo, dos bootstraps, fix de
seguridad) · `backend` (API REST con la lógica de negocio más compleja del módulo) · `frontend`
(3 páginas + ficha de puesto extendida) · **`devops`** (primera vez en el módulo — bootstrap de
usuario base en `scripts/desplegar.sh`) · `testing` · `security`.

**Duración:** 4 de septiembre de 2026, inmediatamente después de commitear y verificar el corte de
`asignación` (`3de346f`).

---

## Contexto

Con `área`/`departamento`/`puesto`/`asignación` cerrados, este bloque cierra el módulo completo con
`SCJ-PRO-05` — otorgar/revocar permiso a puesto. Es el proceso más sensible: define quién puede
repartir permisos, con dos protecciones (bloqueo de auto-otorgamiento directo y por herencia,
bloqueo de dejar al sistema sin nadie que reparta) que el propio documento exige validar de verdad.

## El catálogo de permisos no existía en ningún lado — hasta que el usuario lo dio directo

Ni este repo ni el documento externo de especificación (`RTB-ESP-01`, consultado puntualmente sólo
para esta decisión — contiene PII real que nunca entró a ningún archivo) tenían una lista plana de
los ~16 permisos que `SCJ-PRO-04 §VI` mencionaba de pasada ("14 → 16"). El usuario proveyó el
catálogo completo directo en la conversación: **16 permisos**, 4 heredables
(`alta_personas_usuarios`, `cambio_estado_persona`, `ver_modulo_1`, `ver_modulo_2`) y 12 no
heredables (6 pares edición/lectura: área, departamento, puesto, permiso, puesto_permiso,
asignación). Cuadra exacto con el "14→16" ya documentado. Esta conversación es ahora la fuente de
verdad citada en `25_permiso_migracion_inicial.sql`.

## Qué se hizo

1. **DB** (`21` a `28`) — `personas.permiso` (única tabla del módulo con `codigo varchar` como
   `PRIMARY KEY` en vez de `uuid`, decisión deliberada y documentada, fiel a la redacción literal
   de `SCJ-PRO-05`), `personas.puesto_permiso`, `personas.bitacora_movimiento_puesto_permiso`
   (**inmutable desde el arranque**, no como parche posterior — a diferencia de
   `bitacora_movimiento_persona`, que sí necesitó un parche en su momento), trigger de
   sincronización. Seed del catálogo de 16. **Dos bootstraps distintos**:
   - Genérico (`26_*.sql`): área/departamento/puesto propios ("Tecnologías de la Información" /
     "Gerencia de Tecnologías de la Información" / "Gerente o Encargado de TI"), con los 16
     permisos completos, más una persona placeholder y su asignación — pensado para que **cualquier
     despliegue desde cero** tenga por dónde entrar, incluso sin el organigrama real aplicado.
   - Mapeo real (`27_*.sql`): 28 filas confirmadas con el usuario, otorgando permisos a los puestos
     reales ya sembrados (RH, TI, Dirección) según una matriz de autorización específica de esta
     empresa.
   Un hallazgo de seguridad post-auditoría (`28_*.sql`): la capa 1 de inmutabilidad (`REVOKE
   UPDATE/DELETE`) no había quedado aplicada en la base real por un default de privilegios heredado
   — corregido, sin impacto funcional porque el trigger ya cubría el caso.
2. **Backend** — 5 endpoints (`GET ""`, `GET /vigentes`, `GET /otorgados`, `POST /otorgar`, `POST
   /revocar`), con la validación de negocio más compleja del módulo: recorrido de subárbol
   jerárquico en memoria (BFS sobre el árbol completo de puestos, sin RPC nuevo) para detectar
   auto-otorgamiento por herencia, y el conteo de "última fila activa" a nivel de todo el sistema
   para `puesto_permiso_edicion`.
3. **Frontend** — `PermisosPage` (bitácora de eventos, sin acciones inline — decisión consciente
   para no cruzar eventos históricos contra el estado actual), `OtorgarPermisoPage`,
   `RevocarPermisoPage`, más la tarjeta "Permisos de este puesto" en `FichaPuestoPage`.
4. **DevOps** — `scripts/bootstrap_usuario_base.py` + un paso nuevo en `scripts/desplegar.sh`: la
   única pieza del bootstrap que no puede ser SQL puro (crear el `auth.users` real), con prompt
   interactivo (correo + contraseña con confirmación, `read -s`), sin tocar `.env`, sin dejar la
   contraseña en disco ni en el entorno del shell padre, con el mismo patrón de rollback de usuario
   huérfano ya usado en `usuarios.py`.
5. **Pruebas** — 16 casos backend nuevos (101 total), 23 casos frontend nuevos (191 total).
6. **Seguridad** — 5/6 puntos sin hallazgos. El hallazgo del punto 1 (corregido en `28_*.sql`).

## Fricciones de integración de esta ronda (ninguna llegó al usuario)

- `GET /otorgados`: mi propia instrucción fue ambigua ("bitácora global de puesto_permiso") —
  backend la interpretó como el estado actual de `puesto_permiso`; la corregí a que fuera la
  bitácora de eventos real (`bitacora_movimiento_puesto_permiso`), que es lo que el timeline de
  `PermisosPage` necesitaba.
- Eso dejó sin fuente de datos a "Revocar" y a la tarjeta de la ficha de puesto (necesitaban el
  ESTADO actual, no el log) — se agregó `GET /vigentes` para cubrir ese caso, exponiendo los
  schemas `PuestoPermisoOut`/`PuestoPermisoConDetalle` que backend ya había construido pero
  quedaron sin usar en la primera pasada.
- `frontend` trabajó en paralelo sin esperar el contrato final de `backend` (mismo patrón que
  `asignación`) — ajustó ambos endpoints sin drama una vez reconciliado.

## Qué se decidió

- **Sólo construir `puesto_permiso` en este corte** — el gate débil de
  área/departamento/puesto/asignación/persona/usuario **no se conecta todavía** para ninguno de
  los 16 permisos. Conectarlo ahora habría dejado al sistema sin nadie que pueda editar esos
  catálogos (el único permiso de arranque real era `puesto_permiso_edicion`, y el bloqueo de
  auto-otorgamiento le impide a cualquiera dárselo a sí mismo el resto). "Cerrar el gate" —
  incluida la conexión de `ver_modulo_1`/`2` al sidebar — queda como corte aparte.
- **Usuario base de bootstrap** — mecanismo nuevo, documentado también en memoria persistente
  (ver abajo) por pedido explícito del usuario.
- **Vía de escape siempre disponible**: `db` puede escribir directo en `puesto_permiso` vía `psql`
  (bypassa RLS) si algo queda mal — mismo mecanismo ya usado para los bootstraps de este corte.

## Qué quedó pendiente

- **Cerrar el gate** — conectar los 16 permisos a los routers ya construidos
  (área/departamento/puesto/asignación/persona/usuario), incluida la reconciliación de
  `ver_modulo_1`/`2` con el flag `disponible` de `NAV_GROUPS`. Requiere su propia decisión de qué
  sembrar de arranque para no bloquear el sistema — no se automatiza silenciosamente.
- Reconciliación manual si se carga un organigrama real con su propio tope, dado que el puesto
  "Gerente o Encargado de TI" del bootstrap genérico puede haberse vuelto tope en un despliegue sin
  organigrama previo.
- Con esto, los 5 procesos de `SCJ-PRO-03/04/05` (áreas, departamentos, puestos, asignaciones,
  permisos) están construidos de punta a punta. Sólo el resto de `SCJ-PRO-06` (baja de estructura
  con hijos reales de nivel más alto) sigue con guardas parciales.

## Conteos de tests al cierre de este bloque

- Backend: 85 → **101** casos (`uv run pytest`).
- Frontend: 168 → **191** casos (`npm test`).
